// =====================================================================
// CRM Grupo BVEK — função "ler-proposta" (Supabase Edge Function) — v63
// Funil → proposta → "Usar proposta pronta como base": lê uma proposta feita
// em outro formato (PDF ou Word, muitas vezes montada com ajuda de IA) e
// devolve os dados já no formato do gerador de proposta do CRM:
//   objeto, escopo, prazo, validade, pagamento, premissas, notas,
//   planilha por etapa (itens), composição de preço (equipe, materiais,
//   equipamentos, terceiros, mobilização, documentos, dias e turno) e o
//   detalhe da execução da OS.
//   v71: objeto completo, abertura, seções técnicas antes/depois da planilha
//   (subtítulos, listas e tabelas), exclusões e onde estão as figuras/esquemas
//   (página e recorte no PDF; nome do arquivo no Word) — o CRM recorta.
// Os CUSTOS da composição não vêm daqui: o CRM preenche com a base própria
// (Parâmetros e Fornecedores). Aqui só se lê o que a proposta diz.
//
// Segredo necessário (Supabase → Edge Functions → Secrets):
//   ANTHROPIC_API_KEY  — chave da API da Anthropic (Claude)
// Pedido (POST com JSON):
//   { nome, pdf_base64? , texto?, contexto: { funcoes:[], materiais:[], documentos:[], tipos_cliente:[] } }
// Só o Administrador (as propostas e os valores são só dele desde a v46).
//
// v70 — conversa com a IA na proposta (modo "conversa"):
//   { modo:"conversa", mensagens:[{papel:"usuario"|"ia", texto}], proposta:{…campos atuais},
//     documento?:{ nome, pdf_base64? , texto? }, contexto }
//   Responde { ok, resposta, mudancas } — "mudancas" só traz os campos que a IA
//   sugere trocar; o CRM mostra e só aplica quando a pessoa clica em Aplicar.
//   A conversa e o documento não são guardados (ficam só na tela).
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

// números sem "null" (a API limita campos com mais de um tipo): 0 = não informado
const num = { type: "number" };
const txt = { type: "string" };
const obj = (props: Record<string, unknown>) => ({ type: "object", properties: props, required: Object.keys(props), additionalProperties: false });
const lista = (item: unknown) => ({ type: "array", items: item });

const SCHEMA = obj({
  titulo: txt,
  objeto: txt,
  abertura: txt,
  empresa_sigla: { type: "string", enum: ["EK", "VB", "BL", "KS", ""] },
  cliente_nome: txt,
  cliente_documento: txt,
  numero_original: txt,
  escopo: txt,
  secoes_antes: txt,
  secoes_depois: txt,
  prazo: obj({ numero: num, unidade: { type: "string", enum: ["dias", "semanas", "meses", ""] } }),
  validade_dias: num,
  pagamento: obj({
    tipo: { type: "string", enum: ["medicao", "conclusao", "sinal_conclusao", "sinal_medicao", "outra", ""] },
    sinal_pct: num, dias: num,
    periodo: { type: "string", enum: ["mensal", "quinzenal", "semanal", ""] },
    texto: txt,
  }),
  premissas: txt,
  exclusoes: txt,
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
  figuras: lista(obj({ pagina: num, x: num, y: num, largura: num, altura: num, arquivo: txt, legenda: txt, secao: txt })),
  alertas: lista(txt),
});

// O formato não é imposto pela API (o "grammar" desse formulário fica grande demais):
// o modelo de resposta vai no pedido e a resposta é conferida e completada aqui.
// deno-lint-ignore no-explicit-any
function modelo(sc: any): unknown {
  if (sc.type === "object") return Object.fromEntries(Object.keys(sc.properties).map((k) => [k, modelo(sc.properties[k])]));
  if (sc.type === "array") return [modelo(sc.items)];
  if (sc.enum) return sc.enum.filter((x: string) => x).join(" | ") + (sc.enum.includes("") ? " | (vazio)" : "");
  return sc.type === "number" ? 0 : "";
}
// deno-lint-ignore no-explicit-any
function completar(sc: any, v: any): any {
  if (sc.type === "object") {
    const o = v && typeof v === "object" && !Array.isArray(v) ? v : {};
    return Object.fromEntries(Object.keys(sc.properties).map((k) => [k, completar(sc.properties[k], o[k])]));
  }
  if (sc.type === "array") return Array.isArray(v) ? v.map((x) => completar(sc.items, x)).filter((x) => x !== "") : [];
  if (sc.type === "number") { const n = typeof v === "number" ? v : Number(String(v ?? "").replace(/\./g, "").replace(",", ".")); return isFinite(n) ? n : 0; }
  const t = v == null ? "" : String(v);
  if (sc.enum) return sc.enum.includes(t) ? t : (sc.enum.includes("") ? "" : sc.enum[0]);
  return t;
}
function extrairJson(t: string): unknown {
  const s = t.replace(/^[\s\S]*?```(?:json)?\s*/i, (m) => (m.includes("```") ? "" : m));
  const i = s.indexOf("{"), f = s.lastIndexOf("}");
  if (i < 0 || f <= i) throw new Error("sem JSON");
  return JSON.parse(s.slice(i, f + 1));
}

const SISTEMA = `Você trabalha no comercial do Grupo BVEK (Rio de Janeiro): Engekat Construções (EK — construção civil, projetos técnicos, drywall, steel frame, solda, caldeiraria, tubulação, alpinismo, pintura), Verde Brasilis (VB — áreas verdes, poda, remoção, reflorestamento, paisagismo, jardinagem, legalizações), BrasiLimp (BL — limpeza, conservação, manutenção, segurança) e Kat Corretora de Seguros (KS).

Você recebe uma proposta comercial pronta, feita em outro formato (muitas vezes com ajuda de IA), e deve ADAPTÁ-LA ao modelo de proposta do grupo, preenchendo os campos do gerador do CRM. Não é um resumo: aproveite todo o conteúdo técnico, reorganizado no nosso padrão.

O nosso modelo de proposta já tem, fixos, a carta de apresentação institucional, os segmentos, os seguros, tributos, faturamento, considerações finais, assinaturas e o aceite. NÃO repita esses textos nos campos. O PDF final tem, nesta ordem: Abertura · 1. Objeto · seções técnicas "antes da planilha" · Escopo de fornecimento · Planilha de preços (com subtotais por etapa) · seções técnicas "depois da planilha" · Equipe e equipamentos · Premissas e esclarecimentos · Exclusões · Condições comerciais.

PRINCÍPIO: cada informação vai para UM lugar só, no lugar certo, e a estrutura da proposta original é preservada. Não transforme tudo em lista: parágrafo continua parágrafo, tabela continua tabela, subtítulo continua subtítulo. Nunca repita a mesma informação em dois campos.

Formatação dos campos de texto longo (escopo, secoes_antes, secoes_depois, premissas, exclusoes, abertura, objeto):
- parágrafo = uma linha de texto comum;
- item de lista = linha começando com "• ";
- subtítulo dentro de uma seção = linha começando com "## ";
- negrito = **texto** (use pouco, por exemplo no início de um item: "• **Menos resíduo:** a manta…");
- tabela = linhas começando e terminando com "|", células separadas por "|"; a primeira linha é o cabeçalho. Ex.:
| Critério | Desempenho |
| Resistência | 70 MPa aos 28 dias |
- nota de rodapé de tabela = parágrafo começando com "Obs.:".
- Só em secoes_antes e secoes_depois: cada seção começa com uma linha "# TÍTULO DA SEÇÃO" (em maiúsculas, sem número — o CRM numera).

Regras de cada campo (número desconhecido ou não informado = 0):
- titulo: o objeto em uma frase curta para o funil, começando com o serviço (ex.: "Caminho seguro de pedestres em manta cimentícia — 13,20 m²"). Sem o nome da nossa empresa, sem número de proposta.
- objeto: o texto completo da seção de objeto da proposta original (parágrafo inteiro, com dimensões, local e solução). "" se ela não tiver.
- abertura: os parágrafos da carta/abertura específicos DESTA proposta que vêm depois de "Prezados Senhores" (contexto, histórico com o cliente, solução proposta, anexos de referência). Sem a saudação, sem a apresentação institucional do grupo e sem assinatura. "" se for só um texto genérico.
- empresa_sigla: a empresa do grupo que executa (pelo tipo de serviço ou pelo nome na proposta); "" se não der para saber.
- cliente_nome / cliente_documento (CNPJ ou CPF do CLIENTE, nunca o nosso): "" se não houver.
- numero_original: o número que a proposta enviada traz, se houver.
- secoes_antes: as seções técnicas da original que vêm ANTES da planilha e não são objeto, escopo, premissas, exclusões nem condições comerciais — ex.: justificativa da solução ("Por que…"), solução técnica e método executivo, especificações, sequência executiva. Mantenha os títulos, os parágrafos, as tabelas (todas as linhas e colunas) e as listas da original, em português formal. "" se não houver.
- escopo: SÓ o escopo de fornecimento — o que a contratada fornece/executa — enxuto e objetivo, normalmente de 5 a 15 itens "• ". Se a original separa o escopo em grupos, use "## " para cada grupo. NÃO coloque aqui especificações técnicas, desempenho, ensaios, normas de produto, método passo a passo, SSMA, premissas ou exclusões: isso vai em secoes_antes/secoes_depois/premissas/exclusoes. Não inclua preços.
- secoes_depois: as seções que vêm DEPOIS da planilha na original — ex.: tabela de preços para próximas frentes/faixas, comparativo com outra solução, prazo e cronograma (em tabela), segurança/meio ambiente/saúde (SSMA), garantia, informações complementares. Texto explicativo que acompanha a planilha (ex.: por que o preço é global, tabela de preços por faixa) também vai aqui, numa seção própria. "" se não houver.
- premissas: premissas e esclarecimentos (condições do local, responsabilidades do contratante, horário, revisão de prazo, alterações) — um por linha, começando com "• ". SEM as exclusões e sem repetir o que já está em outra seção.
- exclusoes: o que NÃO está incluído — um item por linha começando com "• ", sem repetir "Não estão incluídos:" em cada linha. "" se não houver.
- nota1 e nota2: deixe "" — só preencha se houver uma observação importante que não caiba em nenhum outro campo (nunca repita premissas).
- prazo: prazo de execução (número + unidade). validade_dias: validade da proposta em dias.
- pagamento: classifique em medicao (por medição), conclusao (após a conclusão), sinal_conclusao (sinal + saldo na conclusão), sinal_medicao (sinal + saldo por medição) ou outra (texto livre em "texto", ex.: "30% na mobilização e 70% na liberação, em até 30 dias após a aprovação da medição"). sinal_pct, dias (prazo para pagar) e periodo quando houver.
- itens: a planilha de preços no nosso padrão. Agrupe em etapas: a linha de etapa tem tipo "etapa", item "1", "2"… e descrição em poucas palavras, quantidade e valores 0. Os itens da etapa têm tipo "item", item "1.1", "1.2"…, descrição clara, unidade (m², m, un, vb, mês, diária, h, kg, m³…), quantidade, preço unitário e total. Se a proposta não tiver etapas, crie etapas lógicas. Use os preços que a proposta traz (finais, já com tudo); se um item não tiver preço, deixe 0. Nunca mostre margem de lucro, BDI ou impostos separados como item: se a proposta tiver linhas de BDI/lucro/impostos, distribua esse valor proporcionalmente nos preços unitários e avise em "alertas". Tabelas de preço por faixa para serviços futuros NÃO são itens: vão em secoes_depois.
- valor_total: o valor global da proposta (0 se não houver).
- composicao: o que é preciso para executar, para o CRM calcular o custo com a nossa base. Equipe: função, quantidade de pessoas e dias (0 = o período todo). Use, quando corresponder, exatamente os nomes de função da lista fornecida. Materiais e equipamentos: descrição (use o nome da lista de materiais quando for o mesmo item), unidade e quantidade. Terceiros e mobilização: descrição e valor só se a proposta disser o custo (senão 0). Dias úteis, sábados e domingos/feriados de trabalho pelo prazo e pelo cronograma (ex.: 1 mês de seg a sex ≈ 22 dias úteis); turno noturno só se a proposta disser. documentos: exigências documentais do cliente que estejam na lista de documentos (ex.: ASO, NR-35, PGR), com o nome exato da lista. tipo_cliente: um nome da lista de tipos de cliente, ou "". Se não houver informação para estimar algo, deixe vazio — não invente números sem base.
- os: detalhe da execução para a equipe (sai só na Ordem de Serviço, sem valores): condições do local, o que está incluído, o que NÃO está incluído, como deve ficar no final, quando parar e consultar o responsável, cuidados de segurança (EPI, NR, isolamento). "" quando a proposta não disser.
- figuras: cada foto, desenho, esquema, croqui, gráfico ou detalhe técnico em imagem que a proposta original traz (NÃO inclua logotipos, cabeçalhos, rodapés, marcas d'água, assinaturas, nem tabelas de texto — tabelas vão como texto nas seções). Em PDF: pagina (1 = primeira) e o retângulo da figura em PORCENTAGEM da página, medido a partir do canto superior esquerdo (x, y, largura, altura, de 0 a 100), com uma pequena folga em volta e incluindo a legenda/cotas que fazem parte do desenho; arquivo "". Em Word, a imagem aparece no texto como [imagem NOME]: informe arquivo = NOME e deixe pagina e o retângulo 0. legenda: curta e descritiva (ex.: "Seção típica do caminho com trincheiras de ancoragem"). secao: o título EXATO (o mesmo do "# ") da seção de secoes_antes ou secoes_depois onde a figura deve aparecer, ou "" para "Imagens de referência". Lista vazia se não houver figuras.
- alertas: avisos curtos para quem vai revisar (ex.: "a proposta original mostrava BDI de 25% — diluído nos preços", "item 2.3 sem preço", "a soma dos itens difere do valor global", "prazo não informado").

Escreva tudo em português do Brasil, sem emojis.

Responda SOMENTE com um objeto JSON válido (sem texto antes ou depois, sem comentários), com exatamente estes campos. Onde o modelo mostra opções separadas por " | ", escolha uma delas ("(vazio)" = string vazia ""):
` + JSON.stringify(modelo(SCHEMA), null, 1);

// ---------- v70: conversa ----------
const CAMPOS_CONVERSA = ["titulo", "objeto", "abertura", "secoes_antes", "escopo", "secoes_depois", "premissas", "exclusoes", "nota1", "nota2", "prazo", "validade_dias", "pagamento", "itens"];
const SISTEMA_CONVERSA = `Você trabalha no comercial do Grupo BVEK (Rio de Janeiro): Engekat Construções (EK — construção civil, projetos técnicos, drywall, steel frame, solda, caldeiraria, tubulação, alpinismo, pintura), Verde Brasilis (VB — áreas verdes, poda, remoção, reflorestamento, paisagismo, jardinagem, legalizações), BrasiLimp (BL — limpeza, conservação, manutenção, segurança) e Kat Corretora de Seguros (KS).

Você conversa com o administrador dentro do criador de propostas do CRM. Pode haver um documento anexado (proposta de terceiros, pedido do cliente, memorial, edital…) e sempre vem o estado atual da proposta que está sendo montada. Ajude a entender o documento, conferir a proposta, apontar lacunas e riscos e, quando ele pedir, alterar a proposta.

Regras:
- Responda em português do Brasil, direto e em linguagem simples, sem emojis. Quando citar o documento, diga onde está (página, item, seção) se der para saber. Não invente o que o documento não diz: se não estiver lá, diga.
- Só sugira mudanças na proposta quando o administrador pedir uma alteração (ou concordar com uma sugestão sua). Para perguntas, só responda e deixe "mudancas" vazio.
- Campos que você pode mudar: titulo, objeto, abertura, secoes_antes, escopo, secoes_depois, premissas, exclusoes, nota1, nota2, prazo, validade_dias, pagamento, itens. Coloque em "mudancas" SOMENTE os campos que mudam, já com o conteúdo final completo de cada um (o texto inteiro do escopo, a planilha inteira etc.), não só o trecho alterado.
- Formatação dos textos: parágrafo = linha comum; lista = linha começando com "• "; subtítulo = linha começando com "## "; negrito = **texto**; tabela = linhas "| a | b |" (a primeira é o cabeçalho). Em secoes_antes e secoes_depois cada seção começa com "# TÍTULO" (maiúsculas, sem número). O PDF tem, nesta ordem: abertura · objeto · secoes_antes · escopo · planilha · secoes_depois · equipe · premissas · exclusoes · condições comerciais.
- Cada informação vai para um campo só: escopo enxuto (o que fornecemos, 5 a 15 itens); especificações, método, comparativos, cronograma e SSMA nas seções técnicas; exclusões só em exclusoes; titulo é o objeto numa frase curta, sem o nome da nossa empresa e sem número de proposta.
- itens = planilha inteira: linhas de etapa com tipo "etapa", item "1", "2"…, quantidade e valores 0; itens com tipo "item", item "1.1", "1.2"…, unidade, quantidade, valor_unitario e valor_total.
- Preços: mantenha os preços que já estão na proposta. Não invente preço nem custo. Ao dividir ou juntar itens, redistribua o valor existente só se ele pedir, e avise na resposta. Nunca mostre margem de lucro, BDI ou impostos separados como item.
- A composição de preço (equipe, materiais, custos) vem só da base do CRM; você pode comentar, mas não altera.
- A carta de apresentação, condições gerais, seguros, tributos, assinaturas e aceite já são fixos no modelo: não coloque esses textos nos campos.

Responda SOMENTE com um objeto JSON válido, sem texto antes ou depois:
{"resposta": "sua resposta ao administrador (pode ter várias linhas)", "mudancas": {}}
Formato de cada campo em "mudancas" (inclua só os que mudam):
` + JSON.stringify(Object.fromEntries(CAMPOS_CONVERSA.map((k) => [k, modelo(SCHEMA.properties[k])])), null, 1);

// deno-lint-ignore no-explicit-any
async function conversar(client: Anthropic, p: any) {
  const msgs = (Array.isArray(p.mensagens) ? p.mensagens : [])
    // deno-lint-ignore no-explicit-any
    .map((m: any) => ({ role: m?.papel === "ia" ? "assistant" : "user", texto: String(m?.texto ?? "").slice(0, 20000) }))
    // deno-lint-ignore no-explicit-any
    .filter((m: any) => m.texto.trim()).slice(-30);
  while (msgs.length && msgs[0].role !== "user") msgs.shift();
  if (!msgs.length || msgs[msgs.length - 1].role !== "user") return json({ erro: "Escreva a mensagem." }, 400);

  const doc = p.documento && typeof p.documento === "object" ? p.documento : null;
  const pdf = doc && typeof doc.pdf_base64 === "string" ? doc.pdf_base64.replace(/\s+/g, "") : "";
  const texto = doc && typeof doc.texto === "string" ? doc.texto : "";
  if (pdf.length > 30 * 1024 * 1024) return json({ erro: "Documento grande demais (máx. ~20 MB)." }, 400);
  const nomeDoc = String((doc && doc.nome) || "").slice(0, 120);

  // deno-lint-ignore no-explicit-any
  const messages: any[] = [];
  msgs.forEach((m: { role: string; texto: string }, i: number) => {
    // deno-lint-ignore no-explicit-any
    const content: any[] = [];
    if (i === 0) {
      if (pdf) content.push({ type: "document", source: { type: "base64", media_type: "application/pdf", data: pdf }, title: nomeDoc || "documento", cache_control: { type: "ephemeral" } });
      else if (texto.trim()) content.push({ type: "text", text: `<documento arquivo="${nomeDoc}">\n${texto.slice(0, 400000)}\n</documento>`, cache_control: { type: "ephemeral" } });
      else content.push({ type: "text", text: "(nenhum documento anexado à conversa)" });
    }
    if (i === msgs.length - 1) {
      content.push({ type: "text", text: `<proposta_atual>\n${JSON.stringify(p.proposta || {}, null, 1).slice(0, 200000)}\n</proposta_atual>` });
    }
    content.push({ type: "text", text: m.texto });
    messages.push({ role: m.role, content: m.role === "assistant" ? m.texto : content });
  });

  // deno-lint-ignore no-explicit-any
  const params: any = {
    model: "claude-opus-5-5",
    max_tokens: 32000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    system: SISTEMA_CONVERSA,
    output_config: { effort: "medium" },
    messages,
  };
  const msg = await client.beta.messages.stream(params).finalMessage();
  if (msg.stop_reason === "refusal") return json({ erro: "A IA recusou responder. Reformule a mensagem." }, 422);
  if (msg.stop_reason === "max_tokens") return json({ erro: "A resposta ficou longa demais. Peça uma parte de cada vez." }, 422);
  // deno-lint-ignore no-explicit-any
  const t = (msg.content as any[]).filter((b) => b.type === "text").map((b) => b.text).join("\n").trim();
  if (!t) return json({ erro: "A IA não respondeu." }, 502);
  let resposta = t;
  // deno-lint-ignore no-explicit-any
  let mudancas: any = null;
  try {
    // deno-lint-ignore no-explicit-any
    const o: any = extrairJson(t);
    resposta = String(o.resposta ?? "").trim() || "Pronto.";
    if (o.mudancas && typeof o.mudancas === "object") {
      // deno-lint-ignore no-explicit-any
      const m: any = {};
      CAMPOS_CONVERSA.forEach((k) => { if (k in o.mudancas) m[k] = completar(SCHEMA.properties[k], o.mudancas[k]); });
      if (Object.keys(m).length) mudancas = m;
    }
  } catch (_) { /* veio texto solto: mostra como resposta */ }
  return json({ ok: true, resposta, mudancas, uso: msg.usage });
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
    if (!perfil || perfil.ativo === false || perfil.perfil !== "administrador") return json({ erro: "Só o Administrador usa propostas." }, 403);

    const chave = Deno.env.get("ANTHROPIC_API_KEY");
    if (!chave) return json({ erro: "Falta configurar a leitura por IA: cadastre o segredo ANTHROPIC_API_KEY nas Edge Functions do Supabase." }, 500);

    const p = await req.json().catch(() => ({}));
    if (p.modo === "conversa") return await conversar(new Anthropic({ apiKey: chave }), p);
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
      max_tokens: 64000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      system: SISTEMA,
      output_config: { effort: "medium" },
      messages: [{ role: "user", content: conteudo }],
    };
    const msg = await client.beta.messages.stream(params).finalMessage();
    if (msg.stop_reason === "refusal") return json({ erro: "A IA recusou ler este arquivo. Preencha à mão." }, 422);
    if (msg.stop_reason === "max_tokens") return json({ erro: "A proposta é longa demais para ler de uma vez. Envie só a parte técnica e comercial." }, 422);
    // deno-lint-ignore no-explicit-any
    const texto_ia = (msg.content as any[]).filter((b) => b.type === "text").map((b) => b.text).join("\n");
    if (!texto_ia.trim()) return json({ erro: "A IA não devolveu dados." }, 502);
    let dados;
    try { dados = completar(SCHEMA, extrairJson(texto_ia)); } catch (_) { return json({ erro: "A resposta da IA veio fora do formato. Tente de novo." }, 502); }
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
