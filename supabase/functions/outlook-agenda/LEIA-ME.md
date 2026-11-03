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

Calendário usado: o da caixa `MS_REMETENTE` (a mesma do envio de e-mails).
Para usar outra caixa, crie o segredo `OUTLOOK_AGENDA` com o e-mail dela.

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
3. No CRM, abra **Cronograma**. Se aparecer "Outlook ligado", está funcionando.

Enquanto não estiver ligado, o cronograma e a folha automática funcionam normalmente;
só não aparece nada no Outlook.
