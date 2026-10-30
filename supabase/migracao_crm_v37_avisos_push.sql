-- =====================================================================
-- CRM Grupo BVEK — migração v37
-- Avisos no celular/computador mesmo com o CRM FECHADO (Web Push).
--  1. push_inscricoes: os aparelhos de cada pessoa (cada um vê só os seus).
--  2. push_config: chaves do Web Push e segredo do agendamento — só o
--     servidor lê (nenhum perfil do CRM tem acesso).
--  3. Agendamento: de segunda a sábado, às 8h40 e às 13h40 (Brasília), a
--     função "push" manda a cada pessoa as tarefas do dia, os pagamentos a
--     autorizar (administrador) e as declarações para assinar (funcionário).
--
-- Antes: publique a função supabase/functions/push (Edge Functions → push).
-- Precisa das extensões pg_cron e pg_net (já usadas no lembrete do WhatsApp, v20).
-- A chave usada abaixo é a chave PÚBLICA (anon) — a mesma que já está no site.
-- Pode rodar mais de uma vez. Nada é apagado.
-- =====================================================================
begin;

create table if not exists public.push_inscricoes (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid(),
  endpoint     text not null unique,
  p256dh       text not null,
  auth         text not null,
  user_agent   text,
  criado_em    timestamptz not null default now(),
  ultimo_envio timestamptz
);
alter table public.push_inscricoes enable row level security;
drop policy if exists push_proprio on public.push_inscricoes;
create policy push_proprio on public.push_inscricoes for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on public.push_inscricoes to authenticated;

create table if not exists public.push_config (
  id            integer primary key default 1 check (id = 1),
  publica       text,
  privada       text,
  segredo_cron  text
);
alter table public.push_config enable row level security;   -- sem regra = ninguém do CRM lê
revoke all on public.push_config from anon, authenticated;
insert into public.push_config (id, segredo_cron) values (1, gen_random_uuid()::text)
on conflict (id) do update set segredo_cron = coalesce(public.push_config.segredo_cron, excluded.segredo_cron);

-- chama a função "push" (lembretes do dia)
create or replace function public.bvek_push_lembretes() returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_req bigint;
begin
  select net.http_post(
    url     := 'https://smusenaszgkqkjjwblyi.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type', 'application/json',
                 'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNtdXNlbmFzemdrcWtqandibHlpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI0MTIwNTMsImV4cCI6MjA5Nzk4ODA1M30.IU1Z9ddIUpktjHvWqrSZaEWuo4gbmZfrfmYJ_NoXbWs',
                 'x-bvek-cron', (select segredo_cron from public.push_config where id = 1)),
    body    := jsonb_build_object('acao', 'lembretes')) into v_req;
  return v_req;
end $$;
revoke all on function public.bvek_push_lembretes() from public, anon, authenticated;

commit;

-- agendamento (horário do servidor = UTC: 11h40 e 16h40 UTC = 8h40 e 13h40 em Brasília)
select cron.unschedule(jobid) from cron.job where jobname = 'bvek-push-lembretes';
select cron.schedule('bvek-push-lembretes', '40 11,16 * * 1-6', 'select public.bvek_push_lembretes()');

-- Conferência
select (select count(*) from information_schema.tables where table_schema = 'public'
         and table_name in ('push_inscricoes','push_config'))              as tabelas_deve_ser_2,
       (select count(*) from cron.job where jobname = 'bvek-push-lembretes') as agendamento_deve_ser_1;
