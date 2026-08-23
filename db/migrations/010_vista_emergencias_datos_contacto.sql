-- 010 — Agregar contacto, reportado_por y el despacho activo a la vista pública
--
-- El popup del mapa solo mostraba tipo y descripción porque la vista v_emergencias no
-- exponía `contacto` ni quién reportó. Se añaden también `estado_despacho` y
-- `despacho_id` como subqueries, para que el panel de comando conozca el despacho activo
-- y pueda marcarlo como atendido mediante la API de despacho.
--
-- LAS COLUMNAS NUEVAS VAN AL FINAL, Y NO ES UNA CUESTIÓN DE ESTILO.
--
-- `create or replace view` solo admite AÑADIR columnas al final: no puede insertarlas en
-- medio, ni renombrarlas, ni cambiarles el tipo. Una primera versión de esta migración
-- las colocaba junto a `datos`, donde encajaban mejor a la vista, y Postgres la rechazó:
--
--   ERROR 42P16: cannot change name of view column "lon" to "contacto"
--
-- El mensaje despista, porque no se estaba renombrando nada: al desplazar `lon` de la
-- posición 8 a la 10, Postgres compara posición por posición y lo interpreta como un
-- renombrado. Reordenar exigiría `drop view` + `create view`, que tumbaría los permisos y
-- dejaría un instante sin vista mientras el frontend consulta. No vale la pena: el orden
-- de columnas de una vista es cosmético, PostgREST y el cliente de Supabase seleccionan
-- por nombre.
--
-- Las diez primeras columnas se repiten EXACTAMENTE como las dejó la 009 —mismo orden,
-- mismo nombre, mismo tipo— porque cualquier diferencia rompe el replace.

begin;

create or replace view public.v_emergencias
with (security_invoker = true) as
select
  -- 1-10: idénticas a la 009. No tocar sin hacer drop + create.
  e.id,
  e.tipo::text        as tipo,
  e.ciudad::text      as ciudad,
  e.prioridad::text   as prioridad,
  e.triage_score,
  e.descripcion,
  e.datos,
  extensions.st_x(e.geom::extensions.geometry) as lon,
  extensions.st_y(e.geom::extensions.geometry) as lat,
  e.creado_en,

  -- 11 en adelante: lo que añade esta migración.
  e.contacto,
  e.reportado_por,

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

-- `create or replace` conserva los permisos existentes, pero repetir el grant mantiene la
-- migración autocontenida: aplicada sobre una base recién creada deja el mismo estado.
grant select on public.v_emergencias to authenticated;

commit;
