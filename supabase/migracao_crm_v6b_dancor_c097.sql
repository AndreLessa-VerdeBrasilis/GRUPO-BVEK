-- =====================================================================
-- CRM Grupo BVEK — 19/10/2026
-- 1) DANCOR recebe C097 (o C093 já estava em uso no CRM).
-- 2) C093 MOOVE LUBRIFICANTES é o mesmo cliente do C026 COSAN MOOVE
--    (Ilha Terminal / grupo Cosan): cards, contatos, atividades e
--    projetos passam para o C026; o C093 fica inativo (mesclado),
--    nada é apagado e o código C093 não é reutilizado.
-- Pode rodar de novo sem duplicar nada.
-- =====================================================================

-- 1. Dancor
insert into public.clientes (codigo, nome, endereco, empresas_atendidas, situacao, observacoes, referencias_rede)
select 'C097', 'DANCOR', 'Estação Campinho / Fábrica Sudeste', 'EK', 'Prospect',
       'Proposta PCEK1512.5V0 - adequação da rede de água potável.',
       'notebook andre/Dancor Bombas'
where not exists (select 1 from public.clientes where codigo = 'C097' or nome = 'DANCOR');

-- 2. Mesclar C093 em C026
select public.mesclar_clientes(o.id, d.id)
from public.clientes o, public.clientes d
where o.codigo = 'C093' and d.codigo = 'C026' and o.ativo;

update public.clientes
set observacoes = 'Mesclado em C026 COSAN MOOVE em 19/10/2026 (mesmo cliente).'
where codigo = 'C093' and coalesce(observacoes, '') not like 'Mesclado em C026%';

-- Conferência
select c.codigo, c.nome, c.ativo, c.situacao,
       (select count(*) from public.cards k where k.cliente_id = c.id) as cards
from public.clientes c
where c.codigo in ('C026', 'C093', 'C097')
order by c.codigo;
