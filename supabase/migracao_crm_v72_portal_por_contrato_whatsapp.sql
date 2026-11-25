-- =====================================================================
-- CRM Grupo BVEK — migração v72 (25/11/2026)
-- 1. PORTAL DO CLIENTE POR CONTRATO
--    • Cada contrato tem a sua lista de CONTATOS com acesso
--      (portal_contratos.contatos). O login do cliente (e-mail) só vê os
--      contratos liberados em que o e-mail dele está nessa lista.
--    • Na primeira vez a lista é preenchida com o contato da proposta do
--      contrato e com os contatos que JÁ têm login (ninguém perde acesso).
--    • "Preparar acessos" (Clientes → Portal: acessos) põe no portal
--      todos os contratos que ainda não estão lá (liberados, sem a
--      proposta) e acrescenta o contato da proposta onde a lista está vazia.
--    • Pendências: contratos sem contato, contatos sem e-mail e contatos
--      que ainda não receberam o login (bvek_portal_pendencias).
--    • Envio do login e da senha provisória por e-mail: só pela função
--      "portal-acessos" e só depois que o Administrador ligar o envio
--      (portal_config.envio_liberado — começa DESLIGADO).
-- 2. WHATSAPP DA CONVOCAÇÃO: campo opcional "ID da conta do WhatsApp"
--    (WABA) para o diagnóstico conferir o modelo de mensagem.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Rode DEPOIS da v71. Pode rodar mais de uma vez sem duplicar nada.
-- Nada é apagado.
-- =====================================================================

-- 0. WhatsApp da convocação ----------------------------------------------------------
alter table public.whatsapp_convocacao_config add column if not exists meta_waba_id text;

-- 1. CONTATOS DE CADA CONTRATO NO PORTAL ---------------------------------------------
alter table public.portal_contratos add column if not exists contatos uuid[] not null default '{}';

-- configuração do envio dos acessos (uma linha só)
create table if not exists public.portal_config (
  id              integer primary key default 1,
  envio_liberado  boolean not null default false,   -- desligado = nenhum e-mail sai
  assunto         text,
  mensagem        text,
  atualizado_por  text,
  atualizado_em   timestamptz not null default now()
);
alter table public.portal_config drop constraint if exists portal_config_uma_linha;
alter table public.portal_config add constraint portal_config_uma_linha check (id = 1);
insert into public.portal_config (id) values (1) on conflict (id) do nothing;

-- histórico dos envios de acesso (quem recebeu, quando, erro)
create table if not exists public.portal_acessos_envios (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  nome        text,
  perfil_id   uuid,
  ok          boolean not null default false,
  erro        text,
  remetente   text,
  enviado_por text,
  enviado_em  timestamptz not null default now()
);
create index if not exists portal_acessos_envios_email_idx on public.portal_acessos_envios (lower(email), enviado_em desc);

do $$
declare t text;
begin
  foreach t in array array['portal_config','portal_acessos_envios'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists bvek_ler on public.%I', t);
    execute format('drop policy if exists bvek_inserir on public.%I', t);
    execute format('drop policy if exists bvek_alterar on public.%I', t);
    execute format('drop policy if exists bvek_apagar on public.%I', t);
    execute format('create policy bvek_ler on public.%I for select to authenticated using (public.bvek_pode(''{administrador}''::text[]))', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;
-- só a configuração pode ser alterada pela tela (o histórico só a função grava)
drop policy if exists bvek_alterar on public.portal_config;
create policy bvek_alterar on public.portal_config for update to authenticated
  using (public.bvek_pode('{administrador}'::text[])) with check (public.bvek_pode('{administrador}'::text[]));
grant update on public.portal_config to authenticated;

-- contato(s) da proposta de um contrato
create or replace function public.bvek_contatos_proposta(p_projeto uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct c.contato_id), '{}')
    from public.cards c
   where c.contato_id is not null
     and (c.projeto_id = p_projeto or c.id = (select p.card_id from public.projetos p where p.id = p_projeto))
$$;
revoke all on function public.bvek_contatos_proposta(uuid) from public, anon;
grant execute on function public.bvek_contatos_proposta(uuid) to authenticated;

-- primeira vez: contato da proposta + contatos que já têm login (ninguém perde acesso)
update public.portal_contratos pc
   set contatos = (select coalesce(array_agg(distinct x), '{}') from unnest(
          public.bvek_contatos_proposta(pc.projeto_id) ||
          coalesce((select array_agg(ct.id)
                      from public.contatos ct
                      join public.projetos p on p.id = pc.projeto_id and ct.cliente_id = p.cliente_id
                      join public.perfis pf on pf.perfil = 'cliente' and lower(pf.email) = lower(trim(ct.email))
                     where coalesce(trim(ct.email), '') <> ''), '{}')) x)
 where cardinality(pc.contatos) = 0;

-- o login do cliente pode ver este contrato? (liberado + e-mail do login na lista de contatos)
create or replace function public.bvek_portal_contrato_meu(p_projeto uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.portal_contratos pc
      join public.contatos ct on ct.id = any(pc.contatos)
      join public.perfis pf on pf.id = auth.uid() and pf.ativo and pf.perfil = 'cliente'
     where pc.projeto_id = p_projeto and pc.liberado
       and lower(trim(ct.email)) = lower(pf.email))
$$;
revoke all on function public.bvek_portal_contrato_meu(uuid) from public, anon;
grant execute on function public.bvek_portal_contrato_meu(uuid) to authenticated;

-- arquivos: igual à v59, só dos contratos do login
create or replace function public.bvek_portal_pode_arquivo(p_bucket text, p_nome text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_clis uuid[] := public.bvek_meus_clientes();
begin
  if cardinality(v_clis) = 0 or p_nome is null then return false; end if;
  if p_bucket = 'propostas' then
    return exists (select 1 from public.portal_contratos pc
                     join public.projetos p on p.id = pc.projeto_id
                     join public.cards c on c.id = pc.card_id
                    where public.bvek_portal_contrato_meu(p.id) and pc.ver_proposta and c.arquivo_proposta = p_nome);
  elsif p_bucket = 'documentos' then
    return exists (select 1 from public.portal_contratos pc
                     join public.projetos p on p.id = pc.projeto_id
                     join public.documentos d on d.id = any(pc.documentos)
                    where public.bvek_portal_contrato_meu(p.id) and pc.ver_documentos
                      and d.funcionario_id is null and d.situacao = 'vigente' and d.arquivo = p_nome);
  elsif p_bucket = 'diarios' then
    return exists (select 1 from public.diarios_obra d
                     join public.portal_contratos pc on pc.projeto_id = d.projeto_id
                    where public.bvek_portal_contrato_meu(d.projeto_id) and pc.ver_diario and d.situacao = 'fechado'
                      and d.id::text = split_part(p_nome, '/', 1)
                      and (exists (select 1 from jsonb_array_elements(coalesce(d.fotos, '[]'::jsonb)) f where f->>'caminho' = p_nome)
                           or exists (select 1 from jsonb_array_elements(coalesce(d.registros, '[]'::jsonb)) r where r->>'foto' = p_nome)));
  elsif p_bucket = 'portal' then
    return exists (select 1 from public.portal_arquivos a
                     join public.portal_contratos pc on pc.projeto_id = a.projeto_id
                    where public.bvek_portal_contrato_meu(a.projeto_id) and a.visivel and a.caminho = p_nome
                      and ((a.categoria = 'inicio' and pc.ver_inicio) or (a.categoria in ('medicao','nota_fiscal') and pc.ver_medicoes)));
  end if;
  return false;
end $$;
revoke all on function public.bvek_portal_pode_arquivo(text, text) from public, anon;
grant execute on function public.bvek_portal_pode_arquivo(text, text) to authenticated;

-- OS: igual à v59, cliente só nos contratos do login
create or replace function public.bvek_os_do_projeto(p_projeto uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_card uuid; r jsonb;
begin
  if not (public.bvek_pode('{administrador,comercial,administrativo,contabilidade}')
          or (public.bvek_pode('{funcionario}') and exists (
                select 1 from public.cronograma c
                 where c.projeto_id = p_projeto and c.situacao = 'ativo'
                   and c.data_fim >= current_date - 30
                   and public.bvek_meu_funcionario_id() = any(c.funcionarios)))
          or (public.bvek_pode('{cliente}') and public.bvek_portal_contrato_meu(p_projeto)
              and exists (select 1 from public.portal_contratos pc where pc.projeto_id = p_projeto and pc.ver_os))) then
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

-- tudo o que o cliente vê: igual à v59, só os contratos do login
create or replace function public.bvek_portal_dados() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cli uuid := public.bvek_meu_cliente_id(); v_clis uuid[] := public.bvek_meus_clientes(); r jsonb;
begin
  if cardinality(v_clis) = 0 then return null; end if;
  select jsonb_build_object(
    'cliente', (select jsonb_build_object('id', cl.id, 'codigo', cl.codigo, 'nome', cl.nome, 'razao_social', cl.razao_social,
                                          'documento', cl.documento, 'endereco', cl.endereco,
                                          'email', to_jsonb(cl)->>'email', 'telefone', to_jsonb(cl)->>'telefone')
                  from public.clientes cl where cl.id = coalesce(v_cli, v_clis[1])),
    'clientes', coalesce((select jsonb_agg(jsonb_build_object('id', cl.id, 'codigo', cl.codigo, 'nome', cl.nome, 'razao_social', cl.razao_social,
                                          'documento', cl.documento, 'endereco', cl.endereco,
                                          'email', to_jsonb(cl)->>'email', 'telefone', to_jsonb(cl)->>'telefone')
                                          order by (cl.id = v_cli) desc, cl.codigo)
                  from public.clientes cl where cl.id = any(v_clis)), '[]'::jsonb),
    'contratos', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'codigo', p.codigo, 'nome', p.nome, 'local', p.local, 'status', p.status, 'ano', p.ano,
        'cliente_id', p.cliente_id, 'cliente_codigo', clp.codigo, 'cliente_nome', clp.nome,
        'empresa_sigla', e.sigla, 'empresa_nome', e.nome,
        'periodo', (select jsonb_build_object('inicio', min(c.data_inicio), 'fim', max(c.data_fim))
                      from public.cronograma c where c.projeto_id = p.id and c.situacao = 'ativo'),
        'proposta', case when pc.ver_proposta then
            (select jsonb_build_object('numero', cd.numero_proposta, 'titulo', cd.titulo,
                                       'arquivo', cd.arquivo_proposta, 'arquivo_nome', cd.arquivo_proposta_nome)
               from public.cards cd where cd.id = pc.card_id) end,
        'ver_os', pc.ver_os,
        'os', case when pc.ver_os then public.bvek_os_do_projeto(p.id) end,
        'ver_diario', pc.ver_diario,
        'diarios', case when pc.ver_diario then coalesce((
            select jsonb_agg(jsonb_build_object(
                     'id', d.id, 'data', d.data, 'hora_inicio', d.hora_inicio, 'hora_fim', d.hora_fim,
                     'clima_manha', d.clima_manha, 'clima_tarde', d.clima_tarde, 'condicao', d.condicao,
                     'atividades', d.atividades, 'servicos', d.servicos, 'divergencias', d.divergencias,
                     'ocorrencias', d.ocorrencias, 'visitas', d.visitas, 'seguranca', d.seguranca, 'pendencias', d.pendencias,
                     'fotos', d.fotos,
                     'registros', (select coalesce(jsonb_agg(jsonb_build_object('em', x->>'em', 'texto', x->>'texto', 'foto', x->>'foto', 'autor', x->>'autor')
                                                             order by x->>'em'), '[]'::jsonb)
                                     from jsonb_array_elements(coalesce(d.registros, '[]'::jsonb)) x
                                    where coalesce(x->>'texto', '') <> '' or coalesce(x->>'foto', '') <> ''),
                     'equipe', (select coalesce(jsonb_agg(f.nome order by f.nome), '[]'::jsonb)
                                  from public.funcionarios f where f.id = any(case when cardinality(d.presentes) > 0 then d.presentes else d.equipe end)))
                   order by d.data desc)
              from public.diarios_obra d where d.projeto_id = p.id and d.situacao = 'fechado'), '[]'::jsonb) end,
        'documentos', case when pc.ver_documentos then coalesce((
            select jsonb_agg(jsonb_build_object('id', d.id, 'tipo', t.nome, 'descricao', d.descricao, 'orgao', d.orgao,
                                                'numero', d.numero, 'emissao', d.data_emissao, 'validade', d.data_validade,
                                                'arquivo', d.arquivo, 'arquivo_nome', d.arquivo_nome,
                                                'empresa_sigla', ed.sigla) order by t.nome)
              from public.documentos d left join public.tipos_documento t on t.id = d.tipo_id
              left join public.empresas ed on ed.id = d.empresa_id
             where d.id = any(pc.documentos) and d.funcionario_id is null and d.situacao = 'vigente'), '[]'::jsonb) end,
        'arquivos', coalesce((
            select jsonb_agg(jsonb_build_object('id', a.id, 'categoria', a.categoria, 'titulo', a.titulo, 'numero', a.numero,
                                                'data', a.data_documento, 'caminho', a.caminho, 'arquivo_nome', a.arquivo_nome)
                             order by a.data_documento desc nulls last, a.criado_em desc)
              from public.portal_arquivos a
             where a.projeto_id = p.id and a.visivel
               and ((a.categoria = 'inicio' and pc.ver_inicio) or (a.categoria in ('medicao','nota_fiscal') and pc.ver_medicoes))), '[]'::jsonb),
        'ver_inicio', pc.ver_inicio, 'ver_medicoes', pc.ver_medicoes)
        order by clp.codigo, p.codigo desc)
      from public.projetos p
      join public.portal_contratos pc on pc.projeto_id = p.id and pc.liberado
      left join public.clientes clp on clp.id = p.cliente_id
      left join public.empresas e on e.id = p.empresa_id
     where public.bvek_portal_contrato_meu(p.id)), '[]'::jsonb))
  into r;
  return r;
end $$;
revoke all on function public.bvek_portal_dados() from public, anon;
grant execute on function public.bvek_portal_dados() to authenticated;

-- PREPARAR ACESSOS (só Administrador): todo contrato no portal + contato da proposta
create or replace function public.bvek_portal_preparar(p_quem text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_novos int := 0; v_contatos int := 0;
begin
  if not public.bvek_pode('{administrador}') then raise exception 'Só o Administrador prepara os acessos do portal.'; end if;
  -- contratos que ainda não estão no portal: entram liberados, sem a proposta (tem valores)
  insert into public.portal_contratos (projeto_id, liberado, ver_proposta, ver_os, ver_diario, ver_documentos, ver_inicio, ver_medicoes, contatos, atualizado_por)
  select p.id, true, false, true, true, false, true, true, public.bvek_contatos_proposta(p.id), coalesce(p_quem, 'preparar acessos')
    from public.projetos p
   where not exists (select 1 from public.portal_contratos pc where pc.projeto_id = p.id)
  on conflict (projeto_id) do nothing;
  get diagnostics v_novos = row_count;
  -- contratos que já estavam no portal sem contato: recebem o contato da proposta
  update public.portal_contratos pc
     set contatos = public.bvek_contatos_proposta(pc.projeto_id), atualizado_por = coalesce(p_quem, pc.atualizado_por), atualizado_em = now()
   where cardinality(pc.contatos) = 0 and cardinality(public.bvek_contatos_proposta(pc.projeto_id)) > 0;
  get diagnostics v_contatos = row_count;
  return jsonb_build_object('contratos_novos', v_novos, 'contratos_com_contato', v_contatos);
end $$;
revoke all on function public.bvek_portal_preparar(text) from public, anon;
grant execute on function public.bvek_portal_preparar(text) to authenticated;

-- PENDÊNCIAS (só Administrador): o que falta para cada contrato ter acesso
create or replace function public.bvek_portal_pendencias() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.bvek_pode('{administrador}') then raise exception 'Só o Administrador vê os acessos do portal.'; end if;
  with ct as (   -- cada contato de cada contrato no portal
    select pc.projeto_id, ct.id contato_id, ct.nome, ct.cliente_id, lower(trim(coalesce(ct.email, ''))) email
      from public.portal_contratos pc join public.contatos ct on ct.id = any(pc.contatos)
  ), logins as (
    select lower(pf.email) email, pf.id, pf.ativo, pf.senha_definida_em, pf.perfil from public.perfis pf where pf.email is not null
  )
  select jsonb_build_object(
    -- contratos sem nenhum contato na lista (ou contrato fora do portal)
    'sem_contato', coalesce((select jsonb_agg(jsonb_build_object('projeto_id', p.id, 'codigo', p.codigo, 'nome', p.nome, 'status', p.status,
                                     'cliente_id', p.cliente_id, 'cliente', cl.nome, 'cliente_codigo', cl.codigo,
                                     'no_portal', pc.projeto_id is not null, 'liberado', coalesce(pc.liberado, false),
                                     'contatos_do_cliente', (select count(*) from public.contatos x where x.cliente_id = p.cliente_id))
                                     order by cl.codigo, p.codigo)
        from public.projetos p left join public.portal_contratos pc on pc.projeto_id = p.id
        left join public.clientes cl on cl.id = p.cliente_id
       where pc.projeto_id is null or cardinality(pc.contatos) = 0
          or not exists (select 1 from public.contatos x where x.id = any(pc.contatos))), '[]'::jsonb),
    -- contatos ligados a contrato mas sem e-mail válido
    'sem_email', coalesce((select jsonb_agg(distinct jsonb_build_object('contato_id', ct.contato_id, 'nome', ct.nome, 'cliente_id', ct.cliente_id,
                                     'cliente', cl.nome, 'cliente_codigo', cl.codigo))
        from ct left join public.clientes cl on cl.id = ct.cliente_id
       where ct.email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'), '[]'::jsonb),
    -- e-mails que precisam receber o acesso (sem login, ou login que nunca entrou)
    'a_enviar', coalesce((select jsonb_agg(x order by x->>'nome') from (
        select jsonb_build_object('email', ct.email, 'nome', min(ct.nome),
                 'contato_ids', jsonb_agg(distinct ct.contato_id), 'cliente_ids', jsonb_agg(distinct ct.cliente_id),
                 'contratos', jsonb_agg(distinct p.codigo),
                 'tem_login', bool_or(l.id is not null), 'conflito', bool_or(l.perfil is not null and l.perfil not in ('pendente','cliente')),
                 'ultimo_envio', (select jsonb_build_object('em', e.enviado_em, 'ok', e.ok, 'erro', e.erro)
                                    from public.portal_acessos_envios e where lower(e.email) = ct.email order by e.enviado_em desc limit 1)) x
          from ct join public.projetos p on p.id = ct.projeto_id
          join public.portal_contratos pc on pc.projeto_id = ct.projeto_id and pc.liberado
          left join logins l on l.email = ct.email
         where ct.email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
           and ct.email not like '%@bvek.com.br' and ct.email not like '%@funcionario.bvek.com.br'
           and (l.id is null or (l.perfil = 'cliente' and l.senha_definida_em is null))
         group by ct.email) s), '[]'::jsonb),
    -- já com acesso ativo (entrou e criou a senha)
    'com_acesso', (select count(distinct ct.email) from ct join logins l on l.email = ct.email
                    where l.perfil = 'cliente' and l.ativo and l.senha_definida_em is not null),
    -- clientes com contrato e sem nenhum contato cadastrado
    'clientes_sem_contato', coalesce((select jsonb_agg(jsonb_build_object('cliente_id', cl.id, 'cliente', cl.nome, 'cliente_codigo', cl.codigo) order by cl.codigo)
        from public.clientes cl
       where exists (select 1 from public.projetos p where p.cliente_id = cl.id)
         and not exists (select 1 from public.contatos x where x.cliente_id = cl.id)), '[]'::jsonb),
    'envio_liberado', (select envio_liberado from public.portal_config where id = 1))
  into r;
  return r;
end $$;
revoke all on function public.bvek_portal_pendencias() from public, anon;
grant execute on function public.bvek_portal_pendencias() to authenticated;

notify pgrst, 'reload schema';

-- Conferência ------------------------------------------------------------------------
select 'coluna portal_contratos.contatos' as item,
       case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'portal_contratos' and column_name = 'contatos') then 'ok' else 'FALTA' end as resultado
union all
select 'campo WABA do WhatsApp', case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'whatsapp_convocacao_config' and column_name = 'meta_waba_id') then 'ok' else 'FALTA' end
union all
select 'funções do portal v72', (select count(*)::text || ' de 5' from pg_proc where proname in ('bvek_contatos_proposta','bvek_portal_contrato_meu','bvek_portal_preparar','bvek_portal_pendencias','bvek_portal_dados'))
union all
select 'envio dos acessos', case when (select envio_liberado from public.portal_config where id = 1) then 'LIGADO' else 'desligado (nenhum e-mail sai)' end
union all
select 'contratos no portal / com contato', (select count(*)::text || ' / ' || count(*) filter (where cardinality(contatos) > 0)::text from public.portal_contratos)
union all
select 'contratos do CRM', (select count(*)::text from public.projetos)
union all
select 'logins de cliente', (select count(*)::text from public.perfis where perfil = 'cliente');
