// =====================================================================
// CRM Grupo BVEK — função "email-contabilidade" (Supabase Edge Function)
// Envia o fechamento mensal do RH para a contabilidade pelo Microsoft 365
// (Microsoft Graph), a partir de uma caixa de e-mail do grupo. A senha do
// app fica só nos segredos do Supabase, nunca no navegador nem no GitHub.
//
// Segredos (Supabase → Edge Functions → Secrets):
//   MS_TENANT_ID      ID do diretório (locatário) do Microsoft 365
//   MS_CLIENT_ID      ID do aplicativo registrado no Entra ID
//   MS_CLIENT_SECRET  segredo (valor) desse aplicativo
//   MS_REMETENTE      caixa que envia, ex.: rh@verdebrasilis.com.br
//                     (pode ser caixa compartilhada)
//
// O app precisa da permissão de APLICATIVO "Mail.Send" do Microsoft Graph,
// com consentimento do administrador.
//
// Pedido (POST com JSON):
//   { competencia: "2026-10-01", para: ["a@x.com"], cc: [], assunto, corpo,
//     anexos: [{ caminho: "envios/2026-10/arquivo.xlsx", nome: "arquivo.xlsx" }] }
//   Os anexos já precisam estar no bucket "rh" (o CRM sobe antes de chamar).
//
// Só Administrador e Administrativo do CRM podem chamar.
// Cada envio (ou erro) fica registrado em envios_contabilidade.
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
const LIMITE_ANEXOS = 3 * 1024 * 1024; // o Graph aceita até ~3 MB de anexos neste modo

function base64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
const escHtml = (t: string) => t.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const adm = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  // deno-lint-ignore no-explicit-any
  let registro: any = null;
  try {
    // 1. quem está chamando?
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: { user }, error: erroUsuario } = await adm.auth.getUser(jwt);
    if (erroUsuario || !user) return json({ erro: "Sessão inválida. Saia e entre de novo no CRM." }, 401);
    const { data: perfil } = await adm.from("perfis").select("perfil,ativo,nome,email").eq("id", user.id).maybeSingle();
    if (!perfil || !perfil.ativo || !["administrador", "administrativo"].includes(perfil.perfil)) {
      return json({ erro: "Seu perfil não pode enviar e-mails do RH." }, 403);
    }

    const tenant = Deno.env.get("MS_TENANT_ID"), clientId = Deno.env.get("MS_CLIENT_ID");
    const segredo = Deno.env.get("MS_CLIENT_SECRET"), remetente = Deno.env.get("MS_REMETENTE");
    if (!tenant || !clientId || !segredo || !remetente) {
      return json({ erro: "Falta configurar o envio pelo Microsoft 365: segredos MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET e MS_REMETENTE no Supabase (Edge Functions → Secrets)." }, 500);
    }

    // 2. confere o pedido
    const p = await req.json().catch(() => ({}));
    const lista = (v: unknown) => (Array.isArray(v) ? v : String(v || "").split(/[;,]/)).map((x) => String(x).trim()).filter(Boolean);
    const para = lista(p.para), cc = lista(p.cc);
    if (!para.length) return json({ erro: "Informe pelo menos um destinatário." }, 400);
    const ruim = [...para, ...cc].find((e) => !EMAIL_OK.test(e));
    if (ruim) return json({ erro: `E-mail inválido: ${ruim}` }, 400);
    if (!/^\d{4}-\d{2}-01$/.test(String(p.competencia || ""))) return json({ erro: "Competência inválida." }, 400);
    const assunto = String(p.assunto || "").slice(0, 250) || "Fechamento do RH";
    const corpo = String(p.corpo || "").slice(0, 20000);
    // deno-lint-ignore no-explicit-any
    const anexosPedido = (Array.isArray(p.anexos) ? p.anexos : []).slice(0, 15) as any[];

    registro = {
      competencia: p.competencia, enviado_por: perfil.nome || perfil.email || user.email, remetente,
      para: para.join("; "), cc: cc.join("; ") || null, assunto, corpo,
      anexos: anexosPedido.map((a) => ({ caminho: a.caminho, nome: a.nome })),
    };

    // 3. baixa os anexos do bucket "rh"
    // deno-lint-ignore no-explicit-any
    const anexos: any[] = [];
    let total = 0;
    for (const a of anexosPedido) {
      const caminho = String(a.caminho || "");
      if (!caminho.startsWith("envios/") || caminho.includes("..")) throw new Error(`Anexo fora da pasta de envios: ${caminho}`);
      const { data, error } = await adm.storage.from("rh").download(caminho);
      if (error || !data) throw new Error(`Não foi possível ler o anexo ${a.nome || caminho}.`);
      const bytes = new Uint8Array(await data.arrayBuffer());
      total += bytes.length;
      anexos.push({
        "@odata.type": "#microsoft.graph.fileAttachment",
        name: String(a.nome || caminho.split("/").pop()),
        contentType: data.type || "application/octet-stream",
        contentBytes: base64(bytes),
      });
    }
    if (total > LIMITE_ANEXOS) {
      throw new Error(`Os anexos somam ${(total / 1048576).toFixed(1)} MB; o limite deste envio é 3 MB. Tire algum anexo ou envie em dois e-mails.`);
    }

    // 4. token do Microsoft 365 (credenciais do aplicativo)
    const rt = await fetch(`https://login.microsoftonline.com/${encodeURIComponent(tenant)}/oauth2/v2.0/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "client_credentials", client_id: clientId, client_secret: segredo, scope: "https://graph.microsoft.com/.default" }),
    });
    const tok = await rt.json().catch(() => ({}));
    if (!rt.ok || !tok.access_token) {
      throw new Error("O Microsoft 365 recusou o aplicativo: " + (tok.error_description || tok.error || rt.status));
    }

    // 5. envia
    const html = corpo.includes("<") ? corpo : escHtml(corpo).replace(/\n/g, "<br>");
    const rs = await fetch(`https://graph.microsoft.com/v1.0/users/${encodeURIComponent(remetente)}/sendMail`, {
      method: "POST",
      headers: { Authorization: "Bearer " + tok.access_token, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: {
          subject: assunto,
          body: { contentType: "HTML", content: html },
          toRecipients: para.map((address) => ({ emailAddress: { address } })),
          ccRecipients: cc.map((address) => ({ emailAddress: { address } })),
          attachments: anexos,
        },
        saveToSentItems: true,
      }),
    });
    if (rs.status !== 202) {
      const t = await rs.text();
      let msg = t.slice(0, 300);
      try { msg = JSON.parse(t).error.message; } catch (_) { /* texto puro */ }
      if (rs.status === 403) msg += " (confira a permissão Mail.Send de aplicativo com consentimento do administrador)";
      if (rs.status === 404) msg += ` (a caixa ${remetente} não foi encontrada no Microsoft 365)`;
      throw new Error("O Microsoft 365 não enviou o e-mail: " + msg);
    }

    const { data: salvo } = await adm.from("envios_contabilidade").insert({ ...registro, situacao: "enviado" }).select().single();
    return json({ ok: true, envio: salvo, remetente });
  } catch (e) {
    const msg = String((e as Error)?.message || e);
    if (registro) await adm.from("envios_contabilidade").insert({ ...registro, situacao: "erro", erro: msg.slice(0, 1000) });
    return json({ erro: msg }, 500);
  }
});
