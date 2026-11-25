// =====================================================================
// CRM Grupo BVEK — função "portal-acessos" (Supabase Edge Function) — v72
// Clientes → Portal: acessos → "Enviar acessos": cria o login do portal
// do cliente para cada contato ligado a um contrato liberado e manda por
// e-mail o endereço, o login e uma senha provisória (gerada aqui e
// NUNCA guardada). No primeiro acesso a pessoa cria a própria senha.
//
// Usa os MESMOS segredos dos outros e-mails do CRM:
//   MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET, MS_REMETENTE
// Remetente: a caixa de quem está logado (como a proposta, v64), com a
// assinatura padrão do grupo (user_metadata.assinatura_email).
//
// TRAVA: nada é enviado enquanto portal_config.envio_liberado = false
// (liga e desliga em Clientes → Portal: acessos). A prévia funciona sempre.
//
// Pedido (POST com JSON) — só o Administrador:
//   { acao: "previa", email }          → devolve o e-mail que seria enviado (com senha de exemplo)
//   { acao: "enviar", emails: [..] }   → cria/atualiza o login e envia
// Quem já entrou e criou a senha NÃO recebe senha nova.
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
const ENDERECO = "https://grupo-bvek.vercel.app";
const G = "https://graph.microsoft.com/v1.0";
const escHtml = (t: unknown) => String(t ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
// deno-lint-ignore no-explicit-any
type Linha = Record<string, any>;
const primeiroNome = (n: string) => {
  const p = String(n || "").trim().split(/\s+/)[0] || "";
  return p ? p.charAt(0).toUpperCase() + p.slice(1).toLowerCase() : "";
};
function base64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
// senha provisória: 12 caracteres sem letras que confundem (0/O, 1/l/I)
function senhaProvisoria(): string {
  const L = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  const b = crypto.getRandomValues(new Uint8Array(12));
  let s = Array.from(b, (x) => L[x % L.length]).join("");
  if (!/\d/.test(s)) s = s.slice(0, 11) + "7";
  return s;
}

// ---- assinatura padrão do grupo (igual à da proposta) ----
const LOGO_URL = ENDERECO + "/img/assinatura/grupo-bvek-solucoes.png";
const FONTE = "font-family:Aptos,Calibri,Helvetica,sans-serif;font-size:12pt;color:rgb(0,0,0)";
function assinaturaHtml(a: { nome: string; cargo: string; fixo: string; celular: string }, email: string, comLogo: boolean): string {
  const A = "font-family:Arial,Helvetica,sans-serif";
  const tel = [a.fixo && `Fixo <b>${escHtml(a.fixo)}</b>`, a.celular && `Cel. <b>${escHtml(a.celular)}</b>`].filter(Boolean).join(" · ");
  return `<div style="${FONTE}"><br></div><div style="${FONTE}">Atenciosamente,</div><div style="${FONTE}"><br></div>
<table style="background-color:#fff;color:rgb(46,58,70);border-collapse:collapse;border-spacing:0"><tbody><tr>
${comLogo ? `<td style="text-align:center;padding:4px 16px 4px 0;vertical-align:middle;width:118px"><img src="cid:logo-bvek" alt="Grupo BVEK Soluções" width="118" style="width:118px;height:auto;border:0"></td>` : ""}
<td style="border-left:3px solid rgb(14,74,132);padding:2px 0 2px 16px;vertical-align:middle">
<div style="line-height:20px;${A};font-size:16px;color:rgb(14,74,132)"><b>${escHtml(a.nome)}</b></div>
${a.cargo ? `<div style="line-height:17px;${A};font-size:12px;color:rgb(74,86,99)">${escHtml(a.cargo)}</div>` : ""}
${tel ? `<div style="line-height:17px;padding-top:6px;${A};font-size:12px">${tel}</div>` : ""}
<div style="line-height:17px;${A};font-size:12px;color:rgb(74,86,99)">${escHtml(email)}</div>
<div style="line-height:17px;${A};font-size:12px;color:rgb(14,74,132)">www.bvek.com.br</div>
</td></tr></tbody></table>`;
}
async function baixarLogo(): Promise<Uint8Array | null> {
  try {
    const r = await fetch(LOGO_URL);
    if (!r.ok) return null;
    const b = new Uint8Array(await r.arrayBuffer());
    return b.length > 0 && b.length < 300 * 1024 ? b : null;
  } catch (_) { return null; }
}

const ASSUNTO_PADRAO = "Seu acesso ao Portal do Cliente — Grupo BVEK";
const MENSAGEM_PADRAO =
  "Olá, {nome}!\n\nO Grupo BVEK liberou para você o Portal do Cliente, onde você acompanha os seus contratos conosco: ordem de serviço, diário de obra, documentos de início, medições e notas fiscais.\n\nContratos liberados para você:\n{contratos}";

function corpoEmail(cfg: Linha, nome: string, email: string, senha: string, contratos: string[], novo: boolean): string {
  const msg = String(cfg.mensagem || "").trim() || MENSAGEM_PADRAO;
  const texto = msg.replace(/\{nome\}/g, primeiroNome(nome) || nome).replace(/\{contratos\}/g, contratos.map((c) => "• " + c).join("\n"));
  const acesso = `<table style="border-collapse:collapse;margin:14px 0;${FONTE}">
<tr><td style="padding:3px 14px 3px 0;color:#555">Endereço</td><td style="padding:3px 0"><a href="${ENDERECO}" style="color:rgb(14,74,132)"><b>${ENDERECO.replace("https://", "")}</b></a></td></tr>
<tr><td style="padding:3px 14px 3px 0;color:#555">Login</td><td style="padding:3px 0"><b>${escHtml(email)}</b></td></tr>
${novo ? `<tr><td style="padding:3px 14px 3px 0;color:#555">Senha provisória</td><td style="padding:3px 0;font-family:Consolas,monospace;font-size:13pt"><b>${escHtml(senha)}</b></td></tr>` : ""}
</table>
<div style="${FONTE};line-height:1.5">${novo ? "No primeiro acesso o portal pede para você criar a sua própria senha." : "Use a senha que você já criou. Se esqueceu, responda este e-mail."}</div>`;
  return `<div style="${FONTE};line-height:1.5">${escHtml(texto).replace(/\n/g, "<br>")}</div>${acesso}`;
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
async function enviarEmail(tok: string, de: string, para: string, assunto: string, html: string, logo: Uint8Array | null): Promise<string | null> {
  const inline = logo ? [{ "@odata.type": "#microsoft.graph.fileAttachment", name: "grupo-bvek.png", contentType: "image/png", contentBytes: base64(logo), isInline: true, contentId: "logo-bvek" }] : [];
  const r = await fetch(`${G}/users/${encodeURIComponent(de)}/sendMail`, {
    method: "POST",
    headers: { Authorization: "Bearer " + tok, "Content-Type": "application/json" },
    body: JSON.stringify({ message: { subject: assunto, body: { contentType: "HTML", content: html }, toRecipients: [{ emailAddress: { address: para } }], attachments: inline }, saveToSentItems: true }),
  });
  if (r.status === 202) return null;
  const t = await r.text();
  try { return String(JSON.parse(t).error.message).slice(0, 300); } catch (_) { return t.slice(0, 300) || String(r.status); }
}

// contatos (e contratos) de um e-mail nos contratos liberados no portal
// deno-lint-ignore no-explicit-any
async function dadosDoEmail(adm: any, email: string) {
  const { data: cts } = await adm.from("contatos").select("id,nome,email,cliente_id");
  const meus = ((cts || []) as Linha[]).filter((c) => String(c.email || "").trim().toLowerCase() === email);
  if (!meus.length) return null;
  const ids = meus.map((c) => c.id);
  const { data: pcs } = await adm.from("portal_contratos").select("projeto_id,contatos,liberado").eq("liberado", true).overlaps("contatos", ids);
  const pids = ((pcs || []) as Linha[]).map((x) => x.projeto_id);
  if (!pids.length) return null;
  const { data: ps } = await adm.from("projetos").select("id,codigo,nome,cliente_id").in("id", pids).order("codigo");
  const projetos = (ps || []) as Linha[];
  return {
    nome: String(meus[0].nome || email.split("@")[0]),
    clientes: [...new Set(projetos.map((p) => p.cliente_id).filter(Boolean))] as string[],
    contratos: projetos.map((p) => `${p.codigo} — ${p.nome}`),
  };
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
    if (!perfil || perfil.ativo === false || perfil.perfil !== "administrador") return json({ erro: "Só o Administrador envia os acessos do portal." }, 403);
    const quem = String(perfil.nome || perfil.email || user.email || "");

    const { data: cfgRow, error: ec } = await adm.from("portal_config").select("*").eq("id", 1).maybeSingle();
    if (ec) return json({ erro: /portal_config/.test(ec.message) ? "Falta rodar a migração v72 no Supabase." : ec.message }, 500);
    const cfg = (cfgRow || {}) as Linha;
    const assunto = String(cfg.assunto || "").trim() || ASSUNTO_PADRAO;
    const p = await req.json().catch(() => ({}));

    // assinatura de quem está logado
    const am = (user.user_metadata || {}).assinatura_email || {};
    const ass = { nome: String(am.nome || perfil.nome || "").trim(), cargo: String(am.cargo || "").trim(), fixo: String(am.fixo || "").trim(), celular: String(am.celular || "").trim() };

    // ---------------- prévia (não envia nada)
    if (p.acao === "previa") {
      const email = String(p.email || "").trim().toLowerCase();
      const d = email ? await dadosDoEmail(adm, email) : null;
      const html = corpoEmail(cfg, d?.nome || "Cliente", email || "contato@cliente.com.br", "Exemplo7Senha", d?.contratos || ["C000-0000 — Contrato de exemplo"], true) +
        (ass.nome ? assinaturaHtml(ass, String(user.email || ""), false) : "");
      return json({ ok: true, assunto, html, envio_liberado: !!cfg.envio_liberado });
    }

    if (p.acao !== "enviar") return json({ erro: "Ação desconhecida." }, 400);
    // ---------------- TRAVA
    if (!cfg.envio_liberado) return json({ erro: "O envio dos acessos está DESLIGADO. Ligue em Clientes → Portal: acessos quando quiser que os e-mails saiam." }, 403);

    const emails = [...new Set((Array.isArray(p.emails) ? p.emails : []).map((x: unknown) => String(x).trim().toLowerCase()).filter((e: string) => EMAIL_OK.test(e)))].slice(0, 100) as string[];
    if (!emails.length) return json({ erro: "Nenhum e-mail para enviar." }, 400);

    const tenant = Deno.env.get("MS_TENANT_ID"), clientId = Deno.env.get("MS_CLIENT_ID");
    const segredo = Deno.env.get("MS_CLIENT_SECRET"), padrao = Deno.env.get("MS_REMETENTE");
    if (!tenant || !clientId || !segredo || !padrao) return json({ erro: "Falta configurar o envio pelo Microsoft 365 (segredos MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET e MS_REMETENTE)." }, 500);
    const tokMs = await tokenM365(tenant, clientId, segredo);
    const logo = ass.nome ? await baixarLogo() : null;

    // caixas possíveis — sempre do próprio usuário (mesmo nome antes do @)
    const meuEmail = String(user.email || "").toLowerCase();
    const local = (e: string) => e.split("@")[0] || "";
    const dominio = (e: string) => e.split("@")[1] || "";
    const candidatas = [...new Set([meuEmail, String(perfil.email || "").toLowerCase(), local(meuEmail) + "@" + dominio(padrao.toLowerCase())]
      .filter((e) => e && EMAIL_OK.test(e) && !e.endsWith("@funcionario.bvek.com.br")))];
    let caixaBoa = "";

    const resultado: Linha[] = [];
    for (const email of emails) {
      const r: Linha = { email, ok: false, erro: "" };
      let perfilId: string | null = null;
      try {
        if (email.endsWith("@bvek.com.br") || email.endsWith("@funcionario.bvek.com.br")) throw new Error("e-mail do grupo — use o e-mail do cliente");
        const d = await dadosDoEmail(adm, email);
        if (!d) throw new Error("este e-mail não está em nenhum contrato liberado no portal");
        r.nome = d.nome;

        // login existente?
        const { data: pf } = await adm.from("perfis").select("id,perfil,cliente_id,clientes_extras,senha_definida_em,nome").ilike("email", email.replace(/[%_\\]/g, "\\$&")).maybeSingle();
        if (pf && !["pendente", "cliente"].includes(pf.perfil)) throw new Error(`este e-mail já é um login do escritório (${pf.perfil})`);
        if (pf && pf.perfil === "cliente" && pf.senha_definida_em) {
          // já entrou: só garante os clientes do login, sem senha nova
          const extras = [...new Set([...(pf.clientes_extras || []), ...d.clientes].filter((x) => x && x !== pf.cliente_id))];
          await adm.from("perfis").update({ ativo: true, cliente_id: pf.cliente_id || d.clientes[0], clientes_extras: extras }).eq("id", pf.id);
          r.ok = true; r.erro = ""; r.pulado = "já tinha acesso (não recebeu senha nova)";
          resultado.push(r);
          continue;
        }
        const senha = senhaProvisoria();
        if (pf) {
          const { error } = await adm.auth.admin.updateUserById(pf.id, { password: senha, email_confirm: true });
          if (error) throw new Error("não consegui trocar a senha: " + error.message);
          perfilId = pf.id;
        } else {
          const { data: nu, error } = await adm.auth.admin.createUser({ email, password: senha, email_confirm: true, user_metadata: { nome: d.nome } });
          if (error || !nu?.user) throw new Error("não consegui criar o login: " + (error?.message || "erro"));
          perfilId = nu.user.id;
        }
        const principal = pf?.perfil === "cliente" && pf.cliente_id ? pf.cliente_id : d.clientes[0];
        const extras = [...new Set([...((pf?.perfil === "cliente" && pf.clientes_extras) || []), ...d.clientes].filter((x) => x && x !== principal))];
        const { error: ep } = await adm.from("perfis").upsert({
          id: perfilId, email, nome: pf?.nome || d.nome, perfil: "cliente", ativo: true,
          cliente_id: principal, clientes_extras: extras, senha_definida_em: null,
        }, { onConflict: "id" });
        if (ep) throw new Error("login criado, mas não consegui gravar o perfil: " + ep.message);

        // e-mail
        const corpoPara = (cx: string) => corpoEmail(cfg, d.nome, email, senha, d.contratos, true) + (ass.nome ? assinaturaHtml(ass, cx, !!logo) : "");
        let erro: string | null = "sem caixa de e-mail";
        for (const cx of caixaBoa ? [caixaBoa] : candidatas) {
          erro = await enviarEmail(tokMs, cx, email, assunto, corpoPara(cx), logo);
          if (!erro) { caixaBoa = cx; break; }
        }
        if (erro) throw new Error("login criado, mas o e-mail não saiu: " + erro + " (reenvie depois)");
        r.ok = true; r.remetente = caixaBoa;
      } catch (e) {
        r.erro = String((e as Error)?.message || e).slice(0, 300);
      }
      await adm.from("portal_acessos_envios").insert({ email, nome: r.nome || null, perfil_id: perfilId, ok: r.ok, erro: r.erro || r.pulado || null, remetente: r.remetente || null, enviado_por: quem });
      resultado.push(r);
    }
    return json({ ok: true, enviados: resultado.filter((r) => r.ok && !r.pulado).length, resultado });
  } catch (e) {
    console.error(e);
    return json({ erro: String((e as Error)?.message || e) }, 500);
  }
});
