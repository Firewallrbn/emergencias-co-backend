-- 010 — Agregar datos, contacto y despacho_id a la vista pública de emergencias
--
-- El popup del mapa solo mostraba tipo y descripción porque la vista v_emergencias no
-- exponía las columnas `datos` (campos críticos variables) ni `contacto`.
--
-- También se agrega `estado_despacho` y `despacho_id` como subqueries para que el
-- frontend conozca el despacho activo y pueda modificarlo mediante la API de despacho.

begin;

create or replace view public.v_emergencias
with (security_invoker = true) as
select
  e.id,
  e.tipo::text        as tipo,
  e.ciudad::text      as ciudad,
  e.prioridad::text   as prioridad,
  e.triage_score,
  e.descripcion,
  e.datos,
  e.contacto,
  e.reportado_por,
  extensions.st_x(e.geom::extensions.geometry) as lon,
  extensions.st_y(e.geom::extensions.geometry) as lat,
  e.creado_en,
  -- Estado del despacho más reciente (si existe).
  (
    select d.estado::text
    from dispatch.despachos d
    where d.emergencia_id = e.id
    order by d.creado_en desc
    limit 1
  ) as estado_despacho,
  -- ID del despacho más reciente (si existe). Permite al panel de comando
  -- modificar el despacho correspondiente (marcarlo como atendido/despachado).
  (
    select d.id
    from dispatch.despachos d
    where d.emergencia_id = e.id
    order by d.creado_en desc
    limit 1
  ) as despacho_id
from intake.emergencias e;

comment on view public.v_emergencias is
  'Lectura de emergencias para el frontend. Expone lon/lat como numeros, datos criticos, contacto, estado y ID de despacho.';

commit;
