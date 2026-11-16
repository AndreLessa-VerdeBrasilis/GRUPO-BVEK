// =====================================================================
// CRM Grupo BVEK — função "ler-proposta" (Supabase Edge Function) — v63
// Funil → proposta → "Usar proposta pronta como base": lê uma proposta feita
// em outro formato (PDF ou Word, muitas vezes montada com ajuda de IA) e
// devolve os dados já no formato do gerador de proposta do CRM:
//   objeto, escopo, prazo, validade, pagamento, premissas, notas,
//   planilha por etapa (itens), composição de preço (equipe, materiais,
//   equipamentos, terceiros, mobilização, documentos, dias e turno) e o
//   detalhe da execução da OS.
// Os CUSTOS da composição não vêm daqui: o CRM preenche com a base própria
// (Parâmetros e Fornecedores). Aqui só se lê o que a proposta diz.
//
// Segredo necessário (Supabase → Edge Functions → Secrets):
//   ANTHROPIC_API_KEY  — chave da API da Anthropic (Claude)
// Pedido (POST com JSON):
//   { nome, pdf_base64? , texto?, contexto: { funcoes:[], materiais:[], documentos:[], tipos_cliente:[] } }
// Só o Administrador (as propostas e os valores são só dele desde a v46).
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import Anthropic from "npm:@anthropic-ai/sdk@1.8.0";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const num = { type: ["number", "null"] };
const txt = { type: "string" };
const obj = (props: Record<string, unknown>) => ({ type: "object", properties: props, required: Object.keys(props), additionalProperties: false });
const lista = (item: unknown) => ({ type: "array", items: item });

const SCHEMA = obj({
  titulo: txt,
  empresa_sigla: { type: "string", enum: ["EK", "VB", "BL", "KS", ""] },
  cliente_nome: txt,
  cliente_documento: txt,
  numero_original: txt,
  escopo: txt,
  prazo: obj({ numero: num, unidade: { type: "string", enum: ["dias", "semanas", "meses", ""] } }),
  validade_dias: num,
  pagamento: obj({
    tipo: { type: "string", enum: ["medicao", "conclusao", "sinal_conclusao", "sinal_medicao", "outra", ""] },
    sinal_pct: num, dias: num,
    periodo: { type: "string", enum: ["mensal", "quinzenal", "semanal", ""] },
    texto: txt,
  }),
  premissas: txt,
  nota1: txt,
  nota2: txt,
  valor_total: num,
  itens: lista(obj({
    tipo: { type: "string", enum: ["etapa", "item"] },
    item: txt, descricao: txt, unidade: txt, quantidade: num, valor_unitario: num, valor_total: num,
  })),
  composicao: obj({
    turno: { type: "string", enum: ["diurno", "noturno"] },
    dias_uteis: num, sabados: num, domingos: num,
    tipo_cliente: txt,
    equipe: lista(obj({ funcao: txt, qtd: num, dias: num })),
    materiais: lista(obj({ descricao: txt, unidade: txt, qtd: num })),
    equipamentos: lista(obj({ descricao: txt, unidade: txt, qtd: num })),
    terceiros: lista(obj({ descricao: txt, valor: num })),
    mobilizacao: lista(obj({ descricao: txt, valor: num })),
    documentos: lista(txt),
    obs: txt,
  }),
  os: obj({ condicoes_local: txt, incluido: txt, nao_incluido: txt, resultado_final: txt, pontos_parada: txt, seguranca: txt }),
  alertas: lista(txt),
});

const SISTEMA = `Você trabalha no comercial do Grupo BVEK (Rio de Janeiro): Engekat Construções (EK — construção civil, projetos técnicos, drywall, steel frame, solda, caldeiraria, tubulação, alpinismo, pintura), Verde Brasilis (VB — áreas verdes, poda, remoção, reflorestamento, paisagismo, jardinagem, legalizações), BrasiLimp (BL — limpeza, conservação, manutenção, segurança) e Kat Corretora de Seguros (KS).

Você recebe uma proposta comercial pronta, feita em outro formato (muitas vezes com ajuda de IA), e deve ADAPTÁ-LA ao modelo de proposta do grupo, preenchendo os campos do gerador do CRM. Não é um resumo: aproveite todo o conteúdo técnico, reorganizado no nosso padrão.

O nosso modelo de proposta já tem, fixos, a carta de apresentação, os segmentos, os seguros, tributos, faturamento, considerações finais, assinaturas e o aceite. NÃO repita esses textos institucionais nos campos. O PDF final tem as seções: Objeto · Escopo de fornecimento · Planilha de preços (com subtotais por etapa) · Resumo por etapa · Equipe e equipamentos previstos · Premissas e esclarecimentos · Condições comerciais.

Regras de cada campo:
- titulo: o objeto em uma frase curta, começando com o serviço (ex.: "Retrofit do laboratório — térreo"). Sem o nome da nossa empresa, sem número de proposta.
- empresa_sigla: a empresa do grupo que executa (pelo tipo de serviço ou pelo nome na proposta); "" se não der para saber.
- cliente_nome / cliente_documento (CNPJ ou CPF do CLIENTE, nunca o nosso): "" se não houver.
- numero_original: o número que a proposta enviada traz, se houver.
- escopo: o escopo de fornecimento completo, em português formal e objetivo, em linhas curtas. Use um título curto por grupo de serviços numa linha e, abaixo, cada atividade numa linha começando com "• ". Inclua especificações técnicas, normas, materiais e métodos citados. Não inclua preços aqui.
- premissas: premissas, esclarecimentos, exclusões ("Não estão incluídos: …"), responsabilidades do contratante e condições do local — uma por linha, começando com "• ".
- nota1 e nota2: duas observações curtas e importantes que a proposta traga (ex.: chuva, paralisação, horário); "" se não houver.
- prazo: prazo de execução (número + unidade). validade_dias: validade da proposta em dias.
- pagamento: classifique em medicao (por medição), conclusao (após a conclusão), sinal_conclusao (sinal + saldo na conclusão), sinal_medicao (sinal + saldo por medição) ou outra (texto livre em "texto"). sinal_pct, dias (prazo para pagar) e periodo quando houver.
- itens: a planilha de preços no nosso padrão. Agrupe em etapas: a linha de etapa tem tipo "etapa", item "1", "2"… e descrição em poucas palavras, sem quantidade e sem valores (null). Os itens da etapa têm tipo "item", item "1.1", "1.2"…, descrição clara, unidade (m², m, un, vb, mês, diária, h, kg, m³…), quantidade, preço unitário e total. Se a proposta não tiver etapas, crie etapas lógicas. Use os preços que a proposta traz (finais, já com tudo); se um item não tiver preço, deixe null. Nunca mostre margem de lucro, BDI ou impostos separados como item: se a proposta tiver linhas de BDI/lucro/impostos, distribua esse valor proporcionalmente nos preços unitários e avise em "alertas".
- valor_total: o valor global da proposta (null se não houver).
- composicao: o que é preciso para executar, para o CRM calcular o custo com a nossa base. Equipe: função, quantidade de pessoas e dias (null = o período todo). Use, quando corresponder, exatamente os nomes de função da lista fornecida. Materiais e equipamentos: descrição (use o nome da lista de materiais quando for o mesmo item), unidade e quantidade. Terceiros e mobilização: descrição e valor só se a proposta disser o custo (senão null). Dias úteis, sábados e domingos/feriados de trabalho pelo prazo e pelo cronograma (ex.: 1 mês de seg a sex ≈ 22 dias úteis); turno noturno só se a proposta disser. documentos: exigências documentais do cliente que estejam na lista de documentos (ex.: ASO, NR-35, PGR), com o nome exato da lista. tipo_cliente: um nome da lista de tipos de cliente, ou "". Se não houver informação para estimar algo, deixe vazio — não invente números sem base.
- os: detalhe da execução para a equipe (sai só na Ordem de Serviço, sem valores): condições do local, o que está incluído, o que NÃO está incluído, como deve ficar no final, quando parar e consultar o responsável, cuidados de segurança (EPI, NR, isolamento). "" quando a proposta não disser.
- alertas: avisos curtos para quem vai revisar (ex.: "a proposta original mostrava BDI de 25% — diluído nos preços", "item 2.3 sem preço", "a soma dos itens difere do valor global", "prazo não informado").

Escreva tudo em português do Brasil, sem emojis.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ erro: "Use POST." }, 405);
  const adm = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: { user }, error: eu } = await adm.auth.getUser(jwt);
    if (eu || !user) return json({ erro: "Sessão inválida. Saia e entre de novo no CRM." }, 401);
    const { data: perfil } = await adm.from("perfis").select("perfil,ativo").eq("id", user.id).maybeSingle();
    if (!perfil || perfil.ativo === false || perfil.perfil !== "administrador") return json({ erro: "Só o Administrador usa propostas." }, 403);

    const chave = Deno.env.get("ANTHROPIC_API_KEY");
    if (!chave) return json({ erro: "Falta configurar a leitura por IA: cadastre o segredo ANTHROPIC_API_KEY nas Edge Functions do Supabase." }, 500);

    const p = await req.json().catch(() => ({}));
    const pdf = typeof p.pdf_base64 === "string" ? p.pdf_base64.replace(/\s+/g, "") : "";
    const texto = typeof p.texto === "string" ? p.texto : "";
    if (!pdf && texto.trim().length < 30) return json({ erro: "Não recebi o conteúdo da proposta." }, 400);
    if (pdf.length > 30 * 1024 * 1024) return json({ erro: "Arquivo grande demais (máx. ~20 MB)." }, 400);

    const ctx = p.contexto || {};
    const nomes = (a: unknown, max: number) => (Array.isArray(a) ? a : []).map((x) => String(x).trim()).filter(Boolean).slice(0, max);
    const contexto = `Listas do CRM (use estes nomes quando corresponderem):
Funções da equipe: ${nomes(ctx.funcoes, 200).join("; ") || "(nenhuma cadastrada)"}
Tipos de cliente: ${nomes(ctx.tipos_cliente, 50).join("; ") || "(nenhum)"}
Documentos exigidos possíveis: ${nomes(ctx.documentos, 100).join("; ") || "(nenhum)"}
Materiais cadastrados: ${nomes(ctx.materiais, 600).join("; ") || "(nenhum)"}`;

    // deno-lint-ignore no-explicit-any
    const conteudo: any[] = [];
    if (pdf) conteudo.push({ type: "document", source: { type: "base64", media_type: "application/pdf", data: pdf } });
    else conteudo.push({ type: "text", text: `<proposta arquivo="${String(p.nome || "").slice(0, 120)}">\n${texto.slice(0, 400000)}\n</proposta>` });
    conteudo.push({ type: "text", text: `${contexto}\n\nAdapte a proposta acima ao modelo do grupo, preenchendo todos os campos.` });

    const client = new Anthropic({ apiKey: chave });
    // deno-lint-ignore no-explicit-any
    const params: any = {
      model: "claude-opus-5-5",
      max_tokens: 32000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      system: SISTEMA,
      output_config: { effort: "medium", format: { type: "json_schema", schema: SCHEMA } },
      messages: [{ role: "user", content: conteudo }],
    };
    const msg = await client.beta.messages.stream(params).finalMessage();
    if (msg.stop_reason === "refusal") return json({ erro: "A IA recusou ler este arquivo. Preencha à mão." }, 422);
    if (msg.stop_reason === "max_tokens") return json({ erro: "A proposta é longa demais para ler de uma vez. Envie só a parte técnica e comercial." }, 422);
    // deno-lint-ignore no-explicit-any
    const bloco = (msg.content as any[]).find((b) => b.type === "text");
    if (!bloco) return json({ erro: "A IA não devolveu dados." }, 502);
    let dados;
    try { dados = JSON.parse(bloco.text); } catch (_) { return json({ erro: "A resposta da IA veio incompleta. Tente de novo." }, 502); }
    return json({ ok: true, dados, uso: msg.usage });
  } catch (e) {
    console.error(e);
    // deno-lint-ignore no-explicit-any
    const s = (e as any)?.status;
    if (s === 401) return json({ erro: "A chave ANTHROPIC_API_KEY foi recusada. Confira o segredo no Supabase." }, 500);
    if (s === 429 || s === 529) return json({ erro: "A IA está sobrecarregada agora. Tente de novo em 1 minuto." }, 503);
    return json({ erro: String((e as Error)?.message || e) }, 500);
  }
});
