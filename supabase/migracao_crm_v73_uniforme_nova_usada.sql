-- CRM v73: uniforme no inventário ganha o estado "Usada" (além de "Nova").
-- Só amplia a lista de estados permitidos; nenhum item existente muda.
-- Pode rodar mais de uma vez.

alter table public.inventario_itens drop constraint if exists inventario_estado_chk;
alter table public.inventario_itens add constraint inventario_estado_chk
  check (estado in ('novo','bom','regular','usado','manutencao','inservivel'));

-- Conferência: a regra nova e quantos uniformes há em cada estado
select pg_get_constraintdef(oid) as regra_estado
  from pg_constraint where conname = 'inventario_estado_chk';
select estado, count(*) as uniformes
  from public.inventario_itens where tipo = 'uniforme' group by estado order by estado;
