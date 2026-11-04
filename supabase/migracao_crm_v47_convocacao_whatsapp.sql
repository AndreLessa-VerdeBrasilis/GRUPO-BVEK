-- =====================================================================
-- CRM Grupo BVEK — migração v47 (04/11/2026)
-- Convocação pelo Cronograma: aviso no WhatsApp e no e-mail
-- ---------------------------------------------------------------------
-- 1. Ficha do funcionário: novo campo "celular" (WhatsApp).
-- 2. Cronograma: horário de início e de fim da alocação.
-- 3. Tabela "cronograma_avisos": cada aviso mandado a cada funcionário
--    (convocação, alteração ou cancelamento; WhatsApp ou e-mail), com o
--    resultado. Quem grava é só a função "convocacao" (servidor).
--    O número/e-mail usado só aparece para Administrador, Administrativo
--    e Contabilidade; os outros perfis veem só se foi e quando foi.
-- 4. WhatsApp (Meta): nome do modelo aprovado para a convocação.
-- 5. bvek_funcionarios_basico passa a dizer se o funcionário tem celular
--    (sem mostrar o número) — para o ícone 📱 no Cronograma.
--
-- Antes de testar: publique a função supabase/functions/convocacao
-- (Edge Functions → Deploy new function → nome "convocacao").
-- Pode rodar mais de uma vez. Nada é apagado.
-- =====================================================================

-- 1. CELULAR NA FICHA ----------------------------------------------------
alter table public.funcionarios add column if not exists celular text;  -- só números, com DDD (ex.: 21999999999)

-- 2. HORÁRIO NA ALOCAÇÃO ---------------------------------------------------
alter table public.cronograma add column if not exists hora_inicio time;
alter table public.cronograma add column if not exists hora_fim    time;

-- 3. AVISOS DA CONVOCAÇÃO ----------------------------------------------------
create table if not exists public.cronograma_avisos (
  id             uuid primary key default gen_random_uuid(),
  cronograma_id  uuid not null references public.cronograma(id) on delete cascade,
  funcionario_id uuid references public.funcionarios(id) on delete set null,
  tipo           text not null,          -- convocacao | alteracao | cancelamento
  canal          text not null,          -- whatsapp | email
  destino        text,                   -- número ou e-mail usado
  ok             boolean not null default false,
  erro           text,
  assinatura     text,                   -- resumo do que foi avisado (para saber se mudou depois)
  enviado_em     timestamptz not null default now(),
  enviado_por    text
);
alter table public.cronograma_avisos drop constraint if exists cronograma_avisos_tipo_chk;
alter table public.cronograma_avisos add constraint cronograma_avisos_tipo_chk check (tipo in ('convocacao','alteracao','cancelamento'));
alter table public.cronograma_avisos drop constraint if exists cronograma_avisos_canal_chk;
alter table public.cronograma_avisos add constraint cronograma_avisos_canal_chk check (canal in ('whatsapp','email'));
create index if not exists cronograma_avisos_crono_idx on public.cronograma_avisos (cronograma_id, funcionario_id, enviado_em desc);

alter table public.cronograma_avisos enable row level security;
drop policy if exists bvek_ler     on public.cronograma_avisos;
drop policy if exists bvek_inserir on public.cronograma_avisos;
drop policy if exists bvek_alterar on public.cronograma_avisos;
drop policy if exists bvek_apagar  on public.cronograma_avisos;
create policy bvek_ler on public.cronograma_avisos for select to authenticated
  using (public.bvek_pode('{administrador,administrativo,contabilidade}'::text[]));
-- sem política de inserir/alterar/apagar: só a função "convocacao" (servidor) grava
grant select on public.cronograma_avisos to authenticated;
revoke all on public.cronograma_avisos from anon;

-- resumo para TODOS os perfis do cronograma (sem número nem e-mail)
create or replace function public.bvek_cronograma_avisos(p_ids uuid[])
returns table (cronograma_id uuid, funcionario_id uuid, tipo text, canal text, ok boolean, erro text, enviado_em timestamptz, enviado_por text)
language sql stable security definer set search_path = public as $$
  select a.cronograma_id, a.funcionario_id, a.tipo, a.canal, a.ok, a.erro, a.enviado_em, a.enviado_por
    from public.cronograma_avisos a
   where a.cronograma_id = any(p_ids)
     and public.bvek_pode('{administrador,comercial,administrativo,contabilidade}'::text[])
   order by a.enviado_em desc
$$;
revoke all on function public.bvek_cronograma_avisos(uuid[]) from public, anon;
grant execute on function public.bvek_cronograma_avisos(uuid[]) to authenticated;

-- 4. MODELO DA META PARA A CONVOCAÇÃO -----------------------------------------
alter table public.whatsapp_config add column if not exists meta_modelo_convocacao text;

-- 5. FUNCIONÁRIOS (dados básicos) + "tem celular" ------------------------------
drop function if exists public.bvek_funcionarios_basico();
create function public.bvek_funcionarios_basico()
returns table (id uuid, nome text, cargo text, empresa_id uuid, ativo boolean, tem_email boolean, tem_celular boolean)
language sql stable security definer set search_path = public as $$
  select f.id, f.nome, f.cargo, f.empresa_id, f.ativo,
         (coalesce(trim(f.email), '') like '%@%'),
         (length(regexp_replace(coalesce(f.celular, ''), '\D', '', 'g')) >= 10)
    from public.funcionarios f
   where public.bvek_ativo()
   order by f.nome
$$;
revoke all on function public.bvek_funcionarios_basico() from public, anon;
grant execute on function public.bvek_funcionarios_basico() to authenticated;

-- ---------------------------------------------------------------------
-- Conferência: as 4 primeiras linhas devem dizer "ok";
-- a última mostra quantos funcionários ativos já têm celular na ficha.
-- ---------------------------------------------------------------------
select 'coluna celular na ficha' as item,
       case when exists (select 1 from information_schema.columns where table_schema='public' and table_name='funcionarios' and column_name='celular') then 'ok' else 'FALTOU' end as resultado
union all
select 'horário no cronograma',
       case when (select count(*) from information_schema.columns where table_schema='public' and table_name='cronograma' and column_name in ('hora_inicio','hora_fim')) = 2 then 'ok' else 'FALTOU' end
union all
select 'tabela de avisos da convocação',
       case when to_regclass('public.cronograma_avisos') is not null then 'ok' else 'FALTOU' end
union all
select 'modelo da Meta para convocação',
       case when exists (select 1 from information_schema.columns where table_schema='public' and table_name='whatsapp_config' and column_name='meta_modelo_convocacao') then 'ok' else 'FALTOU' end
union all
select 'funcionários ativos com celular',
       count(*) filter (where length(regexp_replace(coalesce(celular,''), '\D', '', 'g')) >= 10)::text || ' de ' || count(*)::text
  from public.funcionarios where ativo is not false;
