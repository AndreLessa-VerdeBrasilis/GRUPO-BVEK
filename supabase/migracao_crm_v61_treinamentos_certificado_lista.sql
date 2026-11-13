-- =====================================================================
-- CRM Grupo BVEK — migração v61
-- Emissão automática de treinamentos (NRs): certificado + lista de presença
--
--  1. tipos_documento.modelo_treinamento: o "modelo" de cada treinamento
--     (norma, título, carga horária, conteúdo programático e texto do
--     certificado). Editável no CRM (Documentos → Emitir treinamento).
--  2. treinamentos: cada turma emitida (data, local, instrutor, empresa
--     que certifica, participantes) com o PDF da lista de presença e,
--     depois, a lista assinada.
--  3. documentos.treinamento_id: o certificado de cada participante vira
--     um documento do funcionário (com validade e aviso de renovação),
--     ligado à turma.
--
-- Pode rodar mais de uma vez sem duplicar nada.
-- =====================================================================

-- 1. MODELO DE TREINAMENTO NO TIPO DE DOCUMENTO -------------------------
alter table public.tipos_documento add column if not exists modelo_treinamento jsonb;

-- tipos que ainda não existem (não mexe nos que já existem)
insert into public.tipos_documento (nome, categoria, orgao, validade_dias, dias_aviso, ordem) values
  ('NR-06 – EPI',                          'funcionario', null, null, 30, 220),
  ('NR-10 – Segurança em eletricidade',    'funcionario', null, 730,  30, 230),
  ('NR-12 – Máquinas e equipamentos',      'funcionario', null, null, 30, 240),
  ('NR-18 – Construção civil',             'funcionario', null, null, 30, 250),
  ('NR-33 – Espaço confinado',             'funcionario', null, 365,  30, 260),
  ('NR-35 – Trabalho em altura',           'funcionario', null, 730,  30, 270)
on conflict (nome) do nothing;

-- modelos iniciais (só onde o tipo ainda não tem modelo — o que foi editado no CRM fica)
with m(padrao, modelo) as (values
  ('^NR[[:space:]-]*0?6([^0-9]|$)', jsonb_build_object(
     'norma','NR 06','titulo','Equipamento de Proteção Individual','carga_horaria','04 horas',
     'conteudo', jsonb_build_array(
       'O que são Normas Regulamentadoras','NR 06 e regulamentações','Responsabilidades, direitos e obrigações',
       'Responsabilidades do empregador','Responsabilidades do trabalhador','Importância do EPI',
       'Proteção da cabeça','Proteção dos olhos e da face','Proteção auditiva','Proteção respiratória',
       'Proteção do tronco','Proteção dos membros superiores','Proteção dos membros inferiores',
       'Proteção do corpo inteiro','Proteção contra quedas','Uso correto do EPI e Certificado de Aprovação (CA)',
       'Conservação, higienização e armazenamento dos EPIs'))),
  ('^NR[[:space:]-]*10([^0-9]|$)', jsonb_build_object(
     'norma','NR 10','titulo','Segurança em Instalações e Serviços em Eletricidade','carga_horaria','40 horas',
     'conteudo', jsonb_build_array(
       'Introdução à segurança com eletricidade','Riscos em instalações e serviços com eletricidade: choque elétrico, arco elétrico, queimaduras e quedas',
       'Campos eletromagnéticos','Técnicas de análise de risco','Medidas de controle do risco elétrico: desenergização, aterramento, equipotencialização',
       'Dispositivos DR, barreiras, invólucros, bloqueios e impedimentos','Normas técnicas brasileiras (ABNT NBR 5410 e NBR 14039)',
       'Regulamentações do MTE: qualificação, habilitação, capacitação e autorização','Equipamentos de proteção coletiva',
       'Equipamentos de proteção individual','Rotinas de trabalho e procedimentos','Documentação das instalações elétricas',
       'Riscos adicionais: altura, ambientes confinados, áreas classificadas, umidade e condições atmosféricas',
       'Proteção e combate a incêndios','Acidentes de origem elétrica','Primeiros socorros','Responsabilidades'))),
  ('^NR[[:space:]-]*12([^0-9]|$)', jsonb_build_object(
     'norma','NR 12','titulo','Segurança no Trabalho em Máquinas e Equipamentos','carga_horaria','08 horas',
     'conteudo', jsonb_build_array(
       'Identificação dos riscos de cada máquina e equipamento e das proteções específicas',
       'Funcionamento das proteções: como e por que devem ser usadas',
       'Quando e por quem uma proteção pode ser removida','O que fazer se uma proteção for danificada ou perder a função',
       'Princípios de segurança na utilização da máquina ou equipamento','Riscos mecânicos, elétricos e outros relevantes',
       'Método de trabalho seguro','Permissão de trabalho',
       'Bloqueio da máquina durante inspeção, limpeza, lubrificação e manutenção'))),
  ('^NR[[:space:]-]*18([^0-9]|$)', jsonb_build_object(
     'norma','NR 18','titulo','Segurança e Saúde no Trabalho na Indústria da Construção','carga_horaria','04 horas',
     'conteudo', jsonb_build_array(
       'Condições e meio ambiente de trabalho no canteiro de obras','Riscos inerentes à função',
       'Uso adequado dos equipamentos de proteção individual (EPI)','Equipamentos de proteção coletiva (EPC) existentes no canteiro',
       'Programa de Gerenciamento de Riscos (PGR) da obra','Ordem, limpeza e organização do canteiro',
       'Procedimentos em situações de emergência'))),
  ('^NR[[:space:]-]*33([^0-9]|$)', jsonb_build_object(
     'norma','NR 33','titulo','Segurança e Saúde nos Trabalhos em Espaços Confinados — Trabalhador Autorizado e Vigia','carga_horaria','16 horas',
     'conteudo', jsonb_build_array(
       'Definições','Reconhecimento, avaliação e controle de riscos','Funcionamento dos equipamentos utilizados',
       'Procedimentos e utilização da Permissão de Entrada e Trabalho (PET)','Noções de resgate e primeiros socorros'))),
  ('^NR[[:space:]-]*35([^0-9]|$)', jsonb_build_object(
     'norma','NR 35','titulo','Trabalho em Altura','carga_horaria','08 horas',
     'conteudo', jsonb_build_array(
       'Normas e regulamentos aplicáveis ao trabalho em altura','Análise de risco e condições impeditivas',
       'Riscos potenciais do trabalho em altura e medidas de prevenção e controle',
       'Sistemas, equipamentos e procedimentos de proteção coletiva',
       'EPI para trabalho em altura: seleção, inspeção, conservação e limitação de uso',
       'Acidentes típicos em trabalhos em altura',
       'Condutas em situações de emergência, noções de resgate e primeiros socorros')))
)
update public.tipos_documento t
   set modelo_treinamento = m.modelo
  from m
 where t.categoria = 'funcionario'
   and t.modelo_treinamento is null
   and t.nome ~* m.padrao;

-- 2. TURMAS DE TREINAMENTO ----------------------------------------------
create table if not exists public.treinamentos (
  id                     uuid primary key default gen_random_uuid(),
  numero                 integer generated by default as identity,
  tipo_id                uuid references public.tipos_documento(id),
  norma                  text,
  titulo                 text,
  carga_horaria          text,
  data_realizacao        date not null,
  local                  text,
  cidade                 text,
  instrutor              text,
  instrutor_cargo        text,
  instrutor_registro     text,
  empresa_razao          text,
  empresa_fantasia       text,
  empresa_cnpj           text,
  conteudo               jsonb not null default '[]'::jsonb,
  texto_certificado      text,
  participantes          jsonb not null default '[]'::jsonb,  -- [{funcionario_id, nome, cpf, funcao, documento_id}]
  data_validade          date,
  lista_arquivo          text,
  lista_arquivo_nome     text,
  lista_assinada_arquivo text,
  lista_assinada_nome    text,
  observacoes            text,
  criado_por             text,
  criado_em              timestamptz not null default now(),
  atualizado_em          timestamptz not null default now()
);
create index if not exists treinamentos_data_idx on public.treinamentos (data_realizacao desc);

alter table public.documentos add column if not exists treinamento_id uuid references public.treinamentos(id) on delete set null;
create index if not exists documentos_treinamento_idx on public.documentos (treinamento_id);

-- 3. SEGURANÇA: mesma regra dos documentos dos funcionários (v46) --------
alter table public.treinamentos enable row level security;
drop policy if exists bvek_ler     on public.treinamentos;
drop policy if exists bvek_inserir on public.treinamentos;
drop policy if exists bvek_alterar on public.treinamentos;
drop policy if exists bvek_apagar  on public.treinamentos;
create policy bvek_ler     on public.treinamentos for select to authenticated
  using (public.bvek_pode('{administrador,administrativo,contabilidade}'));
create policy bvek_inserir on public.treinamentos for insert to authenticated
  with check (public.bvek_pode('{administrador,administrativo}'));
create policy bvek_alterar on public.treinamentos for update to authenticated
  using (public.bvek_pode('{administrador,administrativo}'))
  with check (public.bvek_pode('{administrador,administrativo}'));
create policy bvek_apagar  on public.treinamentos for delete to authenticated
  using (public.bvek_pode('{administrador}'));
grant select, insert, update, delete on public.treinamentos to authenticated;
revoke all on public.treinamentos from anon;

-- Conferência: os tipos de treinamento e se já têm modelo
select t.nome as tipo,
       coalesce(t.modelo_treinamento->>'norma', '— sem modelo (preencha ao emitir) —') as norma,
       t.modelo_treinamento->>'carga_horaria' as carga_horaria,
       jsonb_array_length(coalesce(t.modelo_treinamento->'conteudo', '[]'::jsonb)) as itens_conteudo,
       t.validade_dias,
       (select count(*) from public.treinamentos) as turmas_emitidas
  from public.tipos_documento t
 where t.categoria = 'funcionario' and (t.modelo_treinamento is not null or t.nome ~* '^NR')
 order by t.ordem, t.nome;
