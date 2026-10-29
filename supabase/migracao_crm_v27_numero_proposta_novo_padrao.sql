-- =====================================================================
-- CRM Grupo BVEK — migração v27 (29/10/2026)
-- Número das propostas no padrão novo: C###-NNNN-PRP-SSSS_RXX
--
-- Decisões do André (29/10/2026):
--   - SSSS = sequência ÚNICA do grupo inteiro (não por cliente);
--   - a próxima proposta nova é a 0020 (a da Vibra foi a 0019);
--   - as propostas antigas (ex.: VB001-0626) são RENUMERADAS;
--   - quando o projeto C###-NNNN é criado, o 0000 vira o NNNN do projeto.
--
-- O que esta migração faz:
--  1. cards.numero_proposta_antigo: guarda o número antigo (nada se perde).
--  2. Renumera as propostas antigas em ordem de criação (0001, 0002…),
--     pulando números já usados no padrão novo. As versões de uma mesma
--     proposta ficam com o mesmo número (a revisão _R00, _R01… é a versão).
--  3. gerar_numero_proposta_grupo(cliente): número das propostas novas.
--     Começa em 0020 — ou depois do maior número já usado, se for maior.
--  4. Gatilho: se o cliente da proposta mudar, o C### acompanha; quando o
--     projeto é criado (ou ligado), o 0000 vira o NNNN do projeto, em
--     todas as versões da proposta.
--
-- Atenção: PDFs, arquivos e pastas da rede que usam o número antigo NÃO
-- mudam sozinhos. A conferência no fim lista "antigo → novo".
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez: só renumera o que ainda está no padrão antigo.
-- =====================================================================

begin;

alter table public.cards add column if not exists numero_proposta_antigo text;

create table if not exists public.bvek_sequencias (
  nome   text primary key,
  ultimo integer not null default 0
);
alter table public.bvek_sequencias enable row level security;
drop policy if exists bvek_ler on public.bvek_sequencias;
create policy bvek_ler on public.bvek_sequencias for select to authenticated using (public.bvek_ativo());
grant select on public.bvek_sequencias to authenticated;

-- NNNN do projeto ligado a qualquer versão da proposta (0000 se não houver)
create or replace function public.bvek_nnnn_projeto_familia(p_raiz uuid, p_projeto uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select split_part(p.codigo, '-', 2) from public.projetos p
      where p.id = p_projeto and p.codigo ~ '^C[0-9]+-[0-9]{4}$'),
    (select split_part(p.codigo, '-', 2)
       from public.cards f
       join public.projetos p on p.id = f.projeto_id or p.card_id = f.id
      where coalesce(f.card_pai_id, f.id) = p_raiz and p.codigo ~ '^C[0-9]+-[0-9]{4}$'
      order by p.seq limit 1),
    '0000')
$$;

-- antes de gravar: mantém C### e NNNN do número coerentes com cliente e projeto
create or replace function public.bvek_cards_numero() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_cli text;
begin
  if new.numero_proposta is null or new.numero_proposta !~ '^C[0-9]{3,}-[0-9]{4}-PRP-[0-9]{4}$' then return new; end if;
  if tg_op = 'UPDATE' and new.cliente_id is not distinct from old.cliente_id
     and new.projeto_id is not distinct from old.projeto_id
     and new.numero_proposta = old.numero_proposta then return new; end if;
  select codigo into v_cli from public.clientes where id = new.cliente_id and codigo ~ '^C[0-9]{3,}$';
  new.numero_proposta := coalesce(v_cli, split_part(new.numero_proposta, '-', 1)) || '-'
    || public.bvek_nnnn_projeto_familia(coalesce(new.card_pai_id, new.id), new.projeto_id)
    || '-PRP-' || split_part(new.numero_proposta, '-PRP-', 2);
  return new;
end $$;
drop trigger if exists cards_numero on public.cards;
create trigger cards_numero before insert or update on public.cards
  for each row execute function public.bvek_cards_numero();

-- depois de gravar: as outras versões da mesma proposta recebem o mesmo número
create or replace function public.bvek_cards_numero_familia() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;
  if new.numero_proposta ~ '^C[0-9]{3,}-[0-9]{4}-PRP-[0-9]{4}$'
     and new.numero_proposta is distinct from old.numero_proposta then
    update public.cards set numero_proposta = new.numero_proposta
     where coalesce(card_pai_id, id) = coalesce(new.card_pai_id, new.id)
       and id <> new.id and numero_proposta is distinct from new.numero_proposta
       and numero_proposta ~ '^C[0-9]{3,}-[0-9]{4}-PRP-[0-9]{4}$';
  end if;
  return null;
end $$;
drop trigger if exists cards_numero_familia on public.cards;
create trigger cards_numero_familia after update on public.cards
  for each row execute function public.bvek_cards_numero_familia();

-- ---------------------------------------------------------------------
-- RENUMERAÇÃO das propostas antigas (só as que ainda não estão no padrão novo)
-- ---------------------------------------------------------------------
update public.cards
   set numero_proposta_antigo = numero_proposta
 where numero_proposta is not null
   and numero_proposta !~ '^C[0-9]{3,}-[0-9]{4}-PRP-[0-9]{4}$'
   and numero_proposta_antigo is null;

do $$
declare
  fam   record;
  v_n   integer := 0;
  v_cli text;
begin
  for fam in
    select coalesce(c.card_pai_id, c.id) as raiz, min(c.criado_em) as desde
      from public.cards c
     where c.numero_proposta is not null
       and c.numero_proposta !~ '^C[0-9]{3,}-[0-9]{4}-PRP-[0-9]{4}$'
     group by 1 order by 2, 1
  loop
    -- próximo número livre (pula os já usados no padrão novo)
    loop
      v_n := v_n + 1;
      exit when not exists (select 1 from public.cards
                             where split_part(numero_proposta, '-PRP-', 2) = lpad(v_n::text, 4, '0')
                               and numero_proposta ~ '^C[0-9]{3,}-[0-9]{4}-PRP-[0-9]{4}$');
    end loop;
    select cl.codigo into v_cli
      from public.cards c join public.clientes cl on cl.id = c.cliente_id
     where c.id = fam.raiz and cl.codigo ~ '^C[0-9]{3,}$';
    -- o gatilho acerta o NNNN se a proposta já tiver projeto
    update public.cards
       set numero_proposta = coalesce(v_cli, 'C000') || '-0000-PRP-' || lpad(v_n::text, 4, '0')
     where coalesce(card_pai_id, id) = fam.raiz
       and numero_proposta is not null
       and numero_proposta !~ '^C[0-9]{3,}-[0-9]{4}-PRP-[0-9]{4}$';
  end loop;
end $$;

-- sequência do grupo: a próxima é a 0020 (ou depois do maior número já usado)
insert into public.bvek_sequencias (nome, ultimo) values ('proposta', 19) on conflict (nome) do nothing;
update public.bvek_sequencias
   set ultimo = greatest(ultimo, 19, coalesce((select max(split_part(numero_proposta, '-PRP-', 2)::int)
                                                from public.cards
                                               where numero_proposta ~ '^C[0-9]{3,}-[0-9]{4}-PRP-[0-9]{4}$'), 0))
 where nome = 'proposta';

-- número de uma proposta nova (só Administrador e Comercial criam propostas)
create or replace function public.gerar_numero_proposta_grupo(p_cliente uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_cod text; v_n integer;
begin
  if not public.bvek_pode('{administrador,comercial}') then
    raise exception 'Sem permissão para criar proposta.';
  end if;
  select codigo into v_cod from public.clientes where id = p_cliente;
  if v_cod is null or v_cod !~ '^C[0-9]{3,}$' then
    raise exception 'O cliente ainda não tem código C###. Abra o cliente e gere o código antes.';
  end if;
  insert into public.bvek_sequencias (nome, ultimo) values ('proposta', 19) on conflict (nome) do nothing;
  loop
    update public.bvek_sequencias set ultimo = ultimo + 1 where nome = 'proposta' returning ultimo into v_n;
    exit when not exists (select 1 from public.cards
                           where split_part(numero_proposta, '-PRP-', 2) = lpad(v_n::text, 4, '0')
                             and numero_proposta ~ '^C[0-9]{3,}-[0-9]{4}-PRP-[0-9]{4}$');
  end loop;
  return v_cod || '-0000-PRP-' || lpad(v_n::text, 4, '0');
end $$;
revoke all on function public.gerar_numero_proposta_grupo(uuid) from public, anon;
grant execute on function public.gerar_numero_proposta_grupo(uuid) to authenticated;

commit;

-- ---------------------------------------------------------------------
-- Conferência: antigo → novo (a revisão _RXX é a versão − 1) e o próximo número
-- ---------------------------------------------------------------------
select numero_proposta_antigo                                         as numero_antigo,
       numero_proposta || '_R' || lpad((coalesce(versao, 1) - 1)::text, 2, '0') as numero_novo,
       titulo
  from public.cards
 where numero_proposta_antigo is not null
union all
select '— próxima proposta nova —',
       'PRP-' || lpad((ultimo + 1)::text, 4, '0'), ''
  from public.bvek_sequencias where nome = 'proposta'
order by 2;
