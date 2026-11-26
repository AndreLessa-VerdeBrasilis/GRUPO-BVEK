// =====================================================================
// CRM Grupo BVEK — função "pedidos-email" (Supabase Edge Function) — v80
// Lê as caixas de e-mail cadastradas em Contratos → Notas e pedidos →
// Captura no e-mail (tabela pedidos_config) e transforma em "Pedido do
// cliente — a classificar" todo e-mail cujo ASSUNTO ou TEXTO tenha uma
// das palavras-chave (ordem de compra, pedido de compra, purchase order…)
// ou, no assunto, uma sigla com número (OC 1234, PC-4500123, PO#789…).
// Os anexos (PDF, planilha, Word, XML, imagem) vão para a pasta privada
// "pedidos". O mesmo e-mail nunca entra duas vezes (internetMessageId).
// E-mails de domínios internos (ignorar_dominios) são ignorados.
//
// Usa os MESMOS segredos dos outros e-mails do CRM:
//   MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET
// O aplicativo do Microsoft 365 precisa da permissão de aplicativo
// Mail.Read (Microsoft Graph) com consentimento do administrador.
//
// Pedido (POST com JSON):
//   { acao: "buscar" }                       → Administrador logado
//   { acao: "buscar", automatico: true }     + cabeçalho x-cron-token (agendamento)
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const G = "https://graph.microsoft.com/v1.0";
// deno-lint-ignore no-explicit-any
type Linha = Record<string, any>;

const semAcento = (s: string) => String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "");
const normal = (s: string) => semAcento(s).toLowerCase().replace(/\s+/g, " ");
const escRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const GENERICOS = new Set(["gmail.com", "hotmail.com", "outlook.com", "live.com", "yahoo.com", "yahoo.com.br", "icloud.com", "uol.com.br", "bol.com.br", "terra.com.br", "globo.com", "msn.com"]);
// siglas só contam no ASSUNTO e com número: "OC 1234", "PC-4500123", "PO#789", "AF nº 55"
const SIGLAS = /\b(OC|OS|PC|PO|OF|AF|AC|RC|RQ)\s*(?:n[º°o]?\.?|nr\.?|#|:|-)?\s*(\d[\d.\-\/]{2,})/i;
const NOME_SIGLA: Record<string, string> = {
  OC: "Ordem de compra", OS: "Ordem de serviço", PC: "Pedido de compra", PO: "Purchase order", OF: "Ordem de fornecimento",
  AF: "Autorização de fornecimento", AC: "Autorização de compra", RC: "Requisição de compra", RQ: "Requisição",
};
const TIPOS_ANEXO = /\.(pdf|xlsx?|xlsm|csv|docx?|xml|png|jpe?g|webp|heic|zip|msg|eml)$/i;

async function tokenM365(tenant: string, clientId: string, segredo: string): Promise<string> {
  const rt = await fetch(`https://login.microsoftonline.com/${encodeURIComponent(tenant)}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "client_credentials", client_id: clientId, client_secret: segredo, scope: "https://graph.microsoft.com/.default" }),
  });
  const tok = await rt.json().catch(() => ({}));
  if (!rt.ok || !tok.access_token) throw new Error("O Microsoft 365 recusou o aplicativo: " + (tok.error_description || tok.error || rt.status));
  return tok.access_token;
}
async function graph(tok: string, url: string): Promise<Linha> {
  const r = await fetch(url.startsWith("http") ? url : G + url, {
    headers: { Authorization: "Bearer " + tok, Prefer: 'outlook.body-content-type="text"' },
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) {
    const m = d?.error?.message || r.status;
    if (r.status === 403 || /Access is denied|Authorization_RequestDenied|ErrorAccessDenied/i.test(String(m)))
      throw new Error("O aplicativo do Microsoft 365 não tem a permissão Mail.Read (ver o LEIA-ME da função pedidos-email).");
    throw new Error("Microsoft 365: " + m);
  }
  return d;
}

// o que tem de pedido no e-mail? devolve o tipo e o número (quando dá para achar)
function analisar(assunto: string, texto: string, palavras: string[]): { tipo: string; numero: string | null } | null {
  const a = normal(assunto), t = normal(texto).slice(0, 20000);
  // as palavras mais longas primeiro ("pedido de compra" antes de "requisição")
  const ord = [...palavras].map((p) => [p, normal(p)] as const).filter(([, n]) => n.length >= 4).sort((x, y) => y[1].length - x[1].length);
  for (const [orig, n] of ord) {
    const re = new RegExp("(^|[^a-z0-9])" + escRe(n) + "([^a-z0-9]|$)");
    const noAssunto = re.test(a);
    if (!noAssunto && !re.test(t)) continue;
    const fonte = noAssunto ? a : t, i = fonte.search(re);
    const depois = fonte.slice(i + n.length + 1, i + n.length + 60);
    const m = depois.match(/^\W{0,3}(?:n[ºo°]?\.?|numero|nr\.?|no\.?|#)?\s*[:\-]?\s*([a-z0-9][a-z0-9\-\/.]*\d[a-z0-9\-\/]*)/i);
    const tipo = orig.charAt(0).toUpperCase() + orig.slice(1);
    return { tipo, numero: m ? m[1].toUpperCase().replace(/[.\-\/]+$/, "") : (assunto.match(/\b\d{4,}\b/) || [null])[0] };
  }
  const s = assunto.match(SIGLAS);
  if (s) return { tipo: NOME_SIGLA[s[1].toUpperCase()] || s[1].toUpperCase(), numero: s[2].replace(/[.\-\/]+$/, "") };
  return null;
}

async function buscar(adm: ReturnType<typeof createClient>, inicio: number) {
  const { data: cfg, error: ec } = await adm.from("pedidos_config").select("*").eq("id", 1).maybeSingle();
  if (ec || !cfg) throw new Error("Rode a migração v80 no Supabase (falta a tabela pedidos_config).");
  const caixas: string[] = (cfg.caixas || []).map((c: string) => String(c).trim().toLowerCase()).filter(Boolean);
  if (!caixas.length) throw new Error("Cadastre ao menos uma caixa de e-mail em Contratos → Notas e pedidos → Captura no e-mail.");
  const palavras: string[] = (cfg.palavras || []).filter(Boolean);
  const ignorar = new Set<string>([...(cfg.ignorar_dominios || []), ...caixas.map((c) => c.split("@")[1])].map((d: string) => String(d).toLowerCase().trim()).filter(Boolean));
  const tenant = Deno.env.get("MS_TENANT_ID"), clientId = Deno.env.get("MS_CLIENT_ID"), segredo = Deno.env.get("MS_CLIENT_SECRET");
  if (!tenant || !clientId || !segredo) throw new Error("Faltam os segredos do Microsoft 365 (MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET).");
  const tok = await tokenM365(tenant, clientId, segredo);

  // de onde começar: última busca − 2 h (folga), ou N dias na primeira vez
  const desde = cfg.ultima_busca
    ? new Date(new Date(cfg.ultima_busca).getTime() - 2 * 3600000)
    : new Date(Date.now() - Number(cfg.dias_primeira || 30) * 86400000);
  let ate = new Date().toISOString(), cortou = false, ultimoVisto = desde.toISOString();

  // clientes pelos e-mails dos contatos (e-mail exato e, se não for genérico, o domínio)
  const { data: contatos } = await adm.from("contatos").select("cliente_id,email").not("email", "is", null);
  const porEmail = new Map<string, string>(), porDominio = new Map<string, Set<string>>();
  (contatos || []).forEach((c: Linha) => {
    String(c.email || "").toLowerCase().split(/[;,\s]+/).filter((e) => e.includes("@")).forEach((e) => {
      if (!c.cliente_id) return;
      porEmail.set(e, c.cliente_id);
      const d = e.split("@")[1];
      if (d && !GENERICOS.has(d)) { const s = porDominio.get(d) || new Set(); s.add(c.cliente_id); porDominio.set(d, s); }
    });
  });
  const { data: projs } = await adm.from("projetos").select("id,cliente_id,status");
  const ativosDo = (cli: string) => (projs || []).filter((p: Linha) => p.cliente_id === cli && !["Concluído", "Cancelado"].includes(p.status));

  let lidos = 0, novos = 0;
  const erros: string[] = [], achados: string[] = [];
  for (const caixa of caixas) {
    let url: string | null = `/users/${encodeURIComponent(caixa)}/messages?$filter=${encodeURIComponent(`receivedDateTime ge ${desde.toISOString()}`)}` +
      `&$orderby=receivedDateTime asc&$top=50&$select=id,internetMessageId,subject,from,receivedDateTime,body,webLink,hasAttachments,isDraft`;
    try {
      while (url) {
        if (Date.now() - inicio > 45000) { cortou = true; break; }
        const pg = await graph(tok, url);
        const msgs: Linha[] = pg.value || [];
        const ids = msgs.map((m) => m.internetMessageId).filter(Boolean);
        const { data: ja } = ids.length ? await adm.from("pedidos_cliente").select("email_id").in("email_id", ids) : { data: [] };
        const jaTem = new Set((ja || []).map((x: Linha) => x.email_id));
        for (const m of msgs) {
          if (Date.now() - inicio > 45000) { cortou = true; break; }
          lidos++;
          if (m.receivedDateTime) ultimoVisto = m.receivedDateTime;
          if (m.isDraft || !m.internetMessageId || jaTem.has(m.internetMessageId)) continue;
          const de = String(m.from?.emailAddress?.address || "").toLowerCase(), dom = de.split("@")[1] || "";
          if (!de || ignorar.has(dom)) continue;
          const corpo = String(m.body?.content || "");
          const r = analisar(String(m.subject || ""), corpo, palavras);
          if (!r) continue;
          // cliente: e-mail exato do contato, ou o domínio de um cliente só
          let cliente_id: string | null = porEmail.get(de) || null;
          if (!cliente_id && porDominio.get(dom)?.size === 1) cliente_id = [...porDominio.get(dom)!][0];
          const ativos = cliente_id ? ativosDo(cliente_id) : [];
          const id = crypto.randomUUID();
          // anexos (sem as imagens da assinatura)
          const arquivos: Linha[] = [];
          if (m.hasAttachments) {
            try {
              const at = await graph(tok, `/users/${encodeURIComponent(caixa)}/messages/${m.id}/attachments?$select=id,name,contentType,size,isInline`);
              for (const a of (at.value || []) as Linha[]) {
                if (a.isInline || a["@odata.type"] !== "#microsoft.graph.fileAttachment") continue;
                if (!TIPOS_ANEXO.test(String(a.name || "")) || Number(a.size || 0) > 20 * 1024 * 1024) continue;
                const full = await graph(tok, `/users/${encodeURIComponent(caixa)}/messages/${m.id}/attachments/${a.id}`);
                const bin = Uint8Array.from(atob(full.contentBytes || ""), (c) => c.charCodeAt(0));
                const limpo = semAcento(String(a.name)).replace(/[^\w.\- ]+/g, "_").replace(/\s+/g, " ").trim() || "anexo";
                const caminho = `${id}/${limpo}`;
                const up = await adm.storage.from("pedidos").upload(caminho, bin, { contentType: a.contentType || "application/octet-stream", upsert: true });
                if (!up.error) arquivos.push({ caminho, nome: a.name, tamanho: a.size });
              }
            } catch (e) { erros.push(`anexo de "${m.subject}": ${(e as Error).message}`); }
          }
          const { error } = await adm.from("pedidos_cliente").insert({
            id, situacao: "a_classificar", origem: "email", tipo: r.tipo, numero: r.numero,
            data_pedido: String(m.receivedDateTime || "").slice(0, 10) || null,
            cliente_id, projeto_id: ativos.length === 1 ? ativos[0].id : null,
            email_id: m.internetMessageId, email_caixa: caixa, email_de: de, email_de_nome: m.from?.emailAddress?.name || null,
            email_assunto: m.subject || null, email_data: m.receivedDateTime || null,
            email_trecho: corpo.replace(/\s+/g, " ").trim().slice(0, 1500) || null, email_link: m.webLink || null,
            arquivos, criado_por: "Captura no e-mail",
          });
          if (error) { if (!/duplicate|unique/i.test(error.message)) erros.push(error.message); continue; }
          novos++; achados.push(`${r.tipo}${r.numero ? " " + r.numero : ""} — ${m.from?.emailAddress?.name || de}`);
        }
        if (cortou) break;
        url = pg["@odata.nextLink"] || null;
      }
    } catch (e) { erros.push(`${caixa}: ${(e as Error).message}`); }
    if (cortou) break;
  }
  if (cortou) ate = ultimoVisto;
  const resumo = `${novos} pedido(s) novo(s) · ${lidos} e-mail(s) lido(s)${cortou ? " · continua na próxima busca" : ""}${erros.length ? " · " + erros.length + " erro(s)" : ""}`;
  // só avança a data se não deu erro geral (senão a próxima busca tenta de novo)
  const upd: Linha = { ultimo_resultado: resumo + (erros.length ? " — " + erros[0] : ""), atualizado_em: new Date().toISOString() };
  if (!(erros.length && !lidos)) upd.ultima_busca = ate;
  await adm.from("pedidos_config").update(upd).eq("id", 1);
  return { novos, lidos, cortou, erros, achados, resumo };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ erro: "Use POST." }, 405);
  const inicio = Date.now();
  const adm = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    const p = await req.json().catch(() => ({}));
    if (p.acao !== "buscar") return json({ erro: "Ação desconhecida." }, 400);
    const tokenCron = req.headers.get("x-cron-token") || "";
    if (tokenCron) {
      const { data: cfg } = await adm.from("pedidos_config").select("token_cron").eq("id", 1).maybeSingle();
      if (!cfg || cfg.token_cron !== tokenCron) return json({ erro: "Sem permissão." }, 403);
    } else {
      const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: { user }, error } = await adm.auth.getUser(jwt);
      if (error || !user) return json({ erro: "Sessão inválida. Saia e entre de novo no CRM." }, 401);
      const { data: perfil } = await adm.from("perfis").select("perfil,ativo").eq("id", user.id).maybeSingle();
      if (!perfil || perfil.ativo === false || perfil.perfil !== "administrador") return json({ erro: "Só o Administrador busca os pedidos no e-mail." }, 403);
    }
    return json(await buscar(adm, inicio));
  } catch (e) {
    return json({ erro: String((e as Error).message || e) }, 500);
  }
});
