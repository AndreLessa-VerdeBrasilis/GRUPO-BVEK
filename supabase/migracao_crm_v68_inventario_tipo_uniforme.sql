-- CRM v68: inventário ganha o tipo "Uniformes", com modelo da peça, tamanho e cor.
-- Só amplia a lista de tipos e acrescenta 3 colunas; nenhum item existente muda.
-- Pode rodar mais de uma vez.

alter table public.inventario_itens drop constraint if exists inventario_tipo_chk;
alter table public.inventario_itens add constraint inventario_tipo_chk
  check (tipo in ('material','equipamento','ferramenta','epi','uniforme','veiculo','outro'));

alter table public.inventario_itens add column if not exists unif_modelo  text;
alter table public.inventario_itens add column if not exists unif_tamanho text;
alter table public.inventario_itens add column if not exists unif_cor     text;

-- Conferência: a regra nova, as colunas novas e quantos itens há de cada tipo
select pg_get_constraintdef(oid) as regra_tipo
  from pg_constraint where conname = 'inventario_tipo_chk';
select column_name from information_schema.columns
 where table_schema = 'public' and table_name = 'inventario_itens' and column_name like 'unif_%';
select tipo, count(*) as itens from public.inventario_itens group by tipo order by tipo;
