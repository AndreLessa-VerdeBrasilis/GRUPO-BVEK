# CRM Grupo BVEK — instruções para o Claude Code

Sempre responda em português. O dono do sistema é o André Lessa (sócio do Grupo BVEK). Ele construiu o CRM sem formação em programação: explique as mudanças em linguagem simples, sem jargão desnecessário.

## O sistema

- CRM web sem framework: um único arquivo `index.html` (HTML + CSS + JavaScript) que conversa direto com o Supabase.
- Repositório: `AndreLessa-VerdeBrasilis/GRUPO-BVEK`, branch `main`.
- Deploy automático na Vercel a cada push: https://grupo-bvek.vercel.app
- Banco: Supabase, projeto https://smusenaszgkqkjjwblyi.supabase.co
- Tabelas principais: `clientes`, `contatos`, `cards` (funil/kanban), `itens_proposta`, `sequencia_propostas`, `projetos`, `atividades`, `historico_etapas`, `empresas`.
- Empresas do grupo: **Engekat** (EK, Engekat Construções), **Verde Brasilis** (VB), **BrasiLimp** (BL) e **Kat Corretora** (KS).
- Outros arquivos: `perfil.html` + `perfil-questionario.js` (formulário de perfil para candidatos) e `supabase/functions/` (funções do Supabase: `email-contabilidade`, `email-comunicado`, `secullum`, `sharepoint`, `push`, `outlook-agenda` — cronograma ↔ calendário do Outlook — e `convocacao` — aviso da alocação do cronograma ao funcionário por WhatsApp/Meta e e-mail; configuração própria em Cronograma → ⚙️ WhatsApp, tabela `whatsapp_convocacao_config`, separada do lembrete de pagamentos do Financeiro) e `modelos/` (modelos de documentos, ex.: termo de adesão à assinatura eletrônica).

## Regras de negócio (NÃO alterar sem pedido explícito do André)

- **Cliente**: código fixo `C###` (C001, C002…). Nunca é reaproveitado, nem quando o cliente é mesclado ou excluído. O próximo é sempre o maior existente + 1.
- **Projeto**: código `C###-NNNN` (cliente + sequência única de 4 dígitos do grupo inteiro).
  - Pasta do projeto fica no site da empresa executora: Engekat `10.2_PROJETOS`, Verde Brasilis `20.2_PROJETOS`, BrasiLimp `30.2_PROJETOS`.
- **Pasta do cliente na rede**: `Grupo BVEK/03_CLIENTES/C###_NOME`, com subpastas `01_CADASTRO`, `02_PROPOSTAS`, `03_CONTRATOS`, `04_NOTAS FISCAIS`.
- **Proposta**: `C###-NNNN-PRP-SSSS_RXX` (`0000` quando ainda não há projeto; revisões R00, R01…). Este padrão substitui o antigo (ex.: `VB001-0626.V1`) — se encontrar resquícios do padrão antigo no código, avise antes de mexer.
- O CRM, a planilha `BVK-GES-CTL-REGISTRO DE CLIENTES E PROJETOS EDITAVEL.xlsx` (em `00_GESTAO\00.5_REGISTROS`) e as pastas da rede usam os mesmos códigos. **Sempre que uma mudança criar cliente ou projeto, avise o André para atualizar os três.**

## Como trabalhar

1. **Antes de mexer**, leia o `index.html` atual e as migrações em `supabase/`. Não reescreva o que já funciona; faça a menor mudança que resolve.
2. **Decisões do André**: se algo exigir regra de negócio, nome, campo novo ou mudança de comportamento visível, pergunte antes de implementar.
3. **Banco de dados**:
   - Toda mudança de banco vira um arquivo novo em `supabase/` no formato `migracao_crm_vNN_descricao.sql`, com o próximo número (confira o maior existente; em 06/nov/2026 a última era a v51).
   - A migração precisa poder rodar mais de uma vez sem duplicar nada (`if not exists`, `where not exists`, `create or replace`, `on conflict do nothing`).
   - Termine o arquivo com um `select` que permita ao André conferir o resultado.
   - **Funil só do administrador (desde a v46):** propostas (`cards`, `itens_proposta`, histórico), contratos fixos, valores e PDFs das propostas só chegam ao Administrador — o banco não manda para os outros perfis. Antes (v36) a regra era: o perfil Comercial não recebe `cards.valor_estimado`, `cards.composicao`, `itens_proposta.valor_unitario/valor_total` nem `contratos_recorrentes.valor_mensal/custo_mensal`. O front-end lê propostas, itens e contratos pelas funções `bvek_cards`, `bvek_itens_proposta` e `bvek_contratos` (nunca `select('*')` direto nessas tabelas). Migração que criar coluna nova nessas três tabelas deve terminar com `select public.bvek_proteger_valores();`.
   - O André roda o SQL manualmente no SQL Editor do Supabase. Não execute SQL no banco de produção por conta própria. Quando o código depender da migração, diga claramente: "rode a migração vNN ANTES de testar".
4. **Nunca apague dados nem colunas** sem aprovação explícita. Prefira adicionar/desativar a remover.
5. **Segredos**: senhas, service_role key, tokens e credenciais nunca vão para arquivos do repositório nem para mensagens de commit. A chave anon pública do Supabase já usada no front-end pode permanecer como está.
6. **Commit e push**: ao terminar e testar, faça commit em `main` com mensagem clara no padrão `CRM vNN: descrição curta` e faça push (isso publica na Vercel).
7. **Ao final de cada tarefa**, entregue ao André:
   - o que mudou, em poucas linhas;
   - se há migração para rodar (nome do arquivo);
   - um roteiro curto do que testar em https://grupo-bvek.vercel.app depois do deploy;
   - se criou cliente/projeto: lembrete de atualizar planilha e pastas.
8. Teste localmente antes do push sempre que possível (abrir o `index.html` num servidor local e verificar o console do navegador sem erros).

## Decisões já tomadas pelo André (contexto para novas funções)

Boa parte disto já foi implementada nas versões v11 a v18 (acessos, documentos, cobrança, RH, currículos, faltas, folha do mês, perfil de contracheque). Confira no código e nas migrações o que já existe antes de construir algo destas listas.

**Perfis de acesso**
- Administrador, Comercial, Administrativo — todos veem todas as empresas; a restrição é só por cargo. O perfil Consulta foi removido na v46.
- Funil, propostas, valores e contratos: só o Administrador (v46). Os outros sabem os clientes e projetos, e só isso.
- Cadastro completo dos funcionários (CPF, PIS, e-mail…) e documentos dos funcionários: só Administrador, Administrativo e Contabilidade (v46). Os outros perfis recebem só nome, cargo e empresa (`bvek_funcionarios_basico`).
- Contabilidade: vê só RH e documentos (ponto, VA, VT, academia, odonto etc.).
- "Funcionário (contracheque e ponto)": login por CPF + senha, vê todos os contracheques do CPF e as próprias marcações do ponto (Secullum, ação `meu_ponto`).
- Objetivo: abrir o CRM deve ser o primeiro movimento dos funcionários ao chegar no escritório.
- Painel completo (funil, valores, contratos, ganhos × custos) só para o Administrador (v45). Os outros perfis veem o "Painel da equipe": tarefas, agenda do escritório, quem está onde hoje e documentos — nunca propostas, valores ou contratos.
- Cronograma (v45): todos os perfis do escritório (Administrador, Comercial, Administrativo e Contabilidade) veem, criam e alteram alocações (só o administrador apaga). Quem não é do RH vê só o nome dos funcionários. Só os intermitentes entram na folha pelo cronograma.
- Agenda do escritório (v45): caixa `agenda@bvek.com.br` no Microsoft 365, tabela `agenda_escritorio`, linha "🏢 Escritório" no Cronograma. Eventos do escritório não entram na folha.

**Funil / propostas**
- Cobrança de retorno das propostas enviadas é feita com colunas no funil atual (não em aba ou funil separado).
- PDF da proposta segue o modelo da proposta da Vibra (`C091-0000-PRP-0019_R00`, SharePoint `03_CLIENTES/C091_VIBRA/02_PROPOSTAS`): carta de apresentação, quadro-resumo, seções numeradas, planilha com subtotais por etapa, condições comerciais e assinaturas. **Nunca mostrar margem de lucro** (nem BDI/impostos separados) na proposta.
- Identidade visual dos PDFs (proposta e OS): logos e marcas d'água em `img/logos/` (as mesmas das atas, `00.5.1.1_MODELOS/_sistema`) e as cores de cada empresa em `TEMAS_EMPRESA` no `index.html` — Engekat é azul (#1E3A5F/#2E6DB4), Verde Brasilis verde/laranja, BrasiLimp azul. Fundos sempre claros (sem faixas sólidas).
- Textos fixos do modelo ficam em ⚙️ Parâmetros (`precificacao_config.dados.proposta`). Dados bancários só no banco — o repositório é público.
- Impostos na composição de preço: preço = custo total ÷ 0,85 (15% sobre o preço).
- Ordem de serviço: número da proposta com OS no lugar de PRP (`C###-NNNN-OS-SSSS`), sem valores.

**Controle de documentos**
- Certidões das empresas do grupo, documentos de funcionários e renovação do CAU, com alertas de vencimento (já houve renovações em cima da hora).

**RH**
- Funcionários registrados só no CNPJ da Verde Brasilis. Aila e André são sócios (pró-labore) e não batem ponto. Intermitentes não estão no Secullum e só entram na folha do mês em que foram convocados.
- Ponto: Tecnoponto / sistema Secullum (homologado, pelo celular). Ponto no CRM só via integração com o Secullum. Prioridade principal do RH: puxar faltas e dias trabalhados do Secullum.
- Benefícios: cadastro + fechamento mensal; VA/VT pelos dias trabalhados; academia é TotalPass.
- Faltas (apuradas de 26 do mês anterior a 25):
  - injustificada: desconta o dia + VT + VR;
  - justificada (atestado, licença): desconta VT e VR;
  - abonada: desconta só VT.
- Envio mensal à contabilidade Innove (thais.ribeiro@innovecontabil.com.br e dp@innovecontabil.com.br) todo dia 25: a Sulamita (perfil administrador) confere no CRM e clica Enviar, via Microsoft 365, usando a caixa sulamita.decanio@bvek.com.br como remetente.
- Adiantamento de 40% do salário no dia 15 para quem solicita; vales (empréstimos informais) descontados com valor livre mês a mês.
- Regra de prazos (dia 25 e dia 15): sábado → sexta anterior; domingo → segunda seguinte; feriado → dia útil anterior.
- Contracheques: a contabilidade manda um PDF único sem CPF; o CRM separa por funcionário e acrescenta nome, CPF, admissão e função.
- Salário, contracheques e vales visíveis para admin, administrativo e contabilidade. Ponto/benefícios visíveis para admin, administrativo e contabilidade (desde a v28 o comercial não acessa o RH).

**Currículos**
- Banco de currículos (inclui freelas) com análise de perfil e formulário de perfil emocional para candidatos, com parecer do RH.
- Divulgação de vagas (v49): botão "📣 Divulgar vaga" em Currículos, com modelos por função na tabela `vagas_modelos` (salário conforme CCT, atividades, benefícios, requisitos) e texto padrão "Como se candidatar" em `rh_config.vaga_como_candidatar`. Gera texto para WhatsApp/redes, texto simples para sites de emprego e PDF com a identidade visual da empresa.

**Obras (v51)**
- Ordem de serviço detalhada: botão "🧭 Detalhar execução (OS)" na proposta, tabela `os_detalhes` (condições do local, incluído / NÃO incluído, como deve ficar, quando parar e consultar, segurança, "como executar" item a item). Sai só na OS, nunca na proposta. Campo em branco sai na OS como "⚠️ não informado — confirmar com o responsável".
- Diário de obra: aba "Diário de obra" e aba "📒 Diário de obra" no login do funcionário (CPF). Tabela `diarios_obra`; `bvek_diarios_gerar` cria o diário de cada dia com equipe alocada num projeto no Cronograma. A equipe preenche (só os diários dela, via `bvek_diario_salvar`); Administrador e Administrativo conferem e fecham. Relatório em PDF para o cliente (sem valores, com ciência do cliente). Fotos no bucket `diarios`.
- Documentos do SharePoint dos funcionários: espelho na tabela `documentos_sharepoint` (um registro por arquivo, `sp_id` único), gravado só pela função `sharepoint` (`sincronizar_colaboradores`); arquivo enviado pelo CRM fica ligado ao documento e aparece uma vez só.
- Reunião do escritório marcada no Outlook: convidar `agenda@bvek.com.br` (senão vira alocação "sem cliente"; acrescentar a agenda depois e sincronizar tira a alocação do cronograma sem apagar o evento).
