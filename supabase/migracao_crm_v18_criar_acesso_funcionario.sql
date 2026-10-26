-- =====================================================================
-- CRM Grupo BVEK — migração v18 (26/10/2026)
-- Criar o acesso dos intermitentes direto pelo CRM (aba Usuários)
--
--  1. bvek_criar_acesso_funcionario(funcionario, senha)
--       cria o login CPF@funcionario.bvek.com.br já confirmado, com a senha
--       provisória digitada pelo administrador na tela, e já deixa o perfil
--       como "Funcionário (só contracheque)". Se o login já existir, só
--       acerta o perfil e reativa (não troca a senha).
--  2. bvek_nova_senha_funcionario(funcionario, senha)
--       define uma nova senha provisória (o login por CPF não tem e-mail
--       de verdade, então "esqueci a senha" é feito pelo administrador).
--
-- Só o Administrador consegue usar as duas funções (conferido no banco).
-- A senha não fica gravada em nenhum arquivo: é digitada na tela do CRM
-- e guardada só criptografada pelo próprio Supabase.
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

create or replace function public.bvek_criar_acesso_funcionario(p_funcionario uuid, p_senha text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cpf   text;
  v_nome  text;
  v_email text;
  v_uid   uuid;
begin
  if not public.bvek_pode('{administrador}') then
    raise exception 'Só o Administrador pode criar acessos.';
  end if;
  select regexp_replace(coalesce(cpf, ''), '\D', '', 'g'), nome
    into v_cpf, v_nome
    from public.funcionarios where id = p_funcionario;
  if v_nome is null then raise exception 'Funcionário não encontrado.'; end if;
  if length(v_cpf) <> 11 then
    raise exception 'Cadastre o CPF de % na ficha antes de criar o acesso.', v_nome;
  end if;
  v_email := v_cpf || '@funcionario.bvek.com.br';

  select id into v_uid from auth.users where lower(email) = v_email;

  if v_uid is null then
    if length(coalesce(p_senha, '')) < 8 then
      raise exception 'A senha provisória precisa ter pelo menos 8 caracteres.';
    end if;
    v_uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                            email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token, recovery_token,
                            email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
            v_email, extensions.crypt(p_senha, extensions.gen_salt('bf')),
            now(), '{"provider":"email","providers":["email"]}'::jsonb,
            jsonb_build_object('nome', v_nome),
            now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider,
                                 last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_uid, v_uid::text,
            jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true),
            'email', now(), now(), now());
  end if;

  -- o gatilho da v11 cria o perfil como "pendente"; aqui já libera
  insert into public.perfis (id, email, nome, perfil, ativo)
  values (v_uid, v_email, v_nome, 'funcionario', true)
  on conflict (id) do update
     set perfil = 'funcionario', ativo = true,
         nome = coalesce(public.perfis.nome, excluded.nome),
         email = excluded.email
   where public.perfis.perfil in ('pendente', 'funcionario');

  return v_email;
end $$;

create or replace function public.bvek_nova_senha_funcionario(p_funcionario uuid, p_senha text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cpf   text;
  v_email text;
  v_uid   uuid;
begin
  if not public.bvek_pode('{administrador}') then
    raise exception 'Só o Administrador pode trocar a senha de outra pessoa.';
  end if;
  if length(coalesce(p_senha, '')) < 8 then
    raise exception 'A senha provisória precisa ter pelo menos 8 caracteres.';
  end if;
  select regexp_replace(coalesce(cpf, ''), '\D', '', 'g') into v_cpf
    from public.funcionarios where id = p_funcionario;
  if length(coalesce(v_cpf, '')) <> 11 then raise exception 'Funcionário sem CPF válido.'; end if;
  v_email := v_cpf || '@funcionario.bvek.com.br';
  select u.id into v_uid from auth.users u
    join public.perfis p on p.id = u.id and p.perfil = 'funcionario'
   where lower(u.email) = v_email;
  if v_uid is null then raise exception 'Este funcionário ainda não tem acesso criado.'; end if;
  update auth.users
     set encrypted_password = extensions.crypt(p_senha, extensions.gen_salt('bf')),
         updated_at = now()
   where id = v_uid;
  return v_email;
end $$;

revoke all on function public.bvek_criar_acesso_funcionario(uuid, text) from public, anon;
revoke all on function public.bvek_nova_senha_funcionario(uuid, text)   from public, anon;
grant execute on function public.bvek_criar_acesso_funcionario(uuid, text) to authenticated;
grant execute on function public.bvek_nova_senha_funcionario(uuid, text)   to authenticated;

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from pg_proc where proname in
         ('bvek_criar_acesso_funcionario','bvek_nova_senha_funcionario'))   as funcoes_novas_deve_ser_2;

-- Intermitentes: CPF e se já têm acesso
select f.nome,
       f.cpf,
       case when length(regexp_replace(coalesce(f.cpf, ''), '\D', '', 'g')) <> 11 then '⚠ falta CPF na ficha'
            when p.id is not null then 'acesso criado (' || p.perfil || ')'
            else 'sem acesso — criar na aba Usuários' end                  as situacao
  from public.funcionarios f
  join public.funcionario_rh r on r.funcionario_id = f.id and r.tipo_contrato = 'intermitente'
  left join auth.users u on lower(u.email) = regexp_replace(coalesce(f.cpf, ''), '\D', '', 'g') || '@funcionario.bvek.com.br'
  left join public.perfis p on p.id = u.id
 where f.ativo
 order by f.nome;
