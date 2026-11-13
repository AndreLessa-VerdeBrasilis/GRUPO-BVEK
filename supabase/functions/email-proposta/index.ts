// =====================================================================
// CRM Grupo BVEK — função "email-proposta" (Supabase Edge Function) — v59
// Funil → abrir a proposta → "Enviar por e-mail": manda o e-mail ao cliente
// com o PDF da proposta (o arquivo guardado na proposta, bucket "propostas")
// anexado, pelo Microsoft 365.
// Usa os MESMOS segredos dos outros e-mails do CRM:
//   MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET, MS_REMETENTE
// Remetente: a caixa do próprio usuário logado, quando ela é do mesmo
// domínio da MS_REMETENTE; se o Microsoft 365 não aceitar, sai pela
// MS_REMETENTE. Quem enviou vai sempre em cópia.
//
// Pedido (POST com JSON):
//   { card_id, para: [..], cc: [..], assunto, mensagem }
// Só o Administrador (as propostas e os valores são só dele desde a v46).
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const EMAIL_OK = /^[^\s@;,<>]+@[^\s@;,<>]+\.[^\s@;,<>]+$/;
const escHtml = (t: string) => t.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
function base64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
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
async function erroGraph(r: Response): Promise<string> {
  const t = await r.text();
  try { return JSON.parse(t).error.message; } catch (_) { return t.slice(0, 300) || String(r.status); }
}
const G = "https://graph.microsoft.com/v1.0";

// envia pela caixa "de"; anexo até 3 MB vai junto; maior, por sessão de upload (rascunho → anexo → enviar)
// deno-lint-ignore no-explicit-any
async function enviar(tok: string, de: string, msg: any, anexo: { nome: string; bytes: Uint8Array }): Promise<string | null> {
  const H = { Authorization: "Bearer " + tok, "Content-Type": "application/json" };
  const caixa = `${G}/users/${encodeURIComponent(de)}`;
  if (anexo.bytes.length <= 3 * 1024 * 1024) {
    const r = await fetch(`${caixa}/sendMail`, {
      method: "POST", headers: H,
      body: JSON.stringify({ message: { ...msg, attachments: [{ "@odata.type": "#microsoft.graph.fileAttachment", name: anexo.nome, contentType: "application/pdf", contentBytes: base64(anexo.bytes) }] }, saveToSentItems: true }),
    });
    return r.status === 202 ? null : await erroGraph(r);
  }
  const rd = await fetch(`${caixa}/messages`, { method: "POST", headers: H, body: JSON.stringify(msg) });
  if (!rd.ok) return await erroGraph(rd);
  const rascunho = await rd.json();
  const rs = await fetch(`${caixa}/messages/${rascunho.id}/attachments/createUploadSession`, {
    method: "POST", headers: H,
    body: JSON.stringify({ AttachmentItem: { attachmentType: "file", name: anexo.nome, size: anexo.bytes.length, contentType: "application/pdf" } }),
  });
  if (!rs.ok) return await erroGraph(rs);
  const { uploadUrl } = await rs.json();
  const PEDACO = 3 * 1024 * 1024;
  for (let i = 0; i < anexo.bytes.length; i += PEDACO) {
    const parte = anexo.bytes.subarray(i, Math.min(i + PEDACO, anexo.bytes.length));
    const ru = await fetch(uploadUrl, {
      method: "PUT",
      headers: { "Content-Type": "application/octet-stream", "Content-Length": String(parte.length), "Content-Range": `bytes ${i}-${i + parte.length - 1}/${anexo.bytes.length}` },
      body: parte,
    });
    if (!ru.ok && ru.status !== 201 && ru.status !== 200) return await erroGraph(ru);
  }
  const re = await fetch(`${caixa}/messages/${rascunho.id}/send`, { method: "POST", headers: { Authorization: "Bearer " + tok } });
  return re.status === 202 ? null : await erroGraph(re);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ erro: "Use POST." }, 405);
  const adm = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: { user }, error: eu } = await adm.auth.getUser(jwt);
    if (eu || !user) return json({ erro: "Sessão inválida. Saia e entre de novo no CRM." }, 401);
    const { data: perfil } = await adm.from("perfis").select("perfil,ativo,nome,email").eq("id", user.id).maybeSingle();
    if (!perfil || perfil.ativo === false || perfil.perfil !== "administrador") return json({ erro: "Só o Administrador envia propostas." }, 403);

    const tenant = Deno.env.get("MS_TENANT_ID"), clientId = Deno.env.get("MS_CLIENT_ID");
    const segredo = Deno.env.get("MS_CLIENT_SECRET"), padrao = Deno.env.get("MS_REMETENTE");
    if (!tenant || !clientId || !segredo || !padrao) return json({ erro: "Falta configurar o envio pelo Microsoft 365 (segredos MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET e MS_REMETENTE)." }, 500);

    const p = await req.json().catch(() => ({}));
    const para = (Array.isArray(p.para) ? p.para : []).map((x: unknown) => String(x).trim()).filter(Boolean).slice(0, 20);
    const cc = (Array.isArray(p.cc) ? p.cc : []).map((x: unknown) => String(x).trim()).filter(Boolean).slice(0, 20);
    if (!para.length) return json({ erro: "Informe quem vai receber." }, 400);
    const ruim = [...para, ...cc].find((e: string) => !EMAIL_OK.test(e));
    if (ruim) return json({ erro: `E-mail inválido: ${ruim}` }, 400);

    const { data: card } = await adm.from("cards").select("id,titulo,numero_proposta,arquivo_proposta,arquivo_proposta_nome").eq("id", String(p.card_id || "")).maybeSingle();
    if (!card) return json({ erro: "Proposta não encontrada." }, 404);
    if (!card.arquivo_proposta) return json({ erro: "A proposta ainda não tem PDF guardado. Gere a proposta antes." }, 400);
    const { data: arq, error: ea } = await adm.storage.from("propostas").download(card.arquivo_proposta);
    if (ea || !arq) return json({ erro: "Não encontrei o PDF da proposta no CRM." }, 404);
    const bytes = new Uint8Array(await arq.arrayBuffer());
    if (bytes.length > 30 * 1024 * 1024) return json({ erro: "O PDF passa de 30 MB: grande demais para e-mail." }, 413);
    const nomeAnexo = (String(card.numero_proposta || "").match(/^[\w.\-]+$/) ? card.numero_proposta + ".pdf" : (card.arquivo_proposta_nome || "proposta.pdf"));

    const assunto = String(p.assunto || "").trim().slice(0, 250) || `Proposta ${card.numero_proposta || ""} — ${card.titulo || ""}`;
    const texto = String(p.mensagem || "").slice(0, 20000);
    const corpo = `<div style="font-family:Calibri,Arial,sans-serif;font-size:15px;color:#222;line-height:1.5">${escHtml(texto).replace(/\n/g, "<br>")}</div>`;
    const meuEmail = String(user.email || "").toLowerCase();
    const ccFinal = [...new Set([...cc, ...(EMAIL_OK.test(meuEmail) && !meuEmail.endsWith("@funcionario.bvek.com.br") ? [meuEmail] : [])])]
      .filter((e) => !para.map((x: string) => x.toLowerCase()).includes(e.toLowerCase()));
    const msg = {
      subject: assunto,
      body: { contentType: "HTML", content: corpo },
      toRecipients: para.map((e: string) => ({ emailAddress: { address: e } })),
      ccRecipients: ccFinal.map((e: string) => ({ emailAddress: { address: e } })),
    };

    const tok = await tokenM365(tenant, clientId, segredo);
    const dominio = (e: string) => e.split("@")[1] || "";
    let remetente = padrao, erro: string | null = null;
    if (meuEmail && dominio(meuEmail) === dominio(padrao.toLowerCase()) && meuEmail !== padrao.toLowerCase()) {
      erro = await enviar(tok, meuEmail, msg, { nome: nomeAnexo, bytes });
      if (erro) { console.warn("caixa do usuário recusou:", erro); remetente = padrao; erro = await enviar(tok, padrao, msg, { nome: nomeAnexo, bytes }); }
      else remetente = meuEmail;
    } else erro = await enviar(tok, padrao, msg, { nome: nomeAnexo, bytes });
    if (erro) return json({ erro: "O Microsoft 365 não enviou: " + erro }, 502);
    return json({ ok: true, remetente, para, cc: ccFinal });
  } catch (e) {
    console.error(e);
    return json({ erro: String((e as Error)?.message || e) }, 500);
  }
});
