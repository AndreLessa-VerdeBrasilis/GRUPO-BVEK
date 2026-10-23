-- =====================================================================
-- CRM Grupo BVEK — migração v13 (23/10/2026)
--  1. PERFIL CONTABILIDADE (consulta): vê funcionários, benefícios e
--     documentos/certidões. NÃO vê funil, propostas, clientes, contatos,
--     projetos nem atividades (bloqueado no banco, não só na tela).
--  2. BENEFÍCIOS DOS FUNCIONÁRIOS
--       tipos_beneficio        : VA, VR, VT, academia, odonto, saúde...
--                                cálculo "por dia trabalhado" ou "mensal"
--       funcionario_beneficios : quem recebe o quê e por quanto
--       competencias_beneficios: o fechamento de cada mês (10/2026...)
--       competencia_funcionarios: dias trabalhados de cada um no mês
--                                (hoje digitados; depois virão do Secullum)
--       competencia_itens      : foto dos valores no dia do fechamento
--     Quem vê: Administrador, Administrativo, Contabilidade e Comercial.
--     Quem altera: Administrador e Administrativo.
--  3. Funcionário ganha CPF, PIS e data de admissão (usados para ligar
--     ao ponto do Secullum na próxima etapa).
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. PERFIL CONTABILIDADE
-- ---------------------------------------------------------------------
alter table public.perfis drop constraint if exists perfis_perfil_chk;
alter table public.perfis add constraint perfis_perfil_chk
  check (perfil in ('pendente','administrador','comercial','administrativo','consulta','contabilidade'));

-- ---------------------------------------------------------------------
-- 2. FUNCIONÁRIOS: CPF, PIS e admissão
-- ---------------------------------------------------------------------
alter table public.funcionarios add column if not exists cpf           text;
alter table public.funcionarios add column if not exists pis           text;
alter table public.funcionarios add column if not exists data_admissao date;

-- ---------------------------------------------------------------------
-- 3. BENEFÍCIOS
-- ---------------------------------------------------------------------
create table if not exists public.tipos_beneficio (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null unique,
  calculo      text not null default 'mensal',   -- 'por_dia' ou 'mensal'
  valor_padrao numeric(12,2),
  ordem        integer not null default 100,
  ativo        boolean not null default true,
  criado_em    timestamptz not null default now()
);
alter table public.tipos_beneficio drop constraint if exists tipos_beneficio_calculo_chk;
alter table public.tipos_beneficio add constraint tipos_beneficio_calculo_chk
  check (calculo in ('por_dia','mensal'));

insert into public.tipos_beneficio (nome, calculo, ordem) values
  ('Vale-alimentação',                 'por_dia', 10),
  ('Vale-refeição',                    'por_dia', 20),
  ('Vale-transporte',                  'por_dia', 30),
  ('Academia (Wellhub / Gympass)',     'mensal',  40),
  ('Plano odontológico',               'mensal',  50),
  ('Plano de saúde',                   'mensal',  60),
  ('Seguro de vida',                   'mensal',  70),
  ('Outro benefício',                  'mensal', 199)
on conflict (nome) do nothing;

create table if not exists public.funcionario_beneficios (
  id             uuid primary key default gen_random_uuid(),
  funcionario_id uuid not null references public.funcionarios(id) on delete cascade,
  tipo_id        uuid not null references public.tipos_beneficio(id),
  valor          numeric(12,2) not null default 0,  -- por dia (VA/VR/VT) ou por mês
  desconto       numeric(12,2) not null default 0,  -- valor mensal descontado do funcionário
  inicio         date,
  fim            date,
  ativo          boolean not null default true,
  observacoes    text,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  unique (funcionario_id, tipo_id)
);
alter table public.funcionario_beneficios drop constraint if exists funcionario_beneficios_valores_chk;
alter table public.funcionario_beneficios add constraint funcionario_beneficios_valores_chk
  check (valor >= 0 and desconto >= 0);

create table if not exists public.competencias_beneficios (
  id          uuid primary key default gen_random_uuid(),
  competencia date not null unique,      -- sempre o dia 1 do mês
  dias_uteis  integer not null default 22,
  situacao    text not null default 'aberta',
  fechada_em  timestamptz,
  fechada_por text,
  observacoes text,
  criado_em   timestamptz not null default now()
);
alter table public.competencias_beneficios drop constraint if exists competencias_situacao_chk;
alter table public.competencias_beneficios add constraint competencias_situacao_chk
  check (situacao in ('aberta','fechada'));
alter table public.competencias_beneficios drop constraint if exists competencias_dia1_chk;
alter table public.competencias_beneficios add constraint competencias_dia1_chk
  check (extract(day from competencia) = 1 and dias_uteis between 0 and 31);

create table if not exists public.competencia_funcionarios (
  id               uuid primary key default gen_random_uuid(),
  competencia_id   uuid not null references public.competencias_beneficios(id) on delete cascade,
  funcionario_id   uuid not null references public.funcionarios(id) on delete cascade,
  dias_trabalhados integer,               -- vazio = usa os dias úteis do mês
  origem           text not null default 'manual',   -- 'manual' ou 'secullum'
  observacoes      text,
  atualizado_em    timestamptz not null default now(),
  unique (competencia_id, funcionario_id)
);
alter table public.competencia_funcionarios drop constraint if exists competencia_funcionarios_dias_chk;
alter table public.competencia_funcionarios add constraint competencia_funcionarios_dias_chk
  check (dias_trabalhados is null or dias_trabalhados between 0 and 31);

create table if not exists public.competencia_itens (
  id               uuid primary key default gen_random_uuid(),
  competencia_id   uuid not null references public.competencias_beneficios(id) on delete cascade,
  funcionario_id   uuid not null references public.funcionarios(id) on delete cascade,
  tipo_id          uuid references public.tipos_beneficio(id),
  tipo_nome        text not null,
  calculo          text not null,
  valor_unitario   numeric(12,2) not null default 0,
  dias             integer,
  valor_total      numeric(12,2) not null default 0,
  desconto         numeric(12,2) not null default 0,
  criado_em        timestamptz not null default now(),
  unique (competencia_id, funcionario_id, tipo_nome)
);
create index if not exists competencia_itens_comp_idx on public.competencia_itens (competencia_id);

-- ---------------------------------------------------------------------
-- 4. SEGURANÇA (RLS)
--    ler_*: quem pode LER; ins/upd/del: quem pode GRAVAR
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select * from (values
    -- área comercial: contabilidade NÃO lê
    ('clientes',               '{administrador,comercial,administrativo,consulta}', '{administrador,comercial}',      '{administrador,comercial}',      '{administrador}'),
    ('contatos',               '{administrador,comercial,administrativo,consulta}', '{administrador,comercial}',      '{administrador,comercial}',      '{administrador,comercial}'),
    ('cards',                  '{administrador,comercial,administrativo,consulta}', '{administrador,comercial}',      '{administrador,comercial}',      '{administrador}'),
    ('itens_proposta',         '{administrador,comercial,administrativo,consulta}', '{administrador,comercial}',      '{administrador,comercial}',      '{administrador,comercial}'),
    ('sequencia_propostas',    '{administrador,comercial,administrativo,consulta}', '{administrador,comercial}',      '{administrador,comercial}',      '{administrador}'),
    ('historico_etapas',       '{administrador,comercial,administrativo,consulta}', '{administrador,comercial}',      '{administrador}',                '{administrador}'),
    ('atividades',             '{administrador,comercial,administrativo,consulta}', '{administrador,comercial,administrativo}', '{administrador,comercial,administrativo}', '{administrador,comercial,administrativo}'),
    ('projetos',               '{administrador,comercial,administrativo,consulta}', '{administrador,comercial,administrativo}', '{administrador,comercial,administrativo}', '{administrador}'),
    ('historico_cards',        '{administrador,comercial,administrativo,consulta}', '{administrador}',                '{administrador}',                '{administrador}'),
    ('propostas',              '{administrador,comercial,administrativo,consulta}', '{administrador}',                '{administrador}',                '{administrador}'),
    -- benefícios: consulta NÃO lê
    ('tipos_beneficio',        '{administrador,administrativo,contabilidade,comercial}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador}'),
    ('funcionario_beneficios', '{administrador,administrativo,contabilidade,comercial}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador,administrativo}'),
    ('competencias_beneficios','{administrador,administrativo,contabilidade,comercial}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador}'),
    ('competencia_funcionarios','{administrador,administrativo,contabilidade,comercial}','{administrador,administrativo}', '{administrador,administrativo}', '{administrador,administrativo}'),
    ('competencia_itens',      '{administrador,administrativo,contabilidade,comercial}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador,administrativo}')
  ) as t(tabela, ler, ins, upd, del)
  loop
    continue when to_regclass('public.' || r.tabela) is null;
    execute format('alter table public.%I enable row level security', r.tabela);
    execute format('drop policy if exists bvek_autenticado on public.%I', r.tabela);
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

-- PDFs das propostas: contabilidade não abre
drop policy if exists propostas_ler on storage.objects;
create policy propostas_ler on storage.objects for select to authenticated
  using (bucket_id = 'propostas' and public.bvek_pode('{administrador,comercial,administrativo,consulta}'));

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from public.tipos_beneficio)                                  as tipos_de_beneficio_deve_ser_8,
       (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'funcionarios'
           and column_name in ('cpf','pis','data_admissao'))                          as colunas_novas_funcionario_deve_ser_3,
       (select count(*) from pg_policies where schemaname = 'public'
         and tablename in ('tipos_beneficio','funcionario_beneficios','competencias_beneficios',
                           'competencia_funcionarios','competencia_itens'))           as regras_beneficios_deve_ser_20,
       (select count(*) from pg_constraint where conname = 'perfis_perfil_chk'
         and pg_get_constraintdef(oid) like '%contabilidade%')                        as perfil_contabilidade_ok;
