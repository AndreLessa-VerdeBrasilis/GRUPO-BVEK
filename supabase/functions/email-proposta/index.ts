// =====================================================================
// CRM Grupo BVEK — função "email-proposta" (Supabase Edge Function) — v59 / v64
// Funil → abrir a proposta → "Enviar por e-mail": manda o e-mail ao cliente
// com o PDF da proposta (o arquivo guardado na proposta, bucket "propostas")
// anexado, pelo Microsoft 365.
// Usa os MESMOS segredos dos outros e-mails do CRM:
//   MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET, MS_REMETENTE
// Remetente (v64): SEMPRE a caixa de quem está logado no CRM. Nunca cai
// mais na MS_REMETENTE (a caixa da Sulamita, que é do RH/contabilidade).
// Ordem de tentativa: a caixa informada na tela ("de", que precisa ter o
// mesmo nome antes do @ que o login), o e-mail do login e o mesmo nome
// no domínio da MS_REMETENTE (ex.: login andre.lessa@verdebrasilis.com.br
// → caixa andre.lessa@bvek.com.br). Se nenhuma aceitar, NÃO envia e avisa.
// Assinatura (v64): a assinatura padrão do grupo (logo Grupo BVEK
// Soluções, nome, cargo, telefones, e-mail e empresas do grupo), a mesma
// do carimbo do Outlook, montada aqui com os dados enviados pela tela.
//
// Pedido (POST com JSON):
//   { card_id, para: [..], cc: [..], assunto, mensagem, de?,
//     assinatura?: { nome, cargo, fixo, celular } }
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

// ---- assinatura padrão do grupo (igual ao carimbo do Outlook) ----
const LOGO_URL = "https://grupo-bvek.vercel.app/img/assinatura/grupo-bvek-solucoes.png";
const FONTE = "font-family:Aptos,Calibri,Helvetica,sans-serif;font-size:12pt;color:rgb(0,0,0)";
function assinaturaHtml(a: { nome: string; cargo: string; fixo: string; celular: string }, email: string, comLogo: boolean): string {
  const A = "font-family:Arial,Helvetica,sans-serif";
  const tel = [a.fixo && `Fixo <b>${escHtml(a.fixo)}</b>`, a.celular && `Cel. <b>${escHtml(a.celular)}</b>`].filter(Boolean).join(" · ");
  return `<div style="${FONTE}"><br></div><div style="${FONTE}">Atenciosamente,</div><div style="${FONTE}"><br></div>
<table style="background-color:#fff;color:rgb(46,58,70);border-collapse:collapse;border-spacing:0"><tbody><tr>
${comLogo ? `<td style="text-align:center;padding:4px 16px 4px 0;vertical-align:middle;width:118px"><a href="https://linktr.ee/Grupo.BVEK" style="text-decoration:none"><img src="cid:logo-bvek" alt="Grupo BVEK Soluções" width="118" style="width:118px;height:auto;border:0"></a></td>` : ""}
<td style="border-left:3px solid rgb(14,74,132);padding:2px 0 2px 16px;vertical-align:middle">
<div style="line-height:20px;${A};font-size:16px;color:rgb(14,74,132)"><b>${escHtml(a.nome)}</b></div>
${a.cargo ? `<div style="line-height:17px;${A};font-size:12px;color:rgb(74,86,99)">${escHtml(a.cargo)}</div>` : ""}
${tel ? `<div style="line-height:17px;padding-top:6px;${A};font-size:12px">${tel}</div>` : ""}
<div style="line-height:17px;${A};font-size:12px;color:rgb(74,86,99)"><a href="mailto:${escHtml(email)}" style="color:rgb(74,86,99);text-decoration:none">${escHtml(email)}</a></div>
<div style="line-height:17px;${A};font-size:12px;color:rgb(14,74,132)"><a href="https://linktr.ee/Grupo.BVEK" style="color:rgb(14,74,132);text-decoration:none">www.bvek.com.br</a></div>
</td></tr><tr><td colspan="2" style="padding-top:10px"><div style="line-height:16px;padding-top:7px;border-top:1px solid rgb(221,227,233);${A};font-size:11px">Empresas do grupo: <a href="https://www.engekat.com.br/" style="color:rgb(31,94,154);text-decoration:none"><b>Engekat Construções</b></a> · <a href="https://www.verdebrasilis.com.br/" style="color:rgb(11,90,18);text-decoration:none"><b>Verde Brasilis</b></a> · <a href="https://www.brasilimp.com.br/" style="color:rgb(31,78,121);text-decoration:none"><b>BrasiLimp</b></a> · <a href="https://www.katseguros.com.br/" style="color:rgb(30,90,150);text-decoration:none"><b>KAT Seguros</b></a></div></td></tr></tbody></table>`;
}
async function baixarLogo(): Promise<Uint8Array | null> {
  try {
    const r = await fetch(LOGO_URL);
    if (!r.ok) return null;
    const b = new Uint8Array(await r.arrayBuffer());
    return b.length > 0 && b.length < 300 * 1024 ? b : null;
  } catch (_) { return null; }
}

// envia pela caixa "de"; anexo até 3 MB vai junto; maior, por sessão de upload (rascunho → anexo → enviar)
// deno-lint-ignore no-explicit-any
async function enviar(tok: string, de: string, msg: any, anexo: { nome: string; bytes: Uint8Array }, logo: Uint8Array | null): Promise<string | null> {
  const H = { Authorization: "Bearer " + tok, "Content-Type": "application/json" };
  const caixa = `${G}/users/${encodeURIComponent(de)}`;
  const inline = logo ? [{ "@odata.type": "#microsoft.graph.fileAttachment", name: "grupo-bvek.png", contentType: "image/png", contentBytes: base64(logo), isInline: true, contentId: "logo-bvek" }] : [];
  if (anexo.bytes.length <= 3 * 1024 * 1024) {
    const r = await fetch(`${caixa}/sendMail`, {
      method: "POST", headers: H,
      body: JSON.stringify({ message: { ...msg, attachments: [...inline, { "@odata.type": "#microsoft.graph.fileAttachment", name: anexo.nome, contentType: "application/pdf", contentBytes: base64(anexo.bytes) }] }, saveToSentItems: true }),
    });
    return r.status === 202 ? null : await erroGraph(r);
  }
  const rd = await fetch(`${caixa}/messages`, { method: "POST", headers: H, body: JSON.stringify({ ...msg, attachments: inline }) });
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
    const meuEmail = String(user.email || "").toLowerCase();

    // caixas possíveis — todas do próprio usuário (mesmo nome antes do @)
    const local = (e: string) => e.split("@")[0] || "";
    const dominio = (e: string) => e.split("@")[1] || "";
    const pedida = String(p.de || "").trim().toLowerCase();
    if (pedida && (!EMAIL_OK.test(pedida) || (pedida !== meuEmail && pedida !== String(perfil.email || "").toLowerCase() && local(pedida) !== local(meuEmail))))
      return json({ erro: `A caixa ${pedida} não é a sua. O CRM só envia da caixa de quem está logado (${meuEmail}).` }, 403);
    const candidatas = [...new Set([pedida, meuEmail, String(perfil.email || "").toLowerCase(), local(meuEmail) + "@" + dominio(padrao.toLowerCase())]
      .filter((e) => e && EMAIL_OK.test(e) && !e.endsWith("@funcionario.bvek.com.br")))];
    if (!candidatas.length) return json({ erro: "Não sei qual é a sua caixa de e-mail. Informe no campo \"Enviar da caixa\"." }, 400);

    const a = p.assinatura && typeof p.assinatura === "object" ? p.assinatura : null;
    const ass = a ? {
      nome: String(a.nome || perfil.nome || "").trim().slice(0, 80),
      cargo: String(a.cargo || "").trim().slice(0, 80),
      fixo: String(a.fixo || "").trim().slice(0, 30),
      celular: String(a.celular || "").trim().slice(0, 30),
    } : null;
    const logo = ass ? await baixarLogo() : null;
    const corpoPara = (caixa: string) =>
      `<div style="${FONTE};line-height:1.5">${escHtml(texto).replace(/\n/g, "<br>")}</div>` + (ass && ass.nome ? assinaturaHtml(ass, caixa, !!logo) : "");
    const montar = (caixa: string) => {
      // a cópia para si mesmo só quando o login é outro endereço (a mensagem já fica nos Itens Enviados da caixa)
      const ccFinal = [...new Set(cc.map((e: string) => e.toLowerCase()))]
        .filter((e) => !para.map((x: string) => x.toLowerCase()).includes(e) && e !== caixa);
      return {
        ccFinal,
        msg: {
          subject: assunto,
          body: { contentType: "HTML", content: corpoPara(caixa) },
          toRecipients: para.map((e: string) => ({ emailAddress: { address: e } })),
          ccRecipients: ccFinal.map((e: string) => ({ emailAddress: { address: e } })),
        },
      };
    };

    const tok = await tokenM365(tenant, clientId, segredo);
    let remetente = "", erro: string | null = null, ccUsado: string[] = [];
    const tentativas: string[] = [];
    for (const caixa of candidatas) {
      const m = montar(caixa);
      erro = await enviar(tok, caixa, m.msg, { nome: nomeAnexo, bytes }, logo);
      if (!erro) { remetente = caixa; ccUsado = m.ccFinal; break; }
      console.warn(`caixa ${caixa} recusou:`, erro);
      tentativas.push(`${caixa}: ${erro}`);
    }
    if (!remetente) return json({ erro: "Não consegui enviar pela sua caixa de e-mail (o CRM não usa mais a caixa padrão para propostas).\n" + tentativas.join("\n") }, 502);
    return json({ ok: true, remetente, para, cc: ccUsado });
  } catch (e) {
    console.error(e);
    return json({ erro: String((e as Error)?.message || e) }, 500);
  }
});
