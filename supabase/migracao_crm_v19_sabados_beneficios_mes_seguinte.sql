-- =====================================================================
-- CRM Grupo BVEK — migração v19 (28/10/2026)
-- Benefícios: sábados trabalhados e benefícios do mês seguinte
--
--  1. competencia_funcionarios.sabados_trabalhados
--       quantos sábados (meio período, 4h) o funcionário trabalhou no
--       período de apuração (26 do mês anterior a 25). É esporádico:
--       normalmente um intermitente e um encarregado CLT.
--  2. tipos_beneficio.conta_sabado
--       o benefício "por dia" que também paga os sábados trabalhados.
--       Regra do André: o VT conta o sábado; o VR NÃO conta (são só 4h).
--       Já deixa marcado no Vale-transporte.
--
-- Os benefícios passam a ser do MÊS SEGUINTE ao do fechamento:
-- o fechamento de 25/10 calcula com os dias úteis de NOVEMBRO e desconta
-- as faltas de 26/09 a 25/10. Isso é só regra de tela (não muda tabela).
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

alter table public.competencia_funcionarios
  add column if not exists sabados_trabalhados integer not null default 0;
alter table public.competencia_funcionarios drop constraint if exists competencia_funcionarios_sabados_chk;
alter table public.competencia_funcionarios add constraint competencia_funcionarios_sabados_chk
  check (sabados_trabalhados between 0 and 6);

alter table public.tipos_beneficio
  add column if not exists conta_sabado boolean not null default false;

-- VT conta o sábado (só marca se ainda ninguém mexeu)
update public.tipos_beneficio
   set conta_sabado = true
 where nome = 'Vale-transporte' and conta_sabado = false;

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'competencia_funcionarios'
           and column_name = 'sabados_trabalhados')                       as coluna_sabados_deve_ser_1,
       (select string_agg(nome, ', ') from public.tipos_beneficio
         where conta_sabado)                                              as beneficios_que_contam_sabado;
