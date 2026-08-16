/**
 * Acceso a Postgres (Supabase) desde Lambda.
 *
 * Tres decisiones que no son negociables en este entorno:
 *
 * 1. **Pooler en modo transacción** (puerto 6543 de Supavisor). Cada contenedor Lambda es un
 *    proceso independiente; sin pooler, un pico de concurrencia abre cientos de conexiones
 *    reales y tumba la base. Con pooler, cientos de contenedores comparten unas pocas.
 *
 * 2. **`max: 1` por contenedor.** Una Lambda atiende una invocación a la vez, así que un pool
 *    grande solo reserva conexiones ociosas que le quita a los demás contenedores.
 *
 * 3. **Sin prepared statements con nombre.** En modo transacción la conexión cambia entre
 *    sentencias y un statement con nombre revienta con "prepared statement does not exist".
 *    `pg` usa statements sin nombre mientras no se pase `name` en la query — así que
 *    simplemente nunca se pasa.
 *
 * El pool se crea perezosamente y se reutiliza entre invocaciones del mismo contenedor.
 * El servicio se conecta con **su propio rol Postgres**, nunca con la service_role key de
 * Supabase: así RLS sigue aplicando también al backend.
 */

import pg from 'pg';
import { obtenerConfig } from './config.ts';
import { conReintentos, esErrorTransitorio } from './retry.ts';
import { CircuitBreaker } from './circuit-breaker.ts';
import { logger } from './logger.ts';

const { Pool } = pg;

let pool: pg.Pool | undefined;

const breaker = new CircuitBreaker({
  nombre: 'postgres',
  umbralFallos: 5,
  reposoMs: 10_000,
});

async function obtenerPool(): Promise<pg.Pool> {
  if (pool) return pool;

  const { databaseUrl } = await obtenerConfig();

  pool = new Pool({
    connectionString: databaseUrl,
    max: 1,
    // Supabase exige TLS. El pooler presenta un certificado que no encadena con el
    // almacén del runtime de Lambda, así que se cifra sin verificar la cadena.
    ssl: { rejectUnauthorized: false },
    // Por debajo del timeout de la Lambda: mejor fallar rápido que agotar el tiempo.
    connectionTimeoutMillis: 5_000,
    idleTimeoutMillis: 30_000,
    keepAlive: true,
  });

  pool.on('error', (err) => {
    logger.error('Error en conexión ociosa del pool', err);
    // Un cliente ocioso caído invalida el pool: se descarta para recrearlo al vuelo.
    pool = undefined;
  });

  return pool;
}

export interface OpcionesQuery {
  /** Reintentar ante errores transitorios. Desactívalo en escrituras no idempotentes. */
  reintentar?: boolean;
}

/**
 * Ejecuta una consulta parametrizada.
 * Los valores van SIEMPRE como parámetros `$1, $2...` — nunca interpolados en el SQL.
 */
export async function consultar<T extends pg.QueryResultRow = pg.QueryResultRow>(
  sql: string,
  parametros: readonly unknown[] = [],
  opciones: OpcionesQuery = {},
): Promise<pg.QueryResult<T>> {
  const { reintentar = true } = opciones;

  const ejecutar = async (): Promise<pg.QueryResult<T>> => {
    const p = await obtenerPool();
    // Sin `name`: statement sin nombre, compatible con el pooler en modo transacción.
    return p.query<T>(sql, parametros as unknown[]);
  };

  const conBreaker = (): Promise<pg.QueryResult<T>> => breaker.ejecutar(ejecutar);

  if (!reintentar) return conBreaker();

  return conReintentos(conBreaker, {
    intentos: 3,
    baseMs: 100,
    maxMs: 1_000,
    esReintentable: esErrorTransitorio,
    alReintentar: (intento, esperaMs, err) =>
      logger.warn('Reintentando consulta', {
        intento,
        esperaMs,
        codigo: (err as { code?: string })?.code,
      }),
  });
}

/**
 * Ejecuta varias sentencias dentro de una transacción, sobre la misma conexión.
 * Necesario cuando hay que garantizar atomicidad — el pooler en modo transacción
 * respeta el bloque BEGIN/COMMIT mientras se use un único cliente.
 */
export async function enTransaccion<T>(
  trabajo: (cliente: pg.PoolClient) => Promise<T>,
): Promise<T> {
  const p = await obtenerPool();
  const cliente = await p.connect();
  try {
    await cliente.query('BEGIN');
    const resultado = await trabajo(cliente);
    await cliente.query('COMMIT');
    return resultado;
  } catch (err) {
    await cliente.query('ROLLBACK').catch(() => undefined);
    throw err;
  } finally {
    cliente.release();
  }
}

/** Sonda de salud para `GET /v1/health`. No lanza: devuelve el diagnóstico. */
export async function verificarSalud(): Promise<{ ok: boolean; latencyMs: number; detalle?: string }> {
  const inicio = Date.now();
  try {
    await consultar('SELECT 1', [], { reintentar: false });
    return { ok: true, latencyMs: Date.now() - inicio };
  } catch (err) {
    return {
      ok: false,
      latencyMs: Date.now() - inicio,
      detalle: err instanceof Error ? err.message : String(err),
    };
  }
}
