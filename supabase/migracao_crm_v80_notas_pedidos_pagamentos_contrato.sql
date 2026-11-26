-- =====================================================================
-- CRM Grupo BVEK — migração v80 (26/11/2026)
--
-- Tudo ligado ao contrato, lançado uma vez só:
--
-- 1. Pagamentos a autorizar (Financeiro) ganham cliente / contrato (ou
--    Escritório), categoria e forma. Quando o André marca "Autorizei",
--    o próprio banco cria a SAÍDA correspondente (Financeiro → Saídas),
--    já justificada e ligada ao contrato. Assim o custo aparece em
--    Contratos → Custos × recebido sem ninguém lançar de novo.
--    Mudou o contrato do pagamento depois? A saída acompanha.
--
-- 2. Notas fiscais emitidas (tabela notas_fiscais), ligadas ao contrato e
--    ao pedido do cliente. Quando a nota é marcada como RECEBIDA, ela vira
--    o "Recebido" do contrato (não precisa lançar o recebimento à mão).
--
-- 3. Pedidos do cliente (tabela pedidos_cliente): ordem de compra / ordem
--    de serviço / requisição que o CLIENTE emite. Ligados ao contrato.
--    Os que chegam por e-mail entram sozinhos como "a classificar"
--    (função pedidos-email). Pasta privada "pedidos" para os anexos.
--
-- 4. pedidos_config: caixas de e-mail lidas, palavras-chave e a busca
--    automática (de hora em hora, dias úteis, 7h às 20h).
--
-- Tudo só para o Administrador (mesma regra dos valores desde a v46).
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. PAGAMENTOS A AUTORIZAR → SAÍDA → CONTRATO
-- ---------------------------------------------------------------------
alter table public.pagamentos_autorizacao add column if not exists cliente_id uuid references public.clientes(id) on delete set null;
alter table public.pagamentos_autorizacao add column if not exists projeto_id uuid references public.projetos(id) on delete set null;
alter table public.pagamentos_autorizacao add column if not exists escritorio boolean not null default false;
alter table public.pagamentos_autorizacao add column if not exists categoria  text;
alter table public.pagamentos_autorizacao add column if not exists forma      text not null default 'boleto';
alter table public.pagamentos_autorizacao drop constraint if exists pagamentos_autorizacao_forma_chk;
alter table public.pagamentos_autorizacao add constraint pagamentos_autorizacao_forma_chk check (forma in ('boleto','pix','outro'));

alter table public.saidas add column if not exists pagamento_id uuid references public.pagamentos_autorizacao(id) on delete set null;
create unique index if not exists saidas_pagamento_unq on public.saidas (pagamento_id);
alter table public.saidas drop constraint if exists saidas_origem_chk;
alter table public.saidas add constraint saidas_origem_chk check (origem in ('extrato','manual','pagamento'));

create or replace function public.bvek_pagamento_para_saida() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.situacao = 'autorizado' and new.valor is not null and (new.projeto_id is not null or new.escritorio) then
    insert into public.saidas (pagamento_id, origem, forma, data, valor, fornecedor, descricao, categoria,
                               cliente_id, projeto_id, escritorio, empresa_id, situacao, criado_por, criado_por_id, observacoes)
    values (new.id, 'pagamento', new.forma, coalesce(new.autorizado_em::date, new.vencimento, current_date), new.valor,
            new.favorecido, coalesce(new.descricao, new.favorecido), coalesce(new.categoria, 'Outros'),
            case when new.escritorio then null else new.cliente_id end,
            case when new.escritorio then null else new.projeto_id end,
            new.escritorio, new.empresa_id, 'justificada', coalesce(new.autorizado_por, new.criado_por), null,
            'Veio de Pagamentos a autorizar')
    on conflict (pagamento_id) do update set
      forma = excluded.forma, valor = excluded.valor, fornecedor = excluded.fornecedor, descricao = excluded.descricao,
      categoria = excluded.categoria, cliente_id = excluded.cliente_id, projeto_id = excluded.projeto_id,
      escritorio = excluded.escritorio, empresa_id = excluded.empresa_id, atualizado_em = now();
  end if;
  return new;
end $$;
drop trigger if exists bvek_pagamento_para_saida on public.pagamentos_autorizacao;
create trigger bvek_pagamento_para_saida after insert or update on public.pagamentos_autorizacao
  for each row execute function public.bvek_pagamento_para_saida();

-- ---------------------------------------------------------------------
-- 2. PEDIDOS DO CLIENTE (OC / OS / requisição emitida pelo cliente)
-- ---------------------------------------------------------------------
create table if not exists public.pedidos_cliente (
  id              uuid primary key default gen_random_uuid(),
  projeto_id      uuid references public.projetos(id) on delete set null,
  cliente_id      uuid references public.clientes(id) on delete set null,
  empresa_id      uuid references public.empresas(id) on delete set null,
  tipo            text,                 -- Ordem de compra, Ordem de serviço, Requisição…
  numero          text,                 -- número do pedido no sistema do cliente
  data_pedido     date,
  valor           numeric(14,2),
  validade        date,
  descricao       text,
  situacao        text not null default 'ativo',   -- a_classificar · ativo · encerrado · descartado
  origem          text not null default 'manual',  -- manual · email
  email_id        text,                 -- internetMessageId (não entra 2x)
  email_caixa     text,
  email_de        text,
  email_de_nome   text,
  email_assunto   text,
  email_data      timestamptz,
  email_trecho    text,
  email_link      text,
  arquivos        jsonb not null default '[]'::jsonb,  -- [{caminho, nome, tamanho}] na pasta "pedidos"
  observacoes     text,
  classificado_por text,
  classificado_em timestamptz,
  criado_por      text,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);
alter table public.pedidos_cliente drop constraint if exists pedidos_cliente_sit_chk;
alter table public.pedidos_cliente add constraint pedidos_cliente_sit_chk check (situacao in ('a_classificar','ativo','encerrado','descartado'));
alter table public.pedidos_cliente drop constraint if exists pedidos_cliente_origem_chk;
alter table public.pedidos_cliente add constraint pedidos_cliente_origem_chk check (origem in ('manual','email'));
create unique index if not exists pedidos_cliente_email_unq on public.pedidos_cliente (email_id);
create index if not exists pedidos_cliente_proj_idx on public.pedidos_cliente (projeto_id);
create index if not exists pedidos_cliente_sit_idx on public.pedidos_cliente (situacao);

-- ---------------------------------------------------------------------
-- 3. NOTAS FISCAIS EMITIDAS
-- ---------------------------------------------------------------------
create table if not exists public.notas_fiscais (
  id                 uuid primary key default gen_random_uuid(),
  projeto_id         uuid references public.projetos(id) on delete set null,
  cliente_id         uuid references public.clientes(id) on delete set null,
  empresa_id         uuid references public.empresas(id) on delete set null,
  pedido_id          uuid references public.pedidos_cliente(id) on delete set null,
  numero             text not null,
  serie              text,
  codigo_verificacao text,
  chave_acesso       text,
  data_emissao       date not null,
  competencia        date,
  valor              numeric(14,2) not null,   -- valor dos serviços (bruto)
  valor_liquido      numeric(14,2),            -- depois das retenções (ISS, INSS, IR…)
  descricao          text,
  prazo_dias         integer,                  -- 30, 60…
  vencimento         date,
  situacao           text not null default 'emitida',  -- emitida · recebida · cancelada
  data_recebimento   date,
  valor_recebido     numeric(14,2),
  tomador_nome       text,
  tomador_doc        text,
  prestador_doc      text,
  pdf_caminho        text,                     -- pasta "portal" (projeto_id/…)
  xml_caminho        text,
  portal_arquivo_id  uuid references public.portal_arquivos(id) on delete set null,
  observacoes        text,
  criado_por         text,
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now()
);
alter table public.notas_fiscais drop constraint if exists notas_fiscais_sit_chk;
alter table public.notas_fiscais add constraint notas_fiscais_sit_chk check (situacao in ('emitida','recebida','cancelada'));
create unique index if not exists notas_fiscais_num_unq on public.notas_fiscais ((coalesce(empresa_id::text, '')), numero, (coalesce(serie, '')));
create index if not exists notas_fiscais_proj_idx on public.notas_fiscais (projeto_id);
create index if not exists notas_fiscais_sit_idx on public.notas_fiscais (situacao, vencimento);

-- ---------------------------------------------------------------------
-- 4. CONFIGURAÇÃO DA CAPTURA DE PEDIDOS NO E-MAIL (uma linha só)
-- ---------------------------------------------------------------------
create table if not exists public.pedidos_config (
  id              integer primary key default 1,
  caixas          text[] not null default '{}',   -- caixas lidas (ex.: andre.lessa@…)
  palavras        text[] not null default '{}',
  ignorar_dominios text[] not null default '{bvek.com.br,verdebrasilis.com.br}',  -- e-mails internos não viram pedido
  dias_primeira   integer not null default 30,    -- 1ª busca: quantos dias para trás
  ultima_busca    timestamptz,
  ultimo_resultado text,
  token_cron      text not null default replace(gen_random_uuid()::text, '-', ''),
  atualizado_em   timestamptz not null default now(),
  constraint pedidos_config_uma check (id = 1)
);
insert into public.pedidos_config (id, palavras) values (1, array[
  'ordem de compra','pedido de compra','ordem de serviço','requisição de compra','requisição',
  'documento de compra','autorização de aquisição','pedido de fornecimento','ordem de fornecimento',
  'autorização de fornecimento','pedido de aquisição','ordem de aquisição','autorização de compra',
  'purchase order','purchase request','purchase requisition','requisition','service order','work order',
  'purchasing document','purchase document','procurement order','acquisition order','acquisition request',
  'supply order','supply request','supply authorization','purchase authorization','procurement authorization'])
on conflict (id) do nothing;
alter table public.pedidos_config add column if not exists ignorar_dominios text[] not null default '{bvek.com.br,verdebrasilis.com.br}';

-- ---------------------------------------------------------------------
-- 5. REGRAS: só o Administrador
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['pedidos_cliente','notas_fiscais','pedidos_config'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists bvek_ler on public.%I', t);
    execute format('drop policy if exists bvek_inserir on public.%I', t);
    execute format('drop policy if exists bvek_alterar on public.%I', t);
    execute format('drop policy if exists bvek_apagar on public.%I', t);
    execute format($p$create policy bvek_ler on public.%I for select to authenticated using (public.bvek_pode('{administrador}'::text[]))$p$, t);
    execute format($p$create policy bvek_inserir on public.%I for insert to authenticated with check (public.bvek_pode('{administrador}'::text[]))$p$, t);
    execute format($p$create policy bvek_alterar on public.%I for update to authenticated using (public.bvek_pode('{administrador}'::text[])) with check (public.bvek_pode('{administrador}'::text[]))$p$, t);
    execute format($p$create policy bvek_apagar on public.%I for delete to authenticated using (public.bvek_pode('{administrador}'::text[]))$p$, t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;
-- a senha da busca automática fica só no banco
revoke select on public.pedidos_config from authenticated;
grant select (id, caixas, palavras, ignorar_dominios, dias_primeira, ultima_busca, ultimo_resultado, atualizado_em) on public.pedidos_config to authenticated;

-- pasta privada "pedidos" (anexos dos pedidos do cliente) — só o Administrador
insert into storage.buckets (id, name, public, file_size_limit)
values ('pedidos', 'pedidos', false, 26214400)
on conflict (id) do update set public = false;
drop policy if exists pedidos_ler     on storage.objects;
drop policy if exists pedidos_enviar  on storage.objects;
drop policy if exists pedidos_alterar on storage.objects;
drop policy if exists pedidos_apagar  on storage.objects;
create policy pedidos_ler on storage.objects for select to authenticated using (bucket_id = 'pedidos' and public.bvek_pode('{administrador}'));
create policy pedidos_enviar on storage.objects for insert to authenticated with check (bucket_id = 'pedidos' and public.bvek_pode('{administrador}'));
create policy pedidos_alterar on storage.objects for update to authenticated using (bucket_id = 'pedidos' and public.bvek_pode('{administrador}')) with check (bucket_id = 'pedidos' and public.bvek_pode('{administrador}'));
create policy pedidos_apagar on storage.objects for delete to authenticated using (bucket_id = 'pedidos' and public.bvek_pode('{administrador}'));

commit;

-- ---------------------------------------------------------------------
-- 6. BUSCA AUTOMÁTICA NO E-MAIL — de hora em hora, segunda a sexta, 7h às 20h (Brasília)
--    Só se o Supabase tiver pg_cron e pg_net; senão use o botão "Buscar no e-mail agora".
-- ---------------------------------------------------------------------
do $$
begin
  begin
    create extension if not exists pg_net;
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron/pg_net indisponível: use o botão "Buscar no e-mail agora" (%).', sqlerrm;
    return;
  end;
  if exists (select 1 from cron.job where jobname = 'bvek-pedidos-email') then
    perform cron.unschedule('bvek-pedidos-email');
  end if;
  perform cron.schedule('bvek-pedidos-email', '23 10-23 * * 1-5', $job$
    select net.http_post(
      url     := 'https://smusenaszgkqkjjwblyi.supabase.co/functions/v1/pedidos-email',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        -- chave pública (a mesma do index.html); a permissão real é o token_cron abaixo
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNtdXNlbmFzemdrcWtqandibHlpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI0MTIwNTMsImV4cCI6MjA5Nzk4ODA1M30.IU1Z9ddIUpktjHvWqrSZaEWuo4gbmZfrfmYJ_NoXbWs',
        'x-cron-token', (select token_cron from public.pedidos_config where id = 1)),
      body    := '{"acao":"buscar","automatico":true}'::jsonb,
      timeout_milliseconds := 60000);
  $job$);
end $$;

-- Conferência ------------------------------------------------------------------------
select 'pagamentos: colunas de contrato' as item,
       case when (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'pagamentos_autorizacao'
                   and column_name in ('cliente_id','projeto_id','escritorio','categoria','forma')) = 5 then 'ok' else 'FALTA' end as resultado
union all
select 'pagamento autorizado vira saída (gatilho)',
       case when exists (select 1 from pg_trigger where tgname = 'bvek_pagamento_para_saida') then 'ok' else 'FALTA' end
union all
select 'tabela pedidos_cliente', case when to_regclass('public.pedidos_cliente') is not null then 'ok' else 'FALTA' end
union all
select 'tabela notas_fiscais', case when to_regclass('public.notas_fiscais') is not null then 'ok' else 'FALTA' end
union all
select 'palavras-chave cadastradas', (select cardinality(palavras)::text from public.pedidos_config where id = 1)
union all
select 'pasta privada "pedidos"', case when exists (select 1 from storage.buckets where id = 'pedidos' and not public) then 'ok' else 'FALTA' end
union all
select 'busca automática no e-mail', case when exists (select 1 from pg_extension where extname = 'pg_cron')
            then 'agendada (de hora em hora, dias úteis)' else 'sem pg_cron (use o botão)' end;
