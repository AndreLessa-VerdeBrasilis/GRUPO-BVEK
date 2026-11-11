// =====================================================================
// CRM Grupo BVEK — função "normas-iso" (Supabase Edge Function) — v56
// Busca leis e normas novas no LexML (portal oficial de legislação do
// Senado: federal, estados e municípios) com as palavras de
// Gestão → 📜 Normas ISO → ⚙️ Palavras da busca (tabela iso_config) e grava
// o que for novo em iso_novidades, para o administrador avaliar.
//
// Pedido (POST com JSON):
//   { acao: "buscar" }  → Administrador logado (botão "🔎 Buscar agora")
//   { acao: "buscar", automatico: true } + cabeçalho x-cron-token
//        → agendamento semanal do Supabase (pg_cron, migração v56)
//
// Não precisa de segredo novo: usa SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
// deno-lint-ignore no-explicit-any
type Linha = Record<string, any>;

const SRU = "https://www.lexml.gov.br/busca/SRU";
const decod = (t: string) => t.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
  .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, "&")
  .replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
function campo(reg: string, nome: string): string {
  const m = reg.match(new RegExp(`<(?:[\\w-]+:)?${nome}[^>]*>([\\s\\S]*?)</(?:[\\w-]+:)?${nome}>`, "i"));
  return m ? decod(m[1]) : "";
}
function esferaDaUrn(urn: string): string {
  // urn:lex:br:federal:lei:...  |  urn:lex:br;rio.de.janeiro:estadual:...  |  urn:lex:br;rio.de.janeiro;rio.de.janeiro:municipal:...
  const m = urn.match(/^urn:lex:([^:]+):([^:]+)/i);
  if (!m) return "";
  return m[2].toLowerCase();
}
function localDaUrn(urn: string): string {
  const m = urn.match(/^urn:lex:([^:]+)/i);
  return m ? m[1].toLowerCase() : "";
}
// a lei é de um lugar que interessa? (federal = "br"; RJ = "br;rio.de.janeiro"…)
function localOk(urn: string, locais: string[]): boolean {
  const loc = localDaUrn(urn), esf = esferaDaUrn(urn);
  return locais.some((l) => {
    const x = l.toLowerCase().trim();
    if (x === "federal") return loc === "br" && esf === "federal";
    return loc.split(";").includes(x);
  });
}

async function consultar(query: string, max = 50): Promise<{ registros: string[]; erro: string }> {
  const url = `${SRU}?operation=searchRetrieve&version=1.1&maximumRecords=${max}&startRecord=1&query=${encodeURIComponent(query)}`;
  const r = await fetch(url, { headers: { Accept: "application/xml" } });
  const t = await r.text();
  if (!r.ok) return { registros: [], erro: `LexML respondeu ${r.status}` };
  const diag = t.match(/<(?:\w+:)?diagnostic>([\s\S]*?)<\/(?:\w+:)?diagnostic>/i);
  if (diag) return { registros: [], erro: "LexML: " + (campo(diag[1], "message") || campo(diag[1], "details") || "consulta não aceita") };
  return { registros: t.match(/<(?:\w+:)?record>[\s\S]*?<\/(?:\w+:)?record>/gi) || [], erro: "" };
}

async function buscar(adm: Linha): Promise<Linha> {
  const { data: cfg } = await adm.from("iso_config").select("*").eq("id", 1).maybeSingle();
  if (!cfg) throw new Error("Falta rodar a migração v56 no Supabase.");
  const termos = ((cfg.termos || []) as string[]).map((t) => t.trim()).filter(Boolean);
  const locais = ((cfg.localidades || []) as string[]).length ? cfg.localidades as string[] : ["federal", "rio.de.janeiro"];
  const desde = new Date(Date.now() - Math.max(7, Number(cfg.dias_busca) || 30) * 86400000).toISOString().slice(0, 10);
  const ano = desde.slice(0, 4);

  const achados = new Map<string, Linha>();
  const erros: string[] = [];
  for (const termo of termos) {
    // 1ª tentativa: termo + data; se o LexML não aceitar o filtro de data, busca só pelo termo e filtra aqui
    let r = await consultar(`(dc.title all "${termo}" or dc.description all "${termo}") and date >= "${ano}"`);
    if (r.erro) r = await consultar(`dc.description all "${termo}"`);
    if (r.erro) { erros.push(`"${termo}": ${r.erro}`); continue; }
    for (const reg of r.registros) {
      const urn = campo(reg, "urn");
      if (!urn || achados.has(urn)) continue;
      if (!localOk(urn, locais)) continue;
      const data = (campo(reg, "date").match(/\d{4}-\d{2}-\d{2}/) || [""])[0];
      if (data && data < desde) continue;
      if (!data && !urn.includes(ano)) continue;
      achados.set(urn, {
        fonte: "lexml", chave: urn,
        titulo: (campo(reg, "title") || urn).slice(0, 500),
        ementa: campo(reg, "description").slice(0, 2000) || null,
        data_publicacao: data || null,
        esfera: esferaDaUrn(urn) || null,
        tipo: campo(reg, "tipoDocumento") || null,
        link: "https://www.lexml.gov.br/urn/" + urn,
        termo,
      });
    }
  }
  const lista = [...achados.values()];
  let novos = 0;
  if (lista.length) {
    const { data, error } = await adm.from("iso_novidades").upsert(lista, { onConflict: "chave", ignoreDuplicates: true }).select("id");
    if (error) throw new Error(error.message);
    novos = (data || []).length;
  }
  const resumo = `${new Date().toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo" })}: ${termos.length} palavra(s), ${lista.length} lei(s) encontrada(s), ${novos} nova(s)` +
    (erros.length ? ` · ${erros.length} palavra(s) com erro: ${erros.slice(0, 3).join("; ")}` : "");
  await adm.from("iso_config").update({ ultima_busca: new Date().toISOString(), ultimo_resultado: resumo.slice(0, 1000) }).eq("id", 1);
  return { ok: true, encontrados: lista.length, novos, erros, resumo };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ erro: "Use POST." }, 405);
  const adm = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    const p = await req.json().catch(() => ({}));
    if (p.acao !== "buscar") return json({ erro: "Ação desconhecida." }, 400);
    // quem pode: o agendamento (x-cron-token) ou um Administrador logado
    const tokenCron = req.headers.get("x-cron-token") || "";
    if (tokenCron) {
      const { data: cfg } = await adm.from("iso_config").select("token_cron").eq("id", 1).maybeSingle();
      if (!cfg || cfg.token_cron !== tokenCron) return json({ erro: "Sem permissão." }, 403);
    } else {
      const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: { user }, error } = await adm.auth.getUser(jwt);
      if (error || !user) return json({ erro: "Sessão inválida. Saia e entre de novo no CRM." }, 401);
      const { data: perfil } = await adm.from("perfis").select("perfil,ativo").eq("id", user.id).maybeSingle();
      if (!perfil || perfil.ativo === false || perfil.perfil !== "administrador") return json({ erro: "Só o Administrador busca as normas." }, 403);
    }
    return json(await buscar(adm));
  } catch (e) {
    return json({ erro: String((e as Error).message || e) }, 500);
  }
});
