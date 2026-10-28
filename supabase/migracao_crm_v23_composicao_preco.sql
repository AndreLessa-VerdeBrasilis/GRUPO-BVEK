-- =====================================================================
-- CRM Grupo BVEK — migração v23 (28/10/2026)
-- Composição de preço das propostas (cotação)
--
--  1. cards.composicao: a "planilha de custos" de cada proposta
--     (tipo de cliente, período/turno, equipe, materiais, equipamentos,
--      terceiros, mobilização, documentação e BDI).
--  2. precificacao_config: parâmetros do grupo usados como ponto de
--     partida em toda composição — custo/dia de cada função, adicionais
--     (sábado, domingo/feriado, noturno), BDI, impostos de cada empresa,
--     margem de lucro por tipo de cliente e custos de documentação.
--     Os valores iniciais são EXEMPLOS: o André ajusta em
--     Funil → card → 🧮 Composição de preço → ⚙️ Parâmetros.
--
-- Quem altera os parâmetros: só o Administrador.
-- Quem usa a composição: Administrador e Comercial (os demais só veem).
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado
-- (os parâmetros já ajustados não são sobrescritos).
-- =====================================================================

begin;

alter table public.cards add column if not exists composicao jsonb;

create table if not exists public.precificacao_config (
  id             integer primary key default 1,
  dados          jsonb not null default '{}'::jsonb,
  atualizado_em  timestamptz not null default now(),
  atualizado_por text
);
alter table public.precificacao_config drop constraint if exists precificacao_config_uma_linha;
alter table public.precificacao_config add constraint precificacao_config_uma_linha check (id = 1);

insert into public.precificacao_config (id, dados) values (1, $json$
{
  "funcoes": [
    {"nome": "Ajudante / servente",                 "custo_dia": 0},
    {"nome": "Auxiliar de limpeza",                 "custo_dia": 0},
    {"nome": "Jardineiro",                          "custo_dia": 0},
    {"nome": "Podador / operador de motosserra",    "custo_dia": 0},
    {"nome": "Pedreiro",                            "custo_dia": 0},
    {"nome": "Pintor",                              "custo_dia": 0},
    {"nome": "Eletricista",                         "custo_dia": 0},
    {"nome": "Encanador",                           "custo_dia": 0},
    {"nome": "Carpinteiro / armador",               "custo_dia": 0},
    {"nome": "Soldador / caldeireiro",              "custo_dia": 0},
    {"nome": "Alpinista industrial",                "custo_dia": 0},
    {"nome": "Operador de máquina",                 "custo_dia": 0},
    {"nome": "Motorista",                           "custo_dia": 0},
    {"nome": "Encarregado",                         "custo_dia": 0},
    {"nome": "Técnico de segurança do trabalho",    "custo_dia": 0},
    {"nome": "Engenheiro / arquiteto",              "custo_dia": 0}
  ],
  "adicionais": {"sabado": 50, "domingo_feriado": 100, "noturno": 20},
  "bdi": {"adm_central": 4.0, "seguros_garantia": 0.8, "risco": 1.27, "despesas_financeiras": 1.23},
  "tributos_empresa": {},
  "tributos_padrao": 0,
  "tipos_cliente": [
    {"nome": "Indústria / fábrica",               "lucro": 10},
    {"nome": "Condomínio",                        "lucro": 10},
    {"nome": "Comércio / escritório",             "lucro": 10},
    {"nome": "Shopping, hospital ou escola",      "lucro": 10},
    {"nome": "Órgão público / licitação",         "lucro": 10},
    {"nome": "Residencial / pessoa física",       "lucro": 10}
  ],
  "documentos": [
    {"nome": "ASO (exame médico)",                          "custo": 0, "por_pessoa": true},
    {"nome": "Treinamento NR-35 (trabalho em altura)",      "custo": 0, "por_pessoa": true},
    {"nome": "Treinamento NR-10 (eletricidade)",            "custo": 0, "por_pessoa": true},
    {"nome": "Treinamento NR-33 (espaço confinado)",        "custo": 0, "por_pessoa": true},
    {"nome": "Treinamento NR-12 / NR-18",                   "custo": 0, "por_pessoa": true},
    {"nome": "Integração / SSMA do cliente",                "custo": 0, "por_pessoa": true},
    {"nome": "EPI específico do cliente",                   "custo": 0, "por_pessoa": true},
    {"nome": "PGR / PCMSO específico da obra",              "custo": 0, "por_pessoa": false},
    {"nome": "ART / RRT",                                   "custo": 0, "por_pessoa": false},
    {"nome": "Seguro / apólice exigida pelo cliente",       "custo": 0, "por_pessoa": false},
    {"nome": "Autorização ambiental / de poda (prefeitura)", "custo": 0, "por_pessoa": false},
    {"nome": "Plano de rigging / permissão de trabalho",    "custo": 0, "por_pessoa": false}
  ]
}
$json$::jsonb)
on conflict (id) do nothing;

alter table public.precificacao_config enable row level security;
grant select, insert, update on public.precificacao_config to authenticated;
drop policy if exists bvek_ler     on public.precificacao_config;
drop policy if exists bvek_inserir on public.precificacao_config;
drop policy if exists bvek_alterar on public.precificacao_config;
create policy bvek_ler on public.precificacao_config for select to authenticated
  using (public.bvek_pode('{administrador,comercial,administrativo,consulta}'));
create policy bvek_inserir on public.precificacao_config for insert to authenticated
  with check (public.bvek_pode('{administrador}'));
create policy bvek_alterar on public.precificacao_config for update to authenticated
  using (public.bvek_pode('{administrador}')) with check (public.bvek_pode('{administrador}'));

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'cards' and column_name = 'composicao') as coluna_composicao_deve_ser_1,
       (select jsonb_array_length(dados->'funcoes') from public.precificacao_config where id = 1)   as funcoes_cadastradas,
       (select count(*) from pg_policies where schemaname = 'public' and tablename = 'precificacao_config') as regras_deve_ser_3;
