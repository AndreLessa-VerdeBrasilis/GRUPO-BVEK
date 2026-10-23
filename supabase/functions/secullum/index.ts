// =====================================================================
// CRM Grupo BVEK — função "secullum" (Supabase Edge Function)
// Conversa com o Ponto Secullum Web (integração externa oficial) pelo
// servidor, para a senha nunca ir para o navegador nem para o GitHub.
//
// Segredos (Supabase → Edge Functions → Secrets):
//   SECULLUM_USUARIO  usuário da conta Secullum
//   SECULLUM_SENHA    senha desse usuário
//   SECULLUM_BANCO    (opcional) nome ou id do banco, se houver mais de um
//
// Ações (POST com JSON):
//   { "acao": "funcionarios" }  → lista nome, CPF, PIS, admissão, demissão
//
// Só Administrador e Administrativo do CRM podem chamar.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const AUTENTICADOR = "https://autenticador.secullum.com.br";
const PONTOWEB = "https://pontowebintegracaoexterna.secullum.com.br/IntegracaoExterna/";
const CLIENT_ID_PONTOWEB = "3"; // valor fixo informado pela Secullum

// lê um campo sem depender de maiúsculas/minúsculas (Nome, nome, NOME)
// deno-lint-ignore no-explicit-any
function campo(o: any, ...nomes: string[]): any {
  if (!o || typeof o !== "object") return null;
  const chaves = Object.keys(o);
  for (const n of nomes) {
    const k = chaves.find((c) => c.toLowerCase() === n.toLowerCase());
    if (k !== undefined && o[k] !== null && o[k] !== "") return o[k];
  }
  return null;
}
const soData = (v: unknown) => (v ? String(v).slice(0, 10) : null);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    // 1. quem está chamando?
    const adm = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: { user }, error: erroUsuario } = await adm.auth.getUser(jwt);
    if (erroUsuario || !user) return json({ erro: "Sessão inválida. Saia e entre de novo no CRM." }, 401);
    const { data: perfil } = await adm.from("perfis").select("perfil,ativo").eq("id", user.id).maybeSingle();
    if (!perfil || !perfil.ativo || !["administrador", "administrativo"].includes(perfil.perfil)) {
      return json({ erro: "Seu perfil não pode buscar dados do Secullum." }, 403);
    }

    const usuario = Deno.env.get("SECULLUM_USUARIO");
    const senha = Deno.env.get("SECULLUM_SENHA");
    if (!usuario || !senha) {
      return json({ erro: "Faltam os segredos SECULLUM_USUARIO e SECULLUM_SENHA no Supabase (Edge Functions → Secrets)." }, 500);
    }
    const pedido = await req.json().catch(() => ({}));

    // 2. entra no Secullum
    const rt = await fetch(AUTENTICADOR + "/Token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "password", username: usuario, password: senha, client_id: CLIENT_ID_PONTOWEB }),
    });
    const tok = await rt.json().catch(() => ({}));
    if (!rt.ok || !tok.access_token) {
      return json({ erro: "O Secullum recusou o usuário ou a senha.", detalhe: tok.error_description || tok.error || rt.status }, 502);
    }
    const token = tok.access_token as string;

    // 3. escolhe o banco do Ponto Web
    const rb = await fetch(AUTENTICADOR + "/ContasSecullumExterno/ListarBancos/", { headers: { Authorization: "Bearer " + token } });
    // deno-lint-ignore no-explicit-any
    const bancos = ((await rb.json().catch(() => [])) as any[]).filter((b) => String(campo(b, "clienteId")) === CLIENT_ID_PONTOWEB);
    if (!bancos.length) {
      return json({ erro: "Nenhum banco do Ponto Web liberado para este usuário. Confira com a Tecnoponto se a integração externa está ativa." }, 502);
    }
    const preferido = Deno.env.get("SECULLUM_BANCO");
    const banco = (preferido && bancos.find((b) => String(campo(b, "id")) === preferido || campo(b, "nome") === preferido)) || bancos[0];
    const idBanco = String(campo(banco, "identificador")).replace(/-/g, "");

    const pontoWeb = async (rota: string) => {
      const r = await fetch(PONTOWEB + rota, { headers: { Authorization: "Bearer " + token, secullumidbancoselecionado: idBanco } });
      const t = await r.text();
      if (!r.ok) throw new Error(`Secullum respondeu ${r.status} em ${rota.split("?")[0]}: ${t.slice(0, 300)}`);
      return t ? JSON.parse(t) : null;
    };

    // 4. ações
    if (pedido.acao === "funcionarios") {
      const lista = (await pontoWeb("Funcionarios")) || [];
      // deno-lint-ignore no-explicit-any
      const funcionarios = (lista as any[]).map((f) => {
        const emp = campo(f, "Empresa");
        const fun = campo(f, "Funcao");
        return {
          nome: campo(f, "Nome"),
          cpf: campo(f, "Cpf"),
          pis: campo(f, "NumeroPis", "Pis"),
          folha: campo(f, "NumeroFolha"),
          admissao: soData(campo(f, "Admissao")),
          demissao: soData(campo(f, "Demissao")),
          empresa_doc: campo(f, "EmpresaCnpjCpf") || campo(emp, "Documento", "CnpjCpf"),
          funcao: campo(f, "FuncaoDescricao") || campo(fun, "Descricao"),
        };
      });
      return json({
        banco: campo(banco, "nome"),
        bancos: bancos.map((b) => campo(b, "nome")),
        total: funcionarios.length,
        funcionarios,
      });
    }

    return json({ erro: "Ação desconhecida." }, 400);
  } catch (e) {
    return json({ erro: String((e as Error)?.message || e) }, 500);
  }
});
