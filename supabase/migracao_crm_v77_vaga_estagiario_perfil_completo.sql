-- =====================================================================
-- CRM Grupo BVEK — migração v77 (25/11/2026)
-- Currículos → Divulgar vaga: modelo "ESTAGIÁRIO DE ENGENHARIA CIVIL"
-- com o perfil completo (leitura de projetos, Excel intermediário,
-- escrita técnica, soft skills de campo, permanência, teste prático,
-- avaliação semestral e integração NR-18/NR-35).
-- ---------------------------------------------------------------------
-- - Se a v76 ainda não foi rodada: cria o modelo já completo.
-- - Se a v76 foi rodada e o RH ainda não mexeu no modelo: atualiza.
-- - Se o RH já alterou o modelo pelo CRM: NÃO mexe (o select do fim mostra).
-- O valor da bolsa continua em branco (o RH preenche no gerador).
-- Pode rodar mais de uma vez.
-- =====================================================================

with v(funcao, tipo_vaga, atividades, beneficios, requisitos, experiencia, local_trabalho) as (values
  ('ESTAGIÁRIO DE ENGENHARIA CIVIL',
   'Estágio (Lei 11.788/2008)',
   'Acompanhar visitas técnicas e fazer levantamentos (medidas, fotos e condições do local)
Desenhar croquis, plantas e detalhes no AutoCAD
Levantar quantitativos e montar planilhas de orçamento para as propostas
Montar e atualizar cronogramas de obra e a escala das equipes
Acompanhar obras e serviços: diário de obra, fotos, medições e relatório de conclusão
Organizar documentos de segurança do trabalho para integração nos clientes
Apoiar os controles da ISO 9001/14001, o cadastro de fornecedores e o inventário',
   'Bolsa-auxílio
Auxílio-transporte
Vale-refeição
Seguro contra acidentes pessoais
Curso de MS Project pago pela empresa
Treinamento de NR-18 e NR-35 na integração
Avaliação semestral com conversa de retorno
Recesso remunerado de 30 dias a cada 12 meses de estágio
Jornada de até 6 horas por dia (30 horas por semana), compatível com a faculdade',
   'Cursando Engenharia Civil (aceitamos Engenharia de Produção), do 4º ao 8º período
Leitura e interpretação de projetos (arquitetônico, estrutural e de instalações)
AutoCAD
Excel intermediário (fórmulas, PROCV, filtros e planilha de quantitativo)
Word, PowerPoint e Outlook
Escrita técnica: e-mail formal, relatório e diário de obra em português correto
Disponibilidade para ir a obras e clientes no Rio de Janeiro (sol, obra e uso de EPI fazem parte)
Disponibilidade de 6 horas por dia no turno combinado na entrevista
Permanência mínima de 1 ano
Perfil desenrolado, proativo e engajado
Boa comunicação com clientes, escritório e equipe de campo (de igual para igual com encarregado, pedreiro e jardineiro)
Postura em cliente: pontualidade, apresentação e respeito às regras de segurança
Saber lidar com várias frentes ao mesmo tempo
Avisar cedo quando algo dá errado e pedir ajuda
Organização e discrição com documentos, preços e dados de clientes
A seleção inclui teste prático de AutoCAD e Excel',
   'Diferencial: MS Project (oferecemos curso)
Diferencial: noções de orçamento por composição (EMOP ou SINAPI)
Diferencial: noções de NR-18 e NR-35
Diferencial: CNH categoria B',
   'Presencial — escritório e obras/clientes')
),
atualiza as (
  update public.vagas_modelos m
     set tipo_vaga = v.tipo_vaga, atividades = v.atividades, beneficios = v.beneficios,
         requisitos = v.requisitos, experiencia = v.experiencia, local_trabalho = v.local_trabalho,
         atualizado_em = now(), atualizado_por = 'migração v77'
    from v
   where upper(m.funcao) = upper(v.funcao)
     and m.atualizado_por in ('migração v76', 'migração v77')
  returning m.id
)
insert into public.vagas_modelos (funcao, tipo_vaga, atividades, beneficios, requisitos, experiencia, local_trabalho, atualizado_por)
select v.funcao, v.tipo_vaga, v.atividades, v.beneficios, v.requisitos, v.experiencia, v.local_trabalho, 'migração v77'
  from v
 where not exists (select 1 from public.vagas_modelos m where upper(m.funcao) = upper(v.funcao));

-- Conferência: atualizado_por deve ser "migração v77", com 7 atividades,
-- 9 benefícios, 16 requisitos e 4 diferenciais. Se aparecer outro nome em
-- atualizado_por, o RH já tinha alterado o modelo e ele foi mantido.
select funcao, atualizado_por,
       array_length(string_to_array(atividades, chr(10)), 1) as qtd_atividades,
       array_length(string_to_array(beneficios, chr(10)), 1) as qtd_beneficios,
       array_length(string_to_array(requisitos, chr(10)), 1) as qtd_requisitos,
       array_length(string_to_array(experiencia, chr(10)), 1) as qtd_diferenciais
  from public.vagas_modelos
 where upper(funcao) = upper('ESTAGIÁRIO DE ENGENHARIA CIVIL');
