# Imagen OCI del microservicio Geo.
#
# El contexto de build es la RAIZ del monorepo, no esta carpeta, porque el servicio
# depende del workspace @emergencias/shared. Se construye asi:
#
#   docker build -f services/geo/Dockerfile -t emergencias-geo .
#
# Multi-stage a proposito: la etapa final no contiene ni node_modules, ni codigo fuente,
# ni el compilador. Solo un archivo JavaScript con todo lo necesario ya empaquetado.

# ---------------------------------------------------------------------------------------
# Etapa 1 — compilacion
# ---------------------------------------------------------------------------------------
FROM public.ecr.aws/lambda/nodejs:22 AS builder

WORKDIR /build

# Los manifiestos primero, en una capa aparte. Docker solo reejecuta `npm ci` cuando
# cambian las dependencias, no cada vez que se toca una linea de codigo.
COPY package.json package-lock.json ./
COPY packages/shared/package.json packages/shared/
COPY services/geo/package.json services/geo/

RUN npm ci

# Ahora si, el codigo.
COPY tsconfig.base.json ./
COPY packages/shared packages/shared
COPY services/geo services/geo

# Un unico archivo con todo dentro.
#   --format=cjs      el runtime de Lambda carga el handler como CommonJS
#   --external:pg-native  pg intenta requerirlo de forma opcional para usar libpq; no lo
#                     usamos, y sin marcarlo como externo esbuild falla al no encontrarlo
RUN npx esbuild services/geo/src/index.ts \
      --bundle \
      --platform=node \
      --target=node22 \
      --format=cjs \
      --external:pg-native \
      --define:__CAOS__=false \
      --minify \
      --outfile=dist/index.js

# ---------------------------------------------------------------------------------------
# Etapa 2 — runtime
# ---------------------------------------------------------------------------------------
FROM public.ecr.aws/lambda/nodejs:22

# Un solo archivo. Nada de node_modules, nada de fuentes, nada de herramientas de build:
# menos superficie de ataque y arranques en frio mas cortos.
COPY --from=builder /build/dist/index.js ${LAMBDA_TASK_ROOT}/

CMD ["index.handler"]
