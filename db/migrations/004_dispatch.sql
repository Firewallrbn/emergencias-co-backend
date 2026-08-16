-- 004 — Service 2: Dispatch & Resource Assignment
--
-- Incluye el Anti-Corruption Layer: dispatch nunca consulta `intake.emergencias`
-- directamente desde el código, sino a través de una vista que fija el contrato. Si intake
-- renombra una columna interna, se ajusta la vista y dispatch no se entera.

begin;

-- ---------------------------------------------------------------------------
-- Unidades de respuesta
-- ---------------------------------------------------------------------------
create table if not exists dispatch.unidades (
  id             uuid primary key default gen_random_uuid(),
  codigo         text not null unique,
  organismo      comun.organismo not null,
  ciudad         comun.ciudad not null,
  geom           extensions.geography(Point, 4326) not null,
  disponible     boolean not null default true,
  capacidad      integer not null default 1 check (capacidad > 0),
  actualizado_en timestamptz not null default now()
);

comment on table dispatch.unidades is
  'Cuadrillas de Cruz Roja, Bomberos, Defensa Civil y UNGRD desplegadas en los 4 nodos.';

create index if not exists unidades_geom_gix
  on dispatch.unidades using gist (geom);

-- La búsqueda siempre es "unidades disponibles en tal ciudad". Índice parcial: solo
-- indexa las disponibles, que son las únicas que se consultan.
create index if not exists unidades_ciudad_disponibles_ix
  on dispatch.unidades (ciudad)
  where disponible;

-- ---------------------------------------------------------------------------
-- Despachos
-- ---------------------------------------------------------------------------
create table if not exists dispatch.despachos (
  id             uuid primary key default gen_random_uuid(),

  -- Referencia por id, sin FOREIGN KEY: una clave foránea entre schemas de servicios
  -- distintos crea un acoplamiento físico que contradice Database per Service.
  -- La integridad se garantiza en el flujo (dispatch solo consume ids que intake publicó).
  emergencia_id  uuid not null,

  unidad_id      uuid references dispatch.unidades (id) on delete set null,
  estado         comun.estado_despacho not null default 'pendiente',
  distancia_m    numeric(10, 2),
  notas          text,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);

-- Una emergencia no puede tener dos despachos activos a la vez.
create unique index if not exists despachos_emergencia_activa_uk
  on dispatch.despachos (emergencia_id)
  where estado not in ('atendido', 'cancelado');

create index if not exists despachos_estado_ix
  on dispatch.despachos (estado, creado_en desc);

create index if not exists despachos_unidad_ix
  on dispatch.despachos (unidad_id)
  where unidad_id is not null;

drop trigger if exists despachos_tocar_actualizado on dispatch.despachos;
create trigger despachos_tocar_actualizado
  before update on dispatch.despachos
  for each row execute function comun.tocar_actualizado_en();

-- ---------------------------------------------------------------------------
-- Anti-Corruption Layer: contrato de lectura hacia intake
--
-- `security_invoker = true` es imprescindible: por defecto una vista se evalúa con los
-- permisos de su dueño (postgres), lo que saltaría la RLS de intake.emergencias y haría
-- que las pruebas de RLS pasaran en falso.
-- ---------------------------------------------------------------------------
create or replace view dispatch.v_emergencias_pendientes
with (security_invoker = true) as
select
  e.id,
  e.tipo,
  e.ciudad,
  e.prioridad,
  e.triage_score,
  e.geom,
  e.creado_en
from intake.emergencias e
where not exists (
  select 1
  from dispatch.despachos d
  where d.emergencia_id = e.id
    and d.estado not in ('atendido', 'cancelado')
)
order by e.prioridad, e.creado_en;

comment on view dispatch.v_emergencias_pendientes is
  'Anti-Corruption Layer: unica via por la que dispatch lee el dominio de intake.';

-- ---------------------------------------------------------------------------
-- Asignación por proximidad
--
-- ST_DWithin sobre geography acota el radio en metros y aprovecha el índice GiST;
-- el orden por distancia se calcula solo sobre las candidatas ya filtradas.
-- ---------------------------------------------------------------------------
create or replace function dispatch.unidad_mas_cercana(
  p_geom   extensions.geography,
  p_ciudad comun.ciudad,
  p_radio_m numeric default 50000
)
returns table (unidad_id uuid, distancia_m numeric)
language sql
stable
set search_path = ''
as $$
  select u.id,
         round(extensions.st_distance(u.geom, p_geom)::numeric, 2)
  from dispatch.unidades u
  where u.disponible
    and u.ciudad = p_ciudad
    and extensions.st_dwithin(u.geom, p_geom, p_radio_m)
  -- El operador KNN hay que calificarlo con OPERATOR(): la función corre con
  -- `search_path = ''` y un `<->` a secas no se resuelve en el schema extensions.
  order by u.geom operator(extensions.<->) p_geom
  limit 1;
$$;

comment on function dispatch.unidad_mas_cercana is
  'Unidad disponible mas cercana dentro del radio. El operador KNN <-> ordena por distancia aprovechando el indice GiST.';

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
grant select, insert, update on dispatch.despachos to svc_dispatch;
grant select, update on dispatch.unidades to svc_dispatch;
grant select on dispatch.v_emergencias_pendientes to svc_dispatch;
grant execute on function dispatch.unidad_mas_cercana to svc_dispatch;

grant usage on schema dispatch to authenticated;
grant select on dispatch.despachos, dispatch.unidades to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table dispatch.unidades  enable row level security;
alter table dispatch.unidades  force row level security;
alter table dispatch.despachos enable row level security;
alter table dispatch.despachos force row level security;

-- Solo los operadores ven el despliegue de recursos; un ciudadano no tiene por qué
-- saber dónde están las cuadrillas.
drop policy if exists operador_lee_unidades on dispatch.unidades;
create policy operador_lee_unidades
  on dispatch.unidades for select
  to authenticated
  using (
    comun.es_operador()
    and (comun.ciudad_operador() is null or ciudad::text = comun.ciudad_operador())
  );

drop policy if exists svc_dispatch_unidades on dispatch.unidades;
create policy svc_dispatch_unidades
  on dispatch.unidades for all
  to svc_dispatch
  using (true) with check (true);

drop policy if exists operador_lee_despachos on dispatch.despachos;
create policy operador_lee_despachos
  on dispatch.despachos for select
  to authenticated
  using (comun.es_operador());

drop policy if exists svc_dispatch_despachos on dispatch.despachos;
create policy svc_dispatch_despachos
  on dispatch.despachos for all
  to svc_dispatch
  using (true) with check (true);

commit;
