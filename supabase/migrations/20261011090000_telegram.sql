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
