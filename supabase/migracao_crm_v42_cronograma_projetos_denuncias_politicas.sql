-- =====================================================================
-- CRM Grupo BVEK — migração v42
-- ---------------------------------------------------------------------
-- 1. Cronograma ↔ Outlook: cada evento fica na agenda de QUEM lançou a
--    alocação (e-mail do login), e não mais numa caixa fixa.
--    Novas colunas: outlook_caixa (caixa onde o evento está) e
--    outlook_icaluid (identificador do evento igual para organizador e
--    convidados — evita alocação duplicada quando duas pessoas sincronizam).
-- 2. Canal de denúncias (acesso por CPF): ANÔNIMO. A denúncia entra só pela
--    função bvek_denuncia_enviar, que NÃO grava quem enviou (nem login, nem
--    e-mail, nem horário exato — só a data). Quem denuncia recebe um
--    protocolo para acompanhar a resposta do RH.
--    Só Administrador e Administrativo (RH) leem e respondem. Nada é apagado.
-- 3. Políticas da empresa: o RH escreve e publica na aba RH; o funcionário
--    (acesso por CPF) lê as publicadas.
--
-- Pode rodar mais de uma vez.
-- =====================================================================

-- 1. CRONOGRAMA: caixa do Outlook de cada evento -------------------------
alter table public.cronograma add column if not exists outlook_caixa   text;
alter table public.cronograma add column if not exists outlook_icaluid text;
create index if not exists cronograma_icaluid_idx on public.cronograma (outlook_icaluid) where outlook_icaluid is not null;

-- 2. CANAL DE DENÚNCIAS ---------------------------------------------------
create table if not exists public.denuncias (
  id            uuid primary key default gen_random_uuid(),
  protocolo     text not null unique,
  categoria     text not null,
  descricao     text not null,
  local         text,
  quando        text,          -- quando aconteceu (texto livre)
  envolvidos    text,
  recebida_em   date not null default current_date,  -- só a data (anonimato)
  situacao      text not null default 'nova',        -- nova | em_analise | concluida | arquivada
  resposta      text,          -- resposta que quem denunciou vê pelo protocolo
  respondida_em date,
  anotacoes_rh  text,          -- anotações internas do RH (quem denunciou não vê)
  atualizado_em timestamptz not null default now()
);
alter table public.denuncias drop constraint if exists denuncias_situacao_chk;
alter table public.denuncias add constraint denuncias_situacao_chk check (situacao in ('nova','em_analise','concluida','arquivada'));
create index if not exists denuncias_recebida_idx on public.denuncias (recebida_em desc);

alter table public.denuncias enable row level security;
drop policy if exists bvek_ler     on public.denuncias;
drop policy if exists bvek_inserir on public.denuncias;
drop policy if exists bvek_alterar on public.denuncias;
drop policy if exists bvek_apagar  on public.denuncias;
create policy bvek_ler     on public.denuncias for select to authenticated using (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_alterar on public.denuncias for update to authenticated using (public.bvek_pode('{administrador,administrativo}'::text[])) with check (public.bvek_pode('{administrador,administrativo}'::text[]));
-- sem regra de inserir (só pela função) e sem regra de apagar (nunca se apaga)
revoke all on public.denuncias from anon;
revoke insert, delete on public.denuncias from authenticated;
grant select, update on public.denuncias to authenticated;

-- envia a denúncia (qualquer login ativo, inclusive Funcionário por CPF); devolve o protocolo
create or replace function public.bvek_denuncia_enviar(p_categoria text, p_descricao text, p_local text, p_quando text, p_envolvidos text)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare prot text; tent integer := 0;
begin
  if public.bvek_perfil() is null then raise exception 'Sem acesso.'; end if;
  if coalesce(trim(p_descricao), '') = '' or length(trim(p_descricao)) < 10 then raise exception 'Descreva o que aconteceu.'; end if;
  loop
    tent := tent + 1;
    prot := 'DEN-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.denuncias where protocolo = prot) or tent > 5;
  end loop;
  insert into public.denuncias (protocolo, categoria, descricao, local, quando, envolvidos)
  values (prot, left(coalesce(nullif(trim(p_categoria), ''), 'Outro'), 80), left(trim(p_descricao), 8000),
          left(nullif(trim(p_local), ''), 300), left(nullif(trim(p_quando), ''), 200), left(nullif(trim(p_envolvidos), ''), 1000));
  return prot;
end $$;

-- consulta pelo protocolo (quem denunciou acompanha a resposta)
create or replace function public.bvek_denuncia_consultar(p_protocolo text)
returns table (protocolo text, categoria text, recebida_em date, situacao text, resposta text, respondida_em date)
language sql stable security definer set search_path = public as $$
  select d.protocolo, d.categoria, d.recebida_em, d.situacao, d.resposta, d.respondida_em
    from public.denuncias d
   where public.bvek_perfil() is not null
     and d.protocolo = upper(trim(p_protocolo))
$$;

revoke all on function public.bvek_denuncia_enviar(text, text, text, text, text) from public, anon;
revoke all on function public.bvek_denuncia_consultar(text)                      from public, anon;
grant execute on function public.bvek_denuncia_enviar(text, text, text, text, text) to authenticated;
grant execute on function public.bvek_denuncia_consultar(text)                      to authenticated;

-- 3. POLÍTICAS DA EMPRESA -------------------------------------------------
create table if not exists public.politicas (
  id            uuid primary key default gen_random_uuid(),
  titulo        text not null,
  conteudo      text not null default '',
  link          text,          -- opcional: link do documento completo (SharePoint etc.)
  ordem         integer not null default 0,
  publicada     boolean not null default false,
  atualizado_por text,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.politicas enable row level security;
drop policy if exists bvek_ler     on public.politicas;
drop policy if exists bvek_inserir on public.politicas;
drop policy if exists bvek_alterar on public.politicas;
drop policy if exists bvek_apagar  on public.politicas;
create policy bvek_ler     on public.politicas for select to authenticated using (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_inserir on public.politicas for insert to authenticated with check (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_alterar on public.politicas for update to authenticated using (public.bvek_pode('{administrador,administrativo}'::text[])) with check (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_apagar  on public.politicas for delete to authenticated using (public.bvek_pode('{administrador}'::text[]));
grant select, insert, update, delete on public.politicas to authenticated;
revoke all on public.politicas from anon;

-- políticas publicadas (para o acesso por CPF)
create or replace function public.bvek_politicas_publicadas()
returns table (id uuid, titulo text, conteudo text, link text, atualizado_em timestamptz)
language sql stable security definer set search_path = public as $$
  select p.id, p.titulo, p.conteudo, p.link, p.atualizado_em
    from public.politicas p
   where public.bvek_perfil() is not null and p.publicada
   order by p.ordem, p.titulo
$$;
revoke all on function public.bvek_politicas_publicadas() from public, anon;
grant execute on function public.bvek_politicas_publicadas() to authenticated;

-- Conferência
select 'coluna outlook_caixa no cronograma' as item,
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'cronograma' and column_name = 'outlook_caixa')::text as ok
union all
select 'tabela denuncias', (to_regclass('public.denuncias') is not null)::text
union all
select 'tabela politicas', (to_regclass('public.politicas') is not null)::text
union all
select 'funções novas (deve ser 3)', count(*)::text
  from pg_proc where pronamespace = 'public'::regnamespace
   and proname in ('bvek_denuncia_enviar','bvek_denuncia_consultar','bvek_politicas_publicadas')
union all
select 'denúncias recebidas', count(*)::text from public.denuncias
union all
select 'políticas cadastradas', count(*)::text from public.politicas;
