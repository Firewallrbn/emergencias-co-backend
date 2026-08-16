/**
 * Patrón: Circuit Breaker.
 *
 * Cuando una dependencia (Supabase, otro servicio) está caída, seguir llamándola solo
 * consume tiempo de Lambda y empeora la latencia de toda la cadena. El breaker corta:
 * tras N fallos consecutivos pasa a ABIERTO y falla rápido sin tocar la red, y después
 * de una ventana de reposo prueba con una sola llamada (SEMIABIERTO) antes de reabrir el paso.
 *
 * Nota sobre Lambda: el estado vive en memoria del contenedor, así que es por contenedor,
 * no global. Aun así cumple su función — un contenedor que ya sabe que la dependencia está
 * caída deja de castigarla durante el resto de sus invocaciones.
 */

export type EstadoBreaker = 'CERRADO' | 'ABIERTO' | 'SEMIABIERTO';

export interface OpcionesBreaker {
  /** Fallos consecutivos que abren el circuito. */
  umbralFallos?: number;
  /** Tiempo que permanece abierto antes de permitir una llamada de prueba. */
  reposoMs?: number;
  /** Éxitos consecutivos en SEMIABIERTO para volver a cerrar. */
  umbralExitos?: number;
  nombre?: string;
}

export class CircuitoAbiertoError extends Error {
  readonly code = 'CIRCUIT_OPEN';
  constructor(nombre: string, reabreEn: number) {
    super(`Circuito "${nombre}" abierto; reintentar en ${Math.max(0, reabreEn)} ms`);
    this.name = 'CircuitoAbiertoError';
  }
}

export class CircuitBreaker {
  #estado: EstadoBreaker = 'CERRADO';
  #fallos = 0;
  #exitos = 0;
  #abiertoHasta = 0;

  readonly #umbralFallos: number;
  readonly #reposoMs: number;
  readonly #umbralExitos: number;
  readonly #nombre: string;

  constructor(opciones: OpcionesBreaker = {}) {
    this.#umbralFallos = opciones.umbralFallos ?? 5;
    this.#reposoMs = opciones.reposoMs ?? 10_000;
    this.#umbralExitos = opciones.umbralExitos ?? 2;
    this.#nombre = opciones.nombre ?? 'sin-nombre';
  }

  get estado(): EstadoBreaker {
    // El paso de ABIERTO a SEMIABIERTO es por tiempo, no por evento: se evalúa al consultar.
    if (this.#estado === 'ABIERTO' && Date.now() >= this.#abiertoHasta) {
      this.#estado = 'SEMIABIERTO';
      this.#exitos = 0;
    }
    return this.#estado;
  }

  async ejecutar<T>(operacion: () => Promise<T>): Promise<T> {
    if (this.estado === 'ABIERTO') {
      throw new CircuitoAbiertoError(this.#nombre, this.#abiertoHasta - Date.now());
    }

    try {
      const resultado = await operacion();
      this.#registrarExito();
      return resultado;
    } catch (err) {
      this.#registrarFallo();
      throw err;
    }
  }

  #registrarExito(): void {
    if (this.#estado === 'SEMIABIERTO') {
      this.#exitos++;
      if (this.#exitos >= this.#umbralExitos) this.#cerrar();
      return;
    }
    this.#fallos = 0;
  }

  #registrarFallo(): void {
    // Un solo fallo en SEMIABIERTO basta para volver a abrir: la dependencia sigue mal.
    if (this.#estado === 'SEMIABIERTO') {
      this.#abrir();
      return;
    }
    this.#fallos++;
    if (this.#fallos >= this.#umbralFallos) this.#abrir();
  }

  #abrir(): void {
    this.#estado = 'ABIERTO';
    this.#abiertoHasta = Date.now() + this.#reposoMs;
    this.#exitos = 0;
  }

  #cerrar(): void {
    this.#estado = 'CERRADO';
    this.#fallos = 0;
    this.#exitos = 0;
  }
}
