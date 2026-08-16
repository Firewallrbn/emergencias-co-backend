-- 009 — Superficie de lectura para el frontend
--
-- PostgREST solo sirve los schemas que Supabase tiene declarados como expuestos, y por
-- defecto son `public` y `graphql_public`. Nuestros schemas por servicio no lo están, así
-- que el panel de comando no podía leer nada: PGRST106 "Invalid schema: intake".
--
-- Se resuelve con vistas en `public` en lugar de exponer los cuatro schemas completos.
-- La diferencia importa: exponer un schema publica TODAS sus tablas, presentes y futuras,
-- mientras que una vista declara exactamente qué columnas salen al exterior. Si mañana se
-- añade una tabla interna a intake, no queda publicada por accidente.
--
-- `security_invoker = true` en todas: sin eso la vista se evalúa con los permisos de su
-- dueño y saltaría la RLS de la tabla subyacente, que es justo lo que estamos protegiendo.
-- Con el invocador, un ciudadano sigue viendo solo sus reportes.

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
  -- Se entregan las coordenadas ya proyectadas a números. El tipo geography sale por
  -- PostgREST como WKB hexadecimal, que el navegador tendría que decodificar para poder
  -- pintar un punto en el mapa.
  extensions.st_x(e.geom::extensions.geometry) as lon,
  extensions.st_y(e.geom::extensions.geometry) as lat,
  e.creado_en
from intake.emergencias e;

comment on view public.v_emergencias is
  'Lectura de emergencias para el frontend. Expone lon/lat como numeros en vez del WKB de PostGIS.';

create or replace view public.v_despachos
with (security_invoker = true) as
select
  d.id,
  d.emergencia_id,
  d.estado::text as estado,
  d.distancia_m,
  d.creado_en,
  u.codigo        as unidad,
  u.organismo::text as organismo,
  u.ciudad::text  as ciudad
from dispatch.despachos d
left join dispatch.unidades u on u.id = d.unidad_id;

create or replace view public.v_unidades
with (security_invoker = true) as
select
  u.id,
  u.codigo,
  u.organismo::text as organismo,
  u.ciudad::text    as ciudad,
  u.disponible,
  extensions.st_x(u.geom::extensions.geometry) as lon,
  extensions.st_y(u.geom::extensions.geometry) as lat
from dispatch.unidades u;

create or replace view public.v_notificaciones
with (security_invoker = true) as
select
  n.id,
  n.emergencia_id,
  n.destinatario,
  n.canal,
  n.asunto,
  n.estado,
  n.creado_en
from notify.notificaciones n;

-- Solo lectura, y solo para sesiones autenticadas. `anon` no recibe nada: quien no ha
-- iniciado sesión no tiene por qué ver reportes de emergencia de nadie.
grant select on
  public.v_emergencias,
  public.v_despachos,
  public.v_unidades,
  public.v_notificaciones
to authenticated;

commit;
