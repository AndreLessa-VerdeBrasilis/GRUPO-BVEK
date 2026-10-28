-- =====================================================================
-- CRM Grupo BVEK — migração v24 (28/10/2026)
-- Quadro de tarefas (estilo Trello/Asana) na aba Atividades
--
-- Aproveita a tabela "atividades" que já existe (nada é apagado) e
-- acrescenta o que o quadro precisa:
--   status       a_fazer · fazendo · aguardando · feito  (coluna do quadro)
--   prioridade   baixa · normal · alta · urgente
--   visibilidade equipe · administradores
--                "administradores" = tarefa só dos administradores: o
--                Comercial, o Administrativo e a Consulta NÃO veem
--                (regra gravada no banco, não só na tela)
--   detalhes, checklist, etiquetas, projeto, ordem e atualizado_em
--
-- "concluida" continua funcionando: o banco mantém status e concluida
-- sempre combinando (feito = concluída).
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

alter table public.atividades add column if not exists status        text;
alter table public.atividades add column if not exists prioridade    text not null default 'normal';
alter table public.atividades add column if not exists visibilidade  text not null default 'equipe';
alter table public.atividades add column if not exists detalhes      text;
alter table public.atividades add column if not exists checklist     jsonb not null default '[]'::jsonb;
alter table public.atividades add column if not exists etiquetas     text[] not null default '{}';
alter table public.atividades add column if not exists projeto_id    uuid references public.projetos(id) on delete set null;
alter table public.atividades add column if not exists ordem         double precision;
alter table public.atividades add column if not exists atualizado_em timestamptz not null default now();

-- atividades antigas entram no quadro: concluídas em "Feito", as demais em "A fazer"
update public.atividades set status = case when concluida then 'feito' else 'a_fazer' end where status is null;
alter table public.atividades alter column status set default 'a_fazer';
alter table public.atividades alter column status set not null;

alter table public.atividades drop constraint if exists atividades_status_chk;
alter table public.atividades add constraint atividades_status_chk check (status in ('a_fazer','fazendo','aguardando','feito'));
alter table public.atividades drop constraint if exists atividades_prioridade_chk;
alter table public.atividades add constraint atividades_prioridade_chk check (prioridade in ('baixa','normal','alta','urgente'));
alter table public.atividades drop constraint if exists atividades_visibilidade_chk;
alter table public.atividades add constraint atividades_visibilidade_chk check (visibilidade in ('equipe','administradores'));
create index if not exists atividades_status_idx on public.atividades (status, ordem);

-- status ⇄ concluida sempre combinando
create or replace function public.bvek_atividade_status() returns trigger
language plpgsql set search_path = public as $$
begin
  new.atualizado_em := now();
  if tg_op = 'INSERT' then
    if new.status is null or (new.concluida and new.status <> 'feito') then
      new.status := case when new.concluida then 'feito' else coalesce(new.status, 'a_fazer') end;
    end if;
  elsif new.status is distinct from old.status then
    null;  -- quem mudou foi o status: acerta a concluida abaixo
  elsif new.concluida is distinct from old.concluida then
    new.status := case when new.concluida then 'feito'
                       when old.status = 'feito' then 'a_fazer' else old.status end;
  end if;
  new.concluida := (new.status = 'feito');
  if new.concluida and new.concluida_em is null then new.concluida_em := now(); end if;
  if not new.concluida then new.concluida_em := null; end if;
  return new;
end $$;
drop trigger if exists atividades_status on public.atividades;
create trigger atividades_status before insert or update on public.atividades
  for each row execute function public.bvek_atividade_status();

-- ---------------------------------------------------------------------
-- SEGURANÇA: tarefas "só administradores" ficam invisíveis para os demais
-- ---------------------------------------------------------------------
alter table public.atividades enable row level security;
drop policy if exists bvek_ler     on public.atividades;
drop policy if exists bvek_inserir on public.atividades;
drop policy if exists bvek_alterar on public.atividades;
drop policy if exists bvek_apagar  on public.atividades;
create policy bvek_ler on public.atividades for select to authenticated
  using (public.bvek_pode('{administrador}')
         or (public.bvek_pode('{comercial,administrativo,consulta}') and visibilidade = 'equipe'));
create policy bvek_inserir on public.atividades for insert to authenticated
  with check (public.bvek_pode('{administrador}')
              or (public.bvek_pode('{comercial,administrativo}') and visibilidade = 'equipe'));
create policy bvek_alterar on public.atividades for update to authenticated
  using (public.bvek_pode('{administrador}')
         or (public.bvek_pode('{comercial,administrativo}') and visibilidade = 'equipe'))
  with check (public.bvek_pode('{administrador}')
              or (public.bvek_pode('{comercial,administrativo}') and visibilidade = 'equipe'));
create policy bvek_apagar on public.atividades for delete to authenticated
  using (public.bvek_pode('{administrador}')
         or (public.bvek_pode('{comercial,administrativo}') and visibilidade = 'equipe'));
grant select, insert, update, delete on public.atividades to authenticated;

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select status, count(*) as tarefas from public.atividades group by status
union all
select 'regras (deve ser 4)', count(*) from pg_policies where schemaname = 'public' and tablename = 'atividades';
