-- =====================================================================
-- 18. Web Push клиенту при смене статуса записи: машина принята, готова; студия перенесла или отменила запись.
--
-- Клиент на странице «Моя запись» разрешает уведомления → подписка сохраняется в push_subscriptions.
-- Владелец меняет статус → триггер создаёт задание status_push_jobs с одноразовым nonce и через pg_net
-- вызывает функцию сайта /api/push (Vercel). Функция по nonce забирает задание (push_job_claim),
-- шифрует и отправляет уведомление (ключи VAPID берёт из push_config), отмечает результат (push_job_done).
-- Если вызов не дошёл — pg_cron раз в минуту повторяет (до 5 попыток за ~10 минут).
-- Ключи VAPID и nonce не доступны ни anon, ни authenticated напрямую; задание без верного nonce не выдаётся.
-- Напоминания за сутки (notification_jobs) по-прежнему выключены.
-- =====================================================================

do $$ begin
  create extension if not exists pg_net;
exception when others then raise notice 'pg_net недоступен: уведомления о статусе отправляться не будут (%)', sqlerrm;
end $$;

create table if not exists public.push_config (
  id            boolean primary key default true check (id),
  vapid_public  text not null check (vapid_public ~ '^[A-Za-z0-9_-]{80,100}$'),
  vapid_private text not null check (vapid_private ~ '^[A-Za-z0-9_-]{40,50}$'),
  subject       text not null default 'https://sgx-booking-ten.vercel.app' check (subject ~ '^(https://|mailto:)'),
  site_url      text not null default 'https://sgx-booking-ten.vercel.app' check (site_url ~ '^https://[^/\s]+$'),
  updated_at    timestamptz not null default now()
);

create table if not exists public.status_push_jobs (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null,
  booking_id uuid not null,
  kind       text not null check (kind in ('accepted', 'ready', 'cancelled', 'moved')),
  nonce      text not null check (nonce ~ '^[a-f0-9]{32}$'),
  status     text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed')),
  attempts   integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id) on delete cascade
);
create index if not exists status_push_jobs_pending on public.status_push_jobs (created_at) where status in ('pending', 'sending');

alter table public.push_config enable row level security;
alter table public.status_push_jobs enable row level security;
revoke all on public.push_config, public.status_push_jobs from public, anon, authenticated;
grant all on public.push_config, public.status_push_jobs to service_role;

-- ---------------------------------------------------------------------
-- Вызов функции сайта (асинхронно, после фиксации транзакции). Без pg_net или без ключей — ничего не делает.
-- ---------------------------------------------------------------------
create or replace function public.push_dispatch(p_job uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare j status_push_jobs; v_site text;
begin
  select site_url into v_site from push_config where id;
  select * into j from status_push_jobs where id = p_job;
  if v_site is null or j.id is null or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then return; end if;
  perform net.http_post(
    url := v_site || '/api/push',
    body := jsonb_build_object('job', j.id, 'nonce', j.nonce),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 15000);
exception when others then
  update status_push_jobs set last_error = 'dispatch: ' || left(sqlerrm, 200) where id = p_job;
end $$;

-- ---------------------------------------------------------------------
-- Триггер: смена статуса или времени записи → задание, если клиент подписан
-- ---------------------------------------------------------------------
create or replace function public.bookings_status_push() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_kind text; v_id uuid;
begin
  if new.anonymized_at is not null then return new; end if;
  if new.status is distinct from old.status then
    v_kind := case
      when new.status = 'accepted' then 'accepted'
      when new.status = 'ready' then 'ready'
      when new.status = 'cancelled' and new.cancelled_by = 'owner' then 'cancelled'
    end;
  elsif new.starts_at is distinct from old.starts_at and new.status in ('new', 'accepted') then
    v_kind := 'moved';
  end if;
  if v_kind is null then return new; end if;
  if not exists (select 1 from push_config where id) or not exists (select 1 from push_subscriptions where booking_id = new.id) then return new; end if;
  insert into status_push_jobs (tenant_id, booking_id, kind, nonce)
    values (new.tenant_id, new.id, v_kind, encode(gen_random_bytes(16), 'hex'))
    returning id into v_id;
  perform public.push_dispatch(v_id);
  return new;
exception when others then
  return new;  -- уведомление не должно мешать владельцу менять статус
end $$;

drop trigger if exists bookings_status_push on public.bookings;
create trigger bookings_status_push after update of status, starts_at on public.bookings
  for each row execute function public.bookings_status_push();

-- ---------------------------------------------------------------------
-- Для функции сайта: забрать задание по nonce и отметить результат
-- ---------------------------------------------------------------------
create or replace function public.push_job_claim(p_job uuid, p_nonce text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare j status_push_jobs; b bookings; t tenants; cfg push_config; v_title text; v_body text; v_when text; v_studio text;
begin
  update status_push_jobs set status = 'sending', attempts = attempts + 1, updated_at = now()
   where id = p_job and nonce = p_nonce and attempts < 6
     and (status = 'pending' or (status = 'sending' and updated_at < now() - interval '2 minutes'))
   returning * into j;
  if j.id is null then raise exception 'not_found' using errcode = 'P0002'; end if;
  select * into cfg from push_config where id;
  select * into b from bookings where id = j.booking_id;
  select * into t from tenants where id = j.tenant_id;
  v_studio := coalesce(t.profile ->> 'name', t.slug);
  v_when := to_char(b.starts_at at time zone t.timezone, 'DD.MM') || ' ('
         || (array['пн','вт','ср','чт','пт','сб','вс'])[extract(isodow from b.starts_at at time zone t.timezone)::int] || '), '
         || to_char(b.starts_at at time zone t.timezone, 'HH24:MI');
  case j.kind
    when 'accepted' then v_title := 'Машина принята — ' || v_studio; v_body := b.service_name || '. Сообщим, когда будет готова.';
    when 'ready' then v_title := 'Машина готова — ' || v_studio; v_body := b.service_name || '. Можно забирать: ' || coalesce(t.profile ->> 'address', '');
    when 'cancelled' then v_title := 'Запись отменена — ' || v_studio; v_body := b.service_name || ', ' || v_when || '. Телефон студии: ' || coalesce(t.profile ->> 'phone', '');
    else v_title := 'Запись перенесена — ' || v_studio; v_body := b.service_name || ': новое время ' || v_when || '.';
  end case;
  return jsonb_build_object(
    'vapidPublic', cfg.vapid_public, 'vapidPrivate', cfg.vapid_private, 'subject', cfg.subject,
    'payload', jsonb_build_object('title', v_title, 'body', v_body, 'url', '/s/' || t.slug || '/my/' || b.id),
    'topic', replace(b.id::text, '-', ''),
    'subscriptions', coalesce((select jsonb_agg(jsonb_build_object('endpoint', endpoint, 'p256dh', p256dh, 'auth', auth))
                                 from push_subscriptions where booking_id = b.id), '[]'::jsonb));
end $$;

create or replace function public.push_job_done(p_job uuid, p_nonce text, p_ok boolean, p_error text, p_gone text[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare j status_push_jobs;
begin
  select * into j from status_push_jobs where id = p_job and nonce = p_nonce and status = 'sending';
  if j.id is null then raise exception 'not_found' using errcode = 'P0002'; end if;
  -- подписки, которых больше нет у браузера (404/410), удаляем — только этой записи
  if p_gone is not null then delete from push_subscriptions where booking_id = j.booking_id and endpoint = any (p_gone); end if;
  update status_push_jobs set
    status = case when p_ok then 'sent' when attempts >= 5 then 'failed' else 'pending' end,
    last_error = case when p_ok then null else left(coalesce(p_error, ''), 300) end, updated_at = now()
   where id = j.id;
end $$;

-- повтор недошедших вызовов (pg_cron раз в минуту)
create or replace function public.push_retry() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
  update status_push_jobs set status = 'failed', last_error = coalesce(last_error, 'истекло время'), updated_at = now()
   where status in ('pending', 'sending') and created_at < now() - interval '30 minutes';
  for r in select id from status_push_jobs
            where (status = 'pending' and updated_at < now() - interval '45 seconds')
               or (status = 'sending' and updated_at < now() - interval '2 minutes')
            order by created_at limit 50 loop
    update status_push_jobs set updated_at = now() where id = r.id;
    perform public.push_dispatch(r.id);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Для клиента: публичный ключ, подписка и отписка по токену записи
-- ---------------------------------------------------------------------
create or replace function public.get_push_key() returns text
language sql stable security definer set search_path = public, extensions as $$
  select vapid_public from push_config where id;
$$;

create or replace function public.subscribe_status_push(p_booking uuid, p_token text, p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b bookings;
begin
  b := public.booking_by_token(p_booking, p_token);
  perform public.hit_rate_limit('push:' || b.id, 10, interval '1 hour');
  if p_endpoint !~ '^https://' or char_length(p_endpoint) > 1000 or char_length(coalesce(p_p256dh, '')) not between 40 and 200
     or char_length(coalesce(p_auth, '')) not between 10 and 100 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  if b.status in ('done', 'cancelled') or b.anonymized_at is not null then raise exception 'cannot_cancel_status' using errcode = 'P0001'; end if;
  insert into push_subscriptions (tenant_id, booking_id, endpoint, p256dh, auth)
  values (b.tenant_id, b.id, p_endpoint, p_p256dh, p_auth)
  on conflict (booking_id, endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

create or replace function public.unsubscribe_status_push(p_booking uuid, p_token text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b bookings;
begin
  b := public.booking_by_token(p_booking, p_token);
  delete from push_subscriptions where booking_id = b.id;
end $$;

-- «Моя запись»: признак подписки (pushOn)
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
    'reminder', coalesce(job, 'none'),
    'pushOn', exists (select 1 from push_subscriptions where booking_id = b.id),
    'pushReady', exists (select 1 from push_config where id));
end $$;

-- ---------- права ----------
revoke all on function public.push_dispatch(uuid) from public, anon, authenticated;
revoke all on function public.bookings_status_push() from public, anon, authenticated;
revoke all on function public.push_retry() from public, anon, authenticated;
revoke all on function public.push_job_claim(uuid, text) from public;
revoke all on function public.push_job_done(uuid, text, boolean, text, text[]) from public;
revoke all on function public.get_push_key() from public;
revoke all on function public.subscribe_status_push(uuid, text, text, text, text) from public;
revoke all on function public.unsubscribe_status_push(uuid, text) from public;
-- функция сайта ходит в базу с публичным ключом: право даёт только знание одноразового nonce
grant execute on function public.push_job_claim(uuid, text), public.push_job_done(uuid, text, boolean, text, text[]) to anon, service_role;
grant execute on function public.get_push_key(), public.subscribe_status_push(uuid, text, text, text, text),
  public.unsubscribe_status_push(uuid, text) to anon, authenticated;
grant execute on function public.push_dispatch(uuid), public.push_retry() to service_role;

-- ---------- повтор раз в минуту ----------
do $$ begin
  begin
    create extension if not exists pg_cron;
  exception when others then raise notice 'pg_cron недоступен: повтор уведомлений работать не будет (%)', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule(jobid) from cron.job where jobname = 'sgx-status-push';
    exception when others then null;
    end;
    perform cron.schedule('sgx-status-push', '* * * * *', 'select public.push_retry()');
  end if;
end $$;
