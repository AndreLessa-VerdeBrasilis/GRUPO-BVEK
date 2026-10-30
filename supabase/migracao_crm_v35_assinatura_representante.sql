-- =====================================================================
-- CRM Grupo BVEK — migração v35
-- Assinatura do representante (imagem) nos termos de adesão e nas
-- declarações de premiação. A imagem fica em rh/assinaturas/ e só
-- Administrador e Administrativo podem ver ou trocar (a Contabilidade,
-- que lê o resto da pasta do RH, não lê a assinatura).
-- Precisa da v14 e da v17 já rodadas. Pode rodar mais de uma vez.
-- =====================================================================
begin;

drop policy if exists rh_ler on storage.objects;
create policy rh_ler on storage.objects for select to authenticated
  using (bucket_id = 'rh' and (
         case when (storage.foldername(name))[1] in ('curriculos','assinaturas')
              then public.bvek_pode('{administrador,administrativo}')
              else public.bvek_pode('{administrador,administrativo,contabilidade}') end));

commit;

-- Conferência: deve mostrar 1 linha com a regra nova
select policyname, qual from pg_policies
 where schemaname = 'storage' and tablename = 'objects' and policyname = 'rh_ler';
