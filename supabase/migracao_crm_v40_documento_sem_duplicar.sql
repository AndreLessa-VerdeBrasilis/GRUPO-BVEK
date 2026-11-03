-- =====================================================================
-- CRM Grupo BVEK — migração v40: documento atualizado não fica duplicado
-- ---------------------------------------------------------------------
-- O "mesmo documento" = mesmo tipo + mesmo titular (funcionário, ou
-- empresa quando é documento da empresa) + mesma descrição (ignorando
-- maiúsculas, acentos, espaços e pontuação).
--
-- 1. Função que gera essa descrição "limpa" para comparar.
-- 2. Limpeza: onde hoje há mais de uma versão VALENDO do mesmo documento,
--    fica só a de validade mais longa (empate: a lançada por último).
--    As outras vão para o histórico ("Renovado") — nada é apagado.
-- 3. Gatilho: sempre que uma versão nova passa a valer, as anteriores vão
--    sozinhas para o histórico. Vale também quando duas pessoas salvam o
--    mesmo documento ao mesmo tempo (a última a salvar fica valendo).
--
-- Pode rodar mais de uma vez.
-- =====================================================================

-- 1. descrição "limpa" (igual à comparação feita no CRM)
create or replace function public.bvek_doc_desc(t text) returns text
language sql immutable as $$
  select regexp_replace(
           translate(lower(coalesce(t, '')),
                     'áàâãäéèêëíìîïóòôõöúùûüçñ',
                     'aaaaaeeeeiiiiooooouuuucn'),
           '[^a-z0-9]', '', 'g');
$$;

create or replace function public.bvek_doc_chave(p_tipo uuid, p_func uuid, p_emp uuid, p_desc text) returns text
language sql immutable as $$
  select p_tipo::text || '|' ||
         case when p_func is not null then 'f:' || p_func::text else 'e:' || coalesce(p_emp::text, '') end
         || '|' || public.bvek_doc_desc(p_desc);
$$;

-- 2. limpeza das duplicatas que já existem
with grupos as (
  select id,
         first_value(id) over w as manter,
         row_number()    over w as n
  from public.documentos
  where situacao = 'vigente' and tipo_id is not null
  window w as (partition by public.bvek_doc_chave(tipo_id, funcionario_id, empresa_id, descricao)
               order by data_validade desc nulls last, criado_em desc)
)
update public.documentos d
   set situacao = 'substituido', substituido_por = g.manter, atualizado_em = now()
  from grupos g
 where d.id = g.id and g.n > 1;

-- 3. gatilho: a versão nova manda as anteriores para o histórico
create or replace function public.bvek_documento_unico() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text;
begin
  if new.situacao <> 'vigente' or new.tipo_id is null then return new; end if;
  k := public.bvek_doc_chave(new.tipo_id, new.funcionario_id, new.empresa_id, new.descricao);
  -- fila única por documento: se duas pessoas salvam juntas, uma espera a outra
  perform pg_advisory_xact_lock(hashtext('bvek_doc:' || k));
  update public.documentos d
     set situacao = 'substituido', substituido_por = new.id, atualizado_em = now()
   where d.id <> new.id
     and d.situacao = 'vigente'
     and d.tipo_id = new.tipo_id
     and public.bvek_doc_chave(d.tipo_id, d.funcionario_id, d.empresa_id, d.descricao) = k;
  return new;
end $$;

drop trigger if exists bvek_documento_unico on public.documentos;
create trigger bvek_documento_unico
  after insert or update of situacao, tipo_id, descricao, empresa_id, funcionario_id on public.documentos
  for each row when (new.situacao = 'vigente')
  execute function public.bvek_documento_unico();

-- Conferência: a 1ª linha deve mostrar 0 documentos duplicados valendo;
-- as demais mostram o que foi para o histórico agora há pouco.
select 'documentos duplicados ainda valendo' as item,
       count(*)::text as resultado, null::text as detalhe, null::text as valido_ate
  from (select 1 from public.documentos
         where situacao = 'vigente' and tipo_id is not null
         group by public.bvek_doc_chave(tipo_id, funcionario_id, empresa_id, descricao)
        having count(*) > 1) x
union all
select 'foi para o histórico (duplicado)',
       coalesce(f.nome, e.nome, '—'),
       t.nome || coalesce(' — ' || d.descricao, ''),
       to_char(d.data_validade, 'DD/MM/YYYY')
  from public.documentos d
  join public.tipos_documento t on t.id = d.tipo_id
  left join public.funcionarios f on f.id = d.funcionario_id
  left join public.empresas e on e.id = d.empresa_id
 where d.situacao = 'substituido' and d.atualizado_em > now() - interval '2 minutes';
