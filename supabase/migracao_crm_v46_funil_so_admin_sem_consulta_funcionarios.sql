-- =====================================================================
-- CRM Grupo BVEK — migração v46 (04/11/2026)
-- 1. FUNIL, PROPOSTAS, VALORES E CONTRATOS SÓ PARA O ADMINISTRADOR
--    Os outros perfis (Comercial, Administrativo, Contabilidade) deixam de
--    receber do banco as propostas (cards), os itens, o histórico do funil,
--    os contratos fixos e os PDFs das propostas. Clientes e projetos continuam
--    liberados para todos.
-- 2. PERFIL "CONSULTA" REMOVIDO
--    Quem estava como Consulta passa para "Aguardando liberação" (perde o
--    acesso até o administrador escolher outro perfil em Usuários). A lista
--    de quem foi movido aparece no final. Nada é apagado.
-- 3. CADASTRO DE FUNCIONÁRIOS PROTEGIDO
--    O cadastro completo (CPF, PIS, endereço, e-mail etc.) e os documentos
--    dos funcionários (e os arquivos deles) só para Administrador,
--    Administrativo e Contabilidade. Os outros perfis recebem só nome, cargo
--    e empresa (função bvek_funcionarios_basico), para o Cronograma.
--    Documentos das EMPRESAS continuam visíveis para todos.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada.
-- =====================================================================

-- 1. FUNIL SÓ PARA O ADMINISTRADOR -----------------------------------------
create or replace function public.bvek_ve_valores() returns boolean
language sql stable security definer set search_path = public as $$
  select public.bvek_pode('{administrador}')
$$;
grant execute on function public.bvek_ve_valores() to authenticated;

create or replace function public.bvek_cards(p_id uuid default null, p_raiz uuid default null)
returns setof jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(c)
         || jsonb_build_object(
              'clientes', (select to_jsonb(cl) from public.clientes cl where cl.id = c.cliente_id),
              'empresas', (select to_jsonb(e)  from public.empresas e  where e.id  = c.empresa_id))
    from public.cards c
   where public.bvek_pode('{administrador}')
     and (p_id   is null or c.id = p_id)
     and (p_raiz is null or c.id = p_raiz or c.card_pai_id = p_raiz)
   order by c.criado_em desc
$$;
grant execute on function public.bvek_cards(uuid, uuid) to authenticated;

create or replace function public.bvek_itens_proposta(p_card uuid)
returns setof jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(i)
    from public.itens_proposta i
   where i.card_id = p_card
     and public.bvek_pode('{administrador}')
   order by i.ordem
$$;
grant execute on function public.bvek_itens_proposta(uuid) to authenticated;

create or replace function public.bvek_contratos()
returns setof jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(k)
    from public.contratos_recorrentes k
   where public.bvek_pode('{administrador}')
   order by k.descricao
$$;
grant execute on function public.bvek_contratos() to authenticated;

-- leitura direta das tabelas do funil: só o administrador
do $$
declare t text;
begin
  foreach t in array array['cards','itens_proposta','historico_etapas','historico_cards','propostas','contratos_recorrentes']
  loop
    continue when to_regclass('public.' || t) is null;
    execute format('drop policy if exists bvek_ler on public.%I', t);
    execute format('create policy bvek_ler on public.%I for select to authenticated using (public.bvek_pode(%L::text[]))', t, '{administrador}');
  end loop;
end $$;

-- contratos fixos: só o administrador grava
drop policy if exists bvek_inserir on public.contratos_recorrentes;
drop policy if exists bvek_alterar on public.contratos_recorrentes;
create policy bvek_inserir on public.contratos_recorrentes for insert to authenticated
  with check (public.bvek_pode('{administrador}'));
create policy bvek_alterar on public.contratos_recorrentes for update to authenticated
  using (public.bvek_pode('{administrador}')) with check (public.bvek_pode('{administrador}'));

-- PDFs das propostas: só o administrador abre e envia (as imagens continuam liberadas)
drop policy if exists propostas_ler on storage.objects;
create policy propostas_ler on storage.objects for select to authenticated
  using (bucket_id = 'propostas' and public.bvek_ativo()
         and (public.bvek_pode('{administrador}') or lower(name) !~ '\.pdf$'));
drop policy if exists propostas_enviar on storage.objects;
create policy propostas_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'propostas' and public.bvek_pode('{administrador}'));

-- parâmetros de preço (BDI, lucro, textos da proposta): sem o perfil Consulta
drop policy if exists bvek_ler on public.precificacao_config;
create policy bvek_ler on public.precificacao_config for select to authenticated
  using (public.bvek_pode('{administrador,administrativo}'));

-- 2. PERFIL CONSULTA REMOVIDO ---------------------------------------------
create temp table if not exists v46_consulta_movidos (email text, nome text);
insert into v46_consulta_movidos select email, nome from public.perfis where perfil = 'consulta';
update public.perfis set perfil = 'pendente', atualizado_em = now() where perfil = 'consulta';
alter table public.perfis drop constraint if exists perfis_perfil_chk;
alter table public.perfis add constraint perfis_perfil_chk
  check (perfil in ('pendente','administrador','comercial','administrativo','contabilidade','funcionario'));

-- 3. CADASTRO DE FUNCIONÁRIOS PROTEGIDO -------------------------------------
drop policy if exists bvek_ler on public.funcionarios;
create policy bvek_ler on public.funcionarios for select to authenticated
  using (public.bvek_pode('{administrador,administrativo,contabilidade}'));

-- só nome, cargo e empresa (para o Cronograma dos outros perfis)
create or replace function public.bvek_funcionarios_basico()
returns table (id uuid, nome text, cargo text, empresa_id uuid, ativo boolean, tem_email boolean)
language sql stable security definer set search_path = public as $$
  select f.id, f.nome, f.cargo, f.empresa_id, f.ativo, (coalesce(trim(f.email), '') like '%@%')
    from public.funcionarios f
   where public.bvek_ativo()
   order by f.nome
$$;
revoke all on function public.bvek_funcionarios_basico() from public, anon;
grant execute on function public.bvek_funcionarios_basico() to authenticated;

-- documentos: os dos funcionários só para quem cuida do RH; os das empresas para todos
drop policy if exists bvek_ler on public.documentos;
create policy bvek_ler on public.documentos for select to authenticated
  using (public.bvek_pode('{administrador,administrativo,contabilidade}')
         or (public.bvek_ativo() and funcionario_id is null));

-- arquivos dos documentos: mesma regra
create or replace function public.bvek_doc_arquivo_da_empresa(p_nome text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.documentos d where d.arquivo = p_nome and d.funcionario_id is null)
$$;
revoke all on function public.bvek_doc_arquivo_da_empresa(text) from public, anon;
grant execute on function public.bvek_doc_arquivo_da_empresa(text) to authenticated;
drop policy if exists documentos_ler on storage.objects;
create policy documentos_ler on storage.objects for select to authenticated
  using (bucket_id = 'documentos'
         and (public.bvek_pode('{administrador,administrativo,contabilidade}')
              or (public.bvek_ativo() and public.bvek_doc_arquivo_da_empresa(name))));

-- Conferência:
--  • "quem lê" de cards e funcionários deve mostrar só os perfis indicados;
--  • "movido de Consulta" lista quem precisa de um perfil novo (em Usuários).
select 'cards (propostas) — quem lê' as item, qual as resultado
  from pg_policies where schemaname = 'public' and tablename = 'cards' and policyname = 'bvek_ler'
union all
select 'funcionários — quem lê', qual
  from pg_policies where schemaname = 'public' and tablename = 'funcionarios' and policyname = 'bvek_ler'
union all
select 'documentos — quem lê', qual
  from pg_policies where schemaname = 'public' and tablename = 'documentos' and policyname = 'bvek_ler'
union all
select 'logins ainda como Consulta (deve ser 0)', count(*)::text from public.perfis where perfil = 'consulta'
union all
select 'movido de Consulta → Aguardando liberação', coalesce(nome, '') || ' <' || coalesce(email, '') || '>'
  from v46_consulta_movidos;
