-- =====================================================================
-- CRM Grupo BVEK — migração v82: AGENDAMENTO DA ENTREVISTA (3º passo)
--
-- Passos do candidato no CRM:
--   1. currículo / indicação recebido (RH → Currículos)
--   2. triagem inicial por mensagem (v81) e decisão do RH
--   3. entrevista presencial — ESTA MIGRAÇÃO
--
-- Quando a decisão da triagem é "Chamar para entrevista", a ficha do
-- currículo mostra "Agendar entrevista". Ao agendar, o CRM:
--   • cria um evento na agenda do escritório (tabela agenda_escritorio,
--     v45): aparece no Cronograma e no Painel, e os entrevistadores
--     recebem o convite no Outlook;
--   • abre o WhatsApp com a mensagem pronta para o candidato
--     (data, horário, local e pedido de confirmação);
--   • guarda a entrevista nesta tabela, ligada ao currículo e ao evento.
-- Remarcar e cancelar mexem no mesmo evento e geram a mensagem certa.
-- Depois da data, o RH marca "compareceu" ou "faltou".
--
-- Pode rodar mais de uma vez sem duplicar nada.
-- =====================================================================
begin;

create table if not exists public.entrevistas (
  id               uuid primary key default gen_random_uuid(),
  curriculo_id     uuid not null references public.curriculos(id) on delete cascade,
  triagem_id       uuid references public.triagens(id) on delete set null,
  agenda_id        uuid references public.agenda_escritorio(id) on delete set null,
  cargo            text,
  inicio           timestamptz not null,
  fim              timestamptz not null,
  local            text,
  entrevistadores  jsonb not null default '[]'::jsonb,   -- [{nome, email}] (recebem o convite no Outlook)
  obs_candidato    text,                                  -- recado que vai na mensagem (ex.: trazer documento com foto)
  situacao         text not null default 'agendada',      -- agendada, realizada, faltou, cancelada
  whatsapp_em      timestamptz,                           -- última vez que o RH abriu o WhatsApp com a mensagem
  whatsapp_por     text,
  observacao       text,                                  -- anotação do RH sobre a entrevista
  criado_em        timestamptz not null default now(),
  criado_por       text,
  atualizado_em    timestamptz not null default now()
);
alter table public.entrevistas add column if not exists obs_candidato text;
alter table public.entrevistas add column if not exists observacao text;
alter table public.entrevistas add column if not exists whatsapp_em timestamptz;
alter table public.entrevistas add column if not exists whatsapp_por text;
alter table public.entrevistas drop constraint if exists entrevistas_situacao_chk;
alter table public.entrevistas add constraint entrevistas_situacao_chk
  check (situacao in ('agendada','realizada','faltou','cancelada'));
alter table public.entrevistas drop constraint if exists entrevistas_datas_chk;
alter table public.entrevistas add constraint entrevistas_datas_chk check (fim > inicio);
create index if not exists entrevistas_curr_idx on public.entrevistas (curriculo_id, inicio desc);
create index if not exists entrevistas_agenda_idx on public.entrevistas (agenda_id);

-- Segurança: mesmas regras dos currículos e da triagem
alter table public.entrevistas enable row level security;
drop policy if exists bvek_ler     on public.entrevistas;
drop policy if exists bvek_inserir on public.entrevistas;
drop policy if exists bvek_alterar on public.entrevistas;
drop policy if exists bvek_apagar  on public.entrevistas;
create policy bvek_ler     on public.entrevistas for select to authenticated using (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_inserir on public.entrevistas for insert to authenticated with check (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_alterar on public.entrevistas for update to authenticated
  using (public.bvek_pode('{administrador,administrativo}'::text[])) with check (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_apagar  on public.entrevistas for delete to authenticated using (public.bvek_pode('{administrador}'::text[]));
grant select, insert, update, delete on public.entrevistas to authenticated;
revoke all on public.entrevistas from anon;

commit;

-- Conferência
select (select count(*) from information_schema.tables where table_schema = 'public' and table_name = 'entrevistas') as tabela_entrevistas_deve_ser_1,
       (select count(*) from pg_policies where schemaname = 'public' and tablename = 'entrevistas')                  as regras_deve_ser_4,
       (select count(*) from information_schema.tables where table_schema = 'public' and table_name = 'triagens')    as triagens_v81_deve_ser_1,
       (select count(*) from public.entrevistas)                                                                     as entrevistas_ja_criadas;
