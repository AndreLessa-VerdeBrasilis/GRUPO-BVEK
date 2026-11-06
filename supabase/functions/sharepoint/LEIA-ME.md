# Ligação do CRM com o SharePoint (v34)

A função `sharepoint` copia para o SharePoint, já com o nome no padrão do memorial,
os arquivos que o CRM gera ou recebe, e mostra dentro do CRM os arquivos da pasta de
cada funcionário. O SharePoint continua sendo o lugar oficial (fonte única); o CRM
só envia e mostra.

| O que                         | Nome                                             | Pasta (site Grupo BVEK)                                   |
|-------------------------------|--------------------------------------------------|-----------------------------------------------------------|
| Contracheque separado         | `BVK-RH-HOL-NOME_COMPLETO_AAAAMM.pdf`            | 01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS/NOME |
| Termo de adesão               | `BVK-RH-CTR-TERMO_ADESAO_ASSINATURA_ELETRONICA_NOME.pdf` | idem                                              |
| Declaração de premiação       | `BVK-RH-DOC-DECLARACAO_PREMIO_NOME_AAAAMM.pdf`   | idem                                                      |
| Documento de funcionário      | conforme o tipo (ASO, TRE, CTR, DOC…)            | idem                                                      |
| PDF da proposta               | `C###-NNNN-PRP-SSSS_RXX.pdf`                     | 03_CLIENTES/C###_NOME/02_PROPOSTAS                        |

## Como ligar (uma vez só)

1. **Azure / Microsoft Entra** (portal.azure.com → Registros de aplicativo → o mesmo
   aplicativo já usado para o e-mail da contabilidade):
   - *Permissões de API* → *Adicionar* → *Microsoft Graph* → **Permissões de aplicativo**
     → `Sites.ReadWrite.All` → *Adicionar*.
   - Clique em **Conceder consentimento do administrador**.
2. **Supabase** → Edge Functions → *Deploy new function* com o nome `sharepoint` e o
   conteúdo de `index.ts` (ou `supabase functions deploy sharepoint`).
   Os segredos `MS_TENANT_ID`, `MS_CLIENT_ID` e `MS_CLIENT_SECRET` já existem (são os do e-mail).
3. Abra a ficha de um funcionário no CRM → *📁 Ver os arquivos da pasta no SharePoint*.
   Se aparecer a lista, está ligado.

Enquanto não estiver ligado, nada quebra: o CRM só deixa de copiar e mostra a "colinha"
com o nome e a pasta para salvar à mão.

## Documentos dos funcionários no CRM (v51) — espelho, sem duplicar

A ação `sincronizar_colaboradores` lê as pastas `01.2.1.1_ATIVOS` e `01.2.1.2_DESLIGADOS`
(com subpastas, até 3 níveis) e grava na tabela `documentos_sharepoint` **um registro por
arquivo**, pela identificação única do arquivo no SharePoint. Os arquivos aparecem em
**Documentos** (filtro “Funcionário”, ou botão 📄 Documentos da ficha).

| Situação no SharePoint | O que acontece no CRM |
|------------------------|-----------------------|
| Arquivo novo | aparece na próxima sincronização |
| Mesmo arquivo lido de novo | não duplica (a identificação é única no banco) |
| Arquivo renomeado ou movido (inclusive de ATIVOS para DESLIGADOS) | o mesmo registro é atualizado |
| Arquivo apagado | fica “removido” (some da tela) — **só** se a pasta foi lida inteira sem erro |
| Pasta que falhou na leitura | nada dela é removido; o aviso aparece na tela |
| Arquivo que o próprio CRM enviou (mesmo nome, mesmo funcionário) | fica ligado ao documento do CRM e aparece **uma vez só**, na linha do documento (☁️ SharePoint) |
| Pasta com nome que não bate com nenhum funcionário | aparece com o aviso “pasta sem funcionário no CRM” |

A pasta é ligada ao funcionário pelo nome completo (sem acento, maiúsculo), o mesmo padrão
que o CRM usa para criar a pasta. A sincronização roda sozinha ao abrir a aba Documentos
(no máximo a cada 15 minutos) e no botão **🔄 Sincronizar agora**. Só o SharePoint grava o
espelho; o CRM nunca apaga nada no SharePoint.

**Publicar:** depois de rodar a migração v51, publique de novo a função `sharepoint`.
