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

## Fase 2 (v36 e v37) — feita

- **Valores protegidos no banco (v36):** o Comercial não recebe mais os valores das propostas, dos itens nem dos contratos fixos — o banco tira esses campos antes de mandar. A composição de preço (custo e lucro) só chega ao Administrador. Os parâmetros de preço (BDI, lucro) não são mais lidos pelo Comercial.
- **Registro de alterações (v36):** quem mudou valor ou etapa de proposta, pagamentos, saídas, contratos fixos, premiações, salários (ficha do RH) e perfis de acesso. Só o Administrador vê (Usuários → 🕵️ Registro de alterações); ninguém altera nem apaga.
- **Bibliotecas dentro do site:** leitor de PDF, gerador de PDF e Excel agora vêm do próprio site (só o leitor de imagem/OCR continua vindo de fora).
- **Avisos com o app fechado (v37):** ver abaixo.

## App para Android e iPhone

**Feito (v34):** o CRM virou um *app instalável* (PWA) — ícone na tela inicial, abre em tela cheia, sem barra do navegador, e mostra **notificações do sistema** de tarefas e pagamentos (botão 🔔 Ativar avisos).
- Android (Chrome): botão 📲 *Instalar app* no topo, ou menu ⋮ → *Instalar app*.
- iPhone (Safari): Compartilhar → *Adicionar à Tela de Início* (notificações exigem iOS 16.4+ e abrir pelo ícone).

**Avisos com o app fechado (v37):** de segunda a sábado, às 8h40 e às 13h40, cada pessoa recebe no celular as tarefas do dia; o administrador, os pagamentos a autorizar; o funcionário, as declarações para assinar. Para ligar: publicar a função `supabase/functions/push` (Edge Functions → nome `push`, sem segredo novo) e rodar a migração v37. Cada pessoa toca uma vez em 🔔 Ativar avisos no aparelho.

**Fase 3 — publicar nas lojas (opcional):**
- *Google Play*: empacotar o mesmo site com Bubblewrap/TWA (conta de desenvolvedor Google: US$ 25, pagamento único).
- *App Store*: empacotar com Capacitor; exige conta Apple Developer (US$ 99/ano) e um Mac para enviar. A Apple costuma recusar apps que são "só um site", então vale a pena só depois do push e de recursos nativos.
