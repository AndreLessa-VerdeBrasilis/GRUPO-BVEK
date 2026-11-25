-- =====================================================================
-- CRM Grupo BVEK — migração v78 (25/11/2026)
--
-- 1. Diário de obra no portal do cliente: o banco deixa de mandar os
--    horários (início/fim do dia e a hora de cada registro) e o autor de
--    cada registro. As horas ficam só para o controle interno.
--
-- 2. Contratos → Custos × recebido (só Administrador): tabela
--    contratos_lancamentos para registrar, por contrato,
--      - o que o cliente PAGOU (recebimentos), e
--      - custos que não passam pelas Saídas do Financeiro
--        (terceiros, aluguel de equipamento, combustível etc.).
--    As compras (Financeiro → Saídas ligadas ao contrato) e a mão de obra
--    (Cronograma) já existem e o CRM soma sozinho.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. PORTAL DO CLIENTE: diário sem horários
-- ---------------------------------------------------------------------
create or replace function public.bvek_portal_dados() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cli uuid := public.bvek_meu_cliente_id(); v_clis uuid[] := public.bvek_meus_clientes(); r jsonb;
begin
  if cardinality(v_clis) = 0 then return null; end if;
  select jsonb_build_object(
    'cliente', (select jsonb_build_object('id', cl.id, 'codigo', cl.codigo, 'nome', cl.nome, 'razao_social', cl.razao_social,
                                          'documento', cl.documento, 'endereco', cl.endereco,
                                          'email', to_jsonb(cl)->>'email', 'telefone', to_jsonb(cl)->>'telefone')
                  from public.clientes cl where cl.id = coalesce(v_cli, v_clis[1])),
    'clientes', coalesce((select jsonb_agg(jsonb_build_object('id', cl.id, 'codigo', cl.codigo, 'nome', cl.nome, 'razao_social', cl.razao_social,
                                          'documento', cl.documento, 'endereco', cl.endereco,
                                          'email', to_jsonb(cl)->>'email', 'telefone', to_jsonb(cl)->>'telefone')
                                          order by (cl.id = v_cli) desc, cl.codigo)
                  from public.clientes cl where cl.id = any(v_clis)), '[]'::jsonb),
    'contratos', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'codigo', p.codigo, 'nome', p.nome, 'local', p.local, 'status', p.status, 'ano', p.ano,
        'cliente_id', p.cliente_id, 'cliente_codigo', clp.codigo, 'cliente_nome', clp.nome,
        'empresa_sigla', e.sigla, 'empresa_nome', e.nome,
        'periodo', (select jsonb_build_object('inicio', min(c.data_inicio), 'fim', max(c.data_fim))
                      from public.cronograma c where c.projeto_id = p.id and c.situacao = 'ativo'),
        'proposta', case when pc.ver_proposta then
            (select jsonb_build_object('numero', cd.numero_proposta, 'titulo', cd.titulo,
                                       'arquivo', cd.arquivo_proposta, 'arquivo_nome', cd.arquivo_proposta_nome)
               from public.cards cd where cd.id = pc.card_id) end,
        'ver_os', pc.ver_os,
        'os', case when pc.ver_os then public.bvek_os_do_projeto(p.id) end,
        'ver_diario', pc.ver_diario,
        'diarios', case when pc.ver_diario then coalesce((
            select jsonb_agg(jsonb_build_object(
                     'id', d.id, 'data', d.data,
                     'clima_manha', d.clima_manha, 'clima_tarde', d.clima_tarde, 'condicao', d.condicao,
                     'atividades', d.atividades, 'servicos', d.servicos, 'divergencias', d.divergencias,
                     'ocorrencias', d.ocorrencias, 'visitas', d.visitas, 'seguranca', d.seguranca, 'pendencias', d.pendencias,
                     'fotos', d.fotos,
                     'registros', (select coalesce(jsonb_agg(jsonb_build_object('texto', x->>'texto', 'foto', x->>'foto')
                                                             order by x->>'em'), '[]'::jsonb)
                                     from jsonb_array_elements(coalesce(d.registros, '[]'::jsonb)) x
                                    where coalesce(x->>'texto', '') <> '' or coalesce(x->>'foto', '') <> ''),
                     'equipe', (select coalesce(jsonb_agg(f.nome order by f.nome), '[]'::jsonb)
                                  from public.funcionarios f where f.id = any(case when cardinality(d.presentes) > 0 then d.presentes else d.equipe end)))
                   order by d.data desc)
              from public.diarios_obra d where d.projeto_id = p.id and d.situacao = 'fechado'), '[]'::jsonb) end,
        'documentos', case when pc.ver_documentos then coalesce((
            select jsonb_agg(jsonb_build_object('id', d.id, 'tipo', t.nome, 'descricao', d.descricao, 'orgao', d.orgao,
                                                'numero', d.numero, 'emissao', d.data_emissao, 'validade', d.data_validade,
                                                'arquivo', d.arquivo, 'arquivo_nome', d.arquivo_nome,
                                                'empresa_sigla', ed.sigla) order by t.nome)
              from public.documentos d left join public.tipos_documento t on t.id = d.tipo_id
              left join public.empresas ed on ed.id = d.empresa_id
             where d.id = any(pc.documentos) and d.funcionario_id is null and d.situacao = 'vigente'), '[]'::jsonb) end,
        'arquivos', coalesce((
            select jsonb_agg(jsonb_build_object('id', a.id, 'categoria', a.categoria, 'titulo', a.titulo, 'numero', a.numero,
                                                'data', a.data_documento, 'caminho', a.caminho, 'arquivo_nome', a.arquivo_nome)
                             order by a.data_documento desc nulls last, a.criado_em desc)
              from public.portal_arquivos a
             where a.projeto_id = p.id and a.visivel
               and ((a.categoria = 'inicio' and pc.ver_inicio) or (a.categoria in ('medicao','nota_fiscal') and pc.ver_medicoes))), '[]'::jsonb),
        'ver_inicio', pc.ver_inicio, 'ver_medicoes', pc.ver_medicoes)
        order by clp.codigo, p.codigo desc)
      from public.projetos p
      join public.portal_contratos pc on pc.projeto_id = p.id and pc.liberado
      left join public.clientes clp on clp.id = p.cliente_id
      left join public.empresas e on e.id = p.empresa_id
     where public.bvek_portal_contrato_meu(p.id)), '[]'::jsonb))
  into r;
  return r;
end $$;
revoke all on function public.bvek_portal_dados() from public, anon;
grant execute on function public.bvek_portal_dados() to authenticated;

-- ---------------------------------------------------------------------
-- 2. LANÇAMENTOS DO CONTRATO (recebimentos e outros custos)
-- ---------------------------------------------------------------------
create table if not exists public.contratos_lancamentos (
  id            uuid primary key default gen_random_uuid(),
  projeto_id    uuid not null references public.projetos(id) on delete cascade,
  tipo          text not null default 'recebimento',   -- recebimento · custo
  data          date not null,
  valor         numeric(14,2) not null,
  descricao     text,                                  -- ex.: "Roçada de outubro", "Aluguel de roçadeira"
  categoria     text,                                  -- custos: Terceiros, Equipamento, Combustível…
  documento     text,                                  -- nº da nota fiscal / recibo
  observacoes   text,
  criado_por    text,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.contratos_lancamentos drop constraint if exists contratos_lancamentos_tipo_chk;
alter table public.contratos_lancamentos add constraint contratos_lancamentos_tipo_chk check (tipo in ('recebimento','custo'));
alter table public.contratos_lancamentos drop constraint if exists contratos_lancamentos_valor_chk;
alter table public.contratos_lancamentos add constraint contratos_lancamentos_valor_chk check (valor >= 0);
create index if not exists contratos_lancamentos_proj_idx on public.contratos_lancamentos (projeto_id, data);

-- Só o Administrador vê e mexe (mesma regra do funil e dos valores, v46)
alter table public.contratos_lancamentos enable row level security;
drop policy if exists bvek_ler     on public.contratos_lancamentos;
drop policy if exists bvek_inserir on public.contratos_lancamentos;
drop policy if exists bvek_alterar on public.contratos_lancamentos;
drop policy if exists bvek_apagar  on public.contratos_lancamentos;
create policy bvek_ler     on public.contratos_lancamentos for select to authenticated using (public.bvek_pode('{administrador}'::text[]));
create policy bvek_inserir on public.contratos_lancamentos for insert to authenticated with check (public.bvek_pode('{administrador}'::text[]));
create policy bvek_alterar on public.contratos_lancamentos for update to authenticated
  using (public.bvek_pode('{administrador}'::text[])) with check (public.bvek_pode('{administrador}'::text[]));
create policy bvek_apagar  on public.contratos_lancamentos for delete to authenticated using (public.bvek_pode('{administrador}'::text[]));
revoke all on public.contratos_lancamentos from anon;
grant select, insert, update, delete on public.contratos_lancamentos to authenticated;

commit;

-- Conferência ------------------------------------------------------------------------
select 'tabela contratos_lancamentos' as item,
       case when to_regclass('public.contratos_lancamentos') is not null then 'ok' else 'FALTA' end as resultado
union all
select 'lançamentos já registrados', (select count(*)::text from public.contratos_lancamentos)
union all
select 'portal sem horários do diário',
       case when pg_get_functiondef('public.bvek_portal_dados()'::regprocedure) like '%hora_inicio%' then 'FALTA' else 'ok' end;
