-- =====================================================================
-- CRM Grupo BVEK — migração v5 (16/10/2026)
--  1. Prazo de execução em dias, semanas ou meses
--     (prazo_execucao_meses continua guardando a QUANTIDADE; a unidade
--      fica em prazo_execucao_unidade. Propostas antigas = meses.)
--  2. Forma de pagamento estruturada (medição / após conclusão / sinal)
--  3. PDF da proposta enviada ao cliente (Storage, bucket "propostas")
-- Pode rodar mais de uma vez sem problema.
-- =====================================================================

alter table public.cards add column if not exists prazo_execucao_unidade text;
update public.cards set prazo_execucao_unidade = 'meses'
 where prazo_execucao_meses is not null and prazo_execucao_unidade is null;
alter table public.cards drop constraint if exists cards_prazo_unidade_chk;
alter table public.cards add constraint cards_prazo_unidade_chk
  check (prazo_execucao_unidade is null or prazo_execucao_unidade in ('dias','semanas','meses'));

alter table public.cards add column if not exists pagamento jsonb;
alter table public.cards add column if not exists arquivo_proposta text;
alter table public.cards add column if not exists arquivo_proposta_nome text;

-- Valor total não pode ser negativo
alter table public.cards drop constraint if exists cards_valor_positivo_chk;
alter table public.cards add constraint cards_valor_positivo_chk
  check (valor_estimado is null or valor_estimado >= 0) not valid;

-- Bucket privado para os PDFs das propostas (só usuários logados)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('propostas', 'propostas', false, 20971520, array['application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 20971520, allowed_mime_types = array['application/pdf'];

drop policy if exists propostas_ler      on storage.objects;
drop policy if exists propostas_enviar   on storage.objects;
drop policy if exists propostas_alterar  on storage.objects;
drop policy if exists propostas_apagar   on storage.objects;
create policy propostas_ler     on storage.objects for select to authenticated using (bucket_id = 'propostas');
create policy propostas_enviar  on storage.objects for insert to authenticated with check (bucket_id = 'propostas');
create policy propostas_alterar on storage.objects for update to authenticated using (bucket_id = 'propostas') with check (bucket_id = 'propostas');
create policy propostas_apagar  on storage.objects for delete to authenticated using (bucket_id = 'propostas');

-- Pasta do projeto C073-0001 (SESC Tijuca) no site da Verde Brasilis
update public.projetos
   set pasta_rede = 'Verdebrasilis/20.2_PROJETOS/C073-0001 SESC TIJUCA PODA DE COQUEIROS E PALMEIRAS'
 where codigo = 'C073-0001';

-- Conferência
select count(*) filter (where prazo_execucao_unidade is not null) as com_prazo,
       count(*) as total_cards,
       (select count(*) from storage.buckets where id = 'propostas') as bucket_ok
  from public.cards;
