-- =====================================================================
-- CRM Grupo BVEK — 19/10/2026
-- 1) C100 SENAC CAMPO GRANDE (NFS-e 0501 – quem paga é o SENAC ARRJ / centro)
-- 2) Projetos da Engekat: C098-0023 (Quality Welding) e C099-0024 (Fiocruz)
-- 3) C098 passa a constar como EK/VB (executado pela EK, faturado pela VB)
-- Pode rodar de novo sem duplicar nada.
-- =====================================================================
insert into public.clientes (codigo, nome, endereco, empresas_atendidas, situacao, observacoes, referencias_rede)
select 'C100', 'SENAC CAMPO GRANDE', 'Campo Grande, RJ', 'VB', 'Cliente',
       'NFS-e 0501 (04/09/2025, R$ 30.936,00, pedido de compra 129302). Tomador/pagador: SENAC ARRJ (CNPJ 03.672.347/0001-79, Rua Marquês de Abrantes 99 – Flamengo).',
       'Grupo BVEK/03_CLIENTES/C100_SENAC CAMPO GRANDE'
where not exists (select 1 from public.clientes where codigo = 'C100');

update public.clientes set empresas_atendidas = 'EK/VB' where codigo = 'C098';

insert into public.projetos (seq, codigo, cliente_id, empresa_id, nome, local, ano, status, pasta_rede)
select x.seq, x.codigo, c.id, e.id, x.nome, x.local, x.ano, x.status,
       public.pasta_projeto(e.id, x.codigo, x.nome)
from (values
  (23,'C098-0023','C098','QUALITY WELDING REPARO DE TELHADOS VIBRA',null,2025,'Concluído'),
  (24,'C099-0024','C099','FIOCRUZ ADEQUACAO DE SALAS E INSTALACAO DE SUPORTES','Rua São Francisco Xavier, 603 – Maracanã, RJ',2025,'Concluído')
) as x(seq, codigo, cli, nome, local, ano, status)
join public.clientes c on c.codigo = x.cli
join public.empresas e on e.sigla = 'EK'
where not exists (select 1 from public.projetos p where p.codigo = x.codigo);

-- O próximo projeto criado pelo CRM recebe 0025
select setval('public.projetos_seq', greatest((select max(seq) from public.projetos), 24));

-- Conferência
select codigo, nome, empresas_atendidas, situacao from public.clientes where codigo in ('C098','C099','C100') order by codigo;
select codigo, nome, status, pasta_rede from public.projetos where seq >= 23 order by seq;
