/**
 * Patrón: Cache-Aside sobre AWS Systems Manager Parameter Store.
 *
 * El enunciado prohíbe archivos .env y secretos en el repositorio: la configuración se
 * recupera dinámicamente en tiempo de inicialización. La promesa se memoiza a nivel de
 * módulo, así que se paga **una sola llamada a SSM por contenedor** (cold start) y las
 * invocaciones siguientes leen de memoria.
 *
 * Se memoiza la promesa, no el resultado: si dos invocaciones concurrentes arrancan antes
 * de que la primera resuelva, ambas esperan la misma llamada en lugar de disparar dos.
 *
 * El rol IAM de cada función solo puede leer su propio prefijo — least privilege real.
 */

import { SSMClient, GetParametersByPathCommand } from '@aws-sdk/client-ssm';
import { conReintentos, esErrorTransitorio } from './retry.ts';
import { logger } from './logger.ts';

/**
 * Prefijo de parámetros, p. ej. `/emergencias/prod/intake`.
 * No es un secreto: lo fija el template SAM. El secreto es lo que hay *detrás* del prefijo.
 */
const PREFIJO = process.env['CONFIG_PREFIX'];

const cliente = new SSMClient({});

export interface Config {
  /** Cadena de conexión al rol Postgres propio del servicio (vía pooler de Supabase). */
  databaseUrl: string;
  /** URL de la cola SQS, solo en los servicios que publican. */
  queueUrl?: string;
  /** Acceso crudo a cualquier otro parámetro del prefijo. */
  raw: Readonly<Record<string, string>>;
}

async function leerParametros(prefijo: string): Promise<Record<string, string>> {
  const valores: Record<string, string> = {};
  let token: string | undefined;

  do {
    const respuesta = await cliente.send(
      new GetParametersByPathCommand({
        Path: prefijo,
        Recursive: true,
        WithDecryption: true,
        NextToken: token,
      }),
    );

    for (const p of respuesta.Parameters ?? []) {
      if (!p.Name || p.Value === undefined) continue;
      // `/emergencias/prod/intake/database_url` -> `database_url`
      const clave = p.Name.slice(prefijo.length).replace(/^\//, '');
      valores[clave] = p.Value;
    }

    token = respuesta.NextToken;
  } while (token);

  return valores;
}

async function cargar(): Promise<Config> {
  if (!PREFIJO) {
    throw new Error(
      'Falta CONFIG_PREFIX. Debe definirlo el template SAM, p. ej. /emergencias/prod/intake',
    );
  }

  const inicio = Date.now();

  const raw = await conReintentos(() => leerParametros(PREFIJO), {
    intentos: 3,
    baseMs: 150,
    esReintentable: (err) => esErrorTransitorio(err) || (err as { name?: string })?.name === 'ThrottlingException',
    alReintentar: (intento, esperaMs) =>
      logger.warn('Reintentando lectura de Parameter Store', { intento, esperaMs }),
  });

  const databaseUrl = raw['database_url'];
  if (!databaseUrl) {
    throw new Error(`No existe el parámetro ${PREFIJO}/database_url en Parameter Store`);
  }

  // Nunca loguear valores: solo cuántos y cuánto tardó.
  logger.info('Configuración cargada desde Parameter Store', {
    prefijo: PREFIJO,
    parametros: Object.keys(raw).length,
    latencyMs: Date.now() - inicio,
  });

  return { databaseUrl, queueUrl: raw['queue_url'], raw };
}

let promesaConfig: Promise<Config> | undefined;

/** Devuelve la configuración del servicio, leyéndola de SSM como mucho una vez por contenedor. */
export function obtenerConfig(): Promise<Config> {
  // Si la primera carga falló, no cacheamos el fallo: el siguiente intento vuelve a probar.
  promesaConfig ??= cargar().catch((err) => {
    promesaConfig = undefined;
    throw err;
  });
  return promesaConfig;
}

/** Solo para tests: descarta la configuración memoizada. */
export function _reiniciarConfig(): void {
  promesaConfig = undefined;
}
