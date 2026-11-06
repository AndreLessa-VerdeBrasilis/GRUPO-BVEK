// =====================================================================
// CRM Grupo BVEK — função "sharepoint" (Supabase Edge Function) · v34 / v51
// Liga o CRM às pastas do SharePoint (site Grupo BVEK), pelo Microsoft Graph,
// com os MESMOS segredos do e-mail: MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET.
// Opcionais: SP_HOST (padrão andrelessaverdebrasiliscom.sharepoint.com)
//            SP_SITE (padrão /sites/GRUPOBVEK9)
//
// O aplicativo do Azure precisa da permissão de APLICATIVO "Sites.ReadWrite.All"
// (ou "Sites.Selected" liberada para o site Grupo BVEK) com consentimento do administrador.
//
// Pedidos (POST com JSON):
//   { acao: "status" }                                  → a integração está ligada?
//   { acao: "enviar", bucket, caminho, pasta, nome }    → copia um arquivo guardado no CRM
//                                                         para a pasta do SharePoint (substitui se já existir)
//   { acao: "listar", pasta }                           → lista os arquivos de uma pasta
//   v51: { acao: "sincronizar_colaboradores" }          → espelha no CRM (tabela documentos_sharepoint)
//        os arquivos das pastas dos funcionários (01.2.1.1_ATIVOS e 01.2.1.2_DESLIGADOS).
//        Sem duplicar: cada arquivo é guardado pela identificação única dele no SharePoint
//        (renomear/mover não cria outro). Arquivo apagado no SharePoint fica "removido" — mas
//        só quando a pasta inteira foi lida sem erro (falha de leitura nunca some com nada).
//
// Só perfis internos (administrador, administrativo, comercial, contabilidade).
// Só pastas de 01_ADMINISTRATIVO/ e 03_CLIENTES/ (nada fora disso).
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const BUCKETS = new Set(["documentos", "rh", "propostas", "financeiro"]);
const PREFIXOS = ["01_ADMINISTRATIVO/", "03_CLIENTES/"];
// quem pode enviar para cada pasta raiz
const ENVIAR: Record<string, string[]> = {
  "01_ADMINISTRATIVO/": ["administrador", "administrativo"],
  "03_CLIENTES/": ["administrador", "administrativo", "comercial"],
};
const LER: Record<string, string[]> = {
  "01_ADMINISTRATIVO/": ["administrador", "administrativo", "contabilidade"],
  "03_CLIENTES/": ["administrador", "administrativo", "comercial", "consulta"],
};

function pastaSegura(p: string): string | null {
  const t = String(p || "").replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
  if (!t || t.includes("..") || /[:*?"<>|#%]/.test(t)) return null;
  return PREFIXOS.some((x) => (t + "/").startsWith(x)) ? t : null;
}
const raizDe = (p: string) => PREFIXOS.find((x) => (p + "/").startsWith(x))!;
const nomeSeguro = (n: string) => /^[A-Za-z0-9_\-.]{3,120}$/.test(n) && !n.includes("..");
const caminhoGraph = (p: string) => p.split("/").map(encodeURIComponent).join("/");

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
let cacheSite: string | null = null;
async function siteId(tok: string): Promise<string> {
  if (cacheSite) return cacheSite;
  const host = Deno.env.get("SP_HOST") || "andrelessaverdebrasiliscom.sharepoint.com";
  const site = Deno.env.get("SP_SITE") || "/sites/GRUPOBVEK9";
  const r = await fetch(`https://graph.microsoft.com/v1.0/sites/${host}:${site}?$select=id`, { headers: { Authorization: "Bearer " + tok } });
  const b = await r.json();
  if (!r.ok) throw new Error(r.status === 403 || r.status === 401
    ? "O aplicativo do Microsoft 365 ainda não tem permissão no SharePoint (Sites.ReadWrite.All). Peça ao administrador do Microsoft 365 para liberar."
    : "Site do SharePoint não encontrado: " + (b.error?.message || r.status));
  cacheSite = b.id;
  return b.id;
}

// ---------------------------------------------------------------------
// v51: espelho das pastas dos funcionários
// ---------------------------------------------------------------------
const BASES_COLAB = [
  "01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.1_ATIVOS",
  "01_ADMINISTRATIVO/01.2_RH/01.2.1_COLABORADORES/01.2.1.2_DESLIGADOS",
];
// mesmo nome de pasta que o CRM usa (pastaColaborador no index.html)
const nomePasta = (n: string) => String(n || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toUpperCase()
  .replace(/[^A-Z0-9 ]+/g, " ").replace(/\s+/g, " ").trim();
type ItemSP = { id: string; name: string; size?: number; webUrl?: string; lastModifiedDateTime?: string; folder?: unknown; file?: unknown };
// lista TODOS os itens de uma pasta (segue as páginas). null = pasta não existe; lança erro se falhar
async function filhos(tok: string, sid: string, pasta: string): Promise<ItemSP[] | null> {
  let url: string | null = `https://graph.microsoft.com/v1.0/sites/${sid}/drive/root:/${caminhoGraph(pasta)}:/children?$top=200&$select=id,name,size,webUrl,lastModifiedDateTime,folder,file`;
  const out: ItemSP[] = [];
  while (url) {
    const r = await fetch(url, { headers: { Authorization: "Bearer " + tok } });
    if (r.status === 404) return null;
    const b = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(`não consegui ler ${pasta}: ${b.error?.message || r.status}`);
    out.push(...(b.value || []));
    url = b["@odata.nextLink"] || null;
  }
  return out;
}
async function sincronizarColaboradores(adm: any, tok: string, sid: string) {
  const inicio = new Date().toISOString();
  const res = { arquivos: 0, novos: 0, removidos: 0, ligados_ao_crm: 0, pastas: 0,
    pastas_sem_funcionario: [] as string[], pastas_com_erro: [] as string[], funcionarios_com_nome_repetido: [] as string[] };
  const { data: funcs, error: ef } = await adm.from("funcionarios").select("id,nome,ativo");
  if (ef) throw new Error("não consegui ler os funcionários: " + ef.message);
  const porNome = new Map<string, any[]>();
  for (const f of funcs || []) { const k = nomePasta(f.nome); if (!porNome.has(k)) porNome.set(k, []); porNome.get(k)!.push(f); }
  const { data: jaTem } = await adm.from("documentos_sharepoint").select("sp_id");
  const conhecidos = new Set((jaTem || []).map((x: any) => x.sp_id));

  const basesOk = new Set<string>(), raizesListadas = new Set<string>(), raizesOk = new Set<string>();
  const linhas: any[] = [];
  for (const base of BASES_COLAB) {
    const pastas = await filhos(tok, sid, base); // erro aqui = para tudo (nada é removido)
    if (pastas === null) continue;               // pasta-base ainda não existe
    basesOk.add(base);
    for (const pf of pastas.filter((x) => x.folder)) {
      const raiz = base + "/" + pf.name;
      raizesListadas.add(raiz); res.pastas++;
      const cands = porNome.get(nomePasta(pf.name)) || [];
      let func = cands.length === 1 ? cands[0] : cands.filter((f) => (f.ativo !== false) === base.endsWith("ATIVOS"));
      if (Array.isArray(func)) func = func.length === 1 ? func[0] : null;
      if (!cands.length) res.pastas_sem_funcionario.push(raiz.split("/").slice(-2).join("/"));
      else if (!func) res.funcionarios_com_nome_repetido.push(pf.name);
      // arquivos da pasta do funcionário e das subpastas (até 3 níveis)
      try {
        const fila: { p: string; n: number }[] = [{ p: raiz, n: 0 }];
        while (fila.length) {
          const { p, n } = fila.shift()!;
          const itens = await filhos(tok, sid, p);
          for (const it of itens || []) {
            if (it.folder) { if (n < 3) fila.push({ p: p + "/" + it.name, n: n + 1 }); continue; }
            linhas.push({ sp_id: it.id, funcionario_id: func ? func.id : null, raiz, pasta: p, nome: it.name, url: it.webUrl || null,
              tamanho: it.size ?? null, alterado_em: it.lastModifiedDateTime || null, situacao: "ativo", visto_em: inicio, atualizado_em: inicio });
          }
        }
        raizesOk.add(raiz);
      } catch (e) { res.pastas_com_erro.push(pf.name + ": " + String((e as Error).message || e)); }
    }
  }
  // grava: um registro por arquivo (sp_id único) — o mesmo arquivo nunca entra duas vezes
  const vistos = new Set<string>();
  const unicas = linhas.filter((l) => !vistos.has(l.sp_id) && vistos.add(l.sp_id));
  for (let i = 0; i < unicas.length; i += 200) {
    const { error } = await adm.from("documentos_sharepoint").upsert(unicas.slice(i, i + 200), { onConflict: "sp_id" });
    if (error) throw new Error("não consegui gravar o espelho: " + error.message);
  }
  res.arquivos = unicas.length;
  res.novos = unicas.filter((l) => !conhecidos.has(l.sp_id)).length;
  // apagados no SharePoint: só quando a pasta foi lida inteira sem erro (ou a pasta do funcionário sumiu)
  const { data: ativos } = await adm.from("documentos_sharepoint").select("id,raiz,visto_em").eq("situacao", "ativo").lt("visto_em", inicio);
  const sumiram = (ativos || []).filter((l: any) => raizesOk.has(l.raiz) ||
    (!raizesListadas.has(l.raiz) && [...basesOk].some((b) => String(l.raiz).startsWith(b + "/")))).map((l: any) => l.id);
  for (let i = 0; i < sumiram.length; i += 200) {
    await adm.from("documentos_sharepoint").update({ situacao: "removido", atualizado_em: new Date().toISOString() }).in("id", sumiram.slice(i, i + 200));
  }
  res.removidos = sumiram.length;
  const { data: lig } = await adm.rpc("bvek_sp_ligar_documentos");
  res.ligados_ao_crm = Number(lig || 0);
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
    if (!perfil || perfil.ativo === false || ["pendente", "funcionario"].includes(perfil.perfil)) return json({ erro: "Sem permissão." }, 403);

    const p = await req.json().catch(() => ({}));
    const acao = String(p.acao || "");
    if (acao === "status") {
      try { const t = await tokenM365(); await siteId(t); return json({ ok: true }); }
      catch (e) { return json({ ok: false, erro: String((e as Error).message || e) }); }
    }

    if (acao === "sincronizar_colaboradores") {
      if (!["administrador", "administrativo", "contabilidade"].includes(perfil.perfil)) return json({ erro: "Sem permissão." }, 403);
      const tok = await tokenM365(), sid = await siteId(tok);
      const res = await sincronizarColaboradores(adm, tok, sid);
      await adm.from("sharepoint_sync").upsert({ id: "colaboradores", ultima_em: new Date().toISOString(), por: user.email || null, resultado: res }, { onConflict: "id" });
      return json({ ok: true, ...res });
    }

    const pasta = pastaSegura(p.pasta);
    if (!pasta) return json({ erro: "Pasta não permitida." }, 400);
    const raiz = raizDe(pasta);

    if (acao === "listar") {
      if (!LER[raiz].includes(perfil.perfil)) return json({ erro: "Sem permissão para esta pasta." }, 403);
      const tok = await tokenM365(), sid = await siteId(tok);
      const r = await fetch(`https://graph.microsoft.com/v1.0/sites/${sid}/drive/root:/${caminhoGraph(pasta)}:/children?$top=200&$select=name,size,webUrl,lastModifiedDateTime,folder,file`,
        { headers: { Authorization: "Bearer " + tok } });
      if (r.status === 404) return json({ ok: true, existe: false, itens: [] });
      const b = await r.json();
      if (!r.ok) return json({ erro: b.error?.message || "Erro ao listar a pasta." }, 502);
      const itens = (b.value || []).map((x: any) => ({ nome: x.name, tamanho: x.size, url: x.webUrl, alterado: x.lastModifiedDateTime, pasta: !!x.folder }));
      const rp = await fetch(`https://graph.microsoft.com/v1.0/sites/${sid}/drive/root:/${caminhoGraph(pasta)}?$select=webUrl`, { headers: { Authorization: "Bearer " + tok } });
      const bp = rp.ok ? await rp.json() : {};
      return json({ ok: true, existe: true, url: bp.webUrl || null, itens });
    }

    if (acao === "enviar") {
      if (!ENVIAR[raiz].includes(perfil.perfil)) return json({ erro: "Sem permissão para enviar a esta pasta." }, 403);
      const bucket = String(p.bucket || ""), caminho = String(p.caminho || ""), nome = String(p.nome || "");
      if (!BUCKETS.has(bucket) || !caminho || caminho.includes("..")) return json({ erro: "Arquivo inválido." }, 400);
      if (!nomeSeguro(nome)) return json({ erro: "Nome de arquivo fora do padrão." }, 400);
      const { data: arq, error: ed } = await adm.storage.from(bucket).download(caminho);
      if (ed || !arq) return json({ erro: "Arquivo não encontrado no CRM." }, 404);
      if (arq.size > 60 * 1024 * 1024) return json({ erro: "Arquivo grande demais (máx. 60 MB)." }, 413);
      const tok = await tokenM365(), sid = await siteId(tok);
      const r = await fetch(`https://graph.microsoft.com/v1.0/sites/${sid}/drive/root:/${caminhoGraph(pasta + "/" + nome)}:/content`, {
        method: "PUT", headers: { Authorization: "Bearer " + tok, "Content-Type": arq.type || "application/octet-stream" }, body: await arq.arrayBuffer(),
      });
      const b = await r.json().catch(() => ({}));
      if (!r.ok) return json({ erro: b.error?.message || "O SharePoint recusou o arquivo." }, 502);
      return json({ ok: true, url: b.webUrl, caminho: pasta + "/" + nome });
    }
    return json({ erro: "Ação desconhecida." }, 400);
  } catch (e) {
    console.error(e);
    return json({ erro: String((e as Error).message || e) }, 500);
  }
});
