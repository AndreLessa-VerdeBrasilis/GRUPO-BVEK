-- =====================================================================
-- CRM Grupo BVEK — projetos 0014 a 0018 (trabalhos antigos que estavam
-- soltos em 03_CLIENTES/.../05_PROJETOS e receberam código em 15/10/2026).
-- Rodar DEPOIS de migracao_crm_v3_pastas_projetos.sql. Pode rodar de novo.
-- =====================================================================
insert into public.projetos (seq, codigo, cliente_id, empresa_id, nome, local, ano, status, pasta_rede)
select x.seq, x.codigo, c.id, e.id, x.nome, x.local, x.ano, 'Concluído',
       public.pasta_projeto(e.id, x.codigo, x.nome)
from (values
  (14,'C038-0014','C038','EK','GAYLUSSAC MURO E OBRAS','Niterói/RJ',null::int),
  (15,'C052-0015','C052','VB','MERCK TRANSPLANTIO E AREAS VERDES',null,2017),
  (16,'C071-0016','C071','VB','SESC FAZENDINHA HORTAS',null,2025),
  (17,'C072-0017','C072','VB','SESC ILHA BIBLIOTECA ALPINISTAS 2026',null,2026),
  (18,'C074-0018','C074','VB','SESI PETROPOLIS PODA DE ARVORES','Petrópolis/RJ',2019)
) as x(seq, codigo, cli, sigla, nome, local, ano)
join public.clientes c on c.codigo = x.cli
join public.empresas e on e.sigla = x.sigla
where not exists (select 1 from public.projetos p where p.codigo = x.codigo);

-- O próximo projeto criado pelo CRM recebe 0019
select setval('public.projetos_seq', greatest((select max(seq) from public.projetos), 18));

select codigo, pasta_rede from public.projetos where seq >= 14 order by seq;
