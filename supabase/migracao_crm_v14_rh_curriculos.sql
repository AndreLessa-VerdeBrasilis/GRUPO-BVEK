-- =====================================================================
-- CRM Grupo BVEK — migração v14 (23/10/2026)
-- RH completo e banco de currículos
--
--  1. FICHA DO FUNCIONÁRIO (funcionario_rh): salário, adiantamento mensal,
--     tipo de contrato, tamanhos de uniforme, ficha de registro (arquivo do
--     kit admissional) e as opções de benefício marcadas na admissão.
--  2. UNIFORMES (uniforme_entregas): cada entrega, com item, tamanho,
--     quantidade, motivo e recibo assinado (opcional).
--  3. CONTRACHEQUES (contracheques): um PDF por funcionário e por mês,
--     separado do PDF único da contabilidade, com cabeçalho de nome, CPF,
--     admissão e função.
--  4. VALES / EMPRÉSTIMOS (emprestimos + emprestimo_descontos): valor
--     emprestado e o desconto lançado a cada mês, até zerar o saldo.
--  5. ADIANTAMENTOS (adiantamentos): 40% do salário no dia 15 para quem
--     solicita (percentual e dia ficam em rh_config).
--  6. ENVIO À CONTABILIDADE (rh_config + envios_contabilidade): e-mails da
--     Innove, dia do envio (25) e o histórico de cada envio.
--  7. CURRÍCULOS (curriculos + avaliacoes_perfil): banco de talentos
--     (inclui freelas) com avaliação, parecer e o questionário
--     comportamental respondido pelo candidato num link (perfil.html).
--  8. ARQUIVOS: bucket privado "rh". A pasta curriculos/ só Administrador
--     e Administrativo abrem; o resto também a Contabilidade.
--
-- Quem vê o quê (regras no banco, não só na tela):
--   salário, contracheques, vales, adiantamentos, uniformes, envios:
--       ler  = Administrador, Administrativo, Contabilidade
--       gravar = Administrador, Administrativo
--   currículos e questionários: Administrador e Administrativo
--   O candidato responde o questionário sem login, só pelo link com código
--   (vale 30 dias e só pode ser respondido uma vez).
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. FICHA DO FUNCIONÁRIO
-- ---------------------------------------------------------------------
create table if not exists public.funcionario_rh (
  funcionario_id     uuid primary key references public.funcionarios(id) on delete cascade,
  salario            numeric(12,2),
  adianta_mensal     boolean not null default false,   -- recebe adiantamento todo mês
  tipo_contrato      text,                              -- CLT, experiência, estágio...
  tam_camisa         text,
  tam_calca          text,
  tam_calcado        text,
  kit_recebido_em    date,                              -- data em que o kit admissional voltou assinado
  ficha_arquivo      text,                              -- caminho no bucket "rh"
  ficha_arquivo_nome text,
  opcoes_beneficios  jsonb not null default '{}'::jsonb, -- {tipo_beneficio_id: "sim" | "nao"}
  observacoes        text,
  atualizado_em      timestamptz not null default now()
);
alter table public.funcionario_rh drop constraint if exists funcionario_rh_salario_chk;
alter table public.funcionario_rh add constraint funcionario_rh_salario_chk
  check (salario is null or salario >= 0);

-- ---------------------------------------------------------------------
-- 2. UNIFORMES
-- ---------------------------------------------------------------------
create table if not exists public.uniforme_entregas (
  id             uuid primary key default gen_random_uuid(),
  funcionario_id uuid not null references public.funcionarios(id) on delete cascade,
  data           date not null default current_date,
  item           text not null,
  tamanho        text,
  quantidade     integer not null default 1,
  motivo         text,                -- admissão, troca por desgaste, perda, extra
  arquivo        text,                -- recibo assinado (opcional)
  arquivo_nome   text,
  observacoes    text,
  criado_por     text,
  criado_em      timestamptz not null default now()
);
alter table public.uniforme_entregas drop constraint if exists uniforme_qtd_chk;
alter table public.uniforme_entregas add constraint uniforme_qtd_chk check (quantidade > 0);
create index if not exists uniforme_func_idx on public.uniforme_entregas (funcionario_id, data desc);

-- ---------------------------------------------------------------------
-- 3. CONTRACHEQUES
-- ---------------------------------------------------------------------
create table if not exists public.contracheques (
  id             uuid primary key default gen_random_uuid(),
  funcionario_id uuid not null references public.funcionarios(id) on delete cascade,
  competencia    date not null,       -- sempre o dia 1 do mês
  arquivo        text not null,
  arquivo_nome   text,
  paginas        integer,
  origem         text not null default 'manual',   -- 'separado' (do PDF da contabilidade) ou 'manual'
  criado_por     text,
  criado_em      timestamptz not null default now(),
  unique (funcionario_id, competencia)
);
alter table public.contracheques drop constraint if exists contracheques_dia1_chk;
alter table public.contracheques add constraint contracheques_dia1_chk check (extract(day from competencia) = 1);
create index if not exists contracheques_comp_idx on public.contracheques (competencia);

-- ---------------------------------------------------------------------
-- 4. VALES / EMPRÉSTIMOS
-- ---------------------------------------------------------------------
create table if not exists public.emprestimos (
  id             uuid primary key default gen_random_uuid(),
  funcionario_id uuid not null references public.funcionarios(id) on delete cascade,
  data           date not null default current_date,
  valor          numeric(12,2) not null,
  motivo         text,
  autorizado_por text,
  situacao       text not null default 'aberto',   -- 'aberto' ou 'quitado'
  observacoes    text,
  criado_por     text,
  criado_em      timestamptz not null default now()
);
alter table public.emprestimos drop constraint if exists emprestimos_valor_chk;
alter table public.emprestimos add constraint emprestimos_valor_chk check (valor > 0);
alter table public.emprestimos drop constraint if exists emprestimos_situacao_chk;
alter table public.emprestimos add constraint emprestimos_situacao_chk check (situacao in ('aberto','quitado'));
create index if not exists emprestimos_func_idx on public.emprestimos (funcionario_id);

create table if not exists public.emprestimo_descontos (
  id            uuid primary key default gen_random_uuid(),
  emprestimo_id uuid not null references public.emprestimos(id) on delete cascade,
  competencia   date not null,        -- mês do contracheque em que foi descontado (dia 1)
  valor         numeric(12,2) not null,
  observacoes   text,
  criado_em     timestamptz not null default now(),
  unique (emprestimo_id, competencia)
);
alter table public.emprestimo_descontos drop constraint if exists emp_desc_valor_chk;
alter table public.emprestimo_descontos add constraint emp_desc_valor_chk check (valor > 0);
alter table public.emprestimo_descontos drop constraint if exists emp_desc_dia1_chk;
alter table public.emprestimo_descontos add constraint emp_desc_dia1_chk check (extract(day from competencia) = 1);

-- ---------------------------------------------------------------------
-- 5. ADIANTAMENTOS
-- ---------------------------------------------------------------------
create table if not exists public.adiantamentos (
  id             uuid primary key default gen_random_uuid(),
  funcionario_id uuid not null references public.funcionarios(id) on delete cascade,
  competencia    date not null,       -- dia 1 do mês
  percentual     numeric(5,2) not null default 40,
  salario_base   numeric(12,2),
  valor          numeric(12,2) not null,
  pago_em        date,
  observacoes    text,
  criado_em      timestamptz not null default now(),
  unique (funcionario_id, competencia)
);
alter table public.adiantamentos drop constraint if exists adiantamentos_valor_chk;
alter table public.adiantamentos add constraint adiantamentos_valor_chk check (valor >= 0 and percentual between 0 and 100);
alter table public.adiantamentos drop constraint if exists adiantamentos_dia1_chk;
alter table public.adiantamentos add constraint adiantamentos_dia1_chk check (extract(day from competencia) = 1);

-- ---------------------------------------------------------------------
-- 6. CONFIGURAÇÃO DO RH E ENVIOS À CONTABILIDADE
-- ---------------------------------------------------------------------
create table if not exists public.rh_config (
  chave         text primary key,
  valor         text,
  atualizado_em timestamptz not null default now()
);
insert into public.rh_config (chave, valor) values
  ('contabilidade_emails',     'thais.ribeiro@innovecontabil.com.br; dp@innovecontabil.com.br'),
  ('dia_envio_contabilidade',  '25'),
  ('dia_adiantamento',         '15'),
  ('percentual_adiantamento',  '40')
on conflict (chave) do nothing;

create table if not exists public.envios_contabilidade (
  id           uuid primary key default gen_random_uuid(),
  competencia  date not null,
  enviado_em   timestamptz not null default now(),
  enviado_por  text,
  remetente    text,
  para         text,
  cc           text,
  assunto      text,
  corpo        text,
  anexos       jsonb not null default '[]'::jsonb,
  situacao     text not null default 'enviado',   -- 'enviado' ou 'erro'
  erro         text
);
alter table public.envios_contabilidade drop constraint if exists envios_situacao_chk;
alter table public.envios_contabilidade add constraint envios_situacao_chk check (situacao in ('enviado','erro'));
create index if not exists envios_comp_idx on public.envios_contabilidade (competencia, enviado_em desc);

-- ---------------------------------------------------------------------
-- 7. CURRÍCULOS E QUESTIONÁRIO COMPORTAMENTAL
-- ---------------------------------------------------------------------
create table if not exists public.curriculos (
  id                  uuid primary key default gen_random_uuid(),
  nome                text not null,
  telefone            text,
  email               text,
  cidade              text,
  funcao              text,               -- função pretendida / que exerce
  vinculo             text,               -- freela, clt, pj, estagio, qualquer
  empresa_id          uuid references public.empresas(id),
  origem              text,               -- indicação, já trabalhou conosco, site...
  ja_trabalhou        text,               -- nao, freela, clt
  disponibilidade     text,
  pretensao           text,
  situacao            text not null default 'novo',
  nota_tecnica        integer,
  nota_comportamental integer,
  chamar_novamente    text,               -- prioridade, sim, nao
  pontos_fortes       text,
  pontos_atencao      text,
  parecer             text,
  avaliado_por        text,
  avaliado_em         timestamptz,
  arquivo             text,               -- currículo (PDF/foto) no bucket "rh"
  arquivo_nome        text,
  funcionario_id      uuid references public.funcionarios(id) on delete set null,
  criado_por          text,
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now()
);
alter table public.curriculos drop constraint if exists curriculos_situacao_chk;
alter table public.curriculos add constraint curriculos_situacao_chk
  check (situacao in ('novo','analise','aprovado','contratado','nao_recomendado','arquivado'));
alter table public.curriculos drop constraint if exists curriculos_notas_chk;
alter table public.curriculos add constraint curriculos_notas_chk
  check ((nota_tecnica is null or nota_tecnica between 1 and 5) and (nota_comportamental is null or nota_comportamental between 1 and 5));
create index if not exists curriculos_situacao_idx on public.curriculos (situacao);

create table if not exists public.avaliacoes_perfil (
  id            uuid primary key default gen_random_uuid(),
  curriculo_id  uuid not null references public.curriculos(id) on delete cascade,
  token         uuid not null unique default gen_random_uuid(),
  versao        integer not null default 1,      -- versão do questionário
  criado_em     timestamptz not null default now(),
  criado_por    text,
  respondido_em timestamptz,
  respostas     jsonb,
  recomendacao  text,                            -- recomendado, com_ressalvas, nao_recomendado
  parecer       text,
  parecer_por   text,
  parecer_em    timestamptz
);
create index if not exists avaliacoes_curr_idx on public.avaliacoes_perfil (curriculo_id, criado_em desc);

-- Página pública do questionário (sem login): só enxerga o primeiro nome
-- do candidato e só grava as respostas uma vez, até 30 dias após o link.
create or replace function public.bvek_perfil_form(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'nome',       split_part(initcap(c.nome), ' ', 1),
           'respondido', a.respondido_em is not null,
           'expirado',   a.criado_em < now() - interval '30 days',
           'versao',     a.versao)
    from public.avaliacoes_perfil a
    join public.curriculos c on c.id = a.curriculo_id
   where a.token = p_token
$$;

create or replace function public.bvek_perfil_responder(p_token uuid, p_respostas jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if p_respostas is null or jsonb_typeof(p_respostas) <> 'object' or length(p_respostas::text) > 30000 then
    raise exception 'Respostas inválidas.';
  end if;
  update public.avaliacoes_perfil
     set respostas = p_respostas, respondido_em = now()
   where token = p_token
     and respondido_em is null
     and criado_em >= now() - interval '30 days';
  get diagnostics n = row_count;
  return n = 1;
end $$;

revoke all on function public.bvek_perfil_form(uuid)               from public;
revoke all on function public.bvek_perfil_responder(uuid, jsonb)   from public;
grant execute on function public.bvek_perfil_form(uuid)             to anon, authenticated;
grant execute on function public.bvek_perfil_responder(uuid, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. SEGURANÇA (RLS) — mesmo padrão da v13
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select * from (values
    ('funcionario_rh',        '{administrador,administrativo,contabilidade}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador}'),
    ('uniforme_entregas',     '{administrador,administrativo,contabilidade}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador,administrativo}'),
    ('contracheques',         '{administrador,administrativo,contabilidade}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador,administrativo}'),
    ('emprestimos',           '{administrador,administrativo,contabilidade}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador}'),
    ('emprestimo_descontos',  '{administrador,administrativo,contabilidade}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador,administrativo}'),
    ('adiantamentos',         '{administrador,administrativo,contabilidade}', '{administrador,administrativo}', '{administrador,administrativo}', '{administrador,administrativo}'),
    ('rh_config',             '{administrador,administrativo,contabilidade}', '{administrador}',                '{administrador}',                '{administrador}'),
    ('envios_contabilidade',  '{administrador,administrativo,contabilidade}', '{administrador,administrativo}', '{administrador}',                '{administrador}'),
    ('curriculos',            '{administrador,administrativo}',               '{administrador,administrativo}', '{administrador,administrativo}', '{administrador}'),
    ('avaliacoes_perfil',     '{administrador,administrativo}',               '{administrador,administrativo}', '{administrador,administrativo}', '{administrador}')
  ) as t(tabela, ler, ins, upd, del)
  loop
    continue when to_regclass('public.' || r.tabela) is null;
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
    execute format('revoke all on public.%I from anon', r.tabela);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 9. ARQUIVOS DO RH (bucket privado "rh")
--    contracheques/AAAA-MM/<funcionário>.pdf · fichas/… · uniformes/…
--    envios/AAAA-MM/… · curriculos/… (este só Admin e Administrativo)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rh', 'rh', false, 26214400,
        array['application/pdf','image/jpeg','image/png',
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              'application/msword','text/csv'])
on conflict (id) do update set public = false, file_size_limit = 26214400,
  allowed_mime_types = array['application/pdf','image/jpeg','image/png',
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              'application/msword','text/csv'];

drop policy if exists rh_ler     on storage.objects;
drop policy if exists rh_enviar  on storage.objects;
drop policy if exists rh_alterar on storage.objects;
drop policy if exists rh_apagar  on storage.objects;
create policy rh_ler on storage.objects for select to authenticated
  using (bucket_id = 'rh' and (
         case when (storage.foldername(name))[1] = 'curriculos'
              then public.bvek_pode('{administrador,administrativo}')
              else public.bvek_pode('{administrador,administrativo,contabilidade}') end));
create policy rh_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'rh' and public.bvek_pode('{administrador,administrativo}'));
create policy rh_alterar on storage.objects for update to authenticated
  using (bucket_id = 'rh' and public.bvek_pode('{administrador,administrativo}'))
  with check (bucket_id = 'rh' and public.bvek_pode('{administrador,administrativo}'));
create policy rh_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'rh' and public.bvek_pode('{administrador,administrativo}'));

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from information_schema.tables where table_schema = 'public'
         and table_name in ('funcionario_rh','uniforme_entregas','contracheques','emprestimos',
                            'emprestimo_descontos','adiantamentos','rh_config',
                            'envios_contabilidade','curriculos','avaliacoes_perfil'))   as tabelas_novas_deve_ser_10,
       (select count(*) from pg_policies where schemaname = 'public'
         and tablename in ('funcionario_rh','uniforme_entregas','contracheques','emprestimos',
                           'emprestimo_descontos','adiantamentos','rh_config',
                           'envios_contabilidade','curriculos','avaliacoes_perfil'))    as regras_deve_ser_40,
       (select count(*) from storage.buckets where id = 'rh')                           as bucket_rh_deve_ser_1,
       (select count(*) from pg_policies where schemaname = 'storage' and policyname like 'rh\_%') as regras_arquivos_deve_ser_4,
       (select count(*) from pg_proc where proname in ('bvek_perfil_form','bvek_perfil_responder')) as funcoes_formulario_deve_ser_2;

select chave, valor from public.rh_config order by chave;
