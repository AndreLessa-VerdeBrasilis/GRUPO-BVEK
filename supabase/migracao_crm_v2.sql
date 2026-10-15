-- =====================================================================
-- GRUPO-BVEK · CRM v2 · migração do banco (Supabase / PostgreSQL)
-- ---------------------------------------------------------------------
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- O script pode ser executado mais de uma vez sem duplicar nada.
-- Nada é apagado: clientes repetidos são apenas marcados como
-- "mesclados" (ativo = false) e seus atendimentos passam para o
-- cliente principal.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. CLIENTES: passa a ser a EMPRESA/PESSOA atendida, com código C###
-- ---------------------------------------------------------------------
alter table public.clientes add column if not exists codigo            text;
alter table public.clientes add column if not exists razao_social      text;
alter table public.clientes add column if not exists documento         text;
alter table public.clientes add column if not exists endereco          text;
alter table public.clientes add column if not exists empresas_atendidas text;
alter table public.clientes add column if not exists situacao          text;
alter table public.clientes add column if not exists observacoes       text;
alter table public.clientes add column if not exists referencias_rede  text;
alter table public.clientes add column if not exists ativo             boolean not null default true;
alter table public.clientes add column if not exists mesclado_em       uuid;
alter table public.clientes add column if not exists criado_em         timestamptz not null default now();

-- o cliente agora é do grupo todo (não de uma empresa só)
do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='clientes' and column_name='empresa_id') then
    execute 'alter table public.clientes alter column empresa_id drop not null';
  end if;
end $$;

create unique index if not exists clientes_codigo_uk on public.clientes (codigo) where codigo is not null;

-- ---------------------------------------------------------------------
-- 2. CONTATOS (várias pessoas por cliente)
-- ---------------------------------------------------------------------
create table if not exists public.contatos (
  id          uuid primary key default gen_random_uuid(),
  cliente_id  uuid not null references public.clientes(id) on delete cascade,
  nome        text not null,
  cargo       text,
  telefone    text,
  email       text,
  principal   boolean not null default false,
  observacoes text,
  criado_em   timestamptz not null default now()
);
create index if not exists contatos_cliente_idx on public.contatos (cliente_id);

-- ---------------------------------------------------------------------
-- 3. CARDS (atendimentos / propostas): campos novos
-- ---------------------------------------------------------------------
alter table public.cards add column if not exists contato_id           uuid references public.contatos(id) on delete set null;
alter table public.cards add column if not exists origem               text;
alter table public.cards add column if not exists probabilidade        integer;
alter table public.cards add column if not exists motivo_perda         text;
alter table public.cards add column if not exists motivo_perda_detalhe text;
alter table public.cards add column if not exists data_fechamento_real date;
alter table public.cards add column if not exists etapa_desde          timestamptz default now();
alter table public.cards add column if not exists projeto_id           uuid;

-- ---------------------------------------------------------------------
-- 4. HISTÓRICO DE ETAPAS (gravado automaticamente pelo banco)
-- ---------------------------------------------------------------------
create table if not exists public.historico_etapas (
  id          uuid primary key default gen_random_uuid(),
  card_id     uuid not null references public.cards(id) on delete cascade,
  etapa_de    text,
  etapa_para  text not null,
  usuario     text,
  criado_em   timestamptz not null default now()
);
create index if not exists historico_card_idx on public.historico_etapas (card_id, criado_em);

create or replace function public.bvek_registrar_etapa() returns trigger
language plpgsql as $$
declare v_user text;
begin
  begin v_user := coalesce(auth.jwt() ->> 'email', null); exception when others then v_user := null; end;
  if tg_op = 'INSERT' then
    new.etapa_desde := now();
  elsif new.etapa is distinct from old.etapa then
    new.etapa_desde := now();
    if new.etapa in ('fechada','perdida') and new.data_fechamento_real is null then
      new.data_fechamento_real := (now() at time zone 'America/Sao_Paulo')::date;
    end if;
    if new.etapa not in ('fechada','perdida') then
      new.data_fechamento_real := null;
    end if;
  end if;
  return new;
end $$;

create or replace function public.bvek_log_etapa() returns trigger
language plpgsql as $$
declare v_user text;
begin
  begin v_user := auth.jwt() ->> 'email'; exception when others then v_user := null; end;
  if tg_op = 'INSERT' then
    insert into public.historico_etapas (card_id, etapa_de, etapa_para, usuario)
    values (new.id, null, coalesce(new.etapa,'entrada'), v_user);
  elsif new.etapa is distinct from old.etapa then
    insert into public.historico_etapas (card_id, etapa_de, etapa_para, usuario)
    values (new.id, old.etapa, new.etapa, v_user);
  end if;
  return null;
end $$;

drop trigger if exists bvek_cards_etapa_before on public.cards;
create trigger bvek_cards_etapa_before before insert or update of etapa on public.cards
  for each row execute function public.bvek_registrar_etapa();
drop trigger if exists bvek_cards_etapa_after on public.cards;
create trigger bvek_cards_etapa_after after insert or update of etapa on public.cards
  for each row execute function public.bvek_log_etapa();

-- ---------------------------------------------------------------------
-- 5. ATIVIDADES / TAREFAS (ligação, e-mail, reunião, visita, tarefa, nota)
-- ---------------------------------------------------------------------
create table if not exists public.atividades (
  id            uuid primary key default gen_random_uuid(),
  card_id       uuid references public.cards(id) on delete cascade,
  cliente_id    uuid references public.clientes(id) on delete cascade,
  tipo          text not null default 'tarefa',
  descricao     text not null,
  data_prevista timestamptz,
  concluida     boolean not null default false,
  concluida_em  timestamptz,
  responsavel   text,
  criado_por    text,
  criado_em     timestamptz not null default now()
);
create index if not exists atividades_card_idx on public.atividades (card_id);
create index if not exists atividades_cliente_idx on public.atividades (cliente_id);
create index if not exists atividades_pend_idx on public.atividades (concluida, data_prevista);

-- ---------------------------------------------------------------------
-- 6. PROJETOS  (código C###-NNNN, sequência NNNN única para o grupo)
-- ---------------------------------------------------------------------
create table if not exists public.projetos (
  id          uuid primary key default gen_random_uuid(),
  seq         integer not null unique,
  codigo      text not null unique,
  cliente_id  uuid not null references public.clientes(id),
  card_id     uuid references public.cards(id) on delete set null,
  empresa_id  uuid references public.empresas(id),
  nome        text not null,
  local       text,
  ano         integer,
  status      text not null default 'Em andamento',
  pasta_rede  text,
  observacoes text,
  criado_em   timestamptz not null default now()
);
create index if not exists projetos_cliente_idx on public.projetos (cliente_id);

do $$ begin
  if not exists (select 1 from information_schema.table_constraints
                 where table_schema='public' and table_name='cards' and constraint_name='cards_projeto_fk') then
    alter table public.cards add constraint cards_projeto_fk foreign key (projeto_id) references public.projetos(id) on delete set null;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 7. FUNÇÕES (chamadas pelo sistema)
-- ---------------------------------------------------------------------

-- 7a. Número da proposta sem risco de repetir (ex.: VB001-0626)
create or replace function public.gerar_numero_proposta(p_empresa uuid) returns text
language plpgsql as $$
declare
  v_sigla text; v_mes int; v_ano int; v_num int; v_id uuid;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  select sigla into v_sigla from public.empresas where id = p_empresa;
  if v_sigla is null then raise exception 'Empresa não encontrada'; end if;
  v_mes := extract(month from v_hoje); v_ano := extract(year from v_hoje);
  perform pg_advisory_xact_lock(hashtext('bvek_prop_' || p_empresa::text || v_ano || v_mes));
  select id, ultimo_numero into v_id, v_num from public.sequencia_propostas
   where empresa_id = p_empresa and mes = v_mes and ano = v_ano
   order by ultimo_numero desc limit 1 for update;
  if v_id is null then
    v_num := 1;
    insert into public.sequencia_propostas (empresa_id, mes, ano, ultimo_numero) values (p_empresa, v_mes, v_ano, 1);
  else
    v_num := v_num + 1;
    update public.sequencia_propostas set ultimo_numero = v_num where id = v_id;
  end if;
  return upper(v_sigla) || lpad(v_num::text, 3, '0') || '-' || lpad(v_mes::text, 2, '0') || right(v_ano::text, 2);
end $$;

-- 7b. Próximo código de cliente livre (C092, C093…) — nunca reutiliza
create or replace function public.proximo_codigo_cliente() returns text
language sql stable as $$
  select 'C' || lpad((coalesce(max(substring(codigo from 2)::int), 0) + 1)::text, 3, '0')
    from public.clientes where codigo ~ '^C[0-9]+$';
$$;

-- 7c. Cliente novo recebe código automaticamente
create or replace function public.bvek_codigo_cliente() returns trigger
language plpgsql as $$
begin
  if new.codigo is null or new.codigo = '' then
    perform pg_advisory_xact_lock(hashtext('bvek_cod_cliente'));
    new.codigo := public.proximo_codigo_cliente();
  end if;
  new.nome := upper(trim(new.nome));
  return new;
end $$;
-- (o gatilho é criado DEPOIS da importação, no fim do script)

-- 7d. Dar código a um cliente antigo que ficou sem código
create or replace function public.gerar_codigo_cliente(p_cliente uuid) returns text
language plpgsql as $$
declare v text;
begin
  perform pg_advisory_xact_lock(hashtext('bvek_cod_cliente'));
  select codigo into v from public.clientes where id = p_cliente;
  if v is not null and v <> '' then return v; end if;
  v := public.proximo_codigo_cliente();
  update public.clientes set codigo = v where id = p_cliente;
  return v;
end $$;

-- 7e. Mesclar um cliente repetido em outro (não apaga; marca como mesclado)
create or replace function public.mesclar_clientes(p_origem uuid, p_destino uuid) returns void
language plpgsql as $$
begin
  if p_origem = p_destino then return; end if;
  update public.cards      set cliente_id = p_destino where cliente_id = p_origem;
  update public.contatos   set cliente_id = p_destino, principal = false where cliente_id = p_origem;
  update public.atividades set cliente_id = p_destino where cliente_id = p_origem;
  update public.projetos   set cliente_id = p_destino where cliente_id = p_origem;
  update public.clientes   set ativo = false, mesclado_em = p_destino where id = p_origem;
end $$;

-- 7f. Criar projeto com o próximo número da sequência do grupo
create sequence if not exists public.projetos_seq;

create or replace function public.criar_projeto(
  p_cliente uuid, p_nome text, p_empresa uuid default null, p_card uuid default null,
  p_local text default null, p_ano int default null, p_status text default 'Em andamento'
) returns public.projetos
language plpgsql as $$
declare v_cod text; v_cli text; v_seq int; v_row public.projetos;
begin
  select codigo, nome into v_cod, v_cli from public.clientes where id = p_cliente;
  if v_cod is null then raise exception 'O cliente precisa ter código (C###) antes de criar o projeto.'; end if;
  v_seq := nextval('public.projetos_seq');
  insert into public.projetos (seq, codigo, cliente_id, card_id, empresa_id, nome, local, ano, status, pasta_rede)
  values (v_seq, v_cod || '-' || lpad(v_seq::text, 4, '0'), p_cliente, p_card, p_empresa, upper(trim(p_nome)), p_local,
          coalesce(p_ano, extract(year from now())::int), coalesce(p_status, 'Em andamento'),
          '03_CLIENTES/' || v_cod || '_' || v_cli || '/05_PROJETOS/' || v_cod || '-' || lpad(v_seq::text, 4, '0') || ' ' || upper(trim(p_nome)))
  returning * into v_row;
  if p_card is not null then update public.cards set projeto_id = v_row.id where id = p_card; end if;
  return v_row;
end $$;

-- ---------------------------------------------------------------------
-- 8. CONVERTER OS CLIENTES QUE JÁ ESTAVAM NO CRM
--    Antes: cada "cliente" era uma pessoa (nome) + empresa_cliente.
--    Agora: a pessoa vira CONTATO e o cliente passa a ser a empresa.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  if not exists (select 1 from public.contatos limit 1) then
    for r in select * from public.clientes where codigo is null and coalesce(trim(nome),'') <> '' loop
      if coalesce(trim(r.empresa_cliente),'') <> '' and upper(trim(r.empresa_cliente)) <> upper(trim(r.nome)) then
        insert into public.contatos (cliente_id, nome, cargo, telefone, email, principal)
        values (r.id, trim(r.nome), r.cargo, r.telefone, r.email, true);
        update public.clientes set nome = upper(trim(r.empresa_cliente)) where id = r.id;
      else
        if coalesce(r.telefone,'') <> '' or coalesce(r.email,'') <> '' then
          insert into public.contatos (cliente_id, nome, cargo, telefone, email, principal)
          values (r.id, trim(r.nome), r.cargo, r.telefone, r.email, true);
        end if;
        update public.clientes set nome = upper(trim(r.nome)) where id = r.id;
      end if;
    end loop;
    -- liga os cards antigos ao contato principal
    update public.cards c set contato_id = ct.id
      from public.contatos ct where ct.cliente_id = c.cliente_id and ct.principal and c.contato_id is null;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 9. IMPORTAR O REGISTRO DE CLIENTES (C001–C091) DA REDE
-- ---------------------------------------------------------------------
create temporary table _reg (
  codigo text, nome text, razao_social text, documento text, endereco text,
  empresas_atendidas text, situacao text, referencias_rede text, observacoes text,
  contato_nome text, contato_tel text, contato_email text
) on commit drop;

insert into _reg values
('C001', 'ACM ILHA', 'Associação Cristã de Moços – unidade Ilha', null, null, 'VB', 'Proposta (04/12/2017, R$ 35.800)', '003 VB/Propostas Enviadas/ENVIAR: PC VB - ACM ILHA - AREAS VERDES (.docx, .emergencial, .etapa2)', null, 'Renata Athayde', '(21) 3396-3044', null),
('C002', 'AFTON BELFORD ROXO', 'AFTON CHEMICAL INDUSTRIA DE ADITIVOS LTDA', 'CNPJ 00.122.145/0002-46', 'Est. da Boa Esperança, 650 – Bom Pastor, Belford Roxo/RJ', 'VB/EK', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/Afton (NOTAS, AUDIT, DOCUMENTOS); 003 VB/CLIENTES/Afton; 01 ENGEKAT1/CLIENTES/Afton; 003 VB: Afton Depósito PET (jpg/pdf/dwg)', 'NFs separadas pelo CNPJ do XML. NFs 0024, 0027, 0028 e 0029 não têm XML (PDF imagem): arquivadas aqui por serem de 2018, período em que todas as notas com XML eram de Belford Roxo — conferir.', null, null, null),
('C003', 'AFTON DUQUE DE CAXIAS', 'AFTON CHEMICAL INDUSTRIA DE ADITIVOS LTDA', 'CNPJ 00.122.145/0003-27', 'Rua Silésia, 3501 – Campos Elíseos, Duque de Caxias/RJ', 'VB/EK', 'Cliente (NF emitida)', 'mesmas pastas da Afton; 003 VB/Propostas Enviadas: Afton Obras e Demolição - Reduc; 003 VB/Propostas Enviadas/ENVIAR: PC VB - AFTON CAXIAS - PINTURA INDUSTRIAL', 'NFs pelo CNPJ do XML: 0040, 0051, 0055, 0057, 0058, 0065, 0067, 0068, 0088, 0103, 0130.', null, null, null),
('C004', 'ALAMO ENGENHARIA', 'Álamo Engenharia', null, null, 'VB', 'Cliente', '003 VB/Álamo; 003 VB/Tim - Alamo', 'Contratante da obra no site da TIM.', null, null, null),
('C005', 'ALBERTO ZYNGIER', 'ALBERTO ZYNGIER', 'CPF 509.222.977-20', 'Rua Codajás, 408 – Leblon, RJ', 'VB', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/Alberto Zyngier (NF 0077 + XML)', null, null, null, null),
('C006', 'ALESSANDRA BENEVIDES', 'Alessandra Benevides', null, 'Estrada do Galeão, 1285 sl 304 (consultório)', 'VB', 'Proposta (06/12/2017)', '003 VB/Propostas Enviadas: PC VB - ALESSANDRA BENEVIDES - OBRAS.pdf; 003 VB/Propostas Enviadas/ENVIAR: .docx e .docx.pdf', null, 'Geral', '(21) 99909-8595', null),
('C007', 'AMJPVA', 'ASSOC MORADORES BAIRRO VISC ALBUQUERQUE E PERNAMBUCO', 'CNPJ 68.696.889/0001-27', 'Rua Gal. Urquiza, 132 – Leblon, RJ', 'VB', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/AMJPVA (14 NFs + XML); boleto BVK-FIN-BOL-ASSOCIACAO MORADORES LEBLON', 'O boleto ''Assoc. Moradores Leblon'' é deste cliente (mesmo CNPJ) — unifiquei.', null, null, null),
('C008', 'ARES', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - ARES - PODA DE ESPÉCIES ARBÓREAS.docx', null, null, null, null),
('C009', 'ARKEMA', null, null, null, 'EK', 'Cliente', '001 ENGEKAT/ARKEMA 25-26; 01 ENGEKAT1/ARKEMA 25-26; notebook andre/Arkema', 'Ainda existem cópias em 01 ENGEKAT1/ARKEMA 25-26 e notebook andre/Arkema — a comparar antes de apagar.', null, null, null),
('C010', 'ARTHUR PASTOR', 'Arthur Pastor', null, 'Av. das Américas, 3434 bl 5 – salas 321 a 324; Av. Delfim Moreira', 'VB', 'Proposta (17/05/2018, R$ 19.430)', '003 VB/Propostas Enviadas: PC VB - ARTHUR PASTOR - AV. DAS AMÉRICAS - PINTURA; PC VB - ARTHUR PASTOR - AV. DELFIN MOREIRA - LIMPEZA EM VIDROS; 05 Prospecção/CLIENTES/Arthur', 'A pasta 05/CLIENTES/Arthur continha notas do Louis (já renomeadas para LOUIS).', null, null, null),
('C011', 'ASSIM', 'Assim – hospital', null, null, 'EK', 'Cliente', '001 ENGEKAT/Assim', null, null, null, null),
('C012', 'ASSOCIACAO CULTURA FRANCO BRASILEIRA', 'ASSOCIACAO DE CULTURA FRANCO BRASILEIRA (Aliança Francesa)', 'CNPJ 33.075.722/0001-64', 'Rua Muniz Barreto, 746 – Botafogo (serviço na Rua Andrade Neves, 315 – Tijuca)', 'VB', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/Associação de Cultura Franco Brasileira (NF 0072 + XML); boleto BVK-FIN-BOL-ASSOCIACAO CULTURA FRANCO BRASILEIRA', null, 'Geral', '(21) 3299-2000', 'contab@rioaliancafrancesa.com.br'),
('C013', 'CAIXA AG ALCANTARA', 'Caixa Econômica Federal – Agência Alcântara', null, null, 'VB', 'Proposta (16/10/2017, R$ 5.120)', '003 VB/Propostas Enviadas: Proposta Verde Brasilis - Ag. Alcântara (.docx/.pdf)', null, 'Helena Ferreira', null, null),
('C014', 'CAIXA AG ANDARAI', 'Caixa Econômica Federal – Agência Andaraí', null, 'Andaraí, RJ', 'VB', 'Proposta (23/02/2018, R$ 2.370)', '003 VB/Propostas Enviadas/ENVIAR: PC VB - AG ANDARAÍ - PODA DE ESPÉCIES ABÓREAS.docx', null, null, null, null),
('C015', 'CAIXA AG BANGU', 'Caixa Econômica Federal – Agência Bangu', null, 'Bangu, RJ', 'VB', 'Proposta', '003 VB/Propostas Enviadas: Proposta Verde Brasilis - Ag. Bangu (.docx/.pdf)', null, null, null, null),
('C016', 'CAIXA AG SANTA CRUZ', 'Caixa Econômica Federal – Agência Santa Cruz', null, 'Santa Cruz, RJ', 'VB', 'Proposta', '003 VB/Propostas Enviadas: Proposta Verde Brasilis - Ag. Santa Cruz (.docx/.pdf)', null, null, null, null),
('C017', 'CENTRO ESPIRITA IRMAO ALIKEMUR', 'CENTRO ESPIRITA IRMAO ALIKEMUR', 'CNPJ 42.332.411/0001-24', 'Rua Barbosa da Silva, 44 – Riachuelo, RJ', 'VB', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/Centro Espírita (NF 0042 + XML); 003 VB/Propostas Enviadas/ENVIAR: PC VB - CENTRO ESPÍRITA IRMÃO ALIKEMUR - PODA', 'Número da nota descoberto no XML (0042) — arquivo renomeado.', null, null, null),
('C018', 'CLAUDIO', 'Cláudio', null, 'Região Oceânica, Niterói (construção de 2 casas)', 'VB', 'Proposta (12/04/2018)', '003 VB/Propostas Enviadas/ENVIAR: PC VB - CLÁUDIO - ADMINISTRAÇÃO DE CONSTRUÇÃO.docx', 'Proposta não traz sobrenome.', 'Geral', '(21) 99458-7147', null),
('C019', 'COLEGIO SANTA MARCELINA', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - Colégio Santa Marcelina - LIMPEZA EM FACHADA (.docx/.pdf) e - OBRAS (.docx/.pdf)', null, null, null, null),
('C020', 'COND CHACARA DO RIO', 'CONDOMINIO DO EDIFICIO CHACARA DO RIO', 'CNPJ 35.855.337/0001-65', 'Av. Paulo de Frontin, 730 – Rio Comprido, RJ', 'VB', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/Cond. Chácara do Rio (NF 0061 + XML, PC VB poda 19-01-2018); boleto BVK-FIN-BOL-CARNE COND ED CHACARA DO RIO', null, 'Geral', '(21) 2502-6255', 'adm_chacaradorio@yahoo.com.br'),
('C021', 'COND CHACARA DOS PINHEIROS', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas: Proposta Verde Brasilis - Cond. Chácara dos Pinheiros (17-10, 31-10, 08-11-2017); 003 VB/Propostas Enviadas/ENVIAR: PC VB - CHÁCARA DOS PINHEIROS 23-02-2018', null, null, null, null),
('C022', 'COND ED BELLA CAROLINA', 'CONDOMINIO DO EDIFICIO RESIDENCIAL BELLA CAROLINA', 'CNPJ 08.069.374/0001-75', 'Rua Carolina Santos, 170 – Lins de Vasconcelos, RJ', 'VB', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/Cond. do Ed. Bella Carolina (NF 0064 + XML); boletos BVK-FIN-BOL-COND ED BELLA CAROLINA e CARNE', null, 'Geral', '(21) 99985-6485', 'ms.assumpcao@uol.com.br'),
('C023', 'COND ED MEU BEM', null, null, null, 'VB', 'Cliente (boleto)', 'boleto BVK-FIN-BOL-COND ED MEU BEM', null, null, null, null),
('C024', 'COND ED PRESIDENTE CARLOS CAMPOS', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas: PC VB - CONDOMINIO DO ED. PRESIDENTE CARLOS CAMPOS - SUPRESSÃO VEGETAL.docx', null, null, null, null),
('C025', 'COPA DOR', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas: Copa D_or - Poda de Árvores Transformadores (.docx/.pdf)', null, null, null, null),
('C026', 'COSAN MOOVE', 'ILHA TERMINAL DISTRIBUICAO DE PRODUTOS DERIVADOS DE PETROLEO LTDA (grupo Cosan)', 'CNPJ 22.935.384/0001-77', 'Rua Campo da Ribeira, 51 – Ribeira, RJ', 'VB/EK', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/cosan moove (5 NFs + XML); 001 ENGEKAT: COSAN-MOOVE - Adufa.docx', null, 'Geral', null, 'nfse.carioca@cosan.com'),
('C027', 'CRECHE CRIAR', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - CRECHE CRIAR - GESSO ACARTONADO E PINTURA, - PINTURA EXTERNA, - SOLDA EM ESTRUTURA METÁLICA', null, null, null, null),
('C028', 'CRECHE PINTANDO O SETE', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - CRECHE PINTANDO O SETE - PODA DE PALMEIRA (.docx/.pdf)', null, null, null, null),
('C029', 'DENIS WRIGHT', null, null, null, 'VB', 'Proposta', '05 Prospecção/CLIENTES/Denis wrigth (PC VB poda drástica .pdf, solicitação de remoção); 003 VB/Propostas Enviadas/ENVIAR: PC VB - DENIS WRIGHT - PODA DRÁSTICA e - SUPRESSÃO VEGETAL', null, null, null, null),
('C030', 'DETRAN PENHA', null, null, 'Penha, RJ', 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - DETRAN PENHA - IMPERMEABILIZAÇÃO E PINTURA EM MARQUISE (.docx/.pdf)', null, null, null, null),
('C031', 'DROGARIA VIVA MAIS', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - DROGARIA VIVA MAIS - SUPRESSÃO VEGETAL.docx', null, null, null, null),
('C032', 'ENGEPRED', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - ENGEPRED - PODA DE ESPÉCIE ARBÓREA.docx', null, null, null, null),
('C033', 'FABIO MARIANO', 'Fábio Mariano', null, 'Pedra de Itaúna', 'VB', 'Proposta', '05 Prospecção/CLIENTES/Fábio Mariano (Disjuntores existentes.txt); 003 VB/Propostas Enviadas: Fábio - Pedra de Itaúna - Deck e paredes em madeira, - Rodapé; SM - Pedra de Itaúna - Reforma varanda gourmet', null, null, null, null),
('C034', 'FAST SHOP BARRA', null, null, 'Barra da Tijuca, RJ', 'VB/EK', 'Proposta', '003 VB/Propostas Enviadas: Proposta Manutenção periódica - Fast Shop Barra; Proposta Paisagismo - Fast Shop Barra; 001 ENGEKAT: Cópia de Proposta Manutenção periódica - Fast Shop Barra.docx', null, null, null, null),
('C035', 'FGV', 'FUNDACAO GETULIO VARGAS', 'CNPJ 33.641.663/0001-44', 'Praia de Botafogo, 190 – Botafogo, RJ', 'VB', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/FGV (3 NFs + XML)', null, 'Geral', '(21) 3799-6003', null),
('C036', 'FIGHT FOR PEACE', 'Fight for Peace', null, null, 'VB', 'Proposta (01/09/2015, R$ 90.000)', '05 Prospecção/CLIENTES/Luke/Luke.pdf', 'Proposta conjunta Verde Brasilis + Alta Paisagem (medida compensatória, 313 mudas).', 'Luke', null, null),
('C037', 'FIRJAN', 'Federação das Indústrias do Estado do RJ', null, null, 'VB', 'Cliente', '05 Prospecção/CLIENTES/Firjan (FIRJAN - DANÇA-MUSICA.pdf); 05 Prospecção/CLIENTES: edital firjan.pdf; 003 VB/Propostas Enviadas: Recibo de Caução - Firjan_.docx; 003 VB/Propostas Enviadas/ENVIAR: PC VB - SESI- PODA DE ESPÉCIES ARBÓREAS.docx (unidade não identificada)', 'A proposta ''PC VB - SESI- PODA DE ESPÉCIES ARBÓREAS'' é do SESI Petrópolis (Bengin) — arquivada em C074.', null, null, null),
('C038', 'GAYLUSSAC', 'GAYLUSSAC EMPREENDIMENTOS EDUCACIONAIS LTDA', 'CNPJ 07.528.125/0001-38', 'Rua Maria Caldas, 35 – São Francisco, Niterói/RJ', 'VB', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/GAYLUSSAC (notas 0033 e 0054, plantas .dwg); 003 VB/CLIENTES/GAYLUSSAC; 003 VB/Propostas Enviadas/ENVIAR: PC VB - GAYLUSSAC - MURO, - OBRAS', null, 'Geral', null, 'elizabethPrado@gaylussac.com.br'),
('C039', 'GLOBAL SERVICOS', 'GLOBAL SERVICOS LTDA ME', 'CNPJ 97.405.773/0001-90', 'Av. Embaixador Abelardo Bueno, 3330 sl 303 – Barra; serviço na Rua Ana Néri, 1029', 'VB', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/Global Serviços (NF 0071 + XML); boleto BVK-FIN-BOL-GLOBAL SERVICOS', null, 'Geral', '(21) 3347-5245', 'jennyfer.trampus@globalservicosltda.com'),
('C040', 'GW ENGENHARIA', null, null, null, 'EK', 'Cliente', '001 ENGEKAT/GW engenharia - VIBRA', null, null, null, null),
('C041', 'IASMIN', 'Iasmin', null, null, 'VB', 'Proposta (22/01/2018, R$ 9.318)', '003 VB/Propostas Enviadas/ENVIAR: PC VB - IASMIN - DRYWALL E PISO LAMINADO (.docx/.pdf, versão 23-01-2018)', 'Proposta não traz sobrenome.', 'Geral', '(21) 97699-0980', null),
('C042', 'INFINEUM', null, null, null, 'VB', 'Cliente', '003 VB/Infineum - Docs Podas de Árvores', null, null, null, null),
('C043', 'IVAN SILVA', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - IVAN SILVA - PODA DE ÁRVORES.docx', null, null, null, null),
('C044', 'JACQUELINE', 'Jacqueline', null, 'Angra dos Reis (reforma e extensão de cozinha)', 'VB', 'Proposta (30/04/2018)', '003 VB/Propostas Enviadas: PC VB - JACQUELINE - ADMINISTRAÇÃO DE CONSTRUÇÃO.docx; 003 VB/Propostas Enviadas/ENVIAR: idem', 'Proposta não traz sobrenome.', 'Geral', '(21) 99797-6799', null),
('C045', 'JOCKEY CLUB', null, null, null, 'VB', 'Proposta', '05 Prospecção/CLIENTES/JOCKEY CLUB (planilhas padrão 30 maio 2018); 05 Prospecção/CLIENTES/PGM: PLANILHA PADRÃO - JOCKEY OP. DE CAIXA; 003 VB/Propostas Enviadas/ENVIAR: PC VB - TERCEIRIZAÇÃO DE MÃO DE OBRA - JOCKEY CLUBE', null, null, null, null),
('C046', 'JSL', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas: PLANILHA CUSTOS - JSL (.pdf/.xls)', null, null, null, null),
('C047', 'KATIA MORAIS', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - KATIA MORAIS - SUPRESSÃO DE PALMEIRA.docx', null, null, null, null),
('C048', 'LARGO DO ARRUDA', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas: PC VB - LARGO DO ARRUDA - AREAS VERDES.pdf; 003 VB/Propostas Enviadas/ENVIAR: - AREAS VERDES.docx, - COMBATE A MOSQUITOS (.docx/.pdf/.alterada)', null, null, null, null),
('C049', 'LEANDRO', 'Leandro', null, null, 'VB', 'Proposta (21/12/2017, R$ 6.200)', '003 VB/Propostas Enviadas/ENVIAR: PC VB - LEANDRO - AREAS VERDES (.docx/.pdf)', 'Supressão de 1 Casuarina. Proposta não traz sobrenome nem telefone.', null, null, null),
('C050', 'LOUIS DE CHARBONNIERES', 'LOUIS ANTOINE DE SEGUR DE CHARBONNIERES', 'CPF 088.680.157-57', 'Av. Visconde de Albuquerque, 552 cob 504 – Leblon, RJ', 'VB', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/LOUIS (NF 0041 + XML + link); 05 Prospecção/CLIENTES/Arthur/NOTAS (NFs 0025, 0031, 0035 + XML)', 'Jardinagem 02/2016 a 01/2018, R$ 20.027 em 4 parcelas.', null, null, null),
('C051', 'MANE DO BRASIL', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - MANE DO BRASIL - MANUTENÇÃO DE AREAS VERDES.docx', null, null, null, null),
('C052', 'MERCK', 'Merck S.A.', null, null, 'VB', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/MERCK (NF 0019, ordens de compra 4540465025 e 4540500384, propostas, transplantio SMAC); 003 VB/Propostas Enviadas/ENVIAR: PC VB - MERCK - AREAS VERDES, PC VB - MERCK SA - AREAS VERDES', 'Atestado de capacidade técnica da Merck vai para o acervo técnico.', null, null, null),
('C053', 'MULTITERMINAIS', null, null, null, 'EK', 'Proposta', '001 ENGEKAT: MultiTerminais - Engekat (.docx/.pdf)', null, null, null, null),
('C054', 'NESTLE BARRA', 'NESTLE BRASIL LTDA', 'CNPJ 60.409.075/0106-20', 'Av. Luís Carlos Prestes, 290 sl 301/302 – Barra, RJ', 'VB', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/Nestlé (NFs 0131, 0132 + XML, Especificação de Itens); 003 VB/Propostas Enviadas: Nestlé - Especificação de Itens (003)', null, 'Geral', null, 'laura.sanzogo@br.nestle.com'),
('C055', 'NESTLE BH', 'Nestlé – Belo Horizonte', null, 'Belo Horizonte/MG', 'VB', 'Proposta', '003 VB/Propostas Enviadas: Proposta - Nestlé BH (Gilson) (.docx/.pdf)', null, 'Gilson', null, null),
('C056', 'PATRICIA JANSEN', 'Patrícia Jansen', null, null, 'VB', 'Proposta (11/12/2017, R$ 2.550)', '05 Prospecção/CLIENTES/Patrícia Jansen (fotos palmeira); 003 VB/Propostas Enviadas: PC VB - PATRICIA JANSEN - AREAS VERDES.docx', null, 'Geral', '(21) 98156-3892', null),
('C057', 'PGM', null, null, null, 'VB', 'Proposta (licitação)', '05 Prospecção/CLIENTES/PGM (PE 156-2018 - APOIO OPERACIONAL, pgm.pdf, planilhas, Demonstrativo, Documentos); 003 VB/Propostas Enviadas: PGM - CONTABILIDADE.pdf', 'Pregão eletrônico 156/2018.', null, null, null),
('C058', 'PNEL', 'PNEL', null, null, 'VB', 'Proposta (22/03/2018, R$ 2.500)', '003 VB/Propostas Enviadas: PC VB - PNEL CAMILA - PODA DE ÁRVORES, PC VB - PNEL CHRISTIANO - PODA DE ÁRVORES', 'Camila e Christiano são contatos da mesma empresa.', 'Camila Ávila', '(21) 3529-3045', 'camila.avila@pnel.com.br'),
('C059', 'POUSADA VILA DO SOL', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas e 003 VB/Propostas Enviadas/ENVIAR: PC VB - POUSADA VILA DO SOL - PODA DE ESPÉCIES ARBÓREAS.docx', null, null, null, null),
('C060', 'PROATIVA', 'Proativa', null, null, 'VB', 'Proposta', '05 Prospecção/CLIENTES/Jarbas (Proativa - Jarbas - Arvores 22-09.pdf); 003 VB/Propostas Enviadas: Proativa - Jarbas - Arvores (28-09 .docx/.pdf); 003 VB/Propostas Enviadas/ENVIAR: PC VB - PROATIVA - PODA EM ESPÉCIES ARBÓREAS', null, 'Jarbas (proprietário)', null, null),
('C061', 'PROPHYLAXIS', 'ProphylaxiS', null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas: SM - ProphylaxiS - Sprinkler (.docx/.pdf); proposta sprinkler (.docx/.pdf)', null, null, null, null),
('C062', 'REDE MV1', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - TERCEIRIZAÇÃO DE MÃO DE OBRA - REDE MV1.docx', null, null, null, null),
('C063', 'RESIDENCIAL CAICO', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - RESIDENCIAL CAICÓ - PINTURA.docx', null, null, null, null),
('C064', 'RITA', 'Rita', null, 'Ramos, RJ (construção de 10 moradias)', 'VB', 'Proposta (16/05/2018)', '003 VB/Propostas Enviadas/ENVIAR: PC VB - RITA - ADMINISTRAÇÃO DE CONSTRUÇÃO STEEL FRAME, - DEMOLIÇÃO E CONSTRUÇÃO STEEL FRAME', 'Proposta não traz sobrenome nem telefone.', null, null, null),
('C065', 'RODRIGO KALACHE', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - RODRIGO KALACHE - SUPRESSÃO VEGETAL.docx', null, null, null, null),
('C066', 'SALAO FONSECA', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas: PC VB - Faxina periódica - Salão Fonseca.docx', null, null, null, null),
('C067', 'SENAC CENTRO POLITECNICO', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas: PC VB - Medida Compensatória, - Supressão Vegetal, - Transplantio - Senac Centro Politécnico', null, null, null, null),
('C068', 'SENAI BOTAFOGO', null, null, 'Botafogo, RJ', 'VB', 'Cliente', '05 Prospecção/CLIENTES/Firjan/BOTAFOGO', null, null, null, null),
('C069', 'SESC ADM REGIONAL RJ', 'SERVICO SOCIAL DO COMERCIO SESC ADMINISTRACAO REGIONAL DO RIO DE JANEIRO', 'CNPJ 03.621.867/0015-58', 'Rua Barão de Mesquita, 539 – Andaraí/Tijuca, RJ', 'VB', 'Cliente', '05 Prospecção/CLIENTES/SESC/Licitações, SESC LICITAÇÃO (certidões); 003 VB/Propostas Enviadas: SESC - Poda de Árvores (09-17, 12-17, 01-18); 05 Prospecção/CLIENTES/SESC: SESC - Poda de Árvores (03-18)', 'Tomador das NFs do SESC (CNPJ da Adm. Regional). Aqui ficam editais/licitações e documentos de habilitação.', 'Geral', '(21) 2212-8300', null),
('C070', 'SESC BARRA MANSA', null, null, 'Barra Mansa/RJ', 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - SESC BARRA MANSA - PODA DE ESPÉCIES ARBÓREAS.docx', null, null, null, null),
('C071', 'SESC FAZENDINHA', null, null, null, 'VB', 'Cliente', '05 Prospecção/CLIENTES/SESC/SESC FAZENDINHA (Controle das Hortas); NF recebida ''Gasolina roçadeira fazendinha''', null, null, null, null),
('C072', 'SESC ILHA', null, null, null, 'VB', 'Cliente', '05 Prospecção/CLIENTES/SESC/SESC - Biblioteca Ilha 26', null, null, null, null),
('C073', 'SESC TIJUCA', 'mesma razão social do SESC Adm. Regional', 'CNPJ 03.621.867/0015-58', 'Rua Barão de Mesquita, 539 – Tijuca, RJ', 'VB', 'Cliente (NF emitida)', '05 Prospecção/CLIENTES/SESC/NOTAS FISCAIS (NFs 0056, 0076, 0102, 0124 + XML); 05 Prospecção/CLIENTES/SESC: Sesc Tijuca - Roçada; 003 VB: SESC Tijuca - Poda Emergencial; 003 VB/Propostas Enviadas/ENVIAR: PC VB - SESC TIJUCA - PODA DE PALMEIRAS E COQUEIROS, PC VC - SESC BARÃO DE MESQUITA', 'NFs 0056, 0076, 0102 e 0124 têm como tomador o SESC Adm. Regional, mas o serviço foi na unidade Tijuca — arquivadas aqui. As propostas ''SESC - Poda de Árvores'' (09-17, 12-17, 01-18, 03-18) são da unidade Tijuca (Paineiras).', 'Geral', '(21) 3138-1296', null),
('C074', 'SESI PETROPOLIS', null, null, 'Petrópolis/RJ', 'VB', 'Cliente', '05 Prospecção/CLIENTES/Firjan/PETRÓPOLIS (planilha orçamentária); 003 VB: Autorização e Relatório - SMA - SESI PETROPOLIS.pdf', null, null, null, null),
('C075', 'SESI SAO CRISTOVAO', null, null, 'São Cristóvão, RJ', 'VB', 'Proposta', '05 Prospecção/CLIENTES: Sesi - São Crsitovão (002).docx', null, null, null, null),
('C076', 'SESI SENADOR ALENCAR', null, null, null, 'VB', 'Cliente', '05 Prospecção/CLIENTES/Firjan/SENADOR ALENCAR; 05 Prospecção/CLIENTES: PC VB - SESI SENADOR ALENCAR - PODA.docx', null, null, null, null),
('C077', 'SESI SENAI TIJUCA', null, null, 'Tijuca, RJ', 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - SESI SENAI TIJUCA - PODA EM ESPÉCIE ARBÓREA e - PODA EM PALMEIRA (.docx/.pdf)', null, null, null, null),
('C078', 'SHEILA', 'Sheila', null, 'Estrada do Dendê', 'VB', 'Proposta (28/12/2017, R$ 1.150)', '003 VB/Propostas Enviadas e 003 VB/Propostas Enviadas/ENVIAR: PC VB - SHEILA - DRYWALL (.docx/.pdf)', 'Proposta não traz sobrenome.', 'Geral', '(21) 97515-1310', null),
('C079', 'SHELL', null, null, null, 'VB', 'Cliente', '003 VB/Shell - Levantamento Arbóreo', null, null, null, null),
('C080', 'STELLA MARIS', null, null, null, 'VB', 'Cliente', '05 Prospecção/CLIENTES/Stella Maris: ATESTADO DE CAPACIDADE TÉCNICA.docx', 'Único arquivo é um atestado — vai para o acervo técnico.', null, null, null),
('C081', 'SUBWAY PENHA', null, null, 'Penha, RJ', 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - SUBWAY PENHA - IMPERMEABILIZAÇÃO E PINTURA EM MARQUISE (.docx/.pdf)', null, null, null, null),
('C082', 'SUMMER DREAMS', null, null, 'apto 903', 'VB', 'Proposta', '003 VB/Propostas Enviadas: PC VB - Reparo - Summer Dreams 903.docx', null, null, null, null),
('C083', 'TANIA LUZ', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas: PC VB - TANIA LUZ - MEDIDA COMPENSATÓRIA (.docx/.pdf e retificada)', null, null, null, null),
('C084', 'TECNOSONDA', null, null, null, 'VB', 'Cliente', '003 VB/Tecnosonda-Verde Brasilis - Vale', 'Serviço executado para a Vale.', null, null, null),
('C085', 'TIEN NIO OEI', 'TIEN NIO OEI', 'CPF 239.749.157-53', 'Rua Graça Aranha, 350 – Leblon, RJ', 'VB', 'Cliente (boleto)', 'boleto BVK-FIN-BOL-AMJPVA GRACA ARANHA 350 (poda, 07/2019, 2 × R$ 8.250)', 'Conferido na migração: as 14 NFs da pasta AMJPVA são todas da AMJPVA (CNPJ). Nenhuma NF dele encontrada.', null, null, null),
('C086', 'TIM SAO CRISTOVAO', null, null, 'São Cristóvão, RJ', 'VB', 'Cliente', '003 VB/Tim - São Cristovão', null, null, null, null),
('C087', 'TOTUS ENGENHARIA', null, null, null, 'VB', 'Proposta', '003 VB/Propostas Enviadas/ENVIAR: PC VB - TOTUS ENGENHARIA - PODA DE ÁRVORE, - PODA DE ESPÉCIE ARBÓREA', null, null, null, null),
('C088', 'UNIMED', null, null, null, 'VB', 'Cliente', '003 VB/UNIMED - DOCUMENTOS', null, null, null, null),
('C089', 'VALE', null, null, null, 'VB', 'Cliente', '003 VB/Tecnosonda-Verde Brasilis - Vale', 'Separado da Tecnosonda, conforme sua orientação.', null, null, null),
('C090', 'VALQUIRIA', 'Valquiria', null, 'Rua Gen. Luiz Mendes de Morais, 50 – Santo Cristo', 'VB', 'Proposta (20/03/2018, R$ 9.568)', '003 VB/Propostas Enviadas: PC VB - VALQUIRIA - DRYWALL.docx', 'Ambientes citados (banheiro PNE, sala da diretoria, costura) indicam empresa — Valquiria deve ser o contato.', 'Geral', '(21) 2233-6648 / 98471-6836', null),
('C091', 'VIBRA', null, null, null, 'EK/VB', 'Cliente', '001 ENGEKAT: VIBRA CALHAS E RUFOS, ALIMENTAR - VIBRA CALHAS E RUFOS, PROJETO VIBRA RESERVATORIOS 09-2025, Documentos Padrão Vibra, Copia de documentos vibra; 003 VB/VIBRA - ROÇAGEM', null, null, null, null);

-- normalização de nomes para comparar (sem acento, sem pontuação)
create or replace function public.bvek_norm(t text) returns text
language sql immutable as $$
  select regexp_replace(
           translate(upper(coalesce(t,'')),
             'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ', 'AAAAAEEEEIIIIOOOOOUUUUCN'),
           '[^A-Z0-9]', '', 'g');
$$;

do $$
declare r record; v_master uuid; m record; v_obs text; v_sit text;
begin
  for r in select * from _reg order by codigo loop
    v_sit := case when r.situacao ilike 'Cliente%' then 'Cliente' else 'Prospect' end;
    v_obs := nullif(concat_ws(E'\n',
               case when r.situacao is not null then 'Registro da rede: ' || r.situacao end,
               r.observacoes), '');

    -- já importado antes? (script rodado de novo)
    select id into v_master from public.clientes where codigo = r.codigo;

    if v_master is null then
      -- procura cliente que já existia no CRM com o mesmo nome
      select id into v_master from public.clientes
       where codigo is null and ativo
         and (bvek_norm(nome) = bvek_norm(r.nome)
              or (r.razao_social is not null and bvek_norm(nome) = bvek_norm(r.razao_social)))
       order by criado_em, id limit 1;

      if v_master is not null then
        update public.clientes set
          codigo = r.codigo, nome = r.nome,
          razao_social = coalesce(razao_social, r.razao_social),
          documento = coalesce(documento, r.documento),
          endereco = coalesce(endereco, r.endereco),
          empresas_atendidas = coalesce(empresas_atendidas, r.empresas_atendidas),
          situacao = case when situacao = 'Cliente' then situacao else v_sit end,
          referencias_rede = r.referencias_rede,
          observacoes = concat_ws(E'\n', nullif(observacoes,''), v_obs)
        where id = v_master;
        -- outros registros repetidos do mesmo cliente → mescla no principal
        for m in select id from public.clientes
                  where codigo is null and ativo and id <> v_master
                    and (bvek_norm(nome) = bvek_norm(r.nome)
                         or (r.razao_social is not null and bvek_norm(nome) = bvek_norm(r.razao_social))) loop
          perform public.mesclar_clientes(m.id, v_master);
        end loop;
      else
        insert into public.clientes (codigo, nome, razao_social, documento, endereco, empresas_atendidas,
                                     situacao, referencias_rede, observacoes, empresa_cliente)
        values (r.codigo, r.nome, r.razao_social, r.documento, r.endereco, r.empresas_atendidas,
                v_sit, r.referencias_rede, v_obs, r.razao_social)
        returning id into v_master;
      end if;

      if r.contato_nome is not null and not exists (
           select 1 from public.contatos where cliente_id = v_master and bvek_norm(nome) = bvek_norm(r.contato_nome)) then
        insert into public.contatos (cliente_id, nome, telefone, email, principal)
        values (v_master, r.contato_nome, r.contato_tel, r.contato_email,
                not exists (select 1 from public.contatos where cliente_id = v_master));
      end if;
    end if;
  end loop;

  -- PNEL tem dois contatos
  insert into public.contatos (cliente_id, nome)
  select id, 'Christiano' from public.clientes c where codigo = 'C058'
     and not exists (select 1 from public.contatos where cliente_id = c.id and nome = 'Christiano');
end $$;

-- ---------------------------------------------------------------------
-- 10. IMPORTAR OS 13 PROJETOS JÁ CODIFICADOS NA REDE
-- ---------------------------------------------------------------------
insert into public.projetos (seq, codigo, cliente_id, empresa_id, nome, local, ano, status, pasta_rede)
select p.seq, c.codigo || '-' || lpad(p.seq::text, 4, '0'), c.id,
       (select id from public.empresas e where upper(e.sigla) = p.emp limit 1),
       p.nome, p.local, p.ano, p.status,
       case when p.pasta is null then null else '03_CLIENTES/' || c.codigo || '_' || c.nome || '/' || p.pasta end
from (values
  ( 1,'C073','PODA DE COQUEIROS E PALMEIRAS','VB','Rua Barão de Mesquita, 539 – Tijuca',2018,'Concluído',null),
  ( 2,'C042','PODA DE ARVORES','VB',null,null,'Concluído','05_PROJETOS/C042-0002 INFINEUM PODA DE ARVORES'),
  ( 3,'C079','LEVANTAMENTO ARBOREO','VB',null,null,'Concluído','05_PROJETOS/C079-0003 SHELL LEVANTAMENTO ARBOREO'),
  ( 4,'C084','TECNOSONDA VALE (serviço no site da Vale)','VB',null,null,'Concluído','05_PROJETOS/C084-0004 TECNOSONDA VALE'),
  ( 5,'C004','ALAMO TIM – MOBILIZAÇÃO SST','VB',null,null,'Concluído','05_PROJETOS/C004-0005 ALAMO TIM MOBILIZACAO SST'),
  ( 6,'C086','TIM SÃO CRISTÓVÃO – MOBILIZAÇÃO SST','VB','São Cristóvão, RJ',null,'Concluído','05_PROJETOS/C086-0006 TIM SAO CRISTOVAO MOBILIZACAO SST'),
  ( 7,'C088','UNIMED – MOBILIZAÇÃO','VB',null,null,'Concluído','05_PROJETOS/C088-0007 UNIMED MOBILIZACAO'),
  ( 8,'C091','VIBRA ROÇAGEM','VB',null,null,'Concluído','05_PROJETOS/C091-0008 VIBRA ROCAGEM'),
  ( 9,'C002','AFTON DEPÓSITO PET','VB','Belford Roxo/RJ',null,'Concluído','05_PROJETOS/C002-0009 AFTON DEPOSITO PET'),
  (10,'C091','VIBRA CALHAS, RUFOS, LINHA DE VIDA E ESCADAS','EK',null,2025,'Em andamento','05_PROJETOS/C091-0010 VIBRA CALHAS RUFOS LINHA DE VIDA E ESCADAS'),
  (11,'C091','VIBRA RESERVATÓRIOS 09-2025','EK',null,2025,'Em andamento','05_PROJETOS/C091-0011 VIBRA RESERVATORIOS 09-2025'),
  (12,'C009','ARKEMA 2025-2026 (obra laboratório e montagens)','EK',null,2025,'Em andamento','05_PROJETOS/C009-0012 ARKEMA 2025-2026'),
  (13,'C040','GW ENGENHARIA – VIBRA','EK',null,null,'Em andamento','05_PROJETOS/C040-0013 GW ENGENHARIA VIBRA')
) as p(seq, cod, nome, emp, local, ano, status, pasta)
join public.clientes c on c.codigo = p.cod
on conflict (seq) do nothing;

select setval('public.projetos_seq', greatest((select coalesce(max(seq),0) from public.projetos), 1),
              (select count(*) > 0 from public.projetos));

-- agora sim: todo cliente novo recebe o próximo código automaticamente
drop trigger if exists bvek_clientes_codigo on public.clientes;
create trigger bvek_clientes_codigo before insert on public.clientes
  for each row execute function public.bvek_codigo_cliente();

-- ---------------------------------------------------------------------
-- 11. SEGURANÇA (RLS): só quem fez login no sistema lê e grava
--     (sem isto, a chave pública do site dá acesso aos dados)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['empresas','clientes','contatos','cards','itens_proposta',
                           'sequencia_propostas','historico_etapas','atividades','projetos'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists bvek_autenticado on public.%I', t);
    execute format('create policy bvek_autenticado on public.%I for all to authenticated using (true) with check (true)', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

grant usage, select on sequence public.projetos_seq to authenticated;
grant execute on function public.gerar_numero_proposta(uuid)       to authenticated;
grant execute on function public.proximo_codigo_cliente()          to authenticated;
grant execute on function public.gerar_codigo_cliente(uuid)        to authenticated;
grant execute on function public.mesclar_clientes(uuid, uuid)      to authenticated;
grant execute on function public.criar_projeto(uuid, text, uuid, uuid, text, int, text) to authenticated;

commit;

-- Conferência rápida (opcional):
-- select codigo, nome, situacao from clientes where ativo order by codigo nulls first;
-- select codigo, nome, status from projetos order by seq;
