-- =====================================================================
-- CRM Grupo BVEK — migração v29 (29/10/2026)
-- Impostos na composição de preço: regra do André
--   preço = custo total ÷ 0,85  (15% de impostos sobre o preço)
--
-- Troca o regime padrão e o de todas as empresas para "% fixo" = 15.
-- O faturamento dos últimos 12 meses já informado fica guardado (se um
-- dia quiser simular pelo Simples, é só escolher o Anexo de novo em
-- ⚙️ Parâmetros). Composições já guardadas nos cards não mudam: ao
-- abrir de novo, troque a empresa executora ou o campo Impostos para 15.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

-- regime padrão
update public.precificacao_config
   set dados = jsonb_set(dados, '{regime_padrao}', '{"anexo": "manual", "pct": 15}'::jsonb, true),
       atualizado_em = now()
 where id = 1
   and (coalesce(dados->'regime_padrao'->>'anexo', '') <> 'manual'
        or coalesce(dados->'regime_padrao'->>'pct', '') <> '15');

-- cada empresa: % fixo 15 (mantém o faturamento informado)
update public.precificacao_config c
   set dados = jsonb_set(c.dados, '{regime_empresa}',
         (select jsonb_object_agg(k, v || '{"anexo": "manual", "pct": 15}'::jsonb)
            from jsonb_each(c.dados->'regime_empresa') as e(k, v))),
       atualizado_em = now()
 where id = 1
   and jsonb_typeof(c.dados->'regime_empresa') = 'object'
   and exists (select 1 from jsonb_each(c.dados->'regime_empresa') as e(k, v)
                where coalesce(v->>'anexo', '') <> 'manual' or coalesce(v->>'pct', '') <> '15');

commit;

-- ---------------------------------------------------------------------
-- Conferência: regime padrão "manual" com 15 e nenhuma empresa diferente
-- ---------------------------------------------------------------------
select dados->'regime_padrao'->>'anexo' as regime_padrao_deve_ser_manual,
       dados->'regime_padrao'->>'pct'   as imposto_padrao_deve_ser_15,
       (select count(*) from jsonb_each(case when jsonb_typeof(dados->'regime_empresa') = 'object' then dados->'regime_empresa' else '{}'::jsonb end) as e(k, v)
         where coalesce(v->>'anexo', '') <> 'manual' or coalesce(v->>'pct', '') <> '15') as empresas_fora_da_regra_deve_ser_0
  from public.precificacao_config where id = 1;
