-- =====================================================================
-- CRM Grupo BVEK — 21/10/2026
-- C102 COND ED EL MORIA e C103 MANSARDA CONSTRUCOES
-- (boletos emitidos encontrados no financeiro – lote 4 da organização da rede)
-- Atualiza também as pastas de C023 e C085, criadas agora na rede.
-- Pode rodar de novo sem duplicar nada.
-- =====================================================================
insert into public.clientes (codigo, nome, endereco, empresas_atendidas, situacao, observacoes, referencias_rede)
select 'C102', 'COND ED EL MORIA', null, 'EK/VB', 'Cliente',
       'CONDOMINIO DO EDIFICIO EL MORIA. Recuperação de Fachadas e Pintura (proposta PCEK2103.5, contrato 06/2025); 12 boletos emitidos em 16/07/2025.',
       'Grupo BVEK/03_CLIENTES/C102_COND ED EL MORIA'
where not exists (select 1 from public.clientes where codigo = 'C102');

insert into public.clientes (codigo, nome, endereco, empresas_atendidas, situacao, observacoes, referencias_rede)
select 'C103', 'MANSARDA CONSTRUCOES', null, 'VB', 'Cliente',
       'Mansarda Construções e Reformas LTDA. Boletos emitidos com vencimento 01/11/2024 e 15/11/2024.',
       'Grupo BVEK/03_CLIENTES/C103_MANSARDA CONSTRUCOES'
where not exists (select 1 from public.clientes where codigo = 'C103');

update public.clientes set referencias_rede = 'Grupo BVEK/03_CLIENTES/C023_COND ED MEU BEM' where codigo = 'C023';
update public.clientes set referencias_rede = 'Grupo BVEK/03_CLIENTES/C085_TIEN NIO OEI' where codigo = 'C085';

select codigo, nome, situacao, referencias_rede from public.clientes where codigo in ('C023','C085','C102','C103') order by codigo;
