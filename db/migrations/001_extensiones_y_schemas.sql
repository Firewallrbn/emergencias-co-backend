-- 001 — Extensiones y schemas
--
-- Patrón: Database per Service (aislamiento lógico). Cada microservicio es dueño de su
-- propio schema; ninguno escribe en el schema de otro. El acoplamiento permitido es
-- lectura a través de vistas explícitas (Anti-Corruption Layer, ver 004).
--
-- Idempotente: se puede ejecutar varias veces sin efecto adicional.

begin;

-- PostGIS vive en `extensions` por convención de Supabase: mantiene `public` limpio y
-- evita que las funciones de la extensión colisionen con las del proyecto.
create schema if not exists extensions;
create extension if not exists postgis with schema extensions;

-- Schema de utilidades compartidas (funciones de RLS, helpers de triage).
create schema if not exists comun;

-- Un schema por microservicio.
create schema if not exists intake;
create schema if not exists dispatch;
create schema if not exists geo;
create schema if not exists notify;

comment on schema intake   is 'Service 1: recepcion de reportes y triage determinista';
comment on schema dispatch is 'Service 2: asignacion de unidades de rescate';
comment on schema geo      is 'Service 3: agregacion geoespacial y puntos calientes';
comment on schema notify   is 'Service 4: notificaciones y broadcast de estado';

-- Las funciones de PostGIS deben resolverse sin calificar el schema en cada llamada.
alter database postgres set search_path to "$user", public, extensions;

commit;
