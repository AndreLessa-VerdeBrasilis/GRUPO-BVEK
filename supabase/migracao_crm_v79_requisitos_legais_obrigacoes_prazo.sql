-- =====================================================================
-- CRM Grupo BVEK — migração v79 — Gestão → Normas ISO (requisitos legais)
-- Ajustes pedidos pela consultoria da certificação ISO 9001 / 14001:
--
--  1. Locais de atuação (tabela iso_locais): municípios e estados onde
--     cada empresa atua. A matriz passa a dizer de qual município/estado
--     é cada lei e a busca automática (função normas-iso) passa a olhar
--     todos os municípios cadastrados (antes: só federal + Rio).
--     Lista inicial (Verde Brasilis): Rio de Janeiro, Duque de Caxias,
--     Belford Roxo, Nova Iguaçu, São João de Meriti, Niterói, Petrópolis,
--     Teresópolis, Itaboraí e São Gonçalo.
--  2. Obrigações de cada lei (tabela iso_obrigacoes): artigo/trecho,
--     o que a lei exige da empresa, a quem se aplica, como cumprimos,
--     evidência, responsável, situação e a validação da interpretação.
--  3. Validação (tabela iso_validadores): quem valida a interpretação —
--     especialista técnico (formação, registro no conselho, comprovante
--     de competência) ou advogado (OAB, parecer). A consultoria cadastra
--     e altera obrigações, mas NÃO valida (o banco recusa).
--     Se o texto da obrigação mudar depois de validado, a validação cai.
--  4. Prazo legal: cada lei ganha data de publicação, prazo para atender
--     (padrão: publicação + 90 dias, editável) e "adequação concluída em".
--     A revisão a cada 12 meses continua como conferência geral extra.
--
-- Pode rodar mais de uma vez. Não apaga nada.
-- =====================================================================
begin;

-- 1. LOCAIS DE ATUAÇÃO -------------------------------------------------
create table if not exists public.iso_locais (
  id            uuid primary key default gen_random_uuid(),
  municipio     text not null,
  uf            text not null default 'RJ',
  empresas      uuid[] not null default '{}',   -- empresas que atuam aqui (vazio = todas)
  ativo         boolean not null default true,
  origem        text not null default 'manual', -- manual, lista_inicial, cliente
  observacoes   text,
  criado_por    text,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index if not exists iso_locais_uk on public.iso_locais (lower(municipio), upper(uf));

insert into public.iso_locais (municipio, uf, empresas, origem, criado_por)
select v.m, 'RJ', coalesce((select array_agg(e.id) from public.empresas e where e.sigla = 'VB'), '{}'), 'lista_inicial', 'migração v79'
  from (values ('Rio de Janeiro'),('Duque de Caxias'),('Belford Roxo'),('Nova Iguaçu'),('São João de Meriti'),
               ('Niterói'),('Petrópolis'),('Teresópolis'),('Itaboraí'),('São Gonçalo')) as v(m)
 where not exists (select 1 from public.iso_locais l where lower(l.municipio) = lower(v.m) and upper(l.uf) = 'RJ');

-- 2. LEI: LOCAL E PRAZO LEGAL -----------------------------------------------
alter table public.iso_requisitos add column if not exists uf              text;   -- estado da lei (estadual/municipal)
alter table public.iso_requisitos add column if not exists municipio       text;   -- município da lei (municipal)
alter table public.iso_requisitos add column if not exists data_publicacao date;
alter table public.iso_requisitos add column if not exists prazo_atender   date;   -- padrão: publicação + 90 dias
alter table public.iso_requisitos add column if not exists adequado_em     date;   -- quando a adequação ao texto novo terminou
alter table public.iso_requisitos add column if not exists prazo_obs       text;   -- de onde veio o prazo (ex.: "art. 20: vigência em 180 dias")

-- as leis já cadastradas como "Estadual (RJ)" e "Municipal (Rio)" ganham o local que valia antes
update public.iso_requisitos set uf = 'RJ' where esfera in ('estadual','municipal') and uf is null;
update public.iso_requisitos set municipio = 'Rio de Janeiro' where esfera = 'municipal' and municipio is null;

alter table public.iso_requisitos_versoes add column if not exists publicacao    date;
alter table public.iso_requisitos_versoes add column if not exists prazo_atender date;

-- 3. QUEM VALIDA A INTERPRETAÇÃO ---------------------------------------------
create table if not exists public.iso_validadores (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null,
  tipo          text not null default 'especialista',  -- especialista, advogado
  formacao      text,                                  -- ex.: Engenheiro ambiental
  registro      text,                                  -- ex.: CREA-RJ 2012345678 · OAB/RJ 123.456
  comprovante   text,                                  -- onde está o currículo / certificados / carteira (link ou pasta)
  contato       text,
  ativo         boolean not null default true,
  criado_por    text,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.iso_validadores drop constraint if exists iso_validadores_tipo_chk;
alter table public.iso_validadores add constraint iso_validadores_tipo_chk check (tipo in ('especialista','advogado'));

-- 4. OBRIGAÇÕES DE CADA LEI ----------------------------------------------------
create table if not exists public.iso_obrigacoes (
  id                 uuid primary key default gen_random_uuid(),
  requisito_id       uuid not null references public.iso_requisitos(id) on delete cascade,
  ordem              integer not null default 0,
  artigo             text,                               -- ex.: Art. 20, § 1º
  obrigacao          text not null,                      -- o que a lei exige da empresa
  aplicavel_a        text,                               -- atividade / processo / local (ex.: obras com demolição)
  empresas           uuid[] not null default '{}',       -- vazio = as mesmas da lei
  situacao           text not null default 'avaliar',
  como_atende        text,
  evidencia          text,
  responsavel        text,
  frequencia         text,                               -- ex.: a cada transporte · anual · na renovação da licença
  ultima_avaliacao   date,                               -- última avaliação de atendimento (ISO 14001 9.1.2)
  precisa_parecer    boolean not null default false,     -- dúvida de interpretação: só vale com parecer de advogado
  validador_id       uuid references public.iso_validadores(id) on delete set null,
  validado_tipo      text,                               -- cópia do validador no dia (o histórico não muda se o cadastro mudar)
  validado_nome      text,
  validado_registro  text,
  validado_em        date,
  parecer            text,                               -- onde está o parecer / registro da validação (link ou pasta)
  validacao_obs      text,
  ativo              boolean not null default true,
  criado_por         text,
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now()
);
create index if not exists iso_obrigacoes_req_idx on public.iso_obrigacoes (requisito_id);
alter table public.iso_obrigacoes drop constraint if exists iso_obrigacoes_sit_chk;
alter table public.iso_obrigacoes add constraint iso_obrigacoes_sit_chk
  check (situacao in ('avaliar','atendido','parcial','nao_atendido','nao_aplicavel'));

-- a consultoria não valida; texto alterado depois de validado → validação cai
create or replace function public.bvek_iso_obrigacao_validacao() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.bvek_perfil() = 'consultoria_iso' then
    if tg_op = 'INSERT' then
      if new.validador_id is not null or new.validado_em is not null then
        raise exception 'A consultoria cadastra as obrigações, mas a validação da interpretação é feita pelo especialista ou advogado da empresa.';
      end if;
    elsif new.validador_id is distinct from old.validador_id or new.validado_em is distinct from old.validado_em
       or new.validado_nome is distinct from old.validado_nome or new.validado_tipo is distinct from old.validado_tipo
       or new.validado_registro is distinct from old.validado_registro or new.parecer is distinct from old.parecer then
      raise exception 'A consultoria cadastra as obrigações, mas a validação da interpretação é feita pelo especialista ou advogado da empresa.';
    end if;
  end if;
  if tg_op = 'UPDATE' and old.validado_em is not null
     and (new.obrigacao is distinct from old.obrigacao or new.artigo is distinct from old.artigo)
     and new.validado_em is not distinct from old.validado_em then
    new.validador_id := null; new.validado_tipo := null; new.validado_nome := null;
    new.validado_registro := null; new.validado_em := null;
  end if;
  return new;
end $$;
drop trigger if exists bvek_iso_obrigacao_validacao on public.iso_obrigacoes;
create trigger bvek_iso_obrigacao_validacao before insert or update on public.iso_obrigacoes
  for each row execute function public.bvek_iso_obrigacao_validacao();

-- 5. PERMISSÕES ----------------------------------------------------------------
-- administrador: tudo · consultoria ISO: lê; cadastra e altera locais e obrigações; só lê os validadores; não apaga
do $$
declare r record;
begin
  for r in select * from (values
    ('iso_locais',      true,  true),
    ('iso_obrigacoes',  true,  true),
    ('iso_validadores', false, false)
  ) as t(tabela, isoc_ins, isoc_upd)
  loop
    execute format('alter table public.%I enable row level security', r.tabela);
    execute format('drop policy if exists bvek_ler on public.%I', r.tabela);
    execute format('drop policy if exists bvek_inserir on public.%I', r.tabela);
    execute format('drop policy if exists bvek_alterar on public.%I', r.tabela);
    execute format('drop policy if exists bvek_apagar on public.%I', r.tabela);
    execute format('drop policy if exists bvek_isoc_ler on public.%I', r.tabela);
    execute format('drop policy if exists bvek_isoc_inserir on public.%I', r.tabela);
    execute format('drop policy if exists bvek_isoc_alterar on public.%I', r.tabela);
    execute format('create policy bvek_ler on public.%I for select to authenticated using (public.bvek_pode(''{administrador}''::text[]))', r.tabela);
    execute format('create policy bvek_inserir on public.%I for insert to authenticated with check (public.bvek_pode(''{administrador}''::text[]))', r.tabela);
    execute format('create policy bvek_alterar on public.%I for update to authenticated using (public.bvek_pode(''{administrador}''::text[])) with check (public.bvek_pode(''{administrador}''::text[]))', r.tabela);
    execute format('create policy bvek_apagar on public.%I for delete to authenticated using (public.bvek_pode(''{administrador}''::text[]))', r.tabela);
    execute format('create policy bvek_isoc_ler on public.%I for select to authenticated using (public.bvek_pode(''{consultoria_iso}''::text[]))', r.tabela);
    if r.isoc_ins then
      execute format('create policy bvek_isoc_inserir on public.%I for insert to authenticated with check (public.bvek_pode(''{consultoria_iso}''::text[]))', r.tabela);
    end if;
    if r.isoc_upd then
      execute format('create policy bvek_isoc_alterar on public.%I for update to authenticated using (public.bvek_pode(''{consultoria_iso}''::text[])) with check (public.bvek_pode(''{consultoria_iso}''::text[]))', r.tabela);
    end if;
    execute format('grant select, insert, update, delete on public.%I to authenticated', r.tabela);
    execute format('revoke all on public.%I from anon', r.tabela);
  end loop;
end $$;

commit;

-- Conferência ----------------------------------------------------------------------------
-- Primeiro o resumo; depois, os clientes com contrato e a cidade encontrada no local do
-- contrato (ou no endereço do cliente). "FORA DA LISTA" = conferir e, se atuamos lá,
-- cadastrar em Gestão → Normas ISO → Locais de atuação.
with sem_acento as (
  select 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ'::text de, 'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC'::text para
), contratos as (
  select c.codigo, c.nome, coalesce(nullif(string_agg(distinct nullif(trim(p.local), ''), ' | '), ''), c.endereco) as onde
    from public.clientes c join public.projetos p on p.cliente_id = c.id
   group by c.id, c.codigo, c.nome, c.endereco
), achado as (
  select k.codigo, k.nome, k.onde,
         (select string_agg(l.municipio, ', ' order by l.municipio) from public.iso_locais l, sem_acento s
           where l.ativo and lower(translate(coalesce(k.onde, ''), s.de, s.para)) like '%' || lower(translate(l.municipio, s.de, s.para)) || '%') as municipio
    from contratos k
)
select 1 as ordem, 'tabelas novas (iso_locais, iso_obrigacoes, iso_validadores)' as item,
       case when to_regclass('public.iso_locais') is not null and to_regclass('public.iso_obrigacoes') is not null
             and to_regclass('public.iso_validadores') is not null then 'ok' else 'FALTA' end as resultado
union all
select 2, 'locais de atuação cadastrados', (select string_agg(municipio || '/' || uf, ', ' order by municipio) from public.iso_locais where ativo)
union all
select 3, 'colunas de prazo legal na lei',
       case when exists (select 1 from information_schema.columns where table_name = 'iso_requisitos' and column_name = 'prazo_atender') then 'ok' else 'FALTA' end
union all
select 4, 'leis municipais por local', (select string_agg(coalesce(municipio, '(sem município)') || ': ' || n, ' · ')
                                          from (select municipio, count(*) n from public.iso_requisitos where esfera = 'municipal' and ativo group by municipio) x)
union all
select 10, a.codigo || ' ' || a.nome || ' — ' || coalesce(a.onde, '(sem endereço)'),
       coalesce(a.municipio, case when a.onde is null then 'sem endereço: preencher' when a.onde ~* '(,|-|–)\s*RJ\s*$' then 'provavelmente Rio de Janeiro (confirmar)' else 'FORA DA LISTA' end)
  from achado a
order by 1, 2;
