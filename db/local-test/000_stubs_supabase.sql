-- STUBS SOLO PARA VALIDACIÓN LOCAL — NUNCA APLICAR EN SUPABASE
--
-- Supabase provisiona por su cuenta el schema `auth`, la función `auth.uid()` y los roles
-- `anon` / `authenticated`. En un Postgres limpio no existen, así que las migraciones
-- fallarían por motivos que no tienen nada que ver con su corrección.
--
-- Este archivo los recrea con la firma mínima para poder validar en Docker que las
-- migraciones compilan, que las políticas RLS se crean y que los índices son válidos,
-- sin gastar el proyecto de Supabase en ensayo y error.

-- La imagen postgis/postgis instala PostGIS en `public`, mientras que Supabase lo tiene en
-- `extensions`. Se replica el layout de Supabase para que las migraciones se validen contra
-- la misma disposición que encontrarán en producción, en vez de relajarlas para el test.
-- Sentencias planas, no dentro de un bloque DO: los DROP EXTENSION dentro de plpgsql no
-- surtieron efecto en pruebas. Este archivo siempre corre sobre un contenedor recién
-- creado, así que borrar y recrear sin condiciones es lo más simple y predecible.
-- Se recrea en lugar de mover porque postgis_topology y postgis_tiger_geocoder dependen
-- de postgis y bloquearían un ALTER EXTENSION ... SET SCHEMA.
drop extension if exists postgis_tiger_geocoder cascade;
drop extension if exists postgis_topology cascade;
drop extension if exists postgis cascade;

create schema if not exists extensions;
create extension if not exists postgis with schema extensions;

create schema if not exists auth;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end
$$;

-- En Supabase devuelve el uuid del usuario del JWT. Aquí, el mismo claim si está presente.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(
    coalesce(
      nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub',
      ''
    ),
    ''
  )::uuid;
$$;

grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid to anon, authenticated;
