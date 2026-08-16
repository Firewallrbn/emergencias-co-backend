/**
 * Triage determinista.
 *
 * "Determinista" es un requisito explícito del enunciado, y significa dos cosas concretas:
 * el mismo payload produce siempre el mismo puntaje, y el puntaje se puede justificar.
 * Nada de aleatoriedad, nada de relojes, nada de estado externo. Por eso esta función es
 * pura y se puede probar sin base de datos.
 *
 * El puntaje se guarda junto a la emergencia para poder auditar después por qué algo quedó
 * en P1, sin tener que volver a ejecutar el algoritmo con el código de aquel momento.
 */

import { PRIORIDAD_BASE } from '@emergencias/shared';
import type { Prioridad, TipoSolicitud } from '@emergencias/shared';

/** Puntaje de partida por tipo de solicitud. */
const PUNTAJE_BASE: Readonly<Record<TipoSolicitud, number>> = {
  usar_medica: 70,
  albergue: 45,
  suministros: 30,
  danos: 15,
};

/** Umbrales de puntaje que elevan la prioridad por encima de la base del tipo. */
const UMBRAL: Readonly<Record<Exclude<Prioridad, 'P4'>, number>> = {
  P1: 80,
  P2: 55,
  P3: 30,
};

export interface DatosTriaje {
  /** Personas atrapadas bajo escombros. El factor que más pesa. */
  personas_atrapadas?: number;
  heridos?: number;
  /** Condiciones de riesgo inminente: fuga_gas, fuego, colapso, deslizamiento. */
  riesgo_inminente?: readonly string[];
  adultos?: number;
  ninos?: number;
  tercera_edad?: number;
  /** Personas afectadas en solicitudes de suministros. */
  personas?: number;
  /** leve | moderado | severo */
  agrietamiento?: string;
  /** Riesgo de colapso sobre una vía: afecta al acceso de los equipos de rescate. */
  riesgo_via?: boolean;
}

export interface ResultadoTriaje {
  prioridad: Prioridad;
  puntaje: number;
  /** Desglose legible de cómo se llegó al puntaje. Se registra en el log, no en la BD. */
  factores: readonly string[];
}

const acotar = (valor: number, min: number, max: number): number =>
  Math.min(max, Math.max(min, valor));

/**
 * Calcula prioridad y puntaje a partir del tipo de solicitud y sus datos críticos.
 *
 * Regla de seguridad: el resultado nunca puede ser MENOS urgente que la prioridad base del
 * tipo. Un reporte de rescate urbano es P1 aunque no informe cuántas personas hay
 * atrapadas — la ausencia de datos en una emergencia no es evidencia de que sea leve.
 */
export function calcularTriaje(tipo: TipoSolicitud, datos: DatosTriaje = {}): ResultadoTriaje {
  const factores: string[] = [];
  let puntaje = PUNTAJE_BASE[tipo];
  factores.push(`base ${tipo}: ${puntaje}`);

  const atrapadas = acotar(Math.trunc(datos.personas_atrapadas ?? 0), 0, 100);
  if (atrapadas > 0) {
    // Cada persona atrapada suma, pero con techo: 8 atrapados ya es la máxima urgencia
    // operativa; sumar sin límite solo distorsionaría el orden frente a otros P1.
    const suma = Math.min(20, atrapadas * 4);
    puntaje += suma;
    factores.push(`${atrapadas} atrapadas: +${suma}`);
  }

  const heridos = acotar(Math.trunc(datos.heridos ?? 0), 0, 100);
  if (heridos > 0) {
    const suma = Math.min(12, heridos * 2);
    puntaje += suma;
    factores.push(`${heridos} heridos: +${suma}`);
  }

  const riesgos = datos.riesgo_inminente ?? [];
  if (riesgos.length > 0) {
    // Fuego y fuga de gas pueden convertir un rescate en una catástrofe mayor mientras
    // la cuadrilla va en camino, así que pesan más que un riesgo estructural pasivo.
    const criticos = riesgos.filter((r) => r === 'fuego' || r === 'fuga_gas').length;
    const suma = Math.min(15, criticos * 8 + (riesgos.length - criticos) * 4);
    puntaje += suma;
    factores.push(`riesgo inminente [${riesgos.join(', ')}]: +${suma}`);
  }

  const vulnerables = acotar(Math.trunc(datos.ninos ?? 0), 0, 1000)
    + acotar(Math.trunc(datos.tercera_edad ?? 0), 0, 1000);
  if (vulnerables > 0) {
    const suma = Math.min(10, Math.ceil(vulnerables / 5));
    puntaje += suma;
    factores.push(`${vulnerables} personas vulnerables: +${suma}`);
  }

  const afectados = acotar(Math.trunc(datos.adultos ?? datos.personas ?? 0), 0, 100000);
  if (afectados > 0) {
    // Escala logarítmica: la diferencia entre 10 y 100 afectados importa mucho más que
    // la que hay entre 1000 y 1090.
    const suma = Math.min(10, Math.floor(Math.log10(afectados + 1) * 4));
    puntaje += suma;
    factores.push(`${afectados} afectados: +${suma}`);
  }

  if (datos.agrietamiento === 'severo') {
    puntaje += 10;
    factores.push('agrietamiento severo: +10');
  } else if (datos.agrietamiento === 'moderado') {
    puntaje += 5;
    factores.push('agrietamiento moderado: +5');
  }

  if (datos.riesgo_via) {
    // Una vía bloqueada no solo es un daño: impide llegar a las demás emergencias.
    puntaje += 8;
    factores.push('riesgo sobre via de acceso: +8');
  }

  puntaje = acotar(puntaje, 0, 100);

  let prioridad: Prioridad = 'P4';
  if (puntaje >= UMBRAL.P1) prioridad = 'P1';
  else if (puntaje >= UMBRAL.P2) prioridad = 'P2';
  else if (puntaje >= UMBRAL.P3) prioridad = 'P3';

  // Nunca por debajo de la prioridad base del tipo.
  const base = PRIORIDAD_BASE[tipo];
  if (prioridad > base) {
    factores.push(`elevada a ${base} por prioridad minima del tipo`);
    prioridad = base;
  }

  return { prioridad, puntaje, factores };
}
