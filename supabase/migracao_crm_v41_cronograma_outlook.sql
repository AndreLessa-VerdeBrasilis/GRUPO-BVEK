-- =====================================================================
-- CRM Grupo BVEK — migração v41: cronograma de funcionários + Outlook
-- ---------------------------------------------------------------------
-- 1. Tabela "cronograma": cada linha é uma alocação = equipe (um ou mais
--    funcionários) num projeto/cliente, de uma data a outra.
--    Sábado e domingo só contam quando marcados.
--    Cada alocação vira um evento no calendário do Outlook (e eventos
--    criados no Outlook com funcionários convidados viram alocações).
-- 2. Folha do mês automática: para os INTERMITENTES, os dias alocados no
--    mês (do dia 1 ao último dia) viram "dias convocados" e o funcionário
--    entra na folha. Só mexe em competência ABERTA. Se a alocação for
--    cancelada, o funcionário sai da folha (se tinha entrado pelo cronograma).
-- 3. Segurança: só Administrador e Administrativo veem e alteram.
--
-- Pode rodar mais de uma vez.
-- =====================================================================

-- 1. CRONOGRAMA ---------------------------------------------------------
create table if not exists public.cronograma (
  id                  uuid primary key default gen_random_uuid(),
  titulo              text,
  projeto_id          uuid references public.projetos(id) on delete set null,
  cliente_id          uuid references public.clientes(id) on delete set null,
  local               text,
  data_inicio         date not null,
  data_fim            date not null,
  sabado              boolean not null default false,   -- conta os sábados do período
  domingo             boolean not null default false,   -- conta os domingos do período
  funcionarios        uuid[] not null default '{}',
  observacoes         text,
  situacao            text not null default 'ativo',    -- ativo | cancelado
  origem              text not null default 'crm',      -- crm | outlook
  outlook_id          text,
  outlook_alterado_em timestamptz,  -- última alteração do evento no Outlook já trazida para o CRM
  outlook_sync_em     timestamptz,  -- última vez que o CRM e o Outlook ficaram iguais
  outlook_erro        text,
  criado_por          text,
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now()
);
alter table public.cronograma drop constraint if exists cronograma_datas_chk;
alter table public.cronograma add constraint cronograma_datas_chk check (data_fim >= data_inicio);
alter table public.cronograma drop constraint if exists cronograma_situacao_chk;
alter table public.cronograma add constraint cronograma_situacao_chk check (situacao in ('ativo','cancelado'));
alter table public.cronograma drop constraint if exists cronograma_origem_chk;
alter table public.cronograma add constraint cronograma_origem_chk check (origem in ('crm','outlook'));
create unique index if not exists cronograma_outlook_idx on public.cronograma (outlook_id) where outlook_id is not null;
create index if not exists cronograma_datas_idx on public.cronograma (data_inicio, data_fim);
create index if not exists cronograma_func_idx on public.cronograma using gin (funcionarios);

alter table public.cronograma enable row level security;
drop policy if exists bvek_ler     on public.cronograma;
drop policy if exists bvek_inserir on public.cronograma;
drop policy if exists bvek_alterar on public.cronograma;
drop policy if exists bvek_apagar  on public.cronograma;
create policy bvek_ler     on public.cronograma for select to authenticated using (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_inserir on public.cronograma for insert to authenticated with check (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_alterar on public.cronograma for update to authenticated using (public.bvek_pode('{administrador,administrativo}'::text[])) with check (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_apagar  on public.cronograma for delete to authenticated using (public.bvek_pode('{administrador}'::text[]));
grant select, insert, update, delete on public.cronograma to authenticated;
revoke all on public.cronograma from anon;

-- 2. FOLHA DO MÊS AUTOMÁTICA -----------------------------------------------
-- marca na folha quantos dias vieram do cronograma (vazio = não veio do cronograma)
alter table public.competencia_funcionarios add column if not exists dias_cronograma integer;

-- dias de trabalho de um funcionário entre duas datas, pelo cronograma
create or replace function public.bvek_cronograma_dias(p_func uuid, p_ini date, p_fim date) returns integer
language sql stable security definer set search_path = public as $$
  select count(distinct g.d)::int
    from public.cronograma c
    cross join lateral generate_series(greatest(c.data_inicio, p_ini), least(c.data_fim, p_fim), interval '1 day') as g(d)
   where c.situacao = 'ativo'
     and p_func = any(c.funcionarios)
     and c.data_inicio <= p_fim and c.data_fim >= p_ini
     and (extract(isodow from g.d) < 6
          or (extract(isodow from g.d) = 6 and c.sabado)
          or (extract(isodow from g.d) = 7 and c.domingo));
$$;

-- recalcula os intermitentes de uma competência (uso interno: gatilhos)
create or replace function public.bvek_cronograma_folha_int(p_comp date) returns integer
language plpgsql security definer set search_path = public as $$
declare
  comp record; f record; n integer; cf record; mudou integer := 0;
  ini date := date_trunc('month', p_comp)::date;
  fim date := (date_trunc('month', p_comp) + interval '1 month - 1 day')::date;
begin
  select * into comp from public.competencias_beneficios where competencia = ini;
  if not found or comp.situacao <> 'aberta' then return 0; end if;
  for f in
    select fu.id from public.funcionarios fu
      join public.funcionario_rh r on r.funcionario_id = fu.id
     where r.tipo_contrato = 'intermitente' and fu.ativo is not false
  loop
    n := public.bvek_cronograma_dias(f.id, ini, fim);
    select * into cf from public.competencia_funcionarios where competencia_id = comp.id and funcionario_id = f.id;
    if n > 0 then
      if not found then
        insert into public.competencia_funcionarios (competencia_id, funcionario_id, origem, na_folha, dias_trabalhados, dias_cronograma)
        values (comp.id, f.id, 'manual', true, n, n);
        mudou := mudou + 1;
      elsif cf.na_folha is distinct from true or cf.dias_trabalhados is distinct from n or cf.dias_cronograma is distinct from n then
        update public.competencia_funcionarios
           set na_folha = true, dias_trabalhados = n, dias_cronograma = n, atualizado_em = now()
         where id = cf.id;
        mudou := mudou + 1;
      end if;
    elsif found and cf.dias_cronograma is not null then
      -- tinha entrado pelo cronograma e não há mais dias: sai da folha
      update public.competencia_funcionarios
         set na_folha = null, dias_trabalhados = null, dias_cronograma = null, atualizado_em = now()
       where id = cf.id;
      mudou := mudou + 1;
    end if;
  end loop;
  return mudou;
end $$;
revoke all on function public.bvek_cronograma_folha_int(date) from public;
revoke all on function public.bvek_cronograma_folha_int(date) from anon, authenticated;

-- chamada pelo CRM (ao abrir a folha do mês): só Administrador e Administrativo
create or replace function public.bvek_cronograma_folha(p_comp date) returns integer
language plpgsql security definer set search_path = public as $$
begin
  if not public.bvek_pode('{administrador,administrativo}'::text[]) then return 0; end if;
  return public.bvek_cronograma_folha_int(p_comp);
end $$;
revoke all on function public.bvek_cronograma_folha(date) from public;
grant execute on function public.bvek_cronograma_folha(date) to authenticated;

-- gatilho: mudou o cronograma → recalcula os meses envolvidos
create or replace function public.bvek_cronograma_gatilho() returns trigger
language plpgsql security definer set search_path = public as $$
declare m date; meses date[] := '{}';
begin
  if tg_op in ('UPDATE','DELETE') then
    meses := meses || array(select generate_series(date_trunc('month', old.data_inicio), date_trunc('month', old.data_fim), interval '1 month')::date);
  end if;
  if tg_op in ('INSERT','UPDATE') then
    meses := meses || array(select generate_series(date_trunc('month', new.data_inicio), date_trunc('month', new.data_fim), interval '1 month')::date);
  end if;
  foreach m in array (select array(select distinct unnest(meses))) loop
    perform public.bvek_cronograma_folha_int(m);
  end loop;
  return null;
end $$;
drop trigger if exists bvek_cronograma_folha on public.cronograma;
create trigger bvek_cronograma_folha
  after insert or update or delete on public.cronograma
  for each row execute function public.bvek_cronograma_gatilho();

-- gatilho: competência aberta agora → já entra com o cronograma
create or replace function public.bvek_competencia_cronograma() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.bvek_cronograma_folha_int(new.competencia);
  return null;
end $$;
drop trigger if exists bvek_competencia_cronograma on public.competencias_beneficios;
create trigger bvek_competencia_cronograma
  after insert on public.competencias_beneficios
  for each row execute function public.bvek_competencia_cronograma();

-- Conferência
select 'tabela cronograma' as item, (to_regclass('public.cronograma') is not null)::text as ok
union all
select 'coluna dias_cronograma na folha',
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'competencia_funcionarios' and column_name = 'dias_cronograma')::text
union all
select 'alocações cadastradas', count(*)::text from public.cronograma
union all
select 'intermitentes ativos', count(*)::text
  from public.funcionarios f join public.funcionario_rh r on r.funcionario_id = f.id
 where r.tipo_contrato = 'intermitente' and f.ativo is not false;
