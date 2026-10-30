// =====================================================================
// CRM Grupo BVEK — função "sharepoint" (Supabase Edge Function) · v34
// Liga o CRM às pastas do SharePoint (site Grupo BVEK), pelo Microsoft Graph,
// com os MESMOS segredos do e-mail: MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET.
// Opcionais: SP_HOST (padrão andrelessaverdebrasiliscom.sharepoint.com)
//            SP_SITE (padrão /sites/GRUPOBVEK9)
//
// O aplicativo do Azure precisa da permissão de APLICATIVO "Sites.ReadWrite.All"
// (ou "Sites.Selected" liberada para o site Grupo BVEK) com consentimento do administrador.
//
// Pedidos (POST com JSON):
//   { acao: "status" }                                  → a integração está ligada?
//   { acao: "enviar", bucket, caminho, pasta, nome }    → copia um arquivo guardado no CRM
//                                                         para a pasta do SharePoint (substitui se já existir)
//   { acao: "listar", pasta }                           → lista os arquivos de uma pasta
//
// Só perfis internos (administrador, administrativo, comercial, contabilidade).
// Só pastas de 01_ADMINISTRATIVO/ e 03_CLIENTES/ (nada fora disso).
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const BUCKETS = new Set(["documentos", "rh", "propostas", "financeiro"]);
const PREFIXOS = ["01_ADMINISTRATIVO/", "03_CLIENTES/"];
// quem pode enviar para cada pasta raiz
const ENVIAR: Record<string, string[]> = {
  "01_ADMINISTRATIVO/": ["administrador", "administrativo"],
  "03_CLIENTES/": ["administrador", "administrativo", "comercial"],
};
const LER: Record<string, string[]> = {
  "01_ADMINISTRATIVO/": ["administrador", "administrativo", "contabilidade"],
  "03_CLIENTES/": ["administrador", "administrativo", "comercial", "consulta"],
};

function pastaSegura(p: string): string | null {
  const t = String(p || "").replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
  if (!t || t.includes("..") || /[:*?"<>|#%]/.test(t)) return null;
  return PREFIXOS.some((x) => (t + "/").startsWith(x)) ? t : null;
}
const raizDe = (p: string) => PREFIXOS.find((x) => (p + "/").startsWith(x))!;
const nomeSeguro = (n: string) => /^[A-Za-z0-9_\-.]{3,120}$/.test(n) && !n.includes("..");
const caminhoGraph = (p: string) => p.split("/").map(encodeURIComponent).join("/");

let cacheToken: { v: string; ate: number } | null = null;
async function tokenM365(): Promise<string> {
  if (cacheToken && cacheToken.ate > Date.now()) return cacheToken.v;
  const tenant = Deno.env.get("MS_TENANT_ID"), clientId = Deno.env.get("MS_CLIENT_ID"), segredo = Deno.env.get("MS_CLIENT_SECRET");
  if (!tenant || !clientId || !segredo) throw new Error("Falta configurar os segredos do Microsoft 365 (MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET).");
  const r = await fetch(`https://login.microsoftonline.com/${encodeURIComponent(tenant)}/oauth2/v2.0/token`, {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "client_credentials", client_id: clientId, client_secret: segredo, scope: "https://graph.microsoft.com/.default" }),
  });
  const b = await r.json();
  if (!r.ok || !b.access_token) throw new Error("Microsoft 365 recusou o acesso: " + (b.error_description || b.error || r.status));
  cacheToken = { v: b.access_token, ate: Date.now() + 50 * 60 * 1000 };
  return b.access_token;
}
let cacheSite: string | null = null;
async function siteId(tok: string): Promise<string> {
  if (cacheSite) return cacheSite;
  const host = Deno.env.get("SP_HOST") || "andrelessaverdebrasiliscom.sharepoint.com";
  const site = Deno.env.get("SP_SITE") || "/sites/GRUPOBVEK9";
  const r = await fetch(`https://graph.microsoft.com/v1.0/sites/${host}:${site}?$select=id`, { headers: { Authorization: "Bearer " + tok } });
  const b = await r.json();
  if (!r.ok) throw new Error(r.status === 403 || r.status === 401
    ? "O aplicativo do Microsoft 365 ainda não tem permissão no SharePoint (Sites.ReadWrite.All). Peça ao administrador do Microsoft 365 para liberar."
    : "Site do SharePoint não encontrado: " + (b.error?.message || r.status));
  cacheSite = b.id;
  return b.id;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ erro: "Use POST." }, 405);
  const adm = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: { user }, error: eu } = await adm.auth.getUser(jwt);
    if (eu || !user) return json({ erro: "Sessão inválida. Saia e entre de novo no CRM." }, 401);
    const { data: perfil } = await adm.from("perfis").select("perfil,ativo").eq("id", user.id).maybeSingle();
    if (!perfil || perfil.ativo === false || ["pendente", "funcionario"].includes(perfil.perfil)) return json({ erro: "Sem permissão." }, 403);

    const p = await req.json().catch(() => ({}));
    const acao = String(p.acao || "");
    if (acao === "status") {
      try { const t = await tokenM365(); await siteId(t); return json({ ok: true }); }
      catch (e) { return json({ ok: false, erro: String((e as Error).message || e) }); }
    }

    const pasta = pastaSegura(p.pasta);
    if (!pasta) return json({ erro: "Pasta não permitida." }, 400);
    const raiz = raizDe(pasta);

    if (acao === "listar") {
      if (!LER[raiz].includes(perfil.perfil)) return json({ erro: "Sem permissão para esta pasta." }, 403);
      const tok = await tokenM365(), sid = await siteId(tok);
      const r = await fetch(`https://graph.microsoft.com/v1.0/sites/${sid}/drive/root:/${caminhoGraph(pasta)}:/children?$top=200&$select=name,size,webUrl,lastModifiedDateTime,folder,file`,
        { headers: { Authorization: "Bearer " + tok } });
      if (r.status === 404) return json({ ok: true, existe: false, itens: [] });
      const b = await r.json();
      if (!r.ok) return json({ erro: b.error?.message || "Erro ao listar a pasta." }, 502);
      const itens = (b.value || []).map((x: any) => ({ nome: x.name, tamanho: x.size, url: x.webUrl, alterado: x.lastModifiedDateTime, pasta: !!x.folder }));
      const rp = await fetch(`https://graph.microsoft.com/v1.0/sites/${sid}/drive/root:/${caminhoGraph(pasta)}?$select=webUrl`, { headers: { Authorization: "Bearer " + tok } });
      const bp = rp.ok ? await rp.json() : {};
      return json({ ok: true, existe: true, url: bp.webUrl || null, itens });
    }

    if (acao === "enviar") {
      if (!ENVIAR[raiz].includes(perfil.perfil)) return json({ erro: "Sem permissão para enviar a esta pasta." }, 403);
      const bucket = String(p.bucket || ""), caminho = String(p.caminho || ""), nome = String(p.nome || "");
      if (!BUCKETS.has(bucket) || !caminho || caminho.includes("..")) return json({ erro: "Arquivo inválido." }, 400);
      if (!nomeSeguro(nome)) return json({ erro: "Nome de arquivo fora do padrão." }, 400);
      const { data: arq, error: ed } = await adm.storage.from(bucket).download(caminho);
      if (ed || !arq) return json({ erro: "Arquivo não encontrado no CRM." }, 404);
      if (arq.size > 60 * 1024 * 1024) return json({ erro: "Arquivo grande demais (máx. 60 MB)." }, 413);
      const tok = await tokenM365(), sid = await siteId(tok);
      const r = await fetch(`https://graph.microsoft.com/v1.0/sites/${sid}/drive/root:/${caminhoGraph(pasta + "/" + nome)}:/content`, {
        method: "PUT", headers: { Authorization: "Bearer " + tok, "Content-Type": arq.type || "application/octet-stream" }, body: await arq.arrayBuffer(),
      });
      const b = await r.json().catch(() => ({}));
      if (!r.ok) return json({ erro: b.error?.message || "O SharePoint recusou o arquivo." }, 502);
      return json({ ok: true, url: b.webUrl, caminho: pasta + "/" + nome });
    }
    return json({ erro: "Ação desconhecida." }, 400);
  } catch (e) {
    console.error(e);
    return json({ erro: String((e as Error).message || e) }, 500);
  }
});
