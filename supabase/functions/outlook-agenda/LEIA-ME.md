# Cronograma do CRM ↔ calendário do Outlook (v41)

A função `outlook-agenda` liga a aba **Cronograma** do CRM a um calendário do Outlook,
nos dois sentidos:

| Onde muda                         | O que acontece                                                                 |
|-----------------------------------|--------------------------------------------------------------------------------|
| Nova alocação no CRM              | vira um evento de dia inteiro no Outlook; os funcionários com e-mail no cadastro são convidados |
| Alocação alterada/cancelada no CRM | o evento é alterado/apagado no Outlook                                         |
| Evento novo no Outlook            | vira alocação no CRM **se** tiver funcionário convidado (e-mail do cadastro) ou o nome completo do funcionário no assunto. Código do projeto (`C###-NNNN`) no assunto liga ao projeto |
| Evento alterado no Outlook        | datas, convidados e local são trazidos para o CRM                              |
| Evento apagado no Outlook         | a alocação fica **cancelada** no CRM (nada é apagado)                          |

A sincronização roda ao abrir a aba Cronograma, ao trocar de mês e no botão
**🔄 Sincronizar com Outlook**. Cada alocação salva no CRM vai na hora para o Outlook.

**Agenda usada (v42): a de quem está usando o CRM.** Cada alocação vira evento na agenda
do Outlook do e-mail do login de quem lançou (o convite aos funcionários sai em nome dessa
pessoa). A caixa fica gravada na alocação; se outra pessoa alterar a alocação depois, o
evento continua na agenda de quem criou. A sincronização lê a agenda de quem clicou em
**🔄 Sincronizar** — só eventos em que essa pessoa é a organizadora viram alocação (convite
recebido não duplica).

O e-mail do login no CRM precisa ser o mesmo da caixa do Microsoft 365. Eventos antigos
(da v41, que ficavam na caixa `OUTLOOK_AGENDA`/`MS_REMETENTE`) passam para a agenda de
quem os alterar.

Se o administrador do Microsoft 365 tiver limitado o aplicativo a algumas caixas
(*Application Access Policy*), inclua as caixas de quem usa o Cronograma.

## Agenda do escritório (v45)

Reuniões e eventos do escritório ficam na caixa **agenda@bvek.com.br** do Microsoft 365
e aparecem para todos no CRM (linha **🏢 Escritório** do Cronograma e quadro
**Agenda do escritório** no Painel). Ficam na tabela `agenda_escritorio`, separados do
cronograma: **não entram na folha**.

| Onde muda | O que acontece |
|-----------|----------------|
| Reunião criada no Outlook com `agenda@bvek.com.br` convidada | aparece no CRM (só leitura: muda-se no Outlook de quem marcou) |
| Reunião alterada/cancelada no Outlook | o CRM traz a mudança / marca como cancelada |
| Evento criado no CRM (**+ Evento do escritório**) | vai para a agenda do escritório e os convidados recebem o convite |
| Evento alterado/cancelado no CRM | o Outlook é atualizado e os convidados recebem o aviso |

Reunião com `agenda@bvek.com.br` convidada **não vira alocação** do cronograma, mesmo com
funcionário convidado.

**Como marcar uma reunião do escritório pelo Outlook:** convide `agenda@bvek.com.br` (junto com
os colegas). Sem ela, um evento com funcionários convidados vira alocação “sem cliente” no
Cronograma. **v51:** se isso já aconteceu, basta acrescentar `agenda@bvek.com.br` como convidada
no Outlook e clicar em 🔄 Sincronizar: a alocação sai do Cronograma (e da folha) e o evento
passa para a linha 🏢 Escritório. O evento no Outlook não é apagado. (Não use “Cancelar
alocação” no CRM para isso: cancelar no CRM apaga o evento no Outlook.)

Para ver a agenda do escritório no próprio Outlook: *Calendário → Adicionar calendário →
Da organização / Do diretório* → `agenda@bvek.com.br` (a caixa precisa estar compartilhada
com a equipe no Microsoft 365).

Se um convite enviado à agenda não aparecer no calendário dela, o administrador do
Microsoft 365 pode ligar o processamento automático:
`Set-CalendarProcessing -Identity agenda@bvek.com.br -AutomateProcessing AutoUpdate`.
Para usar outra caixa, crie o segredo `OUTLOOK_ESCRITORIO` no Supabase.

Desde a v45 todos os perfis do escritório (Administrador, Comercial, Administrativo,
Contabilidade e Consulta) usam o Cronograma e a agenda do escritório.

## Como ligar (uma vez só)

1. **Azure / Microsoft Entra** (portal.azure.com → Registros de aplicativo → o mesmo
   aplicativo já usado para o e-mail da contabilidade):
   - *Permissões de API* → *Adicionar* → *Microsoft Graph* → **Permissões de aplicativo**
     → `Calendars.ReadWrite` → *Adicionar*.
   - Clique em **Conceder consentimento do administrador**.
2. **Supabase** → Edge Functions → *Deploy new function* com o nome `outlook-agenda` e o
   conteúdo de `index.ts` (ou `supabase functions deploy outlook-agenda`).
   Os segredos `MS_TENANT_ID`, `MS_CLIENT_ID`, `MS_CLIENT_SECRET` e `MS_REMETENTE` já existem.
   (Opcional) crie `OUTLOOK_AGENDA` para usar o calendário de outra caixa.
   **v45:** publique de novo a função depois de atualizar o `index.ts` (agenda do escritório).
3. No CRM, abra **Cronograma**. Se aparecer "Outlook ligado", está funcionando.

Enquanto não estiver ligado, o cronograma e a folha automática funcionam normalmente;
só não aparece nada no Outlook.
