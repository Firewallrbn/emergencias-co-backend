# Parcial 1: Arquitectura de Microservicios Serverless Resiliente para Gestión de Emergencias

**Curso:** Patrones Arquitectónicos Avanzados
**Nivel:** Pregrado en Ingeniería de Sistemas

---

## 1. Contexto y Planteamiento del Problema

En el año 2026, un evento sísmico de alta magnitud sacudió la región centro-occidente y pacífica de Colombia, afectando de manera crítica a los departamentos y ciudades de **Chocó, Pereira, Cali y Manizales**. La infraestructura convencional de telecomunicaciones y despacho de emergencias colapsó debido a picos masivos de tráfico concurrente, solicitudes duplicadas y falta de resiliencia en el procesamiento de datos geoespaciales.

El objetivo de este taller es diseñar, estructurar e implementar una solución de software de grado de producción basada en Patrones Arquitectónicos Avanzados y una arquitectura desacoplada de microservicios contenerizados y serverless. El sistema debe ser capaz de procesar, clasificar, enrutar y responder en tiempo real a las solicitudes de auxilio de la población y los cuerpos de socorro (Cruz Roja, Bomberos, Defensa Civil y UNGRD).

## 2. Objetivos de Aprendizaje

- Implementar una arquitectura orientada a microservicios contenerizados mediante imágenes OCI/Docker ejecutadas en entornos serverless (AWS Lambda).
- Diseñar y configurar un API Gateway centralizado para enrutamiento HTTP, validación de esquemas, políticas de estrangulamiento (throttling) y agregación de servicios.
- Desplegar y orquestar una capa de presentación reactiva y desacoplada utilizando Vercel para optimización de entrega perimetral (Edge delivery).
- Administrar la persistencia relacional y en tiempo real usando Supabase (PostgreSQL), aplicando Row Level Security (RLS) y particionamiento lógico de esquemas.
- Ejecutar estrategias avanzadas de despliegue continuo de backend (Canary Releases / Weighted Traffic Shifting o Feature Flags) en ambiente de producción con mecanismos automáticos de rollback.
- Eliminar por completo el uso de variables de entorno estáticas / archivos `.env` en el repositorio, adoptando un patrón de recuperación dinámica de configuración y secretos vía Parameter Store / Secrets Manager con IAM de mínimo privilegio.
- Configurar gobernanza de costos en la nube mediante presupuestos automatizados (AWS Budgets / Cloud Alerts) para evitar sobrecostos por picos de carga.

## 3. Dominio y Tipología de Solicitudes

El sistema debe gestionar obligatoriamente **cuatro tipos especializados** de solicitudes de emergencia con diferentes niveles de prioridad y flujos de trabajo:

| # | Tipo de Solicitud | Prioridad (Triage) | Zona Geográfica | Datos Críticos Requeridos |
|---|---|---|---|---|
| 1 | Búsqueda y Rescate Urbano (USAR) / Emergencia Médica | Crítica (P1) | Chocó, Pereira, Cali, Manizales | Coordenadas GPS, número de personas atrapadas/heridas, condiciones de riesgo inminente (fuga de gas, fuego). |
| 2 | Albergue y Refugio Temporal | Alta (P2) | Zonas urbanas y rurales de los 4 nodos | Conteo de damnificados (adultos, niños, tercera edad), requerimientos de accesibilidad, estado de habitabilidad de vivienda. |
| 3 | Suministros Básicos y Asistencia Humanitaria | Media (P3) | Chocó, Pereira, Cali, Manizales | Categoría de insumo (agua potable, raciones de campaña, kits de primeros auxilios, medicamentos crónicos). |
| 4 | Evaluación de Daños Estructurales | Baja / Preventiva (P4) | Infraestructura crítica y residencial | Tipo de edificación, nivel de agrietamiento o asentamiento, evidencia fotográfica, riesgo de colapso sobre vías. |

## 4. Especificación de Arquitectura de Software

### 4.1. Descomposición de Microservicios (Backend Dockerizado en AWS Lambda)

Cada microservicio debe ser completamente autónomo, poseer su propio ciclo de vida de integración/despliegue (CI/CD) y estar empaquetado como una imagen de contenedor compatible con OCI (Docker) desplegada sobre AWS Lambda:

- **Service 1 — Intake & Triage Microservice:** encargado de la recepción masiva de reportes ciudadanos, validación de integridad de payload y cálculo determinístico de severidad de triage.
- **Service 2 — Dispatch & Resource Assignment Microservice:** gestiona la asignación de unidades de rescate y cuadrillas de respuesta según disponibilidad geográfica en Chocó, Pereira, Cali y Manizales.
- **Service 3 — Geospatial & Zone Aggregation Microservice:** procesa agrupamiento geoespacial (clustering) para detectar puntos calientes de colapso y zonas aisladas.
- **Service 4 — Notification & Status Broadcast Microservice:** transmite actualizaciones de estado a los ciudadanos y organismos mediante Webhooks y eventos reactivos.

### 4.2. API Gateway y Enrutamiento HTTP

Se debe configurar un API Gateway (AWS HTTP API o REST API Gateway) como punto único de entrada:

- Enrutamiento por recurso/método hacia cada función Lambda containerizada correspondiente (e.g. `POST /v1/emergencias`, `GET /v1/emergencias/zona/{ciudad}`, `PATCH /v1/despachos/{id}`).
- Configuración explícita de CORS con políticas restrictivas para el dominio desplegado en Vercel.
- Políticas de Rate Limiting y Throttling por IP/Token para mitigar saturación y ataques de denegación de servicio durante la emergencia.
- Ambiente (Stage) configurado formalmente como `prod`.

### 4.3. Persistencia de Datos con Supabase

- Base de datos PostgreSQL administrada en Supabase con soporte para consultas geoespaciales (PostGIS habilitado para cálculos de radio y proximidad de cuadrillas).
- Modelado con esquemas desacoplados o aislamiento por tablas para respetar el principio de autonomía de microservicios.
- Implementación estricta de Row Level Security (RLS) para evitar acceso no autorizado entre roles (Ciudadano vs. Operador de Emergencias).
- Suscripciones Realtime de Supabase para actualización reactiva en el dashboard de control sin necesidad de polling repetitivo.

### 4.4. Frontend en Vercel

- Aplicación moderna (Next.js, Vite/React o SvelteKit) optimizada para tiempos de carga mínimos en redes degradadas.
- Módulo de radicación de emergencias offline-first / PWA ligero para víctimas con conectividad intermitente.
- Panel de visualización y comando para organismos de rescate con mapa interactivo de Chocó, Pereira, Cali y Manizales.
- Despliegue automatizado en la plataforma Vercel vinculado a la rama principal de producción.

### 4.5. Seguridad y Gestión de Secretos (Sin Variables de Entorno en Repositorio)

- **Restricción Estricta de Seguridad:** está terminantemente prohibido incluir archivos `.env`, llaves de API, credenciales de base de datos o secretos en los repositorios de código (ni siquiera en commits históricos).
- Los microservicios en Lambda deben recuperar sus configuraciones y secretos en tiempo de inicialización (cold start) directamente desde AWS Systems Manager Parameter Store o AWS Secrets Manager.
- La autenticación y autorización entre componentes de infraestructura debe resolverse mediante roles de ejecución IAM con el principio de menor privilegio (Least Privilege Principle).
- En el Frontend de Vercel, únicamente se autoriza la inyección de variables públicas de cliente a través del panel de configuración de entorno seguro de Vercel (Project Settings), sin exponer credenciales administrativas de Supabase (Service Role Key).

## 5. Estrategia de Despliegue en Producción (Canary / Feature Flags)

Los estudiantes deben seleccionar e implementar **una** de las siguientes dos estrategias avanzadas de despliegue continuo para el backend:

### Opción A: Despliegues Progresivos Canary con AWS CodeDeploy y Lambda Aliases

- Configurar un alias de producción (`prod`) en las funciones Lambda apuntando a las versiones publicadas.
- Definir una configuración de tráfico incremental (e.g., `Canary10Percent5Minutes` o `Linear10PercentEvery1Minute`) usando CodeDeploy / SAM / Serverless Framework.
- Establecer alarmas de Amazon CloudWatch monitoreando métricas de error (HTTP 5xx, Lambda Errors, Latency > 1500 ms).
- Validar el rollback automatizado: en caso de que la alarma se active durante la ventana del 10 % de tráfico, el sistema debe revertir inmediatamente al 100 % de la versión previa sin intervención manual.

### Opción B: Despliegue Controlado por Feature Flags & Circuit Breakers

- Integrar un motor de Feature Flags (LaunchDarkly, Flagsmith o AWS AppConfig).
- Implementar banderas dinámicas para habilitar nuevas capacidades de enrutamiento o algoritmos de triage por porcentaje de usuarios o por zona geográfica (e.g. activar nuevo algoritmo de triaje solo para Manizales y Pereira inicialmente).
- Probar el apagado de emergencia (Kill Switch) en caliente ante fallas de dependencia sin necesidad de redeploy de la infraestructura.

## 6. Gobernanza de Costos (AWS Budgets)

Para garantizar el uso eficiente de recursos y evitar cargos imprevistos en la cuenta cloud durante las pruebas de carga, cada equipo debe:

- Crear un presupuesto de costo mensual en AWS Budgets con un límite máximo estricto (ej. $10.00 USD).
- Configurar al menos dos alertas automáticas por correo electrónico:
  - **Alerta 1:** consumo real superior al 50 % del presupuesto.
  - **Alerta 2:** consumo proyectado (forecasted) superior al 85 % del presupuesto.
- Adjuntar evidencia fotográfica y reporte de configuración en la entrega final.

## 7. Fases de Desarrollo y Entregables del Taller

### Fase 1: Modelado de Dominio y Base de Datos (Semana 1)

- Definición del diagrama entidad-relación en Supabase con soporte geoespacial.
- Políticas RLS y scripts de migración reproducibles.

### Fase 2: Dockerización y Microservicios Serverless (Semana 2)

- Construcción de los `Dockerfile` optimizados (multi-stage build, tamaño mínimo de imagen OCI).
- Publicación de imágenes en Amazon ECR y despliegue a AWS Lambda.
- Implementación del cliente para lectura de secretos en AWS Parameter Store / Secrets Manager.

### Fase 3: Gateway, Enrutamiento y Frontend en Vercel (Semana 3)

- Configuración de rutas, CORS y rate limiting en API Gateway.
- Desarrollo de interfaz en Vercel con vistas diferenciadas para ciudadanos y centros de despacho por ciudad.

### Fase 4: Despliegue Progresivo

- Despliegue de la aplicación con estrategias de CI/CD. Si usa GitLab tendrá puntos extra para su entrega. (Solo desplegará el BE).

## 8. Rúbrica de Evaluación

| Criterio | Peso | Descripción del Nivel Excelente (5.0) |
|---|---|---|
| Arquitectura de Microservicios y Dominio | 20 % | Desacoplamiento total entre servicios. Cobertura completa de los 4 tipos de solicitudes y las 4 ciudades (Chocó, Pereira, Cali, Manizales). Patrones de diseño aplicados con rigor técnico. |
| Dockerización y Serverless Lambda | 20 % | Contenedores OCI altamente optimizados (multi-stage builds, imágenes ligeras), ejecución impecable en AWS Lambda sin cold-starts excesivos, logs estructurados en CloudWatch. |
| API Gateway y Gestión de Secretos | 15 % | API Gateway con enrutamiento limpio, validación de esquemas y CORS. Cero variables de entorno estáticas en repositorios; consumo dinámico vía Secrets Manager / Parameter Store con roles IAM mínimos. |
| Estrategia de Despliegue (Canary / Feature Flags) | 20 % | Implementación demostrable de tráfico gradual (Canary con CodeDeploy / Alias) o Feature Flags dinámicos. Evidencia de rollback automatizado o Kill Switch frente a inyección de errores sintéticos en producción. |
| Frontend Vercel y Supabase (Persistencia) | 15 % | Frontend desplegado en Vercel, interfaz reactiva y amigable en situaciones de estrés, integración con Supabase en tiempo real, consultas geoespaciales y políticas RLS verificadas. |
| Gobernanza de Costos y Documentación | 10 % | AWS Budgets configurado con alertas tempranas comprobadas. Diagramas C4 (Contexto, Contenedores, Componentes), manual de despliegue y video demostrativo de funcionamiento continuo. |

## 9. Requisitos de Entrega

- **Repositorios de Código:** enlaces a repositorios de GitHub/GitLab con commits limpios, sin secretos y con pipeline de CI/CD automatizado configurado.
- **URLs de Producción:**
  - Frontend activo en Vercel.
  - Endpoint base de API Gateway (Stage `prod`).
- **Informe Técnico Arquitectónico:**
  - Diagrama de arquitectura C4 y flujo de despliegue Canary / Feature Flags.
  - Evidencia de consumo de secretos desde AWS Secrets Manager / Parameter Store.
  - Capturas de pantalla de la configuración de AWS Budgets y alertas asociadas.
  - Evidencia de la prueba de resiliencia / rollback automático ante fallo en producción.
- **Video Demostrativo (máximo 5 minutos):** recorrido por el flujo completo de creación de solicitudes para las 4 ciudades y prueba en vivo del mecanismo de despliegue progresivo.
