# Pedidos do cliente capturados no e-mail (v80)

A função `pedidos-email` lê as caixas cadastradas em **Contratos → Notas e pedidos →
Captura no e-mail** e cria um **Pedido do cliente — a classificar** para cada e-mail que
tenha uma das palavras-chave no **assunto ou no texto**. Também reconhece no assunto as
siglas seguidas de número (OC 1234, PC-4500123, PO#789, OF, AF, AC, RC).

- Os anexos (PDF, planilha, Word, XML, imagem) vão para a pasta privada `pedidos`.
- O mesmo e-mail nunca entra duas vezes.
- E-mails dos domínios internos (`bvek.com.br`, `verdebrasilis.com.br` e o das caixas lidas) são
  ignorados. Assim a nossa própria OS (`C###-NNNN-OS-SSSS`) não vira pedido.
- O CRM tenta achar o cliente pelo e-mail de quem enviou (contatos cadastrados) e, se o
  cliente tem um contrato só em andamento, já sugere o contrato.
- Um administrador abre o pedido, confere o cliente, o contrato, o número e o valor, e salva
  como **Ativo**. Se o e-mail não for um pedido, clica em **Não é pedido**.

A busca roda sozinha **de hora em hora, de segunda a sexta, das 7h às 20h** (pg_cron, criado
pela migração v80). Também dá para rodar na hora com o botão **Buscar no e-mail agora**.

## Como ligar (uma vez só)

1. **Azure / Microsoft Entra** (portal.azure.com → Registros de aplicativo → o mesmo
   aplicativo já usado nos e-mails do CRM):
   - *Permissões de API* → *Adicionar uma permissão* → *Microsoft Graph* →
     **Permissões de aplicativo** → `Mail.Read` → *Adicionar*.
   - Clique em **Conceder consentimento do administrador**.
   - Se houver uma *Application Access Policy* limitando o aplicativo a algumas caixas,
     inclua a caixa que será lida (ex.: a do André).
2. **Supabase** → Edge Functions → *Deploy new function* com o nome `pedidos-email` e o
   conteúdo de `index.ts` (ou `supabase functions deploy pedidos-email`).
   Os segredos `MS_TENANT_ID`, `MS_CLIENT_ID` e `MS_CLIENT_SECRET` já existem.
3. **Supabase → SQL Editor**: rode `supabase/migracao_crm_v80_notas_pedidos_pagamentos_contrato.sql`.
4. No CRM: **Contratos → Notas e pedidos → Captura no e-mail**. Coloque a(s) caixa(s)
   (uma por linha), confira as palavras, clique em **Salvar configuração** e depois em
   **Buscar no e-mail agora**. A primeira busca olha os últimos 30 dias (dá para mudar).

## Regra no Outlook: encaminhar os pedidos para a equipe administradora

O CRM já captura os pedidos sozinho. A regra abaixo serve para que a equipe **também veja o
e-mail na caixa dela**, sem depender do André encaminhar. Os clientes não precisam mudar nada.

**Outlook na web** (outlook.office.com), entrando com a caixa do André:

1. Engrenagem (Configurações) → **Email** → **Regras** → **+ Adicionar nova regra**.
2. Nome: `Pedidos do cliente → equipe adm`.
3. **Adicionar uma condição** → *Assunto ou corpo inclui* → digite cada palavra abaixo e
   aperte Enter depois de cada uma (o Outlook não diferencia maiúsculas):

   Português:
   `ordem de compra` · `pedido de compra` · `ordem de serviço` · `ordem de servico` ·
   `requisição` · `requisicao` · `documento de compra` · `autorização de aquisição` ·
   `autorizacao de aquisicao` · `pedido de fornecimento` · `ordem de fornecimento` ·
   `autorização de fornecimento` · `autorizacao de fornecimento` · `pedido de aquisição` ·
   `pedido de aquisicao` · `ordem de aquisição` · `ordem de aquisicao` ·
   `autorização de compra` · `autorizacao de compra`

   Inglês:
   `purchase order` · `purchase request` · `purchase requisition` · `requisition` ·
   `service order` · `work order` · `purchasing document` · `purchase document` ·
   `procurement order` · `acquisition order` · `acquisition request` · `supply order` ·
   `supply request` · `supply authorization` · `purchase authorization` ·
   `procurement authorization`

   > Escreva as palavras com e sem acento: muitos sistemas de compras mandam sem acento.
   > **Não** coloque as siglas soltas (OC, OS, PC, PO, OF, AF, AC) na regra: o Outlook procura
   > o pedaço de texto em qualquer lugar, então "PO" pegaria "POR", "PONTO" etc. As siglas com
   > número quem pega é o CRM.

4. **Adicionar uma exceção** → *O endereço do remetente inclui* → `bvek.com.br` e
   `verdebrasilis.com.br` (para não encaminhar e-mails internos, como a nossa própria OS).
5. **Adicionar uma ação** → **Redirecionar para** → os e-mails da equipe administradora.
   (*Redirecionar* é melhor que *Encaminhar*: o e-mail chega como se o cliente tivesse mandado,
   e quem responder fala direto com o cliente.)
6. Deixe **desmarcado** "Parar de processar mais regras", para as outras regras continuarem
   funcionando.
7. **Salvar**. Para testar, peça a um colega que mande para o André um e-mail com assunto
   "Teste ordem de compra 123" de um endereço de fora (Gmail, por exemplo).

Se o Microsoft 365 bloquear o encaminhamento (alguns ambientes bloqueiam encaminhamento
automático), o administrador do 365 libera em *Defender → Políticas de spam de saída →
Encaminhamento automático*. Para caixas da mesma empresa normalmente já funciona.

**Alternativa mais simples de manter:** criar no Microsoft 365 um **grupo** (ex.:
`adm-pedidos@bvek.com.br`) com a equipe administradora e, na regra, redirecionar para o
grupo. Quem entra ou sai da equipe é ajustado no grupo, sem mexer na regra.
