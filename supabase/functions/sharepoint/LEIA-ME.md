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
