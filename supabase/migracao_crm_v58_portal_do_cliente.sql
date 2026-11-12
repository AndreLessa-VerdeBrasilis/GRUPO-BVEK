-- =====================================================================
-- CRM Grupo BVEK — migração v58 (12/11/2026)
-- PORTAL DO CLIENTE (login com e-mail e senha)
--   • Perfil novo "cliente": cada login fica ligado a UM cliente do CRM
--     (perfis.cliente_id). Um cliente pode ter vários logins (um por
--     contato). Só o Administrador cria, pelo cadastro do cliente.
--   • O cliente vê só os CONTRATOS que o escritório liberar, e em cada um
--     só o que estiver marcado (tabela portal_contratos):
--       proposta (o PDF guardado na proposta escolhida), ordem de serviço
--       (sem valores), diário de obra (só os dias conferidos e FECHADOS,
--       com fotos, sem áudio), documentos da empresa executora escolhidos
--       um a um (certidões etc.) e os arquivos do contrato.
--   • Arquivos do contrato (tabela portal_arquivos, pasta privada
--     "portal"): documentos de início (contrato assinado, ART/RRT, ordem
--     de início…), medições e notas fiscais. Cada um com "visível ao
--     cliente".
--   • Os dados do próprio cliente (código, razão social, CNPJ, endereço)
--     aparecem sempre, só para leitura.
--   • O cliente NÃO vê nada mais do CRM (funil, valores, outros clientes,
--     RH…): as tabelas que liberam a leitura para "qualquer login do
--     escritório" ficam fechadas para ele, como para o Funcionário.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Rode DEPOIS da v57. Pode rodar mais de uma vez sem duplicar nada.
-- =====================================================================

-- 1. PERFIL NOVO ---------------------------------------------------------------
alter table public.perfis add column if not exists cliente_id uuid references public.clientes(id) on delete set null;
create index if not exists perfis_cliente_idx on public.perfis (cliente_id);
alter table public.perfis drop constraint if exists perfis_perfil_chk;
alter table public.perfis add constraint perfis_perfil_chk
  check (perfil in ('pendente','administrador','comercial','administrativo','contabilidade','estagiario','consultoria_iso','funcionario','cliente'));

create or replace function public.bvek_ativo() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.bvek_perfil() not in ('funcionario','consultoria_iso','cliente'), false)
$$;
grant execute on function public.bvek_ativo() to authenticated;

-- o cliente do login (null = não é login de cliente)
create or replace function public.bvek_meu_cliente_id() returns uuid
language sql stable security definer set search_path = public as $$
  select p.cliente_id from public.perfis p
   where p.id = auth.uid() and p.ativo and p.perfil = 'cliente'
$$;
revoke all on function public.bvek_meu_cliente_id() from public, anon;
grant execute on function public.bvek_meu_cliente_id() to authenticated;

-- 2. O QUE CADA CONTRATO MOSTRA NO PORTAL -----------------------------------------
create table if not exists public.portal_contratos (
  projeto_id      uuid primary key references public.projetos(id) on delete cascade,
  liberado        boolean not null default false,  -- o contrato aparece no portal
  ver_proposta    boolean not null default false,
  card_id         uuid references public.cards(id) on delete set null,  -- proposta mostrada
  ver_os          boolean not null default false,
  ver_diario      boolean not null default false,
  ver_documentos  boolean not null default false,  -- documentos da empresa executora
  documentos      uuid[]  not null default '{}',   -- quais documentos (ids)
  ver_inicio      boolean not null default false,  -- documentos de início
  ver_medicoes    boolean not null default false,  -- medições e notas fiscais
  atualizado_por  text,
  atualizado_em   timestamptz not null default now()
);

create table if not exists public.portal_arquivos (
  id              uuid primary key default gen_random_uuid(),
  projeto_id      uuid not null references public.projetos(id) on delete cascade,
  categoria       text not null default 'inicio',  -- inicio | medicao | nota_fiscal
  titulo          text not null,
  numero          text,
  data_documento  date,
  caminho         text not null,                   -- pasta "portal"
  arquivo_nome    text,
  visivel         boolean not null default true,   -- aparece para o cliente
  criado_por      text,
  criado_em       timestamptz not null default now()
);
alter table public.portal_arquivos drop constraint if exists portal_arquivos_cat_chk;
alter table public.portal_arquivos add constraint portal_arquivos_cat_chk check (categoria in ('inicio','medicao','nota_fiscal'));
create index if not exists portal_arquivos_projeto_idx on public.portal_arquivos (projeto_id);

do $$
declare t text;
begin
  foreach t in array array['portal_contratos','portal_arquivos'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists bvek_ler on public.%I', t);
    execute format('drop policy if exists bvek_inserir on public.%I', t);
    execute format('drop policy if exists bvek_alterar on public.%I', t);
    execute format('drop policy if exists bvek_apagar on public.%I', t);
    execute format('create policy bvek_ler on public.%I for select to authenticated using (public.bvek_pode(''{administrador}''::text[]))', t);
    execute format('create policy bvek_inserir on public.%I for insert to authenticated with check (public.bvek_pode(''{administrador}''::text[]))', t);
    execute format('create policy bvek_alterar on public.%I for update to authenticated using (public.bvek_pode(''{administrador}''::text[])) with check (public.bvek_pode(''{administrador}''::text[]))', t);
    execute format('create policy bvek_apagar on public.%I for delete to authenticated using (public.bvek_pode(''{administrador}''::text[]))', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- pasta privada dos arquivos do contrato
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('portal', 'portal', false, 26214400,
        array['application/pdf','image/jpeg','image/png','image/webp',
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              'application/xml','text/xml'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- 3. O CLIENTE PODE ABRIR ESTE ARQUIVO? -------------------------------------------
create or replace function public.bvek_portal_pode_arquivo(p_bucket text, p_nome text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_cli uuid := public.bvek_meu_cliente_id();
begin
  if v_cli is null or p_nome is null then return false; end if;
  if p_bucket = 'propostas' then
    return exists (select 1 from public.portal_contratos pc
                     join public.projetos p on p.id = pc.projeto_id
                     join public.cards c on c.id = pc.card_id
                    where p.cliente_id = v_cli and pc.liberado and pc.ver_proposta and c.arquivo_proposta = p_nome);
  elsif p_bucket = 'documentos' then
    return exists (select 1 from public.portal_contratos pc
                     join public.projetos p on p.id = pc.projeto_id
                     join public.documentos d on d.id = any(pc.documentos)
                    where p.cliente_id = v_cli and pc.liberado and pc.ver_documentos
                      and d.funcionario_id is null and d.situacao = 'vigente' and d.arquivo = p_nome);
  elsif p_bucket = 'diarios' then
    -- só as FOTOS dos dias fechados (o áudio nunca vai para o cliente)
    return exists (select 1 from public.diarios_obra d
                     join public.portal_contratos pc on pc.projeto_id = d.projeto_id
                     join public.projetos p on p.id = d.projeto_id
                    where p.cliente_id = v_cli and pc.liberado and pc.ver_diario and d.situacao = 'fechado'
                      and d.id::text = split_part(p_nome, '/', 1)
                      and (exists (select 1 from jsonb_array_elements(coalesce(d.fotos, '[]'::jsonb)) f where f->>'caminho' = p_nome)
                           or exists (select 1 from jsonb_array_elements(coalesce(d.registros, '[]'::jsonb)) r where r->>'foto' = p_nome)));
  elsif p_bucket = 'portal' then
    return exists (select 1 from public.portal_arquivos a
                     join public.portal_contratos pc on pc.projeto_id = a.projeto_id
                     join public.projetos p on p.id = a.projeto_id
                    where p.cliente_id = v_cli and pc.liberado and a.visivel and a.caminho = p_nome
                      and ((a.categoria = 'inicio' and pc.ver_inicio) or (a.categoria in ('medicao','nota_fiscal') and pc.ver_medicoes)));
  end if;
  return false;
end $$;
revoke all on function public.bvek_portal_pode_arquivo(text, text) from public, anon;
grant execute on function public.bvek_portal_pode_arquivo(text, text) to authenticated;

drop policy if exists portal_cliente_ler on storage.objects;
create policy portal_cliente_ler on storage.objects for select to authenticated
  using (bucket_id in ('propostas','documentos','diarios','portal')
         and public.bvek_pode('{cliente}') and public.bvek_portal_pode_arquivo(bucket_id, name));

drop policy if exists portal_ler on storage.objects;
drop policy if exists portal_enviar on storage.objects;
drop policy if exists portal_alterar on storage.objects;
drop policy if exists portal_apagar on storage.objects;
create policy portal_ler on storage.objects for select to authenticated
  using (bucket_id = 'portal' and public.bvek_pode('{administrador}'));
create policy portal_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'portal' and public.bvek_pode('{administrador}'));
create policy portal_alterar on storage.objects for update to authenticated
  using (bucket_id = 'portal' and public.bvek_pode('{administrador}'));
create policy portal_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'portal' and public.bvek_pode('{administrador}'));

-- 4. A OS TAMBÉM PARA O CLIENTE (contrato liberado com "Ordem de serviço") ----------
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
                   and p.cliente_id = public.bvek_meu_cliente_id()))) then
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

-- 5. TUDO O QUE O CLIENTE VÊ, NUMA CHAMADA (sem valores além do PDF da proposta) ----
create or replace function public.bvek_portal_dados() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cli uuid := public.bvek_meu_cliente_id(); r jsonb;
begin
  if v_cli is null then return null; end if;
  select jsonb_build_object(
    'cliente', (select jsonb_build_object('codigo', cl.codigo, 'nome', cl.nome, 'razao_social', cl.razao_social,
                                          'documento', cl.documento, 'endereco', cl.endereco,
                                          'email', to_jsonb(cl)->>'email', 'telefone', to_jsonb(cl)->>'telefone')
                  from public.clientes cl where cl.id = v_cli),
    'contratos', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'codigo', p.codigo, 'nome', p.nome, 'local', p.local, 'status', p.status, 'ano', p.ano,
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
        order by p.codigo desc)
      from public.projetos p
      join public.portal_contratos pc on pc.projeto_id = p.id and pc.liberado
      left join public.empresas e on e.id = p.empresa_id
     where p.cliente_id = v_cli), '[]'::jsonb))
  into r;
  return r;
end $$;
revoke all on function public.bvek_portal_dados() from public, anon;
grant execute on function public.bvek_portal_dados() to authenticated;

-- 6. CRIAR O LOGIN DO CLIENTE (só o Administrador, pelo cadastro do cliente) ----------
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
     set perfil = 'cliente', ativo = true, cliente_id = excluded.cliente_id,
         nome = coalesce(excluded.nome, public.perfis.nome), email = excluded.email
   where public.perfis.perfil in ('pendente', 'cliente');
  return v_email;
end $$;
revoke all on function public.bvek_criar_acesso_cliente(uuid, text, text, text) from public, anon;
grant execute on function public.bvek_criar_acesso_cliente(uuid, text, text, text) to authenticated;

-- Conferência ------------------------------------------------------------------------
select 'tabelas do portal' as item,
       (select count(*)::text || ' de 2' from information_schema.tables where table_schema = 'public' and table_name in ('portal_contratos','portal_arquivos')) as resultado
union all
select 'funções do portal', (select count(*)::text || ' de 4' from pg_proc where proname in ('bvek_meu_cliente_id','bvek_portal_pode_arquivo','bvek_portal_dados','bvek_criar_acesso_cliente'))
union all
select 'pasta privada "portal"', case when exists (select 1 from storage.buckets where id = 'portal' and not public) then 'ok' else 'FALTA' end
union all
select 'perfil "cliente" aceito', case when pg_get_constraintdef((select oid from pg_constraint where conname = 'perfis_perfil_chk')) like '%cliente%' then 'ok' else 'FALTA' end
union all
select 'logins de cliente já criados', (select count(*)::text from public.perfis where perfil = 'cliente');
