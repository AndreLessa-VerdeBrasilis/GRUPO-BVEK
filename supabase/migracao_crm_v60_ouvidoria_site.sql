-- =====================================================================
-- CRM v60: Ouvidoria do site (www.bvek.com.br/ouvidoria) no canal de denúncias
--
-- O formulário da Ouvidoria no site do Grupo BVEK grava no MESMO canal de
-- denúncias do CRM (tabela public.denuncias, RH → Denúncias), sem login.
--   * coluna "origem": 'funcionario' (acesso por CPF) ou 'site' (Ouvidoria do site)
--   * coluna "tipo": Denúncia, Reclamação, Sugestão ou Elogio
--   * coluna "contato": só se a pessoa QUISER se identificar (opcional)
--   * protocolo do site começa com OUV- (o dos funcionários continua DEN-)
--   * continua anônimo: não guarda nome, login, IP nem horário — só a data
--   * limite de 300 relatos por dia vindos do site (proteção contra robôs)
-- Pode rodar mais de uma vez sem duplicar nada.
-- =====================================================================

alter table public.denuncias add column if not exists origem  text not null default 'funcionario';
alter table public.denuncias add column if not exists tipo    text not null default 'Denúncia';
alter table public.denuncias add column if not exists contato text;

alter table public.denuncias drop constraint if exists denuncias_origem_chk;
alter table public.denuncias add constraint denuncias_origem_chk check (origem in ('funcionario','site'));
alter table public.denuncias drop constraint if exists denuncias_tipo_chk;
alter table public.denuncias add constraint denuncias_tipo_chk check (tipo in ('Denúncia','Reclamação','Sugestão','Elogio'));

-- envio pela Ouvidoria do site (sem login); devolve o protocolo OUV-XXXXXXXX
create or replace function public.bvek_ouvidoria_enviar(
  p_tipo text, p_categoria text, p_descricao text,
  p_local text, p_quando text, p_envolvidos text, p_contato text)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare prot text; tent integer := 0; v_tipo text;
begin
  v_tipo := case when p_tipo in ('Denúncia','Reclamação','Sugestão','Elogio') then p_tipo else 'Denúncia' end;
  if coalesce(trim(p_descricao), '') = '' or length(trim(p_descricao)) < 10 then
    raise exception 'Descreva o que aconteceu.';
  end if;
  if (select count(*) from public.denuncias where origem = 'site' and recebida_em = current_date) >= 300 then
    raise exception 'Muitos relatos hoje. Tente de novo amanhã ou ligue (21) 3040-3700.';
  end if;
  loop
    tent := tent + 1;
    prot := 'OUV-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.denuncias where protocolo = prot) or tent > 5;
  end loop;
  insert into public.denuncias (protocolo, origem, tipo, categoria, descricao, local, quando, envolvidos, contato)
  values (prot, 'site', v_tipo,
          left(coalesce(nullif(trim(p_categoria), ''), 'Outro'), 80),
          left(trim(p_descricao), 8000),
          left(nullif(trim(p_local), ''), 300),
          left(nullif(trim(p_quando), ''), 200),
          left(nullif(trim(p_envolvidos), ''), 1000),
          left(nullif(trim(p_contato), ''), 300));
  return prot;
end $$;

-- consulta pelo protocolo do site (só mostra situação e a resposta; nunca o relato)
create or replace function public.bvek_ouvidoria_consultar(p_protocolo text)
returns table (protocolo text, tipo text, categoria text, recebida_em date, situacao text, resposta text, respondida_em date)
language sql stable security definer set search_path = public as $$
  select d.protocolo, d.tipo, d.categoria, d.recebida_em, d.situacao, d.resposta, d.respondida_em
    from public.denuncias d
   where d.origem = 'site'
     and d.protocolo = upper(trim(p_protocolo))
$$;

revoke all on function public.bvek_ouvidoria_enviar(text, text, text, text, text, text, text) from public;
revoke all on function public.bvek_ouvidoria_consultar(text) from public;
grant execute on function public.bvek_ouvidoria_enviar(text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.bvek_ouvidoria_consultar(text) to anon, authenticated;

-- a tabela continua fechada para quem não tem login (o site só usa as duas funções acima)
revoke all on public.denuncias from anon;

-- Conferência: as 3 colunas novas e as 2 funções devem aparecer com "ok = true"
select 'coluna ' || c as item, exists (select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'denuncias' and column_name = c) as ok
  from unnest(array['origem','tipo','contato']) c
union all
select 'função ' || f, exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = f)
  from unnest(array['bvek_ouvidoria_enviar','bvek_ouvidoria_consultar']) f;
