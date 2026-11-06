-- =====================================================================
-- CRM Grupo BVEK — migração v51 (06/11/2026)
-- 1. ORDEM DE SERVIÇO DETALHADA (só na OS, não sai na proposta)
--    Tabela os_detalhes (uma por proposta): condições encontradas no local,
--    o que está e o que NÃO está incluído, como deve ficar no final,
--    quando parar e consultar, segurança e "como executar / como deve
--    ficar" de cada item. Só o Administrador grava (o funil é só dele);
--    a equipe lê pelo diário de obra (função bvek_os_do_projeto, sem valores).
-- 2. DIÁRIO DE OBRA
--    Tabela diarios_obra (um por projeto e dia). A função bvek_diarios_gerar
--    cria sozinha o diário de cada dia em que há equipe alocada no
--    Cronograma num projeto. O encarregado preenche pelo celular (login CPF,
--    só os diários da equipe dele) e o escritório confere e fecha.
--    Fotos no bucket privado "diarios".
-- 3. DOCUMENTOS DOS FUNCIONÁRIOS NO SHAREPOINT (espelho, sem duplicar)
--    Tabela documentos_sharepoint: um registro por arquivo do SharePoint,
--    pela identificação única do arquivo (sp_id, nunca repete). Quem grava é
--    só a função "sharepoint" (sincronizar_colaboradores). O arquivo que o
--    próprio CRM mandou fica ligado ao documento do CRM (aparece uma vez só).
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada.
-- =====================================================================

-- 1. ORDEM DE SERVIÇO DETALHADA ---------------------------------------------
create table if not exists public.os_detalhes (
  card_id              uuid primary key references public.cards(id) on delete cascade,
  projeto_id           uuid references public.projetos(id) on delete set null,
  condicoes_local      text,   -- o que foi visto na vistoria (forro, laje, instalações embutidas…)
  incluido             text,   -- o que está incluído
  nao_incluido         text,   -- o que NÃO está incluído
  resultado_final      text,   -- como deve ficar ao final (critério de aceite)
  pontos_parada        text,   -- quando parar e consultar o responsável antes de seguir
  seguranca            text,   -- riscos e cuidados
  responsavel_tecnico  text,
  contato_responsavel  text,
  itens                jsonb not null default '{}'::jsonb, -- { "<chave do item>": "como executar / como deve ficar" }
  atualizado_por       text,
  criado_em            timestamptz not null default now(),
  atualizado_em        timestamptz not null default now()
);
-- chave do item = número + descrição "limpos" (o CRM regrava os itens a cada salvamento; o id muda)
create or replace function public.bvek_chave_item(p_item text, p_desc text) returns text
language sql immutable as $$
  select regexp_replace(translate(lower(coalesce(p_item, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'), '[^a-z0-9]', '', 'g')
         || '|' ||
         regexp_replace(translate(lower(coalesce(p_desc, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'), '[^a-z0-9]', '', 'g');
$$;
create index if not exists os_detalhes_projeto_idx on public.os_detalhes (projeto_id);
alter table public.os_detalhes enable row level security;
drop policy if exists bvek_ler     on public.os_detalhes;
drop policy if exists bvek_inserir on public.os_detalhes;
drop policy if exists bvek_alterar on public.os_detalhes;
create policy bvek_ler     on public.os_detalhes for select to authenticated using (public.bvek_pode('{administrador}'));
create policy bvek_inserir on public.os_detalhes for insert to authenticated with check (public.bvek_pode('{administrador}'));
create policy bvek_alterar on public.os_detalhes for update to authenticated
  using (public.bvek_pode('{administrador}')) with check (public.bvek_pode('{administrador}'));

-- 2. DIÁRIO DE OBRA -----------------------------------------------------------
create table if not exists public.diarios_obra (
  id              uuid primary key default gen_random_uuid(),
  projeto_id      uuid not null references public.projetos(id) on delete cascade,
  data            date not null,
  cronograma_ids  uuid[] not null default '{}',
  equipe          uuid[] not null default '{}',   -- quem estava alocado (quem pode preencher)
  presentes       uuid[],                         -- quem de fato foi (null = todos da equipe)
  hora_inicio     time,
  hora_fim        time,
  clima_manha     text,   -- bom | nublado | chuva | chuva_forte
  clima_tarde     text,
  condicao        text,   -- normal | parcial | parado
  servicos        jsonb not null default '[]'::jsonb, -- [{ref,item,descricao,situacao,pct,obs}]
  atividades      text,   -- o que foi feito hoje
  divergencias    text,   -- o que estava diferente da OS no local e o que foi decidido (por quem)
  ocorrencias     text,
  pendencias      text,
  seguranca       text,
  visitas         text,   -- visitas e instruções do cliente/fiscal
  fotos           jsonb not null default '[]'::jsonb, -- [{caminho,legenda,momento}]
  situacao        text not null default 'pendente',   -- pendente | preenchido | fechado | cancelado
  preenchido_por  text,
  preenchido_em   timestamptz,
  fechado_por     text,
  fechado_em      timestamptz,
  criado_por      text,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);
create unique index if not exists diarios_obra_proj_data_idx on public.diarios_obra (projeto_id, data);
create index if not exists diarios_obra_data_idx on public.diarios_obra (data);
create index if not exists diarios_obra_equipe_idx on public.diarios_obra using gin (equipe);
alter table public.diarios_obra drop constraint if exists diarios_obra_situacao_chk;
alter table public.diarios_obra add constraint diarios_obra_situacao_chk
  check (situacao in ('pendente','preenchido','fechado','cancelado'));
alter table public.diarios_obra enable row level security;
drop policy if exists bvek_ler     on public.diarios_obra;
drop policy if exists bvek_inserir on public.diarios_obra;
drop policy if exists bvek_alterar on public.diarios_obra;
drop policy if exists bvek_apagar  on public.diarios_obra;
create policy bvek_ler on public.diarios_obra for select to authenticated
  using (public.bvek_pode('{administrador,comercial,administrativo,contabilidade}'));
create policy bvek_inserir on public.diarios_obra for insert to authenticated
  with check (public.bvek_pode('{administrador,comercial,administrativo,contabilidade}'));
create policy bvek_alterar on public.diarios_obra for update to authenticated
  using (public.bvek_pode('{administrador,comercial,administrativo,contabilidade}'))
  with check (public.bvek_pode('{administrador,comercial,administrativo,contabilidade}'));
create policy bvek_apagar on public.diarios_obra for delete to authenticated
  using (public.bvek_pode('{administrador}'));

-- diário fechado só muda com Administrador ou Administrativo (e só eles fecham)
create or replace function public.bvek_diario_trava() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if; -- funções internas
  if (old.situacao = 'fechado' or new.situacao = 'fechado')
     and not public.bvek_pode('{administrador,administrativo}') then
    raise exception 'Só o Administrador ou o Administrativo fecham ou alteram um diário fechado.';
  end if;
  new.atualizado_em := now();
  return new;
end $$;
drop trigger if exists bvek_diario_trava on public.diarios_obra;
create trigger bvek_diario_trava before update on public.diarios_obra
  for each row execute function public.bvek_diario_trava();

-- o funcionário (login CPF) está na equipe deste diário?
create or replace function public.bvek_diario_meu(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.diarios_obra d
                  where d.id = p_id and public.bvek_pode('{funcionario}')
                    and public.bvek_meu_funcionario_id() = any(d.equipe))
$$;
revoke all on function public.bvek_diario_meu(uuid) from public, anon;
grant execute on function public.bvek_diario_meu(uuid) to authenticated;

-- AUTOMAÇÃO: cria o diário de cada dia com equipe alocada num projeto (até hoje)
create or replace function public.bvek_diarios_gerar(p_ini date, p_fim date) returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_fim date := least(coalesce(p_fim, current_date), current_date);
  v_ini date := greatest(coalesce(p_ini, current_date - 7), current_date - 400);
  v_func uuid := null;
  v_n integer := 0;
begin
  if public.bvek_pode('{funcionario}') then
    v_func := public.bvek_meu_funcionario_id();
    if v_func is null then return 0; end if;
  elsif not public.bvek_pode('{administrador,comercial,administrativo,contabilidade}') then
    raise exception 'Sem permissão.';
  end if;
  if v_ini > v_fim then return 0; end if;

  with dias as (
    select c.projeto_id, g::date as data, c.id as cron_id, c.funcionarios
      from public.cronograma c
      cross join lateral generate_series(greatest(c.data_inicio, v_ini), least(c.data_fim, v_fim), interval '1 day') g
     where c.situacao = 'ativo' and c.projeto_id is not null
       and c.data_inicio <= v_fim and c.data_fim >= v_ini
       and (extract(isodow from g) < 6 or (extract(isodow from g) = 6 and c.sabado) or (extract(isodow from g) = 7 and c.domingo))
       and (v_func is null or v_func = any(c.funcionarios))
  ), juntos as (
    select d.projeto_id, d.data, array_agg(distinct d.cron_id) as crons, array_agg(distinct u) as equipe
      from dias d cross join lateral unnest(d.funcionarios) u
     group by d.projeto_id, d.data
  ), ins as (
    insert into public.diarios_obra (projeto_id, data, cronograma_ids, equipe, criado_por)
    select projeto_id, data, crons, equipe, 'Cronograma' from juntos
    on conflict (projeto_id, data) do update
       set cronograma_ids = excluded.cronograma_ids,
           equipe = (select coalesce(array_agg(distinct u), '{}') from unnest(diarios_obra.equipe || excluded.equipe) u),
           situacao = case when diarios_obra.situacao = 'cancelado' then 'pendente' else diarios_obra.situacao end
     where diarios_obra.situacao in ('pendente','cancelado')
       and (diarios_obra.equipe is distinct from excluded.equipe
            or diarios_obra.cronograma_ids is distinct from excluded.cronograma_ids
            or diarios_obra.situacao = 'cancelado')
    returning 1
  )
  select count(*) into v_n from ins;

  -- alocação cancelada ou encurtada: diário ainda vazio (pendente) vira "cancelado" (nada é apagado)
  if v_func is null then
    update public.diarios_obra d set situacao = 'cancelado'
     where d.situacao = 'pendente' and d.data between v_ini and v_fim and d.criado_por = 'Cronograma'
       and not exists (
         select 1 from public.cronograma c
          where c.situacao = 'ativo' and c.projeto_id = d.projeto_id
            and d.data between c.data_inicio and c.data_fim
            and (extract(isodow from d.data) < 6 or (extract(isodow from d.data) = 6 and c.sabado) or (extract(isodow from d.data) = 7 and c.domingo)));
  end if;
  return v_n;
end $$;
revoke all on function public.bvek_diarios_gerar(date, date) from public, anon;
grant execute on function public.bvek_diarios_gerar(date, date) to authenticated;

-- O QUE A OS DIZ (sem valores) — para o diário e para o encarregado
create or replace function public.bvek_os_do_projeto(p_projeto uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_card uuid; r jsonb;
begin
  if not (public.bvek_pode('{administrador,comercial,administrativo,contabilidade}')
          or exists (select 1 from public.diarios_obra d where d.projeto_id = p_projeto
                       and public.bvek_pode('{funcionario}') and public.bvek_meu_funcionario_id() = any(d.equipe))) then
    return null;
  end if;
  select coalesce(
           (select o.card_id from public.os_detalhes o where o.projeto_id = p_projeto order by o.atualizado_em desc limit 1),
           (select c.id from public.cards c where c.projeto_id = p_projeto order by (c.etapa in ('fechada','concluida')) desc, c.criado_em desc limit 1),
           (select p.card_id from public.projetos p where p.id = p_projeto))
    into v_card;
  if v_card is null then return null; end if;
  select jsonb_build_object(
           'card_id', c.id,
           'numero_os', case when c.numero_proposta ~ '-PRP-' then regexp_replace(regexp_replace(c.numero_proposta, '-PRP-', '-OS-'), '_R[0-9]+$', '') else null end,
           'servico', c.titulo, 'escopo', c.escopo,
           'condicoes_local', o.condicoes_local, 'incluido', o.incluido, 'nao_incluido', o.nao_incluido,
           'resultado_final', o.resultado_final, 'pontos_parada', o.pontos_parada, 'seguranca', o.seguranca,
           'responsavel_tecnico', o.responsavel_tecnico, 'contato_responsavel', o.contato_responsavel,
           'itens', coalesce((select jsonb_agg(jsonb_build_object(
                       'ref', public.bvek_chave_item(i.item, i.descricao), 'item', i.item, 'descricao', i.descricao, 'unidade', i.unidade,
                       'quantidade', i.quantidade, 'como', o.itens ->> public.bvek_chave_item(i.item, i.descricao)) order by i.ordem)
                     from public.itens_proposta i where i.card_id = c.id), '[]'::jsonb))
    into r
    from public.cards c left join public.os_detalhes o on o.card_id = c.id
   where c.id = v_card;
  return r;
end $$;
revoke all on function public.bvek_os_do_projeto(uuid) from public, anon;
grant execute on function public.bvek_os_do_projeto(uuid) to authenticated;

-- DIÁRIOS DO FUNCIONÁRIO (login CPF): os da equipe dele, últimos 45 dias
create or replace function public.bvek_meus_diarios() returns setof jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(d) || jsonb_build_object(
           'projeto_codigo', p.codigo, 'projeto_nome', p.nome, 'projeto_local', p.local,
           'cliente_nome', coalesce(cl.nome, ''),
           'equipe_nomes', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'nome', f.nome) order by f.nome), '[]'::jsonb)
                              from public.funcionarios f where f.id = any(d.equipe)))
    from public.diarios_obra d
    join public.projetos p on p.id = d.projeto_id
    left join public.clientes cl on cl.id = p.cliente_id
   where public.bvek_pode('{funcionario}')
     and public.bvek_meu_funcionario_id() = any(d.equipe)
     and d.situacao <> 'cancelado'
     and d.data >= current_date - 45
   order by d.data desc
$$;
revoke all on function public.bvek_meus_diarios() from public, anon;
grant execute on function public.bvek_meus_diarios() to authenticated;

-- o funcionário salva o diário (só os campos do dia; não fecha)
create or replace function public.bvek_diario_salvar(p_id uuid, p_dados jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_nome text; r public.diarios_obra;
begin
  if not public.bvek_diario_meu(p_id) then raise exception 'Este diário não é da sua equipe.'; end if;
  if exists (select 1 from public.diarios_obra where id = p_id and situacao = 'fechado') then
    raise exception 'Este diário já foi fechado pelo escritório. Fale com o escritório para corrigir.';
  end if;
  select nome into v_nome from public.funcionarios where id = public.bvek_meu_funcionario_id();
  update public.diarios_obra set
    hora_inicio  = nullif(p_dados->>'hora_inicio','')::time,
    hora_fim     = nullif(p_dados->>'hora_fim','')::time,
    clima_manha  = nullif(p_dados->>'clima_manha',''),
    clima_tarde  = nullif(p_dados->>'clima_tarde',''),
    condicao     = nullif(p_dados->>'condicao',''),
    presentes    = case when jsonb_typeof(p_dados->'presentes') = 'array'
                        then array(select x::uuid from jsonb_array_elements_text(p_dados->'presentes') x where x::uuid = any(equipe))
                        else presentes end,
    servicos     = coalesce(p_dados->'servicos', servicos),
    atividades   = nullif(p_dados->>'atividades',''),
    divergencias = nullif(p_dados->>'divergencias',''),
    ocorrencias  = nullif(p_dados->>'ocorrencias',''),
    pendencias   = nullif(p_dados->>'pendencias',''),
    seguranca    = nullif(p_dados->>'seguranca',''),
    visitas      = nullif(p_dados->>'visitas',''),
    fotos        = case when jsonb_typeof(p_dados->'fotos') = 'array' then p_dados->'fotos' else fotos end,
    situacao     = 'preenchido',
    preenchido_por = coalesce(v_nome, 'Funcionário'),
    preenchido_em  = now()
  where id = p_id
  returning * into r;
  return to_jsonb(r);
end $$;
revoke all on function public.bvek_diario_salvar(uuid, jsonb) from public, anon;
grant execute on function public.bvek_diario_salvar(uuid, jsonb) to authenticated;

-- fotos do diário (bucket privado): pasta = id do diário
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('diarios', 'diarios', false, 10485760, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 10485760,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','application/pdf'];
create or replace function public.bvek_diario_da_pasta(p_nome text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.diarios_obra d
                  where d.id::text = split_part(p_nome, '/', 1)
                    and public.bvek_pode('{funcionario}')
                    and public.bvek_meu_funcionario_id() = any(d.equipe))
$$;
revoke all on function public.bvek_diario_da_pasta(text) from public, anon;
grant execute on function public.bvek_diario_da_pasta(text) to authenticated;
drop policy if exists diarios_ler on storage.objects;
create policy diarios_ler on storage.objects for select to authenticated
  using (bucket_id = 'diarios' and (public.bvek_pode('{administrador,comercial,administrativo,contabilidade}') or public.bvek_diario_da_pasta(name)));
drop policy if exists diarios_enviar on storage.objects;
create policy diarios_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'diarios' and (public.bvek_pode('{administrador,comercial,administrativo,contabilidade}') or public.bvek_diario_da_pasta(name)));

-- 3. DOCUMENTOS DOS FUNCIONÁRIOS NO SHAREPOINT -----------------------------------
create table if not exists public.documentos_sharepoint (
  id              uuid primary key default gen_random_uuid(),
  sp_id           text not null,             -- identificação única do arquivo no SharePoint
  funcionario_id  uuid references public.funcionarios(id) on delete set null,
  raiz            text not null,             -- pasta do funcionário (…/01.2.1.1_ATIVOS/NOME)
  pasta           text not null,             -- pasta onde o arquivo está (pode ser subpasta)
  nome            text not null,
  url             text,
  tamanho         bigint,
  alterado_em     timestamptz,
  documento_id    uuid references public.documentos(id) on delete set null,
  ligado_manual   boolean not null default false,
  situacao        text not null default 'ativo',  -- ativo | removido (apagado no SharePoint)
  visto_em        timestamptz not null default now(),
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);
create unique index if not exists documentos_sharepoint_sp_idx on public.documentos_sharepoint (sp_id);
create index if not exists documentos_sharepoint_func_idx on public.documentos_sharepoint (funcionario_id);
alter table public.documentos_sharepoint enable row level security;
drop policy if exists bvek_ler     on public.documentos_sharepoint;
drop policy if exists bvek_alterar on public.documentos_sharepoint;
create policy bvek_ler on public.documentos_sharepoint for select to authenticated
  using (public.bvek_pode('{administrador,administrativo,contabilidade}'));
-- o RH só liga/desliga o arquivo a um documento do CRM; o resto quem grava é a função "sharepoint"
create policy bvek_alterar on public.documentos_sharepoint for update to authenticated
  using (public.bvek_pode('{administrador,administrativo}')) with check (public.bvek_pode('{administrador,administrativo}'));

create table if not exists public.sharepoint_sync (
  id          text primary key,           -- 'colaboradores'
  ultima_em   timestamptz,
  por         text,
  resultado   jsonb
);
alter table public.sharepoint_sync enable row level security;
drop policy if exists bvek_ler on public.sharepoint_sync;
create policy bvek_ler on public.sharepoint_sync for select to authenticated
  using (public.bvek_pode('{administrador,administrativo,contabilidade}'));

-- liga cada arquivo do SharePoint ao documento do CRM de mesmo nome do mesmo funcionário
-- (o arquivo que o CRM mandou). Prefere a versão valendo. Ligação feita à mão não é mexida.
create or replace function public.bvek_sp_ligar_documentos() returns integer
language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  update public.documentos_sharepoint s
     set documento_id = m.doc, atualizado_em = now()
    from (select s2.id,
                 (select d.id from public.documentos d
                   where d.funcionario_id = s2.funcionario_id
                     and lower(coalesce(d.arquivo_nome, '')) = lower(s2.nome)
                   order by (d.situacao = 'vigente') desc, d.criado_em desc limit 1) as doc
            from public.documentos_sharepoint s2
           where not s2.ligado_manual and s2.funcionario_id is not null) m
   where s.id = m.id and s.documento_id is distinct from m.doc;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.bvek_sp_ligar_documentos() from public, anon, authenticated;

-- Conferência
select 'tabela os_detalhes' as item, (to_regclass('public.os_detalhes') is not null)::text as resultado
union all select 'tabela diarios_obra', (to_regclass('public.diarios_obra') is not null)::text
union all select 'tabela documentos_sharepoint', (to_regclass('public.documentos_sharepoint') is not null)::text
union all select 'bucket diarios', exists(select 1 from storage.buckets where id = 'diarios')::text
union all select 'funções novas (deve ser 7)', count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('bvek_diarios_gerar','bvek_os_do_projeto','bvek_meus_diarios','bvek_diario_salvar','bvek_diario_meu','bvek_diario_da_pasta','bvek_sp_ligar_documentos')
union all select 'diários já existentes', count(*)::text from public.diarios_obra
union all select 'arquivos do SharePoint espelhados (duplicados deve ser 0)',
  (select count(*) from public.documentos_sharepoint)::text || ' (duplicados: ' ||
  (select count(*) from (select sp_id from public.documentos_sharepoint group by sp_id having count(*) > 1) x)::text || ')';
