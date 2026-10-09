-- =====================================================================
-- 2. Записи, занятость ресурсов, оплаты, уведомления, счётчики.
-- =====================================================================

create table public.bookings (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants (id) on delete cascade,
  service_id        uuid not null,
  resource_id       uuid not null,
  status            text not null default 'new' check (status in ('new', 'accepted', 'ready', 'done', 'cancelled')),
  starts_at         timestamptz not null,
  ends_at           timestamptz not null check (ends_at > starts_at),
  buffer_min        integer not null default 0 check (buffer_min between 0 and 240),
  -- снимок на момент записи: смена цены услуги не меняет старые записи
  service_name      text not null,
  price             numeric(10,2) not null check (price >= 0),
  client_name       text not null check (char_length(client_name) between 2 and 80),
  client_phone      text not null check (client_phone ~ '^\+[0-9]{10,15}$'),
  client_car        text not null check (char_length(client_car) between 2 and 80),
  -- доступ клиента к одной записи: в БД только sha256 токена
  access_token_hash bytea not null check (octet_length(access_token_hash) = 32),
  idempotency_key   uuid not null,
  source            text not null default 'client' check (source in ('client', 'owner')),
  is_demo           boolean not null default false,
  consent_at        timestamptz,
  consent_version   text,
  cancelled_by      text check (cancelled_by in ('client', 'owner')),
  cancelled_at      timestamptz,
  anonymized_at     timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (tenant_id, idempotency_key),
  unique (tenant_id, id),
  foreign key (tenant_id, service_id) references public.services (tenant_id, id),
  foreign key (tenant_id, resource_id) references public.resources (tenant_id, id)
);
create index bookings_tenant_start_idx on public.bookings (tenant_id, starts_at);
create trigger bookings_touch before update on public.bookings for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- Единая занятость ресурса: и записи, и блокировки владельца.
-- EXCLUDE гарантирует, что два интервала на одном ресурсе не пересекаются.
-- ---------------------------------------------------------------------
create table public.resource_occupancies (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null,
  resource_id uuid not null,
  kind        text not null check (kind in ('booking', 'block')),
  booking_id  uuid unique,
  period      tstzrange not null check (not isempty(period) and lower_inc(period) and not upper_inc(period)),
  note        text not null default '' check (char_length(note) <= 120),
  created_by  uuid,
  created_at  timestamptz not null default now(),
  foreign key (tenant_id, resource_id) references public.resources (tenant_id, id) on delete cascade,
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id) on delete cascade,
  check ((kind = 'booking') = (booking_id is not null)),
  constraint occupancy_no_overlap exclude using gist (resource_id with =, period with &&)
);
create index occupancies_tenant_period_idx on public.resource_occupancies using gist (tenant_id, period);

-- ---------------------------------------------------------------------
-- Оплаты и возвраты
-- ---------------------------------------------------------------------
create table public.payments (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null,
  booking_id uuid not null,
  kind       text not null check (kind in ('pay', 'refund')),
  amount     numeric(10,2) not null check (amount > 0),
  method     text not null default 'cash' check (method in ('cash', 'card', 'erip', 'other')),
  paid_at    timestamptz not null default now(),
  created_by uuid,
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id) on delete cascade
);
create index payments_tenant_paid_idx on public.payments (tenant_id, paid_at);

-- ---------------------------------------------------------------------
-- Web Push: подписки и outbox заданий
-- ---------------------------------------------------------------------
create table public.push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null,
  booking_id uuid not null,
  endpoint   text not null check (endpoint ~ '^https://'),
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now(),
  unique (booking_id, endpoint),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id) on delete cascade
);

create table public.notification_jobs (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null,
  booking_id  uuid not null,
  kind        text not null check (kind in ('reminder_24h')),
  run_at      timestamptz not null,
  status      text not null default 'pending' check (status in ('pending', 'processing', 'sent', 'cancelled', 'failed', 'skipped')),
  -- одно напоминание на одно время записи: перенос создаёт новый ключ, старое задание отменяется
  dedup_key   text not null unique,
  lease_until timestamptz,
  attempts    integer not null default 0,
  last_error  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id) on delete cascade
);
create index notification_jobs_due_idx on public.notification_jobs (run_at) where status in ('pending', 'processing');
create trigger notification_jobs_touch before update on public.notification_jobs for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- Общие атомарные счётчики для ограничения частоты публичных запросов
-- ---------------------------------------------------------------------
create table public.rate_counters (
  key          text not null,
  window_start timestamptz not null,
  count        integer not null default 0,
  primary key (key, window_start)
);

create or replace function public.hit_rate_limit(p_key text, p_limit integer, p_window interval) returns void
language plpgsql security definer set search_path = public as $$
declare w timestamptz := to_timestamp(floor(extract(epoch from now()) / extract(epoch from p_window)) * extract(epoch from p_window));
        c integer;
begin
  insert into rate_counters (key, window_start, count) values (p_key, w, 1)
  on conflict (key, window_start) do update set count = rate_counters.count + 1
  returning count into c;
  if c > p_limit then raise exception 'rate_limited' using errcode = 'P0001'; end if;
end $$;

-- IP клиента из заголовков PostgREST (Cloudflare/прокси); пусто при прямом вызове
create or replace function public.request_ip() returns text
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.headers', true), '')::json ->> 'cf-connecting-ip',
    split_part(coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1),
    '');
$$;
