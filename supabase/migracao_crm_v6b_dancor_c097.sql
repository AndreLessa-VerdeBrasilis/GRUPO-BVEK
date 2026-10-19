-- =====================================================================
-- CRM Grupo BVEK — DANCOR recebe C097 (o C093 já era do cliente
-- MOOVE LUBRIFICANTES, criado pelo CRM em 16/10/2026).
-- Pode rodar de novo: não duplica.
-- =====================================================================
insert into public.clientes (codigo, nome, endereco, empresas_atendidas, situacao, observacoes, referencias_rede)
select 'C097', 'DANCOR', 'Estação Campinho / Fábrica Sudeste', 'EK', 'Prospect',
       'Proposta PCEK1512.5V0 - adequação da rede de água potável.',
       'notebook andre/Dancor Bombas'
where not exists (select 1 from public.clientes where codigo = 'C097' or nome = 'DANCOR');

select codigo, nome, situacao, empresas_atendidas
from public.clientes where codigo in ('C026','C093','C094','C095','C096','C097') order by codigo;
