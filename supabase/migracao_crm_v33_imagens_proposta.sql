-- =====================================================================
-- CRM Grupo BVEK — migração v33 (29/10/2026)
-- Imagens da proposta (fotos do local, croquis, referências)
--
--  1. cards.imagens: lista das imagens do atendimento, com legenda e se
--     sai ou não no PDF da proposta.
--  2. A pasta "propostas" do Supabase passa a aceitar imagens
--     (JPG, PNG, WEBP), além do PDF.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

alter table public.cards add column if not exists imagens jsonb not null default '[]'::jsonb;

update storage.buckets
   set allowed_mime_types = array['application/pdf','image/jpeg','image/png','image/webp']
 where id = 'propostas';

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'cards' and column_name = 'imagens')  as coluna_imagens_deve_ser_1,
       (select allowed_mime_types from storage.buckets where id = 'propostas')                as tipos_aceitos_na_pasta_propostas;
