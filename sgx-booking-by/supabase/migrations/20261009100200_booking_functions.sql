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
language plpgsql stable security definer set search_path = public as $$
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
language sql stable security definer set search_path = public as $$
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
) language plpgsql stable security definer set search_path = public as $$
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
language plpgsql immutable as $$
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
language plpgsql stable security definer set search_path = public as $$
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
language plpgsql security definer set search_path = public as $$
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
language plpgsql security definer set search_path = public as $$
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
language plpgsql stable security definer set search_path = public as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking and access_token_hash = public.token_hash(p_token);
  if not found or b.anonymized_at is not null then raise exception 'not_found' using errcode = 'P0001'; end if;
  return b;
end $$;

create or replace function public.get_my_booking(p_booking uuid, p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
language plpgsql security definer set search_path = public as $$
begin
  update bookings set status = 'cancelled', cancelled_by = p_by, cancelled_at = now() where id = p_booking;
  delete from resource_occupancies where booking_id = p_booking; -- время сразу освобождается
  perform public.sync_reminder(p_booking);
end $$;

create or replace function public.cancel_my_booking(p_booking uuid, p_token text) returns void
language plpgsql security definer set search_path = public as $$
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
language plpgsql security definer set search_path = public as $$
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
