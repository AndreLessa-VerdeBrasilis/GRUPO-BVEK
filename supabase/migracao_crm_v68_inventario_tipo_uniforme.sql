-- CRM v68: inventário ganha o tipo "Uniformes".
-- Só amplia a lista de tipos permitidos; nenhum item existente muda.
-- Pode rodar mais de uma vez.

alter table public.inventario_itens drop constraint if exists inventario_tipo_chk;
alter table public.inventario_itens add constraint inventario_tipo_chk
  check (tipo in ('material','equipamento','ferramenta','epi','uniforme','veiculo','outro'));

-- Conferência: a regra nova e quantos itens há de cada tipo
select pg_get_constraintdef(oid) as regra_tipo
  from pg_constraint where conname = 'inventario_tipo_chk';
select tipo, count(*) as itens from public.inventario_itens group by tipo order by tipo;
