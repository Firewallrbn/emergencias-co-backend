-- 006 — Service 4: Notification & Status Broadcast

begin;

create table if not exists notify.webhooks (
  id          uuid primary key default gen_random_uuid(),
  organismo   comun.organismo not null,
  ciudad      comun.ciudad,
  url         text not null check (url ~ '^https://'),
  activo      boolean not null default true,
  creado_en   timestamptz not null default now(),
  unique (organismo, url)
);

comment on table notify.webhooks is
  'Endpoints de los organismos de socorro. Solo https: un webhook en claro filtraria datos de victimas.';

create table if not exists notify.notificaciones (
  id             uuid primary key default gen_random_uuid(),
  emergencia_id  uuid not null,
  destinatario   text not null,
  canal          text not null check (canal in ('webhook', 'realtime', 'email')),
  asunto         text not null,
  cuerpo         jsonb not null default '{}'::jsonb,
  estado         text not null default 'pendiente'
                   check (estado in ('pendiente', 'enviada', 'fallida')),
  intentos       integer not null default 0,
  ultimo_error   text,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);

-- La cola de reenvío consulta siempre "pendientes y fallidas, más antiguas primero".
-- Índice parcial: las enviadas son la mayoría y no se consultan nunca por aquí.
create index if not exists notificaciones_pendientes_ix
  on notify.notificaciones (creado_en)
  where estado in ('pendiente', 'fallida');

create index if not exists notificaciones_emergencia_ix
  on notify.notificaciones (emergencia_id, creado_en desc);

drop trigger if exists notificaciones_tocar_actualizado on notify.notificaciones;
create trigger notificaciones_tocar_actualizado
  before update on notify.notificaciones
  for each row execute function comun.tocar_actualizado_en();

grant select, insert, update on notify.notificaciones to svc_notify;
grant select on notify.webhooks to svc_notify;

grant usage on schema notify to authenticated;
grant select on notify.notificaciones to authenticated;

alter table notify.notificaciones enable row level security;
alter table notify.notificaciones force row level security;
alter table notify.webhooks       enable row level security;
alter table notify.webhooks       force row level security;

drop policy if exists operador_lee_notificaciones on notify.notificaciones;
create policy operador_lee_notificaciones
  on notify.notificaciones for select
  to authenticated
  using (comun.es_operador());

drop policy if exists svc_notify_notificaciones on notify.notificaciones;
create policy svc_notify_notificaciones
  on notify.notificaciones for all
  to svc_notify
  using (true) with check (true);

-- Los webhooks contienen URLs internas de los organismos: ningún cliente los lee.
drop policy if exists svc_notify_webhooks on notify.webhooks;
create policy svc_notify_webhooks
  on notify.webhooks for select
  to svc_notify
  using (activo);

commit;
