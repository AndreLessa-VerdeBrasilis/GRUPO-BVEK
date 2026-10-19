-- =====================================================================
-- CRM Grupo BVEK — 19/10/2026
-- C101 CONDOMINIO LOS ANGELES (encontrado nos anexos de e-mail da VB)
-- Pode rodar de novo sem duplicar nada.
-- =====================================================================
insert into public.clientes (codigo, nome, endereco, empresas_atendidas, situacao, observacoes, referencias_rede)
select 'C101', 'CONDOMINIO LOS ANGELES', null, 'VB', 'Cliente',
       'CONDOMINIO DO EDIFICIO RESIDENCIAL LOS ANGELES – CNPJ 03.276.879/0001-97. Poda de árvores (2ª etapa 02/2023, R$ 8.000,00 em 6 parcelas; em 25/03/2024 só a 1/6 estava paga – NF 402).',
       'Grupo BVEK/03_CLIENTES/C101_CONDOMINIO LOS ANGELES'
where not exists (select 1 from public.clientes where codigo = 'C101');

select codigo, nome, situacao from public.clientes where codigo in ('C100','C101') order by codigo;
select codigo, nome, pasta_rede from public.projetos where seq >= 23 order by seq;
