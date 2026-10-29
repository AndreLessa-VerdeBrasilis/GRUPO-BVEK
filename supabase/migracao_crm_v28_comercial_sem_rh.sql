-- =====================================================================
-- CRM Grupo BVEK — migração v28 (29/10/2026)
-- O perfil Comercial deixa de acessar o RH (benefícios e ponto).
--
-- Antes (v13): Administrador, Administrativo, Contabilidade e Comercial
-- liam os benefícios, os fechamentos do mês e as faltas/ponto lidos do
-- Secullum. Agora só Administrador, Administrativo e Contabilidade.
-- Quem grava continua igual. Nada é apagado.
--
-- (A margem de lucro por dia e a ordem de serviço não precisam de banco:
--  ficam guardadas na composição de preço que já existe no card.)
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada.
-- =====================================================================

begin;

do $$
declare r record;
begin
  for r in select * from (values
    ('tipos_beneficio',         '{administrador,administrativo,contabilidade}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador}'),
    ('funcionario_beneficios',  '{administrador,administrativo,contabilidade}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador,administrativo}'),
    ('competencias_beneficios', '{administrador,administrativo,contabilidade}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador}'),
    ('competencia_funcionarios','{administrador,administrativo,contabilidade}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador,administrativo}'),
    ('competencia_itens',       '{administrador,administrativo,contabilidade}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador,administrativo}')
  ) as t(tabela, ler, ins, upd, del)
  loop
    continue when to_regclass('public.' || r.tabela) is null;
    execute format('alter table public.%I enable row level security', r.tabela);
    execute format('drop policy if exists bvek_ler on public.%I', r.tabela);
    execute format('drop policy if exists bvek_inserir on public.%I', r.tabela);
    execute format('drop policy if exists bvek_alterar on public.%I', r.tabela);
    execute format('drop policy if exists bvek_apagar on public.%I', r.tabela);
    execute format('create policy bvek_ler on public.%I for select to authenticated using (public.bvek_pode(%L::text[]))', r.tabela, r.ler);
    execute format('create policy bvek_inserir on public.%I for insert to authenticated with check (public.bvek_pode(%L::text[]))', r.tabela, r.ins);
    execute format('create policy bvek_alterar on public.%I for update to authenticated using (public.bvek_pode(%L::text[])) with check (public.bvek_pode(%L::text[]))', r.tabela, r.upd, r.upd);
    execute format('create policy bvek_apagar on public.%I for delete to authenticated using (public.bvek_pode(%L::text[]))', r.tabela, r.del);
  end loop;
end $$;

commit;

-- ---------------------------------------------------------------------
-- Conferência: as 5 tabelas devem aparecer SEM "comercial" na coluna quem_le
-- ---------------------------------------------------------------------
select tablename as tabela, qual as quem_le
  from pg_policies
 where schemaname = 'public'
   and policyname = 'bvek_ler'
   and tablename in ('tipos_beneficio','funcionario_beneficios','competencias_beneficios',
                     'competencia_funcionarios','competencia_itens')
 order by 1;
