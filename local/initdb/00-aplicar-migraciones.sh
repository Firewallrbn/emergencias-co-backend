#!/bin/bash
# Prepara la base de la demostración local.
#
# La imagen de Postgres ejecuta los archivos de /docker-entrypoint-initdb.d en orden
# alfabético, pero solo los del primer nivel: no entra en subdirectorios. Por eso el
# proyecto monta `db/` completo en /db y este script aplica las migraciones en su orden
# real, que es el mismo que en Supabase.
set -euo pipefail

psql=(psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -v ON_ERROR_STOP=1 --quiet)

echo "== Preparando base de demostración =="

# Los mismos stubs que usa el validador: PostGIS en el schema `extensions`, schema `auth`
# y roles `anon` / `authenticated`, para replicar el layout de Supabase.
"${psql[@]}" -f /db/local-test/000_stubs_supabase.sql

for archivo in /db/migrations/*.sql; do
  echo "-- $(basename "$archivo")"
  "${psql[@]}" -f "$archivo"
done

for archivo in /db/seed/*.sql; do
  echo "-- seed $(basename "$archivo")"
  "${psql[@]}" -f "$archivo"
done

# Contraseñas de los roles de servicio.
#
# En producción se generan al azar y viven solo en Parameter Store (ver
# scripts/configurar-credenciales.ps1). Aquí es una contraseña de juguete para una base
# efímera que se destruye con `docker compose down`: no protege absolutamente nada, y
# ponerla a la vista es más honesto que fingir un secreto donde no lo hay.
: "${CLAVE_SERVICIOS_LOCAL:?falta CLAVE_SERVICIOS_LOCAL}"

for rol in svc_intake svc_dispatch svc_geo svc_notify; do
  "${psql[@]}" -c "alter role ${rol} with login password '${CLAVE_SERVICIOS_LOCAL}';"
done

echo "== Base lista: $("${psql[@]}" -tAc 'select count(*) from intake.emergencias') emergencias sembradas =="
