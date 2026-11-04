-- =====================================================================
-- CRM Grupo BVEK — migração v49 (04/11/2026)
-- Currículos → 📣 Divulgar vaga
-- ---------------------------------------------------------------------
-- 1. Tabela "vagas_modelos": um modelo de divulgação por função
--    (salário, observação do salário, tipo de vaga, atividades, benefícios,
--    requisitos, experiência e local). O gerador abre a vaga já preenchida
--    e o RH só ajusta o que mudar.
-- 2. Já vem com as 3 vagas do modelo atual (Descrições das Vagas 2026):
--    Auxiliar de jardinagem, Ajudante de pedreiro e Pedreiro
--    (salários 2026/2027 conforme a CCT).
-- 3. Texto padrão de "Como se candidatar" (rh_config, chave vaga_como_candidatar).
-- Acesso: o mesmo dos currículos (Administrador e Administrativo).
--
-- Pode rodar mais de uma vez. Nada é apagado.
-- =====================================================================

create table if not exists public.vagas_modelos (
  id             uuid primary key default gen_random_uuid(),
  funcao         text not null,          -- título da vaga, ex.: PEDREIRO
  empresa_id     uuid references public.empresas(id) on delete set null,
  salario        numeric(12,2),
  salario_obs    text,                   -- ex.: atualizado 2026/2027 conf. CCT
  tipo_vaga      text,                   -- ex.: Efetivo CLT
  atividades     text,                   -- uma por linha
  beneficios     text,                   -- um por linha
  requisitos     text,                   -- um por linha
  experiencia    text,                   -- um por linha
  local_trabalho text,                   -- ex.: Presencial
  ativo          boolean not null default true,
  atualizado_em  timestamptz not null default now(),
  atualizado_por text
);
create unique index if not exists vagas_modelos_funcao_idx on public.vagas_modelos (upper(funcao));

alter table public.vagas_modelos enable row level security;
drop policy if exists bvek_ler     on public.vagas_modelos;
drop policy if exists bvek_inserir on public.vagas_modelos;
drop policy if exists bvek_alterar on public.vagas_modelos;
drop policy if exists bvek_apagar  on public.vagas_modelos;
create policy bvek_ler     on public.vagas_modelos for select to authenticated using (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_inserir on public.vagas_modelos for insert to authenticated with check (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_alterar on public.vagas_modelos for update to authenticated
  using (public.bvek_pode('{administrador,administrativo}'::text[])) with check (public.bvek_pode('{administrador,administrativo}'::text[]));
create policy bvek_apagar  on public.vagas_modelos for delete to authenticated using (public.bvek_pode('{administrador}'::text[]));
grant select, insert, update, delete on public.vagas_modelos to authenticated;
revoke all on public.vagas_modelos from anon;

-- modelos atuais (Descrições das Vagas 2026)
insert into public.vagas_modelos (funcao, salario, salario_obs, tipo_vaga, atividades, beneficios, requisitos, experiencia, local_trabalho, atualizado_por)
select v.funcao, v.salario, v.salario_obs, v.tipo_vaga, v.atividades, v.beneficios, v.requisitos, v.experiencia, v.local_trabalho, 'migração v49'
  from (values
  ('AUXILIAR DE JARDINAGEM', 1966.52, 'atualizado 2026/2027 conf. CCT', null,
   'Auxiliar na manutenção e conservação de jardins e áreas verdes
Realizar capina manual e limpeza de canteiros
Auxiliar no plantio de mudas, flores, árvores e gramas
Realizar poda de plantas, arbustos e cercas vivas
Efetuar irrigação e adubação de plantas
Auxiliar na preparação e conservação do solo
Realizar recolhimento e descarte adequado de resíduos vegetais
Auxiliar na utilização, limpeza e conservação de ferramentas e equipamentos de jardinagem
Manter os locais de trabalho limpos e organizados',
   'Assistência odontológica
Seguro de vida
Vale-refeição
Vale-transporte',
   'Fácil acesso à Avenida Brasil (preferencialmente candidatos que residam nas proximidades ou tenham facilidade de deslocamento até a região)',
   'CTPS (obrigatório)',
   'Presencial'),
  ('AJUDANTE DE PEDREIRO', 1851.90, 'atualizado 2026/2027 conf. CCT', 'Efetivo CLT',
   'Preparar e transportar materiais, ferramentas e equipamentos
Limpar e compactar solos
Preparar canteiros de obras
Preparar misturas de construção, como cimento e argamassa
Auxiliar na demolição de edificações
Montar e desmontar andaimes
Realizar pequenos reparos e ajustes
Manter ferramentas e equipamentos em ordem
Zelar pela conservação do canteiro de obras
Auxiliar no reboco das estruturas construídas com argamassa',
   'Assistência odontológica
Seguro de vida
Vale-refeição
Vale-transporte',
   null, null, null),
  ('PEDREIRO', 3140.23, 'atualizado 2026/2027 conf. CCT', 'Efetivo CLT',
   'Compreender plantas, cortes, elevações e detalhes técnicos
Seguir orientações de engenheiros, mestres de obras ou arquitetos
Assentamento de tijolos, blocos ou pedras
Construção de paredes, muros e divisórias
Execução de vergas, contravergas e pilares
Aplicação de reboco, chapisco e emboço
Instalação de pisos, azulejos e revestimentos cerâmicos
Aplicação de massa fina, massa corrida e argamassa
Construção de escadas, calçadas, rampas, churrasqueiras etc.
Concretagem de sapatas, vigas, lajes e colunas
Abertura de rasgos e canaletas para instalações elétricas e hidráulicas
Alinhamento e nivelamento de superfícies e estruturas
Correções em estruturas danificadas
Substituição de peças, demolições parciais e ampliações
Cumprimento das normas de segurança do trabalho
Uso correto de EPIs (Equipamentos de Proteção Individual)
Organização do ambiente de trabalho',
   'Assistência odontológica
Seguro de vida
Vale-refeição
Vale-transporte',
   null, null, null)
  ) as v(funcao, salario, salario_obs, tipo_vaga, atividades, beneficios, requisitos, experiencia, local_trabalho)
 where not exists (select 1 from public.vagas_modelos m where upper(m.funcao) = upper(v.funcao));

-- texto padrão de "Como se candidatar" (o RH muda no próprio gerador)
insert into public.rh_config (chave, valor) values
  ('vaga_como_candidatar', 'Interessados: enviar currículo pelo WhatsApp ou e-mail do RH, informando a vaga no assunto.')
on conflict (chave) do nothing;

-- Conferência: devem aparecer as 3 funções com o salário.
select funcao, salario, coalesce(tipo_vaga, '—') as tipo_vaga,
       array_length(string_to_array(atividades, chr(10)), 1) as qtd_atividades
  from public.vagas_modelos order by funcao;
