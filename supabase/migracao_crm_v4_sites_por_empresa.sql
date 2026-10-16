-- =====================================================================
-- CRM Grupo BVEK — migração v4: um site do SharePoint por empresa
-- Regra (16/10/2026):
--   Pastas comuns do grupo (clientes, administrativo, comercial, gestão)
--     -> site "Grupo BVEK":   03_CLIENTES/C###_NOME
--   Projetos ficam no site da empresa executora:
--     EK -> site Engekat:        10.2_PROJETOS/C###-NNNN NOME
--     VB -> site Verdebrasilis:  20.2_PROJETOS/C###-NNNN NOME
--     BL -> site Brasilimp:      30.2_PROJETOS/C###-NNNN NOME
-- O caminho gravado começa pelo nome do site, para saber onde abrir.
-- Pode rodar mais de uma vez sem problema.
-- =====================================================================

create or replace function public.pasta_projeto(p_empresa uuid, p_codigo text, p_nome text) returns text
language sql stable as $$
  select case e.sigla
           when 'EK' then 'Engekat/10.2_PROJETOS/'
           when 'VB' then 'Verdebrasilis/20.2_PROJETOS/'
           when 'BL' then 'Brasilimp/30.2_PROJETOS/'
         end || p_codigo || ' ' || upper(trim(p_nome))
  from public.empresas e where e.id = p_empresa
$$;

-- Atualiza os caminhos já gravados (troca só o prefixo antigo)
update public.projetos set pasta_rede = regexp_replace(pasta_rede, '^BVEK/10_ENGEKAT/10\.2_PROJETOS/', 'Engekat/10.2_PROJETOS/')
 where pasta_rede like 'BVEK/10_ENGEKAT/%';
update public.projetos set pasta_rede = regexp_replace(pasta_rede, '^BVEK/20_VERDE BRASILIS/20\.2_PROJETOS/', 'Verdebrasilis/20.2_PROJETOS/')
 where pasta_rede like 'BVEK/20_VERDE BRASILIS/%';
update public.projetos set pasta_rede = regexp_replace(pasta_rede, '^BVEK/30_BRASILIMP/30\.2_PROJETOS/', 'Brasilimp/30.2_PROJETOS/')
 where pasta_rede like 'BVEK/30_BRASILIMP/%';

-- Conferência
select codigo, pasta_rede from public.projetos order by codigo;
