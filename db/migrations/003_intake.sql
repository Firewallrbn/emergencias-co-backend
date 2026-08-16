-- 003 — Service 1: Intake & Triage
--
-- Tabla raíz del dominio. Dos cosas que responden directamente al planteamiento del
-- enunciado ("picos masivos de tráfico concurrente, solicitudes duplicadas"):
--   * `idempotency_key` con índice único → una solicitud reenviada no se duplica.
--   * `geom` geography + índice GiST → consultas de proximidad en tiempo real.

begin;

create table if not exists intake.emergencias (
  id                uuid primary key default gen_random_uuid(),

  -- Patrón: Idempotency Key. El cliente genera la clave; el índice único la hace efectiva
  -- aunque lleguen dos peticiones concurrentes por contenedores Lambda distintos.
  idempotency_key   text not null,

  tipo              comun.tipo_solicitud not null,
  ciudad            comun.ciudad not null,
  prioridad         comun.prioridad not null,

  -- Puntaje determinista del triage: mismo payload, mismo puntaje. Se guarda para poder
  -- auditar por qué una solicitud quedó en P1 sin volver a ejecutar el algoritmo.
  triage_score      integer not null check (triage_score between 0 and 100),

  -- geography (no geometry): los cálculos de distancia salen en metros sobre el elipsoide,
  -- que es lo que necesita ST_DWithin para "unidades a menos de N km".
  geom              extensions.geography(Point, 4326) not null,

  descripcion       text not null check (length(descripcion) between 1 and 2000),

  -- Campos críticos variables por tipo de solicitud (personas atrapadas, conteo de
  -- damnificados, categoría de insumo, nivel de agrietamiento). JSONB porque cada tipo
  -- exige un conjunto distinto y el gateway ya validó su forma contra un JSON Schema.
  datos             jsonb not null default '{}'::jsonb,

  reportado_por     uuid,
  contacto          text,

  creado_en         timestamptz not null default now(),
  actualizado_en    timestamptz not null default now()
);

comment on table intake.emergencias is
  'Solicitudes de auxilio. Propiedad exclusiva del microservicio intake.';

-- Idempotencia: misma clave, misma solicitud. Es un índice único, no solo una restricción
-- lógica en el código: dos contenedores concurrentes no pueden burlarlo.
create unique index if not exists emergencias_idempotency_uk
  on intake.emergencias (idempotency_key);

-- Índice geoespacial. Sin él, ST_DWithin degenera en escaneo secuencial.
create index if not exists emergencias_geom_gix
  on intake.emergencias using gist (geom);

-- El panel de comando filtra por ciudad y ordena por prioridad y recencia.
-- Índice compuesto en ese orden: igualdad primero, luego los criterios de orden.
create index if not exists emergencias_ciudad_prioridad_ix
  on intake.emergencias (ciudad, prioridad, creado_en desc);

-- Un ciudadano consulta sus propios reportes; parcial para no indexar los anónimos.
create index if not exists emergencias_reportante_ix
  on intake.emergencias (reportado_por, creado_en desc)
  where reportado_por is not null;

-- ---------------------------------------------------------------------------
-- actualizado_en automático
-- ---------------------------------------------------------------------------
create or replace function comun.tocar_actualizado_en()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.actualizado_en := now();
  return new;
end;
$$;

drop trigger if exists emergencias_tocar_actualizado on intake.emergencias;
create trigger emergencias_tocar_actualizado
  before update on intake.emergencias
  for each row execute function comun.tocar_actualizado_en();

-- ---------------------------------------------------------------------------
-- Permisos: mínimos y explícitos, columna de acción por columna de acción.
-- ---------------------------------------------------------------------------
grant select, insert, update on intake.emergencias to svc_intake;

-- dispatch y geo solo LEEN. No pueden escribir en el schema de otro servicio.
-- Sin `usage` sobre el schema, el `select` sobre la tabla no sirve de nada.
grant usage on schema intake to svc_dispatch, svc_geo, authenticated, anon;
grant select on intake.emergencias to svc_dispatch, svc_geo;

-- El frontend consulta con el rol `authenticated`; RLS decide qué filas ve.
grant select on intake.emergencias to authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security
--
-- Se activa en la tabla y, además, se FUERZA: sin `force`, el dueño de la tabla
-- (postgres) se saltaría las políticas, y las pruebas de RLS darían un falso verde.
-- ---------------------------------------------------------------------------
alter table intake.emergencias enable row level security;
alter table intake.emergencias force row level security;

drop policy if exists ciudadano_lee_propias on intake.emergencias;
create policy ciudadano_lee_propias
  on intake.emergencias for select
  to authenticated
  using (reportado_por = (select auth.uid()));

drop policy if exists operador_lee_su_ciudad on intake.emergencias;
create policy operador_lee_su_ciudad
  on intake.emergencias for select
  to authenticated
  using (
    comun.es_operador()
    and (
      comun.ciudad_operador() is null
      or ciudad::text = comun.ciudad_operador()
    )
  );

-- El servicio de intake necesita ver y escribir todo: es el dueño del agregado.
drop policy if exists svc_intake_total on intake.emergencias;
create policy svc_intake_total
  on intake.emergencias for all
  to svc_intake
  using (true) with check (true);

drop policy if exists svc_lectura_interna on intake.emergencias;
create policy svc_lectura_interna
  on intake.emergencias for select
  to svc_dispatch, svc_geo
  using (true);

commit;
