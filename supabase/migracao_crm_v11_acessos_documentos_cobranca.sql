-- =====================================================================
-- CRM Grupo BVEK — migração v11 (22/10/2026)
--  1. LOGINS COM PERFIL DE ACESSO (regras gravadas no banco, não só na tela)
--       administrador  : tudo, inclusive usuários, empresas e exclusões
--       comercial      : funil, propostas, clientes, contatos, projetos, atividades
--       administrativo : documentos e certidões, funcionários, projetos, atividades
--                        (funil e clientes só para consulta)
--       consulta       : só leitura
--       pendente       : login novo, sem acesso até o administrador liberar
--  2. CONTROLE DE DOCUMENTOS E CERTIDÕES (empresas do grupo e funcionários,
--     incluindo CAU e CREA), com antecedência de aviso por tipo e arquivo
--     guardado no Storage (bucket "documentos")
--  3. COBRANÇA DE RETORNO DAS PROPOSTAS: a etapa "Nutrição 2ª fase" vira
--     "1ª Cobrança"; novas etapas "2ª Cobrança" e "Em Negociação";
--     data da próxima cobrança calculada sozinha ao mudar de etapa
--       Proposta Enviada -> cobrar em 3 dias
--       1ª Cobrança      -> próxima em 4 dias
--       2ª Cobrança      -> próxima em 7 dias
--       Em Negociação    -> próxima em 7 dias
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. PERFIS DE ACESSO
-- ---------------------------------------------------------------------
create table if not exists public.perfis (
  id            uuid primary key references auth.users(id) on delete cascade,
  email         text,
  nome          text,
  perfil        text not null default 'pendente',
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.perfis drop constraint if exists perfis_perfil_chk;
alter table public.perfis add constraint perfis_perfil_chk
  check (perfil in ('pendente','administrador','comercial','administrativo','consulta'));

-- Perfil de quem está logado (null = sem acesso)
create or replace function public.bvek_perfil() returns text
language sql stable security definer set search_path = public as $$
  select perfil from public.perfis
   where id = auth.uid() and ativo and perfil <> 'pendente'
$$;

create or replace function public.bvek_ativo() returns boolean
language sql stable security definer set search_path = public as $$
  select public.bvek_perfil() is not null
$$;

create or replace function public.bvek_pode(p_perfis text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.bvek_perfil() = any(p_perfis), false)
$$;

grant execute on function public.bvek_perfil()        to authenticated;
grant execute on function public.bvek_ativo()         to authenticated;
grant execute on function public.bvek_pode(text[])    to authenticated;

-- Login novo criado no Supabase (Authentication → Add user) entra como "pendente"
create or replace function public.bvek_novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfis (id, email, nome, perfil)
  values (new.id, new.email, split_part(new.email, '@', 1), 'pendente')
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists bvek_novo_usuario on auth.users;
create trigger bvek_novo_usuario after insert on auth.users
  for each row execute function public.bvek_novo_usuario();

-- Logins que já existem: o André vira administrador; os demais mantêm o
-- trabalho de hoje como "comercial" (ajuste depois na aba Usuários).
-- Só vale na primeira vez: se a pessoa já tem perfil, nada muda.
insert into public.perfis (id, email, nome, perfil)
select u.id, u.email, split_part(u.email, '@', 1),
       case when lower(u.email) = 'andre.lessa@verdebrasilis.com.br' then 'administrador' else 'comercial' end
  from auth.users u
 where not exists (select 1 from public.perfis p where p.id = u.id);

-- Garante pelo menos um administrador (o login mais antigo, se faltar)
update public.perfis set perfil = 'administrador'
 where not exists (select 1 from public.perfis where perfil = 'administrador' and ativo)
   and id = (select u.id from auth.users u join public.perfis p on p.id = u.id order by u.created_at limit 1);

-- Não deixa ficar sem nenhum administrador ativo
create or replace function public.bvek_guarda_admin() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.perfil = 'administrador' and old.ativo
       and not exists (select 1 from public.perfis where perfil = 'administrador' and ativo and id <> old.id) then
      raise exception 'É preciso manter pelo menos um administrador ativo.';
    end if;
    return old;
  end if;
  if old.perfil = 'administrador' and old.ativo and (new.perfil <> 'administrador' or not new.ativo)
     and not exists (select 1 from public.perfis where perfil = 'administrador' and ativo and id <> old.id) then
    raise exception 'É preciso manter pelo menos um administrador ativo.';
  end if;
  new.atualizado_em := now();
  return new;
end $$;
drop trigger if exists bvek_perfis_guarda on public.perfis;
create trigger bvek_perfis_guarda before update or delete on public.perfis
  for each row execute function public.bvek_guarda_admin();

-- ---------------------------------------------------------------------
-- 2. DOCUMENTOS E CERTIDÕES
-- ---------------------------------------------------------------------
create table if not exists public.funcionarios (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  cargo       text,
  empresa_id  uuid references public.empresas(id),
  ativo       boolean not null default true,
  observacoes text,
  criado_em   timestamptz not null default now()
);

create table if not exists public.tipos_documento (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null unique,
  categoria     text not null default 'empresa',
  orgao         text,
  validade_dias integer,          -- sugestão para calcular a validade a partir da emissão
  dias_aviso    integer not null default 30,
  link_emissao  text,
  ordem         integer not null default 100,
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now()
);
alter table public.tipos_documento drop constraint if exists tipos_documento_categoria_chk;
alter table public.tipos_documento add constraint tipos_documento_categoria_chk
  check (categoria in ('empresa','funcionario'));

create table if not exists public.documentos (
  id              uuid primary key default gen_random_uuid(),
  tipo_id         uuid references public.tipos_documento(id),
  descricao       text,
  empresa_id      uuid references public.empresas(id),
  funcionario_id  uuid references public.funcionarios(id),
  orgao           text,
  numero          text,
  data_emissao    date,
  data_validade   date,            -- vazio = documento sem vencimento
  dias_aviso      integer not null default 30,
  responsavel     text,
  link_emissao    text,
  arquivo         text,
  arquivo_nome    text,
  observacoes     text,
  situacao        text not null default 'vigente',
  substituido_por uuid references public.documentos(id) on delete set null,
  criado_por      text,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);
alter table public.documentos drop constraint if exists documentos_situacao_chk;
alter table public.documentos add constraint documentos_situacao_chk
  check (situacao in ('vigente','substituido','arquivado'));
alter table public.documentos drop constraint if exists documentos_aviso_chk;
alter table public.documentos add constraint documentos_aviso_chk check (dias_aviso >= 0);
create index if not exists documentos_validade_idx on public.documentos (situacao, data_validade);
create index if not exists documentos_func_idx on public.documentos (funcionario_id);

-- Tipos de documento iniciais (editáveis depois no CRM)
insert into public.tipos_documento (nome, categoria, orgao, validade_dias, dias_aviso, link_emissao, ordem) values
  ('CND Federal (Receita Federal / PGFN)',              'empresa', 'Receita Federal / PGFN',  180,  20, 'https://solucoes.receita.fazenda.gov.br/Servicos/certidaointernet/PJ/Emitir', 10),
  ('CRF – Regularidade do FGTS',                        'empresa', 'Caixa Econômica Federal',  30,   7, 'https://consulta-crf.caixa.gov.br/consultacrf/pages/consultaEmpregador.jsf', 20),
  ('CNDT – Certidão Negativa de Débitos Trabalhistas',  'empresa', 'TST',                      180,  20, 'https://cndt-certidao.tst.jus.br/inicio.faces', 30),
  ('CND Estadual',                                      'empresa', 'SEFAZ / PGE',              null, 15, null, 40),
  ('CND Municipal',                                     'empresa', 'Prefeitura',               null, 15, null, 50),
  ('Certidão de Falência e Recuperação Judicial',       'empresa', 'Tribunal de Justiça',      null, 15, null, 60),
  ('CAU – Certidão de Registro e Quitação (PJ)',        'empresa', 'CAU',                      null, 15, 'https://siccau.caubr.gov.br/', 70),
  ('CAU – Anuidade / renovação do registro (PJ)',       'empresa', 'CAU',                      365,  30, 'https://siccau.caubr.gov.br/', 71),
  ('CREA – Certidão de Registro e Quitação (PJ)',       'empresa', 'CREA',                     null, 15, null, 80),
  ('CREA – Anuidade / renovação do registro (PJ)',      'empresa', 'CREA',                     365,  30, null, 81),
  ('Alvará de funcionamento',                           'empresa', 'Prefeitura',               null, 60, null, 90),
  ('Licença ambiental',                                 'empresa', 'Órgão ambiental',          null, 120, null, 100),
  ('Certificado do Corpo de Bombeiros',                 'empresa', 'Corpo de Bombeiros',       null, 60, null, 110),
  ('Certificado digital (e-CNPJ)',                      'empresa', 'Autoridade certificadora', null, 30, null, 120),
  ('Apólice de seguro',                                 'empresa', 'Seguradora',               365,  30, null, 130),
  ('Cadastro de fornecedor / SICAF',                    'empresa', null,                       null, 30, null, 140),
  ('Outro documento da empresa',                        'empresa', null,                       null, 30, null, 199),
  ('ASO – Atestado de Saúde Ocupacional',               'funcionario', 'Medicina do trabalho', 365,  30, null, 210),
  ('NR-06 – EPI',                                       'funcionario', null,                   null, 30, null, 220),
  ('NR-10 – Segurança em eletricidade',                 'funcionario', null,                   730,  30, null, 230),
  ('NR-12 – Máquinas e equipamentos',                   'funcionario', null,                   null, 30, null, 240),
  ('NR-18 – Construção civil',                          'funcionario', null,                   null, 30, null, 250),
  ('NR-33 – Espaço confinado',                          'funcionario', null,                   365,  30, null, 260),
  ('NR-35 – Trabalho em altura',                        'funcionario', null,                   730,  30, null, 270),
  ('CNH',                                               'funcionario', 'DETRAN',               null, 30, null, 280),
  ('CAU – Registro / anuidade do profissional',         'funcionario', 'CAU',                  365,  30, 'https://siccau.caubr.gov.br/', 290),
  ('CREA – Registro / anuidade do profissional',        'funcionario', 'CREA',                 365,  30, null, 300),
  ('Outro documento do funcionário',                    'funcionario', null,                   null, 30, null, 399)
on conflict (nome) do nothing;

-- Bucket privado para os arquivos dos documentos (PDF ou foto)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos', 'documentos', false, 20971520, array['application/pdf','image/jpeg','image/png'])
on conflict (id) do update set public = false, file_size_limit = 20971520,
  allowed_mime_types = array['application/pdf','image/jpeg','image/png'];

-- ---------------------------------------------------------------------
-- 3. COBRANÇA DE RETORNO DAS PROPOSTAS
-- ---------------------------------------------------------------------
alter table public.cards add column if not exists proxima_cobranca date;
alter table public.cards add column if not exists cobrancas_feitas integer not null default 0;
alter table public.cards add column if not exists ultima_cobranca  timestamptz;
alter table public.cards add column if not exists enviada_em       date;

create or replace function public.bvek_dias_cobranca(p_etapa text) returns integer
language sql immutable as $$
  select case p_etapa when 'enviada' then 3 when 'cobranca1' then 4
                      when 'cobranca2' then 7 when 'negociacao' then 7 end
$$;

create or replace function public.bvek_cobranca() returns trigger
language plpgsql as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_dias int  := public.bvek_dias_cobranca(new.etapa);
begin
  if tg_op = 'INSERT' then
    if v_dias is null then new.proxima_cobranca := null;
    else
      new.enviada_em := coalesce(new.enviada_em, v_hoje);
      new.proxima_cobranca := coalesce(new.proxima_cobranca, v_hoje + v_dias);
    end if;
  elsif new.etapa is distinct from old.etapa then
    if v_dias is null then
      new.proxima_cobranca := null;
    else
      new.enviada_em := coalesce(new.enviada_em, v_hoje);
      -- se a pessoa escolheu a data na mesma alteração, vale a dela
      if new.proxima_cobranca is not distinct from old.proxima_cobranca then
        new.proxima_cobranca := v_hoje + v_dias;
      end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists bvek_cards_cobranca on public.cards;
create trigger bvek_cards_cobranca before insert or update of etapa on public.cards
  for each row execute function public.bvek_cobranca();

-- Propostas já em "Proposta Enviada": data de envio e 1ª cobrança
update public.cards
   set enviada_em       = coalesce(enviada_em, (coalesce(etapa_desde, atualizado_em, now()) at time zone 'America/Sao_Paulo')::date),
       proxima_cobranca = coalesce(proxima_cobranca, (coalesce(etapa_desde, atualizado_em, now()) at time zone 'America/Sao_Paulo')::date + 3)
 where etapa = 'enviada';

-- Propostas em "Nutrição 2ª fase" passam para "1ª Cobrança", com cobrança para hoje
update public.cards
   set etapa = 'cobranca1',
       enviada_em = coalesce(enviada_em, (coalesce(etapa_desde, atualizado_em, now()) at time zone 'America/Sao_Paulo')::date),
       proxima_cobranca = (now() at time zone 'America/Sao_Paulo')::date
 where etapa = 'nutricao2';

-- ---------------------------------------------------------------------
-- 4. SEGURANÇA (RLS): o que cada perfil pode gravar
--    Ler: qualquer login liberado (não pendente, ativo)
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select * from (values
    ('empresas',            '{administrador}',                          '{administrador}',                          '{administrador}'),
    ('clientes',            '{administrador,comercial}',                '{administrador,comercial}',                '{administrador}'),
    ('contatos',            '{administrador,comercial}',                '{administrador,comercial}',                '{administrador,comercial}'),
    ('cards',               '{administrador,comercial}',                '{administrador,comercial}',                '{administrador}'),
    ('itens_proposta',      '{administrador,comercial}',                '{administrador,comercial}',                '{administrador,comercial}'),
    ('sequencia_propostas', '{administrador,comercial}',                '{administrador,comercial}',                '{administrador}'),
    ('historico_etapas',    '{administrador,comercial}',                '{administrador}',                          '{administrador}'),
    ('atividades',          '{administrador,comercial,administrativo}', '{administrador,comercial,administrativo}', '{administrador,comercial,administrativo}'),
    ('projetos',            '{administrador,comercial,administrativo}', '{administrador,comercial,administrativo}', '{administrador}'),
    ('funcionarios',        '{administrador,administrativo}',           '{administrador,administrativo}',           '{administrador}'),
    ('tipos_documento',     '{administrador,administrativo}',           '{administrador,administrativo}',           '{administrador}'),
    ('documentos',          '{administrador,administrativo}',           '{administrador,administrativo}',           '{administrador}'),
    ('perfis',              '{administrador}',                          '{administrador}',                          '{administrador}'),
    ('historico_cards',     '{administrador}',                          '{administrador}',                          '{administrador}'),
    ('propostas',           '{administrador}',                          '{administrador}',                          '{administrador}')
  ) as t(tabela, ins, upd, del)
  loop
    continue when to_regclass('public.' || r.tabela) is null;
    execute format('alter table public.%I enable row level security', r.tabela);
    execute format('drop policy if exists bvek_autenticado on public.%I', r.tabela);
    execute format('drop policy if exists bvek_ler on public.%I', r.tabela);
    execute format('drop policy if exists bvek_inserir on public.%I', r.tabela);
    execute format('drop policy if exists bvek_alterar on public.%I', r.tabela);
    execute format('drop policy if exists bvek_apagar on public.%I', r.tabela);
    execute format('create policy bvek_ler on public.%I for select to authenticated using (public.bvek_ativo())', r.tabela);
    execute format('create policy bvek_inserir on public.%I for insert to authenticated with check (public.bvek_pode(%L::text[]))', r.tabela, r.ins);
    execute format('create policy bvek_alterar on public.%I for update to authenticated using (public.bvek_pode(%L::text[])) with check (public.bvek_pode(%L::text[]))', r.tabela, r.upd, r.upd);
    execute format('create policy bvek_apagar on public.%I for delete to authenticated using (public.bvek_pode(%L::text[]))', r.tabela, r.del);
    execute format('grant select, insert, update, delete on public.%I to authenticated', r.tabela);
  end loop;
end $$;

-- Quem ainda está "pendente" consegue ler o próprio perfil (para ver o aviso)
drop policy if exists bvek_ler on public.perfis;
create policy bvek_ler on public.perfis for select to authenticated
  using (public.bvek_ativo() or id = auth.uid());

-- Arquivos: PDFs das propostas (comercial) e dos documentos (administrativo)
drop policy if exists propostas_ler      on storage.objects;
drop policy if exists propostas_enviar   on storage.objects;
drop policy if exists propostas_alterar  on storage.objects;
drop policy if exists propostas_apagar   on storage.objects;
create policy propostas_ler     on storage.objects for select to authenticated
  using (bucket_id = 'propostas' and public.bvek_ativo());
create policy propostas_enviar  on storage.objects for insert to authenticated
  with check (bucket_id = 'propostas' and public.bvek_pode('{administrador,comercial}'));
create policy propostas_alterar on storage.objects for update to authenticated
  using (bucket_id = 'propostas' and public.bvek_pode('{administrador,comercial}'))
  with check (bucket_id = 'propostas' and public.bvek_pode('{administrador,comercial}'));
create policy propostas_apagar  on storage.objects for delete to authenticated
  using (bucket_id = 'propostas' and public.bvek_pode('{administrador}'));

drop policy if exists documentos_ler      on storage.objects;
drop policy if exists documentos_enviar   on storage.objects;
drop policy if exists documentos_alterar  on storage.objects;
drop policy if exists documentos_apagar   on storage.objects;
create policy documentos_ler     on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and public.bvek_ativo());
create policy documentos_enviar  on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos' and public.bvek_pode('{administrador,administrativo}'));
create policy documentos_alterar on storage.objects for update to authenticated
  using (bucket_id = 'documentos' and public.bvek_pode('{administrador,administrativo}'))
  with check (bucket_id = 'documentos' and public.bvek_pode('{administrador,administrativo}'));
create policy documentos_apagar  on storage.objects for delete to authenticated
  using (bucket_id = 'documentos' and public.bvek_pode('{administrador}'));

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
-- 1) Logins e perfis: confira se o seu e-mail está como "administrador"
select p.email, p.nome, p.perfil, p.ativo from public.perfis p order by p.perfil, p.email;

-- 2) Resumo do resto
select (select count(*) from public.tipos_documento)                          as tipos_de_documento,
       (select count(*) from storage.buckets where id = 'documentos')        as bucket_documentos_ok,
       (select count(*) from public.cards where etapa = 'nutricao2')         as ainda_em_nutricao2_deve_ser_0,
       (select count(*) from public.cards where etapa = 'cobranca1')         as em_1a_cobranca,
       (select count(*) from public.cards where etapa = 'enviada')           as propostas_enviadas,
       (select count(*) from pg_policies where schemaname = 'public' and policyname = 'bvek_autenticado') as politicas_antigas_deve_ser_0;
