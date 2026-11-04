-- =====================================================================
-- CRM Grupo BVEK — migração v45 (04/11/2026)
-- 1. Cronograma liberado para TODOS os perfis do escritório
--    (Administrador, Comercial, Administrativo, Contabilidade e Consulta):
--    todos veem, criam e alteram alocações. Só o Administrador apaga
--    (os outros cancelam). O perfil Funcionário (login por CPF) continua fora.
-- 2. Agenda do escritório: tabela "agenda_escritorio", espelho do
--    calendário da caixa agenda@bvek.com.br no Microsoft 365.
--    Eventos do escritório NÃO entram na folha (são separados do cronograma).
-- 3. Função bvek_pessoas_agenda(): nome e e-mail de quem usa o CRM, para
--    convidar para os eventos do escritório (sem nenhum outro dado).
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada.
-- =====================================================================

-- 1. CRONOGRAMA PARA TODOS ------------------------------------------------
drop policy if exists bvek_ler     on public.cronograma;
drop policy if exists bvek_inserir on public.cronograma;
drop policy if exists bvek_alterar on public.cronograma;
drop policy if exists bvek_apagar  on public.cronograma;
create policy bvek_ler     on public.cronograma for select to authenticated
  using (public.bvek_pode('{administrador,comercial,administrativo,contabilidade,consulta}'::text[]));
create policy bvek_inserir on public.cronograma for insert to authenticated
  with check (public.bvek_pode('{administrador,comercial,administrativo,contabilidade,consulta}'::text[]));
create policy bvek_alterar on public.cronograma for update to authenticated
  using (public.bvek_pode('{administrador,comercial,administrativo,contabilidade,consulta}'::text[]))
  with check (public.bvek_pode('{administrador,comercial,administrativo,contabilidade,consulta}'::text[]));
create policy bvek_apagar  on public.cronograma for delete to authenticated
  using (public.bvek_pode('{administrador}'::text[]));

-- 2. AGENDA DO ESCRITÓRIO ---------------------------------------------------
create table if not exists public.agenda_escritorio (
  id                  uuid primary key default gen_random_uuid(),
  titulo              text not null,
  inicio              timestamptz not null,
  fim                 timestamptz not null,
  dia_inteiro         boolean not null default false,
  local               text,
  descricao           text,
  organizador         text,              -- nome de quem marcou (no Outlook ou no CRM)
  organizador_email   text,
  participantes       jsonb not null default '[]'::jsonb,  -- [{nome, email}]
  situacao            text not null default 'ativo',       -- ativo | cancelado
  origem              text not null default 'crm',         -- crm (criado no CRM) | outlook (convite recebido)
  outlook_id          text,
  outlook_icaluid     text,
  outlook_alterado_em timestamptz,
  outlook_sync_em     timestamptz,
  outlook_erro        text,
  criado_por          text,
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now()
);
alter table public.agenda_escritorio drop constraint if exists agenda_esc_datas_chk;
alter table public.agenda_escritorio add constraint agenda_esc_datas_chk check (fim >= inicio);
alter table public.agenda_escritorio drop constraint if exists agenda_esc_situacao_chk;
alter table public.agenda_escritorio add constraint agenda_esc_situacao_chk check (situacao in ('ativo','cancelado'));
alter table public.agenda_escritorio drop constraint if exists agenda_esc_origem_chk;
alter table public.agenda_escritorio add constraint agenda_esc_origem_chk check (origem in ('crm','outlook'));
create unique index if not exists agenda_esc_outlook_idx on public.agenda_escritorio (outlook_id) where outlook_id is not null;
create index if not exists agenda_esc_datas_idx on public.agenda_escritorio (inicio, fim);

alter table public.agenda_escritorio enable row level security;
drop policy if exists bvek_ler     on public.agenda_escritorio;
drop policy if exists bvek_inserir on public.agenda_escritorio;
drop policy if exists bvek_alterar on public.agenda_escritorio;
drop policy if exists bvek_apagar  on public.agenda_escritorio;
create policy bvek_ler     on public.agenda_escritorio for select to authenticated
  using (public.bvek_pode('{administrador,comercial,administrativo,contabilidade,consulta}'::text[]));
create policy bvek_inserir on public.agenda_escritorio for insert to authenticated
  with check (public.bvek_pode('{administrador,comercial,administrativo,contabilidade,consulta}'::text[]));
create policy bvek_alterar on public.agenda_escritorio for update to authenticated
  using (public.bvek_pode('{administrador,comercial,administrativo,contabilidade,consulta}'::text[]))
  with check (public.bvek_pode('{administrador,comercial,administrativo,contabilidade,consulta}'::text[]));
create policy bvek_apagar  on public.agenda_escritorio for delete to authenticated
  using (public.bvek_pode('{administrador}'::text[]));
grant select, insert, update, delete on public.agenda_escritorio to authenticated;
revoke all on public.agenda_escritorio from anon;

-- 3. PESSOAS PARA CONVIDAR (só nome e e-mail dos logins do escritório) -----
create or replace function public.bvek_pessoas_agenda()
returns table (nome text, email text)
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim(p.nome), ''), split_part(p.email, '@', 1)) as nome, lower(trim(p.email)) as email
    from public.perfis p
   where public.bvek_ativo()
     and p.ativo is not false
     and p.perfil in ('administrador','comercial','administrativo','contabilidade','consulta')
     and p.email is not null
     and p.email not ilike '%@funcionario.bvek.com.br'
   order by 1;
$$;
revoke all on function public.bvek_pessoas_agenda() from public, anon;
grant execute on function public.bvek_pessoas_agenda() to authenticated;

-- Conferência: a 1ª e a 2ª linha devem listar os 5 perfis;
-- a 3ª mostra quantos eventos do escritório já existem (começa em 0).
select 'cronograma — quem lê' as item, qual as resultado
  from pg_policies where schemaname = 'public' and tablename = 'cronograma' and policyname = 'bvek_ler'
union all
select 'agenda do escritório — quem lê', qual
  from pg_policies where schemaname = 'public' and tablename = 'agenda_escritorio' and policyname = 'bvek_ler'
union all
select 'eventos do escritório cadastrados', count(*)::text from public.agenda_escritorio
union all
select 'pessoas para convidar', count(*)::text from public.perfis
 where ativo is not false and perfil in ('administrador','comercial','administrativo','contabilidade','consulta')
   and email is not null and email not ilike '%@funcionario.bvek.com.br';
