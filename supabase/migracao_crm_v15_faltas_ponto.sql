-- =====================================================================
-- CRM Grupo BVEK — migração v15 (26/10/2026)
-- Faltas por tipo e leitura do ponto (Secullum)
--
-- Regras do André para as faltas do período (26 do mês anterior a 25):
--   Injustificada (sem justificativa) → desconta o dia, VR/VA e VT
--   Justificada (atestado, licença)   → desconta VR/VA e VT
--   Abonada (perdoada pela empresa)   → desconta só o VT
--   Férias                            → não é falta, mas não recebe VR/VA nem VT
--
--  1. competencia_funcionarios ganha as faltas por tipo, dias de férias,
--     horas de falta parcial (atrasos/saídas), marcações incompletas e o
--     detalhe dia a dia lido do Secullum. "dias_trabalhados" continua sendo
--     a BASE do mês (vazio = dias úteis); as faltas são descontadas dela.
--  2. tipos_beneficio ganha "desconta_abonada" (ligado no Vale-transporte).
--  3. rh_config: dia de fechamento do ponto (25) e a classificação das
--     justificativas do Secullum (editável no CRM).
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

-- 1. Faltas por tipo -----------------------------------------------------
alter table public.competencia_funcionarios add column if not exists faltas_injustificadas integer not null default 0;
alter table public.competencia_funcionarios add column if not exists faltas_justificadas   integer not null default 0;
alter table public.competencia_funcionarios add column if not exists faltas_abonadas       integer not null default 0;
alter table public.competencia_funcionarios add column if not exists dias_ferias           integer not null default 0;
alter table public.competencia_funcionarios add column if not exists horas_falta_min       integer not null default 0;
alter table public.competencia_funcionarios add column if not exists marcacoes_incompletas integer not null default 0;
alter table public.competencia_funcionarios add column if not exists detalhe               jsonb;
alter table public.competencia_funcionarios add column if not exists sincronizado_em       timestamptz;

alter table public.competencia_funcionarios drop constraint if exists competencia_funcionarios_faltas_chk;
alter table public.competencia_funcionarios add constraint competencia_funcionarios_faltas_chk
  check (faltas_injustificadas between 0 and 31 and faltas_justificadas between 0 and 31
         and faltas_abonadas between 0 and 31 and dias_ferias between 0 and 31
         and horas_falta_min >= 0 and marcacoes_incompletas between 0 and 31);

alter table public.competencia_funcionarios drop constraint if exists competencia_funcionarios_origem_chk;
alter table public.competencia_funcionarios add constraint competencia_funcionarios_origem_chk
  check (origem in ('manual','secullum'));

-- Os itens fechados guardam também as faltas da época
alter table public.competencia_itens add column if not exists faltas jsonb;

-- 2. Benefício que desconta falta abonada (VT) ---------------------------
alter table public.tipos_beneficio add column if not exists desconta_abonada boolean not null default false;
update public.tipos_beneficio set desconta_abonada = true
 where nome = 'Vale-transporte' and desconta_abonada = false
   and not exists (select 1 from public.rh_config where chave = 'v15_vt_marcado');

-- 3. Configuração ----------------------------------------------------------
insert into public.rh_config (chave, valor) values
  ('dia_fechamento_ponto', '25'),
  ('secullum_justificativas',
   '{"ATESTAD":"justificada","ATESTADO":"justificada","ASO":"justificada","LICENCA":"justificada","FERIAS":"ferias","FERIADO":"nao_falta","FOLGA":"nao_falta","COMPENS":"nao_falta","AULA":"abonada","TESTE":"nao_falta"}'),
  ('v15_vt_marcado', 'sim')
on conflict (chave) do nothing;

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'competencia_funcionarios'
         and column_name in ('faltas_injustificadas','faltas_justificadas','faltas_abonadas','dias_ferias',
                             'horas_falta_min','marcacoes_incompletas','detalhe','sincronizado_em'))   as colunas_novas_deve_ser_8,
       (select string_agg(nome, ', ') from public.tipos_beneficio where desconta_abonada)          as desconta_abonada_deve_ser_vale_transporte,
       (select count(*) from public.rh_config where chave in ('dia_fechamento_ponto','secullum_justificativas')) as config_deve_ser_2;
