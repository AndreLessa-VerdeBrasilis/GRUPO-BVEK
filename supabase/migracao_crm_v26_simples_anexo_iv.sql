-- =====================================================================
-- CRM Grupo BVEK — migração v26 (29/10/2026)
-- Parâmetros de preço: Simples Nacional ANEXO IV (correção do André)
--
-- O grupo é tributado no Simples Nacional, Anexo IV (obras, paisagismo,
-- limpeza e conservação). Esta migração troca o regime padrão de III para
-- IV e também as empresas que estavam marcadas como Anexo III. O
-- faturamento dos últimos 12 meses já informado é mantido.
-- Lembrete: no Anexo IV o INSS patronal (CPP) é pago fora do DAS — ele
-- deve estar incluído no custo por dia de cada função.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Rode DEPOIS da v25. Pode rodar mais de uma vez. Nada é apagado.
-- =====================================================================

begin;

-- regime padrão
update public.precificacao_config
   set dados = jsonb_set(dados, '{regime_padrao}', '{"anexo": "IV"}'::jsonb, true),
       atualizado_em = now()
 where id = 1 and coalesce(dados->'regime_padrao'->>'anexo', '') <> 'IV';

-- empresas que estavam no Anexo III passam para o IV (mantém o faturamento)
update public.precificacao_config c
   set dados = jsonb_set(c.dados, '{regime_empresa}',
         (select jsonb_object_agg(k, case when v->>'anexo' = 'III' then jsonb_set(v, '{anexo}', '"IV"'::jsonb) else v end)
            from jsonb_each(c.dados->'regime_empresa') as e(k, v))),
       atualizado_em = now()
 where id = 1
   and exists (select 1 from jsonb_each(c.dados->'regime_empresa') as e(k, v) where v->>'anexo' = 'III');

commit;

-- Conferência: regime padrão deve ser IV e nenhuma empresa no III
select dados->'regime_padrao'->>'anexo' as regime_padrao_deve_ser_IV,
       (select count(*) from jsonb_each(dados->'regime_empresa') as e(k, v) where v->>'anexo' = 'III') as empresas_no_III_deve_ser_0
  from public.precificacao_config where id = 1;
