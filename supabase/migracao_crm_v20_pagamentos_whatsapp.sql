-- =====================================================================
-- CRM Grupo BVEK — migração v20 (28/10/2026)
-- Financeiro: pagamentos a autorizar + lembrete pelo WhatsApp
--
--  1. pagamentos_autorizacao: o financeiro (Sulamita) lança o que está
--     esperando a autorização do André no app do banco.
--  2. whatsapp_config: número do André e a chave do serviço de envio
--     (só o Administrador lê e altera — a chave fica só no banco,
--     nunca em arquivo do repositório).
--  3. bvek_avisar_pagamentos(forcar):
--       - botão "Avisar André agora" no CRM (forcar = true);
--       - a cada 5 minutos o próprio Supabase (pg_cron) chama com
--         forcar = false: se ainda houver pagamento pendente e já tiver
--         passado o intervalo (60 min), manda o lembrete de novo.
--       Para assim que todos forem marcados como autorizados.
--  4. Envio pelo WhatsApp:
--       - CallMeBot (gratuito, manda mensagem para o próprio número);
--       - ou API oficial do WhatsApp (Meta), se um dia quiser trocar.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- Depois: no CRM, aba Financeiro → ⚙️ WhatsApp, cadastre o número e a
-- chave (apikey) do CallMeBot e clique em "Enviar teste".
-- =====================================================================

-- extensões do Supabase para agendar (pg_cron) e chamar a internet (pg_net)
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

begin;

-- ---------------------------------------------------------------------
-- 1. PAGAMENTOS A AUTORIZAR
-- ---------------------------------------------------------------------
create table if not exists public.pagamentos_autorizacao (
  id               uuid primary key default gen_random_uuid(),
  favorecido       text not null,
  descricao        text,
  valor            numeric(14,2),
  vencimento       date,
  banco            text default 'Itaú Empresas',
  empresa_id       uuid references public.empresas(id) on delete set null,
  situacao         text not null default 'pendente',
  lembrete_ativo   boolean not null default true,
  observacoes      text,
  criado_por       text,
  criado_em        timestamptz not null default now(),
  autorizado_em    timestamptz,
  autorizado_por   text,
  avisos_enviados  integer not null default 0,
  ultimo_aviso_em  timestamptz
);
alter table public.pagamentos_autorizacao drop constraint if exists pagamentos_autorizacao_situacao_chk;
alter table public.pagamentos_autorizacao add constraint pagamentos_autorizacao_situacao_chk
  check (situacao in ('pendente','autorizado','cancelado'));
create index if not exists pagamentos_autorizacao_situacao_idx on public.pagamentos_autorizacao (situacao);

-- ---------------------------------------------------------------------
-- 2. CONFIGURAÇÃO DO WHATSAPP (uma linha só)
-- ---------------------------------------------------------------------
create table if not exists public.whatsapp_config (
  id                integer primary key default 1,
  ativo             boolean not null default false,
  provedor          text not null default 'callmebot',
  telefone          text,                 -- só números, com 55 + DDD (ex.: 5521999999999)
  callmebot_apikey  text,
  meta_token        text,
  meta_phone_id     text,
  meta_modelo       text,                 -- nome do modelo aprovado na Meta (1 variável: {{1}})
  meta_idioma       text default 'pt_BR',
  intervalo_min     integer not null default 60,
  hora_inicio       integer not null default 8,
  hora_fim          integer not null default 18,
  fim_de_semana     boolean not null default false,
  atualizado_em     timestamptz not null default now()
);
alter table public.whatsapp_config drop constraint if exists whatsapp_config_uma_linha;
alter table public.whatsapp_config add constraint whatsapp_config_uma_linha check (id = 1);
alter table public.whatsapp_config drop constraint if exists whatsapp_config_provedor_chk;
alter table public.whatsapp_config add constraint whatsapp_config_provedor_chk check (provedor in ('callmebot','meta'));
insert into public.whatsapp_config (id) values (1) on conflict (id) do nothing;

-- histórico dos envios (para conferir se o WhatsApp recebeu)
create table if not exists public.whatsapp_envios (
  id          uuid primary key default gen_random_uuid(),
  enviado_em  timestamptz not null default now(),
  motivo      text,
  telefone    text,
  texto       text,
  request_id  bigint,
  erro        text
);

-- ---------------------------------------------------------------------
-- 3. SEGURANÇA (RLS)
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select * from (values
    ('pagamentos_autorizacao', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador}'),
    ('whatsapp_config',        '{administrador}',                '{administrador}',                '{administrador}',                '{administrador}'),
    ('whatsapp_envios',        '{administrador,administrativo}', '{administrador}',                '{administrador}',                '{administrador}')
  ) as t(tabela, ler, ins, upd, del)
  loop
    execute format('alter table public.%I enable row level security', r.tabela);
    execute format('drop policy if exists bvek_ler on public.%I', r.tabela);
    execute format('drop policy if exists bvek_inserir on public.%I', r.tabela);
    execute format('drop policy if exists bvek_alterar on public.%I', r.tabela);
    execute format('drop policy if exists bvek_apagar on public.%I', r.tabela);
    execute format('create policy bvek_ler on public.%I for select to authenticated using (public.bvek_pode(%L::text[]))', r.tabela, r.ler);
    execute format('create policy bvek_inserir on public.%I for insert to authenticated with check (public.bvek_pode(%L::text[]))', r.tabela, r.ins);
    execute format('create policy bvek_alterar on public.%I for update to authenticated using (public.bvek_pode(%L::text[])) with check (public.bvek_pode(%L::text[]))', r.tabela, r.upd, r.upd);
    execute format('create policy bvek_apagar on public.%I for delete to authenticated using (public.bvek_pode(%L::text[]))', r.tabela, r.del);
    execute format('grant select, insert, update, delete on public.%I to authenticated', r.tabela);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. ENVIO PELO WHATSAPP
-- ---------------------------------------------------------------------
-- Manda um texto para o número configurado. Devolve o id do pedido (pg_net).
create or replace function public.bvek_whatsapp_enviar(p_texto text, p_motivo text default null)
returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare
  c     public.whatsapp_config;
  v_req bigint;
  v_txt text;
begin
  -- pelo CRM: só administrador/administrativo; pelo agendamento (sem login): liberado
  if auth.uid() is not null and not public.bvek_pode('{administrador,administrativo}') then
    raise exception 'Sem permissão para enviar WhatsApp.';
  end if;
  select * into c from public.whatsapp_config where id = 1;
  if c.telefone is null or c.telefone = '' then
    raise exception 'Cadastre o número do WhatsApp em Financeiro → ⚙️ WhatsApp.';
  end if;

  if c.provedor = 'meta' then
    if coalesce(c.meta_token,'') = '' or coalesce(c.meta_phone_id,'') = '' then
      raise exception 'Preencha o token e o ID do número da Meta.';
    end if;
    -- a Meta não aceita quebra de linha dentro da variável do modelo
    v_txt := regexp_replace(p_texto, '\s*\n+\s*', ' | ', 'g');
    select net.http_post(
      url     := 'https://graph.facebook.com/v21.0/' || c.meta_phone_id || '/messages',
      headers := jsonb_build_object('Authorization', 'Bearer ' || c.meta_token, 'Content-Type', 'application/json'),
      body    := case when coalesce(c.meta_modelo,'') <> '' then
                   jsonb_build_object('messaging_product','whatsapp','to',c.telefone,'type','template',
                     'template', jsonb_build_object('name', c.meta_modelo,
                        'language', jsonb_build_object('code', coalesce(c.meta_idioma,'pt_BR')),
                        'components', jsonb_build_array(jsonb_build_object('type','body',
                           'parameters', jsonb_build_array(jsonb_build_object('type','text','text', left(v_txt, 1000)))))))
                 else
                   jsonb_build_object('messaging_product','whatsapp','to',c.telefone,'type','text',
                     'text', jsonb_build_object('body', p_texto))
                 end
    ) into v_req;
  else
    if coalesce(c.callmebot_apikey,'') = '' then
      raise exception 'Preencha a chave (apikey) do CallMeBot.';
    end if;
    select net.http_get(
      url    := 'https://api.callmebot.com/whatsapp.php',
      params := jsonb_build_object('phone', '+' || c.telefone, 'text', p_texto, 'apikey', c.callmebot_apikey)
    ) into v_req;
  end if;

  insert into public.whatsapp_envios (motivo, telefone, texto, request_id)
  values (p_motivo, c.telefone, p_texto, v_req);
  return v_req;
end $$;

-- Valor em reais no padrão brasileiro: 1.234,56
create or replace function public.bvek_fmt_moeda(v numeric)
returns text language sql immutable as $$
  select translate(to_char(v, 'FM999,999,999,990.00'), ',.', '.,')
$$;

-- Texto do lembrete com tudo que está pendente
create or replace function public.bvek_texto_pagamentos()
returns text
language sql stable security definer set search_path = public as $$
  select '🔔 *Grupo BVEK — pagamentos aguardando sua autorização no app do banco*' || chr(10) ||
         string_agg('• ' || p.favorecido ||
                    coalesce(' — R$ ' || public.bvek_fmt_moeda(p.valor), '') ||
                    coalesce(' — vence ' || to_char(p.vencimento, 'DD/MM'), '') ||
                    coalesce(' (' || p.banco || ')', ''),
                    chr(10) order by p.vencimento nulls last, p.criado_em) ||
         chr(10) || 'Total: ' || count(*) || ' pagamento(s)' ||
         coalesce(' · R$ ' || public.bvek_fmt_moeda(sum(p.valor)), '') ||
         chr(10) || 'Depois de autorizar, marque no CRM: https://grupo-bvek.vercel.app/#financeiro'
    from public.pagamentos_autorizacao p
   where p.situacao = 'pendente' and p.lembrete_ativo
     and (auth.uid() is null or public.bvek_pode('{administrador,administrativo}'))
$$;

-- Avisa o André. forcar = true: manda agora (botão do CRM).
-- forcar = false (agendamento): só manda se estiver no horário e já tiver passado o intervalo.
create or replace function public.bvek_avisar_pagamentos(p_forcar boolean default false)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  c        public.whatsapp_config;
  v_qtd    integer;
  v_ultimo timestamptz;
  v_agora  timestamp := (now() at time zone 'America/Sao_Paulo');
  v_texto  text;
begin
  if auth.uid() is not null and not public.bvek_pode('{administrador,administrativo}') then
    raise exception 'Sem permissão.';
  end if;
  select * into c from public.whatsapp_config where id = 1;
  select count(*), max(ultimo_aviso_em) into v_qtd, v_ultimo
    from public.pagamentos_autorizacao where situacao = 'pendente' and lembrete_ativo;
  if v_qtd = 0 then return 'nada pendente'; end if;

  if not p_forcar then
    if not c.ativo then return 'lembrete desligado'; end if;
    if extract(hour from v_agora) < c.hora_inicio or extract(hour from v_agora) >= c.hora_fim then return 'fora do horário'; end if;
    if not c.fim_de_semana and extract(isodow from v_agora) in (6,7) then return 'fim de semana'; end if;
    -- 2 min de folga para o agendamento de 5 em 5 minutos não atrasar uma volta inteira
    if v_ultimo is not null and v_ultimo > now() - make_interval(mins => greatest(c.intervalo_min, 15) - 2) then
      return 'ainda no intervalo';
    end if;
  end if;

  v_texto := public.bvek_texto_pagamentos();
  perform public.bvek_whatsapp_enviar(v_texto, case when p_forcar then 'aviso manual' else 'lembrete automático' end);
  update public.pagamentos_autorizacao
     set avisos_enviados = avisos_enviados + 1, ultimo_aviso_em = now()
   where situacao = 'pendente' and lembrete_ativo;
  return 'enviado';
end $$;

-- Resultado dos últimos envios (o pg_net guarda a resposta do serviço por algumas horas)
create or replace function public.bvek_whatsapp_ultimos()
returns table (enviado_em timestamptz, motivo text, status integer, resposta text)
language sql stable security definer set search_path = public, extensions as $$
  select e.enviado_em, e.motivo, r.status_code, left(coalesce(r.error_msg, r.content::text), 300)
    from public.whatsapp_envios e
    left join net._http_response r on r.id = e.request_id
   where public.bvek_pode('{administrador,administrativo}')
   order by e.enviado_em desc
   limit 10
$$;

revoke all on function public.bvek_whatsapp_enviar(text, text)   from public, anon;
revoke all on function public.bvek_texto_pagamentos()             from public, anon;
revoke all on function public.bvek_avisar_pagamentos(boolean)     from public, anon;
revoke all on function public.bvek_whatsapp_ultimos()             from public, anon;
grant execute on function public.bvek_whatsapp_enviar(text, text) to authenticated;
grant execute on function public.bvek_texto_pagamentos()          to authenticated;
grant execute on function public.bvek_avisar_pagamentos(boolean)  to authenticated;
grant execute on function public.bvek_whatsapp_ultimos()          to authenticated;

commit;

-- ---------------------------------------------------------------------
-- 5. AGENDAMENTO: confere a cada 5 minutos (manda no máximo 1x por intervalo)
--    Rodar de novo só atualiza o mesmo agendamento.
-- ---------------------------------------------------------------------
select cron.schedule('bvek-lembrete-pagamentos', '*/5 * * * *',
                     $$select public.bvek_avisar_pagamentos(false)$$);

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from public.whatsapp_config)                               as config_deve_ser_1,
       (select count(*) from pg_policies where schemaname = 'public'
         and tablename in ('pagamentos_autorizacao','whatsapp_config','whatsapp_envios')) as regras_deve_ser_12,
       (select count(*) from cron.job where jobname = 'bvek-lembrete-pagamentos')  as agendamento_deve_ser_1;
