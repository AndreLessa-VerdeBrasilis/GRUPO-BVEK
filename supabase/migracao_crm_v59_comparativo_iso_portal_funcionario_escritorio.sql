-- =====================================================================
-- CRM Grupo BVEK — migração v59 (13/11/2026)
--   1. NORMAS ISO — versões do texto da lei e comparativo
--      • Tabela iso_requisitos_versoes: o texto de cada versão de uma lei,
--        decreto ou requisito (v1 = o que já valia; v2, v3… = alterações),
--        com "o que mudou" e "o que muda para nós". O CRM compara duas
--        versões e mostra o que entrou, o que saiu e o que mudou de redação.
--      • Administrador e Consultoria ISO cadastram (só o administrador apaga).
--   2. PORTAL DO CLIENTE — um login para vários clientes
--      • perfis.clientes_extras: outros clientes que o mesmo login vê (ex.: o
--        mesmo contato em todas as unidades da FGV). O login continua ligado
--        ao cliente principal (perfis.cliente_id).
--      • Criar acesso com um e-mail que já entra por outro cliente agora SOMA
--        o cliente novo ao login (antes trocava de cliente).
--   3. PERFIL "FUNCIONÁRIO DO ESCRITÓRIO" (login por CPF + tarefas)
--      • perfis.ve_tarefas: o login por CPF (perfil funcionario) também vê
--        as tarefas da equipe (as "só administradores" ficam escondidas):
--        cria, altera e conclui; não apaga. Tudo o que o funcionário já via
--        continua igual (contracheque, ponto, OS…).
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Rode DEPOIS da v58. Pode rodar mais de uma vez sem duplicar nada.
-- Depois de rodar: publique de novo a função "normas-iso" e publique a
-- função nova "email-proposta" (Edge Functions → Deploy).
-- =====================================================================

-- 1. NORMAS ISO: VERSÕES DO TEXTO -------------------------------------------------
create table if not exists public.iso_requisitos_versoes (
  id            uuid primary key default gen_random_uuid(),
  requisito_id  uuid not null references public.iso_requisitos(id) on delete cascade,
  versao        integer not null,
  nome          text not null,          -- ex.: Decreto 10.936/2022 (substitui o 7.404/2010)
  vigencia      date,                   -- em vigor desde
  link          text,
  texto         text,                   -- texto da lei (ou dos artigos que interessam)
  resumo        text,                   -- o que mudou, em palavras simples
  impacto       text,                   -- o que muda para nós
  criado_por    text,
  criado_em     timestamptz not null default now()
);
create unique index if not exists iso_requisitos_versoes_uk on public.iso_requisitos_versoes (requisito_id, versao);

alter table public.iso_requisitos_versoes enable row level security;
drop policy if exists bvek_ler       on public.iso_requisitos_versoes;
drop policy if exists bvek_inserir   on public.iso_requisitos_versoes;
drop policy if exists bvek_alterar   on public.iso_requisitos_versoes;
drop policy if exists bvek_apagar    on public.iso_requisitos_versoes;
drop policy if exists bvek_isoc_ler     on public.iso_requisitos_versoes;
drop policy if exists bvek_isoc_inserir on public.iso_requisitos_versoes;
drop policy if exists bvek_isoc_alterar on public.iso_requisitos_versoes;
create policy bvek_ler     on public.iso_requisitos_versoes for select to authenticated using (public.bvek_pode('{administrador}'::text[]));
create policy bvek_inserir on public.iso_requisitos_versoes for insert to authenticated with check (public.bvek_pode('{administrador}'::text[]));
create policy bvek_alterar on public.iso_requisitos_versoes for update to authenticated using (public.bvek_pode('{administrador}'::text[])) with check (public.bvek_pode('{administrador}'::text[]));
create policy bvek_apagar  on public.iso_requisitos_versoes for delete to authenticated using (public.bvek_pode('{administrador}'::text[]));
create policy bvek_isoc_ler     on public.iso_requisitos_versoes for select to authenticated using (public.bvek_pode('{consultoria_iso}'::text[]));
create policy bvek_isoc_inserir on public.iso_requisitos_versoes for insert to authenticated with check (public.bvek_pode('{consultoria_iso}'::text[]));
create policy bvek_isoc_alterar on public.iso_requisitos_versoes for update to authenticated using (public.bvek_pode('{consultoria_iso}'::text[])) with check (public.bvek_pode('{consultoria_iso}'::text[]));
grant select, insert, update, delete on public.iso_requisitos_versoes to authenticated;
revoke all on public.iso_requisitos_versoes from anon;

-- 2. PORTAL DO CLIENTE: UM LOGIN, VÁRIOS CLIENTES ---------------------------------------
alter table public.perfis add column if not exists clientes_extras uuid[] not null default '{}';

-- todos os clientes do login (principal + extras); vazio = não é login de cliente
create or replace function public.bvek_meus_clientes() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce((select array(select distinct x from unnest(array[p.cliente_id] || coalesce(p.clientes_extras, '{}')) x where x is not null)
                     from public.perfis p
                    where p.id = auth.uid() and p.ativo and p.perfil = 'cliente'), '{}'::uuid[])
$$;
revoke all on function public.bvek_meus_clientes() from public, anon;
grant execute on function public.bvek_meus_clientes() to authenticated;

-- o cliente pode abrir este arquivo? (igual à v58, valendo para todos os clientes do login)
create or replace function public.bvek_portal_pode_arquivo(p_bucket text, p_nome text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_clis uuid[] := public.bvek_meus_clientes();
begin
  if cardinality(v_clis) = 0 or p_nome is null then return false; end if;
  if p_bucket = 'propostas' then
    return exists (select 1 from public.portal_contratos pc
                     join public.projetos p on p.id = pc.projeto_id
                     join public.cards c on c.id = pc.card_id
                    where p.cliente_id = any(v_clis) and pc.liberado and pc.ver_proposta and c.arquivo_proposta = p_nome);
  elsif p_bucket = 'documentos' then
    return exists (select 1 from public.portal_contratos pc
                     join public.projetos p on p.id = pc.projeto_id
                     join public.documentos d on d.id = any(pc.documentos)
                    where p.cliente_id = any(v_clis) and pc.liberado and pc.ver_documentos
                      and d.funcionario_id is null and d.situacao = 'vigente' and d.arquivo = p_nome);
  elsif p_bucket = 'diarios' then
    return exists (select 1 from public.diarios_obra d
                     join public.portal_contratos pc on pc.projeto_id = d.projeto_id
                     join public.projetos p on p.id = d.projeto_id
                    where p.cliente_id = any(v_clis) and pc.liberado and pc.ver_diario and d.situacao = 'fechado'
                      and d.id::text = split_part(p_nome, '/', 1)
                      and (exists (select 1 from jsonb_array_elements(coalesce(d.fotos, '[]'::jsonb)) f where f->>'caminho' = p_nome)
                           or exists (select 1 from jsonb_array_elements(coalesce(d.registros, '[]'::jsonb)) r where r->>'foto' = p_nome)));
  elsif p_bucket = 'portal' then
    return exists (select 1 from public.portal_arquivos a
                     join public.portal_contratos pc on pc.projeto_id = a.projeto_id
                     join public.projetos p on p.id = a.projeto_id
                    where p.cliente_id = any(v_clis) and pc.liberado and a.visivel and a.caminho = p_nome
                      and ((a.categoria = 'inicio' and pc.ver_inicio) or (a.categoria in ('medicao','nota_fiscal') and pc.ver_medicoes)));
  end if;
  return false;
end $$;
revoke all on function public.bvek_portal_pode_arquivo(text, text) from public, anon;
grant execute on function public.bvek_portal_pode_arquivo(text, text) to authenticated;

-- a OS (igual à v58, valendo para todos os clientes do login)
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
          or (public.bvek_pode('{cliente}') and exists (
                select 1 from public.portal_contratos pc join public.projetos p on p.id = pc.projeto_id
                 where pc.projeto_id = p_projeto and pc.liberado and pc.ver_os
                   and p.cliente_id = any(public.bvek_meus_clientes())))) then
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

-- tudo o que o cliente vê (igual à v58 + lista "clientes" + cliente de cada contrato)
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
     where p.cliente_id = any(v_clis)), '[]'::jsonb))
  into r;
  return r;
end $$;
revoke all on function public.bvek_portal_dados() from public, anon;
grant execute on function public.bvek_portal_dados() to authenticated;

-- criar o login do cliente: e-mail que já entra por outro cliente SOMA este cliente (não troca)
create or replace function public.bvek_criar_acesso_cliente(p_cliente uuid, p_nome text, p_email text, p_senha text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_nome  text := nullif(trim(coalesce(p_nome, '')), '');
  v_uid   uuid;
  v_perf  text;
begin
  if not public.bvek_pode('{administrador}') then raise exception 'Só o Administrador cria acessos ao portal.'; end if;
  if not exists (select 1 from public.clientes where id = p_cliente) then raise exception 'Cliente não encontrado.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido.'; end if;
  if v_email like '%@funcionario.bvek.com.br' or v_email like '%@bvek.com.br' then
    raise exception 'Use o e-mail do cliente (não um e-mail do grupo).';
  end if;
  select id into v_uid from auth.users where lower(email) = v_email;
  if v_uid is not null then
    select perfil into v_perf from public.perfis where id = v_uid;
    if coalesce(v_perf, 'pendente') not in ('pendente', 'cliente') then
      raise exception 'Este e-mail já é um login do escritório (%). Use outro e-mail.', v_perf;
    end if;
  else
    if length(coalesce(p_senha, '')) < 8 then raise exception 'A senha provisória precisa ter pelo menos 8 caracteres.'; end if;
    v_uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                            email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token, recovery_token,
                            email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
            v_email, extensions.crypt(p_senha, extensions.gen_salt('bf', 10)),
            now(), '{"provider":"email","providers":["email"]}'::jsonb,
            jsonb_build_object('nome', v_nome),
            now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider,
                                 last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_uid, v_uid::text,
            jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true),
            'email', now(), now(), now());
  end if;
  insert into public.perfis (id, email, nome, perfil, ativo, cliente_id)
  values (v_uid, v_email, coalesce(v_nome, split_part(v_email, '@', 1)), 'cliente', true, p_cliente)
  on conflict (id) do update
     set perfil = 'cliente', ativo = true,
         cliente_id = case when public.perfis.perfil = 'cliente' and public.perfis.cliente_id is not null
                           then public.perfis.cliente_id else excluded.cliente_id end,
         clientes_extras = case when public.perfis.perfil = 'cliente' and public.perfis.cliente_id is not null
                                     and public.perfis.cliente_id <> excluded.cliente_id
                                     and not (excluded.cliente_id = any(coalesce(public.perfis.clientes_extras, '{}')))
                                then coalesce(public.perfis.clientes_extras, '{}') || excluded.cliente_id
                                else coalesce(public.perfis.clientes_extras, '{}') end,
         nome = coalesce(public.perfis.nome, excluded.nome), email = excluded.email
   where public.perfis.perfil in ('pendente', 'cliente');
  return v_email;
end $$;
revoke all on function public.bvek_criar_acesso_cliente(uuid, text, text, text) from public, anon;
grant execute on function public.bvek_criar_acesso_cliente(uuid, text, text, text) to authenticated;

-- outros clientes de um login (só o Administrador)
create or replace function public.bvek_acesso_cliente_clientes(p_perfil uuid, p_clientes uuid[])
returns integer
language plpgsql security definer set search_path = public as $$
declare v_pri uuid; v_lista uuid[];
begin
  if not public.bvek_pode('{administrador}') then raise exception 'Só o Administrador altera os acessos ao portal.'; end if;
  select cliente_id into v_pri from public.perfis where id = p_perfil and perfil = 'cliente';
  if not found then raise exception 'Login de cliente não encontrado.'; end if;
  select coalesce(array_agg(distinct c.id), '{}') into v_lista
    from public.clientes c where c.id = any(coalesce(p_clientes, '{}')) and c.id is distinct from v_pri;
  update public.perfis set clientes_extras = v_lista where id = p_perfil;
  return cardinality(v_lista);
end $$;
revoke all on function public.bvek_acesso_cliente_clientes(uuid, uuid[]) from public, anon;
grant execute on function public.bvek_acesso_cliente_clientes(uuid, uuid[]) to authenticated;

-- 3. FUNCIONÁRIO DO ESCRITÓRIO (login por CPF + tarefas) ----------------------------------
alter table public.perfis add column if not exists ve_tarefas boolean not null default false;

create or replace function public.bvek_func_tarefas() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.ve_tarefas from public.perfis p
                    where p.id = auth.uid() and p.ativo and p.perfil = 'funcionario'), false)
$$;
revoke all on function public.bvek_func_tarefas() from public, anon;
grant execute on function public.bvek_func_tarefas() to authenticated;

-- tarefas: só as da equipe; cria, altera e conclui (não apaga)
drop policy if exists bvek_funcesc_ler     on public.atividades;
drop policy if exists bvek_funcesc_inserir on public.atividades;
drop policy if exists bvek_funcesc_alterar on public.atividades;
create policy bvek_funcesc_ler on public.atividades for select to authenticated
  using (public.bvek_func_tarefas() and visibilidade = 'equipe');
create policy bvek_funcesc_inserir on public.atividades for insert to authenticated
  with check (public.bvek_func_tarefas() and visibilidade = 'equipe');
create policy bvek_funcesc_alterar on public.atividades for update to authenticated
  using (public.bvek_func_tarefas() and visibilidade = 'equipe')
  with check (public.bvek_func_tarefas() and visibilidade = 'equipe');

-- as tarefas com o nome do cliente / contrato (sem abrir o cadastro do cliente) e quem pode ser responsável
create or replace function public.bvek_tarefas_funcionario() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.bvek_func_tarefas() then return null; end if;
  return jsonb_build_object(
    'tarefas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', a.id, 'descricao', a.descricao, 'detalhes', a.detalhes, 'tipo', a.tipo, 'status', a.status,
        'prioridade', a.prioridade, 'responsavel', a.responsavel, 'data_prevista', a.data_prevista,
        'checklist', a.checklist, 'etiquetas', a.etiquetas, 'criado_por', a.criado_por, 'concluida_em', a.concluida_em,
        'cliente', case when cl.id is not null then concat_ws(' · ', cl.codigo, cl.nome) end,
        'projeto', case when pr.id is not null then concat_ws(' — ', pr.codigo, pr.nome) end)
        order by a.data_prevista nulls last)
      from public.atividades a
      left join public.clientes cl on cl.id = a.cliente_id
      left join public.projetos pr on pr.id = a.projeto_id
     where a.visibilidade = 'equipe' and a.tipo <> 'nota'
       and (a.status <> 'feito' or a.concluida_em > now() - interval '30 days')), '[]'::jsonb),
    'pessoas', coalesce((select jsonb_agg(distinct coalesce(nullif(trim(p.nome), ''), split_part(p.email, '@', 1)))
      from public.perfis p
     where p.ativo and (p.perfil in ('administrador','comercial','administrativo','contabilidade','estagiario')
                        or (p.perfil = 'funcionario' and p.ve_tarefas))), '[]'::jsonb));
end $$;
revoke all on function public.bvek_tarefas_funcionario() from public, anon;
grant execute on function public.bvek_tarefas_funcionario() to authenticated;

notify pgrst, 'reload schema';

-- Conferência ------------------------------------------------------------------------
select 'tabela de versões das normas ISO' as item,
       case when to_regclass('public.iso_requisitos_versoes') is not null then 'ok' else 'FALTA' end as resultado
union all
select 'portal: login com vários clientes', case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'perfis' and column_name = 'clientes_extras') then 'ok' else 'FALTA' end
union all
select 'funcionário do escritório (tarefas)', case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'perfis' and column_name = 've_tarefas') then 'ok' else 'FALTA' end
union all
select 'funções novas', (select count(*)::text || ' de 4' from pg_proc where proname in ('bvek_meus_clientes','bvek_acesso_cliente_clientes','bvek_func_tarefas','bvek_tarefas_funcionario'))
union all
select 'regras das tarefas para o funcionário do escritório', (select count(*)::text || ' de 3' from pg_policies where schemaname = 'public' and tablename = 'atividades' and policyname like 'bvek_funcesc_%')
union all
select 'logins de cliente com mais de um cliente', (select count(*)::text from public.perfis where perfil = 'cliente' and cardinality(clientes_extras) > 0);
