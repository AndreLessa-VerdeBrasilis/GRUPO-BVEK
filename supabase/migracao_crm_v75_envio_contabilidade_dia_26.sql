-- CRM v75: envio mensal à contabilidade passa do dia 25 para o dia 26.
-- A folha (faltas/ponto) continua fechando no dia 25 (período 26 → 25);
-- só a data de envio muda, para o dia 25 ficar todo fechado antes de enviar.
-- No CRM: se o dia 26 cair em sábado, domingo ou feriado, o envio vai para o
-- próximo dia útil (nunca antes do dia 26).
-- Pode rodar mais de uma vez.

insert into public.rh_config (chave, valor) values ('dia_envio_contabilidade', '26')
on conflict (chave) do update set valor = '26', atualizado_em = now()
  where public.rh_config.valor is distinct from '26';

-- conferência: dia_envio_contabilidade deve ser 26 e dia_fechamento_ponto continua 25
select chave, valor, atualizado_em
  from public.rh_config
 where chave in ('dia_envio_contabilidade', 'dia_fechamento_ponto')
 order by chave;
