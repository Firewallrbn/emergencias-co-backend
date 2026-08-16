import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { CircuitBreaker, CircuitoAbiertoError } from './circuit-breaker.ts';

const fallar = (): Promise<never> => Promise.reject(new Error('dependencia caida'));
const exito = (): Promise<string> => Promise.resolve('ok');

async function provocarFallos(breaker: CircuitBreaker, veces: number): Promise<void> {
  for (let i = 0; i < veces; i++) {
    await breaker.ejecutar(fallar).catch(() => undefined);
  }
}

describe('CircuitBreaker', () => {
  test('arranca cerrado y deja pasar las llamadas', async () => {
    const breaker = new CircuitBreaker();
    assert.equal(breaker.estado, 'CERRADO');
    assert.equal(await breaker.ejecutar(exito), 'ok');
  });

  test('se abre al alcanzar el umbral de fallos consecutivos', async () => {
    const breaker = new CircuitBreaker({ umbralFallos: 3 });

    await provocarFallos(breaker, 2);
    assert.equal(breaker.estado, 'CERRADO', 'dos fallos no deberian abrirlo');

    await provocarFallos(breaker, 1);
    assert.equal(breaker.estado, 'ABIERTO');
  });

  test('un exito reinicia el conteo de fallos', async () => {
    const breaker = new CircuitBreaker({ umbralFallos: 3 });

    await provocarFallos(breaker, 2);
    await breaker.ejecutar(exito);
    await provocarFallos(breaker, 2);

    assert.equal(breaker.estado, 'CERRADO', 'el exito intermedio debio reiniciar el conteo');
  });

  test('abierto falla rapido sin invocar la operacion', async () => {
    const breaker = new CircuitBreaker({ umbralFallos: 1 });
    await provocarFallos(breaker, 1);

    let invocada = false;
    await assert.rejects(
      breaker.ejecutar(async () => {
        invocada = true;
        return 'no deberia llegar aqui';
      }),
      CircuitoAbiertoError,
    );
    assert.equal(invocada, false, 'no debe tocar la dependencia con el circuito abierto');
  });

  test('pasa a semiabierto tras el reposo y se cierra con suficientes exitos', async () => {
    const breaker = new CircuitBreaker({ umbralFallos: 1, reposoMs: 20, umbralExitos: 2 });
    await provocarFallos(breaker, 1);
    assert.equal(breaker.estado, 'ABIERTO');

    await new Promise((r) => setTimeout(r, 30));
    assert.equal(breaker.estado, 'SEMIABIERTO');

    await breaker.ejecutar(exito);
    assert.equal(breaker.estado, 'SEMIABIERTO', 'un solo exito no basta');

    await breaker.ejecutar(exito);
    assert.equal(breaker.estado, 'CERRADO');
  });

  test('un fallo en semiabierto vuelve a abrir de inmediato', async () => {
    const breaker = new CircuitBreaker({ umbralFallos: 1, reposoMs: 20, umbralExitos: 5 });
    await provocarFallos(breaker, 1);

    await new Promise((r) => setTimeout(r, 30));
    assert.equal(breaker.estado, 'SEMIABIERTO');

    await provocarFallos(breaker, 1);
    assert.equal(breaker.estado, 'ABIERTO');
  });
});
