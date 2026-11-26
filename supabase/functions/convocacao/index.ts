// =====================================================================
// CRM Grupo BVEK — função "convocacao" (Supabase Edge Function) — v47 / v72 / v85
// v85: INTERMITENTES (RH → ficha → tipo de contrato) recebem a CONVOCAÇÃO EM PDF
//      (papel timbrado, art. 452-A da CLT), guardada em Documentos (tipo
//      "Convocação de intermitente", documentos.cronograma_id) e enviada junto:
//      no WhatsApp (modelo com documento no cabeçalho, se configurado; senão o
//      link do PDF vai no texto) e anexada ao e-mail. Alteração → convocação nova
//      (a antiga fica "substituída"); cancelamento → convocação "arquivada".
//      Alocação que já terminou → só a DECLARAÇÃO de prestação de serviços.
//      Precisa da migração v85.
// v72: erro 138000 (botão de ligação pelo WhatsApp no modelo) explicado e
//      apontado pelo diagnóstico; conta do WhatsApp (WABA) informada na tela.
// Cronograma → avisa cada funcionário da equipe pelo WhatsApp (API oficial
// da Meta, configurada em Cronograma → WhatsApp — tabela
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
import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";

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
  const l = [`*${CABECALHO[tipo]} — Grupo BVEK*`, `Olá, ${nome}! ${ABERTURA[tipo]}`, "",
    `*Data:* ${d.data}`, `*Horário:* ${d.horario}`, `*Local:* ${d.local}`];
  if (d.projeto) l.push(`*Contrato:* ${d.projeto}`);
  if (d.cliente) l.push(`*Cliente:* ${d.cliente}`);
  if (d.servico) l.push(`*Serviço:* ${d.servico}`);
  if (tipo !== "cancelamento" && d.equipe) l.push(`*Equipe:* ${d.equipe}`);
  if (tipo !== "cancelamento" && d.obs) l.push(`*Obs.:* ${d.obs}`);
  l.push("", "Dúvidas? Fale com o escritório.");
  return l.join("\n");
}

function emailHtml(tipo: Tipo, nome: string, d: Det, comPdf = false): string {
  const cor = tipo === "cancelamento" ? "#C0392B" : "#0C4982";
  const linha = (rot: string, v: string) => v ? `<tr><td style="padding:4px 12px 4px 0;color:#555;white-space:nowrap;vertical-align:top">${rot}</td><td style="padding:4px 0;font-weight:600">${escH(v).replace(/\n/g, "<br>")}</td></tr>` : "";
  return `<div style="font-family:Calibri,Arial,sans-serif;font-size:15px;color:#222;max-width:640px">
  <div style="border-bottom:3px solid #329948;padding-bottom:8px;margin-bottom:16px">
    <div style="font-size:12px;letter-spacing:.12em;color:#0C4982;font-weight:700">GRUPO BVEK · CRONOGRAMA</div>
    <div style="font-size:20px;font-weight:700;color:${cor};margin-top:4px">${escH(CABECALHO[tipo])}</div>
  </div>
  <p>Olá, ${escH(nome)}!<br>${escH(ABERTURA[tipo])}</p>
  <table style="border-collapse:collapse;font-size:15px">
    ${linha("Data", d.data)}${linha("Horário", d.horario)}${linha("Local", d.local)}
    ${linha("Contrato", d.projeto)}${linha("Cliente", d.cliente)}${linha("Serviço", d.servico)}
    ${tipo !== "cancelamento" ? linha("Equipe", d.equipe) + linha("Observações", d.obs) : ""}
  </table>
  ${comPdf ? `<p style="margin-top:16px">A convocação em PDF está anexada a este e-mail. Responda em até 1 dia útil (pelo WhatsApp, por e-mail ou ao escritório).</p>` : ""}
  <p style="margin-top:24px;font-size:12px;color:#777">Aviso automático do cronograma do Grupo BVEK. Em caso de dúvida, fale com o escritório.</p></div>`;
}

// ------------------------------------------------------------------ v55: erros da Meta em português
const GRAPH = "https://graph.facebook.com/v24.0";
// o que cada código de erro da Meta quer dizer e o que fazer (os mais comuns na convocação)
const ERROS_META: Record<string, string> = {
  "190": "o token de acesso venceu ou é inválido. O token temporário do painel da Meta dura só 24 horas: gere um token PERMANENTE (Usuário do sistema no Gerenciador de Negócios, com a permissão whatsapp_business_messaging) e cole em Cronograma → WhatsApp",
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
  "132000": "o modelo aprovado na Meta não tem 7 variáveis ({{1}} a {{7}}) no corpo — o CRM manda sempre 7. Crie o modelo como o exemplo da tela WhatsApp",
  "132001": "o modelo não existe com esse nome e idioma. Confira o nome exato (minúsculas, com _) e o idioma (pt_BR) em Gerenciador do WhatsApp → Modelos de mensagem",
  "132005": "o texto do modelo com os dados ficou grande demais",
  "132007": "o modelo foi recusado pela política da Meta",
  "132012": "o formato das variáveis do modelo não bate com o que o CRM manda (use variáveis numeradas {{1}}…{{7}}, não nomeadas)",
  "132015": "o modelo foi pausado pela Meta por baixa qualidade",
  "132016": "o modelo foi desativado pela Meta",
  "133010": "o número da empresa não está registrado na API da Meta. No painel: WhatsApp → Configuração da API → registre o número (código PIN de 6 dígitos)",
  "135000": "erro genérico da Meta — tente de novo em alguns minutos",
  // v72: o modelo tem botão "Ligar no WhatsApp" (chamada de voz) ou pedido de permissão de chamada,
  // e as chamadas (Calling API) não estão ligadas no número. A Meta recusa a mensagem inteira.
  "138000": "o modelo de mensagem tem um botão de LIGAÇÃO PELO WHATSAPP (\"Ligar no WhatsApp\" / chamada de voz) ou pedido de permissão de chamada, e as chamadas não estão ligadas no número da empresa (a Meta só libera chamadas para números com limite de 2.000 conversas ou mais). Solução: no Gerenciador do WhatsApp → Modelos de mensagem, crie um modelo novo SEM esse botão (pode ter o botão \"Ligar\" comum, de telefone) e troque o nome do modelo em Cronograma → WhatsApp",
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
  // v72: conta do WhatsApp (WABA) — informada na tela ou achada pelas empresas do token
  const wabaCfg = String(cfg.meta_waba_id || "").replace(/\D/g, "");
  if (wabaCfg) wabas = [wabaCfg, ...wabas.filter((w) => w !== wabaCfg)];
  if (!wabas.length) {
    const bs = await get(`${GRAPH}/me/businesses?fields=id&limit=20`);
    for (const b of ((bs.j.data || []) as Linha[])) {
      for (const tipo of ["owned_whatsapp_business_accounts", "client_whatsapp_business_accounts"]) {
        const w = await get(`${GRAPH}/${encodeURIComponent(b.id)}/${tipo}?fields=id&limit=50`);
        for (const x of ((w.j.data || []) as Linha[])) if (x.id) wabas.push(String(x.id));
      }
    }
    wabas = [...new Set(wabas)];
  }
  // 3. modelo
  if (!modelo) itens.push({ ok: null, item: "Modelo", texto: "Sem modelo: a Meta só entrega a quem mandou mensagem para o número da empresa nas últimas 24 horas — e mesmo assim responde \"ok\" aqui, sem avisar quando não entrega. Por isso a mensagem parece enviada mas não chega. Cadastre um modelo aprovado." });
  else if (!wabas.length) itens.push({ ok: null, item: "Modelo", texto: `Não deu para conferir o modelo "${modelo}" (o token não mostra a conta do WhatsApp). Preencha o "ID da conta do WhatsApp (WABA)" em Cronograma → WhatsApp e diagnostique de novo, ou confira no Gerenciador do WhatsApp se ele está APROVADO, no idioma ${cfg.meta_idioma || "pt_BR"}, com 7 variáveis e SEM botão de ligação pelo WhatsApp.` });
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
      // v72: botão de ligação pelo WhatsApp / pedido de permissão de chamada → erro 138000 se as chamadas não estão ligadas
      const comps = (certo.components || []) as Linha[];
      const botoes = comps.filter((c) => c.type === "BUTTONS").flatMap((c) => (c.buttons || []) as Linha[]);
      if (comps.some((c) => /CALL_PERMISSION/i.test(String(c.type))) || botoes.some((b) => /VOICE_CALL|CALL_PERMISSION/i.test(String(b.type))))
        probs.push("tem botão de LIGAÇÃO PELO WHATSAPP (chamada de voz) ou pedido de permissão de chamada — isso dá o erro 138000 enquanto as chamadas não estiverem ligadas no número. Crie um modelo sem esse botão");
      else if (botoes.some((b) => b.type === "URL" && /\{\{/.test(String(b.url || ""))))
        probs.push("tem botão de link com variável — o CRM não preenche botões; use link fixo ou tire o botão");
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
  const l = [`*${CAB_ESC[tipo]} — Grupo BVEK*`, `Olá, ${nome}! ${ABRE_ESC[tipo]}`, "",
    `*Assunto:* ${d.titulo}`, `*Data:* ${d.data}`, `*Horário:* ${d.horario}`, `*Local:* ${d.local}`];
  if (tipo !== "cancelamento" && d.pauta) l.push(`*Pauta:* ${d.pauta}`);
  if (quem) l.push(`*Marcado por:* ${quem}`);
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
    else if (!temWhats) r.whatsapp = cfg.ativo === false ? "WhatsApp desligado (Cronograma → WhatsApp)" : "WhatsApp (Meta) não configurado";
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

// ------------------------------------------------------------------ v85: convocação em PDF (intermitentes)
const CRM_URL = "https://grupo-bvek.vercel.app";
// funcionários registrados só no CNPJ da Verde Brasilis (mesmos dados do termo de adesão no CRM)
const EMPREGADORA = {
  razao: "VERDE BRASILIS GESTÃO E SERVIÇOS LTDA.", cnpj: "27.400.958/0001-26",
  sede: "Rua Conquista, nº 270 – Jardim Guanabara – Ilha do Governador", representante: "André Ferreira Lessa", cargo: "Diretor",
};
const TIPO_DOC_CONV = "Convocação de intermitente";
const SEMANA_LONGA = ["domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado"];
const MESES = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"];
const fmtCPF = (c: unknown) => { const d = String(c || "").replace(/\D/g, ""); return d.length === 11 ? `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}` : String(c || ""); };
const somaDias = (iso: string, n: number) => { const d = new Date(iso + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
// dias da alocação (mesma regra do CRM: dias úteis + sábado/domingo se marcados; um dia só sempre conta)
function diasDaAloc(l: Linha): string[] {
  const ini = String(l.data_inicio), fim = String(l.data_fim), r: string[] = [];
  if (ini === fim) return [ini];
  for (let d = ini; d <= fim && r.length < 120; d = somaDias(d, 1)) {
    const s = new Date(d + "T12:00:00Z").getUTCDay();
    if ((s === 6 && !l.sabado) || (s === 0 && !l.domingo)) continue;
    r.push(d);
  }
  return r;
}
let timbradoCache: Uint8Array | null | undefined;
async function bytesTimbrado(): Promise<Uint8Array | null> {
  if (timbradoCache !== undefined) return timbradoCache;
  try { const r = await fetch(CRM_URL + "/img/timbrado/bvk-timbrado.pdf"); timbradoCache = r.ok ? new Uint8Array(await r.arrayBuffer()) : null; } catch (_) { timbradoCache = null; }
  return timbradoCache;
}
// deno-lint-ignore no-explicit-any
async function bytesAssinaturaRep(adm: any): Promise<Uint8Array | null> {
  try { const { data, error } = await adm.storage.from("rh").download("assinaturas/representante.png"); return error || !data ? null : new Uint8Array(await data.arrayBuffer()); } catch (_) { return null; }
}
type Run = [string, boolean];
type TextoDoc = { titulo: string; sub: string; partes: Run[][]; abertura: string; clausulas: [string, string][]; fecho: string };
function textoConvocacao(modo: "convocacao" | "alteracao" | "declaracao", l: Linha, f: Linha, d: Det, emitidoAnterior: string | null): TextoDoc {
  const E = EMPREGADORA, dias = diasDaAloc(l), hoje = hojeBrasilia();
  const listaDias = dias.length <= 12
    ? dias.map((x) => `${dataBR(x)} (${SEMANA_LONGA[new Date(x + "T12:00:00Z").getUTCDay()]})`).join("; ")
    : `de ${dataBR(dias[0])} a ${dataBR(dias[dias.length - 1])}, ${d.data.replace(/^.*\(/, "(")}`;
  const antecedencia = Math.round((Date.parse(String(l.data_inicio) + "T12:00:00Z") - Date.parse(hoje + "T12:00:00Z")) / 86400000);
  const partes: Run[][] = [
    [["EMPREGADORA: ", true], [`${E.razao}, inscrita no CNPJ sob o nº ${E.cnpj}, com sede na ${E.sede}, Rio de Janeiro/RJ, integrante do Grupo BVEK.`, false]],
    [["EMPREGADO(A): ", true], [`${String(f.nome || "").toUpperCase()}, CPF nº ${f.cpf ? fmtCPF(f.cpf) : "______________________"}, função ${f.cargo || "______________________________"}, admitido(a) em ${f.data_admissao ? dataBR(String(f.data_admissao)) : "____/____/________"}, contratado(a) na modalidade de trabalho intermitente.`, false]],
  ];
  const servico = [d.servico, d.projeto ? "contrato " + d.projeto : "", d.cliente ? "cliente " + d.cliente : ""].filter(Boolean).join(" – ") || "conforme orientação do escritório";
  const cl: [string, string][] = [
    ["1. Dia(s) de trabalho:", `${listaDias} – total de ${dias.length} dia(s).`],
    ["2. Jornada:", d.horario + "."],
    ["3. Local:", d.local + "."],
    ["4. Serviço:", servico + "."],
  ];
  if (modo === "declaracao") {
    cl.push(["5. Folha de pagamento:", "Os dias acima foram lançados no cronograma da EMPREGADORA e entram na folha de pagamento da competência correspondente, com o pagamento das parcelas previstas no art. 452-A, § 6º, da CLT."]);
    return {
      titulo: "DECLARAÇÃO DE PRESTAÇÃO DE SERVIÇOS", sub: "Contrato de trabalho intermitente – art. 452-A da CLT", partes,
      abertura: "A EMPREGADORA declara, para os devidos fins, que o(a) EMPREGADO(A) acima qualificado(a) prestou serviços, por convocação da EMPREGADORA, nas condições abaixo:",
      clausulas: cl, fecho: "Por ser verdade, as partes assinam a presente declaração.",
    };
  }
  if (d.obs) cl.push(["5. Observações:", d.obs]);
  const n = cl.length + 1;
  cl.push(
    [`${n}. Resposta:`, "Nos termos do art. 452-A, § 2º, da CLT, o(a) EMPREGADO(A) tem o prazo de 1 (um) dia útil, contado do recebimento desta convocação, para responder ao chamado (pelo WhatsApp, e-mail ou diretamente ao escritório), presumindo-se a recusa no silêncio. A recusa da oferta não descaracteriza a subordinação (art. 452-A, § 3º)."],
    [`${n + 1}. Antecedência:`, antecedencia >= 3
      ? `Convocação emitida em ${dataBR(hoje)}, com a antecedência mínima de 3 (três) dias corridos do início dos serviços (art. 452-A, § 1º, da CLT).`
      : `Convocação emitida em ${dataBR(hoje)}, com antecedência inferior a 3 (três) dias corridos do início dos serviços; por isso, a prestação depende da concordância expressa do(a) EMPREGADO(A), que pode recusá-la sem qualquer penalidade.`],
    [`${n + 2}. Remuneração:`, "Pelo período trabalhado, o(a) EMPREGADO(A) receberá a remuneração prevista no contrato de trabalho intermitente, com férias proporcionais acrescidas de um terço, décimo terceiro salário proporcional, repouso semanal remunerado e adicionais legais (art. 452-A, §§ 6º e 11, da CLT), além dos benefícios pelos dias efetivamente trabalhados."],
  );
  return {
    titulo: modo === "alteracao" ? "CONVOCAÇÃO PARA PRESTAÇÃO DE SERVIÇOS – RETIFICADA" : "CONVOCAÇÃO PARA PRESTAÇÃO DE SERVIÇOS",
    sub: "Contrato de trabalho intermitente – art. 452-A da CLT", partes,
    abertura: (modo === "alteracao" ? `Esta convocação substitui a anterior${emitidoAnterior ? `, emitida em ${dataBR(emitidoAnterior)}` : ""}, e vale o que está nela. ` : "") +
      "A EMPREGADORA convoca o(a) EMPREGADO(A) acima qualificado(a) para prestar serviços nas condições abaixo:",
    clausulas: cl, fecho: "Ciente da convocação, o(a) EMPREGADO(A) assina abaixo (o aceite também vale pela resposta no WhatsApp ou e-mail).",
  };
}
// mesmo layout de pdfDocTimbrado (index.html): A4, papel timbrado de fundo, Helvetica, assinaturas lado a lado no fim
async function pdfConvocacao(t: TextoDoc, f: Linha, repPng: Uint8Array | null): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const fn = await doc.embedFont(StandardFonts.Helvetica), fb = await doc.embedFont(StandardFonts.HelveticaBold);
  doc.setTitle(t.titulo + " — " + f.nome); doc.setAuthor("Grupo BVEK");
  const tb = await bytesTimbrado();
  let fundo: Awaited<ReturnType<typeof doc.embedPdf>>[0] | null = null;
  if (tb) { try { [fundo] = await doc.embedPdf(tb, [0]); } catch (_) { fundo = null; } }
  const pri = rgb(12 / 255, 73 / 255, 130 / 255), W = 595.28, H = 841.89, M = 40, larg = W - 2 * M, cor = rgb(.13, .13, .13), TOPO = 104, RODAPE = 128, ESPACO_ASS = 46;
  const lim = (x: string) => String(x).replace(/[“”]/g, '"').replace(/[‘’]/g, "'").replace(/[–—]/g, "-").replace(/[^\x00-\xFF]/g, "");
  // deno-lint-ignore no-explicit-any
  let pg: any, y = 0;
  const novaPg = () => {
    pg = doc.addPage([W, H]);
    if (fundo) pg.drawPage(fundo, { x: 0, y: 0, width: W, height: H });
    else pg.drawText("GRUPO BVEK", { x: M, y: H - 60, size: 14, font: fb, color: pri });
    y = H - TOPO - 6;
  };
  novaPg();
  const par = (runs: Run[], o: { tam?: number; alinhar?: string; antes?: number; depois?: number; c?: ReturnType<typeof rgb>; medir?: boolean } = {}): number => {
    const tam = o.tam ?? 9.5, alinhar = o.alinhar ?? "just", antes = o.antes ?? 0, depois = o.depois ?? 3, c = o.c ?? cor;
    const lh = tam * 1.22, pal: { w: string; f: typeof fn; wd?: number }[] = [];
    runs.forEach(([tx, b]) => lim(tx).split(/(\s+)/).filter((x) => x !== "").forEach((w) => pal.push({ w, f: b ? fb : fn })));
    const linhas: { w: string; f: typeof fn; wd: number }[][] = []; let at: { w: string; f: typeof fn; wd: number }[] = [], la = 0;
    pal.forEach((p) => {
      const esp = /^\s+$/.test(p.w), wd = p.f.widthOfTextAtSize(esp ? " " : p.w, tam);
      if (!esp && la + wd > larg && at.length) { while (at.length && /^\s+$/.test(at[at.length - 1].w)) at.pop(); linhas.push(at); at = []; la = 0; }
      if (esp && !at.length) return;
      at.push({ ...p, wd }); la += wd;
    });
    if (at.length) linhas.push(at);
    if (o.medir) return antes + linhas.length * lh + depois;
    y -= antes;
    linhas.forEach((ln, i) => {
      if (y - lh < RODAPE) novaPg();
      const esps = ln.filter((p) => /^\s+$/.test(p.w)).length, total = ln.reduce((s, p) => s + p.wd, 0);
      let x = M, extra = 0;
      if (alinhar === "centro") x = M + (larg - total) / 2;
      else if (alinhar === "just" && i < linhas.length - 1 && esps) extra = (larg - total) / esps;
      ln.forEach((p) => { if (/^\s+$/.test(p.w)) { x += p.wd + extra; return; } pg.drawText(p.w, { x, y: y - tam, size: tam, font: p.f, color: c }); x += p.wd; });
      y -= lh;
    });
    y -= depois;
    return 0;
  };
  par([[t.titulo, true]], { tam: 12, alinhar: "centro", depois: 1, c: pri });
  par([[t.sub, true]], { tam: 10, alinhar: "centro", depois: 12 });
  t.partes.forEach((r, i, a) => par(r, { depois: i === a.length - 1 ? 8 : 3 }));
  par([[t.abertura, false]], { depois: 8 });
  t.clausulas.forEach(([a, b]) => par([[a + " ", true], [b, false]], { depois: 4 }));
  const hoje = hojeBrasilia();
  const fecho: Run[] = [[t.fecho, false]], local: Run[] = [[`Rio de Janeiro, ${Number(hoje.slice(8, 10))} de ${MESES[Number(hoje.slice(5, 7)) - 1]} de ${hoje.slice(0, 4)}.`, false]];
  // v69: fecho, local/data e assinaturas sempre na mesma página
  if (y - par(fecho, { depois: 10, medir: true }) - par(local, { alinhar: "centro", depois: 6, medir: true }) - ESPACO_ASS - 40 < RODAPE) novaPg();
  par(fecho, { antes: 4, depois: 10 }); par(local, { alinhar: "centro", depois: 6 });
  y -= ESPACO_ASS;
  const colW = (larg - 30) / 2, E = EMPREGADORA;
  if (repPng) { try { const img = await doc.embedPng(repPng); const h = 40, w = Math.min(colW * .8, img.width * h / img.height); pg.drawImage(img, { x: M + colW + 30 + (colW - w) / 2, y: y + 1, width: w, height: h }); } catch (_) { /* sem a imagem */ } }
  ([[M, ["EMPREGADO(A)", "Nome: " + String(f.nome || "").toUpperCase(), "CPF: " + (f.cpf ? fmtCPF(f.cpf) : "")]], [M + colW + 30, [E.razao, "Representante: " + E.representante, "Cargo: " + E.cargo]]] as [number, string[]][]).forEach(([x0, ls]) => {
    pg.drawLine({ start: { x: x0, y }, end: { x: x0 + colW, y }, thickness: .7, color: cor });
    ls.forEach((tx0, i) => {
      const fo = i ? fn : fb, tam = i ? 8.6 : 8.8; let tx = lim(tx0);
      while (fo.widthOfTextAtSize(tx, tam) > colW && tx.length > 4) tx = tx.slice(0, -1);
      pg.drawText(tx, { x: x0 + (colW - fo.widthOfTextAtSize(tx, tam)) / 2, y: y - 12 - i * 12, size: tam, font: fo, color: cor });
    });
  });
  return await doc.save();
}
const nomeArqConv = (modo: string, f: Linha, l: Linha) =>
  `BVK-RH-DOC-${modo === "declaracao" ? "DECLARACAO_SERVICO" : "CONVOCACAO"}_${semAcento(f.nome).toUpperCase().replace(/[^A-Z0-9 ]+/g, " ").trim().replace(/\s+/g, "_")}_${String(l.data_inicio).replace(/-/g, "")}.pdf`;
const base64 = (b: Uint8Array) => { let s = ""; for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000)); return btoa(s); };
type PdfConv = { documento_id: string; caminho: string; nome: string; bytes?: Uint8Array; url?: string };
// gera o PDF, guarda em Documentos (bucket "documentos") e devolve o link para o WhatsApp (30 dias)
// deno-lint-ignore no-explicit-any
async function gerarDocConvocacao(adm: any, modo: "convocacao" | "alteracao" | "declaracao", l: Linha, f: Linha, d: Det, anterior: Linha | null, quem: string, ctx: Linha): Promise<PdfConv> {
  if (!ctx.tipoId) {
    const { data: t, error } = await adm.from("tipos_documento").select("id").eq("nome", TIPO_DOC_CONV).maybeSingle();
    if (error || !t) throw new Error("Falta rodar a migração v85 no Supabase (tipo de documento \"" + TIPO_DOC_CONV + "\").");
    ctx.tipoId = t.id;
  }
  if (ctx.repPng === undefined) ctx.repPng = await bytesAssinaturaRep(adm);
  const t = textoConvocacao(modo, l, f, d, anterior?.criado_em ? String(anterior.criado_em).slice(0, 10) : null);
  const bytes = await pdfConvocacao(t, f, ctx.repPng);
  const nome = nomeArqConv(modo, f, l);
  const desc = `${modo === "declaracao" ? "Declaração de prestação de serviços" : modo === "alteracao" ? "Convocação (retificada)" : "Convocação"} — ${d.data}${d.projeto ? " — " + d.projeto : d.servico ? " — " + d.servico : ""}`;
  const ins = await adm.from("documentos").insert({
    tipo_id: ctx.tipoId, funcionario_id: f.id, empresa_id: f.empresa_id || null, orgao: "RH", descricao: desc.slice(0, 300),
    data_emissao: hojeBrasilia(), data_validade: null, dias_aviso: 0, situacao: "vigente", cronograma_id: l.id, criado_por: quem,
  }).select("id").single();
  if (ins.error) throw new Error(/cronograma_id/.test(ins.error.message) ? "Falta rodar a migração v85 no Supabase." : ins.error.message);
  const sigla = (ctx.siglas as Map<string, string>).get(String(f.empresa_id || "")) || "GERAL";
  const caminho = `${sigla}/${ins.data.id}/${Date.now()}_${nome}`;
  const up = await adm.storage.from("documentos").upload(caminho, bytes, { contentType: "application/pdf", upsert: false });
  if (up.error) { await adm.from("documentos").delete().eq("id", ins.data.id); throw new Error("PDF não foi guardado: " + up.error.message); }
  await adm.from("documentos").update({ arquivo: caminho, arquivo_nome: nome }).eq("id", ins.data.id);
  if (anterior?.id) await adm.from("documentos").update({ situacao: "substituido", substituido_por: ins.data.id, atualizado_em: new Date().toISOString() }).eq("id", anterior.id);
  const { data: su } = await adm.storage.from("documentos").createSignedUrl(caminho, 30 * 24 * 3600);
  return { documento_id: ins.data.id, caminho, nome, bytes, url: su?.signedUrl || "" };
}
// reenvio sem mudança: usa o mesmo PDF já guardado
// deno-lint-ignore no-explicit-any
async function pdfExistente(adm: any, doc: Linha): Promise<PdfConv | null> {
  if (!doc?.arquivo) return null;
  const { data } = await adm.storage.from("documentos").download(doc.arquivo);
  const { data: su } = await adm.storage.from("documentos").createSignedUrl(doc.arquivo, 30 * 24 * 3600);
  return { documento_id: doc.id, caminho: doc.arquivo, nome: doc.arquivo_nome || "convocacao.pdf", bytes: data ? new Uint8Array(await data.arrayBuffer()) : undefined, url: su?.signedUrl || "" };
}

// ------------------------------------------------------------------ envios
// v85: pdf = convocação do intermitente. Com o modelo "com documento" (meta_modelo_doc, cabeçalho DOCUMENTO
// e as mesmas 7 variáveis) o PDF vai anexado na própria mensagem; com o modelo comum, o link do PDF vai na
// variável {{7}}; sem modelo (texto livre, janela de 24 horas), o PDF vai numa segunda mensagem.
async function enviarWhats(cfg: Linha, fone: string, tipo: Tipo, nome: string, d: Det, pdf?: PdfConv | null): Promise<string | null> {
  const modeloDoc = String(cfg.meta_modelo_doc || "").trim();
  const comDoc = !!(pdf?.url && modeloDoc);
  const modelo = comDoc ? modeloDoc : String(cfg.meta_modelo || "").trim();
  const obs = tipo === "cancelamento" ? "Não é preciso comparecer." : d.obs;
  const sete = pdf?.url && !comDoc && modelo ? [`Convocação em PDF: ${pdf.url}`, obs].filter(Boolean).join(" | ") : obs;
  const url = `${GRAPH}/${encodeURIComponent(String(cfg.meta_phone_id).trim())}/messages`;
  const headers = { Authorization: "Bearer " + String(cfg.meta_token).trim(), "Content-Type": "application/json" };
  const corpo = modelo
    ? {
      messaging_product: "whatsapp", to: fone, type: "template",
      template: {
        name: modelo, language: { code: cfg.meta_idioma || "pt_BR" },
        components: [
          ...(comDoc ? [{ type: "header", parameters: [{ type: "document", document: { link: pdf!.url, filename: pdf!.nome } }] }] : []),
          {
            type: "body",
            parameters: [CABECALHO[tipo], nome, d.data, d.horario, d.local,
              [d.projeto, d.cliente && !d.projeto ? d.cliente : "", d.servico].filter(Boolean).join(" · "),
              sete].map(param),
          },
        ],
      },
    }
    : { messaging_product: "whatsapp", to: fone, type: "text", text: { body: textoWhats(tipo, nome, d) } };
  const r = await fetch(url, { method: "POST", headers, body: JSON.stringify(corpo) });
  if (!r.ok) return erroMeta(await r.text());
  if (pdf?.url && !modelo) {
    const r2 = await fetch(url, {
      method: "POST", headers,
      body: JSON.stringify({ messaging_product: "whatsapp", to: fone, type: "document", document: { link: pdf.url, filename: pdf.nome, caption: "Convocação em PDF" } }),
    });
    if (!r2.ok) return "mensagem enviada, mas o PDF não: " + erroMeta(await r2.text());
  }
  return null;
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
async function enviarEmail(token: string, remetente: string, para: string, tipo: Tipo, nome: string, d: Det, pdf?: PdfConv | null): Promise<string | null> {
  const assunto = `${CABECALHO[tipo]} — ${d.data}${d.projeto ? " — " + d.projeto : d.local ? " — " + d.local : ""}`.slice(0, 250);
  const rs = await fetch(`https://graph.microsoft.com/v1.0/users/${encodeURIComponent(remetente)}/sendMail`, {
    method: "POST",
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: JSON.stringify({
      message: {
        subject: assunto, body: { contentType: "HTML", content: emailHtml(tipo, nome, d, !!pdf?.bytes) }, toRecipients: [{ emailAddress: { address: para } }],
        ...(pdf?.bytes ? { attachments: [{ "@odata.type": "#microsoft.graph.fileAttachment", name: pdf.nome, contentType: "application/pdf", contentBytes: base64(pdf.bytes) }] } : {}),
      },
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
    const terminou = l.data_fim < hojeBrasilia();

    const { data: avisos, error: eAv } = await adm.from("cronograma_avisos").select("*")
      .eq("cronograma_id", l.id).eq("ok", true).order("enviado_em", { ascending: false });
    if (eAv) throw new Error(/cronograma_avisos/.test(eAv.message) ? "Falta rodar a migração v47 no Supabase." : eAv.message);
    // último aviso por pessoa (WhatsApp/e-mail) e, à parte, o último PDF da convocação (v85, canal "documento")
    const ultimo = new Map<string, Linha>(), ultimoDoc = new Map<string, Linha>();
    for (const a of avisos || []) {
      if (!a.funcionario_id) continue;
      if (a.canal === "documento") { if (!ultimoDoc.has(a.funcionario_id)) ultimoDoc.set(a.funcionario_id, a); }
      else if (!ultimo.has(a.funcionario_id)) ultimo.set(a.funcionario_id, a);
    }

    const equipeIds: string[] = l.situacao === "ativo" ? (l.funcionarios || []) : [];
    const ids = [...new Set([...(l.funcionarios || []), ...ultimo.keys(), ...ultimoDoc.keys()])];
    const idsQ = ids.length ? ids : ["00000000-0000-0000-0000-000000000000"];
    const [rf, rp, rrh, remp, cfg] = await Promise.all([
      adm.from("funcionarios").select("id,nome,email,celular,ativo,cpf,cargo,data_admissao,empresa_id").in("id", idsQ),
      l.projeto_id ? adm.from("projetos").select("id,codigo,nome,cliente_id,local").eq("id", l.projeto_id).maybeSingle() : Promise.resolve({ data: null }),
      adm.from("funcionario_rh").select("funcionario_id,tipo_contrato").in("funcionario_id", idsQ),
      adm.from("empresas").select("id,sigla"),
      lerConfig(),
    ]);
    const funcs = (rf.data || []) as Linha[];
    const proj = (rp.data || null) as Linha | null;
    const inter = new Set(((rrh.data || []) as Linha[]).filter((r) => r.tipo_contrato === "intermitente").map((r) => String(r.funcionario_id)));
    const ctx: Linha = { siglas: new Map(((remp.data || []) as Linha[]).map((e) => [String(e.id), String(e.sigla || "GERAL")])) };
    const cliId = l.cliente_id || proj?.cliente_id;
    const cli = cliId ? ((await adm.from("clientes").select("id,codigo,nome").eq("id", cliId).maybeSingle()).data as Linha | null) : null;

    const equipeNomes = equipeIds.map((id) => funcs.find((f) => f.id === id)).filter(Boolean).map((f) => nomeCurto(f!.nome));
    const d = detalhes(l, proj, cli, equipeNomes);
    // o que a pessoa precisa saber: se mudar, ela recebe "alteração"
    const assinatura = JSON.stringify([l.data_inicio, l.data_fim, !!l.sabado, !!l.domingo, hora(l.hora_inicio), hora(l.hora_fim), d.local, d.projeto, d.cliente, d.servico, d.obs]);
    const docsDe = async (ids: string[]) => {
      const ds = ids.filter(Boolean);
      if (!ds.length) return new Map<string, Linha>();
      const { data } = await adm.from("documentos").select("id,arquivo,arquivo_nome,situacao,criado_em").in("id", ds);
      return new Map(((data || []) as Linha[]).map((x) => [String(x.id), x]));
    };
    const docsAnt = await docsDe([...ultimoDoc.values()].map((a) => a.documento_id));
    const registros: Linha[] = [];

    // v85: alocação que já terminou → ninguém é avisado; intermitentes ganham a DECLARAÇÃO de prestação de serviços
    if (terminou) {
      const feitos: string[] = [], erros: string[] = [];
      for (const id of equipeIds) {
        const f = funcs.find((x) => x.id === id);
        if (!f || !inter.has(id)) continue;
        const u = ultimoDoc.get(id);
        if (u && u.assinatura === assinatura && u.tipo !== "cancelamento" && !p.reenviar) continue;
        try {
          const pdf = await gerarDocConvocacao(adm, "declaracao", l, f, d, u?.documento_id ? docsAnt.get(u.documento_id) || null : null, quem, ctx);
          registros.push({ cronograma_id: l.id, funcionario_id: f.id, tipo: "convocacao", canal: "documento", destino: pdf.caminho, ok: true, erro: null, assinatura, enviado_por: quem, documento_id: pdf.documento_id });
          feitos.push(f.nome);
        } catch (e) { erros.push(`${f.nome}: ${String((e as Error).message || e)}`); }
      }
      if (registros.length) { const { error } = await adm.from("cronograma_avisos").insert(registros); if (error) console.warn("cronograma_avisos", error.message); }
      return json({
        ok: true, resultado: [], documentos: feitos.length, erros_pdf: erros,
        pulado: "A alocação já terminou: ninguém foi avisado." + (feitos.length ? ` Declaração de prestação de serviços guardada em Documentos para: ${feitos.join(", ")}.` : ""),
      });
    }

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
    for (const { f, tipo } of plano) {
      const nome = primeiroNome(f.nome);
      const fone = foneMeta(f.celular), email = String(f.email || "").trim();
      const r: Linha = { nome: f.nome, tipo, whatsapp: "", email: "" };
      // v85: PDF da convocação do intermitente (novo, reaproveitado no reenvio sem mudança, ou arquivado no cancelamento)
      let pdf: PdfConv | null = null;
      if (inter.has(f.id)) {
        const u = ultimoDoc.get(f.id), docAnt = u?.documento_id ? docsAnt.get(u.documento_id) || null : null;
        try {
          if (tipo === "cancelamento") {
            if (docAnt && u!.tipo !== "cancelamento") {
              await adm.from("documentos").update({ situacao: "arquivado", observacoes: `Convocação cancelada em ${dataBR(hojeBrasilia())} por ${quem}.`, atualizado_em: new Date().toISOString() }).eq("id", docAnt.id);
              registros.push({ cronograma_id: l.id, funcionario_id: f.id, tipo, canal: "documento", destino: docAnt.arquivo, ok: true, erro: null, assinatura, enviado_por: quem, documento_id: docAnt.id });
              r.pdf = "convocação arquivada";
            }
          } else {
            const mesmo = u && u.tipo !== "cancelamento" && u.assinatura === assinatura && docAnt && docAnt.situacao === "vigente";
            pdf = mesmo ? await pdfExistente(adm, docAnt!) : await gerarDocConvocacao(adm, u && u.tipo !== "cancelamento" && docAnt ? "alteracao" : "convocacao", l, f, d, u && u.tipo !== "cancelamento" ? docAnt : null, quem, ctx);
            if (pdf && !mesmo) registros.push({ cronograma_id: l.id, funcionario_id: f.id, tipo, canal: "documento", destino: pdf.caminho, ok: true, erro: null, assinatura, enviado_por: quem, documento_id: pdf.documento_id });
            r.pdf = pdf ? "ok" : "";
          }
        } catch (e) { r.pdf = "erro: " + String((e as Error).message || e).slice(0, 300); pdf = null; }
      }
      const docId = pdf?.documento_id || null;
      if (!fone) r.whatsapp = "sem celular na ficha";
      else if (!temWhats) r.whatsapp = cfg.ativo === false ? "WhatsApp da convocação desligado" : "WhatsApp (Meta) não configurado";
      else {
        let erro: string | null;
        try { erro = await enviarWhats(cfg, fone, tipo, nome, d, pdf); } catch (e) { erro = String((e as Error).message || e).slice(0, 300); }
        r.whatsapp = erro ? "erro: " + erro : "ok";
        registros.push({ cronograma_id: l.id, funcionario_id: f.id, tipo, canal: "whatsapp", destino: fone, ok: !erro, erro, assinatura, enviado_por: quem, ...(docId ? { documento_id: docId } : {}) });
      }
      if (!EMAIL_OK.test(email)) r.email = "sem e-mail na ficha";
      else if (!tokenMs) r.email = erroMs || "e-mail não configurado";
      else {
        let erro: string | null;
        try { erro = await enviarEmail(tokenMs, remetente!, email, tipo, nome, d, pdf); } catch (e) { erro = String((e as Error).message || e).slice(0, 300); }
        r.email = erro ? "erro: " + erro : "ok";
        registros.push({ cronograma_id: l.id, funcionario_id: f.id, tipo, canal: "email", destino: email, ok: !erro, erro, assinatura, enviado_por: quem, ...(docId ? { documento_id: docId } : {}) });
      }
      resultado.push(r);
    }
    if (registros.length) {
      let { error } = await adm.from("cronograma_avisos").insert(registros);
      // sem a migração v85: grava ao menos os avisos de WhatsApp/e-mail (sem o documento)
      if (error && /documento_id|canal_chk|check constraint/i.test(error.message)) {
        ({ error } = await adm.from("cronograma_avisos").insert(registros.filter((x) => x.canal !== "documento").map(({ documento_id: _, ...x }) => x)));
      }
      if (error) console.warn("cronograma_avisos", error.message);
    }
    const enviados = resultado.filter((r) => r.whatsapp === "ok" || r.email === "ok").length;
    return json({ ok: true, enviados, total: resultado.length, resultado, sem_modelo: temWhats && !String(cfg.meta_modelo || "").trim() });
  } catch (e) {
    return json({ erro: String((e as Error)?.message || e) }, 500);
  }
});
