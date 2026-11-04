// =====================================================================
// CRM Grupo BVEK — função "convocacao" (Supabase Edge Function) — v47
// Cronograma → avisa cada funcionário da equipe pelo WhatsApp (API oficial
// da Meta, a mesma configurada em Financeiro → ⚙️ WhatsApp) e pelo e-mail
// (Microsoft 365, mesmos segredos da "email-comunicado":
//   MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET, MS_REMETENTE).
//
// Pedido (POST com JSON):
//   { cronograma_id: "..." }                  → avisa quem ainda não sabe:
//        • quem entrou na equipe → CONVOCAÇÃO
//        • quem já foi avisado e algo mudou (data, horário, local…) → ALTERAÇÃO
//        • quem saiu da equipe, ou alocação cancelada → CANCELAMENTO
//   { cronograma_id: "...", reenviar: true }  → manda de novo a todos da equipe
//
// Quem pode: Administrador, Comercial, Administrativo e Contabilidade.
// Cada envio fica gravado em "cronograma_avisos".
// Alocações que já terminaram não geram aviso.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const PERFIS = ["administrador", "comercial", "administrativo", "contabilidade"];
const EMAIL_OK = /^[^\s@;,<>]+@[^\s@;,<>]+\.[^\s@;,<>]+$/;
const SEMANA = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"];
// deno-lint-ignore no-explicit-any
type Linha = Record<string, any>;
type Tipo = "convocacao" | "alteracao" | "cancelamento";

const escH = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const primeiroNome = (n: string) => {
  const p = String(n || "").trim().split(/\s+/)[0] || "";
  return p ? p.charAt(0).toUpperCase() + p.slice(1).toLowerCase() : "";
};
const nomeCurto = (n: string) => {
  const p = String(n || "").trim().split(/\s+/).map((x) => x.charAt(0).toUpperCase() + x.slice(1).toLowerCase());
  return p.length > 1 ? p[0] + " " + p[p.length - 1] : p[0] || "";
};
const dataBR = (iso: string, ano = true) => iso.slice(8, 10) + "/" + iso.slice(5, 7) + (ano ? "/" + iso.slice(0, 4) : "");
const diaSemana = (iso: string) => SEMANA[new Date(iso + "T12:00:00Z").getUTCDay()];
const hora = (t: string | null) => (t ? String(t).slice(0, 5) : "");
const hojeBrasilia = () => new Date(Date.now() - 3 * 3600 * 1000).toISOString().slice(0, 10);
// número no formato da Meta: 55 + DDD + número
function foneMeta(t: unknown): string {
  const d = String(t || "").replace(/\D/g, "");
  if (d.length === 10 || d.length === 11) return "55" + d;
  if ((d.length === 12 || d.length === 13) && d.startsWith("55")) return d;
  return "";
}

// ------------------------------------------------------------------ textos
function detalhes(l: Linha, proj: Linha | null, cli: Linha | null, equipe: string[]) {
  const ini = l.data_inicio as string, fim = l.data_fim as string;
  let data = ini === fim ? `${diaSemana(ini)}, ${dataBR(ini)}` : `${diaSemana(ini)}, ${dataBR(ini, false)} a ${diaSemana(fim)}, ${dataBR(fim)}`;
  if (ini !== fim) {
    const extras = [l.sabado ? "sábado" : "", l.domingo ? "domingo" : ""].filter(Boolean);
    data += extras.length ? ` (segunda a sexta + ${extras.join(" e ")})` : " (segunda a sexta)";
  }
  const horario = l.hora_inicio && l.hora_fim ? `${hora(l.hora_inicio)} às ${hora(l.hora_fim)}`
    : l.hora_inicio ? `a partir das ${hora(l.hora_inicio)}` : "a combinar com o escritório";
  const local = String(l.local || proj?.local || "").trim() || "a combinar com o escritório";
  const projeto = proj ? `${proj.codigo} — ${proj.nome}` : "";
  const cliente = cli ? `${cli.codigo ? cli.codigo + " — " : ""}${cli.nome}` : "";
  const servico = String(l.titulo || "").trim();
  return { data, horario, local, projeto, cliente, servico, obs: String(l.observacoes || "").trim(), equipe: equipe.join(", ") };
}
type Det = ReturnType<typeof detalhes>;

const CABECALHO: Record<Tipo, string> = {
  convocacao: "Convocação",
  alteracao: "Convocação ALTERADA",
  cancelamento: "Convocação CANCELADA",
};
const ABERTURA: Record<Tipo, string> = {
  convocacao: "Você está escalado(a) para o serviço abaixo.",
  alteracao: "Houve mudança no serviço abaixo. Vale o que está aqui.",
  cancelamento: "O serviço abaixo foi cancelado para você. Não é preciso comparecer.",
};

function textoWhats(tipo: Tipo, nome: string, d: Det): string {
  const icone = tipo === "cancelamento" ? "❌" : tipo === "alteracao" ? "🔄" : "📢";
  const l = [`${icone} *${CABECALHO[tipo]} — Grupo BVEK*`, `Olá, ${nome}! ${ABERTURA[tipo]}`, "",
    `📅 *Data:* ${d.data}`, `🕗 *Horário:* ${d.horario}`, `📍 *Local:* ${d.local}`];
  if (d.projeto) l.push(`🏗️ *Projeto:* ${d.projeto}`);
  if (d.cliente) l.push(`🏢 *Cliente:* ${d.cliente}`);
  if (d.servico) l.push(`🛠️ *Serviço:* ${d.servico}`);
  if (tipo !== "cancelamento" && d.equipe) l.push(`👥 *Equipe:* ${d.equipe}`);
  if (tipo !== "cancelamento" && d.obs) l.push(`📝 *Obs.:* ${d.obs}`);
  l.push("", "Dúvidas? Fale com o escritório.");
  return l.join("\n");
}

function emailHtml(tipo: Tipo, nome: string, d: Det): string {
  const cor = tipo === "cancelamento" ? "#C0392B" : "#0C4982";
  const linha = (rot: string, v: string) => v ? `<tr><td style="padding:4px 12px 4px 0;color:#555;white-space:nowrap;vertical-align:top">${rot}</td><td style="padding:4px 0;font-weight:600">${escH(v).replace(/\n/g, "<br>")}</td></tr>` : "";
  return `<div style="font-family:Calibri,Arial,sans-serif;font-size:15px;color:#222;max-width:640px">
  <div style="border-bottom:3px solid #329948;padding-bottom:8px;margin-bottom:16px">
    <div style="font-size:12px;letter-spacing:.12em;color:#0C4982;font-weight:700">GRUPO BVEK · CRONOGRAMA</div>
    <div style="font-size:20px;font-weight:700;color:${cor};margin-top:4px">${escH(CABECALHO[tipo])}</div>
  </div>
  <p>Olá, ${escH(nome)}!<br>${escH(ABERTURA[tipo])}</p>
  <table style="border-collapse:collapse;font-size:15px">
    ${linha("📅 Data", d.data)}${linha("🕗 Horário", d.horario)}${linha("📍 Local", d.local)}
    ${linha("🏗️ Projeto", d.projeto)}${linha("🏢 Cliente", d.cliente)}${linha("🛠️ Serviço", d.servico)}
    ${tipo !== "cancelamento" ? linha("👥 Equipe", d.equipe) + linha("📝 Observações", d.obs) : ""}
  </table>
  <p style="margin-top:24px;font-size:12px;color:#777">Aviso automático do cronograma do Grupo BVEK. Em caso de dúvida, fale com o escritório.</p></div>`;
}

// parâmetros do modelo da Meta (sem quebra de linha, nunca vazios)
const param = (t: string) => ({ type: "text", text: (String(t || "").replace(/\s*\n+\s*/g, " | ").replace(/\s{4,}/g, "   ").trim() || "—").slice(0, 900) });

// ------------------------------------------------------------------ envios
async function enviarWhats(cfg: Linha, fone: string, tipo: Tipo, nome: string, d: Det): Promise<string | null> {
  const modelo = String(cfg.meta_modelo_convocacao || "").trim();
  const corpo = modelo
    ? {
      messaging_product: "whatsapp", to: fone, type: "template",
      template: {
        name: modelo, language: { code: cfg.meta_idioma || "pt_BR" },
        components: [{
          type: "body",
          parameters: [CABECALHO[tipo], nome, d.data, d.horario, d.local,
            [d.projeto, d.cliente && !d.projeto ? d.cliente : "", d.servico].filter(Boolean).join(" · "),
            tipo === "cancelamento" ? "Não é preciso comparecer." : d.obs].map(param),
        }],
      },
    }
    : { messaging_product: "whatsapp", to: fone, type: "text", text: { body: textoWhats(tipo, nome, d) } };
  const r = await fetch(`https://graph.facebook.com/v21.0/${encodeURIComponent(cfg.meta_phone_id)}/messages`, {
    method: "POST",
    headers: { Authorization: "Bearer " + cfg.meta_token, "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });
  if (r.ok) return null;
  const t = await r.text();
  try { const e = JSON.parse(t).error; return String(e.error_data?.details || e.message || t).slice(0, 300); } catch (_) { return t.slice(0, 300); }
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
async function enviarEmail(token: string, remetente: string, para: string, tipo: Tipo, nome: string, d: Det): Promise<string | null> {
  const assunto = `${CABECALHO[tipo]} — ${d.data}${d.projeto ? " — " + d.projeto : d.local ? " — " + d.local : ""}`.slice(0, 250);
  const rs = await fetch(`https://graph.microsoft.com/v1.0/users/${encodeURIComponent(remetente)}/sendMail`, {
    method: "POST",
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: JSON.stringify({
      message: { subject: assunto, body: { contentType: "HTML", content: emailHtml(tipo, nome, d) }, toRecipients: [{ emailAddress: { address: para } }] },
      saveToSentItems: true,
    }),
  });
  if (rs.status === 202) return null;
  const t = await rs.text();
  try { return String(JSON.parse(t).error.message).slice(0, 300); } catch (_) { return t.slice(0, 300); }
}

// ------------------------------------------------------------------ principal
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const adm = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    // 1. quem está chamando?
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: { user }, error: erroUsuario } = await adm.auth.getUser(jwt);
    if (erroUsuario || !user) return json({ erro: "Sessão inválida. Saia e entre de novo no CRM." }, 401);
    const { data: perfil } = await adm.from("perfis").select("perfil,ativo,nome,email").eq("id", user.id).maybeSingle();
    if (!perfil || !perfil.ativo || !PERFIS.includes(perfil.perfil)) return json({ erro: "Seu perfil não pode enviar convocações." }, 403);
    const quem = perfil.nome || perfil.email || user.email || "";
    const p = await req.json().catch(() => ({}));

    // 2. a alocação e o que já foi avisado
    const { data: l } = await adm.from("cronograma").select("*").eq("id", String(p.cronograma_id || "")).maybeSingle();
    if (!l) return json({ erro: "Alocação não encontrada. Salve antes de avisar." }, 404);
    if (l.data_fim < hojeBrasilia()) return json({ ok: true, pulado: "A alocação já terminou: ninguém foi avisado.", resultado: [] });

    const { data: avisos, error: eAv } = await adm.from("cronograma_avisos").select("funcionario_id,tipo,assinatura,ok,enviado_em")
      .eq("cronograma_id", l.id).eq("ok", true).order("enviado_em", { ascending: false });
    if (eAv) throw new Error(/cronograma_avisos/.test(eAv.message) ? "Falta rodar a migração v47 no Supabase." : eAv.message);
    const ultimo = new Map<string, Linha>();
    for (const a of avisos || []) if (a.funcionario_id && !ultimo.has(a.funcionario_id)) ultimo.set(a.funcionario_id, a);

    const equipeIds: string[] = l.situacao === "ativo" ? (l.funcionarios || []) : [];
    const ids = [...new Set([...(l.funcionarios || []), ...ultimo.keys()])];
    const [rf, rp, rw] = await Promise.all([
      adm.from("funcionarios").select("id,nome,email,celular,ativo").in("id", ids.length ? ids : ["00000000-0000-0000-0000-000000000000"]),
      l.projeto_id ? adm.from("projetos").select("id,codigo,nome,cliente_id,local").eq("id", l.projeto_id).maybeSingle() : Promise.resolve({ data: null }),
      adm.from("whatsapp_config").select("*").eq("id", 1).maybeSingle(),
    ]);
    const funcs = (rf.data || []) as Linha[];
    const proj = (rp.data || null) as Linha | null;
    const cliId = l.cliente_id || proj?.cliente_id;
    const cli = cliId ? ((await adm.from("clientes").select("id,codigo,nome").eq("id", cliId).maybeSingle()).data as Linha | null) : null;
    const cfg = (rw.data || {}) as Linha;

    const equipeNomes = equipeIds.map((id) => funcs.find((f) => f.id === id)).filter(Boolean).map((f) => nomeCurto(f!.nome));
    const d = detalhes(l, proj, cli, equipeNomes);
    // o que a pessoa precisa saber: se mudar, ela recebe "alteração"
    const assinatura = JSON.stringify([l.data_inicio, l.data_fim, !!l.sabado, !!l.domingo, hora(l.hora_inicio), hora(l.hora_fim), d.local, d.projeto, d.cliente, d.servico, d.obs]);

    // 3. quem recebe o quê
    const plano: { f: Linha; tipo: Tipo }[] = [];
    for (const id of ids) {
      const f = funcs.find((x) => x.id === id);
      if (!f || f.ativo === false) continue;
      const u = ultimo.get(id), avisado = !!u && u.tipo !== "cancelamento";
      if (equipeIds.includes(id)) {
        if (!avisado) plano.push({ f, tipo: "convocacao" });
        else if (u!.assinatura !== assinatura) plano.push({ f, tipo: "alteracao" });
        else if (p.reenviar) plano.push({ f, tipo: "convocacao" });
      } else if (avisado) plano.push({ f, tipo: "cancelamento" });
    }
    if (!plano.length) return json({ ok: true, pulado: "Todos já estavam avisados (nada mudou).", resultado: [] });

    // 4. canais disponíveis
    const temWhats = !!(String(cfg.meta_token || "").trim() && String(cfg.meta_phone_id || "").trim());
    const tenant = Deno.env.get("MS_TENANT_ID"), clientId = Deno.env.get("MS_CLIENT_ID");
    const segredo = Deno.env.get("MS_CLIENT_SECRET"), remetente = Deno.env.get("MS_REMETENTE");
    let tokenMs = "", erroMs = "";
    if (tenant && clientId && segredo && remetente && plano.some((x) => EMAIL_OK.test(String(x.f.email || "").trim()))) {
      try { tokenMs = await tokenM365(tenant, clientId, segredo); } catch (e) { erroMs = String((e as Error).message || e); }
    } else if (!(tenant && clientId && segredo && remetente)) erroMs = "e-mail do Microsoft 365 não configurado";

    // 5. envia e registra
    const resultado: Linha[] = [];
    const registros: Linha[] = [];
    for (const { f, tipo } of plano) {
      const nome = primeiroNome(f.nome);
      const fone = foneMeta(f.celular), email = String(f.email || "").trim();
      const r: Linha = { nome: f.nome, tipo, whatsapp: "", email: "" };
      if (!fone) r.whatsapp = "sem celular na ficha";
      else if (!temWhats) r.whatsapp = "WhatsApp (Meta) não configurado";
      else {
        let erro: string | null;
        try { erro = await enviarWhats(cfg, fone, tipo, nome, d); } catch (e) { erro = String((e as Error).message || e).slice(0, 300); }
        r.whatsapp = erro ? "erro: " + erro : "ok";
        registros.push({ cronograma_id: l.id, funcionario_id: f.id, tipo, canal: "whatsapp", destino: fone, ok: !erro, erro, assinatura, enviado_por: quem });
      }
      if (!EMAIL_OK.test(email)) r.email = "sem e-mail na ficha";
      else if (!tokenMs) r.email = erroMs || "e-mail não configurado";
      else {
        let erro: string | null;
        try { erro = await enviarEmail(tokenMs, remetente!, email, tipo, nome, d); } catch (e) { erro = String((e as Error).message || e).slice(0, 300); }
        r.email = erro ? "erro: " + erro : "ok";
        registros.push({ cronograma_id: l.id, funcionario_id: f.id, tipo, canal: "email", destino: email, ok: !erro, erro, assinatura, enviado_por: quem });
      }
      resultado.push(r);
    }
    if (registros.length) {
      const { error } = await adm.from("cronograma_avisos").insert(registros);
      if (error) console.warn("cronograma_avisos", error.message);
    }
    const enviados = resultado.filter((r) => r.whatsapp === "ok" || r.email === "ok").length;
    return json({ ok: true, enviados, total: resultado.length, resultado, sem_modelo: temWhats && !String(cfg.meta_modelo_convocacao || "").trim() });
  } catch (e) {
    return json({ erro: String((e as Error)?.message || e) }, 500);
  }
});
