-- =====================================================================
-- CRM Grupo BVEK — migração v81: TRIAGEM INICIAL DOS CURRÍCULOS
--
-- Quando chega um currículo ou uma indicação, o RH gera na ficha do
-- currículo um link de triagem (triagem.html) e manda ao candidato por
-- WhatsApp ou e-mail. O candidato responde pelo celular, sem login
-- (texto e, se preferir, áudio). As respostas aparecem sozinhas na ficha
-- do currículo, para o RH decidir se chama para a entrevista.
--
-- Perguntas (versão 1, arquivo triagem-questionario.js):
--   1. bairro e cidade onde mora
--   2. disponibilidade de horários
--   3. experiências mais recentes na função (empresa, cargo, período)
--   4. experiência fora da carteira (autônomo, freela, informal,
--      voluntariado, negócio familiar) + quem pode confirmar
--
-- Mesmo padrão do questionário de perfil (v14): link vale 30 dias e só
-- pode ser respondido uma vez. Os áudios ficam no bucket privado
-- "triagem" (o candidato só consegue ENVIAR enquanto o link está aberto;
-- só Administrador e Administrativo ouvem).
--
-- Se o currículo ainda não tem cidade/bairro ou disponibilidade, a
-- resposta do candidato preenche esses campos (nada é sobrescrito).
--
-- Pode rodar mais de uma vez sem duplicar nada.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. TABELA
-- ---------------------------------------------------------------------
create table if not exists public.triagens (
  id             uuid primary key default gen_random_uuid(),
  curriculo_id   uuid not null references public.curriculos(id) on delete cascade,
  token          uuid not null unique default gen_random_uuid(),
  versao         integer not null default 1,     -- versão das perguntas
  cargo          text,                            -- vaga citada na mensagem ao candidato
  criado_em      timestamptz not null default now(),
  criado_por     text,
  respondido_em  timestamptz,
  respondido_por text,                            -- null = o próprio candidato pelo link; nome = RH digitou o que recebeu por mensagem
  respostas      jsonb,
  resultado      text,                            -- entrevistar, talvez, nao
  observacao     text,
  resultado_por  text,
  resultado_em   timestamptz
);
alter table public.triagens add column if not exists cargo text;
alter table public.triagens add column if not exists respondido_por text;
alter table public.triagens add column if not exists resultado text;
alter table public.triagens add column if not exists observacao text;
alter table public.triagens add column if not exists resultado_por text;
alter table public.triagens add column if not exists resultado_em timestamptz;
alter table public.triagens drop constraint if exists triagens_resultado_chk;
alter table public.triagens add constraint triagens_resultado_chk
  check (resultado is null or resultado in ('entrevistar','talvez','nao'));
create index if not exists triagens_curr_idx on public.triagens (curriculo_id, criado_em desc);

-- ---------------------------------------------------------------------
-- 2. PÁGINA PÚBLICA (sem login)
-- ---------------------------------------------------------------------
-- O que a página pode ver: primeiro nome, vaga e se veio por indicação.
create or replace function public.bvek_triagem_form(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'nome',       split_part(initcap(c.nome), ' ', 1),
           'cargo',      coalesce(nullif(trim(t.cargo), ''), nullif(trim(c.funcao), '')),
           'indicacao',  coalesce(c.origem ilike 'indica%', false),
           'respondido', t.respondido_em is not null,
           'expirado',   t.criado_em < now() - interval '30 days',
           'versao',     t.versao)
    from public.triagens t
    join public.curriculos c on c.id = t.curriculo_id
   where t.token = p_token
$$;

-- Usada pela regra do bucket: o link (pasta do arquivo) ainda aceita áudio?
-- Limite de 20 áudios por link, para ninguém encher o armazenamento.
create or replace function public.bvek_triagem_aberta(p_pasta text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare tk uuid; n int;
begin
  if p_pasta is null or p_pasta !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  tk := p_pasta::uuid;
  if not exists (select 1 from public.triagens
                  where token = tk and respondido_em is null
                    and criado_em >= now() - interval '30 days') then
    return false;
  end if;
  select count(*) into n from storage.objects
   where bucket_id = 'triagem' and name like p_pasta || '/%';
  return n < 20;
end $$;

create or replace function public.bvek_triagem_responder(p_token uuid, p_respostas jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  n int; cv uuid; cid text; bai text; disp text; lugar text; caminho text;
begin
  if p_respostas is null or jsonb_typeof(p_respostas) <> 'object' or length(p_respostas::text) > 40000 then
    raise exception 'Respostas inválidas.';
  end if;
  -- áudio só vale se estiver na pasta deste link
  if jsonb_typeof(p_respostas->'audios') = 'object' then
    for caminho in
      select a.value from jsonb_each(p_respostas->'audios') e,
             jsonb_array_elements_text(case when jsonb_typeof(e.value) = 'array' then e.value else '[]'::jsonb end) a
    loop
      if caminho not like p_token::text || '/%' then raise exception 'Áudio inválido.'; end if;
    end loop;
  end if;

  update public.triagens
     set respostas = p_respostas, respondido_em = now(), respondido_por = null
   where token = p_token
     and respondido_em is null
     and criado_em >= now() - interval '30 days'
  returning curriculo_id into cv;
  get diagnostics n = row_count;
  if n <> 1 then return false; end if;

  -- completa a ficha do currículo só onde está em branco
  cid  := left(nullif(trim(p_respostas->'local'->>'cidade'), ''), 60);
  bai  := left(nullif(trim(p_respostas->'local'->>'bairro'), ''), 60);
  disp := left(nullif(trim(p_respostas->>'disponibilidade'), ''), 120);
  lugar := case when cid is not null and bai is not null then cid || ' / ' || bai else coalesce(cid, bai) end;
  update public.curriculos
     set cidade          = coalesce(nullif(trim(cidade), ''), lugar),
         disponibilidade = coalesce(nullif(trim(disponibilidade), ''), disp),
         situacao        = case when situacao = 'novo' then 'analise' else situacao end,
         atualizado_em   = now()
   where id = cv;
  return true;
end $$;

revoke all on function public.bvek_triagem_form(uuid)              from public;
revoke all on function public.bvek_triagem_aberta(text)            from public;
revoke all on function public.bvek_triagem_responder(uuid, jsonb)  from public;
grant execute on function public.bvek_triagem_form(uuid)             to anon, authenticated;
grant execute on function public.bvek_triagem_aberta(text)           to anon, authenticated;
grant execute on function public.bvek_triagem_responder(uuid, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. SEGURANÇA (RLS) — mesmas regras de curriculos/avaliacoes_perfil
-- ---------------------------------------------------------------------
alter table public.triagens enable row level security;
drop policy if exists bvek_ler     on public.triagens;
drop policy if exists bvek_inserir on public.triagens;
drop policy if exists bvek_alterar on public.triagens;
drop policy if exists bvek_apagar  on public.triagens;
create policy bvek_ler     on public.triagens for select to authenticated using (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_inserir on public.triagens for insert to authenticated with check (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_alterar on public.triagens for update to authenticated
  using (public.bvek_pode('{administrador,administrativo}'::text[])) with check (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_apagar  on public.triagens for delete to authenticated using (public.bvek_pode('{administrador}'::text[]));
grant select, insert, update, delete on public.triagens to authenticated;
revoke all on public.triagens from anon;

-- ---------------------------------------------------------------------
-- 4. ÁUDIOS (bucket privado "triagem", até 15 MB por áudio)
--    pasta = token do link: triagem/<token>/<pergunta>_<hora>.<ext>
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('triagem', 'triagem', false, 15728640,
        array['audio/webm','audio/mp4','audio/mpeg','audio/ogg','audio/aac','audio/x-m4a',
              'audio/m4a','audio/wav','audio/x-wav','audio/3gpp','audio/amr','audio/opus'])
on conflict (id) do update set public = false, file_size_limit = 15728640,
  allowed_mime_types = array['audio/webm','audio/mp4','audio/mpeg','audio/ogg','audio/aac','audio/x-m4a',
              'audio/m4a','audio/wav','audio/x-wav','audio/3gpp','audio/amr','audio/opus'];

drop policy if exists triagem_enviar on storage.objects;
drop policy if exists triagem_ler    on storage.objects;
drop policy if exists triagem_apagar on storage.objects;
create policy triagem_enviar on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'triagem' and public.bvek_triagem_aberta((storage.foldername(name))[1]));
create policy triagem_ler on storage.objects for select to authenticated
  using (bucket_id = 'triagem' and public.bvek_pode('{administrador,administrativo}'::text[]));
create policy triagem_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'triagem' and public.bvek_pode('{administrador}'::text[]));

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from information_schema.tables where table_schema = 'public' and table_name = 'triagens') as tabela_triagens_deve_ser_1,
       (select count(*) from pg_policies where schemaname = 'public' and tablename = 'triagens')                  as regras_deve_ser_4,
       (select count(*) from pg_proc where proname in ('bvek_triagem_form','bvek_triagem_aberta','bvek_triagem_responder')) as funcoes_deve_ser_3,
       (select count(*) from storage.buckets where id = 'triagem')                                              as bucket_deve_ser_1,
       (select count(*) from pg_policies where schemaname = 'storage' and policyname like 'triagem\_%')         as regras_audio_deve_ser_3,
       (select count(*) from public.triagens)                                                                   as triagens_ja_criadas;
