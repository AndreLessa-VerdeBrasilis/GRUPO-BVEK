-- =====================================================================
-- CRM Grupo BVEK — migração v53 (06/11/2026)
-- Evento do escritório também avisa os convidados pelo WhatsApp.
--
-- 1. Tabela agenda_escritorio_avisos: cada WhatsApp mandado para um
--    convidado de um evento do escritório (convite, alteração ou
--    cancelamento). Serve para não mandar de novo o que a pessoa já sabe.
--    Só a função "convocacao" (servidor) grava.
-- 2. bvek_pessoas_agenda() passa a dizer se a pessoa tem celular na ficha
--    de funcionário (tem_celular), para mostrar o 📱 na lista de convidados.
--    O número em si nunca vai para a tela.
--
-- Usa o mesmo número/configuração da Meta da convocação
-- (Cronograma → ⚙️ WhatsApp, tabela whatsapp_convocacao_config, v48).
--
-- Rode DEPOIS da v45, v47 e v48. Pode rodar mais de uma vez. Nada é apagado.
-- =====================================================================

-- 1. AVISOS DOS EVENTOS DO ESCRITÓRIO ------------------------------------------
create table if not exists public.agenda_escritorio_avisos (
  id           uuid primary key default gen_random_uuid(),
  evento_id    uuid not null references public.agenda_escritorio(id) on delete cascade,
  email        text not null,            -- convidado (e-mail em minúsculas)
  nome         text,
  tipo         text not null,            -- convite | alteracao | cancelamento
  canal        text not null default 'whatsapp',
  destino      text,                     -- número usado
  ok           boolean not null default false,
  erro         text,
  assinatura   text,                     -- resumo do que foi avisado (para saber se mudou depois)
  enviado_em   timestamptz not null default now(),
  enviado_por  text
);
alter table public.agenda_escritorio_avisos drop constraint if exists agenda_escritorio_avisos_tipo_chk;
alter table public.agenda_escritorio_avisos add constraint agenda_escritorio_avisos_tipo_chk check (tipo in ('convite','alteracao','cancelamento'));
create index if not exists agenda_escritorio_avisos_evento_idx on public.agenda_escritorio_avisos (evento_id, email, enviado_em desc);

alter table public.agenda_escritorio_avisos enable row level security;
drop policy if exists bvek_ler on public.agenda_escritorio_avisos;
create policy bvek_ler on public.agenda_escritorio_avisos for select to authenticated
  using (public.bvek_pode('{administrador,administrativo,contabilidade}'::text[]));
-- sem política de inserir/alterar/apagar: só a função "convocacao" (servidor) grava
grant select on public.agenda_escritorio_avisos to authenticated;
revoke all on public.agenda_escritorio_avisos from anon;

-- resumo para todos os perfis do escritório (sem o número)
create or replace function public.bvek_escritorio_avisos(p_id uuid)
returns table (email text, nome text, tipo text, ok boolean, erro text, enviado_em timestamptz, enviado_por text)
language sql stable security definer set search_path = public as $$
  select a.email, a.nome, a.tipo, a.ok, a.erro, a.enviado_em, a.enviado_por
    from public.agenda_escritorio_avisos a
   where a.evento_id = p_id
     and public.bvek_pode('{administrador,comercial,administrativo,contabilidade}'::text[])
   order by a.enviado_em desc
$$;
revoke all on function public.bvek_escritorio_avisos(uuid) from public, anon;
grant execute on function public.bvek_escritorio_avisos(uuid) to authenticated;

-- 2. CONVIDADOS COM "TEM CELULAR" ----------------------------------------------
-- (muda as colunas devolvidas, por isso é preciso apagar a função antes de recriar)
drop function if exists public.bvek_pessoas_agenda();
create function public.bvek_pessoas_agenda()
returns table (nome text, email text, tem_celular boolean)
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim(p.nome), ''), split_part(p.email, '@', 1)) as nome,
         lower(trim(p.email)) as email,
         exists (
           select 1 from public.funcionarios f
            where f.ativo is not false
              and length(regexp_replace(coalesce(f.celular, ''), '\D', '', 'g')) >= 10
              and (lower(trim(f.email)) = lower(trim(p.email))
                   or (nullif(trim(p.nome), '') is not null and lower(trim(f.nome)) = lower(trim(p.nome))))
         ) as tem_celular
    from public.perfis p
   where public.bvek_ativo()
     and p.ativo is not false
     and p.perfil in ('administrador','comercial','administrativo','contabilidade','consulta')
     and p.email is not null
     and p.email not ilike '%@funcionario.bvek.com.br'
   order by 1;
$$;
revoke all on function public.bvek_pessoas_agenda() from public, anon;
grant execute on function public.bvek_pessoas_agenda() to authenticated;

-- Conferência: quem pode ser convidado e se recebe no WhatsApp
-- (📱 sim = achou celular na ficha do funcionário pelo e-mail ou pelo nome).
select coalesce(nullif(trim(p.nome), ''), p.email) as convidado,
       lower(trim(p.email)) as email,
       case when exists (
         select 1 from public.funcionarios f
          where f.ativo is not false
            and length(regexp_replace(coalesce(f.celular, ''), '\D', '', 'g')) >= 10
            and (lower(trim(f.email)) = lower(trim(p.email))
                 or (nullif(trim(p.nome), '') is not null and lower(trim(f.nome)) = lower(trim(p.nome))))
       ) then '📱 sim' else 'não (cadastre o celular na ficha em RH → Dados)' end as recebe_whatsapp,
       (select count(*) from public.agenda_escritorio_avisos) as avisos_ja_enviados
  from public.perfis p
 where p.ativo is not false
   and p.perfil in ('administrador','comercial','administrativo','contabilidade')
   and p.email is not null and p.email not ilike '%@funcionario.bvek.com.br'
 order by 1;
