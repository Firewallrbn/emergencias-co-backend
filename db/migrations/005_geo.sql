-- 005 — Service 3: Geospatial & Zone Aggregation
--
-- Detecta puntos calientes de colapso agrupando emergencias por cercanía. DBSCAN es el
-- algoritmo adecuado aquí porque no exige fijar de antemano cuántos grupos hay y descarta
-- el ruido: un reporte aislado no es un punto caliente.

begin;

create table if not exists geo.clusters (
  id             uuid primary key default gen_random_uuid(),
  ciudad         comun.ciudad not null,
  centroide      extensions.geography(Point, 4326) not null,
  densidad       integer not null check (densidad > 0),
  prioridad_max  comun.prioridad not null,
  radio_m        numeric(10, 2) not null,
  -- Ventana temporal considerada para calcular el cluster.
  ventana_desde  timestamptz not null,
  ventana_hasta  timestamptz not null,
  calculado_en   timestamptz not null default now()
);

comment on table geo.clusters is
  'Puntos calientes detectados por DBSCAN sobre las emergencias de una ventana de tiempo.';

create index if not exists clusters_centroide_gix
  on geo.clusters using gist (centroide);

create index if not exists clusters_ciudad_ix
  on geo.clusters (ciudad, calculado_en desc);

-- ---------------------------------------------------------------------------
-- Clustering DBSCAN
--
-- ST_ClusterDBSCAN es una función de ventana: agrupa los puntos que tienen al menos
-- `minpoints` vecinos dentro de `eps`. Trabaja sobre geometry, no geography, así que
-- se proyecta a metros con Web Mercator (3857) para que `eps` esté en metros.
-- ---------------------------------------------------------------------------
create or replace function geo.calcular_clusters(
  p_ciudad     comun.ciudad,
  p_eps_m      numeric default 800,
  p_min_puntos integer default 3,
  p_ventana    interval default interval '24 hours'
)
returns table (
  centroide     extensions.geography,
  densidad      integer,
  prioridad_max comun.prioridad,
  radio_m       numeric
)
language sql
stable
set search_path = ''
as $$
  with puntos as (
    select
      e.id,
      e.prioridad,
      e.geom,
      -- ST_ClusterDBSCAN opera sobre geometry, no geography. Se proyecta a Web Mercator
      -- para que `eps` esté en metros. La distorsión de Mercator es de 1/cos(latitud):
      -- a las latitudes de estas cuatro ciudades (3°-6°) ronda el 0,2 %, despreciable
      -- frente a un eps de cientos de metros.
      extensions.st_transform(e.geom::extensions.geometry, 3857) as geom_m
    from intake.emergencias e
    where e.ciudad = p_ciudad
      and e.creado_en >= now() - p_ventana
  ),
  agrupados as (
    select
      p.*,
      extensions.st_clusterdbscan(p.geom_m, eps := p_eps_m, minpoints := p_min_puntos)
        over () as cluster_id
    from puntos p
  ),
  centros as (
    select
      a.cluster_id,
      count(*)::integer as densidad,
      -- min() sobre el enum devuelve el primero declarado, y comun.prioridad se declaró
      -- en orden de urgencia: P1 antes que P2. No hace falta comparar como texto.
      min(a.prioridad) as prioridad_max,
      extensions.st_transform(
        extensions.st_centroid(extensions.st_collect(a.geom_m)),
        4326
      )::extensions.geography as centroide
    from agrupados a
    -- cluster_id null = ruido para DBSCAN: reportes aislados, no puntos calientes.
    where a.cluster_id is not null
    group by a.cluster_id
  )
  select
    c.centroide,
    c.densidad,
    c.prioridad_max,
    -- Radio medido sobre geography: metros reales, sin la distorsión de Mercator.
    (
      select round(max(extensions.st_distance(a2.geom, c.centroide))::numeric, 2)
      from agrupados a2
      where a2.cluster_id = c.cluster_id
    )
  from centros c;
$$;

comment on function geo.calcular_clusters is
  'DBSCAN sobre emergencias recientes de una ciudad. Descarta el ruido (reportes aislados) y devuelve centroide, densidad, prioridad mas urgente y radio en metros.';

grant select, insert, delete on geo.clusters to svc_geo;
grant execute on function geo.calcular_clusters to svc_geo;

grant usage on schema geo to authenticated;
grant select on geo.clusters to authenticated;

alter table geo.clusters enable row level security;
alter table geo.clusters force row level security;

-- Los puntos calientes son información operativa: solo operadores.
drop policy if exists operador_lee_clusters on geo.clusters;
create policy operador_lee_clusters
  on geo.clusters for select
  to authenticated
  using (
    comun.es_operador()
    and (comun.ciudad_operador() is null or ciudad::text = comun.ciudad_operador())
  );

drop policy if exists svc_geo_clusters on geo.clusters;
create policy svc_geo_clusters
  on geo.clusters for all
  to svc_geo
  using (true) with check (true);

commit;
