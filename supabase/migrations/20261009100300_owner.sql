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
