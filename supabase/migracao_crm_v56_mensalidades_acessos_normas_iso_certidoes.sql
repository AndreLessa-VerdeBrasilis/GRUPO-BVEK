-- =====================================================================
-- CRM Grupo BVEK — migração v56 (11/11/2026)
--
-- 1. FINANCEIRO → 📆 Mensalidades e débito automático (tabela mensalidades)
--    Domínios, sistemas, internet, seguros, assinaturas: valor, vencimento,
--    forma de pagamento (débito automático, cartão, boleto…) e alerta antes
--    de vencer. Administrador e Administrativo veem e cadastram; só o
--    administrador apaga. Já vêm cadastrados os 5 domínios do Registro.br
--    (sem valor/vencimento: preencha).
-- 2. GESTÃO → 🔐 Contas e acessos (tabela contas_acessos) — SÓ ADMINISTRADOR
--    Lista de sites e sistemas: login, responsável, onde está a senha
--    (McAfee) e a verificação em 2 etapas (Microsoft Authenticator…).
--    NÃO existe campo de senha: a senha fica só no McAfee.
-- 3. GESTÃO → 📜 Normas ISO 9001 / 14001 — SÓ ADMINISTRADOR
--    • iso_requisitos: lista de leis e requisitos (matriz de requisitos
--      legais), com situação de atendimento, comprovante, responsável e
--      próxima revisão. Já vem com uma lista inicial (federal, estado e
--      município do Rio de Janeiro) marcada "a avaliar".
--    • iso_novidades: leis novas encontradas pela busca automática no LexML
--      (portal oficial de legislação), para avaliar.
--    • iso_config: palavras da busca. Busca toda segunda-feira de manhã
--      (se o Supabase tiver pg_cron/pg_net; senão use o botão "Buscar agora").
-- 4. CURRÍCULOS → certidões entregues pelo candidato (só para funções que
--    justificam), com consentimento. Nada é consultado em nome do candidato.
--
-- Rode DEPOIS da v55. Pode rodar mais de uma vez. Nada é apagado.
-- Depois de rodar: publique a função nova "normas-iso"
-- (supabase/functions/normas-iso/index.ts).
-- =====================================================================

-- 1. MENSALIDADES -------------------------------------------------------------
create table if not exists public.mensalidades (
  id                   uuid primary key default gen_random_uuid(),
  descricao            text not null,                 -- ex.: Domínio bvek.com.br
  categoria            text not null default 'outro', -- dominio, sistema, internet, telefone, seguro, assinatura, servico, aluguel, outro
  fornecedor           text,                          -- ex.: Registro.br
  empresa_id           uuid references public.empresas(id) on delete set null,
  valor                numeric(12,2),
  periodicidade        text not null default 'mensal',-- mensal, bimestral, trimestral, semestral, anual, bienal, unica
  proximo_vencimento   date,
  forma_pagamento      text,                          -- debito_automatico, cartao, boleto, pix, transferencia, outro
  conta_cartao         text,                          -- ex.: Itaú Empresas · cartão final 1234 (nunca o número inteiro)
  renovacao_automatica boolean,
  alerta_dias          integer not null default 15,
  site                 text,                          -- onde ver/pagar
  responsavel          text,
  observacoes          text,
  ativo                boolean not null default true,
  ultimo_pagamento     date,
  criado_por           text,
  criado_em            timestamptz not null default now(),
  atualizado_em        timestamptz not null default now()
);
alter table public.mensalidades drop constraint if exists mensalidades_period_chk;
alter table public.mensalidades add constraint mensalidades_period_chk
  check (periodicidade in ('mensal','bimestral','trimestral','semestral','anual','bienal','unica'));
create index if not exists mensalidades_venc_idx on public.mensalidades (ativo, proximo_vencimento);

alter table public.mensalidades enable row level security;
drop policy if exists bvek_ler     on public.mensalidades;
drop policy if exists bvek_inserir on public.mensalidades;
drop policy if exists bvek_alterar on public.mensalidades;
drop policy if exists bvek_apagar  on public.mensalidades;
create policy bvek_ler     on public.mensalidades for select to authenticated using (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_inserir on public.mensalidades for insert to authenticated with check (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_alterar on public.mensalidades for update to authenticated
  using (public.bvek_pode('{administrador,administrativo}'::text[])) with check (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_apagar  on public.mensalidades for delete to authenticated using (public.bvek_pode('{administrador}'::text[]));
grant select, insert, update, delete on public.mensalidades to authenticated;
revoke all on public.mensalidades from anon;

-- os domínios do grupo (Registro.br) — sem valor e vencimento: preencha no CRM
insert into public.mensalidades (descricao, categoria, fornecedor, periodicidade, site, observacoes, criado_por)
select d, 'dominio', 'Registro.br', 'anual', 'https://registro.br',
       'Cadastrado pela migração v56: preencha valor, vencimento e forma de pagamento.', 'migração v56'
  from unnest(array['Domínio bvek.com.br','Domínio grupobvek.com.br','Domínio engekat.com.br','Domínio verdebrasilis.com.br','Domínio brasilimp.com.br']) d
 where not exists (select 1 from public.mensalidades m where lower(m.descricao) = lower(d));

-- 2. CONTAS E ACESSOS (só administrador; sem senha) ------------------------------
create table if not exists public.contas_acessos (
  id               uuid primary key default gen_random_uuid(),
  servico          text not null,              -- ex.: Itaú Empresas, Registro.br, gov.br, Microsoft 365
  categoria        text not null default 'outro', -- banco, governo, dominio, email, sistema, fornecedor, rede_social, outro
  site             text,
  login            text,                       -- usuário / e-mail / CPF-CNPJ de acesso (NUNCA a senha)
  empresa_id       uuid references public.empresas(id) on delete set null,
  responsavel      text,                       -- quem usa / quem cuida
  onde_senha       text default 'McAfee',      -- onde a senha está guardada
  dois_fatores     text,                       -- nenhum, microsoft_authenticator, sms, email, app_banco, token_fisico, outro
  dois_fatores_onde text,                      -- ex.: celular do André
  recuperacao      text,                       -- e-mail/telefone de recuperação
  mensalidade_id   uuid references public.mensalidades(id) on delete set null,
  ultima_revisao   date,
  observacoes      text,
  ativo            boolean not null default true,
  criado_por       text,
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now()
);
alter table public.contas_acessos enable row level security;
drop policy if exists bvek_ler     on public.contas_acessos;
drop policy if exists bvek_inserir on public.contas_acessos;
drop policy if exists bvek_alterar on public.contas_acessos;
drop policy if exists bvek_apagar  on public.contas_acessos;
create policy bvek_ler     on public.contas_acessos for select to authenticated using (public.bvek_pode('{administrador}'::text[]));
create policy bvek_inserir on public.contas_acessos for insert to authenticated with check (public.bvek_pode('{administrador}'::text[]));
create policy bvek_alterar on public.contas_acessos for update to authenticated
  using (public.bvek_pode('{administrador}'::text[])) with check (public.bvek_pode('{administrador}'::text[]));
create policy bvek_apagar  on public.contas_acessos for delete to authenticated using (public.bvek_pode('{administrador}'::text[]));
grant select, insert, update, delete on public.contas_acessos to authenticated;
revoke all on public.contas_acessos from anon;

-- 3. NORMAS ISO 9001 / 14001 (só administrador) ------------------------------------
create table if not exists public.iso_requisitos (
  id                 uuid primary key default gen_random_uuid(),
  norma              text not null default 'ambas',   -- 9001, 14001, ambas
  tipo               text not null default 'lei',     -- lei, decreto, resolucao, portaria, nr, norma_tecnica, licenca, requisito_cliente, outro
  esfera             text not null default 'federal', -- federal, estadual, municipal, outro
  titulo             text not null,                   -- ex.: Lei 12.305/2010
  orgao              text,                            -- ex.: CONAMA, INEA, ABNT
  ementa             text,                            -- do que trata
  link               text,
  empresas           uuid[] not null default '{}',    -- a quais empresas se aplica (vazio = todas)
  situacao           text not null default 'avaliar', -- avaliar, atendido, parcial, nao_atendido, nao_aplicavel
  como_atende        text,                            -- o que fazemos para cumprir
  evidencia          text,                            -- comprovante (documento, link, pasta)
  responsavel        text,
  proxima_revisao    date,
  periodicidade_meses integer not null default 12,
  ultima_revisao     date,
  origem             text not null default 'manual',  -- manual, lista_inicial, busca
  ativo              boolean not null default true,
  criado_por         text,
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now()
);
alter table public.iso_requisitos drop constraint if exists iso_requisitos_norma_chk;
alter table public.iso_requisitos add constraint iso_requisitos_norma_chk check (norma in ('9001','14001','ambas'));
alter table public.iso_requisitos drop constraint if exists iso_requisitos_sit_chk;
alter table public.iso_requisitos add constraint iso_requisitos_sit_chk
  check (situacao in ('avaliar','atendido','parcial','nao_atendido','nao_aplicavel'));
create unique index if not exists iso_requisitos_titulo_uk on public.iso_requisitos (lower(titulo));

create table if not exists public.iso_novidades (
  id              uuid primary key default gen_random_uuid(),
  fonte           text not null default 'lexml',
  chave           text not null,                 -- URN do LexML (não repete)
  titulo          text not null,
  ementa          text,
  data_publicacao date,
  esfera          text,
  tipo            text,
  link            text,
  termo           text,                          -- palavra da busca que encontrou
  situacao        text not null default 'avaliar', -- avaliar, incluida, descartada
  requisito_id    uuid references public.iso_requisitos(id) on delete set null,
  avaliado_por    text,
  avaliado_em     timestamptz,
  encontrado_em   timestamptz not null default now()
);
create unique index if not exists iso_novidades_chave_uk on public.iso_novidades (chave);
alter table public.iso_novidades drop constraint if exists iso_novidades_sit_chk;
alter table public.iso_novidades add constraint iso_novidades_sit_chk check (situacao in ('avaliar','incluida','descartada'));

create table if not exists public.iso_config (
  id            integer primary key default 1,
  termos        text[] not null default '{}',
  localidades   text[] not null default '{federal,rio.de.janeiro}',
  dias_busca    integer not null default 30,     -- na busca, olha leis publicadas nos últimos N dias
  ultima_busca  timestamptz,
  ultimo_resultado text,
  token_cron    text not null default replace(gen_random_uuid()::text, '-', ''),  -- senha da busca automática (fica só no banco)
  atualizado_em timestamptz not null default now()
);
alter table public.iso_config drop constraint if exists iso_config_uma_linha;
alter table public.iso_config add constraint iso_config_uma_linha check (id = 1);
insert into public.iso_config (id, termos) values (1, array[
  'licenciamento ambiental','resíduos sólidos','resíduos da construção civil','gerenciamento de resíduos',
  'logística reversa','efluentes','emissões atmosféricas','poluição sonora','supressão de vegetação',
  'poda de árvores','arborização urbana','recursos hídricos','produtos perigosos','transporte de resíduos',
  'mudanças climáticas','saneantes','obras e reformas em edificações','segurança e saúde no trabalho',
  'acessibilidade','licitações e contratos'
]) on conflict (id) do nothing;

do $$
declare t text;
begin
  foreach t in array array['iso_requisitos','iso_novidades','iso_config'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists bvek_ler on public.%I', t);
    execute format('drop policy if exists bvek_inserir on public.%I', t);
    execute format('drop policy if exists bvek_alterar on public.%I', t);
    execute format('drop policy if exists bvek_apagar on public.%I', t);
    execute format('create policy bvek_ler on public.%I for select to authenticated using (public.bvek_pode(''{administrador}''::text[]))', t);
    execute format('create policy bvek_alterar on public.%I for update to authenticated using (public.bvek_pode(''{administrador}''::text[])) with check (public.bvek_pode(''{administrador}''::text[]))', t);
    if t <> 'iso_config' then
      execute format('create policy bvek_inserir on public.%I for insert to authenticated with check (public.bvek_pode(''{administrador}''::text[]))', t);
      execute format('create policy bvek_apagar on public.%I for delete to authenticated using (public.bvek_pode(''{administrador}''::text[]))', t);
    end if;
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;
-- a senha da busca automática não vai para o navegador
revoke select (token_cron) on public.iso_config from authenticated;
revoke select on public.iso_config from authenticated;
grant select (id, termos, localidades, dias_busca, ultima_busca, ultimo_resultado, atualizado_em) on public.iso_config to authenticated;

-- lista inicial (ponto de partida: confira se se aplica e se o texto ainda é o vigente)
insert into public.iso_requisitos (norma, tipo, esfera, titulo, orgao, ementa, link, origem, criado_por)
select v.norma, v.tipo, v.esfera, v.titulo, v.orgao, v.ementa, v.link, 'lista_inicial', 'migração v56'
  from (values
  ('ambas','norma_tecnica','outro','ABNT NBR ISO 9001:2015 (com Emenda 1:2024 — mudanças climáticas)','ABNT / ISO','Sistema de gestão da qualidade — requisitos. A ISO está revisando a norma: acompanhar a versão nova e o prazo de transição.', null),
  ('ambas','norma_tecnica','outro','ABNT NBR ISO 14001:2015 (com Emenda 1:2024 — mudanças climáticas)','ABNT / ISO','Sistema de gestão ambiental — requisitos. A ISO está revisando a norma: acompanhar a versão nova e o prazo de transição.', null),
  ('14001','lei','federal','Lei 6.938/1981 — Política Nacional do Meio Ambiente','Congresso Nacional','Objetivos e instrumentos da política ambiental; licenciamento; responsabilidade pelo dano ambiental.','https://www.planalto.gov.br/ccivil_03/leis/l6938.htm'),
  ('14001','lei','federal','Lei 9.605/1998 — Crimes ambientais','Congresso Nacional','Sanções penais e administrativas por condutas lesivas ao meio ambiente.','https://www.planalto.gov.br/ccivil_03/leis/l9605.htm'),
  ('14001','lei','federal','Lei 12.305/2010 — Política Nacional de Resíduos Sólidos','Congresso Nacional','Plano de gerenciamento de resíduos, responsabilidade compartilhada, logística reversa.','https://www.planalto.gov.br/ccivil_03/_ato2007-2010/2010/lei/l12305.htm'),
  ('14001','decreto','federal','Decreto 10.936/2022 — Regulamenta a Política Nacional de Resíduos Sólidos','Presidência da República','Regras do plano de gerenciamento, MTR e logística reversa.','https://www.planalto.gov.br/ccivil_03/_ato2019-2022/2022/decreto/d10936.htm'),
  ('14001','lei','federal','Lei 12.651/2012 — Código Florestal','Congresso Nacional','Proteção da vegetação nativa, APP e supressão de vegetação (paisagismo, poda e manejo).','https://www.planalto.gov.br/ccivil_03/_ato2011-2014/2012/lei/l12651.htm'),
  ('14001','lei','federal','Lei Complementar 140/2011 — Competências no licenciamento','Congresso Nacional','Quem licencia (União, estado ou município) cada atividade.','https://www.planalto.gov.br/ccivil_03/leis/lcp/lcp140.htm'),
  ('14001','resolucao','federal','Resolução CONAMA 237/1997 — Licenciamento ambiental','CONAMA','Procedimentos e atividades sujeitas a licenciamento.', null),
  ('14001','resolucao','federal','Resolução CONAMA 307/2002 — Resíduos da construção civil','CONAMA','Classificação (A, B, C, D), triagem e destinação dos resíduos de obra.', null),
  ('14001','resolucao','federal','Resolução CONAMA 362/2005 — Óleo lubrificante usado','CONAMA','Recolhimento e destinação do óleo usado de máquinas e veículos.', null),
  ('14001','lei','estadual','Lei Estadual RJ 4.191/2003 — Política Estadual de Resíduos Sólidos','ALERJ','Gestão de resíduos no estado do Rio de Janeiro.', null),
  ('14001','decreto','estadual','Decreto Estadual RJ 46.890/2019 — Sistema Estadual de Licenciamento (SELCA)','Governo do RJ / INEA','Licenciamento e demais procedimentos de controle ambiental no RJ.', null),
  ('14001','lei','municipal','Lei Municipal Rio 4.969/2008 — Gestão de resíduos sólidos no município do Rio','Câmara Municipal do Rio','Gestão integrada de resíduos e responsabilidades do gerador (grandes geradores, entulho).', null),
  ('14001','outro','municipal','Autorizações de poda/remoção de árvores no Rio (Fundação Parques e Jardins / SMAC)','Prefeitura do Rio','Autorização prévia para poda, remoção e transplante de árvores em área pública e privada.', null),
  ('9001','lei','federal','Lei 8.078/1990 — Código de Defesa do Consumidor','Congresso Nacional','Qualidade do serviço, informação clara, garantia e responsabilidade do prestador.','https://www.planalto.gov.br/ccivil_03/leis/l8078compilado.htm'),
  ('9001','lei','federal','Lei 5.194/1966 — Exercício da engenharia (CREA) e ART','Congresso Nacional / CONFEA','Responsável técnico e Anotação de Responsabilidade Técnica nos serviços de engenharia.','https://www.planalto.gov.br/ccivil_03/leis/l5194.htm'),
  ('9001','lei','federal','Lei 12.378/2010 — Arquitetura e urbanismo (CAU) e RRT','Congresso Nacional / CAU','Registro de Responsabilidade Técnica nos serviços de arquitetura; registro da empresa no CAU.','https://www.planalto.gov.br/ccivil_03/_ato2007-2010/2010/lei/l12378.htm'),
  ('9001','norma_tecnica','outro','ABNT NBR 16280 — Reforma em edificações','ABNT','Plano de reforma, responsável técnico e comunicação ao síndico antes de obras em edifícios.', null),
  ('9001','norma_tecnica','outro','ABNT NBR 5674 — Manutenção de edificações','ABNT','Sistema de gestão da manutenção predial (contratos de manutenção).', null),
  ('9001','nr','federal','NR-18 — Segurança e saúde na indústria da construção','Ministério do Trabalho','PGR da obra, áreas de vivência, proteção coletiva.', 'https://www.gov.br/trabalho-e-emprego/pt-br/assuntos/inspecao-do-trabalho/seguranca-e-saude-no-trabalho/ctpp-nrs/normas-regulamentadoras-nrs'),
  ('9001','nr','federal','NR-35 — Trabalho em altura','Ministério do Trabalho','Treinamento, análise de risco e permissão de trabalho acima de 2 m.', 'https://www.gov.br/trabalho-e-emprego/pt-br/assuntos/inspecao-do-trabalho/seguranca-e-saude-no-trabalho/ctpp-nrs/normas-regulamentadoras-nrs'),
  ('9001','nr','federal','NR-06 — Equipamento de proteção individual (EPI)','Ministério do Trabalho','Fornecimento, CA, treinamento e registro de entrega de EPI.', 'https://www.gov.br/trabalho-e-emprego/pt-br/assuntos/inspecao-do-trabalho/seguranca-e-saude-no-trabalho/ctpp-nrs/normas-regulamentadoras-nrs'),
  ('9001','nr','federal','NR-01 — Disposições gerais e gerenciamento de riscos (PGR)','Ministério do Trabalho','Inventário de riscos e plano de ação; inclui riscos psicossociais.', 'https://www.gov.br/trabalho-e-emprego/pt-br/assuntos/inspecao-do-trabalho/seguranca-e-saude-no-trabalho/ctpp-nrs/normas-regulamentadoras-nrs'),
  ('ambas','lei','federal','Lei 13.709/2018 — LGPD (proteção de dados pessoais)','Congresso Nacional / ANPD','Dados de clientes, funcionários e candidatos: finalidade, consentimento, segurança.','https://www.planalto.gov.br/ccivil_03/_ato2015-2018/2018/lei/l13709.htm')
  ) as v(norma, tipo, esfera, titulo, orgao, ementa, link)
 where not exists (select 1 from public.iso_requisitos r where lower(r.titulo) = lower(v.titulo));

-- busca automática toda segunda às 7h17 (Brasília) — só se o Supabase tiver pg_cron e pg_net
do $$
begin
  begin
    create extension if not exists pg_net;
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron/pg_net indisponível: use o botão "Buscar agora" (%).', sqlerrm;
    return;
  end;
  if exists (select 1 from cron.job where jobname = 'bvek-normas-iso') then
    perform cron.unschedule('bvek-normas-iso');
  end if;
  perform cron.schedule('bvek-normas-iso', '17 10 * * 1', $job$
    select net.http_post(
      url     := 'https://smusenaszgkqkjjwblyi.supabase.co/functions/v1/normas-iso',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        -- chave pública (a mesma do index.html); a permissão real é o token_cron abaixo
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNtdXNlbmFzemdrcWtqandibHlpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI0MTIwNTMsImV4cCI6MjA5Nzk4ODA1M30.IU1Z9ddIUpktjHvWqrSZaEWuo4gbmZfrfmYJ_NoXbWs',
        'x-cron-token', (select token_cron from public.iso_config where id = 1)),
      body    := '{"acao":"buscar","automatico":true}'::jsonb,
      timeout_milliseconds := 60000);
  $job$);
end $$;

-- 4. CURRÍCULOS: CERTIDÕES ENTREGUES PELO CANDIDATO ----------------------------------
alter table public.curriculos add column if not exists certidoes_exigidas boolean not null default false;
alter table public.curriculos add column if not exists certidoes_justificativa text;   -- por que a função exige
alter table public.curriculos add column if not exists certidoes_consentimento boolean not null default false;
alter table public.curriculos add column if not exists certidoes jsonb not null default '[]'::jsonb;
-- certidoes = [{tipo, situacao: pedida|nada_consta|com_registro|nao_se_aplica, data, arquivo, arquivo_nome, obs}]

-- Conferência
select 'mensalidades' as o_que, count(*)::text as quantos from public.mensalidades
union all select 'contas e acessos', count(*)::text from public.contas_acessos
union all select 'requisitos ISO (lista inicial)', count(*)::text from public.iso_requisitos
union all select 'palavras da busca ISO', coalesce(array_length(termos, 1), 0)::text from public.iso_config where id = 1
union all select 'agendador pg_cron instalado (busca toda segunda)', case when exists (select 1 from pg_extension where extname = 'pg_cron')
            then 'sim' else 'não (use o botão Buscar agora)' end
union all select 'colunas de certidões em currículos', count(*)::text from information_schema.columns
            where table_schema = 'public' and table_name = 'curriculos' and column_name like 'certidoes%';
