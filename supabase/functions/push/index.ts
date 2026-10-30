// =====================================================================
// CRM Grupo BVEK — função "push" (Supabase Edge Function) · v37
// Avisos no celular/computador mesmo com o CRM FECHADO (Web Push).
// Não precisa configurar segredo: as chaves (VAPID) são criadas sozinhas na
// 1ª vez e ficam na tabela push_config, que só o servidor lê.
//
// Pedidos (POST com JSON):
//   { acao: "chave" }        → chave pública para o aparelho se inscrever (login do CRM)
//   { acao: "teste" }        → manda um aviso de teste para os aparelhos de quem pediu
//   { acao: "lembretes" }    → (agendado no banco, 2x por dia) tarefas, pagamentos e
//                              assinaturas pendentes de cada pessoa. Exige o cabeçalho
//                              x-bvek-cron com o segredo guardado em push_config.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-bvek-cron",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const norm = (t: string) => String(t || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toUpperCase().replace(/[^A-Z0-9]/g, "");
const hojeSP = () => new Date(Date.now() - 3 * 3600 * 1000).toISOString().slice(0, 10);

async function chaves(adm: any) {
  let { data } = await adm.from("push_config").select("*").eq("id", 1).maybeSingle();
  if (!data || !data.publica || !data.privada) {
    const k = webpush.generateVAPIDKeys();
    const novo = { id: 1, publica: k.publicKey, privada: k.privateKey, segredo_cron: data?.segredo_cron || crypto.randomUUID() };
    await adm.from("push_config").upsert(novo);
    data = novo;
  }
  webpush.setVapidDetails("mailto:andre.lessa@verdebrasilis.com.br", data.publica, data.privada);
  return data;
}

async function enviar(adm: any, subs: any[], aviso: { titulo: string; corpo: string; url?: string; tag?: string }) {
  let ok = 0;
  for (const s of subs) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify(aviso), { TTL: 6 * 3600 });
      ok++;
    } catch (e: any) {
      // aparelho desinstalou ou trocou: tira da lista
      if (e && (e.statusCode === 404 || e.statusCode === 410)) await adm.from("push_inscricoes").delete().eq("endpoint", s.endpoint);
      else console.error("push", e && (e.statusCode || e.message));
    }
  }
  if (ok) await adm.from("push_inscricoes").update({ ultimo_envio: new Date().toISOString() }).in("endpoint", subs.map((s) => s.endpoint));
  return ok;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const adm = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    const p = await req.json().catch(() => ({}));
    const cfg = await chaves(adm);

    // ---- agendado: lembretes do dia ----
    if (p.acao === "lembretes") {
      if (!cfg.segredo_cron || req.headers.get("x-bvek-cron") !== cfg.segredo_cron) return json({ erro: "não autorizado" }, 401);
      const { data: subs } = await adm.from("push_inscricoes").select("user_id,endpoint,p256dh,auth");
      if (!subs || !subs.length) return json({ ok: true, enviados: 0 });
      const ids = [...new Set(subs.map((s: any) => s.user_id))];
      const { data: perfis } = await adm.from("perfis").select("id,nome,perfil,ativo,email").in("id", ids);
      const hoje = hojeSP();
      const { data: ativ } = await adm.from("atividades").select("descricao,responsavel,data_prevista,concluida,tipo")
        .eq("concluida", false).neq("tipo", "nota").lte("data_prevista", hoje + "T23:59:59");
      const { data: pags } = await adm.from("pagamentos_autorizacao").select("valor,vencimento,situacao,lembrete_ativo").eq("situacao", "pendente");
      let enviados = 0;
      for (const pf of perfis || []) {
        if (pf.ativo === false) continue;
        const partes: string[] = [];
        if (pf.perfil === "funcionario") {
          const cpf = String(pf.email || "").split("@")[0].replace(/\D/g, "");
          const { data: f } = await adm.from("funcionarios").select("id,cpf").eq("ativo", true);
          const meu = (f || []).find((x: any) => String(x.cpf || "").replace(/\D/g, "") === cpf);
          if (meu) {
            const { data: pr } = await adm.from("premiacoes").select("id").eq("funcionario_id", meu.id).is("assinado_em", null);
            if (pr && pr.length) partes.push(`${pr.length} declaração(ões) de premiação para assinar`);
          }
        } else {
          const minhas = (ativ || []).filter((a: any) => norm(a.responsavel) && norm(a.responsavel) === norm(pf.nome));
          if (minhas.length) {
            const atras = minhas.filter((a: any) => String(a.data_prevista).slice(0, 10) < hoje).length;
            partes.push(`${minhas.length} tarefa(s) para hoje${atras ? ` (${atras} atrasada${atras > 1 ? "s" : ""})` : ""}`);
          }
          if (pf.perfil === "administrador") {
            const pg = (pags || []).filter((x: any) => x.lembrete_ativo !== false);
            if (pg.length) partes.push(`${pg.length} pagamento(s) aguardando sua autorização`);
          }
        }
        if (!partes.length) continue;
        const meus = subs.filter((s: any) => s.user_id === pf.id);
        enviados += await enviar(adm, meus, { titulo: "CRM Grupo BVEK", corpo: partes.join(" · "), url: "/", tag: "lembretes" });
      }
      return json({ ok: true, enviados });
    }

    // ---- pedidos do CRM (usuário logado) ----
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: { user }, error: eu } = await adm.auth.getUser(jwt);
    if (eu || !user) return json({ erro: "Sessão inválida. Saia e entre de novo no CRM." }, 401);
    if (p.acao === "chave") return json({ ok: true, chave: cfg.publica });
    if (p.acao === "teste") {
      const { data: subs } = await adm.from("push_inscricoes").select("endpoint,p256dh,auth").eq("user_id", user.id);
      const n = await enviar(adm, subs || [], { titulo: "CRM Grupo BVEK", corpo: "Pronto! Os avisos chegam aqui mesmo com o CRM fechado.", url: "/", tag: "teste" });
      return json({ ok: true, enviados: n });
    }
    return json({ erro: "Ação desconhecida." }, 400);
  } catch (e) {
    console.error(e);
    return json({ erro: String((e as Error).message || e) }, 500);
  }
});
