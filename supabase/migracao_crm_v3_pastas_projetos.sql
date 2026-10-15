-- =====================================================================
-- CRM Grupo BVEK — migração v3: pasta dos PROJETOS por empresa
-- Regra (15/10/2026): clientes ficam em BVEK/03_CLIENTES/C###_NOME;
-- projetos ficam na pasta da empresa executora:
--   EK -> BVEK/10_ENGEKAT/10.2_PROJETOS/C###-NNNN NOME
--   VB -> BVEK/20_VERDE BRASILIS/20.2_PROJETOS/C###-NNNN NOME
--   BL -> BVEK/30_BRASILIMP/30.2_PROJETOS/C###-NNNN NOME
-- Pode rodar mais de uma vez sem problema.
-- =====================================================================

-- 1. Função que monta o caminho da pasta do projeto
create or replace function public.pasta_projeto(p_empresa uuid, p_codigo text, p_nome text) returns text
language sql stable as $$
  select case e.sigla
           when 'EK' then 'BVEK/10_ENGEKAT/10.2_PROJETOS/'
           when 'VB' then 'BVEK/20_VERDE BRASILIS/20.2_PROJETOS/'
           when 'BL' then 'BVEK/30_BRASILIMP/30.2_PROJETOS/'
         end || p_codigo || ' ' || upper(trim(p_nome))
  from public.empresas e where e.id = p_empresa
$$;

-- 2. Criar projeto: agora exige a empresa executora
create or replace function public.criar_projeto(
  p_cliente uuid, p_nome text, p_empresa uuid default null, p_card uuid default null,
  p_local text default null, p_ano int default null, p_status text default 'Em andamento'
) returns public.projetos
language plpgsql as $$
declare v_cod text; v_seq int; v_codigo text; v_row public.projetos;
begin
  select codigo into v_cod from public.clientes where id = p_cliente;
  if v_cod is null then raise exception 'O cliente precisa ter código (C###) antes de criar o projeto.'; end if;
  if p_empresa is null then raise exception 'Escolha a empresa executora do projeto (a pasta fica na pasta da empresa).'; end if;
  v_seq := nextval('public.projetos_seq');
  v_codigo := v_cod || '-' || lpad(v_seq::text, 4, '0');
  insert into public.projetos (seq, codigo, cliente_id, card_id, empresa_id, nome, local, ano, status, pasta_rede)
  values (v_seq, v_codigo, p_cliente, p_card, p_empresa, upper(trim(p_nome)), p_local,
          coalesce(p_ano, extract(year from now())::int), coalesce(p_status, 'Em andamento'),
          public.pasta_projeto(p_empresa, v_codigo, p_nome))
  returning * into v_row;
  if p_card is not null then update public.cards set projeto_id = v_row.id where id = p_card; end if;
  return v_row;
end $$;

-- 3. Se a empresa do projeto mudar, o caminho da pasta acompanha
create or replace function public.trg_projeto_pasta() returns trigger
language plpgsql as $$
begin
  if new.empresa_id is distinct from old.empresa_id and new.empresa_id is not null then
    new.pasta_rede := public.pasta_projeto(new.empresa_id, new.codigo,
                        coalesce(nullif(regexp_replace(coalesce(old.pasta_rede,''), '^.*/' || old.codigo || ' ', ''), ''), new.nome));
  end if;
  return new;
end $$;
drop trigger if exists projeto_pasta on public.projetos;
create trigger projeto_pasta before update of empresa_id on public.projetos
  for each row execute function public.trg_projeto_pasta();

-- 4. Atualizar os projetos já cadastrados (pastas já movidas na rede em 15/10/2026)
update public.projetos p set pasta_rede = x.pasta
from (values
  ('C042-0002','BVEK/20_VERDE BRASILIS/20.2_PROJETOS/C042-0002 INFINEUM PODA DE ARVORES'),
  ('C079-0003','BVEK/20_VERDE BRASILIS/20.2_PROJETOS/C079-0003 SHELL LEVANTAMENTO ARBOREO'),
  ('C084-0004','BVEK/20_VERDE BRASILIS/20.2_PROJETOS/C084-0004 TECNOSONDA VALE'),
  ('C004-0005','BVEK/20_VERDE BRASILIS/20.2_PROJETOS/C004-0005 ALAMO TIM MOBILIZACAO SST'),
  ('C086-0006','BVEK/20_VERDE BRASILIS/20.2_PROJETOS/C086-0006 TIM SAO CRISTOVAO MOBILIZACAO SST'),
  ('C088-0007','BVEK/20_VERDE BRASILIS/20.2_PROJETOS/C088-0007 UNIMED MOBILIZACAO'),
  ('C091-0008','BVEK/20_VERDE BRASILIS/20.2_PROJETOS/C091-0008 VIBRA ROCAGEM'),
  ('C002-0009','BVEK/20_VERDE BRASILIS/20.2_PROJETOS/C002-0009 AFTON DEPOSITO PET'),
  ('C091-0010','BVEK/10_ENGEKAT/10.2_PROJETOS/C091-0010 VIBRA CALHAS RUFOS LINHA DE VIDA E ESCADAS'),
  ('C091-0011','BVEK/10_ENGEKAT/10.2_PROJETOS/C091-0011 VIBRA RESERVATORIOS 09-2025'),
  ('C009-0012','BVEK/10_ENGEKAT/10.2_PROJETOS/C009-0012 ARKEMA 2025-2026'),
  ('C040-0013','BVEK/10_ENGEKAT/10.2_PROJETOS/C040-0013 GW ENGENHARIA VIBRA')
) as x(codigo, pasta)
where p.codigo = x.codigo;

-- Conferência: deve listar os 13 projetos com o caminho novo (C073-0001 não tem pasta própria)
select codigo, pasta_rede from public.projetos order by seq;
