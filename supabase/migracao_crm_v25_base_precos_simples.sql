-- =====================================================================
-- CRM Grupo BVEK — migração v25 (28/10/2026)
-- Base de preços própria + Simples Nacional nos parâmetros de preço
--
--  1. precos_fornecedor.saida_id: um preço pode nascer de uma compra
--     lançada em Financeiro → Saídas (preço pago de verdade). Cada compra
--     vira no máximo 1 preço (não duplica).
--  2. Parâmetros de preço (pedido do André em 28/10/2026):
--       - margem de lucro padrão de 30% em todos os tipos de cliente
--         (só troca onde ainda estava o exemplo de 10%);
--       - impostos: todas as empresas no Simples Nacional, Anexo III,
--         com alíquota efetiva calculada pelo faturamento dos últimos
--         12 meses (informado na tela de parâmetros).
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Rode DEPOIS das migrações v21, v22 e v23.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

alter table public.precos_fornecedor
  add column if not exists saida_id uuid references public.saidas(id) on delete set null;
create unique index if not exists precos_fornecedor_saida_unq
  on public.precos_fornecedor (saida_id) where saida_id is not null;

-- margem 30% onde ainda está o exemplo (10%)
update public.precificacao_config
   set dados = jsonb_set(dados, '{tipos_cliente}',
         (select coalesce(jsonb_agg(case when (t->>'lucro')::numeric = 10
                                         then jsonb_set(t, '{lucro}', '30'::jsonb) else t end), '[]'::jsonb)
            from jsonb_array_elements(dados->'tipos_cliente') t)),
       atualizado_em = now()
 where id = 1
   and exists (select 1 from jsonb_array_elements(dados->'tipos_cliente') t where (t->>'lucro')::numeric = 10);

-- regime padrão: Simples Nacional, Anexo III (só se ainda não foi definido)
update public.precificacao_config
   set dados = dados || '{"regime_padrao": {"anexo": "III"}, "regime_empresa": {}}'::jsonb,
       atualizado_em = now()
 where id = 1 and not (dados ? 'regime_padrao');

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'precos_fornecedor' and column_name = 'saida_id') as coluna_saida_deve_ser_1,
       (select string_agg(t->>'nome' || ': ' || (t->>'lucro') || '%', ' · ')
          from public.precificacao_config c, jsonb_array_elements(c.dados->'tipos_cliente') t where c.id = 1) as margens,
       (select dados->'regime_padrao' from public.precificacao_config where id = 1)                         as regime_padrao;
