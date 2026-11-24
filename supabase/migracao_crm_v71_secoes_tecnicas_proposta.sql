-- =====================================================================
-- CRM Grupo BVEK — v71: seções técnicas da proposta
-- Guarda, em cada proposta (cards), o texto completo do objeto, a abertura
-- (parágrafos depois de "Prezados Senhores"), as seções técnicas antes e
-- depois da planilha (com subtítulos, listas e tabelas) e as exclusões.
--   cards.conteudo_proposta = { objeto, abertura, secoes_antes, secoes_depois, exclusoes }
-- A coluna é copiada sozinha na "Nova versão" (bvek_nova_versao copia todas as colunas).
-- Pode rodar mais de uma vez. Nada é apagado.
-- =====================================================================

alter table public.cards add column if not exists conteudo_proposta jsonb;

-- libera a leitura da coluna nova (os valores continuam protegidos)
select public.bvek_proteger_valores();

-- conferência: deve mostrar 1 linha com "conteudo_proposta | jsonb"
select column_name, data_type
  from information_schema.columns
 where table_schema = 'public' and table_name = 'cards' and column_name = 'conteudo_proposta';
