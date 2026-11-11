-- =====================================================================
-- CRM Grupo BVEK — migração v55 (11/11/2026)
-- Perfil novo: ESTAGIÁRIO
--   Vê e usa só: Painel da equipe, Tarefas, Cronograma (com a agenda do
--   escritório), Inventário e Fornecedores.
--   • Tarefas: igual ao Comercial/Administrativo (só as tarefas da equipe;
--     as marcadas "só administradores" ficam escondidas).
--   • Cronograma: vê, cria e altera alocações e eventos do escritório
--     (não apaga). Dos funcionários vê só nome, cargo e empresa.
--   • Inventário e Fornecedores: cadastra e altera (não apaga; itens e
--     fornecedores se "desativam", como para os outros perfis).
--   • Clientes e projetos: só a leitura do nome/código, para escolher na
--     alocação e na tarefa (a aba Projetos e a aba Clientes não aparecem).
--   • NÃO vê: funil, propostas, valores, contratos, financeiro, RH,
--     documentos, currículos, diário de obra, usuários.
--
-- Como funciona: só ACRESCENTA regras novas ("bvek_estag_*") — as regras
-- que já existem para os outros perfis não são alteradas.
-- Rode DEPOIS da v54. Pode rodar mais de uma vez. Nada é apagado.
--
-- Depois de rodar: publique de novo as funções "convocacao" e
-- "outlook-agenda" (o estagiário passa a poder avisar a equipe e
-- sincronizar o Outlook pelo Cronograma).
-- =====================================================================

-- 1. PERFIL NOVO ---------------------------------------------------------------
alter table public.perfis drop constraint if exists perfis_perfil_chk;
alter table public.perfis add constraint perfis_perfil_chk
  check (perfil in ('pendente','administrador','comercial','administrativo','contabilidade','estagiario','funcionario'));

-- 2. REGRAS EXTRAS SÓ PARA O ESTAGIÁRIO ------------------------------------------
--    (ler, inserir, alterar, apagar) — '-' = não pode
do $$
declare r record;
begin
  for r in select * from (values
    ('cronograma',        'sim', 'sim', 'sim', '-'),
    ('agenda_escritorio', 'sim', 'sim', 'sim', '-'),
    ('inventario_itens',  'sim', 'sim', 'sim', '-'),
    ('inventario_os',     'sim', 'sim', 'sim', 'sim'),
    ('fornecedores',      'sim', 'sim', 'sim', '-'),
    ('materiais',         'sim', 'sim', 'sim', '-'),
    ('precos_fornecedor', 'sim', 'sim', 'sim', 'sim'),
    ('clientes',          'sim', '-',   '-',   '-'),
    ('projetos',          'sim', '-',   '-',   '-')
  ) as t(tabela, ler, ins, upd, del)
  loop
    continue when to_regclass('public.' || r.tabela) is null;
    execute format('drop policy if exists bvek_estag_ler on public.%I', r.tabela);
    execute format('drop policy if exists bvek_estag_inserir on public.%I', r.tabela);
    execute format('drop policy if exists bvek_estag_alterar on public.%I', r.tabela);
    execute format('drop policy if exists bvek_estag_apagar on public.%I', r.tabela);
    if r.ler = 'sim' then
      execute format('create policy bvek_estag_ler on public.%I for select to authenticated using (public.bvek_pode(''{estagiario}''::text[]))', r.tabela);
    end if;
    if r.ins = 'sim' then
      execute format('create policy bvek_estag_inserir on public.%I for insert to authenticated with check (public.bvek_pode(''{estagiario}''::text[]))', r.tabela);
    end if;
    if r.upd = 'sim' then
      execute format('create policy bvek_estag_alterar on public.%I for update to authenticated using (public.bvek_pode(''{estagiario}''::text[])) with check (public.bvek_pode(''{estagiario}''::text[]))', r.tabela);
    end if;
    if r.del = 'sim' then
      execute format('create policy bvek_estag_apagar on public.%I for delete to authenticated using (public.bvek_pode(''{estagiario}''::text[]))', r.tabela);
    end if;
  end loop;
end $$;

-- tarefas: só as da equipe (como Comercial e Administrativo)
drop policy if exists bvek_estag_ler     on public.atividades;
drop policy if exists bvek_estag_inserir on public.atividades;
drop policy if exists bvek_estag_alterar on public.atividades;
drop policy if exists bvek_estag_apagar  on public.atividades;
create policy bvek_estag_ler on public.atividades for select to authenticated
  using (public.bvek_pode('{estagiario}') and visibilidade = 'equipe');
create policy bvek_estag_inserir on public.atividades for insert to authenticated
  with check (public.bvek_pode('{estagiario}') and visibilidade = 'equipe');
create policy bvek_estag_alterar on public.atividades for update to authenticated
  using (public.bvek_pode('{estagiario}') and visibilidade = 'equipe')
  with check (public.bvek_pode('{estagiario}') and visibilidade = 'equipe');
create policy bvek_estag_apagar on public.atividades for delete to authenticated
  using (public.bvek_pode('{estagiario}') and visibilidade = 'equipe');

-- 3. FUNÇÕES DO CRONOGRAMA (mesmo conteúdo de antes + estagiário) ------------------
-- resumo dos avisos da convocação (v47)
create or replace function public.bvek_cronograma_avisos(p_ids uuid[])
returns table (cronograma_id uuid, funcionario_id uuid, tipo text, canal text, ok boolean, erro text, enviado_em timestamptz, enviado_por text)
language sql stable security definer set search_path = public as $$
  select a.cronograma_id, a.funcionario_id, a.tipo, a.canal, a.ok, a.erro, a.enviado_em, a.enviado_por
    from public.cronograma_avisos a
   where a.cronograma_id = any(p_ids)
     and public.bvek_pode('{administrador,comercial,administrativo,contabilidade,estagiario}'::text[])
   order by a.enviado_em desc
$$;
revoke all on function public.bvek_cronograma_avisos(uuid[]) from public, anon;
grant execute on function public.bvek_cronograma_avisos(uuid[]) to authenticated;

-- resumo dos avisos do evento do escritório (v54)
create or replace function public.bvek_escritorio_avisos(p_id uuid)
returns table (email text, funcionario_id uuid, nome text, tipo text, ok boolean, erro text, enviado_em timestamptz, enviado_por text)
language sql stable security definer set search_path = public as $$
  select a.email, a.funcionario_id, a.nome, a.tipo, a.ok, a.erro, a.enviado_em, a.enviado_por
    from public.agenda_escritorio_avisos a
   where a.evento_id = p_id
     and public.bvek_pode('{administrador,comercial,administrativo,contabilidade,estagiario}'::text[])
   order by a.enviado_em desc
$$;
revoke all on function public.bvek_escritorio_avisos(uuid) from public, anon;
grant execute on function public.bvek_escritorio_avisos(uuid) to authenticated;

-- quem pode ser convidado para os eventos do escritório (v53): o estagiário também
create or replace function public.bvek_pessoas_agenda()
returns table (nome text, email text, tem_celular boolean)
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim(p.nome), ''), split_part(p.email, '@', 1)) as nome,
         lower(trim(p.email)) as email,
         exists (
           select 1 from public.funcionarios f
            where f.ativo is not false
              and length(regexp_replace(coalesce(f.celular, ''), '\D', '', 'g')) >= 10
              and (lower(trim(f.email)) = lower(trim(p.email))
                   or (nullif(trim(p.nome), '') is not null and lower(trim(f.nome)) = lower(trim(p.nome))))
         ) as tem_celular
    from public.perfis p
   where public.bvek_ativo()
     and p.ativo is not false
     and p.perfil in ('administrador','comercial','administrativo','contabilidade','estagiario','consulta')
     and p.email is not null
     and p.email not ilike '%@funcionario.bvek.com.br'
   order by 1;
$$;
revoke all on function public.bvek_pessoas_agenda() from public, anon;
grant execute on function public.bvek_pessoas_agenda() to authenticated;

-- Conferência: regras novas do estagiário por tabela (deve aparecer cada tabela)
select tablename as tabela,
       string_agg(replace(policyname, 'bvek_estag_', ''), ', ' order by policyname) as o_estagiario_pode
  from pg_policies
 where schemaname = 'public' and policyname like 'bvek_estag_%'
 group by tablename
 order by tablename;
