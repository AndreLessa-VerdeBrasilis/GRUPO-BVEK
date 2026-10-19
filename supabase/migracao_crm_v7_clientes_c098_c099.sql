-- =====================================================================
-- CRM Grupo BVEK — 19/10/2026
-- Clientes encontrados nas notas fiscais dos e-mails:
--   C098 QUALITY WELDING (concorrente que nos quarteirizou um serviço)
--   C099 FIOCRUZ (NFs emitidas para o Consórcio Facility Maré)
-- Pode rodar de novo sem duplicar nada.
-- =====================================================================
insert into public.clientes (codigo, nome, endereco, empresas_atendidas, situacao, observacoes, referencias_rede)
select x.codigo, x.nome, null, x.empresas, 'Cliente', x.obs, x.refs
from (values
  ('C098','QUALITY WELDING','VB',
   'QUALITY WELDING SERVIÇOS S.A. – CNPJ 02.855.701/0001-38. Concorrente que quarteirizou um serviço para nós. NFS-e 0483 (16/05/2025, R$ 127.208,00).',
   'Grupo BVEK/03_CLIENTES/C098_QUALITY WELDING'),
  ('C099','FIOCRUZ','EK/VB',
   'Serviços contratados via Consórcio Facility Maré (CNPJ 53.851.890/0001-01). Proposta PCEK3005.5V0 (MPE Facility – obra civil). NFS-e 0499 e 0500 (VB, R$ 23.500,00 cada).',
   'Grupo BVEK/03_CLIENTES/C099_FIOCRUZ')
) as x(codigo, nome, empresas, obs, refs)
where not exists (select 1 from public.clientes c where c.codigo = x.codigo);

-- Conferência
select codigo, nome, situacao, ativo from public.clientes where codigo in ('C098','C099') order by codigo;
