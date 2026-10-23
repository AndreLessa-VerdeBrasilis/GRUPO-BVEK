-- =====================================================================
-- CRM Grupo BVEK — migração v12
-- Funcionários ativos importados das pastas da rede + link da pasta
--
-- Origem: Grupo BVEK (site GRUPOBVEK9) › 01_ADMINISTRATIVO › 01.2_RH ›
--         01.2.1_COLABORADORES › 01.2.1.1_ATIVOS  (25 pastas, lidas em 23/10/2026)
--
-- O que faz:
--   1. Cria a coluna funcionarios.pasta_url (link da pasta do funcionário na rede)
--   2. Cadastra os 25 funcionários ativos (empresa e cargo ficam em branco,
--      para preencher na tela 👷 Funcionários)
--   3. Se o funcionário já existir no CRM (mesmo nome, ignorando acento e
--      maiúsculas), não duplica: só completa o link da pasta se estiver vazio
--
-- Pode rodar mais de uma vez sem duplicar nada. Não apaga nem altera
-- empresa, cargo, situação (ativo/desligado) ou observações de ninguém.
--
-- Observação: na rede existem duas pastas para a mesma pessoa
-- ("ALEXANDRE BIANCATTO" e "ALEXANDRE KOLESZA BIANCATTO OSCAR").
-- Aqui entra um cadastro só, com o nome completo e o link da pasta completa.
-- =====================================================================

begin;

-- 1. Coluna nova -------------------------------------------------------
alter table public.funcionarios add column if not exists pasta_url text;

-- Nome comparável: sem acento, maiúsculo, espaços simples
create or replace function public.bvek_nome_cmp(t text) returns text
language sql immutable as $$
  select regexp_replace(upper(translate(coalesce(t,''),
    'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ',
    'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC')), '\s+', ' ', 'g')
$$;

-- 2. Lista das pastas --------------------------------------------------
create temporary table tmp_func_rede (nome text, pasta_url text) on commit drop;
insert into tmp_func_rede (nome, pasta_url) values
  ('ADOVALDO MARTINS PEREIRA', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/ADOVALDO%20MARTINS%20PEREIRA'),
  ('AILA LESSA', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/AILA%20LESSA'),
  ('ALEXANDER WAGNER SOUZA BRITO', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/ALEXANDER%20WAGNER%20SOUZA%20BRITO'),
  ('ALEXANDRE KOLESZA BIANCATTO OSCAR', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/ALEXANDRE%20KOLESZA%20BIANCATTO%20OSCAR'),
  ('ANDRE FERREIRA LESSA', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/ANDRE%20FERREIRA%20LESSA'),
  ('ANTONIO CARLOS PEREIRA DE ALCANTARA', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/ANTONIO%20CARLOS%20PEREIRA%20DE%20ALCANTARA'),
  ('BIANCA POSSIDONIO GONZAGA', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/BIANCA%20POSSIDONIO%20GONZAGA'),
  ('BRAULIO OLIVEIROS', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/BRAULIO%20OLIVEIROS'),
  ('BRUNO DA COSTA LOPES', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/BRUNO%20DA%20COSTA%20LOPES'),
  ('BRUNO MAURICIO DA SILVA FERREIRA', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/BRUNO%20MAURICIO%20DA%20SILVA%20FERREIRA'),
  ('CARLOS AUGUSTO COELHO DA SILVA', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/CARLOS%20AUGUSTO%20COELHO%20DA%20SILVA'),
  ('CLESSIO DE ALMEIDA CARNEIRO', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/CLESSIO%20DE%20ALMEIDA%20CARNEIRO'),
  ('DAVYD ALAN DOS SANTOS', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/DAVYD%20ALAN%20DOS%20SANTOS'),
  ('FABIO DE SOUZA', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/FABIO%20DE%20SOUZA'),
  ('FRANCIMAR DE SOUZA CARVALHO', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/FRANCIMAR%20DE%20SOUZA%20CARVALHO'),
  ('JOABE DE CASTRO BORGES', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/JOABE%20DE%20CASTRO%20BORGES'),
  ('JOAO VITOR LINS', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/JOAO%20VITOR%20LINS'),
  ('LEONARDO DE SOUZA BENEDITO', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/LEONARDO%20DE%20SOUZA%20BENEDITO'),
  ('MATHEUS SILVEIRA SANTOS', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/MATHEUS%20SILVEIRA%20SANTOS'),
  ('MAXIMILIANO DE OLIVEIRA', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/MAXIMILIANO%20DE%20OLIVEIRA'),
  ('PEDRO LESSA DE CARVALHO', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/PEDRO%20LESSA%20DE%20CARVALHO'),
  ('RAFAELA FARINHA ALVES', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/RAFAELA%20FARINHA%20ALVES'),
  ('SULAMITA GUIMARAES DECANIO', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/SULAMITA%20GUIMARAES%20DECANIO'),
  ('TIAGO NUNES DOS SANTOS', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/TIAGO%20NUNES%20DOS%20SANTOS'),
  ('WELLINGTON FELLIPE GOMES LIMA MARTINS', 'https://andrelessaverdebrasiliscom.sharepoint.com/sites/GRUPOBVEK9/Shared%20Documents/01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/WELLINGTON%20FELLIPE%20GOMES%20LIMA%20MARTINS');

-- Quem já está cadastrado só como "ALEXANDRE BIANCATTO" conta como a mesma pessoa
update public.funcionarios f
   set pasta_url = r.pasta_url
  from tmp_func_rede r
 where r.nome = 'ALEXANDRE KOLESZA BIANCATTO OSCAR'
   and public.bvek_nome_cmp(f.nome) = 'ALEXANDRE BIANCATTO'
   and f.pasta_url is null;
update tmp_func_rede set nome = 'ALEXANDRE BIANCATTO'
 where nome = 'ALEXANDRE KOLESZA BIANCATTO OSCAR'
   and exists (select 1 from public.funcionarios f
               where public.bvek_nome_cmp(f.nome) = 'ALEXANDRE BIANCATTO');

-- 3a. Completa o link de quem já existe --------------------------------
update public.funcionarios f
   set pasta_url = r.pasta_url
  from tmp_func_rede r
 where public.bvek_nome_cmp(f.nome) = public.bvek_nome_cmp(r.nome)
   and f.pasta_url is null;

-- 3b. Cadastra quem ainda não existe ------------------------------------
insert into public.funcionarios (nome, ativo, pasta_url)
select r.nome, true, r.pasta_url
  from tmp_func_rede r
 where not exists (select 1 from public.funcionarios f
                   where public.bvek_nome_cmp(f.nome) = public.bvek_nome_cmp(r.nome));

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
-- 1) Lista: deve haver os 25 com link da pasta (empresa/cargo em branco
--    até você preencher)
select f.nome, f.cargo, e.sigla as empresa, f.ativo,
       case when f.pasta_url is not null then 'ok' else '—' end as pasta
  from public.funcionarios f
  left join public.empresas e on e.id = f.empresa_id
 order by f.ativo desc, f.nome;

-- 2) Resumo
select count(*) filter (where ativo)                          as ativos,
       count(*) filter (where ativo and pasta_url is not null) as ativos_com_pasta_deve_ser_25,
       count(*) filter (where ativo and empresa_id is null)    as ativos_sem_empresa
  from public.funcionarios;
