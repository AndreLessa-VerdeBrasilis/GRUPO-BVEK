// =====================================================================
// CRM Grupo BVEK — função "outlook-agenda" (Supabase Edge Function) · v42
// Liga o CRONOGRAMA do CRM ao calendário do Outlook (ida e volta), pelo
// Microsoft Graph, com os MESMOS segredos do e-mail:
//   MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET
// v42: cada evento vai pela agenda de QUEM está usando o CRM (o e-mail do
//      login), e não mais por uma caixa fixa. A caixa fica gravada na alocação
//      (outlook_caixa) para alterar/apagar o evento no lugar certo depois.
//      Eventos antigos (v41, sem caixa gravada) estavam na caixa OUTLOOK_AGENDA
//      ou MS_REMETENTE: ao serem alterados, passam para a agenda de quem alterou.
//
// O aplicativo do Azure precisa da permissão de APLICATIVO "Calendars.ReadWrite"
// com consentimento do administrador (veja LEIA-ME.md).
//
// Pedidos (POST com JSON):
//   { acao: "status" }                 → a integração está ligada?
//   { acao: "enviar", id }             → manda uma alocação do CRM para o Outlook
//                                        (cria, atualiza ou apaga o evento)
//   { acao: "sincronizar", inicio, fim } → ida e volta no período (datas AAAA-MM-DD):
//        • eventos novos no Outlook com funcionário convidado (e-mail do cadastro)
//          ou com o nome do funcionário no assunto viram alocações no CRM;
//        • evento alterado/apagado no Outlook altera/cancela a alocação;
//        • alocação nova/alterada/cancelada no CRM vai para o Outlook.
//
//   v45 — agenda do escritório (caixa agenda@bvek.com.br, ou o segredo OUTLOOK_ESCRITORIO):
//   { acao: "escritorio_sincronizar", inicio, fim } → traz para o CRM os eventos da agenda
//        do escritório (convites recebidos e eventos criados nela) e manda para o Outlook
//        os eventos criados/alterados/cancelados no CRM;
//   { acao: "escritorio_enviar", id }  → manda um evento do escritório criado no CRM
//        para a agenda (cria, atualiza ou cancela — os convidados recebem o convite).
//   Eventos do escritório ficam na tabela agenda_escritorio e NÃO entram na folha.
//
// v45: todos os perfis do escritório (Administrador, Comercial, Administrativo e
// Contabilidade). O perfil Funcionário (login por CPF) não usa.
// =====================================================================
import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const FUSO = "E. South America Standard Time"; // horário de Brasília
const PROP = "String {00020329-0000-0000-C000-000000000046} Name BvekCronogramaId";
const GRAPH = "https://graph.microsoft.com/v1.0";

type Linha = Record<string, any>;

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
// caixa usada na v41 (só para achar eventos antigos, sem caixa gravada)
function caixaLegada(): string | null {
  return Deno.env.get("OUTLOOK_AGENDA") || Deno.env.get("MS_REMETENTE") || null;
}
// caixa onde está o evento de uma alocação
function caixaDaLinha(l: Linha): string | null {
  return l.outlook_caixa || (l.outlook_id ? caixaLegada() : null);
}
const mesmaCaixa = (a: string | null, b: string | null) => !!a && !!b && a.toLowerCase().trim() === b.toLowerCase().trim();
async function graph(metodo: string, caminho: string, corpo?: unknown): Promise<{ ok: boolean; status: number; b: any }> {
  const tok = await tokenM365();
  const r = await fetch(caminho.startsWith("http") ? caminho : GRAPH + caminho, {
    method: metodo,
    headers: {
      Authorization: "Bearer " + tok, "Content-Type": "application/json",
      Prefer: `outlook.timezone="${FUSO}"`,
    },
    body: corpo === undefined ? undefined : JSON.stringify(corpo),
  });
  const txt = await r.text();
  let b: any = null;
  try { b = txt ? JSON.parse(txt) : null; } catch { b = txt; }
  if (r.status === 401 || r.status === 403) {
    throw new Error("O aplicativo do Microsoft 365 ainda não tem permissão neste calendário (Calendars.ReadWrite). Peça ao administrador do Microsoft 365 para liberar. " + (b?.error?.message || ""));
  }
  if (r.status === 404 && /MailboxNotEnabledForRESTAPI|ResourceNotFound|ErrorInvalidUser|MailboxNotFound/i.test(String(b?.error?.code || "")) && /\/users\/[^/]+\/(calendar|calendar\/calendarView|events)(\?|$)/.test(caminho)) {
    throw new Error("Não achei a agenda do Outlook do seu login no Microsoft 365. O e-mail do seu login no CRM precisa ser o mesmo da sua caixa do Microsoft 365.");
  }
  return { ok: r.ok, status: r.status, b };
}

// ---------- datas ----------
const somaDias = (iso: string, n: number) => {
  const d = new Date(iso + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10);
};
const mesesEntre = (a: string, b: string) => {
  const r: string[] = []; let m = a.slice(0, 7) + "-01";
  while (m <= b) { r.push(m); const d = new Date(m + "T12:00:00Z"); d.setUTCMonth(d.getUTCMonth() + 1); m = d.toISOString().slice(0, 10); }
  return r;
};
function datasDoEvento(ev: any): { ini: string; fim: string } {
  const ini = String(ev.start?.dateTime || "").slice(0, 10);
  let fim = String(ev.end?.dateTime || "").slice(0, 10);
  const horaFim = String(ev.end?.dateTime || "").slice(11, 19);
  if (fim > ini && (ev.isAllDay || horaFim === "00:00:00")) fim = somaDias(fim, -1); // fim do Outlook é "exclusivo"
  if (!fim || fim < ini) fim = ini;
  return { ini, fim };
}
const semAcento = (s: string) => String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "");
const norm = (s: string) => " " + semAcento(s).toLowerCase().replace(/[^a-z0-9]+/g, " ").trim() + " ";

// ---------- montagem do evento ----------
function assunto(l: Linha, proj: Linha | null, cli: Linha | null, nomes: string[]): string {
  const cod = proj?.codigo || cli?.codigo || "";
  const tit = l.titulo || proj?.nome || cli?.nome || "Alocação";
  const curtos = nomes.map((n) => { const p = n.trim().split(/\s+/); return p.length > 1 ? p[0] + " " + p[p.length - 1] : p[0]; });
  return `[Cronograma] ${cod ? cod + " " : ""}${tit}${curtos.length ? " — " + curtos.join(", ") : ""}`.slice(0, 250);
}
const escH = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
function corpoEvento(l: Linha, proj: Linha | null, cli: Linha | null, nomes: string[]): string {
  const dias = ["Segunda a sexta", l.sabado ? "sábado" : "", l.domingo ? "domingo" : ""].filter(Boolean).join(", ");
  return `<p><strong>Cronograma do Grupo BVEK</strong></p>
<p>${proj ? `Projeto: <strong>${escH(proj.codigo)}</strong> ${escH(proj.nome)}<br>` : ""}${cli ? `Cliente: ${escH(cli.codigo || "")} ${escH(cli.nome)}<br>` : ""}${l.local ? `Local: ${escH(l.local)}<br>` : ""}${l.hora_inicio ? `Horário: ${escH(String(l.hora_inicio).slice(0, 5))}${l.hora_fim ? " às " + escH(String(l.hora_fim).slice(0, 5)) : ""}<br>` : ""}Dias de trabalho: ${escH(dias)}<br>Equipe: ${escH(nomes.join(", ") || "—")}</p>
${l.observacoes ? `<p>${escH(l.observacoes)}</p>` : ""}
<p style="color:#888;font-size:11px">Gerado pelo CRM Grupo BVEK. Pode mudar datas e convidados aqui: o CRM traz a mudança na próxima sincronização.</p>`;
}

async function carregarApoio(adm: SupabaseClient) {
  const [f, p, c] = await Promise.all([
    adm.from("funcionarios").select("id,nome,email,ativo"),
    adm.from("projetos").select("id,codigo,nome,cliente_id,local"),
    adm.from("clientes").select("id,codigo,nome"),
  ]);
  return { funcs: (f.data || []) as Linha[], projs: (p.data || []) as Linha[], clis: (c.data || []) as Linha[] };
}

// envia uma alocação para o Outlook (cria / atualiza / apaga)
async function apagarEvento(caixaEv: string | null, idEv: string) {
  if (!caixaEv) return;
  const r = await graph("DELETE", `/users/${encodeURIComponent(caixaEv)}/events/${encodeURIComponent(idEv)}`);
  if (!r.ok && r.status !== 404) throw new Error("Outlook não apagou o evento: " + (r.b?.error?.message || r.status));
}
async function enviarLinha(adm: SupabaseClient, l: Linha, apoio: Awaited<ReturnType<typeof carregarApoio>>, minhaCaixa: string): Promise<string> {
  const caixaEv = caixaDaLinha(l);
  if (l.situacao === "cancelado") {
    if (l.outlook_id) await apagarEvento(caixaEv, l.outlook_id);
    await adm.from("cronograma").update({ outlook_id: null, outlook_icaluid: null, outlook_sync_em: new Date().toISOString(), outlook_erro: null }).eq("id", l.id);
    return "apagado";
  }
  // evento antigo (v41) na caixa fixa: passa para a agenda de quem está alterando
  const legado = !!l.outlook_id && !l.outlook_caixa && !mesmaCaixa(caixaEv, minhaCaixa);
  const proj = apoio.projs.find((x) => x.id === l.projeto_id) || null;
  const cli = apoio.clis.find((x) => x.id === (l.cliente_id || proj?.cliente_id)) || null;
  const fs = (l.funcionarios || []).map((id: string) => apoio.funcs.find((x) => x.id === id)).filter(Boolean) as Linha[];
  const nomes = fs.map((x) => x.nome);
  const ev: Record<string, unknown> = {
    subject: assunto(l, proj, cli, nomes),
    body: { contentType: "HTML", content: corpoEvento(l, proj, cli, nomes) },
    start: { dateTime: l.data_inicio + "T00:00:00", timeZone: FUSO },
    end: { dateTime: somaDias(l.data_fim, 1) + "T00:00:00", timeZone: FUSO },
    isAllDay: true, showAs: "free", isReminderOn: false,
    location: { displayName: l.local || proj?.local || "" },
    attendees: fs.filter((x) => x.email).map((x) => ({ emailAddress: { address: String(x.email).trim(), name: x.nome }, type: "required" })),
    categories: ["Cronograma"],
    singleValueExtendedProperties: [{ id: PROP, value: l.id }],
  };
  let r = l.outlook_id && !legado ? await graph("PATCH", `/users/${encodeURIComponent(caixaEv || minhaCaixa)}/events/${encodeURIComponent(l.outlook_id)}`, ev) : null;
  let caixaFinal = l.outlook_id && !legado ? (caixaEv || minhaCaixa) : minhaCaixa;
  if (r && r.status === 404) { r = null; caixaFinal = minhaCaixa; } // apagado no Outlook: cria de novo na agenda de quem enviou
  if (!r) r = await graph("POST", `/users/${encodeURIComponent(caixaFinal)}/events`, ev);
  if (!r.ok) {
    const msg = r.b?.error?.message || String(r.status);
    await adm.from("cronograma").update({ outlook_erro: msg.slice(0, 300) }).eq("id", l.id);
    throw new Error("Outlook recusou o evento: " + msg);
  }
  if (legado && l.outlook_id) {
    try { await apagarEvento(caixaEv, l.outlook_id); } catch (_) { /* o evento antigo fica; o CRM já aponta para o novo */ }
  }
  await adm.from("cronograma").update({
    outlook_id: r.b.id, outlook_caixa: caixaFinal, outlook_icaluid: r.b.iCalUId || null,
    outlook_alterado_em: r.b.lastModifiedDateTime || new Date().toISOString(),
    outlook_sync_em: new Date().toISOString(), outlook_erro: null,
  }).eq("id", l.id);
  return l.outlook_id && !legado ? "atualizado" : "criado";
}

// lê do evento o que importa para o CRM
function lerEvento(ev: any, apoio: Awaited<ReturnType<typeof carregarApoio>>) {
  const { ini, fim } = datasDoEvento(ev);
  const emails = new Set((ev.attendees || []).map((a: any) => String(a.emailAddress?.address || "").toLowerCase().trim()));
  const texto = norm((ev.subject || "") + " " + (ev.bodyPreview || ""));
  const funcs = apoio.funcs.filter((f) => {
    if (f.ativo === false) return false;
    if (f.email && emails.has(String(f.email).toLowerCase().trim())) return true;
    const p = norm(f.nome).trim().split(" ");
    if (p.length < 2) return false;
    return texto.includes(" " + p.join(" ") + " ") || texto.includes(" " + p[0] + " " + p[p.length - 1] + " ");
  }).map((f) => f.id as string);
  const mp = String((ev.subject || "") + " " + (ev.bodyPreview || "")).match(/\bC\d{3}-\d{4}\b/i);
  const proj = mp ? apoio.projs.find((x) => String(x.codigo).toUpperCase() === mp[0].toUpperCase()) || null : null;
  const mc = String(ev.subject || "").match(/\bC\d{3}\b/i);
  const cli = proj ? null : mc ? apoio.clis.find((x) => String(x.codigo || "").toUpperCase() === mc[0].toUpperCase()) || null : null;
  const fimDeSemana = (d: string) => [0, 6].includes(new Date(d + "T12:00:00Z").getUTCDay());
  // evento só no fim de semana: conta o sábado/domingo; senão, só dias úteis
  let sab = false, dom = false;
  if (fimDeSemana(ini) && fimDeSemana(fim) && somaDias(ini, 1) >= fim) {
    for (let d = ini; d <= fim; d = somaDias(d, 1)) { const w = new Date(d + "T12:00:00Z").getUTCDay(); if (w === 6) sab = true; if (w === 0) dom = true; }
  }
  return {
    ini, fim, funcs, projeto_id: proj?.id || null, cliente_id: cli?.id || null,
    local: ev.location?.displayName || null, sab, dom,
    titulo: String(ev.subject || "").replace(/^\[Cronograma\]\s*/i, "").slice(0, 200) || null,
  };
}

async function sincronizar(adm: SupabaseClient, inicio: string, fim: string, minhaCaixa: string) {
  const apoio = await carregarApoio(adm);
  const cx = encodeURIComponent(minhaCaixa);
  const res = { importados: 0, atualizados_no_crm: 0, cancelados_no_crm: 0, enviados: 0, erros: [] as string[], meses: new Set<string>() };
  const marcaMeses = (a: string, b: string) => mesesEntre(a, b).forEach((m) => res.meses.add(m));

  // 1. eventos do Outlook no período
  const eventos: any[] = [];
  let url: string | null = `/users/${cx}/calendar/calendarView?startDateTime=${inicio}T00:00:00-03:00&endDateTime=${somaDias(fim, 1)}T00:00:00-03:00` +
    `&$top=200&$select=id,iCalUId,isOrganizer,subject,start,end,isAllDay,attendees,organizer,lastModifiedDateTime,isCancelled,location,bodyPreview,type` +
    `&$expand=${encodeURIComponent(`singleValueExtendedProperties($filter=id eq '${PROP}')`)}`;
  while (url) {
    const r = await graph("GET", url);
    if (!r.ok) throw new Error("Não consegui ler o calendário do Outlook: " + (r.b?.error?.message || r.status));
    eventos.push(...(r.b.value || []));
    url = r.b["@odata.nextLink"] || null;
    if (eventos.length > 3000) break;
  }

  // 2. alocações do CRM no período (+ as ligadas a eventos encontrados)
  const { data: linhasPer } = await adm.from("cronograma").select("*").lte("data_inicio", fim).gte("data_fim", inicio);
  const idsEv = eventos.map((e) => e.id);
  const { data: linhasEv } = idsEv.length ? await adm.from("cronograma").select("*").in("outlook_id", idsEv.slice(0, 500)) : { data: [] };
  const linhas = new Map<string, Linha>();
  [...(linhasPer || []), ...(linhasEv || [])].forEach((l: Linha) => linhas.set(l.id, l));
  const porOutlook = new Map<string, Linha>();
  linhas.forEach((l) => { if (l.outlook_id) porOutlook.set(l.outlook_id, l); });
  // eventos que já são de uma alocação (mesmo evento visto na agenda de outra pessoa)
  const uids = [...new Set(eventos.map((e) => e.iCalUId).filter(Boolean))] as string[];
  const { data: linhasUid } = uids.length ? await adm.from("cronograma").select("id,outlook_icaluid").in("outlook_icaluid", uids.slice(0, 500)) : { data: [] };
  const uidConhecido = new Set((linhasUid || []).map((x: Linha) => x.outlook_icaluid));
  const vistos = new Set<string>();

  for (const ev of eventos) {
    try {
      const idCrm = (ev.singleValueExtendedProperties || [])[0]?.value || null;
      let l = porOutlook.get(ev.id) || (idCrm ? linhas.get(idCrm) : undefined);
      if (!l && idCrm) { const { data } = await adm.from("cronograma").select("*").eq("id", idCrm).maybeSingle(); l = data || undefined; }
      // evento de uma alocação, mas guardado na agenda de outra pessoa: quem cuida é a dona do evento
      if (l && l.outlook_id && l.outlook_id !== ev.id && !mesmaCaixa(caixaDaLinha(l), minhaCaixa)) { vistos.add(l.id); continue; }
      if (ev.isCancelled) continue; // cancelado = tratado como apagado (abaixo)
      const e = lerEvento(ev, apoio);
      if (l) {
        vistos.add(l.id);
        if (!l.outlook_id || l.outlook_id !== ev.id || !l.outlook_caixa) {
          await adm.from("cronograma").update({ outlook_id: ev.id, outlook_caixa: minhaCaixa, outlook_icaluid: ev.iCalUId || null }).eq("id", l.id);
          l = { ...l, outlook_id: ev.id, outlook_caixa: minhaCaixa };
        }
        if (l.situacao === "cancelado") continue; // será apagado no passo 4
        // v51: evento que veio do Outlook e depois recebeu a agenda do escritório como convidada:
        // sai do cronograma (fica só na agenda do escritório). O evento NÃO é apagado no Outlook.
        if (l.origem === "outlook" && ehDoEscritorio(ev)) {
          await adm.from("cronograma").update({ situacao: "cancelado", outlook_id: null, outlook_icaluid: null,
            outlook_erro: "passou para a agenda do escritório", outlook_sync_em: new Date().toISOString() }).eq("id", l.id);
          res.cancelados_no_crm++; marcaMeses(l.data_inicio, l.data_fim);
          continue;
        }
        const mudouOutlook = new Date(ev.lastModifiedDateTime).getTime() > new Date(l.outlook_alterado_em || 0).getTime() + 2000;
        const mudouCrm = !l.outlook_sync_em || new Date(l.atualizado_em).getTime() > new Date(l.outlook_sync_em).getTime() + 2000;
        const outlookMaisNovo = new Date(ev.lastModifiedDateTime).getTime() > new Date(l.atualizado_em).getTime();
        if (mudouOutlook && (!mudouCrm || outlookMaisNovo)) {
          const dados: Linha = { outlook_alterado_em: ev.lastModifiedDateTime, outlook_sync_em: new Date().toISOString(), outlook_erro: null };
          const novo: Linha = { data_inicio: e.ini, data_fim: e.fim };
          if (e.funcs.length) novo.funcionarios = e.funcs;
          if (e.local && e.local !== l.local) novo.local = e.local;
          if (e.projeto_id && e.projeto_id !== l.projeto_id) novo.projeto_id = e.projeto_id;
          const difere = novo.data_inicio !== l.data_inicio || novo.data_fim !== l.data_fim || ("local" in novo) || ("projeto_id" in novo) ||
            (novo.funcionarios && [...novo.funcionarios].sort().join() !== [...(l.funcionarios || [])].sort().join());
          if (difere) { Object.assign(dados, novo); res.atualizados_no_crm++; marcaMeses(l.data_inicio, l.data_fim); marcaMeses(e.ini, e.fim); }
          await adm.from("cronograma").update(dados).eq("id", l.id);
        } else if (mudouCrm) {
          await enviarLinha(adm, { ...l, outlook_id: ev.id }, apoio, minhaCaixa); res.enviados++;
        }
        continue;
      }
      // evento novo no Outlook: só vira alocação se tiver funcionário, se quem sincroniza
      // for o organizador (convite recebido não conta) e se ainda não for de outra alocação
      if (!e.funcs.length || !e.ini) continue;
      if (ev.isOrganizer === false) continue;
      if (ehDoEscritorio(ev)) continue; // v45: evento do escritório fica na agenda do escritório, não na folha
      if (ev.iCalUId && uidConhecido.has(ev.iCalUId)) continue;
      const { data: ins, error } = await adm.from("cronograma").insert({
        titulo: e.titulo, projeto_id: e.projeto_id, cliente_id: e.cliente_id, local: e.local,
        data_inicio: e.ini, data_fim: e.fim, sabado: e.sab, domingo: e.dom, funcionarios: e.funcs,
        origem: "outlook", outlook_id: ev.id, outlook_caixa: minhaCaixa, outlook_icaluid: ev.iCalUId || null, outlook_alterado_em: ev.lastModifiedDateTime,
        outlook_sync_em: new Date().toISOString(), criado_por: "Outlook",
      }).select().single();
      if (error) { if (!/duplicate/i.test(error.message)) res.erros.push(error.message); continue; }
      vistos.add(ins.id); res.importados++; marcaMeses(e.ini, e.fim);
    } catch (err) { res.erros.push(String((err as Error).message || err)); }
  }

  // 3. ligadas ao Outlook que não apareceram: apagadas, canceladas ou mudaram de período
  for (const l of linhas.values()) {
    if (vistos.has(l.id) || !l.outlook_id || l.situacao !== "ativo") continue;
    const cxl = caixaDaLinha(l);
    if (!cxl) continue;
    try {
      const r = await graph("GET", `/users/${encodeURIComponent(cxl)}/events/${encodeURIComponent(l.outlook_id)}?$select=id,isCancelled,start,end,isAllDay,lastModifiedDateTime`);
      if (r.status === 404 || (r.ok && r.b.isCancelled)) {
        await adm.from("cronograma").update({ situacao: "cancelado", outlook_id: null, outlook_erro: "apagado no Outlook", outlook_sync_em: new Date().toISOString() }).eq("id", l.id);
        res.cancelados_no_crm++; marcaMeses(l.data_inicio, l.data_fim);
      } else if (r.ok && new Date(r.b.lastModifiedDateTime).getTime() > new Date(l.outlook_alterado_em || 0).getTime() + 2000) {
        const { ini, fim: f } = datasDoEvento(r.b);
        await adm.from("cronograma").update({ data_inicio: ini, data_fim: f, outlook_alterado_em: r.b.lastModifiedDateTime, outlook_sync_em: new Date().toISOString() }).eq("id", l.id);
        res.atualizados_no_crm++; marcaMeses(l.data_inicio, l.data_fim); marcaMeses(ini, f);
      }
    } catch (err) { res.erros.push(String((err as Error).message || err)); }
  }

  // 4. CRM → Outlook: novas (sem evento), alteradas e canceladas
  const { data: pend } = await adm.from("cronograma").select("*").lte("data_inicio", fim).gte("data_fim", inicio);
  for (const l of (pend || []) as Linha[]) {
    if (vistos.has(l.id) && l.situacao === "ativo") continue; // já tratadas no passo 2
    const precisa = l.situacao === "cancelado" ? !!l.outlook_id
      : !l.outlook_id || !l.outlook_sync_em || new Date(l.atualizado_em).getTime() > new Date(l.outlook_sync_em).getTime() + 2000;
    if (!precisa) continue;
    try { await enviarLinha(adm, l, apoio, minhaCaixa); res.enviados++; } catch (err) { res.erros.push(String((err as Error).message || err)); }
  }
  return { ...res, meses: [...res.meses].sort() };
}

// =====================================================================
// v45: AGENDA DO ESCRITÓRIO (caixa agenda@bvek.com.br)
// =====================================================================
const PERFIS_OK = ["administrador", "comercial", "administrativo", "contabilidade", "estagiario"];
function caixaEscritorio(): string {
  return (Deno.env.get("OUTLOOK_ESCRITORIO") || "agenda@bvek.com.br").trim();
}
// o evento tem a agenda do escritório como convidada (ou foi marcado nela)?
function ehDoEscritorio(ev: any): boolean {
  const cx = caixaEscritorio();
  if (mesmaCaixa(ev.organizer?.emailAddress?.address || null, cx)) return true;
  return (ev.attendees || []).some((a: any) => mesmaCaixa(a.emailAddress?.address || null, cx));
}
// Brasília não tem horário de verão desde 2019: UTC-3 fixo
const BR = "-03:00";
const localBR = (ts: string) => new Date(new Date(ts).getTime() - 3 * 3600 * 1000).toISOString().slice(0, 19);
function lerEventoEscritorio(ev: any) {
  const cx = caixaEscritorio();
  let inicio: string, fim: string;
  if (ev.isAllDay) {
    const { ini, fim: f } = datasDoEvento(ev);
    inicio = ini + "T00:00:00" + BR; fim = f + "T23:59:00" + BR;
  } else {
    inicio = String(ev.start?.dateTime || "").slice(0, 19) + BR;
    fim = String(ev.end?.dateTime || "").slice(0, 19) + BR;
    if (fim < inicio) fim = inicio;
  }
  const participantes = (ev.attendees || [])
    .map((a: any) => ({ nome: a.emailAddress?.name || "", email: String(a.emailAddress?.address || "").toLowerCase().trim() }))
    .filter((a: any) => a.email && !mesmaCaixa(a.email, cx));
  return {
    titulo: String(ev.subject || "(sem assunto)").slice(0, 250), inicio, fim, dia_inteiro: !!ev.isAllDay,
    local: ev.location?.displayName || null, descricao: ev.bodyPreview ? String(ev.bodyPreview).slice(0, 1000) : null,
    organizador: ev.organizer?.emailAddress?.name || null,
    organizador_email: ev.organizer?.emailAddress?.address ? String(ev.organizer.emailAddress.address).toLowerCase() : null,
    participantes,
  };
}
// manda um evento do escritório criado no CRM para a agenda (o convite sai em nome da agenda do escritório)
async function enviarEscritorio(adm: SupabaseClient, e: Linha): Promise<string> {
  const cx = encodeURIComponent(caixaEscritorio());
  if (e.origem === "outlook") throw new Error("Este evento veio de um convite do Outlook: altere no Outlook de quem marcou (" + (e.organizador || "organizador") + ").");
  if (e.situacao === "cancelado") {
    if (e.outlook_id) {
      const r = await graph("DELETE", `/users/${cx}/events/${encodeURIComponent(e.outlook_id)}`);
      if (!r.ok && r.status !== 404) throw new Error("Outlook não cancelou o evento: " + (r.b?.error?.message || r.status));
    }
    await adm.from("agenda_escritorio").update({ outlook_id: null, outlook_icaluid: null, outlook_sync_em: new Date().toISOString(), outlook_erro: null }).eq("id", e.id);
    return "cancelado";
  }
  const ini = localBR(e.inicio), fim = localBR(e.fim);
  const ev: Record<string, unknown> = {
    subject: e.titulo,
    body: { contentType: "HTML", content: `${e.descricao ? `<p>${escH(e.descricao).replace(/\n/g, "<br>")}</p>` : ""}<p style="color:#888;font-size:11px">Agenda do escritório — Grupo BVEK${e.criado_por ? " · marcado no CRM por " + escH(e.criado_por) : ""}.</p>` },
    start: { dateTime: e.dia_inteiro ? ini.slice(0, 10) + "T00:00:00" : ini, timeZone: FUSO },
    end: { dateTime: e.dia_inteiro ? somaDias(fim.slice(0, 10), 1) + "T00:00:00" : fim, timeZone: FUSO },
    isAllDay: !!e.dia_inteiro, showAs: e.dia_inteiro ? "free" : "busy",
    location: { displayName: e.local || "" },
    attendees: (e.participantes || []).filter((a: Linha) => a?.email).map((a: Linha) => ({ emailAddress: { address: String(a.email).trim(), name: a.nome || a.email }, type: "required" })),
    categories: ["Escritório"],
  };
  let r = e.outlook_id ? await graph("PATCH", `/users/${cx}/events/${encodeURIComponent(e.outlook_id)}`, ev) : null;
  if (r && r.status === 404) r = null; // apagado no Outlook: cria de novo
  const criou = !r;
  if (!r) r = await graph("POST", `/users/${cx}/events`, ev);
  if (!r.ok) {
    const msg = r.b?.error?.message || String(r.status);
    await adm.from("agenda_escritorio").update({ outlook_erro: msg.slice(0, 300) }).eq("id", e.id);
    if (r.status === 404) throw new Error(`Não achei a agenda ${caixaEscritorio()} no Microsoft 365 (ou o aplicativo do CRM não tem acesso a ela).`);
    throw new Error("Outlook recusou o evento: " + msg);
  }
  await adm.from("agenda_escritorio").update({
    outlook_id: r.b.id, outlook_icaluid: r.b.iCalUId || null,
    outlook_alterado_em: r.b.lastModifiedDateTime || new Date().toISOString(),
    outlook_sync_em: new Date().toISOString(), outlook_erro: null,
  }).eq("id", e.id);
  return criou ? "criado" : "atualizado";
}
async function sincronizarEscritorio(adm: SupabaseClient, inicio: string, fim: string) {
  const cx = encodeURIComponent(caixaEscritorio());
  const res = { importados: 0, atualizados_no_crm: 0, cancelados_no_crm: 0, enviados: 0, erros: [] as string[] };
  const eventos: any[] = [];
  let url: string | null = `/users/${cx}/calendar/calendarView?startDateTime=${inicio}T00:00:00${BR}&endDateTime=${somaDias(fim, 1)}T00:00:00${BR}` +
    `&$top=200&$select=id,iCalUId,isOrganizer,subject,start,end,isAllDay,attendees,organizer,lastModifiedDateTime,isCancelled,location,bodyPreview,type`;
  while (url) {
    const r = await graph("GET", url);
    if (!r.ok) {
      if (r.status === 404) throw new Error(`Não achei a agenda ${caixaEscritorio()} no Microsoft 365 (ou o aplicativo do CRM não tem acesso a ela).`);
      throw new Error("Não consegui ler a agenda do escritório: " + (r.b?.error?.message || r.status));
    }
    eventos.push(...(r.b.value || []));
    url = r.b["@odata.nextLink"] || null;
    if (eventos.length > 3000) break;
  }
  const { data: linhasPer } = await adm.from("agenda_escritorio").select("*")
    .lte("inicio", somaDias(fim, 1) + "T00:00:00" + BR).gte("fim", inicio + "T00:00:00" + BR);
  const idsEv = eventos.map((e) => e.id);
  const { data: linhasEv } = idsEv.length ? await adm.from("agenda_escritorio").select("*").in("outlook_id", idsEv.slice(0, 500)) : { data: [] };
  const linhas = new Map<string, Linha>();
  [...(linhasPer || []), ...(linhasEv || [])].forEach((l: Linha) => linhas.set(l.id, l));
  const porOutlook = new Map<string, Linha>();
  linhas.forEach((l) => { if (l.outlook_id) porOutlook.set(l.outlook_id, l); });
  const vistos = new Set<string>();

  for (const ev of eventos) {
    try {
      if (ev.isCancelled) continue;
      const l = porOutlook.get(ev.id);
      const d = lerEventoEscritorio(ev);
      if (l) {
        vistos.add(l.id);
        if (l.situacao === "cancelado" && l.origem === "crm") continue; // será cancelado no Outlook (abaixo)
        const mudouOutlook = new Date(ev.lastModifiedDateTime).getTime() > new Date(l.outlook_alterado_em || 0).getTime() + 2000;
        const mudouCrm = l.origem === "crm" && (!l.outlook_sync_em || new Date(l.atualizado_em).getTime() > new Date(l.outlook_sync_em).getTime() + 2000);
        const outlookMaisNovo = new Date(ev.lastModifiedDateTime).getTime() > new Date(l.atualizado_em).getTime();
        if (mudouOutlook && (!mudouCrm || outlookMaisNovo)) {
          await adm.from("agenda_escritorio").update({ ...d, situacao: "ativo", outlook_icaluid: ev.iCalUId || null, outlook_alterado_em: ev.lastModifiedDateTime, outlook_sync_em: new Date().toISOString(), outlook_erro: null }).eq("id", l.id);
          res.atualizados_no_crm++;
        } else if (mudouCrm) {
          await enviarEscritorio(adm, l); res.enviados++;
        }
        continue;
      }
      // evento novo na agenda do escritório (convite recebido ou criado direto nela)
      const { error } = await adm.from("agenda_escritorio").insert({
        ...d, origem: ev.isOrganizer ? "crm" : "outlook", outlook_id: ev.id, outlook_icaluid: ev.iCalUId || null,
        outlook_alterado_em: ev.lastModifiedDateTime, outlook_sync_em: new Date().toISOString(), criado_por: "Outlook",
      });
      if (error) { if (!/duplicate/i.test(error.message)) res.erros.push(error.message); continue; }
      res.importados++;
    } catch (err) { res.erros.push(String((err as Error).message || err)); }
  }

  // ligados ao Outlook que não apareceram no período: apagados, recusados ou mudaram de data
  for (const l of linhas.values()) {
    if (vistos.has(l.id) || !l.outlook_id || l.situacao !== "ativo") continue;
    try {
      const r = await graph("GET", `/users/${cx}/events/${encodeURIComponent(l.outlook_id)}?$select=id,iCalUId,isOrganizer,subject,start,end,isAllDay,attendees,organizer,lastModifiedDateTime,isCancelled,location,bodyPreview`);
      if (r.status === 404 || (r.ok && r.b.isCancelled)) {
        await adm.from("agenda_escritorio").update({ situacao: "cancelado", outlook_id: null, outlook_erro: "apagado no Outlook", outlook_sync_em: new Date().toISOString() }).eq("id", l.id);
        res.cancelados_no_crm++;
      } else if (r.ok) {
        await adm.from("agenda_escritorio").update({ ...lerEventoEscritorio(r.b), outlook_alterado_em: r.b.lastModifiedDateTime, outlook_sync_em: new Date().toISOString() }).eq("id", l.id);
        res.atualizados_no_crm++;
      }
    } catch (err) { res.erros.push(String((err as Error).message || err)); }
  }

  // CRM → Outlook: criados no CRM ainda sem evento, alterados e cancelados
  for (const l of linhas.values()) {
    if (l.origem !== "crm" || (vistos.has(l.id) && l.situacao === "ativo")) continue;
    const precisa = l.situacao === "cancelado" ? !!l.outlook_id
      : !l.outlook_id || !l.outlook_sync_em || new Date(l.atualizado_em).getTime() > new Date(l.outlook_sync_em).getTime() + 2000;
    if (!precisa) continue;
    try { await enviarEscritorio(adm, l); res.enviados++; } catch (err) { res.erros.push(String((err as Error).message || err)); }
  }
  return res;
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
    if (!perfil || perfil.ativo === false || !PERFIS_OK.includes(perfil.perfil)) return json({ erro: "Sem permissão." }, 403);
    // v42: a agenda usada é a do próprio usuário (e-mail do login)
    const minhaCaixa = String(user.email || "").trim();
    if (!minhaCaixa || /@funcionario\.bvek\.com\.br$/i.test(minhaCaixa)) return json({ ok: false, erro: "Seu login não tem e-mail do Microsoft 365 para a agenda." }, 400);

    const p = await req.json().catch(() => ({}));
    const acao = String(p.acao || "");
    if (acao === "status") {
      try {
        const r = await graph("GET", `/users/${encodeURIComponent(minhaCaixa)}/calendar?$select=id,name`);
        if (!r.ok) return json({ ok: false, erro: r.b?.error?.message || String(r.status) });
        return json({ ok: true, caixa: minhaCaixa, calendario: r.b.name });
      } catch (e) { return json({ ok: false, erro: String((e as Error).message || e) }); }
    }
    if (acao === "enviar") {
      const { data: l } = await adm.from("cronograma").select("*").eq("id", String(p.id || "")).maybeSingle();
      if (!l) return json({ erro: "Alocação não encontrada." }, 404);
      const apoio = await carregarApoio(adm);
      const feito = await enviarLinha(adm, l, apoio, minhaCaixa);
      return json({ ok: true, feito, caixa: minhaCaixa });
    }
    if (acao === "escritorio_enviar") {
      const { data: e } = await adm.from("agenda_escritorio").select("*").eq("id", String(p.id || "")).maybeSingle();
      if (!e) return json({ erro: "Evento não encontrado." }, 404);
      const feito = await enviarEscritorio(adm, e);
      return json({ ok: true, feito, caixa: caixaEscritorio() });
    }
    if (acao === "escritorio_sincronizar") {
      const ok = (s: unknown) => /^\d{4}-\d{2}-\d{2}$/.test(String(s || ""));
      if (!ok(p.inicio) || !ok(p.fim) || p.fim < p.inicio) return json({ erro: "Período inválido." }, 400);
      if (mesesEntre(p.inicio, p.fim).length > 4) return json({ erro: "Sincronize no máximo 3 meses por vez." }, 400);
      return json({ ok: true, caixa: caixaEscritorio(), ...(await sincronizarEscritorio(adm, p.inicio, p.fim)) });
    }
    if (acao === "sincronizar") {
      const ok = (s: unknown) => /^\d{4}-\d{2}-\d{2}$/.test(String(s || ""));
      if (!ok(p.inicio) || !ok(p.fim) || p.fim < p.inicio) return json({ erro: "Período inválido." }, 400);
      if (mesesEntre(p.inicio, p.fim).length > 4) return json({ erro: "Sincronize no máximo 3 meses por vez." }, 400);
      return json({ ok: true, caixa: minhaCaixa, ...(await sincronizar(adm, p.inicio, p.fim, minhaCaixa)) });
    }
    return json({ erro: "Ação desconhecida." }, 400);
  } catch (e) {
    return json({ ok: false, erro: String((e as Error).message || e) }, 500);
  }
});
