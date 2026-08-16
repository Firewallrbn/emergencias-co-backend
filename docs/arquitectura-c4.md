# Arquitectura — Modelo C4

Tres niveles de zoom sobre el mismo sistema: contexto, contenedores y componentes.

> **Sobre la notación.** Los diagramas usan `flowchart` de Mermaid y no la sintaxis
> `C4Context`, que sigue marcada como experimental y produce disposiciones difíciles de
> leer. El modelo C4 define **qué** hay en cada nivel y cómo se anota, no una notación
> concreta; cada elemento lleva aquí su tipo y su tecnología, que es lo que el modelo pide.
> La ventaja práctica es que estos diagramas se renderizan en GitHub sin sorpresas.

---

## Nivel 1 — Contexto

Quién usa el sistema y con qué se habla por fuera.

```mermaid
flowchart TB
    ciudadano["<b>Ciudadano afectado</b><br/><i>[Persona]</i><br/>Reporta una emergencia<br/>desde su teléfono"]
    operador["<b>Operador de socorro</b><br/><i>[Persona]</i><br/>Cruz Roja · Bomberos<br/>Defensa Civil · UNGRD"]

    sistema["<b>Sistema de Gestión de Emergencias</b><br/><i>[Sistema de software]</i><br/>Recibe, clasifica, enruta y responde<br/>solicitudes de auxilio en Chocó,<br/>Pereira, Cali y Manizales"]

    supabase["<b>Supabase</b><br/><i>[Sistema externo]</i><br/>PostgreSQL con PostGIS.<br/>Persistencia y difusión en tiempo real"]
    aws["<b>AWS</b><br/><i>[Sistema externo]</i><br/>Cómputo serverless, secretos<br/>y gobernanza de costos"]
    mapas["<b>CARTO / OpenStreetMap</b><br/><i>[Sistema externo]</i><br/>Cartografía base"]

    ciudadano -->|"Reporta una emergencia<br/>HTTPS, funciona sin conexión"| sistema
    operador -->|"Consulta y despacha<br/>HTTPS"| sistema
    sistema -->|"Persiste y consulta<br/>SQL sobre TLS"| supabase
    sistema -.->|"Notifica cambios de estado<br/>WebSocket"| operador
    sistema -->|"Se ejecuta sobre"| aws
    sistema -->|"Solicita teselas"| mapas

    classDef persona fill:#08427b,stroke:#052e56,color:#fff
    classDef foco fill:#1168bd,stroke:#0b4884,color:#fff
    classDef externo fill:#999,stroke:#6b6b6b,color:#fff
    class ciudadano,operador persona
    class sistema foco
    class supabase,aws,mapas externo
```

**Lo que conviene notar:** la flecha de vuelta hacia el operador es punteada y sale del
sistema, no del operador. Es la difusión en tiempo real: el panel no pregunta cada pocos
segundos si hay novedades, las recibe. El enunciado lo pide explícitamente.

---

## Nivel 2 — Contenedores

Las unidades desplegables por separado y cómo se comunican.

```mermaid
flowchart TB
    ciudadano(["Ciudadano"])
    operador(["Operador"])

    subgraph vercel["Vercel · Edge"]
        pwa["<b>Aplicación web PWA</b><br/><i>[Next.js 15 · React 19]</i><br/>Formulario de radicación con cola<br/>offline y panel de comando"]
    end

    subgraph awsc["AWS · us-east-2"]
        gw["<b>API Gateway REST</b><br/><i>[stage prod]</i><br/>Punto único de entrada.<br/>Validación de esquemas, CORS y throttling"]

        intake["<b>intake</b><br/><i>[Lambda · Node 22]</i><br/>Recepción, triage determinista<br/>e idempotencia"]
        dispatch["<b>dispatch</b><br/><i>[Lambda · Node 22]</i><br/>Asignación de unidades<br/>por proximidad"]
        geo["<b>geo</b><br/><i>[Lambda · Node 22]</i><br/>Clustering DBSCAN<br/>y zonas aisladas"]
        notify["<b>notify</b><br/><i>[Lambda · Node 22]</i><br/>Notificaciones<br/>y difusión de estado"]

        cola[("<b>Cola de despachos</b><br/><i>[SQS + DLQ]</i>")]
        ssm[("<b>Parameter Store</b><br/><i>[SecureString]</i>")]
    end

    subgraph sb["Supabase · ca-central-1"]
        bd[("<b>PostgreSQL + PostGIS</b><br/><i>[un schema por servicio]</i><br/>RLS activa y forzada")]
        rt["<b>Realtime</b><br/><i>[replicación lógica]</i>"]
    end

    ciudadano --> pwa
    operador --> pwa
    pwa -->|"HTTPS · JSON"| gw
    pwa -->|"Lee con la clave anónima<br/>RLS decide qué ve"| bd
    rt -.->|"WebSocket"| pwa

    gw --> intake
    gw --> dispatch
    gw --> geo
    gw --> notify

    intake -->|"Publica"| cola
    cola -->|"Consume por lotes"| dispatch

    intake --> bd
    dispatch --> bd
    geo --> bd
    notify --> bd
    bd --> rt

    intake -.->|"Lee su configuración<br/>en el arranque en frío"| ssm
    dispatch -.-> ssm
    geo -.-> ssm
    notify -.-> ssm

    classDef persona fill:#08427b,stroke:#052e56,color:#fff
    classDef contenedor fill:#438dd5,stroke:#2e6295,color:#fff
    classDef almacen fill:#438dd5,stroke:#2e6295,color:#fff
    classDef borde fill:#85bbf0,stroke:#5d82a8,color:#000
    class ciudadano,operador persona
    class pwa,intake,dispatch,geo,notify,rt contenedor
    class cola,ssm,bd almacen
    class gw borde
```

**Tres cosas que este nivel deja ver y que son decisiones, no accidentes:**

- **La cola está entre `intake` y `dispatch`, no entre el gateway y los servicios.** Es
  donde de verdad hay riesgo de avalancha: recibir un reporte es barato, asignar una
  unidad implica una consulta geoespacial y una transacción con bloqueo.
- **El frontend lee de Supabase pero escribe por el gateway.** Las reglas de negocio
  —triage, idempotencia, despacho— viven en los microservicios; permitir escrituras
  directas las dejaría fuera del camino.
- **Cada servicio tiene su propia flecha a Parameter Store**, y su rol IAM solo alcanza su
  prefijo. No hay una configuración común que todos puedan leer.

---

## Nivel 3 — Componentes de `intake`

Se desglosa `intake` por ser el más rico; los otros tres siguen la misma estructura.

```mermaid
flowchart TB
    gw(["API Gateway"])
    cola(["Cola SQS"])
    ssm(["Parameter Store"])
    bd[("intake.emergencias")]

    subgraph fn["Lambda emergencias-intake"]
        handler["<b>handler</b><br/><i>[punto de entrada]</i><br/>Enruta e inyecta el fallo<br/>sintético del canary"]
        errores["<b>manejarErrores</b><br/><i>[shared/http]</i><br/>Traduce excepciones a<br/>respuestas con CORS"]
        validar["<b>validar</b><br/><i>[componente]</i><br/>Comprueba el payload aunque<br/>el gateway ya lo hiciera"]
        triaje["<b>calcularTriaje</b><br/><i>[función pura]</i><br/>Prioridad y puntaje<br/>deterministas"]
        repo["<b>crearEmergencia</b><br/><i>[componente]</i><br/>INSERT con ON CONFLICT<br/>sobre la clave de idempotencia"]
        publicar["<b>publicarParaDespacho</b><br/><i>[componente]</i><br/>Publica siempre, también<br/>en los duplicados"]

        subgraph compartido["packages/shared"]
            config["<b>obtenerConfig</b><br/><i>[Cache-Aside]</i>"]
            db["<b>consultar</b><br/><i>[pool pg · max 1]</i>"]
            breaker["<b>CircuitBreaker</b>"]
            retry["<b>conReintentos</b><br/><i>[backoff + jitter]</i>"]
            log["<b>logger</b><br/><i>[JSON estructurado]</i>"]
        end
    end

    gw --> handler --> errores --> validar --> triaje --> repo --> publicar
    publicar --> cola
    repo --> db --> breaker --> retry
    db --> config --> ssm
    db --> bd
    handler -.-> log

    classDef comp fill:#85bbf0,stroke:#5d82a8,color:#000
    classDef compartidoC fill:#b8d4f0,stroke:#5d82a8,color:#000
    classDef externo fill:#999,stroke:#6b6b6b,color:#fff
    class handler,errores,validar,triaje,repo,publicar comp
    class config,db,breaker,retry,log compartidoC
    class gw,cola,ssm,bd externo
```

**`calcularTriaje` es una función pura y eso es deliberado.** El enunciado exige un triage
determinista, y la única forma de demostrarlo es que no dependa de reloj, azar ni estado
externo. Por eso se puede probar sin base de datos: los tests le pasan el mismo payload
cincuenta veces y comprueban que el resultado no varía.

---

## Flujo de despliegue Canary

Lo que ocurre desde un `git push` hasta que el tráfico llega a la versión nueva —o vuelve
a la anterior.

```mermaid
sequenceDiagram
    autonumber
    actor dev as Desarrollador
    participant gh as GitHub Actions
    participant sts as AWS STS
    participant cfn as CloudFormation
    participant cd as CodeDeploy
    participant alias as Alias prod
    participant cw as CloudWatch

    dev->>gh: push a main
    gh->>gh: gitleaks · tipos · pruebas · bundle
    gh->>sts: Token OIDC firmado (sin llaves)
    sts-->>gh: Credenciales temporales
    gh->>cfn: sam deploy
    cfn->>cfn: Publica una versión nueva de Lambda
    cfn->>cd: Inicia el despliegue

    Note over cd,alias: Canary10Percent5Minutes
    cd->>alias: 10 % a la versión nueva, 90 % a la anterior

    alt Alguna alarma se activa
        cw-->>cd: ALARM
        cd->>alias: Revierte al 100 % de la versión anterior
        cd-->>gh: Despliegue detenido
        gh-->>dev: El workflow falla
    else Cinco minutos sin alarmas
        cd->>alias: 100 % a la versión nueva
        cd-->>gh: Correcto
        gh->>gh: Comprueba GET /v1/health
        gh-->>dev: Desplegado
    end
```

Las tres alarmas que vigilan la ventana:

| Alarma | Métrica | Umbral |
|---|---|---|
| `emergencias-<svc>-errores` | `AWS/Lambda Errors` sobre el alias | ≥ 1 en 1 min |
| `emergencias-<svc>-latencia` | `AWS/Lambda Duration` p95 | > 1500 ms (3000 en `geo`) |
| `emergencias-intake-api-5xx` | `AWS/ApiGateway 5XXError` | ≥ 1 en 1 min |
| `emergencias-dispatch-dlq` | Mensajes en la cola de muertos | ≥ 1 |

Las tres llevan `TreatMissingData: notBreaching`. Es el detalle que más veces rompe esta
configuración en la práctica: una alarma que se queda en `INSUFFICIENT_DATA` nunca dispara
la reversión, y el despliegue defectuoso pasa como si nada.

La evidencia de una reversión real está en
[`rollback-canary.md`](evidencias/rollback-canary.md): 2 minutos y 44 segundos desde el
despliegue defectuoso hasta el servicio recuperado, sin intervención humana.

---

## Flujo de un reporte, de principio a fin

```mermaid
sequenceDiagram
    autonumber
    actor c as Ciudadano
    participant pwa as PWA
    participant gw as API Gateway
    participant i as intake
    participant q as Cola SQS
    participant d as dispatch
    participant bd as PostgreSQL
    participant rt as Realtime
    actor op as Operador

    c->>pwa: Describe la emergencia
    pwa->>pwa: Genera la clave de idempotencia

    alt Sin conexión
        pwa->>pwa: Guarda en IndexedDB
        pwa-->>c: "Guardado, se enviará solo"
        Note over pwa: Al volver la red, reintenta<br/>con la MISMA clave
    end

    pwa->>gw: POST /v1/emergencias
    gw->>gw: Valida contra el JSON Schema
    Note over gw: Un payload inválido muere aquí,<br/>sin gastar invocación
    gw->>i: Evento proxy
    i->>i: Triage determinista → P1..P4
    i->>bd: INSERT ... ON CONFLICT (idempotency_key)
    bd-->>i: Fila (nueva o existente)
    i->>q: Publica (también si era duplicado)
    i-->>c: 201 con prioridad y número de caso

    q->>d: Consume por lotes
    d->>bd: Unidad más cercana con ST_DWithin
    d->>bd: Bloquea la unidad y crea el despacho
    bd->>rt: Replicación lógica
    rt-->>op: El panel se actualiza sin recargar
```

**El paso 11 es el que suele estar mal en implementaciones parecidas.** Publicar solo
cuando la fila es nueva parece lo lógico y esconde un fallo grave: si el `INSERT` funciona
y la publicación falla, el cliente reintenta, encuentra el duplicado, y esa emergencia se
queda registrada para siempre sin que nadie la despache. Publicar siempre cierra el hueco,
y `dispatch` ya es idempotente.
