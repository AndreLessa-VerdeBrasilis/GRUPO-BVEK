-- =====================================================================
-- CRM Grupo BVEK — migração v48 (04/11/2026)
-- WhatsApp da CONVOCAÇÃO com configuração própria, separada do lembrete
-- de pagamentos:
--   • Financeiro → ⚙️ WhatsApp  = lembrete de pagamentos (tabela whatsapp_config, como antes)
--   • Cronograma → ⚙️ WhatsApp  = convocação dos funcionários (tabela nova
--     whatsapp_convocacao_config, sempre pela API oficial da Meta)
-- Na primeira vez, copia o token e o número da Meta que já estavam no
-- Financeiro (se houver) — depois cada um muda sem afetar o outro.
-- Só o Administrador vê e altera (o token é segredo).
--
-- Rode DEPOIS da v47. Pode rodar mais de uma vez. Nada é apagado.
-- =====================================================================

-- garante a coluna da v47 (caso a v47 ainda não tenha rodado)
alter table public.whatsapp_config add column if not exists meta_modelo_convocacao text;

create table if not exists public.whatsapp_convocacao_config (
  id             integer primary key default 1,
  ativo          boolean not null default true,   -- desligado = a convocação vai só por e-mail
  meta_token     text,
  meta_phone_id  text,
  meta_modelo    text,                            -- modelo aprovado na Meta (7 variáveis)
  meta_idioma    text default 'pt_BR',
  atualizado_em  timestamptz not null default now()
);
alter table public.whatsapp_convocacao_config drop constraint if exists whatsapp_convocacao_config_uma_linha;
alter table public.whatsapp_convocacao_config add constraint whatsapp_convocacao_config_uma_linha check (id = 1);

insert into public.whatsapp_convocacao_config (id, meta_token, meta_phone_id, meta_modelo, meta_idioma)
select 1, w.meta_token, w.meta_phone_id, w.meta_modelo_convocacao, coalesce(w.meta_idioma, 'pt_BR')
  from public.whatsapp_config w where w.id = 1
on conflict (id) do nothing;
insert into public.whatsapp_convocacao_config (id) values (1) on conflict (id) do nothing;

alter table public.whatsapp_convocacao_config enable row level security;
drop policy if exists bvek_ler     on public.whatsapp_convocacao_config;
drop policy if exists bvek_inserir on public.whatsapp_convocacao_config;
drop policy if exists bvek_alterar on public.whatsapp_convocacao_config;
drop policy if exists bvek_apagar  on public.whatsapp_convocacao_config;
create policy bvek_ler     on public.whatsapp_convocacao_config for select to authenticated using (public.bvek_pode('{administrador}'::text[]));
create policy bvek_alterar on public.whatsapp_convocacao_config for update to authenticated
  using (public.bvek_pode('{administrador}'::text[])) with check (public.bvek_pode('{administrador}'::text[]));
grant select, update on public.whatsapp_convocacao_config to authenticated;
revoke all on public.whatsapp_convocacao_config from anon;

-- Conferência: 1 linha; "token preenchido" = sim se já veio do Financeiro.
select ativo,
       case when coalesce(meta_token, '') <> '' then 'sim' else 'não' end as token_preenchido,
       meta_phone_id as id_do_numero,
       coalesce(meta_modelo, '(sem modelo)') as modelo,
       meta_idioma as idioma
  from public.whatsapp_convocacao_config;
