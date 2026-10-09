-- ===== 20261009100000_core.sql =====
-- =====================================================================
-- 1. Ядро: студии, участники, ресурсы (посты/боксы), услуги, график.
--    Один Supabase-проект на все студии; tenant_id во всех зависимых таблицах,
--    составные внешние ключи (tenant_id, id) не дают связать данные разных студий.
-- =====================================================================
create schema if not exists extensions;
create extension if not exists btree_gist with schema extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- Студии
-- ---------------------------------------------------------------------
create table public.tenants (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique check (slug ~ '^[a-z0-9-]{2,40}$'),
  -- preview: только помеченные demo-данные, без реальных уведомлений; live: после проверки настроек
  mode         text not null default 'preview' check (mode in ('preview', 'live')),
  timezone     text not null default 'Europe/Minsk',
  -- публичный профиль: название, тексты, контакты, акцент, карточки, медиа, правила записи, оператор ПД
  profile      jsonb not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  went_live_at timestamptz
);

create table public.tenant_members (
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  role       text not null default 'owner' check (role in ('owner')),
  created_at timestamptz not null default now(),
  primary key (tenant_id, user_id)
);
create index tenant_members_user_idx on public.tenant_members (user_id);

-- ---------------------------------------------------------------------
-- Ресурсы (посты, боксы, подъёмники) и услуги
-- ---------------------------------------------------------------------
create table public.resources (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  key        text not null check (key ~ '^[a-z0-9_-]{1,40}$'),
  name       text not null check (char_length(name) between 1 and 40),
  active     boolean not null default true,
  sort       integer not null default 0,
  unique (tenant_id, key),
  unique (tenant_id, id)
);

create table public.services (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete cascade,
  key          text not null check (key ~ '^[a-z0-9_-]{1,40}$'),
  name         text not null check (char_length(name) between 2 and 80),
  description  text not null default '' check (char_length(description) <= 200),
  price        numeric(10,2) not null check (price >= 0),
  -- непрерывная длительность занятия ресурса в минутах (многодневные работы — тоже в минутах: 2 дня = 2880)
  duration_min integer not null check (duration_min between 15 and 20160),
  active       boolean not null default true,
  sort         integer not null default 0,
  unique (tenant_id, key),
  unique (tenant_id, id)
);

-- На каких ресурсах можно оказывать услугу (пусто = на любом активном ресурсе студии)
create table public.service_resources (
  tenant_id   uuid not null,
  service_id  uuid not null,
  resource_id uuid not null,
  primary key (service_id, resource_id),
  foreign key (tenant_id, service_id) references public.services (tenant_id, id) on delete cascade,
  foreign key (tenant_id, resource_id) references public.resources (tenant_id, id) on delete cascade
);

-- ---------------------------------------------------------------------
-- График: рабочие часы задают моменты приёма машин
-- ---------------------------------------------------------------------
create table public.working_hours (
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  weekday   smallint not null check (weekday between 0 and 6), -- 0 = воскресенье
  opens     time not null,
  closes    time not null check (closes > opens),
  primary key (tenant_id, weekday)
);

create table public.schedule_exceptions (
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  day       date not null,
  closed    boolean not null default true,
  opens     time,
  closes    time,
  note      text not null default '' check (char_length(note) <= 80),
  source    text not null default 'owner' check (source in ('config', 'owner')),
  primary key (tenant_id, day),
  check (closed or (opens is not null and closes is not null and closes > opens))
);

-- ---------------------------------------------------------------------
-- Фото работ. source = 'owner' — загружено владельцем, переиздание конфига их не трогает
-- ---------------------------------------------------------------------
create table public.works (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  key        text,
  photo_url  text not null,
  caption    text not null check (char_length(caption) between 1 and 120),
  sort       integer not null default 0,
  source     text not null default 'owner' check (source in ('config', 'owner')),
  created_at timestamptz not null default now(),
  unique (tenant_id, key)
);

-- ---------------------------------------------------------------------
-- Членство и общие проверки
-- ---------------------------------------------------------------------
create or replace function public.is_member(p_tenant uuid) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from tenant_members where tenant_id = p_tenant and user_id = auth.uid());
$$;

create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
create trigger tenants_touch before update on public.tenants for each row execute function public.touch_updated_at();

create or replace function public.tenants_guard() returns trigger
language plpgsql set search_path = public, extensions as $$
begin
  if not exists (select 1 from pg_timezone_names where name = new.timezone) then
    raise exception 'config_invalid: неизвестный часовой пояс' using errcode = '22023';
  end if;
  if new.mode = 'live' and jsonb_typeof(new.profile -> 'legal') is distinct from 'object' then
    raise exception 'config_invalid: для live нужны данные оператора ПД' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' and new.mode = 'live' and old.mode = 'preview' then
    new.went_live_at := now();
  end if;
  return new;
end $$;
create trigger tenants_guard before insert or update on public.tenants for each row execute function public.tenants_guard();


-- ===== 20261009100100_bookings.sql =====
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
language plpgsql security definer set search_path = public, extensions as $$
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


-- ===== 20261009100200_booking_functions.sql =====
-- =====================================================================
-- 3. Правила графика и атомарные операции с записями.
--    Клиент передаёт только услугу, день и время приёма. Цену, студию,
--    длительность и ресурс определяет сервер.
-- =====================================================================

-- Телефон РБ → +375XXXXXXXXX (как normalizeBYPhone в src/shared/by.ts)
create or replace function public.norm_phone(p text) returns text
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g');
begin
  if d ~ '^375[0-9]{9}$' then return '+' || d; end if;
  if d ~ '^80[0-9]{9}$' then return '+375' || substr(d, 3); end if;
  if d ~ '^[0-9]{9}$' and d ~ '^(17|25|29|33|44|1[5-6]|2[1-3])' then return '+375' || d; end if;
  if btrim(coalesce(p, '')) like '+%' and d ~ '^[0-9]{10,15}$' then return '+' || d; end if;
  raise exception 'bad_phone' using errcode = 'P0001';
end $$;

create or replace function public.rule_int(t public.tenants, k text, dflt integer) returns integer
language sql immutable as $$ select coalesce((t.profile -> 'booking' ->> k)::int, dflt) $$;

-- Окно приёма на день: исключение важнее обычного графика. Пусто = закрыто.
create or replace function public.day_window(p_tenant uuid, p_day date)
returns table (opens time, closes time)
language plpgsql stable security definer set search_path = public, extensions as $$
declare e schedule_exceptions;
begin
  select * into e from schedule_exceptions where tenant_id = p_tenant and day = p_day;
  if found then
    if not e.closed then return query select e.opens, e.closes; end if;
    return;
  end if;
  return query select w.opens, w.closes from working_hours w
    where w.tenant_id = p_tenant and w.weekday = extract(dow from p_day)::smallint;
end $$;

-- Ресурсы, подходящие для услуги, в порядке предпочтения
create or replace function public.eligible_resources(p_tenant uuid, p_service uuid)
returns setof uuid
language sql stable security definer set search_path = public, extensions as $$
  select r.id from resources r
   where r.tenant_id = p_tenant and r.active
     and (not exists (select 1 from service_resources sr where sr.service_id = p_service)
          or exists (select 1 from service_resources sr where sr.service_id = p_service and sr.resource_id = r.id))
   order by r.sort, r.key;
$$;

/*
  Проверяет момент приёма и возвращает интервал работ.
  - день открыт (график или исключение), время внутри окна приёма и кратно шагу от открытия;
  - работы до 12 часов должны закончиться до закрытия этого дня;
  - более длинные работы занимают ресурс непрерывно, через ночь и выходные;
  - клиент: не раньше чем через leadMin и не дальше horizonDays; владелец: не в прошлом (с допуском 1 сутки).
*/
create or replace function public.resolve_interval(
  t public.tenants, p_day date, p_time time, p_duration integer, p_source text,
  out starts_at timestamptz, out ends_at timestamptz
) language plpgsql stable security definer set search_path = public, extensions as $$
declare w record; step int := public.rule_int(t, 'stepMin', 30);
        lead int := public.rule_int(t, 'leadMin', 60);
        horizon int := public.rule_int(t, 'horizonDays', 30);
        local_today date := (now() at time zone t.timezone)::date;
begin
  select * into w from public.day_window(t.id, p_day);
  if not found then raise exception 'closed' using errcode = 'P0001'; end if;
  if p_time < w.opens or p_time >= w.closes
     or (extract(epoch from (p_time - w.opens))::int / 60) % step <> 0 then
    raise exception 'outside_hours' using errcode = 'P0001';
  end if;
  if p_duration <= 720 and p_time + make_interval(mins => p_duration) > w.closes then
    raise exception 'outside_hours' using errcode = 'P0001';
  end if;
  starts_at := (p_day + p_time) at time zone t.timezone;
  ends_at := starts_at + make_interval(mins => p_duration);
  if p_source = 'client' then
    if starts_at < now() + make_interval(mins => lead) then raise exception 'too_soon' using errcode = 'P0001'; end if;
    if p_day > local_today + horizon then raise exception 'too_far' using errcode = 'P0001'; end if;
  elsif starts_at < now() - interval '1 day' then
    raise exception 'in_past' using errcode = 'P0001';
  end if;
end $$;

create or replace function public.token_hash(p_token text) returns bytea
language plpgsql immutable set search_path = public, extensions as $$
begin
  if p_token is null or char_length(p_token) < 32 or char_length(p_token) > 128 then
    raise exception 'bad_token' using errcode = 'P0001';
  end if;
  return digest(p_token, 'sha256');
end $$;

-- ---------------------------------------------------------------------
-- Свободное время (публично; персональные данные не раскрываются)
-- ---------------------------------------------------------------------
create or replace function public.get_availability(p_slug text, p_service_id uuid, p_from date, p_days integer default 14)
returns table (day date, closed boolean, slot_time time, starts_at timestamptz, free boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
declare t tenants; s services; d date; w record; tm time; st timestamptz; per tstzrange;
        step int; lead int; horizon int; buf int; local_today date; free_any boolean;
begin
  select * into t from tenants where slug = p_slug;
  if not found then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
  select * into s from services where tenant_id = t.id and id = p_service_id and active;
  if not found then raise exception 'service_not_found' using errcode = 'P0001'; end if;
  step := public.rule_int(t, 'stepMin', 30); lead := public.rule_int(t, 'leadMin', 60);
  horizon := public.rule_int(t, 'horizonDays', 30); buf := public.rule_int(t, 'bufferMin', 0);
  local_today := (now() at time zone t.timezone)::date;

  for d in select generate_series(greatest(p_from, local_today), least(p_from + least(greatest(p_days, 1), 62) - 1, local_today + horizon), interval '1 day')::date loop
    select * into w from public.day_window(t.id, d);
    if not found then
      day := d; closed := true; slot_time := null; starts_at := null; free := false; return next; continue;
    end if;
    tm := w.opens;
    while tm < w.closes and (s.duration_min > 720 or tm + make_interval(mins => s.duration_min) <= w.closes) loop
      st := (d + tm) at time zone t.timezone;
      if st >= now() + make_interval(mins => lead) then
        per := tstzrange(st, st + make_interval(mins => s.duration_min + buf), '[)');
        select exists (
          select 1 from public.eligible_resources(t.id, s.id) r(id)
           where not exists (select 1 from resource_occupancies o where o.resource_id = r.id and o.period && per)
        ) into free_any;
        day := d; closed := false; slot_time := tm; starts_at := st; free := free_any; return next;
      end if;
      tm := tm + make_interval(mins => step);
      exit when tm <= w.opens; -- защита от перехода через полночь
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Внутреннее: постановка/перенос/отмена напоминаний (outbox)
-- ---------------------------------------------------------------------
create or replace function public.sync_reminder(p_booking uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b bookings; t tenants; key text;
begin
  select * into b from bookings where id = p_booking;
  select * into t from tenants where id = b.tenant_id;
  key := b.id || ':reminder_24h:' || extract(epoch from b.starts_at)::bigint;
  -- отменяем всё, что не соответствует текущему времени записи или статусу
  update notification_jobs set status = 'cancelled', lease_until = null
   where booking_id = b.id and status in ('pending', 'processing') and (dedup_key <> key or b.status in ('cancelled', 'done'));
  if b.status in ('cancelled', 'done') or b.anonymized_at is not null then return; end if;
  if not exists (select 1 from push_subscriptions where booking_id = b.id) then return; end if;
  insert into notification_jobs (tenant_id, booking_id, kind, run_at, dedup_key, status)
  values (b.tenant_id, b.id, 'reminder_24h', greatest(b.starts_at - interval '1 day', now()), key,
          -- preview-студии и demo-записи реальных уведомлений не получают
          case when t.mode = 'live' and not b.is_demo and b.starts_at - now() > interval '2 hours' then 'pending' else 'skipped' end)
  on conflict (dedup_key) do nothing;
end $$;

-- ---------------------------------------------------------------------
-- Создание записи клиентом (одна транзакция)
-- ---------------------------------------------------------------------
create or replace function public.create_booking(
  p_slug text, p_service_id uuid, p_day date, p_time time,
  p_name text, p_phone text, p_car text,
  p_idempotency_key uuid, p_access_token text,
  p_consent boolean, p_consent_version text
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare t tenants; s services; b bookings; h bytea; phone text; iv record; r uuid; bid uuid; ip text := public.request_ip();
begin
  select * into t from tenants where slug = p_slug;
  if not found then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
  h := public.token_hash(p_access_token);

  -- повтор того же запроса: возвращаем ту же запись, если токен совпадает
  select * into b from bookings where tenant_id = t.id and idempotency_key = p_idempotency_key;
  if found then
    if b.access_token_hash <> h then raise exception 'idempotency_conflict' using errcode = 'P0001'; end if;
    return b.id;
  end if;

  if p_consent is not true then raise exception 'consent_required' using errcode = 'P0001'; end if;
  phone := public.norm_phone(p_phone);
  if char_length(btrim(coalesce(p_name, ''))) < 2 or char_length(btrim(coalesce(p_car, ''))) < 2 then
    raise exception 'bad_client_data' using errcode = 'P0001';
  end if;

  if ip <> '' then perform public.hit_rate_limit('book-ip:' || ip, 20, interval '1 hour'); end if;
  perform public.hit_rate_limit('book-phone:' || t.id || ':' || phone, 5, interval '1 day');
  perform public.hit_rate_limit('book-tenant:' || t.id, 30, interval '1 minute');

  select * into s from services where tenant_id = t.id and id = p_service_id and active;
  if not found then raise exception 'service_not_found' using errcode = 'P0001'; end if;
  select * into iv from public.resolve_interval(t, p_day, p_time, s.duration_min, 'client');

  begin
    for r in select * from public.eligible_resources(t.id, s.id) loop
      begin
        insert into bookings (tenant_id, service_id, resource_id, starts_at, ends_at, buffer_min, service_name, price,
                              client_name, client_phone, client_car, access_token_hash, idempotency_key, source,
                              is_demo, consent_at, consent_version)
        values (t.id, s.id, r, iv.starts_at, iv.ends_at, public.rule_int(t, 'bufferMin', 0), s.name, s.price,
                btrim(p_name), phone, btrim(p_car), h, p_idempotency_key, 'client',
                t.mode = 'preview', now(), left(coalesce(p_consent_version, 'v1'), 40))
        returning id into bid;
        insert into resource_occupancies (tenant_id, resource_id, kind, booking_id, period)
        values (t.id, r, 'booking', bid, tstzrange(iv.starts_at, iv.ends_at + make_interval(mins => public.rule_int(t, 'bufferMin', 0)), '[)'));
        return bid;
      exception when exclusion_violation then
        null; -- ресурс занят — пробуем следующий
      end;
    end loop;
  exception when unique_violation then
    -- тот же запрос пришёл параллельно и уже записан
    select * into b from bookings where tenant_id = t.id and idempotency_key = p_idempotency_key;
    if found and b.access_token_hash = h then return b.id; end if;
    raise exception 'idempotency_conflict' using errcode = 'P0001';
  end;
  raise exception 'slot_taken' using errcode = 'P0001';
end $$;

-- ---------------------------------------------------------------------
-- Доступ клиента к своей записи по токену
-- ---------------------------------------------------------------------
create or replace function public.booking_by_token(p_booking uuid, p_token text) returns public.bookings
language plpgsql stable security definer set search_path = public, extensions as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking and access_token_hash = public.token_hash(p_token);
  if not found or b.anonymized_at is not null then raise exception 'not_found' using errcode = 'P0001'; end if;
  return b;
end $$;

create or replace function public.get_my_booking(p_booking uuid, p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare b bookings; t tenants; res text; cancel_h int; job text;
begin
  b := public.booking_by_token(p_booking, p_token);
  select * into t from tenants where id = b.tenant_id;
  select name into res from resources where id = b.resource_id;
  cancel_h := public.rule_int(t, 'cancelHours', 4);
  select status into job from notification_jobs where booking_id = b.id order by created_at desc limit 1;
  return jsonb_build_object(
    'id', b.id, 'slug', t.slug, 'timezone', t.timezone, 'serviceName', b.service_name, 'price', b.price,
    'startsAt', b.starts_at, 'endsAt', b.ends_at, 'resourceName', res, 'status', b.status,
    'clientName', b.client_name, 'clientCar', b.client_car, 'isDemo', b.is_demo,
    'cancelHours', cancel_h,
    'canCancel', b.status = 'new' and b.starts_at - now() >= make_interval(hours => cancel_h),
    'reminder', coalesce(job, 'none'));
end $$;

create or replace function public.cancel_booking_internal(p_booking uuid, p_by text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  update bookings set status = 'cancelled', cancelled_by = p_by, cancelled_at = now() where id = p_booking;
  delete from resource_occupancies where booking_id = p_booking; -- время сразу освобождается
  perform public.sync_reminder(p_booking);
end $$;

create or replace function public.cancel_my_booking(p_booking uuid, p_token text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b bookings; t tenants;
begin
  b := public.booking_by_token(p_booking, p_token);
  perform 1 from bookings where id = b.id for update;
  select * into t from tenants where id = b.tenant_id;
  if b.status <> 'new' then raise exception 'cannot_cancel_status' using errcode = 'P0001'; end if;
  if b.starts_at - now() < make_interval(hours => public.rule_int(t, 'cancelHours', 4)) then
    raise exception 'cannot_cancel_late' using errcode = 'P0001';
  end if;
  perform public.cancel_booking_internal(b.id, 'client');
end $$;

create or replace function public.save_push_subscription(p_booking uuid, p_token text, p_endpoint text, p_p256dh text, p_auth text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare b bookings; st text;
begin
  b := public.booking_by_token(p_booking, p_token);
  perform public.hit_rate_limit('push:' || b.id, 10, interval '1 hour');
  if char_length(p_endpoint) > 1000 or char_length(p_p256dh) > 200 or char_length(p_auth) > 100 then
    raise exception 'too_large' using errcode = 'P0001';
  end if;
  insert into push_subscriptions (tenant_id, booking_id, endpoint, p256dh, auth)
  values (b.tenant_id, b.id, p_endpoint, p_p256dh, p_auth)
  on conflict (booking_id, endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth;
  perform public.sync_reminder(b.id);
  select status into st from notification_jobs where booking_id = b.id order by created_at desc limit 1;
  return coalesce(st, 'none');
end $$;


-- ===== 20261009100300_owner.sql =====
-- =====================================================================
-- 4. Кабинет владельца: ручная запись, перенос, статусы, блокировки,
--    оплаты, статистика (считает SQL), удаление ПД.
--    Студия владельца подтверждается членством в tenant_members на сервере.
-- =====================================================================

create or replace function public.require_member(p_tenant uuid) returns void
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if auth.uid() is null or not public.is_member(p_tenant) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
end $$;

create or replace function public.owner_create_booking(
  p_tenant uuid, p_service_id uuid, p_day date, p_time time,
  p_name text, p_phone text, p_car text, p_idempotency_key uuid, p_resource_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare t tenants; s services; b bookings; iv record; r uuid; bid uuid; phone text;
begin
  perform public.require_member(p_tenant);
  select * into t from tenants where id = p_tenant;
  select * into b from bookings where tenant_id = t.id and idempotency_key = p_idempotency_key;
  if found then return b.id; end if;
  select * into s from services where tenant_id = t.id and id = p_service_id;
  if not found then raise exception 'service_not_found' using errcode = 'P0001'; end if;
  phone := public.norm_phone(p_phone);
  select * into iv from public.resolve_interval(t, p_day, p_time, s.duration_min, 'owner');
  for r in
    select x from public.eligible_resources(t.id, s.id) x
     where p_resource_id is null or x = p_resource_id
  loop
    begin
      insert into bookings (tenant_id, service_id, resource_id, starts_at, ends_at, buffer_min, service_name, price,
                            client_name, client_phone, client_car, access_token_hash, idempotency_key, source, is_demo)
      values (t.id, s.id, r, iv.starts_at, iv.ends_at, public.rule_int(t, 'bufferMin', 0), s.name, s.price,
              btrim(p_name), phone, btrim(p_car), digest(gen_random_uuid()::text, 'sha256'), p_idempotency_key, 'owner',
              t.mode = 'preview')
      returning id into bid;
      insert into resource_occupancies (tenant_id, resource_id, kind, booking_id, period, created_by)
      values (t.id, r, 'booking', bid, tstzrange(iv.starts_at, iv.ends_at + make_interval(mins => public.rule_int(t, 'bufferMin', 0)), '[)'), auth.uid());
      return bid;
    exception when exclusion_violation then null;
    end;
  end loop;
  raise exception 'slot_taken' using errcode = 'P0001';
end $$;

/*
  Перенос: одна транзакция. Длительность берётся из самой записи (снимок),
  поэтому изменение услуги в настройках не меняет уже принятую работу.
  Если свободного ресурса нет — исключение, и исходная запись остаётся как была.
*/
create or replace function public.owner_move_booking(p_booking uuid, p_day date, p_time time, p_resource_id uuid default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b bookings; t tenants; iv record; r uuid; dur int; per tstzrange;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  perform public.require_member(b.tenant_id);
  if b.status in ('done', 'cancelled') then raise exception 'cannot_move_status' using errcode = 'P0001'; end if;
  select * into t from tenants where id = b.tenant_id;
  dur := (extract(epoch from (b.ends_at - b.starts_at)) / 60)::int;
  select * into iv from public.resolve_interval(t, p_day, p_time, dur, 'owner');
  per := tstzrange(iv.starts_at, iv.ends_at + make_interval(mins => b.buffer_min), '[)');
  for r in
    select x from public.eligible_resources(t.id, b.service_id) x
     where p_resource_id is null or x = p_resource_id
     order by x is distinct from b.resource_id
  loop
    begin
      update resource_occupancies set resource_id = r, period = per where booking_id = b.id;
      update bookings set resource_id = r, starts_at = iv.starts_at, ends_at = iv.ends_at where id = b.id;
      perform public.sync_reminder(b.id);
      return;
    exception when exclusion_violation then null;
    end;
  end loop;
  raise exception 'slot_taken' using errcode = 'P0001';
end $$;

create or replace function public.owner_set_status(p_booking uuid, p_status text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  perform public.require_member(b.tenant_id);
  if p_status = 'cancelled' then
    if b.status in ('done', 'cancelled') then raise exception 'bad_transition' using errcode = 'P0001'; end if;
    perform public.cancel_booking_internal(b.id, 'owner');
    return;
  end if;
  if not ((b.status = 'new' and p_status = 'accepted')
       or (b.status = 'accepted' and p_status in ('ready', 'new'))
       or (b.status = 'ready' and p_status in ('done', 'accepted'))) then
    raise exception 'bad_transition' using errcode = 'P0001';
  end if;
  update bookings set status = p_status where id = b.id;
  perform public.sync_reminder(b.id);
end $$;

create or replace function public.owner_add_payment(p_booking uuid, p_kind text, p_amount numeric, p_method text default 'cash') returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b bookings; paid numeric;
begin
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  perform public.require_member(b.tenant_id);
  if p_kind not in ('pay', 'refund') or p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) or p_amount > 1000000 then
    raise exception 'bad_amount' using errcode = 'P0001';
  end if;
  if p_kind = 'refund' then
    select coalesce(sum(case when kind = 'pay' then amount else -amount end), 0) into paid from payments where booking_id = b.id;
    if p_amount > paid then raise exception 'refund_exceeds_paid' using errcode = 'P0001'; end if;
  end if;
  insert into payments (tenant_id, booking_id, kind, amount, method, created_by)
  values (b.tenant_id, b.id, p_kind, p_amount, coalesce(p_method, 'cash'), auth.uid());
end $$;

-- Блокировка поста (ремонт, закрытие части дня). Пересечение с записью или другой блокировкой запрещено.
create or replace function public.owner_block_resource(p_resource_id uuid, p_from timestamptz, p_to timestamptz, p_note text default '') returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare res resources; oid uuid;
begin
  select * into res from resources where id = p_resource_id;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  perform public.require_member(res.tenant_id);
  if p_to <= p_from or p_to - p_from > interval '60 days' then raise exception 'bad_range' using errcode = 'P0001'; end if;
  begin
    insert into resource_occupancies (tenant_id, resource_id, kind, period, note, created_by)
    values (res.tenant_id, res.id, 'block', tstzrange(p_from, p_to, '[)'), left(coalesce(p_note, ''), 120), auth.uid())
    returning id into oid;
  exception when exclusion_violation then
    raise exception 'block_conflict' using errcode = 'P0001';
  end;
  return oid;
end $$;

create or replace function public.owner_unblock(p_occupancy uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare o resource_occupancies;
begin
  select * into o from resource_occupancies where id = p_occupancy and kind = 'block';
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  perform public.require_member(o.tenant_id);
  delete from resource_occupancies where id = o.id;
end $$;

/*
  Статистика за период [p_from; p_to] включительно, в часовом поясе студии.
  visits     — заезды: записи (не отменённые) с началом в периоде;
  completed  — выполненные заказы: статус done, начало в периоде;
  received   — полученные деньги: оплаты минус возвраты по дате оплаты;
  expected   — ожидаемая стоимость ещё не выполненных записей периода (это НЕ выручка).
*/
create or replace function public.owner_stats(p_tenant uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare t tenants; f timestamptz; u timestamptz; res jsonb;
begin
  perform public.require_member(p_tenant);
  select * into t from tenants where id = p_tenant;
  if p_to < p_from or p_to - p_from > 366 then raise exception 'bad_range' using errcode = 'P0001'; end if;
  f := p_from::timestamp at time zone t.timezone;
  u := (p_to + 1)::timestamp at time zone t.timezone;
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'timezone', t.timezone,
    'visits',    (select count(*) from bookings where tenant_id = t.id and status <> 'cancelled' and starts_at >= f and starts_at < u),
    'completed', (select count(*) from bookings where tenant_id = t.id and status = 'done' and starts_at >= f and starts_at < u),
    'cancelled', (select count(*) from bookings where tenant_id = t.id and status = 'cancelled' and starts_at >= f and starts_at < u),
    'received',  (select coalesce(sum(case when kind = 'pay' then amount else 0 end), 0) from payments where tenant_id = t.id and paid_at >= f and paid_at < u),
    'refunded',  (select coalesce(sum(case when kind = 'refund' then amount else 0 end), 0) from payments where tenant_id = t.id and paid_at >= f and paid_at < u),
    'net',       (select coalesce(sum(case when kind = 'pay' then amount else -amount end), 0) from payments where tenant_id = t.id and paid_at >= f and paid_at < u),
    'expected',  (select coalesce(sum(price), 0) from bookings where tenant_id = t.id and status in ('new', 'accepted', 'ready') and starts_at >= f and starts_at < u)
  ) into res;
  return res;
end $$;

-- ---------------------------------------------------------------------
-- Персональные данные (Закон РБ № 99-З): удаление по просьбе и по сроку
-- ---------------------------------------------------------------------
create or replace function public.anonymize_booking_internal(p_booking uuid) returns void
language sql security definer set search_path = public, extensions as $$
  update bookings set client_name = 'Обезличено', client_phone = '+375000000000', client_car = 'Обезличено',
         access_token_hash = digest(gen_random_uuid()::text, 'sha256'), anonymized_at = now()
   where id = p_booking and anonymized_at is null;
  delete from push_subscriptions where booking_id = p_booking;
  update notification_jobs set status = 'cancelled' where booking_id = p_booking and status in ('pending', 'processing');
$$;

create or replace function public.owner_anonymize_booking(p_booking uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  perform public.require_member(b.tenant_id);
  if b.status not in ('done', 'cancelled') then raise exception 'cannot_anonymize_active' using errcode = 'P0001'; end if;
  perform public.anonymize_booking_internal(b.id);
end $$;

create or replace function public.purge_expired_personal_data() returns integer
language plpgsql security definer set search_path = public, extensions as $$
declare r record; n int := 0;
begin
  for r in
    select b.id from bookings b join tenants t on t.id = b.tenant_id
     where b.anonymized_at is null
       and b.ends_at < now() - make_interval(days => coalesce((t.profile -> 'legal' ->> 'retentionDays')::int, 365))
  loop
    perform public.anonymize_booking_internal(r.id); n := n + 1;
  end loop;
  delete from rate_counters where window_start < now() - interval '2 days';
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Outbox: выдача заданий воркеру с арендой (lease) и завершение
-- ---------------------------------------------------------------------
create or replace function public.claim_notification_jobs(p_limit integer default 20, p_lease_seconds integer default 120)
returns table (job_id uuid, booking_id uuid, tenant_slug text, tenant_name text, timezone text,
               service_name text, starts_at timestamptz, address text, endpoint text, p256dh text, auth text)
language plpgsql security definer set search_path = public, extensions as $$
begin
  return query
  with due as (
    select j.id from notification_jobs j
     where (j.status = 'pending' or (j.status = 'processing' and j.lease_until < now()))
       and j.run_at <= now()
       and exists (select 1 from push_subscriptions ps where ps.booking_id = j.booking_id)
     order by j.run_at
     limit greatest(1, least(p_limit, 100))
     for update skip locked
  ), claimed as (
    update notification_jobs j set status = 'processing', lease_until = now() + make_interval(secs => p_lease_seconds), attempts = j.attempts + 1
      from due where j.id = due.id
    returning j.id, j.booking_id
  )
  select c.id, b.id, t.slug, t.profile ->> 'name', t.timezone, b.service_name, b.starts_at, t.profile ->> 'address',
         s.endpoint, s.p256dh, s.auth
    from claimed c
    join bookings b on b.id = c.booking_id
    join tenants t on t.id = b.tenant_id
    join push_subscriptions s on s.booking_id = b.id;
end $$;

create or replace function public.complete_notification_job(p_job uuid, p_status text, p_error text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_status not in ('sent', 'failed', 'pending') then raise exception 'bad_status' using errcode = 'P0001'; end if;
  update notification_jobs
     set status = case when p_status = 'pending' and attempts >= 5 then 'failed' else p_status end,
         lease_until = null, last_error = left(p_error, 500),
         run_at = case when p_status = 'pending' then now() + make_interval(mins => 5 * attempts) else run_at end
   where id = p_job and status = 'processing';
end $$;


-- ===== 20261009100400_security.sql =====
-- =====================================================================
-- 5. Права доступа: RLS на всех таблицах и строгие GRANT.
--    anon видит только публичный профиль, услуги, ресурсы (названия), график и фото работ.
--    Записи, занятость, платежи, токены, подписки, outbox — никогда.
-- =====================================================================

alter table public.tenants              enable row level security;
alter table public.tenant_members       enable row level security;
alter table public.resources            enable row level security;
alter table public.services             enable row level security;
alter table public.service_resources    enable row level security;
alter table public.working_hours        enable row level security;
alter table public.schedule_exceptions  enable row level security;
alter table public.works                enable row level security;
alter table public.bookings             enable row level security;
alter table public.resource_occupancies enable row level security;
alter table public.payments             enable row level security;
alter table public.push_subscriptions   enable row level security;
alter table public.notification_jobs    enable row level security;
alter table public.rate_counters        enable row level security;

-- Сначала отзываем всё, что Supabase выдаёт по умолчанию
revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- ---------- публичные данные студии ----------
grant select (id, slug, mode, timezone, profile, updated_at) on public.tenants to anon, authenticated;
grant select on public.services, public.resources, public.service_resources, public.working_hours,
                public.schedule_exceptions, public.works to anon, authenticated;

create policy tenants_public on public.tenants for select using (true);
create policy services_public on public.services for select using (active or public.is_member(tenant_id));
create policy resources_public on public.resources for select using (active or public.is_member(tenant_id));
create policy service_resources_public on public.service_resources for select using (true);
create policy hours_public on public.working_hours for select using (true);
create policy exceptions_public on public.schedule_exceptions for select using (true);
create policy works_public on public.works for select using (true);

-- ---------- владелец: настройки своей студии ----------
grant update (profile) on public.tenants to authenticated;
create policy tenants_owner_update on public.tenants for update to authenticated
  using (public.is_member(id)) with check (public.is_member(id));

grant insert, update, delete on public.services, public.resources, public.service_resources,
                                public.working_hours, public.schedule_exceptions, public.works to authenticated;
create policy services_owner on public.services for all to authenticated using (public.is_member(tenant_id)) with check (public.is_member(tenant_id));
create policy resources_owner on public.resources for all to authenticated using (public.is_member(tenant_id)) with check (public.is_member(tenant_id));
create policy service_resources_owner on public.service_resources for all to authenticated using (public.is_member(tenant_id)) with check (public.is_member(tenant_id));
create policy hours_owner on public.working_hours for all to authenticated using (public.is_member(tenant_id)) with check (public.is_member(tenant_id));
create policy exceptions_owner on public.schedule_exceptions for all to authenticated using (public.is_member(tenant_id)) with check (public.is_member(tenant_id));
create policy works_owner on public.works for all to authenticated using (public.is_member(tenant_id)) with check (public.is_member(tenant_id));

-- ---------- владелец: чтение записей, занятости и платежей своей студии ----------
grant select on public.tenant_members to authenticated;
create policy members_self on public.tenant_members for select to authenticated using (user_id = auth.uid());

grant select (id, tenant_id, service_id, resource_id, status, starts_at, ends_at, buffer_min, service_name, price,
              client_name, client_phone, client_car, source, is_demo, consent_at, cancelled_by, cancelled_at,
              anonymized_at, created_at, updated_at)
  on public.bookings to authenticated; -- без access_token_hash и idempotency_key
create policy bookings_owner_read on public.bookings for select to authenticated using (public.is_member(tenant_id));

grant select on public.resource_occupancies to authenticated;
create policy occupancies_owner_read on public.resource_occupancies for select to authenticated using (public.is_member(tenant_id));

grant select on public.payments to authenticated;
create policy payments_owner_read on public.payments for select to authenticated using (public.is_member(tenant_id));

grant select (id, booking_id, kind, run_at, status, attempts, last_error) on public.notification_jobs to authenticated;
create policy jobs_owner_read on public.notification_jobs for select to authenticated using (public.is_member(tenant_id));

-- push_subscriptions и rate_counters: без политик и без грантов — только service role и функции

-- ---------- функции ----------
grant execute on function public.get_availability(text, uuid, date, integer) to anon, authenticated;
grant execute on function public.create_booking(text, uuid, date, time, text, text, text, uuid, text, boolean, text) to anon, authenticated;
grant execute on function public.get_my_booking(uuid, text) to anon, authenticated;
grant execute on function public.cancel_my_booking(uuid, text) to anon, authenticated;
grant execute on function public.save_push_subscription(uuid, text, text, text, text) to anon, authenticated;

grant execute on function public.is_member(uuid) to anon, authenticated;
grant execute on function public.owner_create_booking(uuid, uuid, date, time, text, text, text, uuid, uuid) to authenticated;
grant execute on function public.owner_move_booking(uuid, date, time, uuid) to authenticated;
grant execute on function public.owner_set_status(uuid, text) to authenticated;
grant execute on function public.owner_add_payment(uuid, text, numeric, text) to authenticated;
grant execute on function public.owner_block_resource(uuid, timestamptz, timestamptz, text) to authenticated;
grant execute on function public.owner_unblock(uuid) to authenticated;
grant execute on function public.owner_stats(uuid, date, date) to authenticated;
grant execute on function public.owner_anonymize_booking(uuid) to authenticated;

-- claim/complete/purge и внутренние функции — только service_role (Edge Function и Cron)
grant execute on function public.claim_notification_jobs(integer, integer) to service_role;
grant execute on function public.complete_notification_job(uuid, text, text) to service_role;
grant execute on function public.purge_expired_personal_data() to service_role;

-- Функции, которые используются внутри политик и выражений, должны быть доступны вызывающей роли
grant execute on function public.norm_phone(text) to anon, authenticated;

-- Realtime для кабинета (уважает RLS)
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.bookings, public.payments, public.resource_occupancies;
  end if;
end $$;

-- Фото: публичное чтение, запись только участником студии в её папку <tenant_id>/owner/...
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('tenant-media', 'tenant-media', true, 8388608, array['image/jpeg', 'image/png', 'image/webp', 'image/svg+xml'])
on conflict (id) do nothing;

create policy media_owner_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'tenant-media' and (storage.foldername(name))[2] = 'owner'
              and public.is_member(((storage.foldername(name))[1])::uuid));
create policy media_owner_delete on storage.objects for delete to authenticated
  using (bucket_id = 'tenant-media' and (storage.foldername(name))[2] = 'owner'
         and public.is_member(((storage.foldername(name))[1])::uuid));


-- ===== 20261009100500_pipeline.sql =====
-- =====================================================================
-- 6. Функции конвейера (только service_role): демо-записи и переход в live.
-- =====================================================================

-- Ближайший рабочий день от смещения, в который время попадает в окно приёма
create or replace function public.admin_open_day(p_tenant uuid, p_offset integer, p_time time) returns date
language plpgsql stable security definer set search_path = public, extensions as $$
declare tz text; d date; i int := 0; w record;
begin
  select timezone into tz from tenants where id = p_tenant;
  d := (now() at time zone tz)::date + p_offset;
  loop
    select * into w from public.day_window(p_tenant, d);
    exit when found and p_time >= w.opens and p_time < w.closes;
    d := d + case when p_offset < 0 then -1 else 1 end; i := i + 1;
    if i > 60 then raise exception 'no_open_day' using errcode = 'P0001'; end if;
  end loop;
  return d;
end $$;

/*
  Демо-запись для preview: помечена is_demo, с занятостью и оплатами.
  Идемпотентна по p_label (повторная публикация не плодит копии).
*/
create or replace function public.admin_insert_demo_booking(
  p_tenant uuid, p_label text, p_service_key text, p_resource_key text, p_day_offset integer, p_time time,
  p_name text, p_phone text, p_car text, p_status text, p_payments jsonb default '[]'
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare t tenants; s services; r uuid; d date; st timestamptz; bid uuid; p jsonb; v_key uuid := md5(p_tenant || ':' || p_label)::uuid;
begin
  select * into t from tenants where id = p_tenant;
  if t.mode <> 'preview' then raise exception 'demo_only_in_preview' using errcode = 'P0001'; end if;
  select id into bid from bookings where tenant_id = t.id and idempotency_key = v_key;
  if found then return bid; end if;
  select * into s from services where tenant_id = t.id and key = p_service_key;
  if not found then raise exception 'service_not_found' using errcode = 'P0001'; end if;
  select id into r from resources where tenant_id = t.id and key = p_resource_key;
  if r is null then select x into r from public.eligible_resources(t.id, s.id) x limit 1; end if;
  d := public.admin_open_day(t.id, p_day_offset, p_time);
  st := (d + p_time) at time zone t.timezone;
  insert into bookings (tenant_id, service_id, resource_id, status, starts_at, ends_at, buffer_min, service_name, price,
                        client_name, client_phone, client_car, access_token_hash, idempotency_key, source, is_demo, consent_at, consent_version)
  values (t.id, s.id, r, p_status, st, st + make_interval(mins => s.duration_min), public.rule_int(t, 'bufferMin', 0), s.name, s.price,
          p_name, public.norm_phone(p_phone), p_car, digest(gen_random_uuid()::text, 'sha256'), v_key, 'client', true, now(), 'demo')
  returning id into bid;
  if p_status <> 'cancelled' then
    begin
      insert into resource_occupancies (tenant_id, resource_id, kind, booking_id, period)
      values (t.id, r, 'booking', bid, tstzrange(st, st + make_interval(mins => s.duration_min + public.rule_int(t, 'bufferMin', 0)), '[)'));
    exception when exclusion_violation then
      delete from bookings where id = bid; -- демо не должно ломать настоящую занятость
      return null;
    end;
  end if;
  for p in select * from jsonb_array_elements(coalesce(p_payments, '[]')) loop
    insert into payments (tenant_id, booking_id, kind, amount, method, paid_at)
    values (t.id, bid, p ->> 'kind', (p ->> 'amount')::numeric, coalesce(p ->> 'method', 'cash'), least(st + interval '1 hour', now()));
  end loop;
  return bid;
end $$;

-- Перевод в live: удаляет демо-данные и включает режим. Записи клиентов не трогает.
create or replace function public.admin_go_live(p_tenant uuid) returns integer
language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  delete from bookings where tenant_id = p_tenant and is_demo;
  get diagnostics n = row_count;
  update tenants set mode = 'live' where id = p_tenant;
  return n;
end $$;

revoke all on function public.admin_open_day(uuid, integer, time) from public, anon, authenticated;
revoke all on function public.admin_insert_demo_booking(uuid, text, text, text, integer, time, text, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.admin_go_live(uuid) from public, anon, authenticated;
grant execute on function public.admin_open_day(uuid, integer, time) to service_role;
grant execute on function public.admin_insert_demo_booking(uuid, text, text, text, integer, time, text, text, text, text, jsonb) to service_role;
grant execute on function public.admin_go_live(uuid) to service_role;


-- ===== 20261009100600_platform.sql =====
-- =====================================================================
-- 7. Платформа: панель продавца (/admin) и самообслуживание владельцев.
--    Продавец (platform_admins) создаёт студии, выдаёт доступ владельцам, приостанавливает студии.
--    Владелец сам настраивает студию и сам запускает приём записей (owner_go_live).
--    Аккаунты (почта/пароль) создаёт Edge Function admin-users с service role.
-- =====================================================================

create table if not exists public.platform_admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.platform_admins enable row level security;
revoke all on public.platform_admins from anon, authenticated;
grant all on public.platform_admins to service_role;

create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select auth.uid() is not null and exists (select 1 from platform_admins where user_id = auth.uid());
$$;

create or replace function public.require_platform_admin() returns void
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if not public.is_platform_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
end $$;

-- Приостановленная студия: сайт открывается, но новые онлайн-записи не принимаются.
alter table public.tenants add column if not exists suspended boolean not null default false;
grant select (suspended) on public.tenants to anon, authenticated;

create or replace function public.bookings_suspended_guard() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.source = 'client' and exists (select 1 from tenants where id = new.tenant_id and suspended) then
    raise exception 'studio_suspended' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists bookings_suspended_guard on public.bookings;
create trigger bookings_suspended_guard before insert on public.bookings
  for each row execute function public.bookings_suspended_guard();

-- ---------------------------------------------------------------------
-- Панель продавца
-- ---------------------------------------------------------------------
create or replace function public.admin_list_studios() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r jsonb;
begin
  perform public.require_platform_admin();
  select coalesce(jsonb_agg(x order by x ->> 'createdAt' desc), '[]'::jsonb) into r from (
    select jsonb_build_object(
      'id', t.id, 'slug', t.slug, 'name', t.profile ->> 'name', 'mode', t.mode, 'suspended', t.suspended,
      'createdAt', t.created_at, 'wentLiveAt', t.went_live_at,
      'owners', coalesce((select jsonb_agg(jsonb_build_object('userId', u.id, 'email', u.email) order by u.email)
                            from tenant_members m join auth.users u on u.id = m.user_id where m.tenant_id = t.id), '[]'::jsonb),
      'bookings30', (select count(*) from bookings b where b.tenant_id = t.id and not b.is_demo and b.created_at > now() - interval '30 days'),
      'lastBookingAt', (select max(b.created_at) from bookings b where b.tenant_id = t.id and not b.is_demo)
    ) x
    from tenants t
  ) s;
  return r;
end $$;

/*
  Новая студия-заготовка: профиль с подсказками, один пост, одна услуга-пример, график пн–сб.
  Всё это владелец меняет сам в кабинете. Студия создаётся в режиме preview.
*/
create or replace function public.admin_create_studio(p_slug text, p_name text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_slug text := lower(btrim(coalesce(p_slug, ''))); v_name text := btrim(coalesce(p_name, '')); v_id uuid; wd int;
begin
  perform public.require_platform_admin();
  if v_slug !~ '^[a-z0-9][a-z0-9-]{0,38}[a-z0-9]$' or v_slug in ('admin', 'api', 'assets', 'owner', 's', 't') then
    raise exception 'bad_slug' using errcode = 'P0001';
  end if;
  if char_length(v_name) not between 1 and 60 then raise exception 'bad_name' using errcode = 'P0001'; end if;
  if exists (select 1 from tenants where slug = v_slug) then raise exception 'slug_taken' using errcode = 'P0001'; end if;

  insert into tenants (slug, mode, timezone, profile) values (v_slug, 'preview', 'Europe/Minsk', jsonb_build_object(
    'name', v_name,
    'shortName', btrim(left(v_name, 12)),
    'kind', 'Автосервис · Беларусь',
    'tagline', 'Онлайн-запись без звонков и ожидания',
    'description', 'Расскажите о студии: опыт, оборудование, гарантия. Этот текст меняется в кабинете → Настройки.',
    'address', 'Укажите адрес в кабинете',
    'phone', '+375 29 000-00-00',
    'accent', '#4690FF',
    'cards', jsonb_build_array(
      jsonb_build_object('title', 'Запись онлайн', 'text', 'Выберите услугу и время — без звонков.'),
      jsonb_build_object('title', 'Точно ко времени', 'text', 'Пост закреплён за вами, очереди нет.'),
      jsonb_build_object('title', 'Оплата на месте', 'text', 'Наличные, карта или ЕРИП.')),
    'booking', jsonb_build_object('bufferMin', 15, 'stepMin', 30, 'leadMin', 60, 'cancelHours', 4, 'horizonDays', 30),
    'media', jsonb_build_object('hero', '/t/_default/media/hero.svg', 'logo', '/t/_default/media/logo.svg')
  )) returning id into v_id;

  insert into resources (tenant_id, key, name, sort) values (v_id, 'post-1', 'Пост 1', 0);
  insert into services (tenant_id, key, name, description, price, duration_min, sort)
  values (v_id, 'example', 'Комплексная мойка (пример)', 'Измените или скройте в кабинете', 30, 60, 0);
  for wd in 1..5 loop insert into working_hours (tenant_id, weekday, opens, closes) values (v_id, wd, '09:00', '19:00'); end loop;
  insert into working_hours (tenant_id, weekday, opens, closes) values (v_id, 6, '10:00', '16:00');
  return v_id;
end $$;

-- Выдать доступ существующему пользователю по почте. 'linked' — готово, 'no_user' — аккаунта ещё нет.
create or replace function public.admin_add_owner(p_tenant uuid, p_email text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_user uuid;
begin
  perform public.require_platform_admin();
  if not exists (select 1 from tenants where id = p_tenant) then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
  select id into v_user from auth.users where lower(email) = lower(btrim(p_email));
  if v_user is null then return 'no_user'; end if;
  insert into tenant_members (tenant_id, user_id) values (p_tenant, v_user) on conflict do nothing;
  return 'linked';
end $$;

create or replace function public.admin_remove_owner(p_tenant uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.require_platform_admin();
  delete from tenant_members where tenant_id = p_tenant and user_id = p_user;
end $$;

create or replace function public.admin_set_suspended(p_tenant uuid, p_suspended boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.require_platform_admin();
  update tenants set suspended = coalesce(p_suspended, false) where id = p_tenant;
  if not found then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
end $$;

-- ---------------------------------------------------------------------
-- Владелец сам запускает приём записей: демо-записи удаляются, уведомления включаются.
-- Нужны данные оператора ПД (проверяет tenants_guard) и настоящий телефон.
-- ---------------------------------------------------------------------
create or replace function public.owner_go_live(p_tenant uuid) returns integer
language plpgsql security definer set search_path = public, extensions as $$
declare t tenants; n int;
begin
  if not (public.is_member(p_tenant) or public.is_platform_admin()) then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into t from tenants where id = p_tenant for update;
  if t.mode = 'live' then return 0; end if;
  if jsonb_typeof(t.profile -> 'legal') is distinct from 'object' then raise exception 'not_ready_legal' using errcode = 'P0001'; end if;
  if (t.profile ->> 'phone') ~ '000-?00-?00' then raise exception 'not_ready_phone' using errcode = 'P0001'; end if;
  delete from bookings where tenant_id = p_tenant and is_demo;
  get diagnostics n = row_count;
  update tenants set mode = 'live' where id = p_tenant;
  return n;
end $$;

revoke all on function public.is_platform_admin() from public, anon, authenticated;
revoke all on function public.require_platform_admin() from public, anon, authenticated;
revoke all on function public.bookings_suspended_guard() from public, anon, authenticated;
revoke all on function public.admin_list_studios() from public, anon, authenticated;
revoke all on function public.admin_create_studio(text, text) from public, anon, authenticated;
revoke all on function public.admin_add_owner(uuid, text) from public, anon, authenticated;
revoke all on function public.admin_remove_owner(uuid, uuid) from public, anon, authenticated;
revoke all on function public.admin_set_suspended(uuid, boolean) from public, anon, authenticated;
revoke all on function public.owner_go_live(uuid) from public, anon, authenticated;

grant execute on function public.is_platform_admin() to authenticated, service_role;
grant execute on function public.admin_list_studios() to authenticated;
grant execute on function public.admin_create_studio(text, text) to authenticated;
grant execute on function public.admin_add_owner(uuid, text) to authenticated;
grant execute on function public.admin_remove_owner(uuid, uuid) to authenticated;
grant execute on function public.admin_set_suspended(uuid, boolean) to authenticated;
grant execute on function public.owner_go_live(uuid) to authenticated;

-- Для Edge Function admin-users (service role): найти пользователя по почте.
create or replace function public.service_user_id_by_email(p_email text) returns uuid
language sql stable security definer set search_path = public, extensions as $$
  select id from auth.users where lower(email) = lower(btrim(p_email)) limit 1;
$$;
revoke all on function public.service_user_id_by_email(text) from public, anon, authenticated;
grant execute on function public.service_user_id_by_email(text) to service_role;


-- ===== 20261009100700_delete_studio.sql =====
-- =====================================================================
-- 8. Удаление студии продавцом. Безвозвратно: записи, оплаты, услуги, график, фото-карточки, доступы.
--    Для защиты от случайного нажатия нужно повторить адрес студии (slug).
-- =====================================================================
create or replace function public.admin_delete_studio(p_tenant uuid, p_confirm_slug text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_slug text;
begin
  perform public.require_platform_admin();
  select slug into v_slug from tenants where id = p_tenant for update;
  if v_slug is null then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
  if v_slug is distinct from lower(btrim(coalesce(p_confirm_slug, ''))) then raise exception 'confirm_mismatch' using errcode = 'P0001'; end if;
  delete from bookings where tenant_id = p_tenant; -- вместе с занятостью, оплатами и заданиями (cascade)
  delete from tenants where id = p_tenant;        -- всё остальное студии (cascade)
end $$;

revoke all on function public.admin_delete_studio(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_delete_studio(uuid, text) to authenticated;


-- ===== 20261009100800_fixes.sql =====
-- =====================================================================
-- 9. Исправления после проверки:
--    - услуга и её посты сохраняются одной транзакцией (нет дублей и «потерянных» постов при сбое сети);
--    - приостановка не мешает демо-записям конвейера (admin_insert_demo_booking, consent_version = 'demo').
-- =====================================================================
create or replace function public.owner_save_service(
  p_tenant uuid, p_id uuid, p_name text, p_description text, p_price numeric, p_duration_min integer,
  p_active boolean, p_sort integer, p_resource_ids uuid[]
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid := p_id;
begin
  perform public.require_member(p_tenant);
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 80 then raise exception 'config_invalid: name' using errcode = '22023'; end if;
  if p_price is null or p_price < 0 or p_price <> round(p_price, 2) then raise exception 'bad_amount' using errcode = '22023'; end if;
  if v_id is null then
    insert into services (tenant_id, key, name, description, price, duration_min, active, sort)
    values (p_tenant, 's' || replace(left(gen_random_uuid()::text, 13), '-', ''), btrim(p_name), btrim(coalesce(p_description, '')), p_price, p_duration_min, coalesce(p_active, true), coalesce(p_sort, 0))
    returning id into v_id;
  else
    update services set name = btrim(p_name), description = btrim(coalesce(p_description, '')), price = p_price,
                        duration_min = p_duration_min, active = coalesce(p_active, true), sort = coalesce(p_sort, sort)
     where id = v_id and tenant_id = p_tenant;
    if not found then raise exception 'service_not_found' using errcode = 'P0001'; end if;
  end if;
  delete from service_resources where tenant_id = p_tenant and service_id = v_id;
  -- составной FK (tenant_id, resource_id) не даст привязать пост другой студии
  insert into service_resources (tenant_id, service_id, resource_id)
  select p_tenant, v_id, r from unnest(coalesce(p_resource_ids, '{}')) r;
  return v_id;
end $$;
revoke all on function public.owner_save_service(uuid, uuid, text, text, numeric, integer, boolean, integer, uuid[]) from public, anon, authenticated;
grant execute on function public.owner_save_service(uuid, uuid, text, text, numeric, integer, boolean, integer, uuid[]) to authenticated;

create or replace function public.bookings_suspended_guard() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.source = 'client' and new.consent_version is distinct from 'demo' and exists (select 1 from tenants where id = new.tenant_id and suspended) then
    raise exception 'studio_suspended' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function public.bookings_suspended_guard() from public, anon, authenticated;


-- ===== 20261009100900_delete_by_function.sql =====
-- =====================================================================
-- 10. Удаление студий и аккаунтов идёт через Edge Function admin-users:
--     продавец подтверждает почтой владельца, владелец — своим паролем (пароль проверяет только Auth).
--     Здесь — служебные функции только для service role.
-- =====================================================================
drop function if exists public.admin_delete_studio(uuid, text);

create or replace function public.service_delete_studio(p_tenant uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform 1 from tenants where id = p_tenant for update;
  if not found then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
  delete from bookings where tenant_id = p_tenant; -- вместе с занятостью, оплатами и заданиями (cascade)
  delete from tenants where id = p_tenant;        -- услуги, посты, график, фото-карточки, доступы (cascade)
end $$;

create or replace function public.service_tenant_owner_emails(p_tenant uuid) returns text[]
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(array_agg(u.email order by u.email), '{}') from tenant_members m join auth.users u on u.id = m.user_id where m.tenant_id = p_tenant;
$$;

revoke all on function public.service_delete_studio(uuid) from public, anon, authenticated;
revoke all on function public.service_tenant_owner_emails(uuid) from public, anon, authenticated;
grant execute on function public.service_delete_studio(uuid) to service_role;
grant execute on function public.service_tenant_owner_emails(uuid) to service_role;


-- ===== 20261009101000_billing_domains.sql =====
-- =====================================================================
-- 11. Панель продавца: учёт оплат покупателей и собственные домены студий.
-- =====================================================================

-- Учёт оплат: видит и меняет только продавец (через функции). Владельцы студий эту таблицу не видят.
create table if not exists public.platform_billing (
  tenant_id     uuid primary key references public.tenants (id) on delete cascade,
  paid_until    date,
  monthly_price numeric(10,2) check (monthly_price is null or monthly_price >= 0),
  note          text not null default '' check (char_length(note) <= 300),
  updated_at    timestamptz not null default now()
);
alter table public.platform_billing enable row level security;
revoke all on public.platform_billing from anon, authenticated;
grant all on public.platform_billing to service_role;

-- Собственный домен студии (например zapis.studio.by): сайт на этом домене открывает именно эту студию.
alter table public.tenants add column if not exists custom_domain text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'tenants_custom_domain_check') then
    alter table public.tenants add constraint tenants_custom_domain_check
      check (custom_domain is null or custom_domain ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$');
  end if;
end $$;
create unique index if not exists tenants_custom_domain_key on public.tenants (custom_domain) where custom_domain is not null;
grant select (custom_domain) on public.tenants to anon, authenticated;

create or replace function public.admin_list_studios() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r jsonb;
begin
  perform public.require_platform_admin();
  select coalesce(jsonb_agg(x order by x ->> 'createdAt' desc), '[]'::jsonb) into r from (
    select jsonb_build_object(
      'id', t.id, 'slug', t.slug, 'name', t.profile ->> 'name', 'mode', t.mode, 'suspended', t.suspended,
      'createdAt', t.created_at, 'wentLiveAt', t.went_live_at, 'customDomain', t.custom_domain,
      'paidUntil', pb.paid_until, 'monthlyPrice', pb.monthly_price, 'billingNote', coalesce(pb.note, ''),
      'owners', coalesce((select jsonb_agg(jsonb_build_object('userId', u.id, 'email', u.email) order by u.email)
                            from tenant_members m join auth.users u on u.id = m.user_id where m.tenant_id = t.id), '[]'::jsonb),
      'bookings30', (select count(*) from bookings b where b.tenant_id = t.id and not b.is_demo and b.created_at > now() - interval '30 days'),
      'lastBookingAt', (select max(b.created_at) from bookings b where b.tenant_id = t.id and not b.is_demo)
    ) x
    from tenants t left join platform_billing pb on pb.tenant_id = t.id
  ) s;
  return r;
end $$;

-- Оплата: дата «оплачено до», цена в месяц, заметка. p_extend_months > 0 — продлить на N месяцев
-- от «оплачено до» (или от сегодня, если срок уже прошёл) и снять приостановку.
create or replace function public.admin_set_billing(
  p_tenant uuid, p_paid_until date, p_monthly_price numeric, p_note text, p_extend_months integer default 0
) returns date
language plpgsql security definer set search_path = public, extensions as $$
declare v_until date; v_today date := (now() at time zone 'Europe/Minsk')::date;
begin
  perform public.require_platform_admin();
  if not exists (select 1 from tenants where id = p_tenant) then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
  if p_monthly_price is not null and (p_monthly_price < 0 or p_monthly_price <> round(p_monthly_price, 2)) then
    raise exception 'bad_amount' using errcode = '22023';
  end if;
  v_until := p_paid_until;
  if coalesce(p_extend_months, 0) > 0 then
    v_until := (greatest(coalesce(p_paid_until, v_today), v_today) + make_interval(months => p_extend_months))::date;
    update tenants set suspended = false where id = p_tenant;
  end if;
  insert into platform_billing (tenant_id, paid_until, monthly_price, note, updated_at)
  values (p_tenant, v_until, p_monthly_price, left(coalesce(p_note, ''), 300), now())
  on conflict (tenant_id) do update set paid_until = excluded.paid_until, monthly_price = excluded.monthly_price,
                                        note = excluded.note, updated_at = now();
  return v_until;
end $$;

create or replace function public.admin_set_domain(p_tenant uuid, p_domain text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v text := nullif(regexp_replace(lower(btrim(coalesce(p_domain, ''))), '^https?://|/.*$', '', 'g'), '');
begin
  perform public.require_platform_admin();
  if v is not null and (v !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' or v like '%pages.dev' or v like '%supabase.co') then
    raise exception 'bad_domain' using errcode = 'P0001';
  end if;
  if v is not null and exists (select 1 from tenants where custom_domain = v and id <> p_tenant) then
    raise exception 'domain_taken' using errcode = 'P0001';
  end if;
  update tenants set custom_domain = v where id = p_tenant;
  if not found then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
  return v;
end $$;

revoke all on function public.admin_list_studios() from public, anon, authenticated;
revoke all on function public.admin_set_billing(uuid, date, numeric, text, integer) from public, anon, authenticated;
revoke all on function public.admin_set_domain(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_list_studios() to authenticated;
grant execute on function public.admin_set_billing(uuid, date, numeric, text, integer) to authenticated;
grant execute on function public.admin_set_domain(uuid, text) to authenticated;


-- ===== 20261009101100_drop_billing.sql =====
-- =====================================================================
-- 12. Учёт оплат покупателей убран из панели продавца (по решению владельца сервиса).
--     Домены студий остаются.
-- =====================================================================
drop function if exists public.admin_set_billing(uuid, date, numeric, text, integer);

create or replace function public.admin_list_studios() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r jsonb;
begin
  perform public.require_platform_admin();
  select coalesce(jsonb_agg(x order by x ->> 'createdAt' desc), '[]'::jsonb) into r from (
    select jsonb_build_object(
      'id', t.id, 'slug', t.slug, 'name', t.profile ->> 'name', 'mode', t.mode, 'suspended', t.suspended,
      'createdAt', t.created_at, 'wentLiveAt', t.went_live_at, 'customDomain', t.custom_domain,
      'owners', coalesce((select jsonb_agg(jsonb_build_object('userId', u.id, 'email', u.email) order by u.email)
                            from tenant_members m join auth.users u on u.id = m.user_id where m.tenant_id = t.id), '[]'::jsonb),
      'bookings30', (select count(*) from bookings b where b.tenant_id = t.id and not b.is_demo and b.created_at > now() - interval '30 days'),
      'lastBookingAt', (select max(b.created_at) from bookings b where b.tenant_id = t.id and not b.is_demo)
    ) x
    from tenants t
  ) s;
  return r;
end $$;

drop table if exists public.platform_billing;

revoke all on function public.admin_list_studios() from public, anon, authenticated;
grant execute on function public.admin_list_studios() to authenticated;


-- ===== 20261009101200_disable_push.sql =====
-- =====================================================================
-- 13. Напоминания через Web Push отключены (по решению владельца сервиса).
--     Клиенту остаётся событие календаря (.ics) с напоминанием за 24 часа.
--     Расписание отправки снимается, ожидающие задания помечаются как пропущенные, подписки удаляются.
--     (Новые задания outbox по-прежнему создаются, но их никто не отправляет — это безопасно.)
--     Ежедневная очистка персональных данных (sgx-purge-personal-data) остаётся.
-- =====================================================================
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'sgx-send-reminders';
  end if;
end $$;

update public.notification_jobs set status = 'skipped', last_error = 'push disabled'
 where status in ('pending', 'processing');

delete from public.push_subscriptions;


-- ===== 20261009101300_drop_domains.sql =====
-- =====================================================================
-- 14. Собственные домены студий убраны (по решению владельца сервиса).
-- =====================================================================
drop function if exists public.admin_set_domain(uuid, text);

create or replace function public.admin_list_studios() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r jsonb;
begin
  perform public.require_platform_admin();
  select coalesce(jsonb_agg(x order by x ->> 'createdAt' desc), '[]'::jsonb) into r from (
    select jsonb_build_object(
      'id', t.id, 'slug', t.slug, 'name', t.profile ->> 'name', 'mode', t.mode, 'suspended', t.suspended,
      'createdAt', t.created_at, 'wentLiveAt', t.went_live_at,
      'owners', coalesce((select jsonb_agg(jsonb_build_object('userId', u.id, 'email', u.email) order by u.email)
                            from tenant_members m join auth.users u on u.id = m.user_id where m.tenant_id = t.id), '[]'::jsonb),
      'bookings30', (select count(*) from bookings b where b.tenant_id = t.id and not b.is_demo and b.created_at > now() - interval '30 days'),
      'lastBookingAt', (select max(b.created_at) from bookings b where b.tenant_id = t.id and not b.is_demo)
    ) x
    from tenants t
  ) s;
  return r;
end $$;

drop index if exists public.tenants_custom_domain_key;
alter table public.tenants drop constraint if exists tenants_custom_domain_check;
alter table public.tenants drop column if exists custom_domain;

revoke all on function public.admin_list_studios() from public, anon, authenticated;
grant execute on function public.admin_list_studios() to authenticated;


-- ===== 20261009101400_revoke_push.sql =====
-- =====================================================================
-- 15. Push отключён: сохранять подписки больше нельзя (иначе копились бы задания, которые никто не отправит).
-- =====================================================================
revoke execute on function public.save_push_subscription(uuid, text, text, text, text) from anon, authenticated;


-- ===== демо-студии (seed без локальных владельцев) =====
-- СГЕНЕРИРОВАНО scripts/build-seed.ts из tenants/*/business.json. Не редактируйте вручную.
-- Только демо-данные: студии в режиме preview, записи помечены is_demo.


-- ===== graphite =====
insert into public.tenants (slug, mode, timezone, profile) values ('graphite', 'preview', 'Europe/Minsk', '{"name":"GRAPHITE Detailing","shortName":"GRAPHITE","kind":"Детейлинг-студия · Минск","tagline":"Полировка, керамика и плёнка. Два поста, тёплый бокс, фотоотчёт","description":"Работаем с кузовом и салоном так, как с собственной машиной: свет для поиска дефектов, замеры толщины ЛКП, фотоотчёт до и после. Свободное время видно сразу.","address":"г. Минск, ул. Тимирязева, 65Б, бокс 12","phone":"+375 29 000-00-00","accent":"#4690FF","cards":[{"title":"Гарантия 2 года","text":"На керамику и плёнку. Фотоотчёт до и после в мессенджер."},{"title":"Один пост — одна машина","text":"Никакой очереди в общем зале: ваш автомобиль на своём посту."},{"title":"Оплата по факту","text":"Наличными, картой или через ЕРИП после приёмки работы."}],"booking":{"bufferMin":15,"stepMin":30,"leadMin":60,"cancelHours":4,"horizonDays":30},"media":{"hero":"/t/graphite/media/hero.svg","logo":"/t/graphite/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'graphite'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'graphite'), 'post-2', 'Пост 2 (плёнка)', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'graphite'), 'wash', 'Детейлинг-мойка', 'Двухфазная мойка, диски, арки, сушка', 45.5, 90, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'graphite'), 'interior', 'Химчистка салона', 'Сиденья, потолок, ковры, пластик', 250, 300, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'graphite'), 'polish', 'Полировка кузова', 'Двухэтапная, убираем голограммы и мелкие царапины', 450, 600, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'graphite'), 'ceramic', 'Керамическое покрытие', 'Подготовка, полировка, 2 слоя керамики. Машина у нас двое суток', 900, 2880, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'graphite'), 'ppf', 'Плёнка на зоны риска', 'Капот, фары, бампер, зеркала. Только пост 2', 1200, 2880, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.service_resources (tenant_id, service_id, resource_id) select t.id, s.id, r.id from public.tenants t join public.services s on s.tenant_id = t.id and s.key = 'ppf' join public.resources r on r.tenant_id = t.id and r.key = 'post-2' where t.slug = 'graphite' on conflict do nothing;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'graphite'), 1, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'graphite'), 2, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'graphite'), 3, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'graphite'), 4, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'graphite'), 5, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'graphite'), 6, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'graphite'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'graphite'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'graphite'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'graphite'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'graphite'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'graphite'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'graphite'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'graphite'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'graphite'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'graphite'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'graphite'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'graphite'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'graphite'), 'w1', '/t/graphite/media/work-1.svg', 'Керамика на чёрном седане', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'graphite'), 'w2', '/t/graphite/media/work-2.svg', 'Полировка капота: до и после', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'graphite'), 'w3', '/t/graphite/media/work-3.svg', 'Химчистка светлого салона', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'graphite'), 'w4', '/t/graphite/media/work-4.svg', 'Плёнка на фары и бампер', 3, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
select public.admin_insert_demo_booking((select id from public.tenants where slug = 'graphite'), 'demo-0', 'wash', 'post-1', 1, '10:00', 'Демо: Андрей', '+375 29 000-00-01', 'Geely Coolray, белый', 'accepted', '[]'::jsonb);
select public.admin_insert_demo_booking((select id from public.tenants where slug = 'graphite'), 'demo-1', 'ceramic', 'post-2', 2, '09:00', 'Демо: Ольга', '+375 33 000-00-02', 'Volkswagen Tiguan', 'new', '[]'::jsonb);
select public.admin_insert_demo_booking((select id from public.tenants where slug = 'graphite'), 'demo-2', 'interior', 'post-1', -1, '11:00', 'Демо: Сергей', '+375 44 000-00-03', 'Toyota Camry', 'done', '[{"kind":"pay","amount":250,"method":"card"}]'::jsonb);

-- ===== protector =====
insert into public.tenants (slug, mode, timezone, profile) values ('protector', 'preview', 'Europe/Minsk', '{"name":"Шинный двор «Протектор»","shortName":"Протектор","kind":"Шиномонтаж · Брест","tagline":"Переобуем за 40 минут. Балансировка, ремонт проколов, хранение","description":"Три подъёмника и запись по минутам: приезжаете к своему времени и не стоите в очереди. Колёса до R22, низкий профиль и Run Flat.","address":"г. Брест, ул. Пример, 7","phone":"+375 33 000-00-00","accent":"#FF8A3D","cards":[{"title":"40 минут","text":"Средняя сезонная замена для легковой машины."},{"title":"До R22","text":"Низкий профиль, Run Flat, внедорожники."},{"title":"Хранение","text":"Сезонное хранение шин и дисков в тёплом складе."}],"booking":{"bufferMin":5,"stepMin":15,"leadMin":30,"cancelHours":1,"horizonDays":14},"media":{"hero":"/t/protector/media/hero.svg","logo":"/t/protector/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'protector'), 'lift-1', 'Подъёмник 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'protector'), 'lift-2', 'Подъёмник 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'protector'), 'lift-3', 'Подъёмник 3 (грузовые)', 2) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'protector'), 'tires-small', 'Сезонная замена R13–R16', 'Снятие, монтаж, балансировка 4 колёс', 35, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.service_resources (tenant_id, service_id, resource_id) select t.id, s.id, r.id from public.tenants t join public.services s on s.tenant_id = t.id and s.key = 'tires-small' join public.resources r on r.tenant_id = t.id and r.key = 'lift-1' where t.slug = 'protector' on conflict do nothing;
insert into public.service_resources (tenant_id, service_id, resource_id) select t.id, s.id, r.id from public.tenants t join public.services s on s.tenant_id = t.id and s.key = 'tires-small' join public.resources r on r.tenant_id = t.id and r.key = 'lift-2' where t.slug = 'protector' on conflict do nothing;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'protector'), 'tires-big', 'Сезонная замена R17–R22', 'Снятие, монтаж, балансировка 4 колёс', 55, 60, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'protector'), 'balance', 'Балансировка 4 колёс', '', 20, 30, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'protector'), 'repair', 'Ремонт прокола', 'Жгут или грибок, одно колесо', 15, 30, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'protector'), 0, '09:00', '15:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'protector'), 1, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'protector'), 2, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'protector'), 3, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'protector'), 4, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'protector'), 5, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'protector'), 6, '09:00', '17:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'protector'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'protector'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'protector'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'protector'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'protector'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'protector'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'protector'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'protector'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'protector'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'protector'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'protector'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'protector'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'protector'), 'w1', '/t/protector/media/work-1.svg', 'Балансировка на стенде', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'protector'), 'w2', '/t/protector/media/work-2.svg', 'Монтаж низкого профиля R20', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'protector'), 'w3', '/t/protector/media/work-3.svg', 'Сезонное хранение', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
select public.admin_insert_demo_booking((select id from public.tenants where slug = 'protector'), 'demo-0', 'tires-small', 'lift-1', 1, '08:00', 'Демо: Виктор', '+375 29 000-00-11', 'Renault Logan', 'new', '[]'::jsonb);
select public.admin_insert_demo_booking((select id from public.tenants where slug = 'protector'), 'demo-1', 'tires-big', 'lift-3', 1, '08:00', 'Демо: Наталья', '+375 25 000-00-12', 'Kia Sportage', 'new', '[]'::jsonb);

