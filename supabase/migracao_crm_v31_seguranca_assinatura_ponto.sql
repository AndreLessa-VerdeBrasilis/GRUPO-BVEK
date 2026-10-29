-- =====================================================================
-- CRM Grupo BVEK — migração v31 (29/10/2026)
-- Mais segurança jurídica na assinatura eletrônica do ponto
--
--  1. Senha pessoal obrigatória: no 1º acesso por CPF o funcionário cria a
--     própria senha (o RH deixa de saber a senha) e aceita o termo de uso
--     da assinatura eletrônica. Quando o administrador define uma senha
--     provisória nova, a troca volta a ser obrigatória.
--  2. Assinaturas do ponto não podem ser apagadas nem alteradas por
--     ninguém (nem pelo administrador) — trava no próprio banco.
--  3. Cópia do espelho assinado: guarda para qual e-mail e quando foi.
--  4. Ficha do funcionário: data em que o termo de adesão em papel
--     voltou assinado.
--
-- Precisa da v18 e da v30 já rodadas.
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. SENHA PESSOAL E ACEITE DO TERMO
-- ---------------------------------------------------------------------
alter table public.perfis add column if not exists senha_definida_em timestamptz;  -- vazio = ainda usa senha provisória
alter table public.perfis add column if not exists termo_aceito_em   timestamptz;
alter table public.perfis add column if not exists termo_versao      text;
alter table public.funcionario_rh add column if not exists termo_assinatura_em date; -- termo em papel devolvido assinado

-- o próprio funcionário registra que criou a senha (e, se for o caso, aceitou o termo)
create or replace function public.bvek_primeiro_acesso_concluido(p_termo_versao text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sem login.'; end if;
  update public.perfis
     set senha_definida_em = now(),
         termo_aceito_em   = case when p_termo_versao is not null then now() else termo_aceito_em end,
         termo_versao      = coalesce(p_termo_versao, termo_versao)
   where id = auth.uid();
end $$;

-- para o RH: quem já criou a senha e aceitou o termo
create or replace function public.bvek_termos_funcionarios()
returns table (funcionario_id uuid, senha_definida_em timestamptz, termo_aceito_em timestamptz, termo_versao text)
language sql stable security definer set search_path = public as $$
  select f.id, p.senha_definida_em, p.termo_aceito_em, p.termo_versao
    from public.funcionarios f
    join auth.users u on lower(u.email) = regexp_replace(coalesce(f.cpf, ''), '\D', '', 'g') || '@funcionario.bvek.com.br'
    join public.perfis p on p.id = u.id
   where public.bvek_pode('{administrador,administrativo,contabilidade}')
$$;

-- senha provisória nova (administrador) → o funcionário terá de trocar de novo
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
  update public.perfis set senha_definida_em = null where id = v_uid;   -- v31
  return v_email;
end $$;

revoke all on function public.bvek_primeiro_acesso_concluido(text) from public, anon;
revoke all on function public.bvek_termos_funcionarios()           from public, anon;
grant execute on function public.bvek_primeiro_acesso_concluido(text) to authenticated;
grant execute on function public.bvek_termos_funcionarios()           to authenticated;

-- ---------------------------------------------------------------------
-- 2. ASSINATURAS DO PONTO: ninguém apaga nem altera
-- ---------------------------------------------------------------------
alter table public.ponto_assinaturas add column if not exists copia_enviada_para text;
alter table public.ponto_assinaturas add column if not exists copia_enviada_em   timestamptz;

create or replace function public.bvek_trava_assinatura_ponto() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Assinaturas do ponto não podem ser apagadas (registro com valor de prova).';
  end if;
  -- única mudança permitida: anotar a cópia enviada por e-mail
  if (to_jsonb(new) - 'copia_enviada_para' - 'copia_enviada_em') <> (to_jsonb(old) - 'copia_enviada_para' - 'copia_enviada_em') then
    raise exception 'Assinaturas do ponto não podem ser alteradas (registro com valor de prova).';
  end if;
  return new;
end $$;
drop trigger if exists bvek_trava_assinatura_ponto on public.ponto_assinaturas;
create trigger bvek_trava_assinatura_ponto before update or delete on public.ponto_assinaturas
  for each row execute function public.bvek_trava_assinatura_ponto();

drop policy if exists bvek_apagar  on public.ponto_assinaturas;
drop policy if exists bvek_alterar on public.ponto_assinaturas;
revoke update, delete on public.ponto_assinaturas from authenticated;

-- o funcionário consulta a própria assinatura completa (para o comprovante)
create or replace function public.bvek_minha_assinatura_ponto(p_competencia date)
returns setof public.ponto_assinaturas
language sql stable security definer set search_path = public as $$
  select a.* from public.ponto_assinaturas a
   where a.funcionario_id = public.bvek_meu_funcionario_id()
     and a.competencia = date_trunc('month', p_competencia)::date
   order by a.assinado_em desc
   limit 1
$$;
revoke all on function public.bvek_minha_assinatura_ponto(date) from public, anon;
grant execute on function public.bvek_minha_assinatura_ponto(date) to authenticated;

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'perfis'
         and column_name in ('senha_definida_em','termo_aceito_em','termo_versao'))                as colunas_perfis_deve_ser_3,
       (select count(*) from pg_trigger where tgname = 'bvek_trava_assinatura_ponto')               as trava_deve_ser_1,
       (select count(*) from pg_policies where schemaname = 'public' and tablename = 'ponto_assinaturas'
         and policyname in ('bvek_apagar','bvek_alterar'))                                          as regras_apagar_deve_ser_0,
       (select count(*) from public.perfis where perfil = 'funcionario' and senha_definida_em is null) as funcionarios_que_vao_criar_senha;
