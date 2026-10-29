-- =====================================================================
-- CRM Grupo BVEK — migração v30 (29/10/2026)
--
--  1. RH → Comunicação interna: tabela "comunicados" (registro de cada
--     comunicado, para quem foi por e-mail e quando foi para o grupo
--     do WhatsApp) + coluna "email" na ficha do funcionário.
--     O funcionário (login por CPF) vê os comunicados enviados.
--  2. Inventário de materiais e equipamentos ("inventario_itens") e
--     ligação dos itens com a proposta / ordem de serviço ("inventario_os").
--  3. Assinatura eletrônica do ponto: o funcionário confere o ponto do
--     mês no login dele e assina (ou registra discordância).
--     Fica guardado: assinatura desenhada, nome digitado, data/hora,
--     IP, navegador e uma cópia do ponto com código de conferência (hash).
--  4. Proposta: tira a Michelle das assinaturas salvas em ⚙️ Parâmetros.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. COMUNICAÇÃO INTERNA
-- ---------------------------------------------------------------------
alter table public.funcionarios add column if not exists email text;

create table if not exists public.comunicados (
  id                uuid primary key default gen_random_uuid(),
  titulo            text not null,
  mensagem          text not null,
  empresa_id        uuid references public.empresas(id) on delete set null,  -- vazio = todas
  anexo             text,          -- caminho no bucket "rh" (pasta comunicados/)
  anexo_nome        text,
  situacao          text not null default 'rascunho',
  email_total       integer not null default 0,
  email_ok          integer not null default 0,
  email_resultado   jsonb,         -- [{nome, email, ok, erro}]
  email_enviado_em  timestamptz,
  email_enviado_por text,
  whatsapp_em       timestamptz,
  whatsapp_por      text,
  criado_por        text,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now()
);
alter table public.comunicados drop constraint if exists comunicados_situacao_chk;
alter table public.comunicados add constraint comunicados_situacao_chk
  check (situacao in ('rascunho','enviado','parcial','erro'));
create index if not exists comunicados_criado_idx on public.comunicados (criado_em desc);

-- ---------------------------------------------------------------------
-- 2. INVENTÁRIO
-- ---------------------------------------------------------------------
create sequence if not exists public.inventario_codigo_seq;

create table if not exists public.inventario_itens (
  id                 uuid primary key default gen_random_uuid(),
  codigo             text unique default ('INV-' || lpad(nextval('public.inventario_codigo_seq')::text, 4, '0')),
  nome               text not null,
  tipo               text not null default 'equipamento',
  categoria          text,
  marca_modelo       text,
  numero_serie       text,
  unidade            text default 'un',
  quantidade         numeric(14,2) not null default 0,
  quantidade_minima  numeric(14,2),
  localizacao        text,
  estado             text not null default 'bom',
  empresa_id         uuid references public.empresas(id) on delete set null,
  valor_unitario     numeric(14,2),
  data_aquisicao     date,
  observacoes        text,
  ativo              boolean not null default true,
  criado_por         text,
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now()
);
alter table public.inventario_itens drop constraint if exists inventario_tipo_chk;
alter table public.inventario_itens add constraint inventario_tipo_chk
  check (tipo in ('material','equipamento','ferramenta','epi','veiculo','outro'));
alter table public.inventario_itens drop constraint if exists inventario_estado_chk;
alter table public.inventario_itens add constraint inventario_estado_chk
  check (estado in ('novo','bom','regular','manutencao','inservivel'));
alter table public.inventario_itens drop constraint if exists inventario_qtd_chk;
alter table public.inventario_itens add constraint inventario_qtd_chk check (quantidade >= 0);

-- itens do inventário separados para a proposta / ordem de serviço
create table if not exists public.inventario_os (
  id          uuid primary key default gen_random_uuid(),
  card_id     uuid not null references public.cards(id) on delete cascade,
  item_id     uuid not null references public.inventario_itens(id) on delete cascade,
  quantidade  numeric(14,2) not null default 1,
  observacao  text,
  criado_por  text,
  criado_em   timestamptz not null default now(),
  unique (card_id, item_id)
);
alter table public.inventario_os drop constraint if exists inventario_os_qtd_chk;
alter table public.inventario_os add constraint inventario_os_qtd_chk check (quantidade > 0);
create index if not exists inventario_os_item_idx on public.inventario_os (item_id);

-- ---------------------------------------------------------------------
-- 3. ASSINATURA ELETRÔNICA DO PONTO
-- ---------------------------------------------------------------------
create table if not exists public.ponto_assinaturas (
  id              uuid primary key default gen_random_uuid(),
  funcionario_id  uuid not null references public.funcionarios(id) on delete cascade,
  competencia     date not null,         -- 1º dia do mês (período de 26 a 25)
  periodo_inicio  date,
  periodo_fim     date,
  concorda        boolean not null default true,
  observacao      text,                  -- o que está errado, quando não concorda
  nome_digitado   text,
  assinatura      text,                  -- imagem PNG (data:image/png;base64,...)
  dados           jsonb,                 -- cópia do ponto que o funcionário viu
  hash            text,                  -- SHA-256 da cópia (código de conferência)
  ip              text,
  user_agent      text,
  user_id         uuid,
  assinado_em     timestamptz not null default now()
);
create index if not exists ponto_assinaturas_comp_idx on public.ponto_assinaturas (competencia, funcionario_id);

-- ---------------------------------------------------------------------
-- 4. SEGURANÇA (RLS)
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select * from (values
    ('comunicados',       '{administrador,administrativo}',                     '{administrador,administrativo}',          '{administrador,administrativo}',          '{administrador}'),
    ('inventario_itens',  '{administrador,comercial,administrativo,consulta}',  '{administrador,comercial,administrativo}', '{administrador,comercial,administrativo}', '{administrador}'),
    ('inventario_os',     '{administrador,comercial,administrativo,consulta}',  '{administrador,comercial,administrativo}', '{administrador,comercial,administrativo}', '{administrador,comercial,administrativo}'),
    -- assinatura do ponto: só entra pela função bvek_assinar_ponto (nunca é alterada)
    ('ponto_assinaturas', '{administrador,administrativo,contabilidade}',       '{}',                                      '{}',                                      '{administrador}')
  ) as t(tabela, ler, ins, upd, del)
  loop
    execute format('alter table public.%I enable row level security', r.tabela);
    execute format('drop policy if exists bvek_ler on public.%I', r.tabela);
    execute format('drop policy if exists bvek_inserir on public.%I', r.tabela);
    execute format('drop policy if exists bvek_alterar on public.%I', r.tabela);
    execute format('drop policy if exists bvek_apagar on public.%I', r.tabela);
    execute format('create policy bvek_ler on public.%I for select to authenticated using (public.bvek_pode(%L::text[]))', r.tabela, r.ler);
    execute format('create policy bvek_inserir on public.%I for insert to authenticated with check (public.bvek_pode(%L::text[]))', r.tabela, r.ins);
    execute format('create policy bvek_alterar on public.%I for update to authenticated using (public.bvek_pode(%L::text[])) with check (public.bvek_pode(%L::text[]))', r.tabela, r.upd, r.upd);
    execute format('create policy bvek_apagar on public.%I for delete to authenticated using (public.bvek_pode(%L::text[]))', r.tabela, r.del);
    execute format('grant select, insert, update, delete on public.%I to authenticated', r.tabela);
  end loop;
end $$;
grant usage, select on sequence public.inventario_codigo_seq to authenticated;

-- ---------------------------------------------------------------------
-- 5. FUNÇÕES DO LOGIN DO FUNCIONÁRIO (CPF)
-- ---------------------------------------------------------------------
-- funcionário do CPF do login
create or replace function public.bvek_meu_funcionario_id() returns uuid
language sql stable security definer set search_path = public as $$
  select f.id from public.funcionarios f
   where public.bvek_meu_cpf() is not null
     and regexp_replace(coalesce(f.cpf, ''), '\D', '', 'g') = public.bvek_meu_cpf()
   order by f.ativo desc, f.criado_em desc
   limit 1
$$;

-- assina (ou registra discordância) o ponto do mês
create or replace function public.bvek_assinar_ponto(
  p_competencia date, p_inicio date, p_fim date, p_concorda boolean, p_observacao text,
  p_nome text, p_assinatura text, p_dados jsonb, p_user_agent text)
returns table (id uuid, hash text, assinado_em timestamptz)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_func uuid := public.bvek_meu_funcionario_id();
  v_ip   text;
  v_hash text;
begin
  if v_func is null then raise exception 'Seu CPF não está ligado a um cadastro de funcionário. Fale com o RH.'; end if;
  if coalesce(trim(p_nome), '') = '' then raise exception 'Digite o seu nome completo para assinar.'; end if;
  if coalesce(p_assinatura, '') !~ '^data:image/png;base64,' or length(p_assinatura) > 400000 then
    raise exception 'Assinatura inválida. Desenhe de novo.';
  end if;
  if not p_concorda and coalesce(trim(p_observacao), '') = '' then
    raise exception 'Explique o que está errado no ponto.';
  end if;
  begin
    v_ip := split_part(coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for', ''), ',', 1);
  exception when others then v_ip := null; end;
  v_hash := encode(sha256(convert_to(coalesce(p_dados::text, ''), 'UTF8')), 'hex');
  return query
  insert into public.ponto_assinaturas as a
    (funcionario_id, competencia, periodo_inicio, periodo_fim, concorda, observacao, nome_digitado,
     assinatura, dados, hash, ip, user_agent, user_id)
  values (v_func, date_trunc('month', p_competencia)::date, p_inicio, p_fim, p_concorda,
          nullif(trim(p_observacao), ''), upper(trim(p_nome)), p_assinatura, p_dados, v_hash,
          nullif(v_ip, ''), left(p_user_agent, 300), auth.uid())
  returning a.id, a.hash, a.assinado_em;
end $$;

-- assinaturas do próprio funcionário (a mais recente de cada mês vale)
create or replace function public.bvek_minhas_assinaturas_ponto()
returns table (competencia date, concorda boolean, observacao text, assinado_em timestamptz, hash text)
language sql stable security definer set search_path = public as $$
  select a.competencia, a.concorda, a.observacao, a.assinado_em, a.hash
    from public.ponto_assinaturas a
   where a.funcionario_id = public.bvek_meu_funcionario_id()
   order by a.assinado_em desc
$$;

-- comunicados enviados que valem para o funcionário do login
create or replace function public.bvek_meus_comunicados()
returns table (id uuid, titulo text, mensagem text, enviado_em timestamptz)
language sql stable security definer set search_path = public as $$
  select c.id, c.titulo, c.mensagem, coalesce(c.email_enviado_em, c.whatsapp_em, c.criado_em)
    from public.comunicados c
   where public.bvek_meu_funcionario_id() is not null
     and (c.email_enviado_em is not null or c.whatsapp_em is not null)
     and (c.empresa_id is null or c.empresa_id = (select f.empresa_id from public.funcionarios f where f.id = public.bvek_meu_funcionario_id()))
   order by 4 desc
   limit 50
$$;

revoke all on function public.bvek_meu_funcionario_id()                                             from public, anon;
revoke all on function public.bvek_assinar_ponto(date, date, date, boolean, text, text, text, jsonb, text) from public, anon;
revoke all on function public.bvek_minhas_assinaturas_ponto()                                       from public, anon;
revoke all on function public.bvek_meus_comunicados()                                               from public, anon;
grant execute on function public.bvek_meu_funcionario_id()                                             to authenticated;
grant execute on function public.bvek_assinar_ponto(date, date, date, boolean, text, text, text, jsonb, text) to authenticated;
grant execute on function public.bvek_minhas_assinaturas_ponto()                                       to authenticated;
grant execute on function public.bvek_meus_comunicados()                                               to authenticated;

-- ---------------------------------------------------------------------
-- 6. PROPOSTA: tira a Michelle das assinaturas salvas em ⚙️ Parâmetros
-- ---------------------------------------------------------------------
update public.precificacao_config
   set dados = jsonb_set(dados, '{proposta,assinaturas}',
         to_jsonb(trim(both E'\n' from regexp_replace(dados->'proposta'->>'assinaturas', E'\\n?[^\\n]*Mich[^\\n]*', '', 'gi')))),
       atualizado_em = now()
 where id = 1
   and dados->'proposta'->>'assinaturas' ~* 'Mich';

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'funcionarios' and column_name = 'email')        as coluna_email_deve_ser_1,
       (select count(*) from information_schema.tables
         where table_schema = 'public'
           and table_name in ('comunicados','inventario_itens','inventario_os','ponto_assinaturas'))     as tabelas_novas_deve_ser_4,
       (select count(*) from pg_policies where schemaname = 'public'
         and tablename in ('comunicados','inventario_itens','inventario_os','ponto_assinaturas'))        as regras_deve_ser_16,
       (select count(*) from public.precificacao_config
         where dados->'proposta'->>'assinaturas' ~* 'Mich')                                              as michelle_deve_ser_0;
