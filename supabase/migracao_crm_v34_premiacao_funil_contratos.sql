-- =====================================================================
-- CRM Grupo BVEK — migração v34
--  1. Funil: saem as colunas Entrada, Contato, Nutrição 1ª fase, Orçamento
--     e Em Negociação; entra "Concluídas". As propostas dessas colunas vão
--     para "Elaboração de Proposta" (Em Negociação → "2ª Cobrança").
--     Aceite do cliente + data de término do serviço: depois do término o
--     card vai sozinho para Concluídas.
--  2. Perfil Comercial não abre o PDF das propostas (valores restritos).
--  3. Contratos fixos / recorrentes (só administrador) para Ganhos × Custos.
--  4. Premiação / extra no contracheque, com declaração e assinatura
--     eletrônica do funcionário (registro travado depois de assinado).
--  5. Inventário: importar a planilha de vocês (colunas extras guardadas)
--     e o modelo da exportação (tabela crm_config).
--
-- Precisa da v11, v14, v17, v30 e v31 já rodadas.
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. FUNIL
-- ---------------------------------------------------------------------
alter table public.cards add column if not exists aceite_em        date;
alter table public.cards add column if not exists termino_servico  date;

-- "concluida" também é etapa de proposta ganha (mantém a data de fechamento)
create or replace function public.bvek_registrar_etapa() returns trigger
language plpgsql as $$
declare v_user text;
begin
  begin v_user := coalesce(auth.jwt() ->> 'email', null); exception when others then v_user := null; end;
  if tg_op = 'INSERT' then
    new.etapa_desde := now();
  elsif new.etapa is distinct from old.etapa then
    new.etapa_desde := now();
    if new.etapa in ('fechada','concluida','perdida') and new.data_fechamento_real is null then
      new.data_fechamento_real := (now() at time zone 'America/Sao_Paulo')::date;
    end if;
    if new.etapa not in ('fechada','concluida','perdida') then
      new.data_fechamento_real := null;
    end if;
  end if;
  return new;
end $$;

update public.cards set etapa = 'elaboracao', atualizado_em = now()
 where etapa in ('entrada','contato','nutricao1','orcamento');
update public.cards set etapa = 'cobranca2', atualizado_em = now()
 where etapa = 'negociacao';

-- cards aceitos cujo serviço já terminou → Concluídas (o CRM chama ao abrir)
create or replace function public.bvek_concluir_servicos() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.uid() is null or not public.bvek_ativo()
     or coalesce(public.bvek_perfil(), '') in ('funcionario','pendente') then
    return 0;
  end if;
  update public.cards
     set etapa = 'concluida', atualizado_em = now()
   where etapa = 'fechada'
     and aceite_em is not null
     and termino_servico is not null
     and termino_servico < (now() at time zone 'America/Sao_Paulo')::date;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.bvek_concluir_servicos() to authenticated;

-- ---------------------------------------------------------------------
-- 2. PDF DAS PROPOSTAS: o Comercial não lê os PDFs (as imagens continuam liberadas)
-- ---------------------------------------------------------------------
drop policy if exists propostas_ler on storage.objects;
create policy propostas_ler on storage.objects for select to authenticated
  using (bucket_id = 'propostas' and public.bvek_ativo()
         and (not public.bvek_pode('{comercial}') or lower(name) !~ '\.pdf$'));

-- ---------------------------------------------------------------------
-- 3. CONTRATOS FIXOS / RECORRENTES (só administrador)
-- ---------------------------------------------------------------------
create table if not exists public.contratos_recorrentes (
  id              uuid primary key default gen_random_uuid(),
  tipo            text not null default 'receita',     -- receita (prestamos) · despesa (pagamos)
  empresa_id      uuid references public.empresas(id) on delete set null,
  cliente_id      uuid references public.clientes(id) on delete set null,
  card_id         uuid references public.cards(id) on delete set null,   -- proposta de origem (não soma 2x)
  descricao       text not null,
  fornecedor      text,
  valor_mensal    numeric(14,2) not null,
  custo_mensal    numeric(14,2),
  inicio          date not null,
  fim             date,
  dia_vencimento  integer,
  ativo           boolean not null default true,
  observacoes     text,
  criado_por      text,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);
alter table public.contratos_recorrentes drop constraint if exists contratos_recorrentes_tipo_chk;
alter table public.contratos_recorrentes add constraint contratos_recorrentes_tipo_chk check (tipo in ('receita','despesa'));
alter table public.contratos_recorrentes drop constraint if exists contratos_recorrentes_valor_chk;
alter table public.contratos_recorrentes add constraint contratos_recorrentes_valor_chk
  check (valor_mensal >= 0 and (custo_mensal is null or custo_mensal >= 0) and (fim is null or fim >= inicio)
         and (dia_vencimento is null or dia_vencimento between 1 and 31));

-- ---------------------------------------------------------------------
-- 4. PREMIAÇÃO / EXTRA
-- ---------------------------------------------------------------------
create table if not exists public.premiacoes (
  id              uuid primary key default gen_random_uuid(),
  funcionario_id  uuid not null references public.funcionarios(id) on delete cascade,
  competencia     date not null,                 -- 1º dia do mês
  dias            date[] not null default '{}',  -- dia(s) a que se refere
  valor           numeric(12,2) not null,
  motivo          text,
  pago_em         date,
  documento_id    uuid references public.documentos(id) on delete set null,
  criado_por      text,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now(),
  -- assinatura eletrônica do funcionário (só pela função bvek_assinar_premiacao)
  assinado_em     timestamptz,
  concorda        boolean,
  observacao      text,
  nome_digitado   text,
  assinatura      text,
  dados           jsonb,
  hash            text,
  ip              text,
  user_agent      text,
  user_id         uuid
);
create index if not exists premiacoes_func_comp_idx on public.premiacoes (funcionario_id, competencia);
alter table public.premiacoes drop constraint if exists premiacoes_valor_chk;
alter table public.premiacoes add constraint premiacoes_valor_chk check (valor > 0);

-- registro com valor de prova: depois de assinado não muda nem some;
-- a assinatura só entra pela função (o RH não consegue "assinar" no lugar do funcionário)
create or replace function public.bvek_trava_premiacao() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.assinado_em is not null or new.assinatura is not null then
      raise exception 'A assinatura da premiação só pode ser feita pelo funcionário.';
    end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if old.assinado_em is not null then
      raise exception 'Premiação já assinada não pode ser apagada (registro com valor de prova).';
    end if;
    return old;
  end if;
  if old.assinado_em is not null then
    if (to_jsonb(new) - 'documento_id') <> (to_jsonb(old) - 'documento_id') then
      raise exception 'Premiação já assinada não pode ser alterada (registro com valor de prova).';
    end if;
    return new;
  end if;
  if (new.assinado_em is not null or new.assinatura is not null)
     and coalesce(current_setting('bvek.assinando_premiacao', true), '') <> 'sim' then
    raise exception 'A assinatura da premiação só pode ser feita pelo funcionário.';
  end if;
  return new;
end $$;
drop trigger if exists bvek_trava_premiacao on public.premiacoes;
create trigger bvek_trava_premiacao before insert or update or delete on public.premiacoes
  for each row execute function public.bvek_trava_premiacao();

-- premiações do próprio funcionário (login por CPF)
create or replace function public.bvek_minhas_premiacoes()
returns table (id uuid, competencia date, dias date[], valor numeric, motivo text, pago_em date,
               assinado_em timestamptz, concorda boolean, hash text, nome text, cargo text, data_admissao date)
language sql stable security definer set search_path = public as $$
  select p.id, p.competencia, p.dias, p.valor, p.motivo, p.pago_em, p.assinado_em, p.concorda, p.hash,
         f.nome, f.cargo, f.data_admissao
    from public.premiacoes p join public.funcionarios f on f.id = p.funcionario_id
   where p.funcionario_id = public.bvek_meu_funcionario_id()
   order by p.competencia desc, p.criado_em desc
$$;
grant execute on function public.bvek_minhas_premiacoes() to authenticated;

create or replace function public.bvek_minha_premiacao(p_id uuid)
returns setof public.premiacoes
language sql stable security definer set search_path = public as $$
  select p.* from public.premiacoes p
   where p.id = p_id and p.funcionario_id = public.bvek_meu_funcionario_id()
$$;
grant execute on function public.bvek_minha_premiacao(uuid) to authenticated;

create or replace function public.bvek_assinar_premiacao(
  p_id uuid, p_concorda boolean, p_observacao text, p_nome text, p_assinatura text, p_texto text, p_user_agent text)
returns table (id uuid, hash text, assinado_em timestamptz)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_func uuid := public.bvek_meu_funcionario_id();
  v_p    public.premiacoes;
  v_ip   text;
  v_dados jsonb;
begin
  if v_func is null then raise exception 'Seu CPF não está ligado a um cadastro de funcionário. Fale com o RH.'; end if;
  select * into v_p from public.premiacoes where premiacoes.id = p_id and funcionario_id = v_func for update;
  if not found then raise exception 'Premiação não encontrada.'; end if;
  if v_p.assinado_em is not null then raise exception 'Esta declaração já foi assinada.'; end if;
  if coalesce(trim(p_nome), '') = '' then raise exception 'Digite o seu nome completo para assinar.'; end if;
  if coalesce(p_assinatura, '') !~ '^data:image/png;base64,' or length(p_assinatura) > 400000 then
    raise exception 'Assinatura inválida. Desenhe de novo.';
  end if;
  if not p_concorda and coalesce(trim(p_observacao), '') = '' then raise exception 'Explique o que está errado.'; end if;
  begin
    v_ip := split_part(coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for', ''), ',', 1);
  exception when others then v_ip := null; end;
  v_dados := jsonb_build_object('texto', left(coalesce(p_texto, ''), 20000), 'valor', v_p.valor, 'dias', v_p.dias,
                                'competencia', v_p.competencia, 'motivo', v_p.motivo);
  perform set_config('bvek.assinando_premiacao', 'sim', true);
  return query
  update public.premiacoes as a
     set assinado_em = now(), concorda = p_concorda, observacao = nullif(trim(p_observacao), ''),
         nome_digitado = upper(trim(p_nome)), assinatura = p_assinatura, dados = v_dados,
         hash = encode(sha256(convert_to(v_dados::text, 'UTF8')), 'hex'),
         ip = nullif(v_ip, ''), user_agent = left(p_user_agent, 300), user_id = auth.uid()
   where a.id = p_id
  returning a.id, a.hash, a.assinado_em;
  perform set_config('bvek.assinando_premiacao', '', true);
end $$;
grant execute on function public.bvek_assinar_premiacao(uuid, boolean, text, text, text, text, text) to authenticated;

insert into public.tipos_documento (nome, categoria, orgao, validade_dias, dias_aviso, ordem)
values ('Declaração de premiação', 'funcionario', 'RH', null, 0, 206)
on conflict (nome) do nothing;

-- ---------------------------------------------------------------------
-- 5. INVENTÁRIO: colunas extras da planilha importada + modelo da exportação
-- ---------------------------------------------------------------------
alter table public.inventario_itens add column if not exists extras jsonb;
create table if not exists public.crm_config (
  chave         text primary key,
  valor         jsonb,
  atualizado_em timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 6. SEGURANÇA (RLS)
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select * from (values
    ('contratos_recorrentes', '{administrador}',                               '{administrador}',                '{administrador}',                '{administrador}'),
    ('premiacoes',            '{administrador,administrativo,contabilidade}',  '{administrador,administrativo}', '{administrador,administrativo}', '{administrador,administrativo}'),
    ('crm_config',            '{administrador,comercial,administrativo,consulta,contabilidade}', '{administrador,comercial,administrativo}', '{administrador,comercial,administrativo}', '{administrador}')
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

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from public.cards
         where etapa in ('entrada','contato','nutricao1','orcamento','negociacao'))       as cards_em_colunas_antigas_deve_ser_0,
       (select count(*) from information_schema.columns where table_schema = 'public'
         and table_name = 'cards' and column_name in ('aceite_em','termino_servico'))     as colunas_aceite_deve_ser_2,
       (select count(*) from information_schema.tables where table_schema = 'public'
         and table_name in ('contratos_recorrentes','premiacoes','crm_config'))           as tabelas_novas_deve_ser_3,
       (select count(*) from public.tipos_documento where nome = 'Declaração de premiação') as tipo_premiacao_deve_ser_1,
       (select count(*) from pg_proc where proname in
         ('bvek_concluir_servicos','bvek_assinar_premiacao','bvek_minhas_premiacoes','bvek_minha_premiacao')) as funcoes_deve_ser_4;
