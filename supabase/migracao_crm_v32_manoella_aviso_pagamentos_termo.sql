-- =====================================================================
-- CRM Grupo BVEK — migração v32 (29/10/2026)
--
--  1. Cadastra a funcionária MANOELLA DA SILVA SANTANA (Gerente Geral /
--     Compliance, Verde Brasilis) para poder criar o login dela.
--     Dados tirados dos documentos do SharePoint (declarações de preposto).
--     Se ela já existir (mesmo nome ou mesmo CPF), só completa o que
--     estiver vazio — não duplica e não altera nada que já foi preenchido.
--  2. Pagamentos a autorizar: período de aviso ("alertar o André de tal
--     data até tal data"). Fora do período o pagamento não entra no
--     lembrete do WhatsApp nem no aviso do CRM. Sem datas = avisa sempre,
--     como antes.
--  3. Tipo de documento "Termo de adesão – assinatura eletrônica" para
--     guardar o termo de cada funcionário em Documentos.
--
-- Precisa da v11, v13, v20 já rodadas.
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. MANOELLA
-- ---------------------------------------------------------------------
update public.funcionarios f
   set cpf        = coalesce(f.cpf, '150.833.347-55'),
       cargo      = coalesce(f.cargo, 'Gerente Geral / Compliance'),
       empresa_id = coalesce(f.empresa_id, (select id from public.empresas where sigla = 'VB' limit 1))
 where public.bvek_nome_cmp(f.nome) = 'MANOELLA DA SILVA SANTANA'
    or regexp_replace(coalesce(f.cpf, ''), '\D', '', 'g') = '15083334755';

insert into public.funcionarios (nome, cargo, cpf, empresa_id, ativo)
select 'MANOELLA DA SILVA SANTANA', 'Gerente Geral / Compliance', '150.833.347-55',
       (select id from public.empresas where sigla = 'VB' limit 1), true
 where not exists (select 1 from public.funcionarios f
                    where public.bvek_nome_cmp(f.nome) in ('MANOELLA DA SILVA SANTANA', 'MANOELLA SANTANA')
                       or regexp_replace(coalesce(f.cpf, ''), '\D', '', 'g') = '15083334755');

-- ---------------------------------------------------------------------
-- 2. PERÍODO DE AVISO DOS PAGAMENTOS A AUTORIZAR
-- ---------------------------------------------------------------------
alter table public.pagamentos_autorizacao add column if not exists aviso_inicio date;  -- avisar a partir de
alter table public.pagamentos_autorizacao add column if not exists aviso_fim    date;  -- avisar até
alter table public.pagamentos_autorizacao drop constraint if exists pagamentos_autorizacao_aviso_chk;
alter table public.pagamentos_autorizacao add constraint pagamentos_autorizacao_aviso_chk
  check (aviso_inicio is null or aviso_fim is null or aviso_fim >= aviso_inicio);

-- hoje (horário de Brasília) está dentro do período de aviso?
create or replace function public.bvek_pagamento_no_aviso(p_inicio date, p_fim date)
returns boolean language sql stable as $$
  select (p_inicio is null or (now() at time zone 'America/Sao_Paulo')::date >= p_inicio)
     and (p_fim    is null or (now() at time zone 'America/Sao_Paulo')::date <= p_fim)
$$;

-- texto do lembrete: só o que está no período de aviso
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
     and public.bvek_pagamento_no_aviso(p.aviso_inicio, p.aviso_fim)
     and (auth.uid() is null or public.bvek_pode('{administrador,administrativo}'))
$$;

-- lembrete: igual à v20, mas respeitando o período de aviso
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
    from public.pagamentos_autorizacao
   where situacao = 'pendente' and lembrete_ativo
     and public.bvek_pagamento_no_aviso(aviso_inicio, aviso_fim);
  if v_qtd = 0 then return 'nada pendente no período de aviso'; end if;

  if not p_forcar then
    if not c.ativo then return 'lembrete desligado'; end if;
    if extract(hour from v_agora) < c.hora_inicio or extract(hour from v_agora) >= c.hora_fim then return 'fora do horário'; end if;
    if not c.fim_de_semana and extract(isodow from v_agora) in (6,7) then return 'fim de semana'; end if;
    if v_ultimo is not null and v_ultimo > now() - make_interval(mins => greatest(c.intervalo_min, 15) - 2) then
      return 'ainda no intervalo';
    end if;
  end if;

  v_texto := public.bvek_texto_pagamentos();
  perform public.bvek_whatsapp_enviar(v_texto, case when p_forcar then 'aviso manual' else 'lembrete automático' end);
  update public.pagamentos_autorizacao
     set avisos_enviados = avisos_enviados + 1, ultimo_aviso_em = now()
   where situacao = 'pendente' and lembrete_ativo
     and public.bvek_pagamento_no_aviso(aviso_inicio, aviso_fim);
  return 'enviado';
end $$;

revoke all on function public.bvek_avisar_pagamentos(boolean) from public, anon;
revoke all on function public.bvek_texto_pagamentos()         from public, anon;
grant execute on function public.bvek_avisar_pagamentos(boolean) to authenticated;
grant execute on function public.bvek_texto_pagamentos()         to authenticated;
grant execute on function public.bvek_pagamento_no_aviso(date, date) to authenticated;

-- ---------------------------------------------------------------------
-- 3. TIPO DE DOCUMENTO DO TERMO DE ADESÃO
-- ---------------------------------------------------------------------
insert into public.tipos_documento (nome, categoria, orgao, validade_dias, dias_aviso, ordem)
values ('Termo de adesão – assinatura eletrônica', 'funcionario', 'RH', null, 0, 205)
on conflict (nome) do nothing;

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from public.funcionarios
         where regexp_replace(coalesce(cpf, ''), '\D', '', 'g') = '15083334755')                 as manoella_deve_ser_1,
       (select count(*) from information_schema.columns where table_schema = 'public'
         and table_name = 'pagamentos_autorizacao' and column_name in ('aviso_inicio','aviso_fim')) as colunas_aviso_deve_ser_2,
       (select count(*) from public.tipos_documento
         where nome = 'Termo de adesão – assinatura eletrônica')                                    as tipo_termo_deve_ser_1;
