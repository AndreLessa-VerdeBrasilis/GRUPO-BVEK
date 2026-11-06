-- =====================================================================
-- CRM Grupo BVEK — migração v54 (06/11/2026)
-- Evento do escritório: convidar FUNCIONÁRIOS (todos, inclusive quem não
-- tem e-mail / acesso ao CRM). Eles recebem o aviso pelo WhatsApp, no
-- celular da ficha do RH.
--
-- 1. agenda_escritorio.funcionarios: lista dos funcionários convidados.
--    Fica separada dos "participantes" (que vêm do Outlook e são regravados
--    a cada sincronização), por isso o Outlook não apaga esta lista.
-- 2. agenda_escritorio_avisos ganha funcionario_id (o e-mail deixa de ser
--    obrigatório) e bvek_escritorio_avisos passa a devolvê-lo.
--
-- Rode DEPOIS da v53. Pode rodar mais de uma vez. Nada é apagado.
-- =====================================================================

-- 1. FUNCIONÁRIOS CONVIDADOS ------------------------------------------------------
alter table public.agenda_escritorio add column if not exists funcionarios uuid[] not null default '{}';

-- 2. AVISOS POR FUNCIONÁRIO -----------------------------------------------------
alter table public.agenda_escritorio_avisos add column if not exists funcionario_id uuid references public.funcionarios(id) on delete set null;
alter table public.agenda_escritorio_avisos alter column email drop not null;
create index if not exists agenda_escritorio_avisos_func_idx on public.agenda_escritorio_avisos (evento_id, funcionario_id, enviado_em desc);

-- muda as colunas devolvidas, por isso é preciso apagar a função antes de recriar
drop function if exists public.bvek_escritorio_avisos(uuid);
create function public.bvek_escritorio_avisos(p_id uuid)
returns table (email text, funcionario_id uuid, nome text, tipo text, ok boolean, erro text, enviado_em timestamptz, enviado_por text)
language sql stable security definer set search_path = public as $$
  select a.email, a.funcionario_id, a.nome, a.tipo, a.ok, a.erro, a.enviado_em, a.enviado_por
    from public.agenda_escritorio_avisos a
   where a.evento_id = p_id
     and public.bvek_pode('{administrador,comercial,administrativo,contabilidade}'::text[])
   order by a.enviado_em desc
$$;
revoke all on function public.bvek_escritorio_avisos(uuid) from public, anon;
grant execute on function public.bvek_escritorio_avisos(uuid) to authenticated;

-- Conferência: funcionários ativos que podem ser convidados e se recebem no WhatsApp.
select f.nome as funcionario,
       case when length(regexp_replace(coalesce(f.celular, ''), '\D', '', 'g')) >= 10 then '📱 sim'
            else 'não (cadastre o celular na ficha em RH → Dados)' end as recebe_whatsapp,
       (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'agenda_escritorio' and column_name = 'funcionarios') as coluna_criada
  from public.funcionarios f
 where f.ativo is not false
 order by 1;
