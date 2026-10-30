-- =====================================================================
-- CRM Grupo BVEK — migração v36 (fase 2 da proteção)
--  1. VALORES PROTEGIDOS NO BANCO: o perfil Comercial deixa de RECEBER os
--     valores (antes eram só escondidos na tela). Valem para:
--       cards.valor_estimado · itens_proposta.valor_unitario/valor_total
--       contratos_recorrentes.valor_mensal/custo_mensal
--     A composição de preço (custo e lucro: cards.composicao) só chega ao
--     Administrador. Os dados passam a ser lidos por funções do banco que
--     tiram esses campos conforme o perfil.
--  2. Parâmetros de preço (BDI, lucro) deixam de ser lidos pelo Comercial.
--  3. Contratos fixos: Comercial e Administrativo veem e preenchem (sem
--     valores); PDF da proposta vigente guardado no contrato.
--  4. Registro de auditoria: quem alterou valores, pagamentos, contratos,
--     premiações e perfis de acesso (e o que mudou).
--
-- ATENÇÃO para migrações futuras: coluna NOVA em cards, itens_proposta ou
-- contratos_recorrentes precisa terminar com
--     select public.bvek_proteger_valores();
-- (libera a leitura da coluna nova; os valores continuam protegidos).
--
-- Precisa da v34 já rodada. Pode rodar mais de uma vez. Nada é apagado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. CONTRATOS: colunas novas e valor opcional (o Comercial cadastra sem valor)
-- ---------------------------------------------------------------------
alter table public.contratos_recorrentes add column if not exists equipe        text;
alter table public.contratos_recorrentes add column if not exists arquivo       text;
alter table public.contratos_recorrentes add column if not exists arquivo_nome  text;
alter table public.contratos_recorrentes alter column valor_mensal drop not null;

-- ---------------------------------------------------------------------
-- 1. QUEM VÊ VALORES
-- ---------------------------------------------------------------------
create or replace function public.bvek_ve_valores() returns boolean
language sql stable security definer set search_path = public as $$
  select public.bvek_pode('{administrador,administrativo,consulta}')
$$;
grant execute on function public.bvek_ve_valores() to authenticated;

-- libera a leitura direta de todas as colunas, MENOS as de valor
create or replace function public.bvek_proteger_valores() returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_cols text;
begin
  for r in select * from (values
    ('cards',                 array['valor_estimado','composicao']),
    ('itens_proposta',        array['valor_unitario','valor_total']),
    ('contratos_recorrentes', array['valor_mensal','custo_mensal'])
  ) as t(tabela, ocultas)
  loop
    execute format('revoke select on public.%I from anon, authenticated', r.tabela);
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into v_cols
      from information_schema.columns
     where table_schema = 'public' and table_name = r.tabela and column_name <> all(r.ocultas);
    execute format('grant select (%s) on public.%I to authenticated', v_cols, r.tabela);
  end loop;
end $$;
revoke all on function public.bvek_proteger_valores() from public, anon, authenticated;

-- leitura das propostas (com cliente e empresa), tirando o que o perfil não pode ver
create or replace function public.bvek_cards(p_id uuid default null, p_raiz uuid default null)
returns setof jsonb
language sql stable security definer set search_path = public as $$
  select (to_jsonb(c)
          - (case when public.bvek_ve_valores() then array[]::text[] else array['valor_estimado'] end)
          - (case when public.bvek_pode('{administrador}') then array[]::text[] else array['composicao'] end))
         || jsonb_build_object(
              'clientes', (select to_jsonb(cl) from public.clientes cl where cl.id = c.cliente_id),
              'empresas', (select to_jsonb(e)  from public.empresas e  where e.id  = c.empresa_id))
    from public.cards c
   where public.bvek_pode('{administrador,comercial,administrativo,consulta}')
     and (p_id   is null or c.id = p_id)
     and (p_raiz is null or c.id = p_raiz or c.card_pai_id = p_raiz)
   order by c.criado_em desc
$$;
grant execute on function public.bvek_cards(uuid, uuid) to authenticated;

create or replace function public.bvek_itens_proposta(p_card uuid)
returns setof jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(i) - (case when public.bvek_ve_valores() then array[]::text[] else array['valor_unitario','valor_total'] end)
    from public.itens_proposta i
   where i.card_id = p_card
     and public.bvek_pode('{administrador,comercial,administrativo,consulta}')
   order by i.ordem
$$;
grant execute on function public.bvek_itens_proposta(uuid) to authenticated;

create or replace function public.bvek_contratos()
returns setof jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(k) - (case when public.bvek_ve_valores() then array[]::text[] else array['valor_mensal','custo_mensal'] end)
    from public.contratos_recorrentes k
   where public.bvek_pode('{administrador,comercial,administrativo,consulta}')
   order by k.descricao
$$;
grant execute on function public.bvek_contratos() to authenticated;

-- nova versão da proposta feita no banco (copia valores e itens sem passar pelo navegador)
create or replace function public.bvek_nova_versao(p_card uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare o public.cards; v_raiz uuid; v_ver int; v jsonb; v_cols text; v_icols text; v_id uuid;
begin
  if not public.bvek_pode('{administrador,comercial}') then raise exception 'Seu perfil não cria versões de proposta.'; end if;
  select * into o from public.cards where id = p_card;
  if not found then raise exception 'Proposta não encontrada.'; end if;
  v_raiz := coalesce(o.card_pai_id, o.id);
  select max(coalesce(versao, 1)) into v_ver from public.cards where id = v_raiz or card_pai_id = v_raiz;
  v := (to_jsonb(o) - array['id','criado_em','etapa_desde','data_fechamento_real','projeto_id',
                            'arquivo_proposta','arquivo_proposta_nome','aceite_em','termino_servico'])
       || jsonb_build_object('versao', greatest(coalesce(v_ver, 1), coalesce(o.versao, 1)) + 1,
                             'card_pai_id', v_raiz, 'etapa', 'elaboracao', 'motivo_perda', null,
                             'motivo_perda_detalhe', null, 'atualizado_em', now(),
                             'proxima_cobranca', null, 'cobrancas_feitas', 0, 'ultima_cobranca', null, 'enviada_em', null);
  select string_agg(quote_ident(k), ', ') into v_cols
    from jsonb_object_keys(v) k
   where exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'cards' and column_name = k);
  execute format('insert into public.cards (%s) select %s from jsonb_populate_record(null::public.cards, $1) returning id',
                 v_cols, v_cols) using v into v_id;
  select string_agg(quote_ident(column_name), ', ') into v_icols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'itens_proposta' and column_name not in ('id', 'card_id');
  execute format('insert into public.itens_proposta (card_id, %s) select $1, %s from public.itens_proposta where card_id = $2',
                 v_icols, v_icols) using v_id, p_card;
  insert into public.inventario_os (card_id, item_id, quantidade, observacao)
  select v_id, item_id, quantidade, observacao from public.inventario_os where card_id = p_card;
  return v_id;
end $$;
grant execute on function public.bvek_nova_versao(uuid) to authenticated;

select public.bvek_proteger_valores();

-- ---------------------------------------------------------------------
-- 2. PARÂMETROS DE PREÇO (BDI, lucro): o Comercial não lê
-- ---------------------------------------------------------------------
drop policy if exists bvek_ler on public.precificacao_config;
create policy bvek_ler on public.precificacao_config for select to authenticated
  using (public.bvek_pode('{administrador,administrativo,consulta}'));

-- ---------------------------------------------------------------------
-- 3. CONTRATOS FIXOS: Comercial e Administrativo veem e preenchem
-- ---------------------------------------------------------------------
drop policy if exists bvek_ler     on public.contratos_recorrentes;
drop policy if exists bvek_inserir on public.contratos_recorrentes;
drop policy if exists bvek_alterar on public.contratos_recorrentes;
drop policy if exists bvek_apagar  on public.contratos_recorrentes;
create policy bvek_ler on public.contratos_recorrentes for select to authenticated
  using (public.bvek_pode('{administrador,comercial,administrativo,consulta}'));
create policy bvek_inserir on public.contratos_recorrentes for insert to authenticated
  with check (public.bvek_pode('{administrador,comercial,administrativo}'));
create policy bvek_alterar on public.contratos_recorrentes for update to authenticated
  using (public.bvek_pode('{administrador,comercial,administrativo}'))
  with check (public.bvek_pode('{administrador,comercial,administrativo}'));
create policy bvek_apagar on public.contratos_recorrentes for delete to authenticated
  using (public.bvek_pode('{administrador}'));

-- o Comercial não grava valor nos contratos (mantém o que o administrador lançou)
create or replace function public.bvek_contratos_valor_guarda() returns trigger
language plpgsql as $$
begin
  if auth.uid() is not null and not public.bvek_ve_valores() then
    if tg_op = 'INSERT' then new.valor_mensal := null; new.custo_mensal := null;
    else new.valor_mensal := old.valor_mensal; new.custo_mensal := old.custo_mensal; end if;
  end if;
  return new;
end $$;
drop trigger if exists bvek_contratos_valor_guarda on public.contratos_recorrentes;
create trigger bvek_contratos_valor_guarda before insert or update on public.contratos_recorrentes
  for each row execute function public.bvek_contratos_valor_guarda();

-- PDF da proposta vigente do contrato: pasta "contratos/" (o Comercial envia mas não abre PDFs)
drop policy if exists propostas_enviar on storage.objects;
create policy propostas_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'propostas' and (public.bvek_pode('{administrador,comercial}')
              or (public.bvek_pode('{administrativo}') and (storage.foldername(name))[1] = 'contratos')));

-- ---------------------------------------------------------------------
-- 4. AUDITORIA (só o Administrador lê; ninguém altera nem apaga)
-- ---------------------------------------------------------------------
create table if not exists public.auditoria (
  id          bigint generated always as identity primary key,
  tabela      text not null,
  registro_id text,
  acao        text not null,          -- INSERT · UPDATE · DELETE
  usuario     text,
  user_id     uuid,
  mudancas    jsonb,                  -- {campo: [antes, depois]}
  criado_em   timestamptz not null default now()
);
create index if not exists auditoria_tab_idx on public.auditoria (tabela, criado_em desc);
alter table public.auditoria enable row level security;
drop policy if exists bvek_ler on public.auditoria;
create policy bvek_ler on public.auditoria for select to authenticated using (public.bvek_pode('{administrador}'));
revoke insert, update, delete on public.auditoria from authenticated, anon;
grant select on public.auditoria to authenticated;

create or replace function public.bvek_auditar() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_old jsonb; v_new jsonb; v_mud jsonb; v_email text;
begin
  begin v_email := auth.jwt() ->> 'email'; exception when others then v_email := null; end;
  v_old := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else '{}'::jsonb end;
  v_new := case when tg_op in ('UPDATE','INSERT') then to_jsonb(new) else '{}'::jsonb end;
  -- só os campos que mudaram (sem textos longos de assinatura/imagens)
  select coalesce(jsonb_object_agg(k, jsonb_build_array(v_old -> k, v_new -> k)), '{}'::jsonb) into v_mud
    from (select jsonb_object_keys(v_old || v_new) k) x
   where k not in ('atualizado_em','assinatura','imagens','dados','composicao')
     and (v_old -> k) is distinct from (v_new -> k);
  if tg_op = 'UPDATE' and v_mud = '{}'::jsonb then return new; end if;
  insert into public.auditoria (tabela, registro_id, acao, usuario, user_id, mudancas)
  values (tg_table_name, coalesce(v_new ->> 'id', v_old ->> 'id'), tg_op, v_email, auth.uid(), v_mud);
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['pagamentos_autorizacao','saidas','contratos_recorrentes','premiacoes','perfis','funcionario_rh'] loop
    if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = t) then
      execute format('drop trigger if exists bvek_auditoria on public.%I', t);
      execute format('create trigger bvek_auditoria after insert or update or delete on public.%I for each row execute function public.bvek_auditar()', t);
    end if;
  end loop;
end $$;
-- nas propostas, audita só mudança de valor e de etapa
drop trigger if exists bvek_auditoria on public.cards;
create trigger bvek_auditoria after update of valor_estimado, etapa on public.cards
  for each row execute function public.bvek_auditar();

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from information_schema.column_privileges
         where table_schema = 'public' and grantee = 'authenticated' and privilege_type = 'SELECT'
           and ((table_name = 'cards' and column_name in ('valor_estimado','composicao'))
             or (table_name = 'itens_proposta' and column_name in ('valor_unitario','valor_total'))
             or (table_name = 'contratos_recorrentes' and column_name in ('valor_mensal','custo_mensal')))) as colunas_de_valor_abertas_deve_ser_0,
       (select count(*) from pg_proc where proname in
         ('bvek_cards','bvek_itens_proposta','bvek_contratos','bvek_nova_versao','bvek_proteger_valores','bvek_auditar')) as funcoes_deve_ser_6,
       (select count(*) from information_schema.tables where table_schema = 'public' and table_name = 'auditoria') as auditoria_deve_ser_1;
