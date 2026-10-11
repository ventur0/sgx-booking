-- Уведомления в Telegram: настройка бота продавцом, привязка чата владельцем по одноразовому коду,
-- сообщение о новой записи клиента и об отмене клиентом, права. pg_net подменён заглушкой (supabase_shim.sql).
begin;
\ir 00_helpers.sql

insert into auth.users (id, email) values ('d0000000-0000-0000-0000-00000000000d', 'seller@test') on conflict do nothing;
insert into public.platform_admins (user_id) values ('d0000000-0000-0000-0000-00000000000d') on conflict do nothing;

do $$
declare j jsonb; v_url text; code text; d date := pg_temp.open_day('graphite', 9, '12:00'); b uuid; n int; req bigint; msg jsonb;
        tok constant text := '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw';
begin
  -- ---------- посторонние не трогают настройки и таблицы ----------
  set local role anon;
  perform pg_temp.throws($q$select public.admin_tg_get()$q$, 'permission denied', 'anon не видит настройки бота');
  perform pg_temp.throws($q$select public.owner_tg_link(gen_random_uuid())$q$, 'permission denied', 'anon не подключает Telegram');
  perform pg_temp.throws($q$select count(*) from public.tg_config$q$, 'permission denied', 'anon не читает токен бота');
  perform pg_temp.throws($q$select count(*) from public.tg_chats$q$, 'permission denied', 'anon не видит чаты');
  perform pg_temp.throws($q$select public.tg_tick()$q$, 'permission denied', 'anon не запускает опрос бота');
  reset role;

  -- ---------- до настройки бота ----------
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform pg_temp.throws(format($q$select public.owner_tg_link(%L)$q$, pg_temp.tid('graphite')), 'telegram_not_configured', 'без бота подключить нельзя');
  perform pg_temp.throws($q$select public.admin_tg_set('1:x', 'bot', null)$q$, 'forbidden', 'владелец не настраивает бота');
  perform pg_temp.throws($q$select count(*) from public.tg_config$q$, 'permission denied', 'владелец не читает токен бота');
  perform pg_temp.as_admin();

  -- ---------- продавец настраивает бота ----------
  perform pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
  perform pg_temp.throws($q$select public.admin_tg_set('не токен', 'sgx_bot', null)$q$, 'bad_bot_token', 'токен проверяется');
  perform pg_temp.throws(format($q$select public.admin_tg_set(%L, 'a b', null)$q$, tok), 'bad_bot', 'имя бота проверяется');
  perform public.admin_tg_set(tok, 'https://t.me/@Sgx_Booking_bot', 'https://sgx-booking-ten.vercel.app/');
  j := public.admin_tg_get();
  perform pg_temp.ok((j ->> 'configured')::boolean and j ->> 'bot' = 'Sgx_Booking_bot' and j ->> 'siteUrl' = 'https://sgx-booking-ten.vercel.app', 'бот сохранён, ссылка t.me/@ очищена');
  perform pg_temp.ok(not (j ? 'token') and position(tok in j::text) = 0, 'токен не возвращается в браузер');
  perform pg_temp.as_admin();
  perform pg_temp.ok(exists (select 1 from net.test_requests where url like '%/deleteWebhook'), 'при настройке снимается вебхук');

  -- ---------- владелец получает ссылку ----------
  perform pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
  perform pg_temp.throws(format($q$select public.owner_tg_link(%L)$q$, pg_temp.tid('graphite')), 'forbidden', 'чужая студия — нельзя');
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  j := public.owner_tg_link(pg_temp.tid('graphite'));
  v_url := j ->> 'url';
  code := substring(v_url from 'start=([a-f0-9]{16})$');
  perform pg_temp.ok(v_url like 'https://t.me/Sgx_Booking_bot?start=%' and code is not null, 'ссылка на бота с одноразовым кодом');
  perform pg_temp.as_admin();

  -- ---------- опрос бота: первый тик отправляет getUpdates ----------
  perform public.tg_tick();
  select pending_req into req from public.tg_config;
  perform pg_temp.ok(req is not null and exists (select 1 from net.test_requests where id = req and url like '%/getUpdates'), 'тик запрашивает getUpdates');

  -- ответ: /start с кодом и /start с чужим кодом из другого чата
  insert into net._http_response (id, status_code, content) values (req, 200, jsonb_build_object('ok', true, 'result', jsonb_build_array(
    jsonb_build_object('update_id', 500, 'message', jsonb_build_object('chat', jsonb_build_object('id', 777001, 'first_name', 'Иван'), 'text', '/start ' || code)),
    jsonb_build_object('update_id', 501, 'message', jsonb_build_object('chat', jsonb_build_object('id', 777002), 'text', '/start ffffffffffffffff'))))::text);
  perform public.tg_tick();
  perform pg_temp.ok(exists (select 1 from public.tg_chats where chat_id = 777001 and tenant_id = pg_temp.tid('graphite') and title = 'Иван'), 'чат подключён к студии по коду');
  perform pg_temp.ok(not exists (select 1 from public.tg_chats where chat_id = 777002), 'чужой код ничего не подключает');
  perform pg_temp.ok((select "offset" from public.tg_config) = 502, 'смещение getUpdates продвинулось');
  perform pg_temp.ok(exists (select 1 from net.test_requests where method = 'POST' and body ->> 'chat_id' = '777001' and body ->> 'text' like '✅ Готово!%'), 'бот подтвердил подключение');

  -- повторное использование кода не работает
  perform public.tg_handle_updates(jsonb_build_array(jsonb_build_object('update_id', 502, 'message',
    jsonb_build_object('chat', jsonb_build_object('id', 777003), 'text', '/start ' || code))));
  perform pg_temp.ok(not exists (select 1 from public.tg_chats where chat_id = 777003), 'код одноразовый');

  -- ---------- новая запись клиента → сообщение ----------
  delete from net.test_requests;
  b := pg_temp.book('graphite', 'wash', d, '12:00', 'TG1');
  select r.body into msg from net.test_requests r where r.method = 'POST' and r.url like '%/sendMessage' order by r.id desc limit 1;
  perform pg_temp.ok(msg ->> 'chat_id' = '777001', 'сообщение ушло в подключённый чат');
  perform pg_temp.ok(msg ->> 'text' like '🆕 Новая запись — %' and position('Клиент TG1' in msg ->> 'text') > 0 and position('Машина TG1' in msg ->> 'text') > 0
                     and position('+375291112233' in msg ->> 'text') > 0 and position(' BYN' in msg ->> 'text') > 0, 'в сообщении клиент, телефон, машина и цена');
  perform pg_temp.ok(position('/s/graphite/owner/?d=' || d::text || '&b=' || b::text in msg ->> 'text') > 0, 'ссылка ведёт на запись в кабинете');
  perform pg_temp.ok(position('12:00' in msg ->> 'text') > 0, 'время в часовом поясе студии');

  -- запись владельцем — без уведомления; запись в другой студии — не в этот чат
  delete from net.test_requests;
  perform pg_temp.book('protector', (select key from public.services where tenant_id = pg_temp.tid('protector') and active order by sort limit 1),
                       pg_temp.open_day('protector', 9, '12:00'), '12:00', 'TG-OTHER');
  perform pg_temp.ok(not exists (select 1 from net.test_requests where body ->> 'chat_id' = '777001'), 'записи другой студии сюда не приходят');

  -- ---------- отмена клиентом → сообщение ----------
  delete from net.test_requests;
  set local role anon;
  perform public.cancel_my_booking(b, rpad('tok-TG1', 40, 'x'));
  reset role;
  select count(*) into n from net.test_requests where body ->> 'chat_id' = '777001' and body ->> 'text' like '❌ Клиент отменил запись%';
  perform pg_temp.ok(n = 1, 'отмена клиентом приходит одним сообщением');

  -- ---------- владелец видит и отключает чат ----------
  perform pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
  perform pg_temp.throws(format($q$select public.owner_tg_list(%L)$q$, pg_temp.tid('graphite')), 'forbidden', 'чужой владелец не видит чаты студии');
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  j := public.owner_tg_list(pg_temp.tid('graphite'));
  perform pg_temp.ok(jsonb_array_length(j -> 'chats') = 1 and j #>> '{chats,0,title}' = 'Иван' and not (j::text like '%777001%'), 'владелец видит свой чат (без номера чата)');
  perform public.owner_tg_remove(pg_temp.tid('graphite'), (j #>> '{chats,0,id}')::uuid);
  perform pg_temp.as_admin();
  perform pg_temp.ok(not exists (select 1 from public.tg_chats where chat_id = 777001), 'владелец отключил чат');

  -- /stop из Telegram
  insert into public.tg_chats (tenant_id, chat_id, title) values (pg_temp.tid('graphite'), 777009, 'X');
  perform public.tg_handle_updates(jsonb_build_array(jsonb_build_object('update_id', 600, 'message', jsonb_build_object('chat', jsonb_build_object('id', 777009), 'text', '/stop'))));
  perform pg_temp.ok(not exists (select 1 from public.tg_chats where chat_id = 777009), '/stop отключает чат');

  -- без подключённых чатов запись создаётся без запросов
  delete from net.test_requests;
  perform pg_temp.book('graphite', 'wash', d, '14:00', 'TG2');
  perform pg_temp.ok(not exists (select 1 from net.test_requests where url like '%/sendMessage'), 'нет чатов — нет сообщений');

  -- битый ответ не зацикливает опрос
  perform public.tg_tick();
  select pending_req into req from public.tg_config;
  insert into net._http_response (id, status_code, content) values (req, 200, '{"ok":true,"result":[{"update_id":700,"message":{"chat":{"id":"не число"},"text":"x"}}]}');
  perform public.tg_tick();
  perform pg_temp.ok((select "offset" from public.tg_config) = 701 and (select last_error from public.tg_config) like 'обработка:%', 'битое сообщение пропускается, опрос идёт дальше');
end $$;

rollback;
