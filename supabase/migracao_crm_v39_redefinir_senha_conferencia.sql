-- =====================================================================
-- CRM Grupo BVEK — migração v39
-- Redefinir senha (botão 🔑 do Administrador), versão mais segura:
--  - confirma o e-mail do login, se ainda não estava confirmado
--    (login sem e-mail confirmado é recusado pelo Supabase);
--  - depois de gravar, confere se a senha nova bate com o que ficou
--    guardado e avisa se não bater.
-- Pode rodar mais de uma vez. Nada é apagado.
-- =====================================================================
create or replace function public.bvek_redefinir_senha_usuario(p_usuario uuid, p_senha text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text;
  v_ok    boolean;
begin
  if not public.bvek_pode('{administrador}') then
    raise exception 'Só o Administrador pode redefinir a senha de outra pessoa.';
  end if;
  if length(coalesce(p_senha, '')) < 8 then
    raise exception 'A senha provisória precisa ter pelo menos 8 caracteres.';
  end if;
  select u.email into v_email from auth.users u where u.id = p_usuario;
  if v_email is null then raise exception 'Login não encontrado.'; end if;
  update auth.users
     set encrypted_password = extensions.crypt(p_senha, extensions.gen_salt('bf', 10)),
         email_confirmed_at = coalesce(email_confirmed_at, now()),
         updated_at = now()
   where id = p_usuario;
  select u.encrypted_password = extensions.crypt(p_senha, u.encrypted_password) into v_ok
    from auth.users u where u.id = p_usuario;
  if not coalesce(v_ok, false) then
    raise exception 'A senha não foi gravada corretamente. Avise o suporte.';
  end if;
  return v_email;
end $$;

revoke all on function public.bvek_redefinir_senha_usuario(uuid, text) from public, anon;
grant execute on function public.bvek_redefinir_senha_usuario(uuid, text) to authenticated;

-- Conferência: os últimos logins alterados (tipo_senha deve começar com $2)
select email, updated_at, email_confirmed_at is not null as email_confirmado,
       banned_until, left(encrypted_password, 4) as tipo_senha
  from auth.users order by updated_at desc limit 5;
