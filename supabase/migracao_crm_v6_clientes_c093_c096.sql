-- =====================================================================
-- CRM Grupo BVEK — clientes C093 a C096 (vindos da organização do
-- notebook andre em 19/10/2026) e projetos C096-0021 e C095-0022 (EK).
-- Pode rodar de novo: não duplica nada.
-- =====================================================================

-- 1. Clientes (código fixo, igual ao registro rev7)
insert into public.clientes (codigo, nome, endereco, empresas_atendidas, situacao, observacoes, referencias_rede)
select x.codigo, x.nome, x.endereco, x.empresas, x.situacao, x.obs, x.refs
from (values
  ('C093','DANCOR',            'Estação Campinho / Fábrica Sudeste','EK','Prospect',
     'Proposta PCEK1512.5V0 - adequação da rede de água potável.',
     'notebook andre/Dancor Bombas'),
  ('C094','SAFRAN HELICOPTER', null,                                'EK','Prospect',
     'Proposta PCEK2906.6V0 - utilidades. Pastas de referência do cliente e cotação Zafran em 02_PROPOSTAS.',
     'notebook andre/SAFRAN HELICOPTER'),
  ('C095','GUSTAVO LEBLON',    'Leblon, RJ',                        'EK','Prospect',
     'Projeto arquitetônico do cliente (SMR_GKD).',
     'notebook andre/Gustavo - Leblon'),
  ('C096','ROBERTA BOTAFOGO',  'Apto 807, Botafogo, RJ',            'EK','Cliente',
     'Reforma de apartamento (obra concluída).',
     'notebook andre/Roberta - Projeto Reforma Apt Botafogo')
) as x(codigo, nome, endereco, empresas, situacao, obs, refs)
where not exists (select 1 from public.clientes c where c.codigo = x.codigo);

-- 2. Projetos na Engekat (10.2_PROJETOS)
insert into public.projetos (seq, codigo, cliente_id, empresa_id, nome, local, ano, status, pasta_rede)
select x.seq, x.codigo, c.id, e.id, x.nome, x.local, null, x.status,
       public.pasta_projeto(e.id, x.codigo, x.nome)
from (values
  (21,'C096-0021','C096','ROBERTA BOTAFOGO REFORMA APT 807','Botafogo, RJ','Concluído'),
  (22,'C095-0022','C095','GUSTAVO LEBLON PROJETO RESIDENCIAL','Leblon, RJ','Em andamento')
) as x(seq, codigo, cli, nome, local, status)
join public.clientes c on c.codigo = x.cli
join public.empresas e on e.sigla = 'EK'
where not exists (select 1 from public.projetos p where p.codigo = x.codigo);

-- O próximo projeto criado pelo CRM recebe 0023
select setval('public.projetos_seq', greatest((select max(seq) from public.projetos), 22));

-- Conferência
select codigo, nome, situacao from public.clientes where codigo in ('C093','C094','C095','C096') order by codigo;
select codigo, nome, status, pasta_rede from public.projetos where seq >= 21 order by seq;
