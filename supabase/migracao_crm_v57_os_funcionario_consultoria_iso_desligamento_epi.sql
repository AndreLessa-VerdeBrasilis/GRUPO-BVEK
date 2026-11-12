-- =====================================================================
-- CRM Grupo BVEK — migração v57 (12/11/2026)
-- 1. LOGIN POR CPF (perfil Funcionário)
--    • O DIÁRIO DE OBRA sai do login por CPF: o funcionário não vê, não
--      preenche e não abre as fotos dos diários. Só os perfis do escritório
--      (Administrador, Comercial, Administrativo, Contabilidade) usam o
--      diário, pela aba "Diário de obra". Nenhum diário é apagado.
--    • Entram as ORDENS DE SERVIÇO em que o funcionário está escalado no
--      Cronograma (função bvek_minhas_os, sem valores): alocações dos
--      últimos 30 dias, de hoje e futuras.
-- 2. PERFIL NOVO: CONSULTORIA ISO
--    Vê só a aba Gestão → Normas ISO 9001 / 14001. Pode cadastrar e alterar
--    requisitos e avaliar as leis novas (incluir / descartar). Não apaga,
--    não muda as palavras da busca, não vê Contas e acessos nem nada do
--    resto do CRM (clientes, funil, RH, financeiro…).
-- 3. RH — DESLIGAMENTO: data e motivo do desligamento do funcionário.
-- 4. INVENTÁRIO — EPI: data de validade e aviso de compra antes de vencer.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Rode DEPOIS da v56. Pode rodar mais de uma vez sem duplicar nada.
-- =====================================================================

-- 1. LOGIN POR CPF ---------------------------------------------------------------

-- 1a. diário de obra fora do login por CPF (as funções continuam existindo para
--     o escritório; para o funcionário passam a responder "não é seu")
create or replace function public.bvek_diario_meu(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select false
$$;
revoke all on function public.bvek_diario_meu(uuid) from public, anon;
grant execute on function public.bvek_diario_meu(uuid) to authenticated;

create or replace function public.bvek_diario_da_pasta(p_nome text) returns boolean
language sql stable security definer set search_path = public as $$
  select false
$$;
revoke all on function public.bvek_diario_da_pasta(text) from public, anon;
grant execute on function public.bvek_diario_da_pasta(text) to authenticated;

create or replace function public.bvek_meus_diarios() returns setof jsonb
language sql stable security definer set search_path = public as $$
  select null::jsonb where false
$$;
revoke all on function public.bvek_meus_diarios() from public, anon;
grant execute on function public.bvek_meus_diarios() to authenticated;

-- 1b. o que a OS diz (sem valores): o escritório, ou o funcionário escalado no Cronograma
create or replace function public.bvek_os_do_projeto(p_projeto uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_card uuid; r jsonb;
begin
  if not (public.bvek_pode('{administrador,comercial,administrativo,contabilidade}')
          or (public.bvek_pode('{funcionario}') and exists (
                select 1 from public.cronograma c
                 where c.projeto_id = p_projeto and c.situacao = 'ativo'
                   and c.data_fim >= current_date - 30
                   and public.bvek_meu_funcionario_id() = any(c.funcionarios)))) then
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

-- 1c. ordens de serviço do funcionário (login CPF): um item por contrato em que
--     ele está escalado, com as datas da alocação e a OS (sem valores)
create or replace function public.bvek_minhas_os() returns setof jsonb
language sql stable security definer set search_path = public as $$
  with minhas as (
    select c.projeto_id,
           min(c.data_inicio) as inicio, max(c.data_fim) as fim,
           jsonb_agg(jsonb_build_object('inicio', c.data_inicio, 'fim', c.data_fim,
                                        'local', c.local, 'observacoes', c.observacoes,
                                        'sabado', c.sabado, 'domingo', c.domingo)
                     order by c.data_inicio) as alocacoes
      from public.cronograma c
     where public.bvek_pode('{funcionario}')
       and c.situacao = 'ativo' and c.projeto_id is not null
       and c.data_fim >= current_date - 30
       and public.bvek_meu_funcionario_id() = any(c.funcionarios)
     group by c.projeto_id
  )
  select jsonb_build_object(
           'projeto_id', p.id, 'projeto_codigo', p.codigo, 'projeto_nome', p.nome, 'projeto_local', p.local,
           'cliente_nome', coalesce(cl.nome, ''),
           'empresa_sigla', e.sigla, 'empresa_nome', e.nome,
           'inicio', m.inicio, 'fim', m.fim, 'alocacoes', m.alocacoes,
           'os', public.bvek_os_do_projeto(p.id))
    from minhas m
    join public.projetos p on p.id = m.projeto_id
    left join public.clientes cl on cl.id = p.cliente_id
    left join public.empresas e on e.id = p.empresa_id
   order by (m.fim < current_date), m.inicio
$$;
revoke all on function public.bvek_minhas_os() from public, anon;
grant execute on function public.bvek_minhas_os() to authenticated;

-- 2. PERFIL NOVO: CONSULTORIA ISO --------------------------------------------------
alter table public.perfis drop constraint if exists perfis_perfil_chk;
alter table public.perfis add constraint perfis_perfil_chk
  check (perfil in ('pendente','administrador','comercial','administrativo','contabilidade','estagiario','consultoria_iso','funcionario'));

-- As tabelas que liberam a leitura para "qualquer login do escritório" (bvek_ativo)
-- ficam fechadas para a consultoria, como já acontece com o Funcionário.
create or replace function public.bvek_ativo() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.bvek_perfil() not in ('funcionario','consultoria_iso'), false)
$$;
grant execute on function public.bvek_ativo() to authenticated;

-- regras extras só para a consultoria (as dos outros perfis não mudam)
do $$
declare r record;
begin
  for r in select * from (values
    ('iso_requisitos', 'sim', 'sim', 'sim'),
    ('iso_novidades',  'sim', '-',   'sim'),
    ('iso_config',     'sim', '-',   '-'),
    ('empresas',       'sim', '-',   '-')    -- só para mostrar as siglas (EK, VB, BL, KS) na lista
  ) as t(tabela, ler, ins, upd)
  loop
    continue when to_regclass('public.' || r.tabela) is null;
    execute format('drop policy if exists bvek_isoc_ler on public.%I', r.tabela);
    execute format('drop policy if exists bvek_isoc_inserir on public.%I', r.tabela);
    execute format('drop policy if exists bvek_isoc_alterar on public.%I', r.tabela);
    if r.ler = 'sim' then
      execute format('create policy bvek_isoc_ler on public.%I for select to authenticated using (public.bvek_pode(''{consultoria_iso}''::text[]))', r.tabela);
    end if;
    if r.ins = 'sim' then
      execute format('create policy bvek_isoc_inserir on public.%I for insert to authenticated with check (public.bvek_pode(''{consultoria_iso}''::text[]))', r.tabela);
    end if;
    if r.upd = 'sim' then
      execute format('create policy bvek_isoc_alterar on public.%I for update to authenticated using (public.bvek_pode(''{consultoria_iso}''::text[])) with check (public.bvek_pode(''{consultoria_iso}''::text[]))', r.tabela);
    end if;
  end loop;
end $$;

-- 3. RH — DESLIGAMENTO ---------------------------------------------------------------
alter table public.funcionarios add column if not exists data_desligamento   date;
alter table public.funcionarios add column if not exists motivo_desligamento text;
alter table public.funcionarios add column if not exists obs_desligamento    text;

-- 4. INVENTÁRIO — VALIDADE DO EPI ------------------------------------------------------
alter table public.inventario_itens add column if not exists data_validade        date;
alter table public.inventario_itens add column if not exists aviso_validade_dias  integer not null default 30;
alter table public.inventario_itens drop constraint if exists inventario_aviso_validade_chk;
alter table public.inventario_itens add constraint inventario_aviso_validade_chk
  check (aviso_validade_dias between 0 and 365);

-- Conferência ------------------------------------------------------------------------
select 'função bvek_minhas_os (OS no login CPF)' as item,
       case when exists (select 1 from pg_proc where proname = 'bvek_minhas_os') then 'ok' else 'FALTA' end as resultado
union all
select 'diário fora do login CPF', case when public.bvek_diario_da_pasta('x/y') = false then 'ok' else 'FALTA' end
union all
select 'perfil Consultoria ISO — regras', (select count(*)::text || ' regra(s)' from pg_policies where schemaname = 'public' and policyname like 'bvek_isoc_%')
union all
select 'funcionários — colunas do desligamento', (select count(*)::text || ' de 3' from information_schema.columns
  where table_schema = 'public' and table_name = 'funcionarios' and column_name in ('data_desligamento','motivo_desligamento','obs_desligamento'))
union all
select 'inventário — validade do EPI', (select count(*)::text || ' de 2' from information_schema.columns
  where table_schema = 'public' and table_name = 'inventario_itens' and column_name in ('data_validade','aviso_validade_dias'));
