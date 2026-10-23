/* =====================================================================
   Grupo BVEK — Questionário de perfil comportamental (versão 1)
   Usado pela página do candidato (perfil.html) e pelo CRM (index.html),
   para as perguntas e a pontuação serem sempre as mesmas.

   Importante: é um questionário de AUTOAVALIAÇÃO para apoiar a entrevista.
   Não é teste psicológico (esses só podem ser aplicados por psicólogo,
   conforme o Conselho Federal de Psicologia). O parecer é do RH.

   Escala: 1 Discordo totalmente · 2 Discordo · 3 Em parte · 4 Concordo ·
           5 Concordo totalmente.   inv: true = frase invertida (6 - nota).
   Se mudar perguntas, crie a versão 2 (não altere a 1: as respostas já
   gravadas são lidas com ela).
   ===================================================================== */
(function (raiz) {
  const ESCALA = [
    [1, 'Discordo totalmente'], [2, 'Discordo'], [3, 'Em parte'], [4, 'Concordo'], [5, 'Concordo totalmente'],
  ];
  const DIMENSOES = [
    { id: 'equilibrio',   nome: 'Equilíbrio emocional',       desc: 'calma sob pressão, lidar com crítica e frustração' },
    { id: 'equipe',       nome: 'Relacionamento e equipe',     desc: 'colaboração, respeito e resolução de conflitos' },
    { id: 'responsabilidade', nome: 'Responsabilidade',        desc: 'pontualidade, cuidado, segurança e cumprir o combinado' },
    { id: 'comunicacao',  nome: 'Comunicação',                 desc: 'perguntar, avisar, explicar e ouvir' },
    { id: 'adaptacao',    nome: 'Adaptação a mudanças',        desc: 'flexibilidade de local, horário e forma de trabalho' },
    { id: 'iniciativa',   nome: 'Iniciativa e liderança',      desc: 'resolver sem esperar, sugerir melhorias, orientar' },
  ];
  const PERGUNTAS = [
    { id: 'p01', dim: 'equilibrio', txt: 'Mantenho a calma quando algo dá errado no serviço.' },
    { id: 'p02', dim: 'equipe', txt: 'Gosto de ajudar um colega, mesmo quando a tarefa não é minha.' },
    { id: 'p03', dim: 'responsabilidade', txt: 'Chego no horário combinado.' },
    { id: 'p04', dim: 'comunicacao', txt: 'Quando não entendo uma instrução, pergunto antes de fazer.' },
    { id: 'p05', dim: 'adaptacao', txt: 'Aprendo rápido quando mudam a forma de fazer um serviço.' },
    { id: 'p06', dim: 'iniciativa', txt: 'Quando vejo um problema, tento resolver sem esperar alguém mandar.' },
    { id: 'p07', dim: 'equilibrio', txt: 'Uma crítica ao meu trabalho me deixa abalado por muito tempo.', inv: true },
    { id: 'p08', dim: 'equipe', txt: 'Prefiro trabalhar sozinho a dividir tarefas com outras pessoas.', inv: true },
    { id: 'p09', dim: 'responsabilidade', txt: 'Termino o que começo, mesmo quando a tarefa é cansativa.' },
    { id: 'p10', dim: 'comunicacao', txt: 'Aviso com antecedência quando não vou conseguir cumprir algo.' },
    { id: 'p11', dim: 'adaptacao', txt: 'Fico muito incomodado quando o plano muda de última hora.', inv: true },
    { id: 'p12', dim: 'iniciativa', txt: 'Dou sugestões para melhorar a forma como o trabalho é feito.' },
    { id: 'p13', dim: 'equilibrio', txt: 'Consigo trabalhar bem mesmo com prazo apertado.' },
    { id: 'p14', dim: 'equipe', txt: 'Respeito opiniões diferentes da minha.' },
    { id: 'p15', dim: 'responsabilidade', txt: 'Cuido das ferramentas e equipamentos como se fossem meus.' },
    { id: 'p16', dim: 'comunicacao', txt: 'Tenho dificuldade em dizer o que penso.', inv: true },
    { id: 'p17', dim: 'adaptacao', txt: 'Topo trabalhar em locais e horários diferentes quando é preciso.' },
    { id: 'p18', dim: 'iniciativa', txt: 'Consigo orientar colegas que estão começando.' },
    { id: 'p19', dim: 'equilibrio', txt: 'Perco a paciência com facilidade.', inv: true },
    { id: 'p20', dim: 'equipe', txt: 'Quando há briga na equipe, procuro conversar para resolver.' },
    { id: 'p21', dim: 'responsabilidade', txt: 'Às vezes esqueço tarefas que me passaram.', inv: true },
    { id: 'p22', dim: 'comunicacao', txt: 'Escuto a pessoa até o fim antes de responder.' },
    { id: 'p23', dim: 'adaptacao', txt: 'Gosto de aprender coisas novas.' },
    { id: 'p24', dim: 'iniciativa', txt: 'Espero alguém me dizer o que fazer antes de agir.', inv: true },
    { id: 'p25', dim: 'equilibrio', txt: 'Quando estou com um problema pessoal, consigo me concentrar no trabalho.' },
    { id: 'p26', dim: 'equipe', txt: 'Tenho dificuldade em confiar no trabalho dos outros.', inv: true },
    { id: 'p27', dim: 'responsabilidade', txt: 'Sigo as regras de segurança mesmo quando ninguém está olhando.' },
    { id: 'p28', dim: 'comunicacao', txt: 'Consigo explicar as coisas de um jeito que os outros entendem.' },
    { id: 'p29', dim: 'adaptacao', txt: 'Prefiro fazer sempre do mesmo jeito.', inv: true },
    { id: 'p30', dim: 'iniciativa', txt: 'Assumo a responsabilidade quando erro, sem colocar a culpa em outros.' },
  ];
  const ABERTAS = [
    { id: 'a1', txt: 'Conte uma situação difícil que você viveu no trabalho e como resolveu.' },
    { id: 'a2', txt: 'O que faz você gostar de um trabalho? E o que faz você querer sair?' },
    { id: 'a3', txt: 'Como você reage quando um chefe ou cliente reclama do seu serviço?' },
    { id: 'a4', txt: 'Por que você quer trabalhar com a gente?' },
  ];

  // resultado: nota 0–100 por dimensão  →  { dims: [{id,nome,nota,nivel}], media, completas }
  function pontuar(respostas) {
    const r = (respostas && respostas.q) || {};
    let respondidas = 0;
    const dims = DIMENSOES.map((d) => {
      const vals = PERGUNTAS.filter((p) => p.dim === d.id)
        .map((p) => { const v = Number(r[p.id]); if (!(v >= 1 && v <= 5)) return null; respondidas++; return p.inv ? 6 - v : v; })
        .filter((v) => v != null);
      const media = vals.length ? vals.reduce((s, v) => s + v, 0) / vals.length : null;
      const nota = media == null ? null : Math.round(((media - 1) / 4) * 100);
      return { id: d.id, nome: d.nome, desc: d.desc, nota, nivel: nivel(nota) };
    });
    const validas = dims.filter((d) => d.nota != null);
    return {
      dims,
      media: validas.length ? Math.round(validas.reduce((s, d) => s + d.nota, 0) / validas.length) : null,
      completas: respondidas === PERGUNTAS.length,
      respondidas,
      // muita gente marca tudo 5: avisa quando as frases invertidas também receberam nota alta
      concordaComTudo: PERGUNTAS.filter((p) => p.inv && Number(r[p.id]) >= 4).length >= 4,
    };
  }
  function nivel(n) {
    if (n == null) return { k: 'sem', txt: 'sem resposta' };
    if (n >= 75) return { k: 'forte', txt: 'ponto forte' };
    if (n >= 50) return { k: 'adequado', txt: 'adequado' };
    return { k: 'atencao', txt: 'ponto de atenção' };
  }
  // texto inicial do parecer (o RH revisa e completa depois da entrevista)
  function resumo(respostas, primeiroNome) {
    const p = pontuar(respostas);
    if (p.media == null) return '';
    const fortes = p.dims.filter((d) => d.nivel.k === 'forte').map((d) => d.nome.toLowerCase());
    const atencao = p.dims.filter((d) => d.nivel.k === 'atencao').map((d) => d.nome.toLowerCase());
    const lista = (l) => l.length > 1 ? l.slice(0, -1).join(', ') + ' e ' + l[l.length - 1] : l[0];
    let t = `${primeiroNome || 'O candidato'} teve média ${p.media}/100 no questionário de autoavaliação.`;
    if (fortes.length) t += ` Destaques: ${lista(fortes)}.`;
    if (atencao.length) t += ` Pontos a investigar na entrevista: ${lista(atencao)}.`;
    if (!atencao.length) t += ' Nenhuma dimensão abaixo de 50.';
    if (p.concordaComTudo) t += ' Atenção: concordou também com várias frases negativas — as respostas podem estar pouco cuidadosas ou tendendo a agradar.';
    return t;
  }

  raiz.BVEK_QUESTIONARIO = { versao: 1, ESCALA, DIMENSOES, PERGUNTAS, ABERTAS, pontuar, resumo };
})(typeof window !== 'undefined' ? window : globalThis);
