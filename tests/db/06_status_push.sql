-- Web Push клиенту при смене статуса: подписка по токену, задание с одноразовым nonce, вызов функции сайта,
-- выдача задания только по верному nonce, повтор и права. pg_net подменён заглушкой (supabase_shim.sql).
begin;
\ir 00_helpers.sql

do $$
declare d date := pg_temp.open_day('graphite', 9, '12:00'); b uuid; b2 uuid; tok text := rpad('tok-PUSH1', 40, 'x');
        j jsonb; job record; n int;
        ep constant text := 'https://fcm.googleapis.com/fcm/send/abc123';
        p256 constant text := 'BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM';
        auth_k constant text := 'tBHItJI5svbpez7KI4CCXg';
begin
  b := pg_temp.book('graphite', 'wash', d, '12:00', 'PUSH1');

  -- ---------- до настройки ключей ----------
  set local role anon;
  perform pg_temp.ok(public.get_push_key() is null, 'без ключей публичного ключа нет');
  perform pg_temp.ok(not (public.get_my_booking(b, tok) ->> 'pushReady')::boolean, 'клиент видит, что уведомления не настроены');
  perform pg_temp.throws($q$select count(*) from public.push_config$q$, 'permission denied', 'anon не читает ключи VAPID');
  perform pg_temp.throws($q$select count(*) from public.status_push_jobs$q$, 'permission denied', 'anon не видит задания');
  perform pg_temp.throws($q$select public.push_retry()$q$, 'permission denied', 'anon не запускает повтор');
  reset role;

  insert into public.push_config (vapid_public, vapid_private) values (
    'BOrX1gzZbAGuOwuY4vmAiiFfDtwhYR1HKiZGmUlZxQMZ6pyKq2A5ZJsPpv8vQ_QDz5bxyfGX4z0pR7S9oLqBh3c',
    'ZV2q7S3LzHJAk2wmlHkQ9mQyY5x3H7ScsoXk6nJrA2Q');

  -- ---------- подписка клиента ----------
  set local role anon;
  perform pg_temp.ok(length(public.get_push_key()) = 87, 'публичный ключ выдаётся клиенту');
  perform pg_temp.throws(format($q$select public.subscribe_status_push(%L, 'чужой-токен-xxxxxxxxxxxxxxxxxxxxxxxxxxxxx', %L, %L, %L)$q$, b, ep, p256, auth_k), 'not_found', 'без токена записи подписаться нельзя');
  perform pg_temp.throws(format($q$select public.subscribe_status_push(%L, %L, 'http://evil', %L, %L)$q$, b, tok, p256, auth_k), 'bad_request', 'адрес подписки проверяется');
  perform public.subscribe_status_push(b, tok, ep, p256, auth_k);
  perform public.subscribe_status_push(b, tok, ep, p256, auth_k);
  perform pg_temp.ok((public.get_my_booking(b, tok) ->> 'pushOn')::boolean, 'клиент видит, что уведомления включены');
  reset role;
  perform pg_temp.ok((select count(*) from public.push_subscriptions where booking_id = b) = 1, 'повторная подписка не дублируется');

  -- ---------- владелец принимает машину → задание и вызов сайта ----------
  delete from net.test_requests;
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform public.owner_set_status(b, 'accepted');
  perform pg_temp.as_admin();
  select * into job from public.status_push_jobs where booking_id = b and kind = 'accepted';
  perform pg_temp.ok(job.id is not null and job.status = 'pending', 'смена статуса создала задание');
  perform pg_temp.ok(exists (select 1 from net.test_requests where url = 'https://sgx-booking-ten.vercel.app/api/push'
                       and body = jsonb_build_object('job', job.id, 'nonce', job.nonce)), 'база вызвала функцию сайта с номером задания и nonce');

  -- ---------- функция сайта забирает задание ----------
  set local role anon;
  perform pg_temp.throws(format($q$select public.push_job_claim(%L, 'ffffffffffffffffffffffffffffffff')$q$, job.id), 'not_found', 'без верного nonce задание не выдаётся');
  j := public.push_job_claim(job.id, job.nonce);
  perform pg_temp.ok(j #>> '{payload,title}' = 'Машина принята — GRAPHITE Detailing' and j #>> '{payload,url}' = '/s/graphite/my/' || b, 'текст и ссылка уведомления');
  perform pg_temp.ok(jsonb_array_length(j -> 'subscriptions') = 1 and j #>> '{subscriptions,0,endpoint}' = ep and length(j ->> 'vapidPrivate') = 43, 'функция получает подписку и ключи');
  perform pg_temp.throws(format($q$select public.push_job_claim(%L, %L)$q$, job.id, job.nonce), 'not_found', 'задание не выдаётся второй раз');
  perform public.push_job_done(job.id, job.nonce, true, null, null);
  perform pg_temp.throws(format($q$select public.push_job_done(%L, %L, true, null, null)$q$, job.id, job.nonce), 'not_found', 'результат отмечается один раз');
  reset role;
  perform pg_temp.ok((select status from public.status_push_jobs where id = job.id) = 'sent', 'задание отмечено отправленным');

  -- ---------- готово, неудача, повтор, исчезнувшая подписка ----------
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform public.owner_set_status(b, 'ready');
  perform pg_temp.as_admin();
  select * into job from public.status_push_jobs where booking_id = b and kind = 'ready';
  set local role anon;
  j := public.push_job_claim(job.id, job.nonce);
  perform pg_temp.ok(j #>> '{payload,title}' = 'Машина готова — GRAPHITE Detailing' and position('Можно забирать' in j #>> '{payload,body}') > 0, 'уведомление «машина готова» с адресом');
  perform public.push_job_done(job.id, job.nonce, false, 'timeout', null);
  reset role;
  perform pg_temp.ok((select status from public.status_push_jobs where id = job.id) = 'pending', 'после сбоя задание снова в очереди');
  update public.status_push_jobs set updated_at = now() - interval '1 minute' where id = job.id;
  delete from net.test_requests;
  perform public.push_retry();
  perform pg_temp.ok(exists (select 1 from net.test_requests where body ->> 'job' = job.id::text), 'повтор вызывает сайт ещё раз');
  set local role anon;
  j := public.push_job_claim(job.id, job.nonce);
  perform public.push_job_done(job.id, job.nonce, false, '410 Gone', array[ep]);
  reset role;
  perform pg_temp.ok(not exists (select 1 from public.push_subscriptions where booking_id = b), 'подписка, которой больше нет у браузера, удалена');

  -- ---------- без подписки заданий нет; клиентская отмена и «новая» не уведомляют ----------
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform public.owner_set_status(b, 'done');
  perform pg_temp.as_admin();
  perform pg_temp.ok(not exists (select 1 from public.status_push_jobs where booking_id = b and kind not in ('accepted', 'ready')), 'без подписки и для «выполнена» заданий нет');

  b2 := pg_temp.book('graphite', 'wash', d, '14:00', 'PUSH2');
  set local role anon;
  perform public.subscribe_status_push(b2, rpad('tok-PUSH2', 40, 'x'), ep || '2', p256, auth_k);
  reset role;
  -- перенос владельцем → «перенесена»
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform public.owner_move_booking(b2, d, '16:00');
  perform pg_temp.as_admin();
  select * into job from public.status_push_jobs where booking_id = b2 and kind = 'moved';
  set local role anon;
  j := public.push_job_claim(job.id, job.nonce);
  reset role;
  perform pg_temp.ok(j #>> '{payload,title}' like 'Запись перенесена%' and position('16:00' in j #>> '{payload,body}') > 0, 'перенос: новое время в уведомлении');
  -- отмена самим клиентом — без уведомления
  set local role anon;
  perform public.cancel_my_booking(b2, rpad('tok-PUSH2', 40, 'x'));
  reset role;
  perform pg_temp.ok(not exists (select 1 from public.status_push_jobs where booking_id = b2 and kind = 'cancelled'), 'клиенту не шлём уведомление о его собственной отмене');

  -- отписка
  set local role anon;
  perform public.unsubscribe_status_push(b2, rpad('tok-PUSH2', 40, 'x'));
  reset role;
  perform pg_temp.ok(not exists (select 1 from public.push_subscriptions where booking_id = b2), 'клиент отключает уведомления');

  -- старые задания закрываются
  update public.status_push_jobs set created_at = now() - interval '1 hour' where status = 'pending';
  perform public.push_retry();
  select count(*) into n from public.status_push_jobs where status in ('pending', 'sending') and created_at < now() - interval '30 minutes';
  perform pg_temp.ok(n = 0, 'зависшие задания закрываются через 30 минут');
end $$;

rollback;
