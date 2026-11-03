-- =====================================================================
-- CRM Grupo BVEK — migração v38
--  1. bvek_redefinir_senha_usuario(usuario, senha): o Administrador
--     coloca uma senha provisória nova em QUALQUER login (e-mail ou CPF).
--     Ninguém vê a senha antiga — ela é só substituída.
--  2. saidas.escritorio: compra do escritório (sem cliente/projeto).
-- Pode rodar mais de uma vez. Nada é apagado.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. REDEFINIR SENHA DE QUALQUER LOGIN (só administrador)
-- ---------------------------------------------------------------------
create or replace function public.bvek_redefinir_senha_usuario(p_usuario uuid, p_senha text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text;
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
     set encrypted_password = extensions.crypt(p_senha, extensions.gen_salt('bf')),
         updated_at = now()
   where id = p_usuario;
  return v_email;
end $$;

revoke all on function public.bvek_redefinir_senha_usuario(uuid, text) from public, anon;
grant execute on function public.bvek_redefinir_senha_usuario(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 2. SAÍDAS: compra do escritório
-- ---------------------------------------------------------------------
alter table public.saidas add column if not exists escritorio boolean not null default false;

commit;

-- Conferência: as duas linhas devem aparecer
select 'funcao bvek_redefinir_senha_usuario' as item, count(*) as ok
  from pg_proc where proname = 'bvek_redefinir_senha_usuario'
union all
select 'coluna saidas.escritorio', count(*)
  from information_schema.columns where table_schema = 'public' and table_name = 'saidas' and column_name = 'escritorio';
