-- 008 — Cerrar los avisos del linter de seguridad de Supabase
--
-- `public.rls_auto_enable()` la provisiona Supabase, no este proyecto: es una función de
-- event trigger que activa RLS automáticamente en cada tabla nueva del schema `public`.
--
-- El problema es dónde vive. Al estar en `public`, PostgREST la publica como
-- `/rest/v1/rpc/rls_auto_enable`, y siendo SECURITY DEFINER queda invocable por `anon` y
-- por `authenticated`. El linter la reporta con dos avisos (0028 y 0029).
--
-- Revocar EXECUTE no la inutiliza: los event triggers los dispara el motor con el contexto
-- de su dueño, no mediante un GRANT al rol que ejecuta el DDL. Verificado tras aplicarla:
-- una tabla nueva en `public` sigue naciendo con RLS activa.
--
-- Se envuelve en una comprobación de existencia para que la migración también corra en el
-- contenedor de validación local, donde esa función de Supabase no existe.

do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    execute 'revoke execute on function public.rls_auto_enable() from anon, authenticated';
    execute 'revoke execute on function public.rls_auto_enable() from public';
    raise notice 'Revocado EXECUTE publico sobre public.rls_auto_enable().';
  else
    raise notice 'public.rls_auto_enable() no existe aqui (entorno local): nada que revocar.';
  end if;
end
$$;
