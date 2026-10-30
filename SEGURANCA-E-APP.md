# Projeto de proteção do CRM e app no celular (v34)

## O que já foi feito no código (v34)

| Proteção | O que evita |
|---|---|
| Cabeçalhos de segurança na Vercel (`vercel.json`): HTTPS obrigatório (HSTS), proibição de abrir o CRM dentro de outro site, bloqueio de scripts e conexões a sites desconhecidos (CSP) | Golpes de "site falso por cima" (clickjacking), roubo de dados por script injetado, envio de dados para servidores de hackers |
| Biblioteca do banco (Supabase) agora fica **dentro do site** e com versão travada (`vendor/`), em vez de vir de um CDN com versão "solta" | Ataque de cadeia de suprimentos (alguém adulterar a biblioteca no CDN) e quebra por atualização surpresa |
| Valores e lucro: o Comercial não vê valores nem abre/gera o PDF da proposta; custo e lucro (composição, Ganhos × Custos, contratos fixos) só administrador — **o PDF é bloqueado também no banco** | Vazamento de margem |
| Declaração de premiação: assinatura só pelo próprio funcionário, registro travado (não pode ser alterado nem apagado depois de assinado) | Fraude / contestação trabalhista |
| Integração SharePoint: só pastas `01_ADMINISTRATIVO` e `03_CLIENTES`, só perfis internos, nomes validados | Uso da integração para ler/gravar fora do lugar |

## O que o André precisa fazer (contas — 30 minutos)

1. **Verificação em duas etapas (2FA)** em: GitHub, Vercel, Supabase e Microsoft 365 (principalmente contas de administrador). É a proteção mais importante: a maioria das invasões vem de senha vazada.
2. **Supabase → Authentication → Settings**: ligar *Leaked password protection*, senha mínima de 10 caracteres; em *Rate limits*, manter os limites de login.
3. **Supabase → Database → Backups**: confirmar backup diário (no plano Pro, ligar *Point in Time Recovery*). Testar uma restauração por ano.
4. **Supabase → Advisors → Security Advisor**: rodar e mandar o resultado para revisão (aponta tabela sem proteção RLS).
5. **Repositório público**: o código é público. Nunca colocar senha, chave `service_role` ou dado bancário em arquivo. Avaliar deixar o repositório **privado** (a Vercel continua funcionando).
6. Revisar a cada 3 meses a lista de **Usuários** do CRM e desativar quem saiu.

## Próximas etapas sugeridas (fase 2)

- **Valores no banco**: hoje o Comercial não vê valores na tela, mas tecnicamente o valor total da proposta ainda chega ao navegador dele. A fase 2 move valor e composição para uma tabela protegida só para administrador (mudança grande no funil — fazer com calma).
- Trazer as outras bibliotecas (leitor de PDF, Excel, OCR) também para dentro do site.
- Registro de auditoria (quem alterou o quê) nas tabelas financeiras.

## App para Android e iPhone

**Feito (v34):** o CRM virou um *app instalável* (PWA) — ícone na tela inicial, abre em tela cheia, sem barra do navegador, e mostra **notificações do sistema** de tarefas e pagamentos (botão 🔔 Ativar avisos).
- Android (Chrome): botão 📲 *Instalar app* no topo, ou menu ⋮ → *Instalar app*.
- iPhone (Safari): Compartilhar → *Adicionar à Tela de Início* (notificações exigem iOS 16.4+ e abrir pelo ícone).

**Fase 2 — avisos com o app fechado (Web Push):** chave VAPID nos segredos do Supabase + tabela de inscrições + função que dispara no horário (tarefas do dia, pagamentos a autorizar, documentos vencendo, ponto para assinar). O `sw.js` já está pronto para receber.

**Fase 3 — publicar nas lojas (opcional):**
- *Google Play*: empacotar o mesmo site com Bubblewrap/TWA (conta de desenvolvedor Google: US$ 25, pagamento único).
- *App Store*: empacotar com Capacitor; exige conta Apple Developer (US$ 99/ano) e um Mac para enviar. A Apple costuma recusar apps que são "só um site", então vale a pena só depois do push e de recursos nativos.
