-- =====================================================================
-- CRM Grupo BVEK — migração v38 (30/10/2026)
-- O perfil Comercial passa a ver SOMENTE os documentos das empresas
-- (certidões etc.). Documentos de funcionários (ASO, NRs, CNH, termos
-- de adesão, declarações de premiação...) ficam invisíveis para ele.
--
-- Antes: todo perfil ativo lia a tabela "documentos" inteira e abria
-- qualquer arquivo do bucket "documentos".
-- Agora:
--   1. Tabela documentos: o Comercial só lê linhas sem funcionário
--      (funcionario_id vazio). Os demais perfis continuam como antes.
--   2. Arquivos (bucket "documentos"): o Comercial só abre o arquivo
--      se ele pertencer a um documento de empresa.
-- Quem grava/altera/apaga continua igual. Nada é apagado.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada.
-- =====================================================================

begin;

-- 1. Leitura da tabela documentos
drop policy if exists bvek_ler on public.documentos;
create policy bvek_ler on public.documentos for select to authenticated
  using (public.bvek_ativo()
         and (funcionario_id is null or not public.bvek_pode('{comercial}')));

-- 2. Arquivo no Storage: liberado para o Comercial só se for de documento de empresa
create or replace function public.bvek_arquivo_doc_empresa(p_caminho text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.documentos d
     where d.funcionario_id is null
       and (d.arquivo = p_caminho
            or d.id::text = split_part(p_caminho, '/', 2))
  )
$$;
grant execute on function public.bvek_arquivo_doc_empresa(text) to authenticated;

drop policy if exists documentos_ler on storage.objects;
create policy documentos_ler on storage.objects for select to authenticated
  using (bucket_id = 'documentos'
         and public.bvek_ativo()
         and (not public.bvek_pode('{comercial}')
              or public.bvek_arquivo_doc_empresa(name)));

commit;

-- ---------------------------------------------------------------------
-- Conferência: as duas regras devem citar "comercial"
-- ---------------------------------------------------------------------
select 'tabela documentos' as onde, policyname as regra, qual as quem_le
  from pg_policies
 where schemaname = 'public' and tablename = 'documentos' and policyname = 'bvek_ler'
union all
select 'arquivos (storage)', policyname, qual
  from pg_policies
 where schemaname = 'storage' and tablename = 'objects' and policyname = 'documentos_ler';
