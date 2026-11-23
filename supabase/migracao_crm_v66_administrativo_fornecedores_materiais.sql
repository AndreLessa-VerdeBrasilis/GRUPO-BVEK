-- =====================================================================
-- CRM Grupo BVEK — migração v66 (23/11/2026)
-- Perfil ADMINISTRATIVO passa a cadastrar materiais e fornecedores
--
--   • Fornecedores e materiais: cadastra e altera (não apaga — eles se
--     "desativam", como para os outros perfis).
--   • Preços dos fornecedores: registra, altera e apaga preços
--     (igual ao Comercial e ao Estagiário).
--   • Ver, o Administrativo já via desde a v22.
--
-- Como funciona: só ACRESCENTA regras novas ("bvek_admv_*") — as regras
-- que já existem para os outros perfis não são alteradas.
-- Pode rodar mais de uma vez. Nada é apagado.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- =====================================================================

begin;

do $$
declare r record;
begin
  for r in select * from (values
    ('fornecedores',      'sim', 'sim', '-'),
    ('materiais',         'sim', 'sim', '-'),
    ('precos_fornecedor', 'sim', 'sim', 'sim')
  ) as t(tabela, ins, upd, del)
  loop
    continue when to_regclass('public.' || r.tabela) is null;
    execute format('drop policy if exists bvek_admv_inserir on public.%I', r.tabela);
    execute format('drop policy if exists bvek_admv_alterar on public.%I', r.tabela);
    execute format('drop policy if exists bvek_admv_apagar on public.%I', r.tabela);
    if r.ins = 'sim' then
      execute format('create policy bvek_admv_inserir on public.%I for insert to authenticated with check (public.bvek_pode(''{administrativo}''::text[]))', r.tabela);
    end if;
    if r.upd = 'sim' then
      execute format('create policy bvek_admv_alterar on public.%I for update to authenticated using (public.bvek_pode(''{administrativo}''::text[])) with check (public.bvek_pode(''{administrativo}''::text[]))', r.tabela);
    end if;
    if r.del = 'sim' then
      execute format('create policy bvek_admv_apagar on public.%I for delete to authenticated using (public.bvek_pode(''{administrativo}''::text[]))', r.tabela);
    end if;
  end loop;
end $$;

commit;

-- ---------------------------------------------------------------------
-- Conferência: deve mostrar 7 regras (2 fornecedores, 2 materiais, 3 preços)
-- ---------------------------------------------------------------------
select tablename as tabela, policyname as regra, cmd as acao
  from pg_policies
 where schemaname = 'public'
   and policyname like 'bvek_admv_%'
   and tablename in ('fornecedores','materiais','precos_fornecedor')
 order by tablename, policyname;
