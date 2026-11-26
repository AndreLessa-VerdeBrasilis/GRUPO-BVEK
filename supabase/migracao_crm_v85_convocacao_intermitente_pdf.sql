-- =====================================================================
-- CRM Grupo BVEK — migração v85: CONVOCAÇÃO EM PDF PARA OS INTERMITENTES
--
-- Ao salvar uma alocação no Cronograma (com "Avisar a equipe"), a função
-- "convocacao" agora, para cada funcionário com contrato INTERMITENTE
-- (RH → ficha → tipo de contrato):
--   • gera a CONVOCAÇÃO em PDF no papel timbrado (art. 452-A da CLT:
--     data, horário, local, contrato/serviço, prazo de resposta);
--   • guarda o PDF em Documentos (documento do funcionário, tipo
--     "Convocação de intermitente", ligado à alocação);
--   • manda o PDF junto da mensagem do WhatsApp e anexado ao e-mail.
-- Mudou a alocação → convocação nova (a antiga fica "substituída").
-- Cancelou → a convocação fica "arquivada".
-- Alocação que já terminou → só gera a DECLARAÇÃO de prestação de
-- serviços (não manda mensagem).
--
-- Pode rodar mais de uma vez sem duplicar nada.
-- =====================================================================
begin;

-- 1. tipo de documento
insert into public.tipos_documento (nome, categoria, orgao, validade_dias, dias_aviso, ordem)
values ('Convocação de intermitente', 'funcionario', 'RH', null, 0, 207)
on conflict (nome) do nothing;

-- 2. documento ligado à alocação do cronograma
alter table public.documentos add column if not exists cronograma_id uuid references public.cronograma(id) on delete set null;
create index if not exists documentos_cronograma_idx on public.documentos (cronograma_id);

-- 3. aviso guarda qual documento foi junto; canal "documento" = PDF gerado (mesmo sem WhatsApp/e-mail)
alter table public.cronograma_avisos add column if not exists documento_id uuid references public.documentos(id) on delete set null;
alter table public.cronograma_avisos drop constraint if exists cronograma_avisos_canal_chk;
alter table public.cronograma_avisos add constraint cronograma_avisos_canal_chk check (canal in ('whatsapp','email','documento'));

-- 4. modelo da Meta com o PDF no cabeçalho (opcional; sem ele o link do PDF vai no texto)
alter table public.whatsapp_convocacao_config add column if not exists meta_modelo_doc text;

-- 5. resumo dos avisos para a tela da alocação (agora com o documento)
drop function if exists public.bvek_cronograma_avisos(uuid[]);
create function public.bvek_cronograma_avisos(p_ids uuid[])
returns table (cronograma_id uuid, funcionario_id uuid, tipo text, canal text, ok boolean, erro text, enviado_em timestamptz, enviado_por text, documento_id uuid)
language sql stable security definer set search_path = public as $$
  select a.cronograma_id, a.funcionario_id, a.tipo, a.canal, a.ok, a.erro, a.enviado_em, a.enviado_por, a.documento_id
    from public.cronograma_avisos a
   where a.cronograma_id = any(p_ids)
     and public.bvek_pode('{administrador,comercial,administrativo,contabilidade}'::text[])
   order by a.enviado_em desc
$$;
revoke all on function public.bvek_cronograma_avisos(uuid[]) from public, anon;
grant execute on function public.bvek_cronograma_avisos(uuid[]) to authenticated;

commit;

-- Conferência
select (select count(*) from public.tipos_documento where nome = 'Convocação de intermitente')                                            as tipo_documento_deve_ser_1,
       (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'documentos' and column_name = 'cronograma_id') as coluna_documentos_deve_ser_1,
       (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'cronograma_avisos' and column_name = 'documento_id') as coluna_avisos_deve_ser_1,
       (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'whatsapp_convocacao_config' and column_name = 'meta_modelo_doc') as coluna_modelo_doc_deve_ser_1,
       (select count(*) from public.funcionario_rh where tipo_contrato = 'intermitente')                                                    as intermitentes_cadastrados;
