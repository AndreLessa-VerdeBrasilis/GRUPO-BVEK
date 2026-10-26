-- =====================================================================
-- CRM Grupo BVEK — migração v16 (26/10/2026)
--  1. FOLHA DO MÊS: cada competência passa a ter a lista de quem entra
--     naquele mês. Funcionários CLT e sócios entram sozinhos; os de contrato
--     INTERMITENTE só entram quando forem incluídos no mês (com os dias de
--     convocação). Coluna competencia_funcionarios.na_folha:
--        vazio = segue o padrão do contrato · true = incluído · false = fora
--  2. Benefício de academia: "Academia (Wellhub / Gympass)" passa a
--     "Academia (TotalPass)" (o cadastro dos funcionários continua ligado).
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

alter table public.competencia_funcionarios add column if not exists na_folha boolean;

update public.tipos_beneficio set nome = 'Academia (TotalPass)'
 where nome = 'Academia (Wellhub / Gympass)'
   and not exists (select 1 from public.tipos_beneficio where nome = 'Academia (TotalPass)');

commit;

-- Conferência
select (select count(*) from information_schema.columns where table_schema = 'public'
         and table_name = 'competencia_funcionarios' and column_name = 'na_folha')      as coluna_na_folha_deve_ser_1,
       (select string_agg(nome, ', ') from public.tipos_beneficio where nome ilike 'Academia%') as academia_deve_ser_totalpass;
