-- =====================================================================
-- 19. Web Push владельцу: новая запись клиента и отмена клиентом — уведомление на телефон или компьютер,
--     даже когда кабинет закрыт. Работает на той же отправке, что и уведомления клиентам (18): задание
--     с одноразовым nonce → pg_net → /api/push. Нужен выполненный файл 18 (push_config с ключами).
-- =====================================================================

create table if not exists public.owner_push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  user_id    uuid not null,
  endpoint   text not null check (endpoint ~ '^https://' and char_length(endpoint) <= 1000),
  p256dh     text not null check (char_length(p256dh) between 40 and 200),
  auth       text not null check (char_length(auth) between 10 and 100),
  created_at timestamptz not null default now(),
  unique (tenant_id, endpoint)
);
alter table public.owner_push_subscriptions enable row level security;
revoke all on public.owner_push_subscriptions from public, anon, authenticated;
grant all on public.owner_push_subscriptions to service_role;

-- задания: кому (клиенту или владельцу) и новые виды
alter table public.status_push_jobs add column if not exists audience text not null default 'client';
alter table public.status_push_jobs drop constraint if exists status_push_jobs_audience_check;
alter table public.status_push_jobs add constraint status_push_jobs_audience_check check (audience in ('client', 'owner'));
alter table public.status_push_jobs drop constraint if exists status_push_jobs_kind_check;
alter table public.status_push_jobs add constraint status_push_jobs_kind_check
  check (kind in ('accepted', 'ready', 'cancelled', 'moved', 'owner_new', 'owner_cancelled'));

-- ---------------------------------------------------------------------
-- Триггер: новая запись клиента, отмена клиентом → задание владельцу
-- ---------------------------------------------------------------------
create or replace function public.bookings_owner_push() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_kind text; v_id uuid;
begin
  if tg_op = 'INSERT' and new.source = 'client' then
    v_kind := 'owner_new';
  elsif tg_op = 'UPDATE' and new.status = 'cancelled' and old.status is distinct from 'cancelled' and new.cancelled_by = 'client' then
    v_kind := 'owner_cancelled';
  end if;
  if v_kind is null then return new; end if;
  if not exists (select 1 from push_config where id) or not exists (select 1 from owner_push_subscriptions where tenant_id = new.tenant_id) then
    return new;
  end if;
  insert into status_push_jobs (tenant_id, booking_id, kind, audience, nonce)
    values (new.tenant_id, new.id, v_kind, 'owner', encode(gen_random_bytes(16), 'hex'))
    returning id into v_id;
  perform public.push_dispatch(v_id);
  return new;
exception when others then
  return new;  -- уведомление не должно мешать записи клиента
end $$;

drop trigger if exists bookings_owner_push on public.bookings;
create trigger bookings_owner_push after insert or update of status on public.bookings
  for each row execute function public.bookings_owner_push();

-- ---------------------------------------------------------------------
-- Выдача задания функции сайта: для владельца — его подписки и ссылка в кабинет
-- ---------------------------------------------------------------------
create or replace function public.push_job_claim(p_job uuid, p_nonce text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare j status_push_jobs; b bookings; t tenants; cfg push_config; v_title text; v_body text; v_when text; v_studio text; v_url text; v_subs jsonb;
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
  if j.audience = 'owner' then
    v_url := '/s/' || t.slug || '/owner/?d=' || to_char(b.starts_at at time zone t.timezone, 'YYYY-MM-DD') || '&b=' || b.id;
    if j.kind = 'owner_cancelled' then
      v_title := 'Клиент отменил запись — ' || v_studio;
      v_body := b.client_name || ' · ' || b.service_name || ' · ' || v_when || '. Время снова свободно.';
    else
      v_title := 'Новая запись — ' || v_studio;
      v_body := b.client_name || ' · ' || b.service_name || ' · ' || v_when || ' · ' || b.client_car;
    end if;
    v_subs := coalesce((select jsonb_agg(jsonb_build_object('endpoint', endpoint, 'p256dh', p256dh, 'auth', auth))
                          from owner_push_subscriptions where tenant_id = t.id), '[]'::jsonb);
  else
    v_url := '/s/' || t.slug || '/my/' || b.id;
    case j.kind
      when 'accepted' then v_title := 'Машина принята — ' || v_studio; v_body := b.service_name || '. Сообщим, когда будет готова.';
      when 'ready' then v_title := 'Машина готова — ' || v_studio; v_body := b.service_name || '. Можно забирать: ' || coalesce(t.profile ->> 'address', '');
      when 'cancelled' then v_title := 'Запись отменена — ' || v_studio; v_body := b.service_name || ', ' || v_when || '. Телефон студии: ' || coalesce(t.profile ->> 'phone', '');
      else v_title := 'Запись перенесена — ' || v_studio; v_body := b.service_name || ': новое время ' || v_when || '.';
    end case;
    v_subs := coalesce((select jsonb_agg(jsonb_build_object('endpoint', endpoint, 'p256dh', p256dh, 'auth', auth))
                          from push_subscriptions where booking_id = b.id), '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'vapidPublic', cfg.vapid_public, 'vapidPrivate', cfg.vapid_private, 'subject', cfg.subject,
    'payload', jsonb_build_object('title', v_title, 'body', v_body, 'url', v_url),
    -- у владельца каждая запись — отдельное уведомление, у клиента новое заменяет старое по той же записи
    'topic', replace(j.id::text, '-', ''),
    'subscriptions', v_subs);
end $$;

create or replace function public.push_job_done(p_job uuid, p_nonce text, p_ok boolean, p_error text, p_gone text[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare j status_push_jobs;
begin
  select * into j from status_push_jobs where id = p_job and nonce = p_nonce and status = 'sending';
  if j.id is null then raise exception 'not_found' using errcode = 'P0002'; end if;
  if p_gone is not null then
    if j.audience = 'owner' then delete from owner_push_subscriptions where tenant_id = j.tenant_id and endpoint = any (p_gone);
    else delete from push_subscriptions where booking_id = j.booking_id and endpoint = any (p_gone);
    end if;
  end if;
  update status_push_jobs set
    status = case when p_ok then 'sent' when attempts >= 5 then 'failed' else 'pending' end,
    last_error = case when p_ok then null else left(coalesce(p_error, ''), 300) end, updated_at = now()
   where id = j.id;
end $$;

-- ---------------------------------------------------------------------
-- Владелец: подписка этого устройства, отписка, состояние
-- ---------------------------------------------------------------------
create or replace function public.owner_push_subscribe(p_tenant uuid, p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.require_member(p_tenant);
  if coalesce(p_endpoint, '') !~ '^https://' or char_length(p_endpoint) > 1000 or char_length(coalesce(p_p256dh, '')) not between 40 and 200
     or char_length(coalesce(p_auth, '')) not between 10 and 100 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  if (select count(*) from owner_push_subscriptions where tenant_id = p_tenant) >= 20 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  insert into owner_push_subscriptions (tenant_id, user_id, endpoint, p256dh, auth)
  values (p_tenant, auth.uid(), p_endpoint, p_p256dh, p_auth)
  on conflict (tenant_id, endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

create or replace function public.owner_push_unsubscribe(p_tenant uuid, p_endpoint text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.require_member(p_tenant);
  delete from owner_push_subscriptions where tenant_id = p_tenant and endpoint = p_endpoint;
end $$;

create or replace function public.owner_push_state(p_tenant uuid, p_endpoint text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.require_member(p_tenant);
  return jsonb_build_object(
    'ready', exists (select 1 from push_config where id),
    'thisDevice', p_endpoint is not null and exists (select 1 from owner_push_subscriptions where tenant_id = p_tenant and endpoint = p_endpoint),
    'devices', (select count(*) from owner_push_subscriptions where tenant_id = p_tenant));
end $$;

-- при удалении владельца из студии его устройства больше не получают её записи
create or replace function public.owner_push_member_gone() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from owner_push_subscriptions where tenant_id = old.tenant_id and user_id = old.user_id;
  return old;
end $$;
drop trigger if exists tenant_members_push_gone on public.tenant_members;
create trigger tenant_members_push_gone after delete on public.tenant_members
  for each row execute function public.owner_push_member_gone();

revoke all on function public.bookings_owner_push() from public, anon, authenticated;
revoke all on function public.owner_push_member_gone() from public, anon, authenticated;
revoke all on function public.owner_push_subscribe(uuid, text, text, text) from public, anon;
revoke all on function public.owner_push_unsubscribe(uuid, text) from public, anon;
revoke all on function public.owner_push_state(uuid, text) from public, anon;
grant execute on function public.owner_push_subscribe(uuid, text, text, text), public.owner_push_unsubscribe(uuid, text),
  public.owner_push_state(uuid, text) to authenticated;
revoke all on function public.push_job_claim(uuid, text) from public;
revoke all on function public.push_job_done(uuid, text, boolean, text, text[]) from public;
grant execute on function public.push_job_claim(uuid, text), public.push_job_done(uuid, text, boolean, text, text[]) to anon, service_role;
