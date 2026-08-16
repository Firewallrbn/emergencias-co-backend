-- 007 — Publicación Realtime
--
-- El panel de comando se actualiza por suscripción, sin polling: es un requisito explícito
-- del enunciado ("sin necesidad de polling repetitivo") y se demuestra en el video con la
-- pestaña de red en silencio.
--
-- Realtime lee de la replicación lógica de Postgres, así que funciona igual con un INSERT
-- hecho por una Lambda vía `pg` que con uno hecho por supabase-js. RLS se sigue aplicando:
-- cada suscriptor solo recibe las filas que sus políticas le permiten ver.

begin;

-- La publicación la crea Supabase al provisionar el proyecto; si no existe, se crea vacía.
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end
$$;

-- `add table` falla si la tabla ya está en la publicación, así que se comprueba antes
-- para mantener la migración idempotente.
do $$
declare
  objetivo text;
begin
  foreach objetivo in array array[
    'intake.emergencias',
    'dispatch.despachos',
    'notify.notificaciones'
  ] loop
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname || '.' || tablename = objetivo
    ) then
      execute format('alter publication supabase_realtime add table %s', objetivo);
    end if;
  end loop;
end
$$;

-- REPLICA IDENTITY FULL hace que los eventos UPDATE y DELETE incluyan los valores
-- anteriores. Sin esto, el dashboard recibe un UPDATE sin saber qué cambió y no puede
-- aplicar RLS sobre la fila vieja.
alter table intake.emergencias    replica identity full;
alter table dispatch.despachos    replica identity full;
alter table notify.notificaciones replica identity full;

commit;
