/* =====================================================================
   Grupo BVEK — Triagem inicial dos currículos (versão 1)
   Usado pela página do candidato (triagem.html) e pelo CRM (index.html),
   para as perguntas e os textos serem sempre os mesmos.

   É uma etapa rápida, por mensagem, ANTES da entrevista presencial.
   Se mudar as perguntas, crie a versão 2 (não altere a 1: as respostas já
   gravadas são lidas com ela).

   Formato das respostas gravadas (triagens.respostas):
   { versao, local:{bairro,cidade}, disponibilidade,
     experiencias:[{empresa,cargo,periodo}], experiencias_obs,
     outras:{fez:'sim'|'nao', atividades, tempo, referencia},
     audios:{disponibilidade:[caminho], experiencias:[…], outras:[…]},
     enviado_em }
   ===================================================================== */
(function (raiz) {
  const PERGUNTAS = [
    { id: 'local',           txt: 'Em qual bairro e cidade você reside?' },
    { id: 'disponibilidade', txt: 'Qual é a sua disponibilidade de horários?' },
    { id: 'experiencias',    txt: 'Quais foram suas experiências mais recentes na função? Se possível, informe o nome da empresa, o cargo exercido e o período de atuação.' },
    { id: 'outras',          txt: 'Além das experiências com registro em carteira, você já desempenhou essa função de outras formas, como trabalho autônomo, prestação de serviços, freelances, trabalho informal, voluntariado ou atuação em negócio familiar?',
      complemento: 'Em caso positivo, gostaríamos que nos informasse brevemente quais atividades realizava, por quanto tempo e se há alguém que possa recomendar ou confirmar sua experiência profissional, caso seja necessário.' },
  ];
  const ROTULO = Object.fromEntries(PERGUNTAS.map(p => [p.id, p.txt]));

  // vaga em MAIÚSCULAS (como fica no cadastro) vira minúscula no meio da frase
  const oportunidade = cargo => { const c = String(cargo || '').trim(); return c ? `a oportunidade de ${c === c.toUpperCase() ? c.toLowerCase() : c}` : 'uma oportunidade no Grupo BVEK'; };
  // abertura (a mesma na página e na mensagem do WhatsApp/e-mail)
  function abertura(cargo, indicacao) {
    return `${indicacao ? 'Recebemos a sua indicação' : 'Recebemos seu currículo'} para ${oportunidade(cargo)} e gostaríamos de conhecer um pouco mais sobre sua trajetória profissional. ` +
      'Esta é uma etapa inicial de triagem, realizada de forma rápida e por mensagem, e não substitui a entrevista presencial, ' +
      'que será agendada caso seu perfil avance para a próxima fase do processo seletivo.';
  }
  const primeiroNome = n => { const p = String(n || '').trim().split(/\s+/)[0] || ''; return p ? p.charAt(0).toUpperCase() + p.slice(1).toLowerCase() : ''; };

  // mensagem com o link (o candidato responde na página)
  function mensagemLink(nome, cargo, indicacao, url) {
    const n = primeiroNome(nome);
    return `Olá${n ? ', ' + n : ''}! Aqui é do RH do Grupo BVEK.\n\n${abertura(cargo, indicacao)}\n\n` +
      `Para darmos continuidade à avaliação, pedimos, por gentileza, que responda a algumas perguntas rápidas por este link (pelo celular, leva poucos minutos; se preferir, você também poderá responder por áudio):\n${url}`;
  }
  // mensagem com as perguntas escritas (para quem vai responder direto na conversa)
  function mensagemPerguntas(nome, cargo, indicacao) {
    const n = primeiroNome(nome);
    return `Olá${n ? ', ' + n : ''}! Aqui é do RH do Grupo BVEK.\n\n${abertura(cargo, indicacao)}\n\n` +
      'Para darmos continuidade à avaliação, pedimos, por gentileza, que nos informe:\n\n' +
      PERGUNTAS.map(p => `• ${p.txt}${p.complemento ? '\n' + p.complemento : ''}`).join('\n') +
      '\n\nSe preferir, você também poderá responder por áudio.';
  }

  // a resposta tem conteúdo? (texto ou áudio)
  const temAudio = (r, id) => !!(r && r.audios && Array.isArray(r.audios[id]) && r.audios[id].length);
  function respondida(r, id) {
    if (!r) return false;
    if (temAudio(r, id)) return true;
    if (id === 'local') return !!((r.local && (r.local.bairro || r.local.cidade)));
    if (id === 'disponibilidade') return !!String(r.disponibilidade || '').trim();
    if (id === 'experiencias') return (r.experiencias || []).some(e => e.empresa || e.cargo || e.periodo) || !!String(r.experiencias_obs || '').trim();
    if (id === 'outras') return !!(r.outras && r.outras.fez);
    return false;
  }

  raiz.BVEK_TRIAGEM = { versao: 1, PERGUNTAS, ROTULO, abertura, mensagemLink, mensagemPerguntas, primeiroNome, respondida, temAudio, MAX_EXPERIENCIAS: 5 };
})(typeof window !== 'undefined' ? window : globalThis);
