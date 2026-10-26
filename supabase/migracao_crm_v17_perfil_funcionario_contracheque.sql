-- =====================================================================
-- CRM Grupo BVEK — migração v17 (26/10/2026)
-- Perfil "Funcionário (só contracheque)" — pensado para os intermitentes
--
--  1. Novo perfil 'funcionario' na tabela perfis.
--  2. O login desse perfil é o CPF: no Supabase o usuário é criado com o
--     e-mail  <CPF só números>@funcionario.bvek.com.br  (ex.:
--     12345678900@funcionario.bvek.com.br). Na tela de login a pessoa
--     digita só o CPF e a senha.
--  3. Esse perfil NÃO lê nenhuma tabela do CRM (funil, clientes, RH,
--     documentos...). bvek_ativo() passa a ser falso para ele, e ele não
--     está em nenhuma lista de bvek_pode(). Bloqueio feito no banco.
--  4. Ele vê SOMENTE os contracheques dos funcionários cujo CPF é o mesmo
--     do login (todos os meses guardados), por duas funções novas:
--       bvek_meus_contracheques()        → lista dos contracheques
--       bvek_contracheque_meu(caminho)   → libera abrir o PDF no bucket "rh"
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. PERFIL NOVO
-- ---------------------------------------------------------------------
alter table public.perfis drop constraint if exists perfis_perfil_chk;
alter table public.perfis add constraint perfis_perfil_chk
  check (perfil in ('pendente','administrador','comercial','administrativo','consulta','contabilidade','funcionario'));

-- ---------------------------------------------------------------------
-- 2. "Ativo no CRM" não vale para o perfil funcionário
--    (as tabelas que liberam leitura com bvek_ativo() ficam fechadas para ele)
-- ---------------------------------------------------------------------
create or replace function public.bvek_ativo() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.bvek_perfil() <> 'funcionario', false)
$$;
grant execute on function public.bvek_ativo() to authenticated;

-- ---------------------------------------------------------------------
-- 3. CPF do login (só para o perfil funcionário ativo)
--    e-mail 12345678900@funcionario.bvek.com.br  →  '12345678900'
-- ---------------------------------------------------------------------
create or replace function public.bvek_meu_cpf() returns text
language sql stable security definer set search_path = public as $$
  select split_part(lower(u.email), '@', 1)
    from auth.users u
    join public.perfis p on p.id = u.id
   where u.id = auth.uid()
     and p.perfil = 'funcionario' and p.ativo
     and split_part(lower(u.email), '@', 2) = 'funcionario.bvek.com.br'
     and split_part(u.email, '@', 1) ~ '^[0-9]{11}$'
$$;

-- Contracheques do CPF do login (todos os meses guardados)
create or replace function public.bvek_meus_contracheques()
returns table (id uuid, competencia date, arquivo text, arquivo_nome text,
               paginas integer, funcionario_nome text, cargo text, empresa text)
language sql stable security definer set search_path = public as $$
  select c.id, c.competencia, c.arquivo, c.arquivo_nome, c.paginas,
         f.nome, f.cargo, e.nome
    from public.contracheques c
    join public.funcionarios f on f.id = c.funcionario_id
    left join public.empresas e on e.id = f.empresa_id
   where public.bvek_meu_cpf() is not null
     and regexp_replace(coalesce(f.cpf, ''), '\D', '', 'g') = public.bvek_meu_cpf()
   order by c.competencia desc
$$;

-- Nome do funcionário do login (para o cabeçalho da tela)
create or replace function public.bvek_meu_nome_funcionario() returns text
language sql stable security definer set search_path = public as $$
  select f.nome from public.funcionarios f
   where public.bvek_meu_cpf() is not null
     and regexp_replace(coalesce(f.cpf, ''), '\D', '', 'g') = public.bvek_meu_cpf()
   order by f.ativo desc, f.criado_em desc
   limit 1
$$;

-- O arquivo pedido é um contracheque do CPF do login?
create or replace function public.bvek_contracheque_meu(p_caminho text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.contracheques c
      join public.funcionarios f on f.id = c.funcionario_id
     where c.arquivo = p_caminho
       and public.bvek_meu_cpf() is not null
       and regexp_replace(coalesce(f.cpf, ''), '\D', '', 'g') = public.bvek_meu_cpf())
$$;

revoke all on function public.bvek_meu_cpf()                from public, anon;
revoke all on function public.bvek_meus_contracheques()     from public, anon;
revoke all on function public.bvek_meu_nome_funcionario()   from public, anon;
revoke all on function public.bvek_contracheque_meu(text)   from public, anon;
grant execute on function public.bvek_meu_cpf()              to authenticated;
grant execute on function public.bvek_meus_contracheques()   to authenticated;
grant execute on function public.bvek_meu_nome_funcionario() to authenticated;
grant execute on function public.bvek_contracheque_meu(text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. ARQUIVO: o funcionário abre só o PDF do próprio contracheque
--    (a regra rh_ler da v14 continua valendo para os outros perfis)
-- ---------------------------------------------------------------------
drop policy if exists rh_ler_proprio_contracheque on storage.objects;
create policy rh_ler_proprio_contracheque on storage.objects for select to authenticated
  using (bucket_id = 'rh'
         and (storage.foldername(name))[1] = 'contracheques'
         and public.bvek_contracheque_meu(name));

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from pg_constraint where conname = 'perfis_perfil_chk'
         and pg_get_constraintdef(oid) like '%funcionario%')                           as perfil_funcionario_ok_deve_ser_1,
       (select count(*) from pg_proc where proname in ('bvek_meu_cpf','bvek_meus_contracheques',
         'bvek_meu_nome_funcionario','bvek_contracheque_meu'))                          as funcoes_novas_deve_ser_4,
       (select count(*) from pg_policies where schemaname = 'storage'
         and policyname = 'rh_ler_proprio_contracheque')                               as regra_arquivo_deve_ser_1,
       (select count(*) from public.funcionarios
         where length(regexp_replace(coalesce(cpf, ''), '\D', '', 'g')) <> 11)          as funcionarios_sem_cpf_valido;

-- Funcionários ativos, CPF e o e-mail de login que cada um usaria
select f.nome,
       f.cpf,
       case when length(regexp_replace(coalesce(f.cpf, ''), '\D', '', 'g')) = 11
            then regexp_replace(f.cpf, '\D', '', 'g') || '@funcionario.bvek.com.br'
            else '⚠ cadastre o CPF na ficha' end                                        as email_do_login,
       (select count(*) from public.contracheques c where c.funcionario_id = f.id)     as contracheques_guardados
  from public.funcionarios f
 where f.ativo
 order by f.nome;
