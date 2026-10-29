// =====================================================================
// CRM Grupo BVEK — função "email-comunicado" (Supabase Edge Function)
// RH → Comunicação interna: manda o comunicado por e-mail, um e-mail
// para cada funcionário (cada um recebe o seu, com o próprio nome), pelo
// Microsoft 365. Usa os MESMOS segredos da função "email-contabilidade":
//   MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET, MS_REMETENTE
//
// Pedido (POST com JSON):
//   { comunicado_id: "...", funcionario_ids: ["..."] }   → envia de verdade
//   { comunicado_id: "...", teste_para: "eu@bvek.com.br" } → só um teste
//   { acao: "copia_ponto", assinatura_id: "..." }          → (v31) cópia do espelho de
//      ponto assinado para o e-mail do próprio funcionário
//
// Comunicados: só Administrador e Administrativo do CRM.
// Cópia do ponto: o próprio funcionário (login por CPF), só da assinatura dele.
// O resultado (quem recebeu, quem deu erro) fica gravado no comunicado.
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
const LIMITE_ANEXO = 3 * 1024 * 1024;
const escHtml = (t: string) => t.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
function base64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
const primeiroNome = (n: string) => {
  const p = String(n || "").trim().split(/\s+/)[0] || "";
  return p ? p.charAt(0).toUpperCase() + p.slice(1).toLowerCase() : "";
};
function corpoHtml(titulo: string, mensagem: string, nome: string) {
  return `<div style="font-family:Calibri,Arial,sans-serif;font-size:15px;color:#222;max-width:640px">
  <div style="border-bottom:3px solid #329948;padding-bottom:8px;margin-bottom:16px">
    <div style="font-size:12px;letter-spacing:.12em;color:#0C4982;font-weight:700">GRUPO BVEK · COMUNICADO INTERNO</div>
    <div style="font-size:20px;font-weight:700;color:#0C4982;margin-top:4px">${escHtml(titulo)}</div>
  </div>
  ${nome ? `<p>Olá, ${escHtml(nome)}.</p>` : ""}
  <div style="line-height:1.55">${escHtml(mensagem).replace(/\n/g, "<br>")}</div>
  <p style="margin-top:24px;font-size:12px;color:#777">Comunicado enviado pelo RH do Grupo BVEK. Em caso de dúvida, fale com o RH.<br>
  Veja também no CRM: <a href="https://grupo-bvek.vercel.app">grupo-bvek.vercel.app</a></p></div>`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const adm = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    // 1. quem está chamando?
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: { user }, error: erroUsuario } = await adm.auth.getUser(jwt);
    if (erroUsuario || !user) return json({ erro: "Sessão inválida. Saia e entre de novo no CRM." }, 401);
    const { data: perfil } = await adm.from("perfis").select("perfil,ativo,nome,email").eq("id", user.id).maybeSingle();
    const p = await req.json().catch(() => ({}));
    const tenant = Deno.env.get("MS_TENANT_ID"), clientId = Deno.env.get("MS_CLIENT_ID");
    const segredo = Deno.env.get("MS_CLIENT_SECRET"), remetente = Deno.env.get("MS_REMETENTE");
    if (!tenant || !clientId || !segredo || !remetente) {
      return json({ erro: "Falta configurar o envio pelo Microsoft 365 (segredos MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET e MS_REMETENTE)." }, 500);
    }
    if (p.acao === "copia_ponto") {
      if (!perfil || !perfil.ativo || perfil.perfil !== "funcionario") return json({ erro: "Só o próprio funcionário pede a cópia." }, 403);
      return await copiaPonto(adm, user, String(p.assinatura_id || ""), { tenant, clientId, segredo, remetente });
    }
    if (!perfil || !perfil.ativo || !["administrador", "administrativo"].includes(perfil.perfil)) {
      return json({ erro: "Seu perfil não pode enviar comunicados." }, 403);
    }

    // 2. o comunicado e os destinatários
    const { data: com } = await adm.from("comunicados").select("*").eq("id", String(p.comunicado_id || "")).maybeSingle();
    if (!com) return json({ erro: "Comunicado não encontrado. Salve antes de enviar." }, 404);

    // deno-lint-ignore no-explicit-any
    let destinos: any[] = [];
    const teste = String(p.teste_para || "").trim();
    if (teste) {
      if (!EMAIL_OK.test(teste)) return json({ erro: `E-mail inválido: ${teste}` }, 400);
      destinos = [{ nome: perfil.nome || "", email: teste }];
    } else {
      const ids = (Array.isArray(p.funcionario_ids) ? p.funcionario_ids : []).map(String).slice(0, 500);
      if (!ids.length) return json({ erro: "Escolha pelo menos um funcionário." }, 400);
      const { data: fs, error } = await adm.from("funcionarios").select("id,nome,email,ativo").in("id", ids);
      if (error) throw new Error(error.message);
      destinos = (fs || []).filter((f) => f.ativo !== false).map((f) => ({ id: f.id, nome: f.nome, email: String(f.email || "").trim() }));
    }

    // 3. anexo (opcional) do bucket "rh"
    // deno-lint-ignore no-explicit-any
    const anexos: any[] = [];
    if (com.anexo) {
      if (!String(com.anexo).startsWith("comunicados/") || String(com.anexo).includes("..")) throw new Error("Anexo fora da pasta de comunicados.");
      const { data, error } = await adm.storage.from("rh").download(com.anexo);
      if (error || !data) throw new Error("Não foi possível ler o anexo do comunicado.");
      const bytes = new Uint8Array(await data.arrayBuffer());
      if (bytes.length > LIMITE_ANEXO) throw new Error("O anexo passa de 3 MB. Use um arquivo menor.");
      anexos.push({ "@odata.type": "#microsoft.graph.fileAttachment", name: com.anexo_nome || "anexo", contentType: data.type || "application/octet-stream", contentBytes: base64(bytes) });
    }

    // 4. token do Microsoft 365
    const tok = { access_token: await tokenM365(tenant, clientId, segredo) };

    // 5. um e-mail para cada pessoa
    const assunto = (teste ? "[TESTE] " : "") + "Comunicado interno — " + com.titulo;
    // deno-lint-ignore no-explicit-any
    const resultado: any[] = [];
    for (const d of destinos) {
      if (!EMAIL_OK.test(d.email)) { resultado.push({ nome: d.nome, email: d.email || null, ok: false, erro: "sem e-mail válido na ficha" }); continue; }
      try {
        const rs = await fetch(`https://graph.microsoft.com/v1.0/users/${encodeURIComponent(remetente)}/sendMail`, {
          method: "POST",
          headers: { Authorization: "Bearer " + tok.access_token, "Content-Type": "application/json" },
          body: JSON.stringify({
            message: {
              subject: assunto,
              body: { contentType: "HTML", content: corpoHtml(com.titulo, com.mensagem, primeiroNome(d.nome)) },
              toRecipients: [{ emailAddress: { address: d.email } }],
              attachments: anexos,
            },
            saveToSentItems: true,
          }),
        });
        if (rs.status !== 202) {
          const t = await rs.text();
          let msg = t.slice(0, 200);
          try { msg = JSON.parse(t).error.message; } catch (_) { /* texto puro */ }
          resultado.push({ nome: d.nome, email: d.email, ok: false, erro: msg });
        } else resultado.push({ nome: d.nome, email: d.email, ok: true });
      } catch (e) {
        resultado.push({ nome: d.nome, email: d.email, ok: false, erro: String((e as Error)?.message || e).slice(0, 200) });
      }
    }
    const ok = resultado.filter((r) => r.ok).length;
    if (teste) return json({ ok: ok > 0, teste: true, resultado });

    const situacao = ok === resultado.length ? "enviado" : ok ? "parcial" : "erro";
    await adm.from("comunicados").update({
      situacao, email_total: resultado.length, email_ok: ok, email_resultado: resultado,
      email_enviado_em: ok ? new Date().toISOString() : com.email_enviado_em,
      email_enviado_por: perfil.nome || perfil.email || user.email, atualizado_em: new Date().toISOString(),
    }).eq("id", com.id);
    return json({ ok: ok > 0, enviados: ok, total: resultado.length, resultado, remetente });
  } catch (e) {
    return json({ erro: String((e as Error)?.message || e) }, 500);
  }
});

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

// v31: cópia do espelho de ponto assinado para o e-mail do funcionário
// deno-lint-ignore no-explicit-any
async function copiaPonto(adm: any, user: any, assinaturaId: string, ms: { tenant: string; clientId: string; segredo: string; remetente: string }) {
  const m = String(user.email || "").toLowerCase().match(/^(\d{11})@funcionario\.bvek\.com\.br$/);
  if (!m) return json({ erro: "Login sem CPF." }, 403);
  const { data: a } = await adm.from("ponto_assinaturas").select("*").eq("id", assinaturaId).maybeSingle();
  if (!a) return json({ erro: "Assinatura não encontrada." }, 404);
  const { data: f } = await adm.from("funcionarios").select("id,nome,cpf,email,cargo").eq("id", a.funcionario_id).maybeSingle();
  if (!f || String(f.cpf || "").replace(/\D/g, "") !== m[1]) return json({ erro: "Esta assinatura não é sua." }, 403);
  const email = String(f.email || "").trim();
  if (!EMAIL_OK.test(email)) return json({ ok: false, sem_email: true });

  const fmt = (iso: string) => iso ? iso.slice(8, 10) + "/" + iso.slice(5, 7) + "/" + iso.slice(0, 4) : "";
  const quando = new Date(a.assinado_em).toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo" });
  const mes = new Date(a.competencia + "T12:00:00").toLocaleDateString("pt-BR", { month: "long", year: "numeric" });
  const d = a.dados || {}, cols: string[] = d.colunas || [];
  const td = (v: unknown, b = false) => `<td style="border:1px solid #ccc;padding:4px 6px;white-space:nowrap${b ? ";font-weight:700;background:#eef3ee" : ""}">${escHtml(String(v ?? ""))}</td>`;
  // deno-lint-ignore no-explicit-any
  const linhas = (d.dias || []).map((x: any) => `<tr>${td(fmt(x.data).slice(0, 5))}${(x.valores || []).map((v: unknown) => td(v)).join("")}</tr>`).join("");
  const tot = Array.isArray(d.totais) ? `<tr>${td("Total", true)}${d.totais.map((v: unknown) => td(v, true)).join("")}</tr>` : "";
  const tabela = `<table style="border-collapse:collapse;font-size:12px;font-family:Arial,sans-serif"><thead><tr>${["Dia", ...cols].map((c) => `<th style="border:1px solid #ccc;padding:4px 6px;background:#eef3ee;text-align:left">${escHtml(c)}</th>`).join("")}</tr></thead><tbody>${linhas}${tot}</tbody></table>`;
  const html = `<div style="font-family:Calibri,Arial,sans-serif;font-size:14px;color:#222;max-width:720px">
    <div style="border-bottom:3px solid #329948;padding-bottom:8px;margin-bottom:14px"><div style="font-size:12px;letter-spacing:.12em;color:#0C4982;font-weight:700">GRUPO BVEK · COMPROVANTE DE ASSINATURA DO PONTO</div>
    <div style="font-size:18px;font-weight:700;color:#0C4982;margin-top:4px">Espelho de ponto — ${escHtml(mes)}</div></div>
    <p>${escHtml(f.nome)} · CPF ${escHtml(f.cpf || "")}${f.cargo ? " · " + escHtml(f.cargo) : ""}<br>Período: ${fmt(a.periodo_inicio)} a ${fmt(a.periodo_fim)}</p>
    ${tabela}
    <p style="margin-top:14px"><strong>${a.concorda ? "Concordo com as marcações e totais deste período." : "NÃO CONCORDO com o ponto deste período."}</strong>${a.observacao ? "<br>Observação: " + escHtml(a.observacao) : ""}</p>
    ${a.assinatura ? `<img src="cid:assinatura" alt="assinatura" style="height:80px;border-bottom:1px solid #222">` : ""}
    <p style="font-size:12px;color:#555">Assinado eletronicamente por ${escHtml(a.nome_digitado || "")} em ${escHtml(quando)} (horário de Brasília), com login pessoal (CPF e senha) no CRM Grupo BVEK.<br>
    IP: ${escHtml(a.ip || "—")}<br>Código de conferência (SHA-256): ${escHtml(a.hash || "")}</p>
    <p style="font-size:12px;color:#777">Guarde este e-mail: é a sua via do ponto assinado. Se não foi você que assinou, avise o RH imediatamente.</p></div>`;
  // deno-lint-ignore no-explicit-any
  const anexos: any[] = [];
  const b64 = String(a.assinatura || "").replace(/^data:image\/png;base64,/, "");
  if (b64) anexos.push({ "@odata.type": "#microsoft.graph.fileAttachment", name: "assinatura.png", contentType: "image/png", contentBytes: b64, isInline: true, contentId: "assinatura" });

  const token = await tokenM365(ms.tenant, ms.clientId, ms.segredo);
  const rs = await fetch(`https://graph.microsoft.com/v1.0/users/${encodeURIComponent(ms.remetente)}/sendMail`, {
    method: "POST",
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: JSON.stringify({ message: { subject: `Ponto de ${mes} assinado — ${f.nome}`, body: { contentType: "HTML", content: html },
      toRecipients: [{ emailAddress: { address: email } }], attachments: anexos }, saveToSentItems: true }),
  });
  if (rs.status !== 202) {
    const t = await rs.text();
    let msg = t.slice(0, 200);
    try { msg = JSON.parse(t).error.message; } catch (_) { /* texto puro */ }
    return json({ erro: "O Microsoft 365 não enviou a cópia: " + msg }, 500);
  }
  await adm.from("ponto_assinaturas").update({ copia_enviada_para: email, copia_enviada_em: new Date().toISOString() }).eq("id", a.id);
  return json({ ok: true, email });
}
