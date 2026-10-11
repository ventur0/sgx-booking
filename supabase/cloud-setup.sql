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


-- ===== 20261011090000_telegram.sql =====
-- =====================================================================
-- 16. Уведомления владельцу в Telegram о новых записях и отменах клиентом.
--
-- Один бот на весь сервис (его создаёт продавец в @BotFather и вводит токен в панели /admin).
-- Владелец в кабинете нажимает «Подключить Telegram» → открывается бот с одноразовым кодом → «Start».
-- Код читает задание pg_cron (tg_tick, раз в 10 секунд) через getUpdates — вебхук и Edge Function не нужны.
-- Сообщения отправляет триггер на bookings через pg_net (асинхронно, после фиксации транзакции).
-- Токен бота хранится в закрытой таблице и в браузер не попадает никогда.
-- =====================================================================

do $$ begin
  create extension if not exists pg_net;
exception when others then raise notice 'pg_net недоступен: уведомления в Telegram отправляться не будут (%)', sqlerrm;
end $$;

-- ---------- настройки бота (одна строка) ----------
create table if not exists public.tg_config (
  id          boolean primary key default true check (id),
  token       text not null check (token ~ '^[0-9]{5,15}:[A-Za-z0-9_-]{30,64}$'),
  bot         text not null check (bot ~ '^[A-Za-z0-9_]{5,32}$'),
  site_url    text not null default 'https://sgx-booking-ten.vercel.app' check (site_url ~ '^https://[^/\s]+$'),
  "offset"    bigint not null default 0,
  pending_req bigint,
  pending_at  timestamptz,
  last_ok_at  timestamptz,
  last_error  text,
  updated_at  timestamptz not null default now()
);

-- ---------- одноразовые коды привязки ----------
create table if not exists public.tg_link_codes (
  code       text primary key check (code ~ '^[a-f0-9]{16}$'),
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  created_by uuid,
  expires_at timestamptz not null default now() + interval '30 minutes',
  used_at    timestamptz
);
create index if not exists tg_link_codes_tenant on public.tg_link_codes (tenant_id);

-- ---------- подключённые чаты ----------
create table if not exists public.tg_chats (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  chat_id    bigint not null,
  title      text not null default '',
  created_at timestamptz not null default now(),
  unique (tenant_id, chat_id)
);

alter table public.tg_config enable row level security;
alter table public.tg_link_codes enable row level security;
alter table public.tg_chats enable row level security;
revoke all on public.tg_config, public.tg_link_codes, public.tg_chats from public, anon, authenticated;
grant all on public.tg_config, public.tg_link_codes, public.tg_chats to service_role;

-- ---------------------------------------------------------------------
-- Отправка сообщения (асинхронно через pg_net). Без pg_net или без бота — тихо ничего не делает.
-- ---------------------------------------------------------------------
create or replace function public.tg_send(p_chat bigint, p_text text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_token text;
begin
  select token into v_token from tg_config where id;
  if v_token is null or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then return; end if;
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
    body := jsonb_build_object('chat_id', p_chat, 'text', left(p_text, 4000), 'disable_web_page_preview', true),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 10000);
exception when others then
  -- уведомление не должно ломать запись клиента
  update tg_config set last_error = 'sendMessage: ' || sqlerrm, updated_at = now() where id;
end $$;

create or replace function public.tg_when(p_at timestamptz, p_tz text) returns text
language sql stable set search_path = public as $$
  select to_char(p_at at time zone p_tz, 'DD.MM') || ' ('
      || (array['пн','вт','ср','чт','пт','сб','вс'])[extract(isodow from p_at at time zone p_tz)::int] || '), '
      || to_char(p_at at time zone p_tz, 'HH24:MI');
$$;

-- ---------------------------------------------------------------------
-- Триггер: новая запись клиента и отмена клиентом → сообщение во все чаты студии
-- ---------------------------------------------------------------------
create or replace function public.tg_booking_notify() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare t record; c record; v_text text; v_site text; v_link text;
begin
  if tg_op = 'INSERT' and new.source <> 'client' then return new; end if;
  if tg_op = 'UPDATE' and not (new.status = 'cancelled' and old.status <> 'cancelled' and new.cancelled_by = 'client') then return new; end if;
  if not exists (select 1 from tg_chats where tenant_id = new.tenant_id) then return new; end if;
  select site_url into v_site from tg_config where id;
  if v_site is null then return new; end if;

  select slug, timezone, profile ->> 'name' as name into t from tenants where id = new.tenant_id;
  v_link := v_site || '/s/' || t.slug || '/owner/?d=' || to_char(new.starts_at at time zone t.timezone, 'YYYY-MM-DD') || '&b=' || new.id;

  if tg_op = 'INSERT' then
    v_text := '🆕 Новая запись — ' || coalesce(t.name, t.slug) || E'\n\n'
      || new.client_name || ', ' || new.client_phone || E'\n'
      || new.service_name || ' · ' || regexp_replace(replace(to_char(new.price, 'FM9999999990.00'), '.', ','), ',00$', '') || ' BYN' || E'\n'
      || public.tg_when(new.starts_at, t.timezone) || E'\n'
      || 'Машина: ' || new.client_car
      || case when new.is_demo then E'\n(демо-запись: студия в режиме образца)' else '' end
      || E'\n\nОткрыть в кабинете: ' || v_link;
  else
    v_text := '❌ Клиент отменил запись — ' || coalesce(t.name, t.slug) || E'\n\n'
      || new.client_name || ', ' || new.client_phone || E'\n'
      || new.service_name || E'\n'
      || public.tg_when(new.starts_at, t.timezone) || E'\n\n'
      || 'Время снова свободно. Кабинет: ' || v_link;
  end if;

  for c in select chat_id from tg_chats where tenant_id = new.tenant_id loop
    perform public.tg_send(c.chat_id, v_text);
  end loop;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists bookings_tg_notify on public.bookings;
create trigger bookings_tg_notify after insert or update of status on public.bookings
  for each row execute function public.tg_booking_notify();

-- ---------------------------------------------------------------------
-- Обработка ответов бота: /start <код> привязывает чат, /stop отвязывает.
-- Вызывается заданием pg_cron. Разбор вынесен отдельно (tg_handle_updates), чтобы его можно было проверить тестами.
-- ---------------------------------------------------------------------
create or replace function public.tg_handle_updates(p_updates jsonb) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare u jsonb; v_max bigint := null; v_chat bigint; v_text text; v_code text; v_title text; v_tenant uuid; v_name text; n int;
begin
  for u in select * from jsonb_array_elements(coalesce(p_updates, '[]'::jsonb)) loop
    v_max := greatest(coalesce(v_max, 0), (u ->> 'update_id')::bigint);
    v_chat := (u #>> '{message,chat,id}')::bigint;
    v_text := btrim(coalesce(u #>> '{message,text}', ''));
    continue when v_chat is null;
    v_title := left(coalesce(nullif(btrim(concat_ws(' ', u #>> '{message,chat,first_name}', u #>> '{message,chat,last_name}')), ''),
                              u #>> '{message,chat,title}', u #>> '{message,chat,username}', ''), 80);

    if v_text ~* '^/start(@\w+)?\s+[a-f0-9]{16}$' then
      v_code := lower(substring(v_text from '([a-fA-F0-9]{16})$'));
      update tg_link_codes set used_at = now()
       where code = v_code and used_at is null and expires_at > now()
       returning tenant_id into v_tenant;
      if v_tenant is null then
        perform public.tg_send(v_chat, 'Ссылка устарела или уже использована. Откройте кабинет и нажмите «Подключить Telegram» ещё раз.');
      else
        insert into tg_chats (tenant_id, chat_id, title) values (v_tenant, v_chat, v_title)
          on conflict (tenant_id, chat_id) do update set title = excluded.title;
        select profile ->> 'name' into v_name from tenants where id = v_tenant;
        perform public.tg_send(v_chat, '✅ Готово! Новые записи и отмены «' || coalesce(v_name, 'студии') || '» будут приходить сюда.' || E'\n\n' || 'Отключить: команда /stop или кнопка в кабинете.');
      end if;
    elsif v_text ~* '^/stop(@\w+)?$' then
      delete from tg_chats where chat_id = v_chat;
      get diagnostics n = row_count;
      perform public.tg_send(v_chat, case when n > 0 then 'Уведомления отключены. Подключить снова можно в кабинете студии.' else 'Этот чат не подключён ни к одной студии.' end);
    elsif v_text ~* '^/start' then
      perform public.tg_send(v_chat, 'Это бот уведомлений о записях. Чтобы подключить студию, откройте кабинет владельца и нажмите «Подключить Telegram».');
    end if;
  end loop;
  return v_max;
end $$;

create or replace function public.tg_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare cfg tg_config; r record; v_max bigint; v_req bigint;
begin
  if not pg_try_advisory_xact_lock(hashtext('sgx-tg-tick')) then return; end if;
  select * into cfg from tg_config where id for update;
  if not found or to_regprocedure('net.http_get(text,jsonb,jsonb,integer)') is null then return; end if;

  -- 1) ответ на прошлый getUpdates
  if cfg.pending_req is not null then
    select status_code, content, timed_out, error_msg into r from net._http_response where id = cfg.pending_req;
    if not found then
      if cfg.pending_at > now() - interval '60 seconds' then return; end if;  -- ещё в пути
      update tg_config set pending_req = null, last_error = 'getUpdates: нет ответа', updated_at = now() where id;
    elsif r.status_code = 200 then
      begin
        v_max := public.tg_handle_updates(r.content::jsonb -> 'result');
        update tg_config set "offset" = greatest("offset", coalesce(v_max + 1, "offset")), pending_req = null,
               last_ok_at = now(), last_error = null, updated_at = now() where id;
      exception when others then
        -- битое сообщение не должно зациклить опрос: пропускаем пачку целиком
        update tg_config set pending_req = null, updated_at = now(), last_error = 'обработка: ' || left(sqlerrm, 200),
               "offset" = greatest("offset", coalesce((select max((x ->> 'update_id')::bigint) + 1
                                                        from jsonb_array_elements(r.content::jsonb -> 'result') x), "offset"))
         where id;
      end;
    else
      update tg_config set pending_req = null, updated_at = now(),
             last_error = 'getUpdates: ' || coalesce(r.status_code::text, '') || ' ' || left(coalesce(r.content, r.error_msg, ''), 300) where id;
    end if;
    select * into cfg from tg_config where id;
  end if;

  -- 2) новый запрос
  v_req := net.http_get(
    url := 'https://api.telegram.org/bot' || cfg.token || '/getUpdates',
    params := jsonb_build_object('offset', cfg."offset"::text, 'timeout', '0', 'allowed_updates', '["message"]'),
    timeout_milliseconds := 10000);
  update tg_config set pending_req = v_req, pending_at = now() where id;
end $$;

-- ---------------------------------------------------------------------
-- Продавец: настройка бота
-- ---------------------------------------------------------------------
create or replace function public.admin_tg_get() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare cfg tg_config;
begin
  if not public.is_platform_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into cfg from tg_config where id;
  return jsonb_build_object(
    'configured', found, 'bot', cfg.bot, 'siteUrl', coalesce(cfg.site_url, 'https://sgx-booking-ten.vercel.app'),
    'lastOkAt', cfg.last_ok_at, 'lastError', cfg.last_error,
    'chats', (select count(*) from tg_chats), 'studios', (select count(distinct tenant_id) from tg_chats),
    'netReady', to_regprocedure('net.http_get(text,jsonb,jsonb,integer)') is not null);
end $$;

create or replace function public.admin_tg_set(p_token text, p_bot text, p_site text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_bot text := regexp_replace(btrim(coalesce(p_bot, '')), '^(https?://)?(t\.me/)?@?', '');
        v_site text := rtrim(btrim(coalesce(nullif(p_site, ''), 'https://sgx-booking-ten.vercel.app')), '/');
        v_token text := nullif(btrim(coalesce(p_token, '')), '');
begin
  if not public.is_platform_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if v_bot !~ '^[A-Za-z0-9_]{5,32}$' then raise exception 'bad_bot' using errcode = '22023'; end if;
  if v_site !~ '^https://[^/\s]+$' then raise exception 'bad_site' using errcode = '22023'; end if;
  if v_token is null then
    -- без нового токена меняем только имя бота и адрес сайта
    update tg_config set bot = v_bot, site_url = v_site, updated_at = now() where id;
    if not found then raise exception 'bad_bot_token' using errcode = '22023'; end if;
    return;
  end if;
  if v_token !~ '^[0-9]{5,15}:[A-Za-z0-9_-]{30,64}$' then raise exception 'bad_bot_token' using errcode = '22023'; end if;
  insert into tg_config (id, token, bot, site_url) values (true, v_token, v_bot, v_site)
    on conflict (id) do update set token = excluded.token, bot = excluded.bot, site_url = excluded.site_url,
      "offset" = case when tg_config.token = excluded.token then tg_config."offset" else 0 end,
      pending_req = null, last_error = null, updated_at = now();
  -- если у бота был вебхук, getUpdates не работает — снимаем его
  if to_regprocedure('net.http_get(text,jsonb,jsonb,integer)') is not null then
    perform net.http_get(url := 'https://api.telegram.org/bot' || v_token || '/deleteWebhook');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Владелец: подключение и отключение чатов своей студии
-- ---------------------------------------------------------------------
create or replace function public.owner_tg_link(p_tenant uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_bot text; v_code text;
begin
  if not public.is_member(p_tenant) then raise exception 'forbidden' using errcode = '42501'; end if;
  select bot into v_bot from tg_config where id;
  if v_bot is null then raise exception 'telegram_not_configured' using errcode = 'P0001'; end if;
  delete from tg_link_codes where expires_at < now() - interval '1 day';
  if (select count(*) from tg_link_codes where tenant_id = p_tenant and used_at is null and expires_at > now()) >= 10 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  v_code := encode(gen_random_bytes(8), 'hex');
  insert into tg_link_codes (code, tenant_id, created_by) values (v_code, p_tenant, auth.uid());
  return jsonb_build_object('bot', v_bot, 'url', 'https://t.me/' || v_bot || '?start=' || v_code);
end $$;

create or replace function public.owner_tg_list(p_tenant uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if not public.is_member(p_tenant) then raise exception 'forbidden' using errcode = '42501'; end if;
  return jsonb_build_object(
    'configured', exists (select 1 from tg_config where id),
    'chats', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'title', title, 'createdAt', created_at) order by created_at)
                         from tg_chats where tenant_id = p_tenant), '[]'::jsonb));
end $$;

create or replace function public.owner_tg_remove(p_tenant uuid, p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_chat bigint; v_name text;
begin
  if not public.is_member(p_tenant) then raise exception 'forbidden' using errcode = '42501'; end if;
  delete from tg_chats where id = p_id and tenant_id = p_tenant returning chat_id into v_chat;
  if v_chat is not null then
    select profile ->> 'name' into v_name from tenants where id = p_tenant;
    perform public.tg_send(v_chat, 'Уведомления «' || coalesce(v_name, 'студии') || '» отключены в кабинете.');
  end if;
end $$;

-- ---------- права ----------
revoke all on function public.tg_send(bigint, text) from public, anon, authenticated;
revoke all on function public.tg_when(timestamptz, text) from public, anon, authenticated;
revoke all on function public.tg_booking_notify() from public, anon, authenticated;
revoke all on function public.tg_handle_updates(jsonb) from public, anon, authenticated;
revoke all on function public.tg_tick() from public, anon, authenticated;
revoke all on function public.admin_tg_get() from public, anon, authenticated;
revoke all on function public.admin_tg_set(text, text, text) from public, anon, authenticated;
revoke all on function public.owner_tg_link(uuid) from public, anon, authenticated;
revoke all on function public.owner_tg_list(uuid) from public, anon, authenticated;
revoke all on function public.owner_tg_remove(uuid, uuid) from public, anon, authenticated;
grant execute on function public.admin_tg_get(), public.admin_tg_set(text, text, text),
  public.owner_tg_link(uuid), public.owner_tg_list(uuid), public.owner_tg_remove(uuid, uuid) to authenticated;
grant execute on function public.tg_send(bigint, text), public.tg_handle_updates(jsonb), public.tg_tick() to service_role;

-- ---------- задание: опрос бота раз в 10 секунд (или раз в минуту, если секунды не поддерживаются) ----------
do $$ begin
  begin
    create extension if not exists pg_cron;
  exception when others then raise notice 'pg_cron недоступен: подключение чатов работать не будет (%)', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule('sgx-telegram');
    exception when others then null;
    end;
    begin
      perform cron.schedule('sgx-telegram', '10 seconds', 'select public.tg_tick()');
    exception when others then
      perform cron.schedule('sgx-telegram', '* * * * *', 'select public.tg_tick()');
    end;
  end if;
end $$;


-- ===== демо-студии (seed без локальных владельцев) =====
-- СГЕНЕРИРОВАНО scripts/build-seed.ts из tenants/*/business.json. Не редактируйте вручную.
-- Только демо-данные: студии в режиме preview, записи помечены is_demo.


-- ===== agat-vitebsk =====
insert into public.tenants (slug, mode, timezone, profile) values ('agat-vitebsk', 'preview', 'Europe/Minsk', '{"name":"Агат","shortName":"Агат","kind":"Автомойка и химчистка · Витебск","tagline":"Ручная мойка и комплекс «3 в 1» на Генерала Ивановского","description":"Ручная мойка и автохимчистка. Комплексы для легковых, кроссоверов и минивэнов. Демо-версия сайта для студии: цены взяты из карточки на картах и могли измениться, их владелец меняет в кабинете.","address":"г. Витебск, ул. Генерала Ивановского, 5","phone":"+375 29 164-60-43","accent":"#9B6BFF","cards":[{"title":"Ручная мойка","text":"Бережно для кузова."},{"title":"Комплекс 3 в 1","text":"Кузов, салон, коврики."},{"title":"Картой или наличными","text":"Как удобно."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/agat-vitebsk/media/hero.svg","logo":"/t/agat-vitebsk/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'agat-vitebsk'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'agat-vitebsk'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'agat-vitebsk'), 'complex', 'Комплекс 3 в 1', 'Легковые', 33, 60, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'agat-vitebsk'), 'classy', 'Комплекс «Классный»', 'Легковые; кроссовер/минивэн — 60', 55, 90, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'agat-vitebsk'), 'body', 'Мойка кузова', 'От 6 до 45 BYN', 6, 20, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'agat-vitebsk'), 'interior', 'Химчистка салона', '', 280, 300, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'agat-vitebsk'), 0, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'agat-vitebsk'), 1, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'agat-vitebsk'), 2, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'agat-vitebsk'), 3, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'agat-vitebsk'), 4, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'agat-vitebsk'), 5, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'agat-vitebsk'), 6, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), 'w1', '/t/agat-vitebsk/media/work-1.svg', 'Мойка', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), 'w2', '/t/agat-vitebsk/media/work-2.svg', 'Салон после химчистки', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'agat-vitebsk'), 'w3', '/t/agat-vitebsk/media/work-3.svg', 'Колёса и диски', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== artline-motors =====
insert into public.tenants (slug, mode, timezone, profile) values ('artline-motors', 'preview', 'Europe/Minsk', '{"name":"АртЛайнМоторс","shortName":"АртЛайн","kind":"Автосервис · Минск","tagline":"Автосервис на Долгобродской, 22","description":"Легковой автосервис: диагностика, ТО, ремонт ходовой и тормозов. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Долгобродская, 22","phone":"+375 29 103-05-09","accent":"#7B8CFF","cards":[{"title":"Диагностика","text":"Сканер и осмотр на подъёмнике."},{"title":"Смета до ремонта","text":"Согласуем работы и цену заранее."},{"title":"Запись на время","text":"Без ожидания в очереди."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/artline-motors/media/hero.svg","logo":"/t/artline-motors/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'artline-motors'), 'post-1', 'Подъёмник 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'artline-motors'), 'post-2', 'Подъёмник 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'artline-motors'), 'diag', 'Компьютерная диагностика', 'Сканер и чтение ошибок', 40, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'artline-motors'), 'oil', 'Замена масла и фильтра', '', 30, 40, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'artline-motors'), 'brakes', 'Замена тормозных колодок', 'Одна ось', 40, 60, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'artline-motors'), 'chassis', 'Осмотр ходовой', 'На подъёмнике, с отчётом', 25, 60, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'artline-motors'), 'alignment', 'Развал-схождение', '', 45, 60, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'artline-motors'), 1, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'artline-motors'), 2, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'artline-motors'), 3, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'artline-motors'), 4, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'artline-motors'), 5, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'artline-motors'), 6, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'artline-motors'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'artline-motors'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'artline-motors'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'artline-motors'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'artline-motors'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'artline-motors'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'artline-motors'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'artline-motors'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'artline-motors'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'artline-motors'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'artline-motors'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'artline-motors'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'artline-motors'), 'w1', '/t/artline-motors/media/work-1.svg', 'Колёса и диски', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'artline-motors'), 'w2', '/t/artline-motors/media/work-2.svg', 'Блеск кузова', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'artline-motors'), 'w3', '/t/artline-motors/media/work-3.svg', 'Плёнка и оптика', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== avtomoyka-88 =====
insert into public.tenants (slug, mode, timezone, profile) values ('avtomoyka-88', 'preview', 'Europe/Minsk', '{"name":"Автомойка 88","shortName":"Мойка 88","kind":"Автомойка · Витебск, круглосуточно","tagline":"Круглосуточная мойка на Ленинградской, 88","description":"Мойка легковых, микроавтобусов и грузовых, мойка двигателя, химчистка салона, антидождь и горячий воск. Работаем круглосуточно. Демо-версия сайта для студии: цены взяты из карточки на картах и могли измениться, их владелец меняет в кабинете.","address":"г. Витебск, Ленинградская ул., 88","phone":"+375 29 515-15-33","accent":"#0EA5E9","cards":[{"title":"24/7","text":"Работаем круглосуточно."},{"title":"Любой транспорт","text":"Легковые, микроавтобусы, грузовые."},{"title":"Химчистка","text":"Салон, двери, потолок, багажник."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/avtomoyka-88/media/hero.svg","logo":"/t/avtomoyka-88/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'avtomoyka-88'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'avtomoyka-88'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'avtomoyka-88'), 'post-3', 'Пост 3', 2) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'avtomoyka-88'), 'post-4', 'Пост 4', 3) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'avtomoyka-88'), 'car', 'Мойка автомобиля', 'Легковой', 20, 40, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'avtomoyka-88'), 'van', 'Мойка микроавтобуса', '', 30, 60, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'avtomoyka-88'), 'engine', 'Мойка двигателя', '', 35, 40, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'avtomoyka-88'), 'interior', 'Химчистка салона', 'Полная', 350, 300, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'avtomoyka-88'), 'rain', 'Антидождь', 'Стёкла', 15, 15, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'avtomoyka-88'), 'wax', 'Горячий воск', '', 5, 15, true, 5)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'avtomoyka-88'), 0, '00:00', '23:59') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'avtomoyka-88'), 1, '00:00', '23:59') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'avtomoyka-88'), 2, '00:00', '23:59') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'avtomoyka-88'), 3, '00:00', '23:59') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'avtomoyka-88'), 4, '00:00', '23:59') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'avtomoyka-88'), 5, '00:00', '23:59') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'avtomoyka-88'), 6, '00:00', '23:59') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), 'w1', '/t/avtomoyka-88/media/work-1.svg', 'Мойка', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), 'w2', '/t/avtomoyka-88/media/work-2.svg', 'Химчистка', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'avtomoyka-88'), 'w3', '/t/avtomoyka-88/media/work-3.svg', 'Колёса', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== bip-service =====
insert into public.tenants (slug, mode, timezone, profile) values ('bip-service', 'preview', 'Europe/Minsk', '{"name":"Bip service","shortName":"Bip service","kind":"СТО и шиномонтаж · Минск","tagline":"Автосервис и шиномонтаж на Автомобилистов, 2","description":"Автосервис и шиномонтаж: диагностика, ТО, тормоза, ходовая, сезонная замена колёс. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Автомобилистов, 2","phone":"+375 29 739-66-52","accent":"#4F8CFF","cards":[{"title":"Диагностика","text":"Сканер и осмотр на подъёмнике."},{"title":"Смета до ремонта","text":"Согласуем работы и цену заранее."},{"title":"Запись на время","text":"Без ожидания в очереди."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/bip-service/media/hero.svg","logo":"/t/bip-service/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'bip-service'), 'post-1', 'Подъёмник 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'bip-service'), 'post-2', 'Подъёмник 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'bip-service'), 'diag', 'Компьютерная диагностика', 'Сканер и чтение ошибок', 40, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'bip-service'), 'oil', 'Замена масла и фильтра', '', 30, 40, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'bip-service'), 'brakes', 'Замена тормозных колодок', 'Одна ось', 40, 60, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'bip-service'), 'chassis', 'Осмотр ходовой', 'На подъёмнике, с отчётом', 25, 60, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'bip-service'), 'tires', 'Сезонная замена колёс', 'R13–R18, с балансировкой', 40, 45, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bip-service'), 0, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bip-service'), 1, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bip-service'), 2, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bip-service'), 3, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bip-service'), 4, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bip-service'), 5, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bip-service'), 6, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bip-service'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bip-service'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bip-service'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bip-service'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bip-service'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bip-service'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bip-service'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bip-service'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bip-service'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bip-service'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bip-service'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bip-service'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'bip-service'), 'w1', '/t/bip-service/media/work-1.svg', 'Колёса и диски', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'bip-service'), 'w2', '/t/bip-service/media/work-2.svg', 'Блеск кузова', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'bip-service'), 'w3', '/t/bip-service/media/work-3.svg', 'Плёнка и оптика', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== bleskcar =====
insert into public.tenants (slug, mode, timezone, profile) values ('bleskcar', 'preview', 'Europe/Minsk', '{"name":"БлескCar","shortName":"БлескCar","kind":"Автомойка · д. Боровая","tagline":"Тёплая мойка, химчистка и полировка в Боровой","description":"Комплексная мойка, мойка самообслуживания и автомат, химчистка, полировка. Демо-версия сайта для студии: цены взяты из карточки на картах и могли измениться, их владелец меняет в кабинете.","address":"Минский р-н, д. Боровая, Боровлянский с/с, 52","phone":"+375 29 538-90-40","accent":"#38BDF8","cards":[{"title":"Тёплый бокс","text":"Мойка в любую погоду."},{"title":"Запись на время","text":"Бокс ваш, без очереди."},{"title":"От 35 BYN","text":"Комплексная мойка."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/bleskcar/media/hero.svg","logo":"/t/bleskcar/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'bleskcar'), 'post-1', 'Бокс', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'bleskcar'), 'complex', 'Комплексная мойка', 'Кузов, салон, коврики', 35, 60, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'bleskcar'), 'interior', 'Химчистка салона', '', 250, 300, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'bleskcar'), 'polish', 'Полировка кузова', '', 400, 480, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bleskcar'), 0, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bleskcar'), 1, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bleskcar'), 2, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bleskcar'), 3, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bleskcar'), 4, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bleskcar'), 5, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'bleskcar'), 6, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bleskcar'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bleskcar'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bleskcar'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bleskcar'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bleskcar'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bleskcar'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bleskcar'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bleskcar'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bleskcar'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bleskcar'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bleskcar'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'bleskcar'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'bleskcar'), 'w1', '/t/bleskcar/media/work-1.svg', 'Мойка', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'bleskcar'), 'w2', '/t/bleskcar/media/work-2.svg', 'Салон после химчистки', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'bleskcar'), 'w3', '/t/bleskcar/media/work-3.svg', 'Блеск кузова', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== centralnaya-brest =====
insert into public.tenants (slug, mode, timezone, profile) values ('centralnaya-brest', 'preview', 'Europe/Minsk', '{"name":"Центральная","shortName":"Центральная","kind":"Автомойка · Брест","tagline":"Мойка и химчистка на Менжинского, 4А","description":"Ручная мойка, мойка двигателя и колёс, химчистка салона и ковров, предпродажная подготовка, воск. Демо-версия сайта для студии: цены взяты из карточки на картах и могли измениться, их владелец меняет в кабинете.","address":"г. Брест, ул. Менжинского, 4А","phone":"+375 29 555-45-45","accent":"#F05454","cards":[{"title":"Ручная мойка","text":"Двигатель, колёса, кузов."},{"title":"Предпродажная","text":"Подготовка машины к продаже."},{"title":"Сертификаты","text":"Подарочные на любую услугу."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/centralnaya-brest/media/hero.svg","logo":"/t/centralnaya-brest/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'centralnaya-brest'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'centralnaya-brest'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'centralnaya-brest'), 'complex', 'Комплексная мойка', 'Легковой; минивэн 55, грузопассажирский 60', 50, 60, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'centralnaya-brest'), 'body', 'Мойка кузова', 'От 6 до 23 BYN', 6, 20, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'centralnaya-brest'), 'engine', 'Мойка двигателя', '', 30, 40, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'centralnaya-brest'), 'interior', 'Химчистка салона', '', 280, 300, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'centralnaya-brest'), 0, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'centralnaya-brest'), 1, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'centralnaya-brest'), 2, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'centralnaya-brest'), 3, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'centralnaya-brest'), 4, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'centralnaya-brest'), 5, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'centralnaya-brest'), 6, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), 'w1', '/t/centralnaya-brest/media/work-1.svg', 'Мойка', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), 'w2', '/t/centralnaya-brest/media/work-2.svg', 'Салон после химчистки', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'centralnaya-brest'), 'w3', '/t/centralnaya-brest/media/work-3.svg', 'Колёса и диски', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== chameleon =====
insert into public.tenants (slug, mode, timezone, profile) values ('chameleon', 'preview', 'Europe/Minsk', '{"name":"Хамелеон","shortName":"Хамелеон","kind":"Детейлинг и автоателье · Минск","tagline":"Детейлинг у Дворца Республики: фары, хром, шторы, химчистка","description":"Детейлинг, студия тюнинга и автоателье: полировка хрома и стекла, фары, шторки, химчистка, ремонт кожи. Демо-версия сайта для студии: цены взяты из карточки на картах и могли измениться, их владелец меняет в кабинете.","address":"г. Минск, Октябрьская пл., 1 (въезд с ул. Интернациональной)","phone":"+375 29 321-08-08","accent":"#7ED957","cards":[{"title":"Фары как новые","text":"Восстановление и защита плёнкой."},{"title":"Автоателье","text":"Шторы, ремонт кожи, детали."},{"title":"Центр города","text":"Въезд с Интернациональной."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/chameleon/media/hero.svg","logo":"/t/chameleon/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'chameleon'), 'post-1', 'Пост', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'chameleon'), 'chrome', 'Полировка хромированных деталей', '', 200, 240, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'chameleon'), 'curtains', 'Шторы на заднюю полусферу', 'Комплект, седан/хэтч от 120', 180, 120, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'chameleon'), 'headlights', 'Восстановление и защита фар', '', 200, 180, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'chameleon'), 'interior', 'Химчистка салона', '', 280, 300, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'chameleon'), 1, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'chameleon'), 2, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'chameleon'), 3, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'chameleon'), 4, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'chameleon'), 5, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'chameleon'), 6, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chameleon'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chameleon'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chameleon'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chameleon'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chameleon'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chameleon'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chameleon'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chameleon'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chameleon'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chameleon'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chameleon'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chameleon'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'chameleon'), 'w1', '/t/chameleon/media/work-1.svg', 'Плёнка и оптика', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'chameleon'), 'w2', '/t/chameleon/media/work-2.svg', 'Блеск кузова', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'chameleon'), 'w3', '/t/chameleon/media/work-3.svg', 'Салон после химчистки', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== chistaya-sovest =====
insert into public.tenants (slug, mode, timezone, profile) values ('chistaya-sovest', 'preview', 'Europe/Minsk', '{"name":"Чистая совесть","shortName":"Совесть","kind":"Автосервис и шиномонтаж · Минск","tagline":"Автосервис и шиномонтаж на Петруся Бровки, 8Б","description":"Автосервис и шиномонтаж, замена колодок. Каждый день с 9 до 20. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Петруся Бровки, 8Б","phone":"+375 44 744-34-94","accent":"#3FB37F","cards":[{"title":"Диагностика","text":"Сканер и осмотр на подъёмнике."},{"title":"Смета до ремонта","text":"Согласуем работы и цену заранее."},{"title":"Запись на время","text":"Без ожидания в очереди."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/chistaya-sovest/media/hero.svg","logo":"/t/chistaya-sovest/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'chistaya-sovest'), 'post-1', 'Подъёмник 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'chistaya-sovest'), 'post-2', 'Подъёмник 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'chistaya-sovest'), 'diag', 'Компьютерная диагностика', 'Сканер и чтение ошибок', 40, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'chistaya-sovest'), 'oil', 'Замена масла и фильтра', '', 30, 40, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'chistaya-sovest'), 'brakes', 'Замена тормозных колодок', 'Одна ось', 40, 60, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'chistaya-sovest'), 'chassis', 'Осмотр ходовой', 'На подъёмнике, с отчётом', 25, 60, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'chistaya-sovest'), 'tires', 'Сезонная замена колёс', 'R13–R18, с балансировкой', 40, 45, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'chistaya-sovest'), 0, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'chistaya-sovest'), 1, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'chistaya-sovest'), 2, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'chistaya-sovest'), 3, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'chistaya-sovest'), 4, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'chistaya-sovest'), 5, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'chistaya-sovest'), 6, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), 'w1', '/t/chistaya-sovest/media/work-1.svg', 'Колёса и диски', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), 'w2', '/t/chistaya-sovest/media/work-2.svg', 'Блеск кузова', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'chistaya-sovest'), 'w3', '/t/chistaya-sovest/media/work-3.svg', 'Мойка', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== cleanart =====
insert into public.tenants (slug, mode, timezone, profile) values ('cleanart', 'preview', 'Europe/Minsk', '{"name":"КлинАрт","shortName":"КлинАрт","kind":"Автомойка · центр Минска","tagline":"Автомойка в центре, на Ленина, 27. Каждый день с 9 до 22","description":"Бесконтактная и комплексная мойка, химчистка салона, полировка. До шести машин одновременно и зал ожидания с Wi-Fi. Демо-версия сайта для студии: цены и длительность примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Ленина, 27","phone":"+375 44 788-55-00","accent":"#FF5C8A","cards":[{"title":"В центре","text":"Ленина, 27 — рядом с работой и делами."},{"title":"До 6 машин","text":"Принимаем одновременно, без долгого ожидания."},{"title":"Wi-Fi","text":"Зал ожидания, пока моем машину."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/cleanart/media/hero.svg","logo":"/t/cleanart/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'cleanart'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'cleanart'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'cleanart'), 'post-3', 'Пост 3', 2) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'cleanart'), 'complex', 'Комплексная мойка', 'Кузов, салон, коврики, стёкла', 45, 60, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'cleanart'), 'touchless', 'Бесконтактная мойка', 'Кузов и диски', 25, 30, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'cleanart'), 'interior', 'Химчистка салона', 'Сиденья, ковры, пластик', 230, 300, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'cleanart'), 'polish', 'Полировка кузова', 'Восстановительная', 400, 480, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'cleanart'), 'engine', 'Мойка двигателя', 'С консервацией', 35, 40, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'cleanart'), 0, '09:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'cleanart'), 1, '09:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'cleanart'), 2, '09:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'cleanart'), 3, '09:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'cleanart'), 4, '09:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'cleanart'), 5, '09:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'cleanart'), 6, '09:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'cleanart'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'cleanart'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'cleanart'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'cleanart'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'cleanart'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'cleanart'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'cleanart'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'cleanart'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'cleanart'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'cleanart'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'cleanart'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'cleanart'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'cleanart'), 'w1', '/t/cleanart/media/work-1.svg', 'Пена на кузове', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'cleanart'), 'w2', '/t/cleanart/media/work-2.svg', 'Диски', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'cleanart'), 'w3', '/t/cleanart/media/work-3.svg', 'Блеск после полировки', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== detailing-mogilev =====
insert into public.tenants (slug, mode, timezone, profile) values ('detailing-mogilev', 'preview', 'Europe/Minsk', '{"name":"Детейлинг студия на Космонавтов","shortName":"Детейлинг","kind":"Детейлинг · Могилёв","tagline":"Тонировка, химчистка и детейлинг на Космонавтов, 57А","description":"Тонирование стёкол, химчистка салона и детейлинг. Подарочные сертификаты и рассрочка. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Могилёв, ул. Космонавтов, 57А","phone":"+375 44 573-56-94","accent":"#A78BFA","cards":[{"title":"Тонировка","text":"Плёнки разной светопропускаемости."},{"title":"Рассрочка","text":"Дорогие работы — частями."},{"title":"Сертификаты","text":"Подарок для автолюбителя."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/detailing-mogilev/media/hero.svg","logo":"/t/detailing-mogilev/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'detailing-mogilev'), 'post-1', 'Пост', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'detailing-mogilev'), 'tint', 'Тонировка задней полусферы', '', 180, 180, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'detailing-mogilev'), 'interior', 'Химчистка салона', 'Полная', 280, 300, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'detailing-mogilev'), 'polish', 'Полировка кузова', 'Двухэтапная', 400, 480, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'detailing-mogilev'), 'ceramic', 'Керамическое покрытие', 'Подготовка и нанесение', 750, 1440, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'detailing-mogilev'), 1, '10:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'detailing-mogilev'), 2, '10:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'detailing-mogilev'), 3, '10:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'detailing-mogilev'), 4, '10:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'detailing-mogilev'), 5, '10:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'detailing-mogilev'), 6, '10:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), 'w1', '/t/detailing-mogilev/media/work-1.svg', 'Тонировка', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), 'w2', '/t/detailing-mogilev/media/work-2.svg', 'Химчистка', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'detailing-mogilev'), 'w3', '/t/detailing-mogilev/media/work-3.svg', 'Полировка', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== detailing-room =====
insert into public.tenants (slug, mode, timezone, profile) values ('detailing-room', 'preview', 'Europe/Minsk', '{"name":"Detailing room","shortName":"Det. room","kind":"Автомойка · ЖК «Вершина», Минск","tagline":"Автомойка у дома на паркинге ЖК «Вершина»","description":"Мойка прямо на паркинге жилого комплекса: оставили машину — забрали чистой. Воскресенье — только по предварительной записи. Демо-версия сайта для студии: цены и длительность примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Маршала Лосика, 59, паркинг ЖК «Вершина»","phone":"+375 44 589-05-50","accent":"#3CC98A","cards":[{"title":"Рядом с домом","text":"Паркинг ЖК «Вершина», не нужно ехать через город."},{"title":"Один пост","text":"Ваша машина в работе одна, без очереди."},{"title":"Воскресенье","text":"Принимаем по записи."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/detailing-room/media/hero.svg","logo":"/t/detailing-room/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'detailing-room'), 'post-1', 'Пост', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'detailing-room'), 'complex', 'Комплексная мойка', 'Кузов, салон, коврики', 50, 60, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'detailing-room'), 'express', 'Экспресс-мойка кузова', 'Бесконтактная, сушка', 30, 30, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'detailing-room'), 'interior', 'Химчистка салона', 'Сиденья, ковры, пластик', 220, 300, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'detailing-room'), 'engine', 'Мойка двигателя', 'С консервацией', 35, 40, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'detailing-room'), 0, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'detailing-room'), 1, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'detailing-room'), 2, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'detailing-room'), 3, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'detailing-room'), 4, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'detailing-room'), 5, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'detailing-room'), 6, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-room'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-room'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-room'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-room'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-room'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-room'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-room'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-room'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-room'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-room'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-room'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'detailing-room'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'detailing-room'), 'w1', '/t/detailing-room/media/work-1.svg', 'Пена на кузове', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'detailing-room'), 'w2', '/t/detailing-room/media/work-2.svg', 'Чистый салон', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'detailing-room'), 'w3', '/t/detailing-room/media/work-3.svg', 'Диски после мойки', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== dsm-garage =====
insert into public.tenants (slug, mode, timezone, profile) values ('dsm-garage', 'preview', 'Europe/Minsk', '{"name":"DSM garage","shortName":"DSM garage","kind":"СТО · Минск, Советский район","tagline":"Автосервис на Веры Хоружей: диагностика, ходовая, ТО","description":"Диагностика, техническое обслуживание и ремонт ходовой. Wi-Fi и кафе рядом, пока машина в работе. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Веры Хоружей, 32Б","phone":"+375 29 378-16-57","accent":"#C084FC","cards":[{"title":"Диагностика","text":"Сканер и осмотр на подъёмнике."},{"title":"Понятная смета","text":"Согласуем работы до начала ремонта."},{"title":"Wi-Fi","text":"Подождать можно рядом."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/dsm-garage/media/hero.svg","logo":"/t/dsm-garage/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'dsm-garage'), 'post-1', 'Подъёмник 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'dsm-garage'), 'post-2', 'Подъёмник 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'dsm-garage'), 'diag', 'Компьютерная диагностика', 'Сканер и чтение ошибок', 40, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'dsm-garage'), 'oil', 'Замена масла и фильтра', 'Масло клиента или наше', 30, 40, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'dsm-garage'), 'chassis', 'Осмотр ходовой', 'На подъёмнике, с отчётом', 25, 60, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'dsm-garage'), 'alignment', 'Развал-схождение', 'Регулировка углов', 45, 60, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'dsm-garage'), 'brakes', 'Замена тормозных колодок', 'Одна ось', 40, 60, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'dsm-garage'), 1, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'dsm-garage'), 2, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'dsm-garage'), 3, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'dsm-garage'), 4, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'dsm-garage'), 5, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'dsm-garage'), 6, '10:00', '16:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dsm-garage'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dsm-garage'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dsm-garage'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dsm-garage'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dsm-garage'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dsm-garage'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dsm-garage'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dsm-garage'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dsm-garage'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dsm-garage'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dsm-garage'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dsm-garage'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'dsm-garage'), 'w1', '/t/dsm-garage/media/work-1.svg', 'Колёса и тормоза', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'dsm-garage'), 'w2', '/t/dsm-garage/media/work-2.svg', 'Кузов после работ', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'dsm-garage'), 'w3', '/t/dsm-garage/media/work-3.svg', 'Свет и оптика', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== dtlpro-gomel =====
insert into public.tenants (slug, mode, timezone, profile) values ('dtlpro-gomel', 'preview', 'Europe/Minsk', '{"name":"Dtlpro.by","shortName":"Dtlpro","kind":"Детейлинг · Гомель","tagline":"Плёнка, полировка, химчистка и тонировка на Междугородней","description":"Оклейка полиуретаном, полировка, химчистка, ремонт кожи, ламинация карбоном, тонировка. Демо-версия сайта для студии: цены взяты из карточки на картах и могли измениться, их владелец меняет в кабинете.","address":"г. Гомель, Междугородняя ул., 22Б","phone":"+375 33 336-22-27","accent":"#00C2A8","cards":[{"title":"Плёнка","text":"Полиуретан на зоны риска."},{"title":"Карбон","text":"Ламинация деталей."},{"title":"Химчистка","text":"Салон и кожа."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/dtlpro-gomel/media/hero.svg","logo":"/t/dtlpro-gomel/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 'ppf', 'Оклейка зон риска плёнкой', 'По карточке — от 100 BYN', 100, 240, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 'polish', 'Полировка кузова', 'По карточке — от 60 BYN', 60, 240, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 'headlights', 'Полировка фар', '', 100, 90, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 'underbody', 'Мойка днища на подъёмнике', '', 90, 90, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 'interior', 'Химчистка салона', '', 320, 300, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 1, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 2, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 3, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 4, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 5, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 6, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 'w1', '/t/dtlpro-gomel/media/work-1.svg', 'Плёнка и оптика', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 'w2', '/t/dtlpro-gomel/media/work-2.svg', 'Блеск кузова', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'dtlpro-gomel'), 'w3', '/t/dtlpro-gomel/media/work-3.svg', 'Салон после химчистки', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== fastclean =====
insert into public.tenants (slug, mode, timezone, profile) values ('fastclean', 'preview', 'Europe/Minsk', '{"name":"ФастКлин","shortName":"ФастКлин","kind":"Автомойка · Минск, Партизанский район","tagline":"Быстрая мойка на Бядули: четыре поста, кофе с собой","description":"Комплексная мойка, химчистка салона, мойка двигателя и днища, полировка кузова. До четырёх машин одновременно, зал ожидания и Wi-Fi. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Змитрока Бядули, 13 к6","phone":"+375 29 352-97-97","accent":"#00B4D8","cards":[{"title":"4 поста","text":"Принимаем до четырёх машин сразу."},{"title":"Каждый день","text":"С 8:00 до 21:00 без выходных."},{"title":"Кофе с собой","text":"Зал ожидания и Wi-Fi."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/fastclean/media/hero.svg","logo":"/t/fastclean/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'fastclean'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'fastclean'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'fastclean'), 'post-3', 'Пост 3', 2) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'fastclean'), 'post-4', 'Пост 4', 3) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'fastclean'), 'complex', 'Комплексная мойка', 'Кузов, салон, коврики, стёкла', 35, 60, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'fastclean'), 'interior', 'Химчистка салона', 'Сиденья, ковры, пластик', 230, 300, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'fastclean'), 'engine', 'Мойка двигателя', 'С консервацией', 35, 40, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'fastclean'), 'underbody', 'Мойка днища', 'Арки и днище', 30, 30, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'fastclean'), 'polish', 'Полировка кузова', 'Восстановительная', 380, 480, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'fastclean'), 0, '08:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'fastclean'), 1, '08:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'fastclean'), 2, '08:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'fastclean'), 3, '08:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'fastclean'), 4, '08:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'fastclean'), 5, '08:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'fastclean'), 6, '08:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fastclean'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fastclean'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fastclean'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fastclean'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fastclean'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fastclean'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fastclean'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fastclean'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fastclean'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fastclean'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fastclean'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fastclean'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'fastclean'), 'w1', '/t/fastclean/media/work-1.svg', 'Пена на кузове', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'fastclean'), 'w2', '/t/fastclean/media/work-2.svg', 'Химчистка', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'fastclean'), 'w3', '/t/fastclean/media/work-3.svg', 'Блеск после полировки', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== fortuna-auto =====
insert into public.tenants (slug, mode, timezone, profile) values ('fortuna-auto', 'preview', 'Europe/Minsk', '{"name":"Fortuna Auto","shortName":"Fortuna","kind":"Автосервис · Минск","tagline":"Автосервис с подбором запчастей на Севастопольской","description":"Легковой автосервис с подбором запчастей и индивидуальным подходом. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Севастопольская, 2а к1","phone":"+375 29 574-77-77","accent":"#D4AF37","cards":[{"title":"Диагностика","text":"Сканер и осмотр на подъёмнике."},{"title":"Смета до ремонта","text":"Согласуем работы и цену заранее."},{"title":"Запись на время","text":"Без ожидания в очереди."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/fortuna-auto/media/hero.svg","logo":"/t/fortuna-auto/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'fortuna-auto'), 'post-1', 'Подъёмник 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'fortuna-auto'), 'post-2', 'Подъёмник 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'fortuna-auto'), 'diag', 'Компьютерная диагностика', 'Сканер и чтение ошибок', 40, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'fortuna-auto'), 'oil', 'Замена масла и фильтра', '', 30, 40, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'fortuna-auto'), 'brakes', 'Замена тормозных колодок', 'Одна ось', 40, 60, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'fortuna-auto'), 'chassis', 'Осмотр ходовой', 'На подъёмнике, с отчётом', 25, 60, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'fortuna-auto'), 'alignment', 'Развал-схождение', '', 45, 60, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'fortuna-auto'), 1, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'fortuna-auto'), 2, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'fortuna-auto'), 3, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'fortuna-auto'), 4, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'fortuna-auto'), 5, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'fortuna-auto'), 6, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fortuna-auto'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fortuna-auto'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fortuna-auto'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fortuna-auto'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fortuna-auto'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fortuna-auto'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fortuna-auto'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fortuna-auto'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fortuna-auto'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fortuna-auto'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fortuna-auto'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'fortuna-auto'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'fortuna-auto'), 'w1', '/t/fortuna-auto/media/work-1.svg', 'Колёса и диски', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'fortuna-auto'), 'w2', '/t/fortuna-auto/media/work-2.svg', 'Блеск кузова', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'fortuna-auto'), 'w3', '/t/fortuna-auto/media/work-3.svg', 'Плёнка и оптика', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== forum-wash =====
insert into public.tenants (slug, mode, timezone, profile) values ('forum-wash', 'preview', 'Europe/Minsk', '{"name":"Forum","shortName":"Forum","kind":"Автомойка · Минск, Ротмистрова","tagline":"Автомойка на Ротмистрова, 61а. Каждый день с 8 до 22","description":"Комплексная мойка от 25 рублей, химчистка салона, мойка двигателя и полировка. До четырёх машин одновременно, кофе с собой. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Ротмистрова, 61а","phone":"+375 44 500-02-22","accent":"#7C9CFF","cards":[{"title":"От 25 рублей","text":"Комплексная мойка без переплат."},{"title":"8:00–22:00","text":"Каждый день."},{"title":"До 4 машин","text":"Без долгой очереди."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/forum-wash/media/hero.svg","logo":"/t/forum-wash/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'forum-wash'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'forum-wash'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'forum-wash'), 'post-3', 'Пост 3', 2) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'forum-wash'), 'post-4', 'Пост 4', 3) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'forum-wash'), 'complex', 'Комплексная мойка', 'Кузов, салон, коврики', 25, 60, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'forum-wash'), 'express', 'Экспресс-мойка кузова', 'Бесконтактная, сушка', 15, 30, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'forum-wash'), 'interior', 'Химчистка салона', 'Полная', 220, 300, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'forum-wash'), 'engine', 'Мойка двигателя', 'С консервацией', 30, 40, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'forum-wash'), 'polish', 'Полировка кузова', 'Восстановительная', 380, 480, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'forum-wash'), 0, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'forum-wash'), 1, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'forum-wash'), 2, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'forum-wash'), 3, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'forum-wash'), 4, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'forum-wash'), 5, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'forum-wash'), 6, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'forum-wash'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'forum-wash'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'forum-wash'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'forum-wash'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'forum-wash'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'forum-wash'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'forum-wash'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'forum-wash'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'forum-wash'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'forum-wash'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'forum-wash'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'forum-wash'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'forum-wash'), 'w1', '/t/forum-wash/media/work-1.svg', 'Пена', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'forum-wash'), 'w2', '/t/forum-wash/media/work-2.svg', 'Чистые диски', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'forum-wash'), 'w3', '/t/forum-wash/media/work-3.svg', 'Салон после химчистки', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

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

-- ===== happy-car =====
insert into public.tenants (slug, mode, timezone, profile) values ('happy-car', 'preview', 'Europe/Minsk', '{"name":"Happy Car","shortName":"Happy Car","kind":"Автомойка и детейлинг · Могилёв","tagline":"Мойка, детейлинг и тонировка. Открыто до 23:00","description":"Бесконтактная, ручная и комплексная мойка, мойка двигателя и днища, химчистка, полировка, защитный воск, тонировка и заправка кондиционера. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Могилёв, Витебский тупик, 2А","phone":"+375 29 199-99-65","accent":"#FACC15","cards":[{"title":"До 23:00","text":"Удобно после работы."},{"title":"Всё в одном месте","text":"Мойка, детейлинг, тонировка, кондиционер."},{"title":"Защитный воск","text":"Блеск и защита после мойки."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/happy-car/media/hero.svg","logo":"/t/happy-car/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'happy-car'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'happy-car'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'happy-car'), 'post-3', 'Пост 3', 2) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'happy-car'), 'touchless', 'Бесконтактная мойка кузова', 'От 7 BYN', 10, 20, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'happy-car'), 'complex', 'Комплексная мойка', 'Кузов и салон', 40, 60, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'happy-car'), 'interior', 'Химчистка салона', 'Полная', 300, 300, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'happy-car'), 'polish', 'Полировка кузова', '', 400, 480, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'happy-car'), 'tint', 'Тонировка', 'Задняя полусфера', 180, 180, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'happy-car'), 'ac', 'Заправка кондиционера', '', 50, 40, true, 5)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'happy-car'), 0, '08:00', '23:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'happy-car'), 1, '08:00', '23:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'happy-car'), 2, '08:00', '23:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'happy-car'), 3, '08:00', '23:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'happy-car'), 4, '08:00', '23:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'happy-car'), 5, '08:00', '23:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'happy-car'), 6, '08:00', '23:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'happy-car'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'happy-car'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'happy-car'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'happy-car'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'happy-car'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'happy-car'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'happy-car'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'happy-car'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'happy-car'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'happy-car'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'happy-car'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'happy-car'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'happy-car'), 'w1', '/t/happy-car/media/work-1.svg', 'Пена', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'happy-car'), 'w2', '/t/happy-car/media/work-2.svg', 'Полировка', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'happy-car'), 'w3', '/t/happy-car/media/work-3.svg', 'Химчистка', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== hdh-detailing =====
insert into public.tenants (slug, mode, timezone, profile) values ('hdh-detailing', 'preview', 'Europe/Minsk', '{"name":"Hdh Detailing","shortName":"Hdh","kind":"Детейлинг и мойка · Гродно","tagline":"Детейлинг на Титова: полировка, химчистка, бронирование","description":"Полировка кузова и стёкол, химчистка салона, ручная и комплексная мойка, бронирование автомобиля плёнкой. Две моечные зоны. Демо-версия сайта для студии: цены взяты из карточки на картах и могли измениться, их владелец меняет в кабинете.","address":"г. Гродно, ул. Титова, 30А","phone":"+375 29 550-02-27","accent":"#60A5FA","cards":[{"title":"Две зоны","text":"Мойка и детейлинг — без очереди."},{"title":"Бронирование","text":"Защитная плёнка на кузов."},{"title":"Ручная мойка","text":"Бережно для ЛКП."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/hdh-detailing/media/hero.svg","logo":"/t/hdh-detailing/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'hdh-detailing'), 'post-1', 'Моечная зона 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'hdh-detailing'), 'post-2', 'Моечная зона 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'hdh-detailing'), 'complex', 'Комплексная мойка', 'Ручная, кузов и салон', 40, 60, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'hdh-detailing'), 'polish', 'Полировка кузова', 'От 550 BYN', 550, 480, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'hdh-detailing'), 'detail-polish', 'Детейлинг-полировка кузова', 'Многоэтапная, от 850 BYN', 850, 600, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'hdh-detailing'), 'interior', 'Детейлинг-химчистка салона', 'От 350 BYN', 350, 300, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'hdh-detailing'), 'engine', 'Мойка двигателя', '', 35, 40, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'hdh-detailing'), 1, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'hdh-detailing'), 2, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'hdh-detailing'), 3, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'hdh-detailing'), 4, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'hdh-detailing'), 5, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'hdh-detailing'), 6, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'hdh-detailing'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'hdh-detailing'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'hdh-detailing'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'hdh-detailing'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'hdh-detailing'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'hdh-detailing'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'hdh-detailing'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'hdh-detailing'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'hdh-detailing'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'hdh-detailing'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'hdh-detailing'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'hdh-detailing'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'hdh-detailing'), 'w1', '/t/hdh-detailing/media/work-1.svg', 'Полировка', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'hdh-detailing'), 'w2', '/t/hdh-detailing/media/work-2.svg', 'Химчистка', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'hdh-detailing'), 'w3', '/t/hdh-detailing/media/work-3.svg', 'Ручная мойка', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== lab888 =====
insert into public.tenants (slug, mode, timezone, profile) values ('lab888', 'preview', 'Europe/Minsk', '{"name":"Lab 888","shortName":"Lab 888","kind":"Детейлинг и мойка · Брест","tagline":"Трёхфазная мойка, химчистка и полировка на Тимирязева","description":"Трёхфазная мойка с воском или кварцем, уборка и химчистка салона, полировка кузова и фар. Демо-версия сайта для студии: цены взяты из карточки на картах и могли измениться, их владелец меняет в кабинете.","address":"г. Брест, ул. Тимирязева, 1","phone":"+375 33 990-98-88","accent":"#14B8A6","cards":[{"title":"Трёхфазная мойка","text":"С воском или кварцевым покрытием."},{"title":"Детейлинг","text":"Полировка кузова и фар, химчистка."},{"title":"Прайс открыт","text":"Цены видны до записи."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/lab888/media/hero.svg","logo":"/t/lab888/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'lab888'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'lab888'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'lab888'), 'wash-wax', 'Трёхфазная мойка с воском', '', 40, 60, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'lab888'), 'wash-quartz', 'Трёхфазная мойка с кварцем', 'Защитное покрытие', 80, 90, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'lab888'), 'cleaning', 'Уборка салона', 'Пылесос, пластик, стёкла', 30, 45, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'lab888'), 'interior', 'Химчистка салона и багажника', '', 350, 300, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'lab888'), 'polish', 'Полировка кузова', 'Точная цена после осмотра', 390, 480, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'lab888'), 'headlights', 'Полировка фар', 'Обе фары', 50, 60, true, 5)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'lab888'), 1, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'lab888'), 2, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'lab888'), 3, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'lab888'), 4, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'lab888'), 5, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'lab888'), 6, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'lab888'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'lab888'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'lab888'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'lab888'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'lab888'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'lab888'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'lab888'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'lab888'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'lab888'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'lab888'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'lab888'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'lab888'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'lab888'), 'w1', '/t/lab888/media/work-1.svg', 'Полировка', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'lab888'), 'w2', '/t/lab888/media/work-2.svg', 'Химчистка', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'lab888'), 'w3', '/t/lab888/media/work-3.svg', 'Трёхфазная мойка', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== mehanika =====
insert into public.tenants (slug, mode, timezone, profile) values ('mehanika', 'preview', 'Europe/Minsk', '{"name":"Механика","shortName":"Механика","kind":"СТО · Минск","tagline":"СТО на Пушкина, 68","description":"Легковой автосервис, Wi-Fi для клиентов. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, пр-т Пушкина, 68","phone":"+375 29 182-11-22","accent":"#5AA9E6","cards":[{"title":"Диагностика","text":"Сканер и осмотр на подъёмнике."},{"title":"Смета до ремонта","text":"Согласуем работы и цену заранее."},{"title":"Запись на время","text":"Без ожидания в очереди."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/mehanika/media/hero.svg","logo":"/t/mehanika/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'mehanika'), 'post-1', 'Подъёмник 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'mehanika'), 'post-2', 'Подъёмник 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'mehanika'), 'diag', 'Компьютерная диагностика', 'Сканер и чтение ошибок', 40, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'mehanika'), 'oil', 'Замена масла и фильтра', '', 30, 40, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'mehanika'), 'brakes', 'Замена тормозных колодок', 'Одна ось', 40, 60, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'mehanika'), 'chassis', 'Осмотр ходовой', 'На подъёмнике, с отчётом', 25, 60, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'mehanika'), 'alignment', 'Развал-схождение', '', 45, 60, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'mehanika'), 1, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'mehanika'), 2, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'mehanika'), 3, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'mehanika'), 4, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'mehanika'), 5, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'mehanika'), 6, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'mehanika'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'mehanika'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'mehanika'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'mehanika'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'mehanika'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'mehanika'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'mehanika'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'mehanika'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'mehanika'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'mehanika'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'mehanika'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'mehanika'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'mehanika'), 'w1', '/t/mehanika/media/work-1.svg', 'Колёса и диски', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'mehanika'), 'w2', '/t/mehanika/media/work-2.svg', 'Блеск кузова', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'mehanika'), 'w3', '/t/mehanika/media/work-3.svg', 'Плёнка и оптика', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== moonshine-gomel =====
insert into public.tenants (slug, mode, timezone, profile) values ('moonshine-gomel', 'preview', 'Europe/Minsk', '{"name":"Муншайн","shortName":"Муншайн","kind":"Детейлинг · Гомель","tagline":"Детейлинг, химчистка и оклейка на Луначарского","description":"Детейлинг, автохимчистка, полировка кузова и стёкол, оклейка фар и кузова. Демо-версия сайта для студии: цены взяты из карточки на картах и могли измениться, их владелец меняет в кабинете.","address":"г. Гомель, 3-я ул. Луначарского, 21","phone":"+375 29 370-70-69","accent":"#A3B8FF","cards":[{"title":"Химчистка","text":"Детейлинг и экспресс за день."},{"title":"Стёкла","text":"Шлифовка и полировка лобового."},{"title":"Оклейка","text":"Фары, фонари, пакеты."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/moonshine-gomel/media/hero.svg","logo":"/t/moonshine-gomel/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'moonshine-gomel'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'moonshine-gomel'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moonshine-gomel'), 'polish', 'Лёгкая полировка кузова', '', 600, 480, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moonshine-gomel'), 'detail-interior', 'Детейлинг-химчистка', '', 500, 600, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moonshine-gomel'), 'express-interior', 'Экспресс-химчистка', 'Около 8 часов', 350, 480, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moonshine-gomel'), 'windshield', 'Шлифовка и полировка лобового стекла', '', 350, 300, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moonshine-gomel'), 'lights', 'Оклейка фар и фонарей', '', 200, 180, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moonshine-gomel'), 1, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moonshine-gomel'), 2, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moonshine-gomel'), 3, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moonshine-gomel'), 4, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moonshine-gomel'), 5, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moonshine-gomel'), 6, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), 'w1', '/t/moonshine-gomel/media/work-1.svg', 'Блеск кузова', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), 'w2', '/t/moonshine-gomel/media/work-2.svg', 'Салон после химчистки', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'moonshine-gomel'), 'w3', '/t/moonshine-gomel/media/work-3.svg', 'Плёнка и оптика', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== motorbob =====
insert into public.tenants (slug, mode, timezone, profile) values ('motorbob', 'preview', 'Europe/Minsk', '{"name":"Моторбоб","shortName":"Моторбоб","kind":"Шиномонтаж · Минск","tagline":"Шиномонтаж на Горовца, 5Б","description":"Шиномонтаж и продажа шин б/у. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Горовца, 5Б","phone":"+375 29 395-02-02","accent":"#FF6B3D","cards":[{"title":"Без очереди","text":"Приезжайте к своему времени."},{"title":"Любые диски","text":"Штамповка и литьё."},{"title":"Балансировка","text":"На точном стенде."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/motorbob/media/hero.svg","logo":"/t/motorbob/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'motorbob'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'motorbob'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'motorbob'), 'tires-small', 'Сезонная замена R13–R16', 'Снятие, монтаж, балансировка 4 колёс', 35, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'motorbob'), 'tires-big', 'Сезонная замена R17–R20', 'Снятие, монтаж, балансировка 4 колёс', 50, 60, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'motorbob'), 'balance', 'Балансировка 4 колёс', '', 20, 30, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'motorbob'), 'repair', 'Ремонт прокола', 'Жгут или грибок', 15, 30, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'motorbob'), 0, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'motorbob'), 1, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'motorbob'), 2, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'motorbob'), 3, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'motorbob'), 4, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'motorbob'), 5, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'motorbob'), 6, '10:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'motorbob'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'motorbob'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'motorbob'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'motorbob'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'motorbob'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'motorbob'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'motorbob'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'motorbob'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'motorbob'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'motorbob'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'motorbob'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'motorbob'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'motorbob'), 'w1', '/t/motorbob/media/work-1.svg', 'Колёса и диски', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'motorbob'), 'w2', '/t/motorbob/media/work-2.svg', 'Колёса и диски', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'motorbob'), 'w3', '/t/motorbob/media/work-3.svg', 'Мойка', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== moyka-grishina =====
insert into public.tenants (slug, mode, timezone, profile) values ('moyka-grishina', 'preview', 'Europe/Minsk', '{"name":"Автомойка на Гришина","shortName":"Мойка","kind":"Автомойка и детейлинг · Могилёв","tagline":"Мойка, детейлинг и химчистка на Гришина, 90А","description":"Мойка, трёхфазная мойка, удаление битума и металлических вкраплений, кварцевое покрытие, химчистка. Демо-версия сайта для студии: цены взяты из карточки на картах и могли измениться, их владелец меняет в кабинете.","address":"г. Могилёв, ул. Гришина, 90А","phone":"+375 29 169-98-28","accent":"#2BB673","cards":[{"title":"Трёхфазная мойка","text":"Глубокая очистка кузова."},{"title":"Детейлинг","text":"Битум, металл, кварц."},{"title":"Оплата картой","text":"Без наличных."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/moyka-grishina/media/hero.svg","logo":"/t/moyka-grishina/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'moyka-grishina'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'moyka-grishina'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moyka-grishina'), 'wash', 'Мойка', '', 20, 40, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moyka-grishina'), 'complex', 'Комплекс', '', 30, 60, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moyka-grishina'), 'full', 'Полный комплекс', '', 80, 120, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moyka-grishina'), 'three-phase', 'Трёхфазная мойка', '', 35, 60, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moyka-grishina'), 'bitumen', 'Удаление битума', '', 50, 60, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moyka-grishina'), 'interior', 'Химчистка салона', '', 300, 300, true, 5)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-grishina'), 0, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-grishina'), 1, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-grishina'), 2, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-grishina'), 3, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-grishina'), 4, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-grishina'), 5, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-grishina'), 6, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-grishina'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-grishina'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-grishina'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-grishina'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-grishina'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-grishina'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-grishina'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-grishina'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-grishina'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-grishina'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-grishina'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-grishina'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'moyka-grishina'), 'w1', '/t/moyka-grishina/media/work-1.svg', 'Мойка', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'moyka-grishina'), 'w2', '/t/moyka-grishina/media/work-2.svg', 'Блеск кузова', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'moyka-grishina'), 'w3', '/t/moyka-grishina/media/work-3.svg', 'Салон после химчистки', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== moyka-trostenetskaya =====
insert into public.tenants (slug, mode, timezone, profile) values ('moyka-trostenetskaya', 'preview', 'Europe/Minsk', '{"name":"Автомойка на Тростенецкой","shortName":"Мойка Т8","kind":"Автомойка и детейлинг · Минск","tagline":"Бесконтактная мойка, химчистка и полировка. Работаем с 8:00 до 22:00","description":"Большая мойка на Тростенецкой, 8: несколько постов, зал ожидания, кофе и чай с собой. Мойка двигателя, химчистка, полировка. Демо-версия сайта для студии: цены и длительность примерные, их владелец меняет в кабинете.","address":"г. Минск, Тростенецкая ул., 8","phone":"+375 17 242-18-45","accent":"#F59E0B","cards":[{"title":"8:00–22:00","text":"Каждый день, удобно до и после работы."},{"title":"Без очереди","text":"Несколько постов, точное время по записи."},{"title":"Кафе","text":"Кофе и чай с собой, пока моем машину."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/moyka-trostenetskaya/media/hero.svg","logo":"/t/moyka-trostenetskaya/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 'post-3', 'Пост 3', 2) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 'complex', 'Комплексная мойка', 'Кузов, салон, коврики, стёкла', 54, 60, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 'touchless', 'Бесконтактная мойка', 'Кузов и диски', 30, 30, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 'interior', 'Химчистка салона', 'Полная', 240, 300, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 'polish', 'Полировка кузова', 'Восстановительная', 380, 480, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 'engine', 'Мойка двигателя', 'С консервацией', 40, 40, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 0, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 1, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 2, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 3, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 4, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 5, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 6, '08:00', '22:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 'w1', '/t/moyka-trostenetskaya/media/work-1.svg', 'Бесконтактная мойка', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 'w2', '/t/moyka-trostenetskaya/media/work-2.svg', 'Полировка', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'moyka-trostenetskaya'), 'w3', '/t/moyka-trostenetskaya/media/work-3.svg', 'Химчистка', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== nero =====
insert into public.tenants (slug, mode, timezone, profile) values ('nero', 'preview', 'Europe/Minsk', '{"name":"Nero Detailing","shortName":"Nero","kind":"Детейлинг-студия · Минск","tagline":"Детейлинг на Семашко: керамика, полировка, химчистка","description":"Детейлинг-студия с автоматическими воротами и удобным заездом. Полировка, керамика, химчистка, защита фар. Демо-версия сайта для студии: цены и длительность примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Семашко, 25а","phone":"+375 29 180-16-01","accent":"#2EC4B6","cards":[{"title":"Керамика","text":"Защита блеска до 2 лет."},{"title":"Удобный заезд","text":"Автоматические ворота, доступный вход."},{"title":"Оплата на месте","text":"Наличными после приёмки работы."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/nero/media/hero.svg","logo":"/t/nero/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'nero'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'nero'), 'wash', 'Детейлинг-мойка', 'Двухфазная мойка, диски, сушка', 60, 90, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'nero'), 'interior', 'Химчистка салона', 'Полная, с сушкой', 260, 300, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'nero'), 'polish', 'Полировка кузова', 'Двухэтапная', 420, 480, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'nero'), 'ceramic', 'Керамическое покрытие', 'Подготовка, полировка, керамика', 800, 1440, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'nero'), 'lights', 'Плёнка на фары', 'Полиуретан, обе фары', 150, 120, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'nero'), 1, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'nero'), 2, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'nero'), 3, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'nero'), 4, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'nero'), 5, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'nero'), 6, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'nero'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'nero'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'nero'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'nero'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'nero'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'nero'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'nero'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'nero'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'nero'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'nero'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'nero'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'nero'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'nero'), 'w1', '/t/nero/media/work-1.svg', 'Полировка', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'nero'), 'w2', '/t/nero/media/work-2.svg', 'Химчистка салона', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'nero'), 'w3', '/t/nero/media/work-3.svg', 'Защита фар', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== ofs-service =====
insert into public.tenants (slug, mode, timezone, profile) values ('ofs-service', 'preview', 'Europe/Minsk', '{"name":"Only fans service","shortName":"Only fans","kind":"СТО и шиномонтаж · Минск","tagline":"СТО и шиномонтаж на Платонова, 14Б","description":"СТО, шиномонтаж, замена колодок, мойка колёс. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Платонова, 14Б","phone":"+375 29 101-23-43","accent":"#E25C9A","cards":[{"title":"Диагностика","text":"Сканер и осмотр на подъёмнике."},{"title":"Смета до ремонта","text":"Согласуем работы и цену заранее."},{"title":"Запись на время","text":"Без ожидания в очереди."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/ofs-service/media/hero.svg","logo":"/t/ofs-service/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'ofs-service'), 'post-1', 'Подъёмник 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'ofs-service'), 'post-2', 'Подъёмник 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'ofs-service'), 'diag', 'Компьютерная диагностика', 'Сканер и чтение ошибок', 40, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'ofs-service'), 'oil', 'Замена масла и фильтра', '', 30, 40, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'ofs-service'), 'brakes', 'Замена тормозных колодок', 'Одна ось', 40, 60, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'ofs-service'), 'chassis', 'Осмотр ходовой', 'На подъёмнике, с отчётом', 25, 60, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'ofs-service'), 'tires', 'Сезонная замена колёс', 'R13–R18, с балансировкой', 40, 45, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'ofs-service'), 1, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'ofs-service'), 2, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'ofs-service'), 3, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'ofs-service'), 4, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'ofs-service'), 5, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'ofs-service'), 6, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'ofs-service'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'ofs-service'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'ofs-service'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'ofs-service'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'ofs-service'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'ofs-service'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'ofs-service'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'ofs-service'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'ofs-service'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'ofs-service'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'ofs-service'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'ofs-service'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'ofs-service'), 'w1', '/t/ofs-service/media/work-1.svg', 'Колёса и диски', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'ofs-service'), 'w2', '/t/ofs-service/media/work-2.svg', 'Блеск кузова', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'ofs-service'), 'w3', '/t/ofs-service/media/work-3.svg', 'Мойка', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== olimpik =====
insert into public.tenants (slug, mode, timezone, profile) values ('olimpik', 'preview', 'Europe/Minsk', '{"name":"Олимпик Детейлинг","shortName":"Олимпик","kind":"Детейлинг · Минск, Заводской район","tagline":"Мойка паром, химчистка и полировка. Тёплый бокс на два автомобиля","description":"Бережная мойка паром и бесконтактная мойка, химчистка салона, мойка двигателя и днища, полировка кузова. Пока машина в работе — зал ожидания и Wi-Fi. Демо-версия сайта для студии: цены и длительность примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Жилуновича, 7/7-1, 1 этаж","phone":"+375 29 314-57-77","accent":"#D9A83A","cards":[{"title":"Мойка паром","text":"Деликатно для кузова и салона, без лишней химии."},{"title":"Два поста","text":"В боксе одновременно не больше двух машин — без очереди."},{"title":"Зал ожидания","text":"Wi-Fi и кофе, пока идёт работа."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/olimpik/media/hero.svg","logo":"/t/olimpik/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'olimpik'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'olimpik'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'olimpik'), 'complex', 'Комплексная мойка', 'Кузов, салон, коврики, стёкла', 100, 90, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'olimpik'), 'steam', 'Мойка паром', 'Кузов и диски паром, сушка', 60, 60, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'olimpik'), 'interior', 'Химчистка салона', 'Сиденья, потолок, ковры, пластик', 280, 300, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'olimpik'), 'polish', 'Полировка кузова', 'Восстановительная, двухэтапная', 450, 480, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'olimpik'), 'engine', 'Мойка двигателя', 'Паром, с консервацией', 40, 45, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'olimpik'), 'underbody', 'Мойка днища', 'Арки, днище, пороги', 35, 30, true, 5)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'olimpik'), 0, '10:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'olimpik'), 1, '10:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'olimpik'), 2, '10:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'olimpik'), 3, '10:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'olimpik'), 4, '10:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'olimpik'), 5, '10:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'olimpik'), 6, '10:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'olimpik'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'olimpik'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'olimpik'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'olimpik'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'olimpik'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'olimpik'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'olimpik'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'olimpik'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'olimpik'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'olimpik'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'olimpik'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'olimpik'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'olimpik'), 'w1', '/t/olimpik/media/work-1.svg', 'Полировка: глубокий блеск', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'olimpik'), 'w2', '/t/olimpik/media/work-2.svg', 'Химчистка салона', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'olimpik'), 'w3', '/t/olimpik/media/work-3.svg', 'Мойка паром', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

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

-- ===== rd-detailing =====
insert into public.tenants (slug, mode, timezone, profile) values ('rd-detailing', 'preview', 'Europe/Minsk', '{"name":"RD Detailing","shortName":"RD","kind":"Детейлинг-студия · Минск","tagline":"Полировка, плёнка, кузовной ремонт и тюнинг","description":"Студия детейлинга на Дзержинского: полировка и защитные покрытия, оклейка плёнкой, локальный кузовной ремонт и тюнинг. Демо-версия сайта для студии: цены и длительность примерные, их владелец меняет в кабинете.","address":"г. Минск, пр-т Дзержинского, 1в к6","phone":"+375 29 144-00-99","accent":"#E5484D","cards":[{"title":"Плёнка","text":"Полиуретан на зоны риска и полностью."},{"title":"Кузовной ремонт","text":"Сколы, царапины, локальная покраска."},{"title":"Тюнинг","text":"Антихром, тонировка, детали."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/rd-detailing/media/hero.svg","logo":"/t/rd-detailing/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'rd-detailing'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'rd-detailing'), 'post-2', 'Пост 2 (плёнка)', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'rd-detailing'), 'polish', 'Полировка кузова', 'Абразивная, в два этапа', 450, 480, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'rd-detailing'), 'ppf-zones', 'Плёнка на зоны риска', 'Капот, фары, бампер, зеркала', 1100, 2880, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.service_resources (tenant_id, service_id, resource_id) select t.id, s.id, r.id from public.tenants t join public.services s on s.tenant_id = t.id and s.key = 'ppf-zones' join public.resources r on r.tenant_id = t.id and r.key = 'post-2' where t.slug = 'rd-detailing' on conflict do nothing;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'rd-detailing'), 'chips', 'Ремонт сколов', 'Локально, подбор краски', 60, 120, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'rd-detailing'), 'tint', 'Тонировка', 'Задняя полусфера', 200, 180, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'rd-detailing'), 'antichrome', 'Антихром', 'Оклейка хрома плёнкой', 250, 300, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.service_resources (tenant_id, service_id, resource_id) select t.id, s.id, r.id from public.tenants t join public.services s on s.tenant_id = t.id and s.key = 'antichrome' join public.resources r on r.tenant_id = t.id and r.key = 'post-2' where t.slug = 'rd-detailing' on conflict do nothing;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'rd-detailing'), 1, '10:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'rd-detailing'), 2, '10:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'rd-detailing'), 3, '10:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'rd-detailing'), 4, '10:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'rd-detailing'), 5, '10:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'rd-detailing'), 6, '10:00', '17:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'rd-detailing'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'rd-detailing'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'rd-detailing'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'rd-detailing'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'rd-detailing'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'rd-detailing'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'rd-detailing'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'rd-detailing'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'rd-detailing'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'rd-detailing'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'rd-detailing'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'rd-detailing'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'rd-detailing'), 'w1', '/t/rd-detailing/media/work-1.svg', 'Полировка кузова', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'rd-detailing'), 'w2', '/t/rd-detailing/media/work-2.svg', 'Плёнка на фары', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'rd-detailing'), 'w3', '/t/rd-detailing/media/work-3.svg', 'Детали и диски', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== restyling-gomel =====
insert into public.tenants (slug, mode, timezone, profile) values ('restyling-gomel', 'preview', 'Europe/Minsk', '{"name":"Restyling.by","shortName":"Restyling","kind":"Детейлинг и тюнинг · Гомель","tagline":"Бронеплёнка, керамика, тонировка и покраска дисков","description":"Оклейка салона и кузова, тонировка, бронеплёнка, полировка и керамика, покраска дисков, предпродажная подготовка. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Гомель, ул. Владимирова, 10Г","phone":"+375 29 322-66-88","accent":"#FF8A00","cards":[{"title":"Бронеплёнка","text":"Защита кузова от сколов."},{"title":"Диски","text":"Порошковая покраска."},{"title":"Мото","text":"Тюнинг и для мотоциклов."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/restyling-gomel/media/hero.svg","logo":"/t/restyling-gomel/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'restyling-gomel'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'restyling-gomel'), 'post-2', 'Пост 2 (плёнка)', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'restyling-gomel'), 'ppf', 'Бронеплёнка на зоны риска', '', 1000, 2880, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.service_resources (tenant_id, service_id, resource_id) select t.id, s.id, r.id from public.tenants t join public.services s on s.tenant_id = t.id and s.key = 'ppf' join public.resources r on r.tenant_id = t.id and r.key = 'post-2' where t.slug = 'restyling-gomel' on conflict do nothing;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'restyling-gomel'), 'ceramic', 'Полировка и керамика', '', 800, 1440, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'restyling-gomel'), 'tint', 'Тонировка', 'Задняя полусфера', 180, 180, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'restyling-gomel'), 'wheels', 'Порошковая покраска дисков', 'Комплект', 300, 1440, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'restyling-gomel'), 1, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'restyling-gomel'), 2, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'restyling-gomel'), 3, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'restyling-gomel'), 4, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'restyling-gomel'), 5, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'restyling-gomel'), 6, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'restyling-gomel'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'restyling-gomel'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'restyling-gomel'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'restyling-gomel'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'restyling-gomel'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'restyling-gomel'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'restyling-gomel'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'restyling-gomel'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'restyling-gomel'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'restyling-gomel'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'restyling-gomel'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'restyling-gomel'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'restyling-gomel'), 'w1', '/t/restyling-gomel/media/work-1.svg', 'Плёнка и оптика', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'restyling-gomel'), 'w2', '/t/restyling-gomel/media/work-2.svg', 'Блеск кузова', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'restyling-gomel'), 'w3', '/t/restyling-gomel/media/work-3.svg', 'Колёса и диски', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== safari-service =====
insert into public.tenants (slug, mode, timezone, profile) values ('safari-service', 'preview', 'Europe/Minsk', '{"name":"Сафари сервис","shortName":"Сафари","kind":"Автосервис · Минск","tagline":"Подготовим к любой дороге!","description":"Легковой автосервис: подготовка машины к любой дороге. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Левкова, 41/1","phone":"+375 29 107-09-11","accent":"#C8913A","cards":[{"title":"Диагностика","text":"Сканер и осмотр на подъёмнике."},{"title":"Смета до ремонта","text":"Согласуем работы и цену заранее."},{"title":"Запись на время","text":"Без ожидания в очереди."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/safari-service/media/hero.svg","logo":"/t/safari-service/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'safari-service'), 'post-1', 'Подъёмник 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'safari-service'), 'post-2', 'Подъёмник 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'safari-service'), 'diag', 'Компьютерная диагностика', 'Сканер и чтение ошибок', 40, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'safari-service'), 'oil', 'Замена масла и фильтра', '', 30, 40, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'safari-service'), 'brakes', 'Замена тормозных колодок', 'Одна ось', 40, 60, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'safari-service'), 'chassis', 'Осмотр ходовой', 'На подъёмнике, с отчётом', 25, 60, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'safari-service'), 'alignment', 'Развал-схождение', '', 45, 60, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'safari-service'), 1, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'safari-service'), 2, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'safari-service'), 3, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'safari-service'), 4, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'safari-service'), 5, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'safari-service'), 6, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'safari-service'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'safari-service'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'safari-service'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'safari-service'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'safari-service'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'safari-service'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'safari-service'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'safari-service'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'safari-service'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'safari-service'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'safari-service'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'safari-service'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'safari-service'), 'w1', '/t/safari-service/media/work-1.svg', 'Колёса и диски', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'safari-service'), 'w2', '/t/safari-service/media/work-2.svg', 'Блеск кузова', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'safari-service'), 'w3', '/t/safari-service/media/work-3.svg', 'Плёнка и оптика', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== samurai-gomel =====
insert into public.tenants (slug, mode, timezone, profile) values ('samurai-gomel', 'preview', 'Europe/Minsk', '{"name":"Samurai Detailing","shortName":"Samurai","kind":"Детейлинг · Гомель","tagline":"Коррекция ЛКП, керамика и антигравийная плёнка","description":"Химчистка салона, коррекция и полировка кузова, керамика, оклейка антигравийной плёнкой, реставрация фар, удаление вмятин без покраски. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Гомель, Железнодорожный район","phone":"+375 33 633-55-34","accent":"#EA580C","cards":[{"title":"Коррекция ЛКП","text":"Убираем голограммы и царапины."},{"title":"Плёнка","text":"Антигравийная защита зон риска."},{"title":"Сертификаты","text":"Подарочный сертификат на любую услугу."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/samurai-gomel/media/hero.svg","logo":"/t/samurai-gomel/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'samurai-gomel'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'samurai-gomel'), 'post-2', 'Пост 2 (плёнка)', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'samurai-gomel'), 'interior', 'Химчистка салона', 'Полная', 400, 300, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'samurai-gomel'), 'correction', 'Коррекция ЛКП', 'От 300 BYN, точно после осмотра', 300, 480, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'samurai-gomel'), 'headlights', 'Реставрация фар', 'Шлифовка и полировка', 80, 90, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'samurai-gomel'), 'rain', 'Антидождь', 'Стёкла', 30, 30, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'samurai-gomel'), 'ceramic', 'Керамическое покрытие', 'Подготовка и нанесение', 700, 1440, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'samurai-gomel'), 'ppf', 'Плёнка на зоны риска', 'Капот, бампер, фары', 1000, 2880, true, 5)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.service_resources (tenant_id, service_id, resource_id) select t.id, s.id, r.id from public.tenants t join public.services s on s.tenant_id = t.id and s.key = 'ppf' join public.resources r on r.tenant_id = t.id and r.key = 'post-2' where t.slug = 'samurai-gomel' on conflict do nothing;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'samurai-gomel'), 1, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'samurai-gomel'), 2, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'samurai-gomel'), 3, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'samurai-gomel'), 4, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'samurai-gomel'), 5, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'samurai-gomel'), 6, '09:00', '18:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'samurai-gomel'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'samurai-gomel'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'samurai-gomel'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'samurai-gomel'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'samurai-gomel'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'samurai-gomel'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'samurai-gomel'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'samurai-gomel'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'samurai-gomel'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'samurai-gomel'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'samurai-gomel'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'samurai-gomel'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'samurai-gomel'), 'w1', '/t/samurai-gomel/media/work-1.svg', 'Коррекция ЛКП', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'samurai-gomel'), 'w2', '/t/samurai-gomel/media/work-2.svg', 'Плёнка на фары', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'samurai-gomel'), 'w3', '/t/samurai-gomel/media/work-3.svg', 'Химчистка', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== shinka-pushkina =====
insert into public.tenants (slug, mode, timezone, profile) values ('shinka-pushkina', 'preview', 'Europe/Minsk', '{"name":"Шиномонтаж на Пушкина","shortName":"Шинка","kind":"Шиномонтаж · Минск","tagline":"Шиномонтаж на Пушкина, 70а — каждый день с 9 до 20","description":"Шиномонтаж каждый день с 9:00 до 20:00. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, пр-т Пушкина, 70а","phone":"+375 33 388-86-76","accent":"#FFC23D","cards":[{"title":"Без очереди","text":"Приезжайте к своему времени."},{"title":"Любые диски","text":"Штамповка и литьё."},{"title":"Балансировка","text":"На точном стенде."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/shinka-pushkina/media/hero.svg","logo":"/t/shinka-pushkina/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'shinka-pushkina'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'shinka-pushkina'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'shinka-pushkina'), 'tires-small', 'Сезонная замена R13–R16', 'Снятие, монтаж, балансировка 4 колёс', 35, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'shinka-pushkina'), 'tires-big', 'Сезонная замена R17–R20', 'Снятие, монтаж, балансировка 4 колёс', 50, 60, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'shinka-pushkina'), 'balance', 'Балансировка 4 колёс', '', 20, 30, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'shinka-pushkina'), 'repair', 'Ремонт прокола', 'Жгут или грибок', 15, 30, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka-pushkina'), 0, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka-pushkina'), 1, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka-pushkina'), 2, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka-pushkina'), 3, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka-pushkina'), 4, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka-pushkina'), 5, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka-pushkina'), 6, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), 'w1', '/t/shinka-pushkina/media/work-1.svg', 'Колёса и диски', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), 'w2', '/t/shinka-pushkina/media/work-2.svg', 'Колёса и диски', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'shinka-pushkina'), 'w3', '/t/shinka-pushkina/media/work-3.svg', 'Мойка', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== shinka20 =====
insert into public.tenants (slug, mode, timezone, profile) values ('shinka20', 'preview', 'Europe/Minsk', '{"name":"Шинка 20","shortName":"Шинка 20","kind":"Шиномонтаж · Минск, Первомайский район","tagline":"Шиномонтаж без очереди: каждый день с 9 до 21","description":"Сезонная замена колёс, балансировка, ремонт проколов. Приезжайте к своему времени — без ожидания в очереди. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, 1-й Твёрдый пер., 11 к9","phone":"+375 29 583-54-22","accent":"#FFB020","cards":[{"title":"Без очереди","text":"Точное время по записи."},{"title":"Каждый день","text":"С 9:00 до 21:00."},{"title":"Любые диски","text":"Штамповка и литьё R13–R20."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/shinka20/media/hero.svg","logo":"/t/shinka20/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'shinka20'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'shinka20'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'shinka20'), 'tires-small', 'Сезонная замена R13–R16', 'Снятие, монтаж, балансировка 4 колёс', 35, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'shinka20'), 'tires-big', 'Сезонная замена R17–R20', 'Снятие, монтаж, балансировка 4 колёс', 50, 60, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'shinka20'), 'balance', 'Балансировка 4 колёс', '', 20, 30, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'shinka20'), 'repair', 'Ремонт прокола', 'Жгут или грибок', 15, 30, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka20'), 0, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka20'), 1, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka20'), 2, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka20'), 3, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka20'), 4, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka20'), 5, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinka20'), 6, '09:00', '21:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka20'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka20'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka20'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka20'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka20'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka20'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka20'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka20'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka20'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka20'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka20'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinka20'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'shinka20'), 'w1', '/t/shinka20/media/work-1.svg', 'Литые диски', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'shinka20'), 'w2', '/t/shinka20/media/work-2.svg', 'Балансировка', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'shinka20'), 'w3', '/t/shinka20/media/work-3.svg', 'Мойка колёс', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== shinomontazh-vitebsk =====
insert into public.tenants (slug, mode, timezone, profile) values ('shinomontazh-vitebsk', 'preview', 'Europe/Minsk', '{"name":"Шиномонтаж на Кутузова","shortName":"Шиномонтаж","kind":"Шиномонтаж · Витебск","tagline":"Шиномонтаж на Кутузова, 13 и выезд к клиенту","description":"Шиномонтаж, выездной шиномонтаж, оплата картой. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Витебск, ул. Кутузова, 13","phone":"+375 33 644-66-88","accent":"#1FB5C9","cards":[{"title":"Без очереди","text":"Приезжайте к своему времени."},{"title":"Любые диски","text":"Штамповка и литьё."},{"title":"Балансировка","text":"На точном стенде."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/shinomontazh-vitebsk/media/hero.svg","logo":"/t/shinomontazh-vitebsk/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 'tires-small', 'Сезонная замена R13–R16', 'Снятие, монтаж, балансировка 4 колёс', 35, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 'tires-big', 'Сезонная замена R17–R20', 'Снятие, монтаж, балансировка 4 колёс', 50, 60, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 'balance', 'Балансировка 4 колёс', '', 20, 30, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 'repair', 'Ремонт прокола', 'Жгут или грибок', 15, 30, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 'mobile', 'Выездной шиномонтаж', 'Приедем к вам', 80, 90, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 0, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 1, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 2, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 3, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 4, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 5, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 6, '09:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 'w1', '/t/shinomontazh-vitebsk/media/work-1.svg', 'Колёса и диски', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 'w2', '/t/shinomontazh-vitebsk/media/work-2.svg', 'Колёса и диски', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'shinomontazh-vitebsk'), 'w3', '/t/shinomontazh-vitebsk/media/work-3.svg', 'Мойка', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== vershina-tires =====
insert into public.tenants (slug, mode, timezone, profile) values ('vershina-tires', 'preview', 'Europe/Minsk', '{"name":"Вершина","shortName":"Вершина","kind":"Шиномонтаж и автосервис · Минск","tagline":"Шиномонтаж на Гурского, 28а","description":"Шиномонтаж и автосервис, замена колодок, продажа шин б/у. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Гурского, 28а","phone":"+375 29 660-01-53","accent":"#F2994A","cards":[{"title":"Без очереди","text":"Приезжайте к своему времени."},{"title":"Любые диски","text":"Штамповка и литьё."},{"title":"Балансировка","text":"На точном стенде."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/vershina-tires/media/hero.svg","logo":"/t/vershina-tires/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'vershina-tires'), 'post-1', 'Пост 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'vershina-tires'), 'post-2', 'Пост 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'vershina-tires'), 'tires-small', 'Сезонная замена R13–R16', 'Снятие, монтаж, балансировка 4 колёс', 35, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'vershina-tires'), 'tires-big', 'Сезонная замена R17–R20', 'Снятие, монтаж, балансировка 4 колёс', 50, 60, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'vershina-tires'), 'balance', 'Балансировка 4 колёс', '', 20, 30, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'vershina-tires'), 'repair', 'Ремонт прокола', 'Жгут или грибок', 15, 30, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'vershina-tires'), 0, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'vershina-tires'), 1, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'vershina-tires'), 2, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'vershina-tires'), 3, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'vershina-tires'), 4, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'vershina-tires'), 5, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'vershina-tires'), 6, '08:00', '20:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vershina-tires'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vershina-tires'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vershina-tires'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vershina-tires'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vershina-tires'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vershina-tires'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vershina-tires'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vershina-tires'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vershina-tires'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vershina-tires'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vershina-tires'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vershina-tires'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'vershina-tires'), 'w1', '/t/vershina-tires/media/work-1.svg', 'Колёса и диски', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'vershina-tires'), 'w2', '/t/vershina-tires/media/work-2.svg', 'Колёса и диски', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'vershina-tires'), 'w3', '/t/vershina-tires/media/work-3.svg', 'Мойка', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

-- ===== vvk-komplekt =====
insert into public.tenants (slug, mode, timezone, profile) values ('vvk-komplekt', 'preview', 'Europe/Minsk', '{"name":"ВВК комплект","shortName":"ВВК комплект","kind":"Автосервис · Минск","tagline":"Автосервис на Уборевича, 99","description":"Легковой автосервис: диагностика, обслуживание, ремонт ходовой и тормозов. Демо-версия сайта для студии: цены, длительность и часы примерные, их владелец меняет в кабинете.","address":"г. Минск, ул. Уборевича, 99","phone":"+375 29 356-07-01","accent":"#22C3A6","cards":[{"title":"Диагностика","text":"Сканер и осмотр на подъёмнике."},{"title":"Смета до ремонта","text":"Согласуем работы и цену заранее."},{"title":"Запись на время","text":"Без ожидания в очереди."}],"booking":{"bufferMin":10,"stepMin":30,"leadMin":60,"cancelHours":3,"horizonDays":30},"media":{"hero":"/t/vvk-komplekt/media/hero.svg","logo":"/t/vvk-komplekt/media/logo.svg"}}'::jsonb)
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'vvk-komplekt'), 'post-1', 'Подъёмник 1', 0) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.resources (tenant_id, key, name, sort) values ((select id from public.tenants where slug = 'vvk-komplekt'), 'post-2', 'Подъёмник 2', 1) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'vvk-komplekt'), 'diag', 'Компьютерная диагностика', 'Сканер и чтение ошибок', 40, 45, true, 0)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'vvk-komplekt'), 'oil', 'Замена масла и фильтра', '', 30, 40, true, 1)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'vvk-komplekt'), 'brakes', 'Замена тормозных колодок', 'Одна ось', 40, 60, true, 2)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'vvk-komplekt'), 'chassis', 'Осмотр ходовой', 'На подъёмнике, с отчётом', 25, 60, true, 3)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values ((select id from public.tenants where slug = 'vvk-komplekt'), 'alignment', 'Развал-схождение', '', 45, 60, true, 4)
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'vvk-komplekt'), 1, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'vvk-komplekt'), 2, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'vvk-komplekt'), 3, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'vvk-komplekt'), 4, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'vvk-komplekt'), 5, '09:00', '19:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.working_hours (tenant_id, weekday, opens, closes) values ((select id from public.tenants where slug = 'vvk-komplekt'), 6, '10:00', '16:00') on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), '2026-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), '2026-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), '2027-01-01', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), '2027-01-02', true, null, null, 'Новый год', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), '2027-01-07', true, null, null, 'Рождество Христово (православное)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), '2027-03-08', true, null, null, 'День женщин', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), '2027-05-01', true, null, null, 'Праздник труда', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), '2027-05-09', true, null, null, 'День Победы', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), '2027-05-11', true, null, null, 'Радуница', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), '2027-07-03', true, null, null, 'День Независимости', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), '2027-11-07', true, null, null, 'День Октябрьской революции', 'config') on conflict (tenant_id, day) do nothing;
insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), '2027-12-25', true, null, null, 'Рождество Христово (католическое)', 'config') on conflict (tenant_id, day) do nothing;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), 'w1', '/t/vvk-komplekt/media/work-1.svg', 'Колёса и диски', 0, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), 'w2', '/t/vvk-komplekt/media/work-2.svg', 'Блеск кузова', 1, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;
insert into public.works (tenant_id, key, photo_url, caption, sort, source) values ((select id from public.tenants where slug = 'vvk-komplekt'), 'w3', '/t/vvk-komplekt/media/work-3.svg', 'Плёнка и оптика', 2, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;

