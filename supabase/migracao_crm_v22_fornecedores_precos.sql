-- =====================================================================
-- CRM Grupo BVEK — migração v22 (28/10/2026)
-- Fornecedores, materiais e preços de referência (para as cotações)
--
--  1. fornecedores: cadastro com as categorias que cada um atende
--     (limpeza, poda, plantio, construção, demolição, pintura…)
--  2. materiais: catálogo de materiais/serviços com categoria e unidade
--  3. precos_fornecedor: cada preço cotado ou pago (fornecedor, data,
--     quantidade). O CRM calcula sozinho a média, o menor e o último preço
--     de cada material — e a composição de preço das propostas usa isso.
--
-- Quem pode cadastrar/editar: Administrador e Comercial.
-- Quem pode ver: Administrador, Comercial, Administrativo e Consulta.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

create table if not exists public.fornecedores (
  id                   uuid primary key default gen_random_uuid(),
  nome                 text not null,
  razao_social         text,
  cnpj                 text,
  contato              text,
  telefone             text,
  whatsapp             text,
  email                text,
  site                 text,
  cidade               text,
  categorias           text[] not null default '{}',
  avaliacao            integer,
  prazo_entrega        text,
  condicoes_pagamento  text,
  observacoes          text,
  ativo                boolean not null default true,
  criado_por           text,
  criado_em            timestamptz not null default now(),
  atualizado_em        timestamptz not null default now()
);
alter table public.fornecedores drop constraint if exists fornecedores_avaliacao_chk;
alter table public.fornecedores add constraint fornecedores_avaliacao_chk check (avaliacao is null or avaliacao between 1 and 5);
create unique index if not exists fornecedores_nome_unq on public.fornecedores (lower(nome));

create table if not exists public.materiais (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null,
  categoria    text,
  unidade      text,                      -- un, m², m³, kg, saco, h, diária…
  observacoes  text,
  ativo        boolean not null default true,
  criado_em    timestamptz not null default now()
);
create unique index if not exists materiais_nome_unq on public.materiais (lower(nome), coalesce(lower(unidade), ''));

create table if not exists public.precos_fornecedor (
  id              uuid primary key default gen_random_uuid(),
  material_id     uuid not null references public.materiais(id) on delete cascade,
  fornecedor_id   uuid references public.fornecedores(id) on delete set null,
  preco           numeric(14,4) not null,
  unidade         text,
  quantidade      numeric(14,3),
  data            date not null default ((now() at time zone 'America/Sao_Paulo')::date),
  origem          text not null default 'cotacao',   -- cotacao · compra · manual
  frete_incluso   boolean,
  observacoes     text,
  criado_por      text,
  criado_em       timestamptz not null default now()
);
alter table public.precos_fornecedor drop constraint if exists precos_fornecedor_origem_chk;
alter table public.precos_fornecedor add constraint precos_fornecedor_origem_chk check (origem in ('cotacao','compra','manual'));
create index if not exists precos_fornecedor_material_idx on public.precos_fornecedor (material_id, data desc);

-- ---------------------------------------------------------------------
-- SEGURANÇA (RLS)
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select * from (values
    ('fornecedores',      '{administrador,comercial,administrativo,consulta}', '{administrador,comercial}', '{administrador,comercial}', '{administrador}'),
    ('materiais',         '{administrador,comercial,administrativo,consulta}', '{administrador,comercial}', '{administrador,comercial}', '{administrador}'),
    ('precos_fornecedor', '{administrador,comercial,administrativo,consulta}', '{administrador,comercial}', '{administrador,comercial}', '{administrador,comercial}')
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

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from pg_policies where schemaname = 'public'
         and tablename in ('fornecedores','materiais','precos_fornecedor')) as regras_deve_ser_12,
       (select count(*) from public.fornecedores)                          as fornecedores_cadastrados,
       (select count(*) from public.materiais)                             as materiais_cadastrados;
