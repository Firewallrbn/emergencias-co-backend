-- 002 — Roles por servicio, tipos del dominio y helpers de RLS
--
-- Cada microservicio se conecta con su PROPIO rol Postgres. Ninguno es superusuario ni
-- lleva BYPASSRLS, así que las políticas de RLS también se aplican al backend — que es
-- justo lo que se pierde si las Lambdas usan la service_role key de Supabase.
--
-- IMPORTANTE: aquí los roles se crean SIN capacidad de login y SIN contraseña. Poner una
-- contraseña en este archivo la metería en el repositorio, que es exactamente lo que el
-- enunciado prohíbe. La contraseña se asigna una sola vez, a mano, y viaja directo a
-- AWS Parameter Store. Ver db/README.md.

begin;

-- ---------------------------------------------------------------------------
-- Tipos del dominio. Como ENUM, la base rechaza cualquier valor fuera de los
-- 4 tipos y las 4 ciudades que exige el enunciado.
-- ---------------------------------------------------------------------------
-- `to_regtype` resuelve el nombre calificado: comprobar solo por typname daría un falso
-- positivo si cualquier otro schema tuviera un tipo llamado igual, y la migración se
-- saltaría la creación dejando referencias rotas más adelante.
do $$
begin
  if to_regtype('comun.ciudad') is null then
    create type comun.ciudad as enum ('choco', 'pereira', 'cali', 'manizales');
  end if;

  if to_regtype('comun.tipo_solicitud') is null then
    create type comun.tipo_solicitud as enum ('usar_medica', 'albergue', 'suministros', 'danos');
  end if;

  if to_regtype('comun.prioridad') is null then
    create type comun.prioridad as enum ('P1', 'P2', 'P3', 'P4');
  end if;

  if to_regtype('comun.organismo') is null then
    create type comun.organismo as enum ('cruz_roja', 'bomberos', 'defensa_civil', 'ungrd');
  end if;

  if to_regtype('comun.estado_despacho') is null then
    create type comun.estado_despacho as enum
      ('pendiente', 'asignado', 'en_ruta', 'atendido', 'cancelado');
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Roles de servicio
-- ---------------------------------------------------------------------------
do $$
declare
  rol text;
begin
  foreach rol in array array['svc_intake', 'svc_dispatch', 'svc_geo', 'svc_notify'] loop
    if not exists (select 1 from pg_roles where rolname = rol) then
      -- NOLOGIN a propósito: se habilita al asignar la contraseña fuera del repositorio.
      execute format('create role %I nologin', rol);
    end if;
    execute format('grant usage on schema comun to %I', rol);
    execute format('grant usage on schema extensions to %I', rol);
  end loop;
end
$$;

-- Cada servicio usa su propio schema. Los permisos sobre tablas concretas se otorgan
-- en la migración de cada servicio, tabla por tabla — nada de GRANT ALL genérico.
grant usage on schema intake   to svc_intake;
grant usage on schema dispatch to svc_dispatch;
grant usage on schema geo      to svc_geo;
grant usage on schema notify   to svc_notify;

-- ---------------------------------------------------------------------------
-- Helpers de RLS
--
-- El rol de aplicación viaja en el JWT de Supabase, dentro de app_metadata (que el
-- usuario no puede modificar desde el cliente, a diferencia de user_metadata).
-- ---------------------------------------------------------------------------
create or replace function comun.rol_app()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb
      -> 'app_metadata' ->> 'app_role',
    'ciudadano'
  );
$$;

comment on function comun.rol_app is
  'Rol de aplicacion del JWT (ciudadano | operador). Por defecto ciudadano: ante la duda, el menos privilegiado.';

create or replace function comun.es_operador()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select comun.rol_app() = 'operador';
$$;

-- Ciudad asignada al operador; null significa "todas".
create or replace function comun.ciudad_operador()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select nullif(current_setting('request.jwt.claims', true), '')::jsonb
    -> 'app_metadata' ->> 'ciudad';
$$;

grant execute on function comun.rol_app, comun.es_operador, comun.ciudad_operador
  to anon, authenticated, svc_intake, svc_dispatch, svc_geo, svc_notify;

commit;
