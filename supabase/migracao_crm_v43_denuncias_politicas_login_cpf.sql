-- =====================================================================
-- CRM Grupo BVEK — migração v43: canal de denúncias e políticas para o
-- login por CPF (perfil Funcionário)
-- ---------------------------------------------------------------------
-- Na v42 as funções novas conferiam o login com bvek_ativo(), que desde a
-- v17 deixa o perfil Funcionário de fora — por isso a denúncia dava
-- "Sem acesso". Agora aceitam qualquer login liberado (inclusive Funcionário).
-- Nada é apagado. Pode rodar mais de uma vez.
-- =====================================================================

create or replace function public.bvek_denuncia_enviar(p_categoria text, p_descricao text, p_local text, p_quando text, p_envolvidos text)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare prot text; tent integer := 0;
begin
  if public.bvek_perfil() is null then raise exception 'Sem acesso.'; end if;
  if coalesce(trim(p_descricao), '') = '' or length(trim(p_descricao)) < 10 then raise exception 'Descreva o que aconteceu.'; end if;
  loop
    tent := tent + 1;
    prot := 'DEN-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.denuncias where protocolo = prot) or tent > 5;
  end loop;
  insert into public.denuncias (protocolo, categoria, descricao, local, quando, envolvidos)
  values (prot, left(coalesce(nullif(trim(p_categoria), ''), 'Outro'), 80), left(trim(p_descricao), 8000),
          left(nullif(trim(p_local), ''), 300), left(nullif(trim(p_quando), ''), 200), left(nullif(trim(p_envolvidos), ''), 1000));
  return prot;
end $$;

create or replace function public.bvek_denuncia_consultar(p_protocolo text)
returns table (protocolo text, categoria text, recebida_em date, situacao text, resposta text, respondida_em date)
language sql stable security definer set search_path = public as $$
  select d.protocolo, d.categoria, d.recebida_em, d.situacao, d.resposta, d.respondida_em
    from public.denuncias d
   where public.bvek_perfil() is not null
     and d.protocolo = upper(trim(p_protocolo))
$$;

create or replace function public.bvek_politicas_publicadas()
returns table (id uuid, titulo text, conteudo text, link text, atualizado_em timestamptz)
language sql stable security definer set search_path = public as $$
  select p.id, p.titulo, p.conteudo, p.link, p.atualizado_em
    from public.politicas p
   where public.bvek_perfil() is not null and p.publicada
   order by p.ordem, p.titulo
$$;
revoke all on function public.bvek_denuncia_enviar(text, text, text, text, text) from public, anon;
revoke all on function public.bvek_denuncia_consultar(text)                      from public, anon;
revoke all on function public.bvek_politicas_publicadas()                        from public, anon;
grant execute on function public.bvek_denuncia_enviar(text, text, text, text, text) to authenticated;
grant execute on function public.bvek_denuncia_consultar(text)                      to authenticated;
grant execute on function public.bvek_politicas_publicadas()                        to authenticated;

-- Conferência: as 3 funções devem aparecer com "corrigida = true"
select proname as funcao, (prosrc not like '%bvek_ativo%') as corrigida
  from pg_proc
 where pronamespace = 'public'::regnamespace
   and proname in ('bvek_denuncia_enviar','bvek_denuncia_consultar','bvek_politicas_publicadas')
 order by 1;
