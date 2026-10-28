-- =====================================================================
-- CRM Grupo BVEK — migração v21 (28/10/2026)
-- Financeiro: controle das saídas (cartões da empresa, Pix, dinheiro)
--
-- Sem serviço pago: o extrato/fatura do cartão (Itaú Empresas) é
-- importado no CRM (arquivo OFX, Excel/CSV ou PDF). Cada compra vira uma
-- linha UMA vez só (o CRM reconhece o que já foi importado) e quem fez a
-- compra só completa: categoria, para que foi, cliente/projeto e a foto
-- da nota. Se a pessoa já tiver lançado a compra na hora, a importação
-- junta com o lançamento dela (não duplica).
--
--  1. cartoes: cartões da empresa e de quem é cada um (Pedro, Bianca…)
--  2. saidas: cada compra/saída de caixa
--  3. Quem vê o quê (regra no banco):
--       - Administrador e Administrativo: tudo; importam e conferem.
--       - Comercial: só as compras dos próprios cartões e as que lançou;
--         pode lançar e justificar, mas não pode "conferir" nem mudar o
--         valor/data que veio do extrato.
--  4. Pasta de arquivos "financeiro" (fotos e PDFs das notas)
--
-- Como usar: Supabase → SQL Editor → New query → colar TUDO → Run.
-- Pode rodar mais de uma vez sem duplicar nada. Nada é apagado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. CARTÕES
-- ---------------------------------------------------------------------
create table if not exists public.cartoes (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,                       -- ex.: "Itaú Empresas — Pedro"
  final       text,                                -- 4 últimos dígitos
  banco       text default 'Itaú Empresas',
  usuario_id  uuid references public.perfis(id) on delete set null,   -- dono do cartão (login no CRM)
  titular     text,
  empresa_id  uuid references public.empresas(id) on delete set null,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. SAÍDAS
-- ---------------------------------------------------------------------
create table if not exists public.saidas (
  id                uuid primary key default gen_random_uuid(),
  cartao_id         uuid references public.cartoes(id) on delete set null,   -- vazio = Pix, boleto, dinheiro
  forma             text not null default 'cartao',
  data              date not null,
  valor             numeric(14,2) not null,
  descricao_extrato text,                -- como veio no extrato do banco
  parcela           text,                -- ex.: 02/05
  fatura            date,                -- mês da fatura (dia 1)
  origem            text not null default 'manual',   -- 'extrato' ou 'manual'
  hash_extrato      text,                -- impressão digital da linha do extrato (evita importar 2x)
  conciliada        boolean not null default false,   -- já bateu com o extrato do banco
  categoria         text,
  fornecedor        text,
  descricao         text,                -- para que foi a compra
  cliente_id        uuid references public.clientes(id) on delete set null,
  projeto_id        uuid references public.projetos(id) on delete set null,
  empresa_id        uuid references public.empresas(id) on delete set null,
  comprador         text,
  nota_path         text,                -- arquivo da nota na pasta "financeiro"
  situacao          text not null default 'pendente', -- pendente (sem justificativa) · justificada · conferida
  observacoes       text,
  criado_por        text,
  criado_por_id     uuid default auth.uid(),
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),
  conferido_por     text,
  conferido_em      timestamptz
);
alter table public.saidas drop constraint if exists saidas_situacao_chk;
alter table public.saidas add constraint saidas_situacao_chk check (situacao in ('pendente','justificada','conferida'));
alter table public.saidas drop constraint if exists saidas_origem_chk;
alter table public.saidas add constraint saidas_origem_chk check (origem in ('extrato','manual'));
alter table public.saidas drop constraint if exists saidas_forma_chk;
alter table public.saidas add constraint saidas_forma_chk check (forma in ('cartao','pix','boleto','dinheiro','outro'));
alter table public.saidas drop constraint if exists saidas_hash_unq;
alter table public.saidas add constraint saidas_hash_unq unique (hash_extrato);
create index if not exists saidas_data_idx   on public.saidas (data);
create index if not exists saidas_cartao_idx on public.saidas (cartao_id);

-- Cartões do usuário logado (usado nas regras abaixo)
create or replace function public.bvek_meus_cartoes() returns setof uuid
language sql stable security definer set search_path = public as $$
  select id from public.cartoes where usuario_id = auth.uid()
$$;
grant execute on function public.bvek_meus_cartoes() to authenticated;

-- Comercial: não confere e não mexe no que veio do extrato
create or replace function public.bvek_saidas_guarda() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.atualizado_em := now();
  -- SQL Editor / sistema (sem login) e financeiro: livre
  if auth.uid() is null or public.bvek_pode('{administrador,administrativo}') then return new; end if;
  if tg_op = 'INSERT' then
    new.situacao := case when new.situacao = 'conferida' then 'justificada' else new.situacao end;
    new.conferido_por := null; new.conferido_em := null;
    new.origem := 'manual'; new.hash_extrato := null; new.conciliada := false;
    new.criado_por_id := auth.uid();
    return new;
  end if;
  -- UPDATE
  if old.situacao = 'conferida' then
    raise exception 'Esta saída já foi conferida pelo financeiro. Peça para reabrir.';
  end if;
  if new.situacao = 'conferida' then new.situacao := 'justificada'; end if;
  new.conferido_por := old.conferido_por; new.conferido_em := old.conferido_em;
  new.origem := old.origem; new.hash_extrato := old.hash_extrato; new.conciliada := old.conciliada;
  new.criado_por_id := old.criado_por_id;
  if old.origem = 'extrato' then
    new.data := old.data; new.valor := old.valor; new.cartao_id := old.cartao_id;
    new.descricao_extrato := old.descricao_extrato; new.parcela := old.parcela; new.fatura := old.fatura;
  end if;
  return new;
end $$;
drop trigger if exists saidas_guarda on public.saidas;
create trigger saidas_guarda before insert or update on public.saidas
  for each row execute function public.bvek_saidas_guarda();

-- ---------------------------------------------------------------------
-- 3. SEGURANÇA (RLS)
-- ---------------------------------------------------------------------
alter table public.cartoes enable row level security;
alter table public.saidas  enable row level security;
grant select, insert, update, delete on public.cartoes to authenticated;
grant select, insert, update, delete on public.saidas  to authenticated;

drop policy if exists bvek_ler     on public.cartoes;
drop policy if exists bvek_inserir on public.cartoes;
drop policy if exists bvek_alterar on public.cartoes;
drop policy if exists bvek_apagar  on public.cartoes;
create policy bvek_ler on public.cartoes for select to authenticated
  using (public.bvek_pode('{administrador,administrativo}')
         or (public.bvek_pode('{comercial}') and usuario_id = auth.uid()));
create policy bvek_inserir on public.cartoes for insert to authenticated
  with check (public.bvek_pode('{administrador,administrativo}'));
create policy bvek_alterar on public.cartoes for update to authenticated
  using (public.bvek_pode('{administrador,administrativo}')) with check (public.bvek_pode('{administrador,administrativo}'));
create policy bvek_apagar on public.cartoes for delete to authenticated
  using (public.bvek_pode('{administrador}'));

drop policy if exists bvek_ler     on public.saidas;
drop policy if exists bvek_inserir on public.saidas;
drop policy if exists bvek_alterar on public.saidas;
drop policy if exists bvek_apagar  on public.saidas;
create policy bvek_ler on public.saidas for select to authenticated
  using (public.bvek_pode('{administrador,administrativo}')
         or (public.bvek_pode('{comercial}')
             and (cartao_id in (select public.bvek_meus_cartoes()) or criado_por_id = auth.uid())));
create policy bvek_inserir on public.saidas for insert to authenticated
  with check (public.bvek_pode('{administrador,administrativo}')
              or (public.bvek_pode('{comercial}')
                  and (cartao_id is null or cartao_id in (select public.bvek_meus_cartoes()))));
create policy bvek_alterar on public.saidas for update to authenticated
  using (public.bvek_pode('{administrador,administrativo}')
         or (public.bvek_pode('{comercial}')
             and (cartao_id in (select public.bvek_meus_cartoes()) or criado_por_id = auth.uid())))
  with check (public.bvek_pode('{administrador,administrativo}')
         or (public.bvek_pode('{comercial}')
             and (cartao_id is null or cartao_id in (select public.bvek_meus_cartoes()) or criado_por_id = auth.uid())));
create policy bvek_apagar on public.saidas for delete to authenticated
  using (public.bvek_pode('{administrador,administrativo}')
         or (public.bvek_pode('{comercial}') and criado_por_id = auth.uid()
             and origem = 'manual' and not conciliada and situacao <> 'conferida'));

-- ---------------------------------------------------------------------
-- 4. ARQUIVOS DAS NOTAS: pasta "financeiro", caminho saidas/<id da saída>/arquivo
--    quem enxerga a saída enxerga a nota
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('financeiro', 'financeiro', false, 26214400,
        array['application/pdf','image/jpeg','image/png','image/webp','image/heic','image/heif'])
on conflict (id) do nothing;

drop policy if exists financeiro_ler     on storage.objects;
drop policy if exists financeiro_enviar  on storage.objects;
drop policy if exists financeiro_alterar on storage.objects;
drop policy if exists financeiro_apagar  on storage.objects;
create policy financeiro_ler on storage.objects for select to authenticated
  using (bucket_id = 'financeiro' and (public.bvek_pode('{administrador,administrativo}')
         or exists (select 1 from public.saidas s where s.id::text = (storage.foldername(name))[2])));
create policy financeiro_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'financeiro' and (public.bvek_pode('{administrador,administrativo}')
         or exists (select 1 from public.saidas s where s.id::text = (storage.foldername(name))[2])));
create policy financeiro_alterar on storage.objects for update to authenticated
  using (bucket_id = 'financeiro' and public.bvek_pode('{administrador,administrativo}'))
  with check (bucket_id = 'financeiro' and public.bvek_pode('{administrador,administrativo}'));
create policy financeiro_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'financeiro' and public.bvek_pode('{administrador,administrativo}'));

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select (select count(*) from pg_policies where schemaname = 'public'
         and tablename in ('cartoes','saidas'))                                    as regras_deve_ser_8,
       (select count(*) from storage.buckets where id = 'financeiro')             as pasta_financeiro_deve_ser_1,
       (select count(*) from pg_policies where schemaname = 'storage'
         and policyname like 'financeiro\_%')                                      as regras_arquivos_deve_ser_4,
       (select count(*) from public.cartoes)                                       as cartoes_cadastrados;
