-- =====================================================================
-- CRM Grupo BVEK — migração v52 (06/11/2026)
-- DIÁRIO DE OBRA PELO CELULAR: RELATOS EM ÁUDIO E FOTOS NA HORA
--   • Coluna diarios_obra.registros: a linha do tempo do dia. Cada registro
--     pode ter foto, áudio (relato ou narração da foto) e texto, com hora e
--     autor. Vários registros por dia, em momentos diferentes.
--   • Cada registro é gravado na hora (função bvek_diario_registrar), sem
--     depender do resto do formulário. O id do registro vem do celular: se
--     a internet cair e o celular reenviar, o registro NÃO duplica.
--   • bvek_diario_registro_alterar: narrar uma foto depois, escrever texto
--     ou tirar um registro (o funcionário só mexe nos dele; o escritório em
--     todos). Diário fechado não muda.
--   • Bucket "diarios" passa a aceitar áudio (gravação do celular).
--
-- Precisa da v51. Como usar: Supabase → SQL Editor → New query → colar
-- TUDO → Run. Pode rodar mais de uma vez sem duplicar nada.
-- =====================================================================

alter table public.diarios_obra add column if not exists registros jsonb not null default '[]'::jsonb;

-- bucket: fotos + áudio (webm do Android, mp4/m4a do iPhone, ogg, mp3, aac)
update storage.buckets
   set file_size_limit = 26214400,
       allowed_mime_types = array['image/jpeg','image/png','image/webp','application/pdf',
                                  'audio/webm','audio/mp4','audio/x-m4a','audio/m4a','audio/ogg','audio/mpeg','audio/aac','video/webm']
 where id = 'diarios';

-- quem está mexendo pode registrar neste diário?
create or replace function public.bvek_diario_pode_registrar(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.bvek_pode('{administrador,comercial,administrativo,contabilidade}') or public.bvek_diario_meu(p_id)
$$;
revoke all on function public.bvek_diario_pode_registrar(uuid) from public, anon;
grant execute on function public.bvek_diario_pode_registrar(uuid) to authenticated;

-- grava UM registro (foto e/ou áudio e/ou texto) — sem duplicar pelo id
create or replace function public.bvek_diario_registrar(p_id uuid, p_reg jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text := coalesce(nullif(p_reg->>'id',''), gen_random_uuid()::text);
  v_func uuid := public.bvek_meu_funcionario_id();
  v_nome text; v_rec jsonb; d public.diarios_obra;
begin
  if not public.bvek_diario_pode_registrar(p_id) then raise exception 'Este diário não é da sua equipe.'; end if;
  select * into d from public.diarios_obra where id = p_id for update;
  if not found then raise exception 'Diário não encontrado.'; end if;
  if d.situacao = 'fechado' then raise exception 'Este diário já foi fechado pelo escritório. Fale com o escritório.'; end if;
  -- arquivos só da pasta deste diário
  if coalesce(p_reg->>'foto','') <> '' and split_part(p_reg->>'foto','/',1) <> p_id::text then raise exception 'Foto fora da pasta do diário.'; end if;
  if coalesce(p_reg->>'audio','') <> '' and split_part(p_reg->>'audio','/',1) <> p_id::text then raise exception 'Áudio fora da pasta do diário.'; end if;
  -- já gravado (reenvio do celular): devolve sem duplicar
  if exists (select 1 from jsonb_array_elements(d.registros) e where e->>'id' = v_id) then return d.registros; end if;
  if public.bvek_pode('{funcionario}') then
    select nome into v_nome from public.funcionarios where id = v_func;
  else
    select coalesce(nullif(nome,''), email) into v_nome from public.perfis where id = auth.uid();
  end if;
  v_rec := jsonb_strip_nulls(jsonb_build_object(
    'id', v_id,
    'em', coalesce(nullif(p_reg->>'em',''), to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS')),
    'autor', coalesce(v_nome, 'Equipe'),
    'autor_func', case when public.bvek_pode('{funcionario}') then v_func::text end,
    'foto', nullif(p_reg->>'foto',''),
    'audio', nullif(p_reg->>'audio',''),
    'duracao', case when coalesce(p_reg->>'duracao','') ~ '^[0-9]+$' then (p_reg->>'duracao')::int end,
    'texto', nullif(left(coalesce(p_reg->>'texto',''), 2000),'')));
  update public.diarios_obra
     set registros = registros || jsonb_build_array(v_rec),
         situacao = case when situacao = 'pendente' then 'preenchido' else situacao end,
         preenchido_por = coalesce(preenchido_por, v_nome),
         preenchido_em = coalesce(preenchido_em, now())
   where id = p_id
  returning registros into v_rec;
  return v_rec;
end $$;
revoke all on function public.bvek_diario_registrar(uuid, jsonb) from public, anon;
grant execute on function public.bvek_diario_registrar(uuid, jsonb) to authenticated;

-- narrar uma foto depois, mudar o texto ou tirar um registro
-- p_dados: { "audio": "...", "duracao": 12, "texto": "...", "remover": true }
create or replace function public.bvek_diario_registro_alterar(p_id uuid, p_reg text, p_dados jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.diarios_obra; v_novo jsonb := '[]'::jsonb; e jsonb; v_achou boolean := false;
        v_func text := public.bvek_meu_funcionario_id()::text; v_escr boolean;
begin
  if not public.bvek_diario_pode_registrar(p_id) then raise exception 'Este diário não é da sua equipe.'; end if;
  v_escr := public.bvek_pode('{administrador,comercial,administrativo,contabilidade}');
  select * into d from public.diarios_obra where id = p_id for update;
  if not found then raise exception 'Diário não encontrado.'; end if;
  if d.situacao = 'fechado' then raise exception 'Este diário já foi fechado pelo escritório. Fale com o escritório.'; end if;
  if coalesce(p_dados->>'audio','') <> '' and split_part(p_dados->>'audio','/',1) <> p_id::text then raise exception 'Áudio fora da pasta do diário.'; end if;
  for e in select * from jsonb_array_elements(d.registros) loop
    if e->>'id' = p_reg then
      v_achou := true;
      if not v_escr and coalesce(e->>'autor_func','') <> coalesce(v_func,'-') then
        raise exception 'Só quem fez o registro (ou o escritório) pode mudar.';
      end if;
      if coalesce((p_dados->>'remover')::boolean, false) then continue; end if;
      if coalesce(p_dados->>'audio','') <> '' then
        e := e || jsonb_build_object('audio', p_dados->>'audio');
        if coalesce(p_dados->>'duracao','') ~ '^[0-9]+$' then e := e || jsonb_build_object('duracao', (p_dados->>'duracao')::int); end if;
      end if;
      if p_dados ? 'texto' then
        e := case when coalesce(p_dados->>'texto','') = '' then e - 'texto' else e || jsonb_build_object('texto', left(p_dados->>'texto', 2000)) end;
      end if;
    end if;
    v_novo := v_novo || jsonb_build_array(e);
  end loop;
  if not v_achou then raise exception 'Registro ainda não chegou ao CRM.'; end if;
  update public.diarios_obra set registros = v_novo where id = p_id returning registros into v_novo;
  return v_novo;
end $$;
revoke all on function public.bvek_diario_registro_alterar(uuid, text, jsonb) from public, anon;
grant execute on function public.bvek_diario_registro_alterar(uuid, text, jsonb) to authenticated;

-- Conferência
select 'coluna diarios_obra.registros' as item,
       exists(select 1 from information_schema.columns where table_schema='public' and table_name='diarios_obra' and column_name='registros')::text as resultado
union all select 'bucket diarios aceita áudio',
       coalesce((select ('audio/webm' = any(allowed_mime_types) and 'audio/mp4' = any(allowed_mime_types))::text from storage.buckets where id = 'diarios'), 'bucket não existe — rode a v51')
union all select 'funções novas (deve ser 3)', count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('bvek_diario_registrar','bvek_diario_registro_alterar','bvek_diario_pode_registrar');
