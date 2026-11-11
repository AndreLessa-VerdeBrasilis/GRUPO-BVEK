// =====================================================================
// CRM Grupo BVEK — função "convocacao" (Supabase Edge Function) — v47
// Cronograma → avisa cada funcionário da equipe pelo WhatsApp (API oficial
// da Meta, configurada em Cronograma → ⚙️ WhatsApp — tabela
// whatsapp_convocacao_config, v48, separada do lembrete de pagamentos) e pelo e-mail
// (Microsoft 365, mesmos segredos da "email-comunicado":
//   MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET, MS_REMETENTE).
//
// Pedido (POST com JSON):
//   { cronograma_id: "..." }                  → avisa quem ainda não sabe:
//        • quem entrou na equipe → CONVOCAÇÃO
//        • quem já foi avisado e algo mudou (data, horário, local…) → ALTERAÇÃO
//        • quem saiu da equipe, ou alocação cancelada → CANCELAMENTO
//   { cronograma_id: "...", reenviar: true }  → manda de novo a todos da equipe
//   { teste_fone: "21999999999" }             → (só Administrador) manda uma convocação de exemplo
//   { diagnostico: true }                     → (v55, só Administrador) confere token, número e modelo na Meta
//   { escritorio_id: "..." }                  → (v53) evento do escritório: avisa os convidados
//        pelo WhatsApp (convite / alteração / cancelamento, mesma lógica acima;
//        o e-mail já vai pelo convite do Outlook). Celular: ficha do funcionário
//        com o mesmo e-mail (ou, se não houver, com o mesmo nome).
//        Desde a v54 também os funcionários convidados (agenda_escritorio.funcionarios),
//        mesmo sem e-mail: celular da própria ficha.
//   { escritorio_id: "...", reenviar: true }  → manda de novo a todos os convidados
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

const PERFIS = ["administrador", "comercial", "administrativo", "contabilidade", "estagiario"];
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
  if (d.projeto) l.push(`🏗️ *Contrato:* ${d.projeto}`);
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
    ${linha("🏗️ Contrato", d.projeto)}${linha("🏢 Cliente", d.cliente)}${linha("🛠️ Serviço", d.servico)}
    ${tipo !== "cancelamento" ? linha("👥 Equipe", d.equipe) + linha("📝 Observações", d.obs) : ""}
  </table>
  <p style="margin-top:24px;font-size:12px;color:#777">Aviso automático do cronograma do Grupo BVEK. Em caso de dúvida, fale com o escritório.</p></div>`;
}

// ------------------------------------------------------------------ v55: erros da Meta em português
const GRAPH = "https://graph.facebook.com/v24.0";
// o que cada código de erro da Meta quer dizer e o que fazer (os mais comuns na convocação)
const ERROS_META: Record<string, string> = {
  "190": "o token de acesso venceu ou é inválido. O token temporário do painel da Meta dura só 24 horas: gere um token PERMANENTE (Usuário do sistema no Gerenciador de Negócios, com a permissão whatsapp_business_messaging) e cole em Cronograma → ⚙️ WhatsApp",
  "10": "o token não tem permissão para este número. Ao gerar o token do Usuário do sistema, marque o app e as permissões whatsapp_business_messaging e whatsapp_business_management, e dê ao usuário acesso à conta do WhatsApp",
  "200": "o token não tem permissão para este número (veja as permissões whatsapp_business_messaging e whatsapp_business_management do Usuário do sistema)",
  "100": "algum dado está errado — confira o ID do número (Phone number ID, não é o número de telefone nem o ID da conta)",
  "33": "o ID do número não existe ou o token não enxerga ele — confira o Phone number ID no painel da Meta (WhatsApp → Configuração da API)",
  "131030": "o celular de destino não está na lista de números permitidos. Com o número de TESTE da Meta só é possível mandar para até 5 celulares cadastrados; para mandar para todos, registre o número oficial da empresa",
  "131031": "a conta do WhatsApp da empresa está bloqueada ou restrita pela Meta — veja o aviso no Gerenciador do WhatsApp",
  "131042": "problema de pagamento na conta da Meta: cadastre um cartão em Gerenciador de Negócios → Cobrança do WhatsApp",
  "131047": "passaram mais de 24 horas desde a última mensagem dessa pessoa — fora desse prazo só vai mensagem com modelo aprovado (preencha o nome do modelo)",
  "131026": "a mensagem não pôde ser entregue (o celular não tem WhatsApp, ou a pessoa não aceitou os termos novos do WhatsApp)",
  "131056": "muitas mensagens seguidas para o mesmo celular — espere alguns minutos",
  "130429": "limite de envios da Meta atingido — espere alguns minutos e tente de novo",
  "131008": "o modelo pede um dado que não foi mandado",
  "132000": "o modelo aprovado na Meta não tem 7 variáveis ({{1}} a {{7}}) no corpo — o CRM manda sempre 7. Crie o modelo como o exemplo da tela ⚙️ WhatsApp",
  "132001": "o modelo não existe com esse nome e idioma. Confira o nome exato (minúsculas, com _) e o idioma (pt_BR) em Gerenciador do WhatsApp → Modelos de mensagem",
  "132005": "o texto do modelo com os dados ficou grande demais",
  "132007": "o modelo foi recusado pela política da Meta",
  "132012": "o formato das variáveis do modelo não bate com o que o CRM manda (use variáveis numeradas {{1}}…{{7}}, não nomeadas)",
  "132015": "o modelo foi pausado pela Meta por baixa qualidade",
  "132016": "o modelo foi desativado pela Meta",
  "133010": "o número da empresa não está registrado na API da Meta. No painel: WhatsApp → Configuração da API → registre o número (código PIN de 6 dígitos)",
  "135000": "erro genérico da Meta — tente de novo em alguns minutos",
};
function erroMeta(t: string): string {
  try {
    const e = JSON.parse(t).error || {};
    const cod = String(e.code ?? ""), sub = String(e.error_subcode ?? "");
    const det = String(e.error_data?.details || e.message || t).slice(0, 200);
    const exp = ERROS_META[cod] || (sub && ERROS_META[sub]) || (/expired|session has expired/i.test(det) ? ERROS_META["190"] : "");
    return (exp ? exp + ". " : "") + `[Meta: código ${cod || "?"}${sub ? "/" + sub : ""} — ${det}]`;
  } catch (_) { return t.slice(0, 300); }
}
// confere token, número e modelo, sem mandar mensagem
async function diagnosticoMeta(cfg: Linha): Promise<Linha> {
  const tok = String(cfg.meta_token || "").trim(), phone = String(cfg.meta_phone_id || "").trim(), modelo = String(cfg.meta_modelo || "").trim();
  const itens: { ok: boolean | null; item: string; texto: string }[] = [];
  const get = async (url: string) => {
    const r = await fetch(url, { headers: { Authorization: "Bearer " + tok } });
    const t = await r.text();
    return { ok: r.ok, t, j: (() => { try { return JSON.parse(t); } catch (_) { return {}; } })() };
  };
  if (!tok || !phone) return { itens: [{ ok: false, item: "Configuração", texto: "Preencha o token e o ID do número e salve." }] };
  if (/\D/.test(phone)) itens.push({ ok: false, item: "ID do número", texto: "O Phone number ID tem só números (ex.: 123456789012345). Parece que foi colado outro dado." });
  // 1. token
  const dt = await get(`${GRAPH}/debug_token?input_token=${encodeURIComponent(tok)}`);
  let wabas: string[] = [];
  if (dt.ok && dt.j.data) {
    const d = dt.j.data;
    const venc = Number(d.expires_at || 0);
    if (d.is_valid === false) itens.push({ ok: false, item: "Token", texto: "Inválido ou vencido. " + ERROS_META["190"] + "." });
    else itens.push({ ok: venc ? null : true, item: "Token", texto: venc ? `Válido, mas VENCE em ${new Date(venc * 1000).toLocaleString("pt-BR", { timeZone: FUSO })}. Troque por um token permanente (Usuário do sistema).` : "Válido e permanente (não vence)." });
    const esc = (d.scopes || []) as string[];
    if (esc.length && !esc.includes("whatsapp_business_messaging")) itens.push({ ok: false, item: "Permissões do token", texto: "Falta a permissão whatsapp_business_messaging." });
    for (const g of (d.granular_scopes || []) as Linha[]) if (/whatsapp_business/.test(g.scope)) wabas.push(...((g.target_ids || []) as string[]));
    wabas = [...new Set(wabas)];
  } else {
    itens.push({ ok: false, item: "Token", texto: "A Meta não aceitou o token: " + erroMeta(dt.t) });
  }
  // 2. número
  const nr = await get(`${GRAPH}/${encodeURIComponent(phone)}?fields=display_phone_number,verified_name,name_status,quality_rating,platform_type,code_verification_status`);
  if (nr.ok) {
    const n = nr.j;
    itens.push({ ok: true, item: "Número", texto: `${n.display_phone_number || "?"} — ${n.verified_name || "(sem nome)"}${n.quality_rating ? " · qualidade " + n.quality_rating : ""}` });
    if (n.platform_type && n.platform_type !== "CLOUD_API") itens.push({ ok: false, item: "Registro do número", texto: ERROS_META["133010"] + ` (situação atual: ${n.platform_type}).` });
    if (n.name_status && !/APPROVED|AVAILABLE_WITHOUT_REVIEW/.test(n.name_status)) itens.push({ ok: null, item: "Nome de exibição", texto: `Situação do nome na Meta: ${n.name_status}. Enquanto não for aprovado, a Meta limita os envios.` });
    if (/^\+?1\s?555/.test(String(n.display_phone_number || ""))) itens.push({ ok: null, item: "Número de teste", texto: "Este é o número de TESTE da Meta: só manda para até 5 celulares cadastrados no painel. Para avisar todos os funcionários, registre o número oficial da empresa." });
  } else itens.push({ ok: false, item: "Número", texto: erroMeta(nr.t) });
  // 3. modelo
  if (!modelo) itens.push({ ok: null, item: "Modelo", texto: "Sem modelo: a Meta só entrega a quem mandou mensagem para o número da empresa nas últimas 24 horas — e mesmo assim responde \"ok\" aqui, sem avisar quando não entrega. Por isso a mensagem parece enviada mas não chega. Cadastre um modelo aprovado." });
  else if (!wabas.length) itens.push({ ok: null, item: "Modelo", texto: `Não deu para conferir o modelo "${modelo}" (o token não mostra a conta do WhatsApp). Confira no Gerenciador do WhatsApp se ele está APROVADO, no idioma ${cfg.meta_idioma || "pt_BR"} e com 7 variáveis.` });
  else {
    let achou: Linha[] = [];
    for (const w of wabas) {
      const m = await get(`${GRAPH}/${encodeURIComponent(w)}/message_templates?name=${encodeURIComponent(modelo)}&fields=name,status,language,category,components,parameter_format&limit=50`);
      if (m.ok) achou.push(...((m.j.data || []) as Linha[]).filter((x) => x.name === modelo));
    }
    const idioma = String(cfg.meta_idioma || "pt_BR");
    const certo = achou.find((x) => x.language === idioma);
    if (!achou.length) itens.push({ ok: false, item: "Modelo", texto: `Não existe modelo com o nome "${modelo}". ${ERROS_META["132001"]}.` });
    else if (!certo) itens.push({ ok: false, item: "Modelo", texto: `O modelo "${modelo}" existe só em ${achou.map((x) => x.language).join(", ")} — no CRM o idioma está "${idioma}". Corrija o idioma.` });
    else {
      const corpo = String(((certo.components || []) as Linha[]).find((c) => c.type === "BODY")?.text || "");
      const vars = new Set((corpo.match(/\{\{\s*([^}\s]+)\s*\}\}/g) || []).map((v) => v.replace(/[{}\s]/g, "")));
      const cab = ((certo.components || []) as Linha[]).find((c) => c.type === "HEADER");
      const probs: string[] = [];
      if (certo.status !== "APPROVED") probs.push(`está ${certo.status} (precisa estar APPROVED)`);
      if (certo.parameter_format === "NAMED" || [...vars].some((v) => !/^\d+$/.test(v))) probs.push("usa variáveis com nome — o CRM precisa de variáveis numeradas {{1}} a {{7}}");
      else if (vars.size !== 7) probs.push(`tem ${vars.size} variável(is) no corpo — precisa ter exatamente 7 ({{1}} a {{7}})`);
      if (cab && /\{\{/.test(String(cab.text || ""))) probs.push("tem variável no cabeçalho — tire a variável do cabeçalho (o CRM só preenche o corpo)");
      if (cab && cab.format && cab.format !== "TEXT") probs.push(`o cabeçalho é ${cab.format} (imagem/documento) — use cabeçalho de texto ou nenhum`);
      itens.push(probs.length ? { ok: false, item: "Modelo", texto: `"${modelo}" ${probs.join("; ")}.` } : { ok: true, item: "Modelo", texto: `"${modelo}" aprovado, ${idioma}, 7 variáveis (${certo.category}).` });
    }
  }
  return { itens };
}

// parâmetros do modelo da Meta (sem quebra de linha, nunca vazios)
const param = (t: string) => ({ type: "text", text: (String(t || "").replace(/\s*\n+\s*/g, " | ").replace(/\s{4,}/g, "   ").trim() || "—").slice(0, 900) });

// ------------------------------------------------------------------ v53: evento do escritório
type TipoEsc = "convite" | "alteracao" | "cancelamento";
const CAB_ESC: Record<TipoEsc, string> = {
  convite: "Evento do escritório",
  alteracao: "Evento do escritório ALTERADO",
  cancelamento: "Evento do escritório CANCELADO",
};
const ABRE_ESC: Record<TipoEsc, string> = {
  convite: "Você foi convidado(a) para o evento abaixo.",
  alteracao: "Houve mudança no evento abaixo. Vale o que está aqui.",
  cancelamento: "O evento abaixo foi cancelado. Não é preciso comparecer.",
};
const FUSO = "America/Sao_Paulo";
const diaFuso = (ts: string) => new Intl.DateTimeFormat("en-CA", { timeZone: FUSO, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(ts));
const horaFuso = (ts: string) => new Intl.DateTimeFormat("pt-BR", { timeZone: FUSO, hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(ts));
const semAcento = (t: unknown) => String(t || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim().replace(/\s+/g, " ");
function detalhesEsc(e: Linha) {
  const d1 = diaFuso(e.inicio), d2 = diaFuso(e.fim);
  const data = d1 === d2 ? `${diaSemana(d1)}, ${dataBR(d1)}` : `${diaSemana(d1)}, ${dataBR(d1, false)} a ${diaSemana(d2)}, ${dataBR(d2)}`;
  const horario = e.dia_inteiro ? "dia inteiro"
    : d1 === d2 ? `${horaFuso(e.inicio)} às ${horaFuso(e.fim)}` : `${horaFuso(e.inicio)} (${dataBR(d1, false)}) às ${horaFuso(e.fim)} (${dataBR(d2, false)})`;
  return { data, horario, local: String(e.local || "").trim() || "a combinar com o escritório", titulo: String(e.titulo || "").trim(), pauta: String(e.descricao || "").trim(), fim: d2 };
}
function textoWhatsEsc(tipo: TipoEsc, nome: string, d: ReturnType<typeof detalhesEsc>, quem: string): string {
  const icone = tipo === "cancelamento" ? "❌" : tipo === "alteracao" ? "🔄" : "🏢";
  const l = [`${icone} *${CAB_ESC[tipo]} — Grupo BVEK*`, `Olá, ${nome}! ${ABRE_ESC[tipo]}`, "",
    `📌 *Assunto:* ${d.titulo}`, `📅 *Data:* ${d.data}`, `🕗 *Horário:* ${d.horario}`, `📍 *Local:* ${d.local}`];
  if (tipo !== "cancelamento" && d.pauta) l.push(`📝 *Pauta:* ${d.pauta}`);
  if (quem) l.push(`👤 *Marcado por:* ${quem}`);
  l.push("", "O convite também está no seu Outlook.");
  return l.join("\n");
}
async function enviarWhatsEsc(cfg: Linha, fone: string, tipo: TipoEsc, nome: string, d: ReturnType<typeof detalhesEsc>, quem: string): Promise<string | null> {
  const modelo = String(cfg.meta_modelo || "").trim();
  // mesmo modelo de 7 variáveis da convocação: {{6}} = assunto, {{7}} = pauta
  const corpo = modelo
    ? {
      messaging_product: "whatsapp", to: fone, type: "template",
      template: {
        name: modelo, language: { code: cfg.meta_idioma || "pt_BR" },
        components: [{
          type: "body",
          parameters: [CAB_ESC[tipo], nome, d.data, d.horario, d.local, d.titulo,
            tipo === "cancelamento" ? "Não é preciso comparecer." : d.pauta].map(param),
        }],
      },
    }
    : { messaging_product: "whatsapp", to: fone, type: "text", text: { body: textoWhatsEsc(tipo, nome, d, quem) } };
  const r = await fetch(`${GRAPH}/${encodeURIComponent(String(cfg.meta_phone_id).trim())}/messages`, {
    method: "POST",
    headers: { Authorization: "Bearer " + String(cfg.meta_token).trim(), "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });
  if (r.ok) return null;
  return erroMeta(await r.text());
}
// deno-lint-ignore no-explicit-any
async function avisarEscritorio(adm: any, p: Linha, quem: string, cfg: Linha): Promise<Response> {
  const { data: e } = await adm.from("agenda_escritorio").select("*").eq("id", String(p.escritorio_id || "")).maybeSingle();
  if (!e) return json({ erro: "Evento não encontrado. Salve antes de avisar." }, 404);
  const d = detalhesEsc(e);
  if (d.fim < hojeBrasilia()) return json({ ok: true, pulado: "O evento já terminou: ninguém foi avisado.", resultado: [] });

  const { data: avisos, error: eAv } = await adm.from("agenda_escritorio_avisos").select("email,funcionario_id,nome,tipo,assinatura,ok,enviado_em")
    .eq("evento_id", e.id).eq("ok", true).order("enviado_em", { ascending: false });
  if (eAv) throw new Error(/agenda_escritorio_avisos|funcionario_id/.test(eAv.message) ? "Falta rodar as migrações v53 e v54 no Supabase." : eAv.message);
  // cada convidado tem uma chave: "f:<id>" (funcionário convidado, v54) ou o e-mail (convidado do Outlook/CRM)
  const chaveAviso = (a: Linha) => a.funcionario_id ? "f:" + a.funcionario_id : String(a.email || "");
  const ultimo = new Map<string, Linha>();
  for (const a of avisos || []) { const k = chaveAviso(a); if (k && !ultimo.has(k)) ultimo.set(k, a); }

  const caixa = "agenda@bvek.com.br";
  const convidados = new Map<string, { nome: string; email?: string; funcId?: string }>();
  if (e.situacao === "ativo") {
    for (const x of (e.participantes || []) as Linha[]) {
      const em = String(x.email || "").toLowerCase().trim();
      if (em && em !== caixa) convidados.set(em, { nome: String(x.nome || em), email: em });
    }
    for (const id of (e.funcionarios || []) as string[]) if (id) convidados.set("f:" + id, { nome: "", funcId: id });
  }
  const chaves = [...new Set([...convidados.keys(), ...ultimo.keys()])];
  const assinatura = JSON.stringify([e.inicio, e.fim, !!e.dia_inteiro, d.local, d.titulo, d.pauta]);

  const plano: { chave: string; email?: string; funcId?: string; nome: string; tipo: TipoEsc }[] = [];
  for (const k of chaves) {
    const u = ultimo.get(k), avisado = !!u && u.tipo !== "cancelamento";
    const c = convidados.get(k);
    const base = { chave: k, email: c?.email || (u?.email || undefined), funcId: c?.funcId || (u?.funcionario_id || undefined), nome: c?.nome || String(u?.nome || "") || (k.startsWith("f:") ? "" : k) };
    if (c) {
      if (!avisado) plano.push({ ...base, tipo: "convite" });
      else if (u!.assinatura !== assinatura) plano.push({ ...base, tipo: "alteracao" });
      else if (p.reenviar) plano.push({ ...base, tipo: "convite" });
    } else if (avisado) plano.push({ ...base, tipo: "cancelamento" });
  }
  if (!plano.length) return json({ ok: true, pulado: "Todos já estavam avisados no WhatsApp (nada mudou).", resultado: [] });

  // celular: funcionário convidado → a própria ficha; convidado por e-mail → ficha com o mesmo e-mail (ou o mesmo nome)
  const { data: fs } = await adm.from("funcionarios").select("id,nome,email,celular,ativo");
  const todos = (fs || []) as Linha[];
  const comFone = todos.filter((f) => f.ativo !== false && foneMeta(f.celular));
  const acharFunc = (x: { email?: string; funcId?: string; nome: string }) =>
    x.funcId ? todos.find((f) => f.id === x.funcId)
      : comFone.find((f) => String(f.email || "").toLowerCase().trim() === x.email) ||
        (x.nome && x.nome !== x.email ? comFone.find((f) => semAcento(f.nome) === semAcento(x.nome)) : undefined);

  const temWhats = cfg.ativo !== false && !!(String(cfg.meta_token || "").trim() && String(cfg.meta_phone_id || "").trim());
  const organizador = String(e.organizador || e.criado_por || "").trim();
  const resultado: Linha[] = [], registros: Linha[] = [];
  const jaMandado = new Map<string, TipoEsc>();   // mesmo celular convidado duas vezes (por e-mail e como funcionário): uma mensagem só
  for (const x of plano) {
    const f = acharFunc(x);
    const fone = f && f.ativo !== false ? foneMeta(f.celular) : "";
    const nomeCompleto = f?.nome || x.nome || (x.email || "").split("@")[0] || "(funcionário)";
    const r: Linha = { nome: nomeCompleto, email: x.email || null, tipo: x.tipo, whatsapp: "" };
    if (!f && x.funcId) r.whatsapp = "funcionário não encontrado";
    else if (f && f.ativo === false && x.tipo !== "cancelamento") r.whatsapp = "funcionário inativo";
    else if (!fone) r.whatsapp = "sem celular na ficha";
    else if (!temWhats) r.whatsapp = cfg.ativo === false ? "WhatsApp desligado (Cronograma → ⚙️ WhatsApp)" : "WhatsApp (Meta) não configurado";
    else if (jaMandado.has(fone) && jaMandado.get(fone) === x.tipo) {
      // registra como avisado sem mandar de novo
      r.whatsapp = "ok";
      registros.push({ evento_id: e.id, email: x.email || null, funcionario_id: x.funcId || null, nome: r.nome, tipo: x.tipo, canal: "whatsapp", destino: fone, ok: true, erro: null, assinatura, enviado_por: quem });
      continue;
    } else {
      let erro: string | null;
      try { erro = await enviarWhatsEsc(cfg, fone, x.tipo, primeiroNome(nomeCompleto), d, organizador); } catch (er) { erro = String((er as Error).message || er).slice(0, 300); }
      if (!erro) jaMandado.set(fone, x.tipo);
      r.whatsapp = erro ? "erro: " + erro : "ok";
      registros.push({ evento_id: e.id, email: x.email || null, funcionario_id: x.funcId || null, nome: r.nome, tipo: x.tipo, canal: "whatsapp", destino: fone, ok: !erro, erro, assinatura, enviado_por: quem });
    }
    resultado.push(r);
  }
  if (registros.length) {
    const { error } = await adm.from("agenda_escritorio_avisos").insert(registros);
    if (error) console.warn("agenda_escritorio_avisos", error.message);
  }
  const enviados = resultado.filter((r) => r.whatsapp === "ok").length;
  return json({ ok: true, enviados, total: resultado.length, resultado, sem_modelo: temWhats && !String(cfg.meta_modelo || "").trim() });
}

// ------------------------------------------------------------------ envios
async function enviarWhats(cfg: Linha, fone: string, tipo: Tipo, nome: string, d: Det): Promise<string | null> {
  const modelo = String(cfg.meta_modelo || "").trim();
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
  const r = await fetch(`${GRAPH}/${encodeURIComponent(String(cfg.meta_phone_id).trim())}/messages`, {
    method: "POST",
    headers: { Authorization: "Bearer " + String(cfg.meta_token).trim(), "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });
  if (r.ok) return null;
  return erroMeta(await r.text());
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
    const lerConfig = async () => {
      const { data, error } = await adm.from("whatsapp_convocacao_config").select("*").eq("id", 1).maybeSingle();
      if (error) throw new Error(/whatsapp_convocacao_config/.test(error.message) ? "Falta rodar a migração v48 no Supabase." : error.message);
      return (data || {}) as Linha;
    };

    // v55: diagnóstico (só Administrador) — confere token, número e modelo sem mandar mensagem
    if (p.diagnostico) {
      if (perfil.perfil !== "administrador") return json({ erro: "Só o Administrador faz o diagnóstico." }, 403);
      return json({ ok: true, ...(await diagnosticoMeta(await lerConfig())) });
    }

    // teste: uma convocação de exemplo para o número informado
    if (p.teste_fone) {
      if (perfil.perfil !== "administrador") return json({ erro: "Só o Administrador faz o teste." }, 403);
      const cfg = await lerConfig();
      if (!String(cfg.meta_token || "").trim() || !String(cfg.meta_phone_id || "").trim()) return json({ erro: "Preencha o token e o ID do número da Meta e salve." }, 400);
      const fone = foneMeta(p.teste_fone);
      if (!fone) return json({ erro: "Número inválido: informe com DDD." }, 400);
      const hoje = hojeBrasilia();
      const d = detalhes({ data_inicio: hoje, data_fim: hoje, hora_inicio: "07:00", hora_fim: "17:00", local: "Local de exemplo", titulo: "TESTE da convocação", observacoes: "Mensagem de teste do CRM — pode ignorar." }, null, null, [nomeCurto(perfil.nome || "Equipe")]);
      const erro = await enviarWhats(cfg, fone, "convocacao", primeiroNome(perfil.nome || ""), d);
      return erro ? json({ erro: "A Meta recusou: " + erro }, 400) : json({ ok: true, sem_modelo: !String(cfg.meta_modelo || "").trim() });
    }

    // v53: evento do escritório → WhatsApp dos convidados
    if (p.escritorio_id) return await avisarEscritorio(adm, p, quem, await lerConfig());

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
    const [rf, rp, cfg] = await Promise.all([
      adm.from("funcionarios").select("id,nome,email,celular,ativo").in("id", ids.length ? ids : ["00000000-0000-0000-0000-000000000000"]),
      l.projeto_id ? adm.from("projetos").select("id,codigo,nome,cliente_id,local").eq("id", l.projeto_id).maybeSingle() : Promise.resolve({ data: null }),
      lerConfig(),
    ]);
    const funcs = (rf.data || []) as Linha[];
    const proj = (rp.data || null) as Linha | null;
    const cliId = l.cliente_id || proj?.cliente_id;
    const cli = cliId ? ((await adm.from("clientes").select("id,codigo,nome").eq("id", cliId).maybeSingle()).data as Linha | null) : null;

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
    const temWhats = cfg.ativo !== false && !!(String(cfg.meta_token || "").trim() && String(cfg.meta_phone_id || "").trim());
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
      else if (!temWhats) r.whatsapp = cfg.ativo === false ? "WhatsApp da convocação desligado" : "WhatsApp (Meta) não configurado";
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
    return json({ ok: true, enviados, total: resultado.length, resultado, sem_modelo: temWhats && !String(cfg.meta_modelo || "").trim() });
  } catch (e) {
    return json({ erro: String((e as Error)?.message || e) }, 500);
  }
});
