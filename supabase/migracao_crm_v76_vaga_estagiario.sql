-- =====================================================================
-- CRM Grupo BVEK — migração v76 (25/11/2026)
-- Currículos → Divulgar vaga: modelo "ESTAGIÁRIO DE ENGENHARIA CIVIL"
-- ---------------------------------------------------------------------
-- Acrescenta o modelo da vaga de estágio, com atividades, benefícios,
-- requisitos e diferenciais. O valor da bolsa fica em branco: o RH
-- preenche no gerador (campo "Salário") quando estiver definido.
-- Odonto e TotalPass não entraram nos benefícios (falta confirmar se
-- valem para estagiário) — o RH acrescenta no gerador se valer.
--
-- Pode rodar mais de uma vez: se o modelo já existir, nada muda.
-- =====================================================================

insert into public.vagas_modelos (funcao, salario, salario_obs, tipo_vaga, atividades, beneficios, requisitos, experiencia, local_trabalho, atualizado_por)
select v.funcao, null, null, v.tipo_vaga, v.atividades, v.beneficios, v.requisitos, v.experiencia, v.local_trabalho, 'migração v76'
  from (values
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
Recesso remunerado de 30 dias a cada 12 meses de estágio
Jornada de até 6 horas por dia (30 horas por semana), compatível com a faculdade',
   'Cursando Engenharia Civil (aceitamos Engenharia de Produção), do 4º ao 8º período
AutoCAD
Pacote Office completo (Excel, Word, PowerPoint e Outlook)
Disponibilidade para ir a obras e clientes no Rio de Janeiro
Boa comunicação com clientes, equipes de campo e escritório
Perfil desenrolado, engajado e proativo
Organização e cuidado com documentos',
   'MS Project (diferencial — oferecemos curso)',
   'Presencial — escritório e obras/clientes')
  ) as v(funcao, tipo_vaga, atividades, beneficios, requisitos, experiencia, local_trabalho)
 where not exists (select 1 from public.vagas_modelos m where upper(m.funcao) = upper(v.funcao));

-- Conferência: deve aparecer a linha do estágio com 7 atividades, 7 benefícios e 7 requisitos.
select funcao, tipo_vaga, local_trabalho,
       array_length(string_to_array(atividades, chr(10)), 1) as qtd_atividades,
       array_length(string_to_array(beneficios, chr(10)), 1) as qtd_beneficios,
       array_length(string_to_array(requisitos, chr(10)), 1) as qtd_requisitos
  from public.vagas_modelos
 where upper(funcao) = upper('ESTAGIÁRIO DE ENGENHARIA CIVIL');
