-- Web Push владельцу: подписка устройства в кабинете, уведомление о новой записи клиента и об отмене клиентом,
-- права и изоляция студий. pg_net подменён заглушкой (supabase_shim.sql).
begin;
\ir 00_helpers.sql

do $$
declare d date := pg_temp.open_day('graphite', 9, '12:00'); b uuid; job record; j jsonb; n int;
        ep constant text := 'https://web.push.apple.com/owner-device-1';
        p256 constant text := 'BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM';
        auth_k constant text := 'tBHItJI5svbpez7KI4CCXg';
begin
  insert into public.push_config (vapid_public, vapid_private) values (
    'BOrX1gzZbAGuOwuY4vmAiiFfDtwhYR1HKiZGmUlZxQMZ6pyKq2A5ZJsPpv8vQ_QDz5bxyfGX4z0pR7S9oLqBh3c', 'ZV2q7S3LzHJAk2wmlHkQ9mQyY5x3H7ScsoXk6nJrA2Q');

  -- ---------- права ----------
  set local role anon;
  perform pg_temp.throws(format($q$select public.owner_push_subscribe(%L, %L, %L, %L)$q$, pg_temp.tid('graphite'), ep, p256, auth_k), 'permission denied', 'anon не подписывает устройства владельца');
  perform pg_temp.throws($q$select count(*) from public.owner_push_subscriptions$q$, 'permission denied', 'anon не видит устройства владельцев');
  reset role;
  perform pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
  perform pg_temp.throws(format($q$select public.owner_push_subscribe(%L, %L, %L, %L)$q$, pg_temp.tid('graphite'), ep, p256, auth_k), 'forbidden', 'владелец другой студии не подписывается на чужие записи');
  perform pg_temp.throws(format($q$select public.owner_push_state(%L, null)$q$, pg_temp.tid('graphite')), 'forbidden', 'и не видит их состояние');

  -- ---------- владелец подписывает устройство ----------
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform pg_temp.throws(format($q$select public.owner_push_subscribe(%L, 'http://x', %L, %L)$q$, pg_temp.tid('graphite'), p256, auth_k), 'bad_request', 'адрес подписки проверяется');
  perform public.owner_push_subscribe(pg_temp.tid('graphite'), ep, p256, auth_k);
  perform public.owner_push_subscribe(pg_temp.tid('graphite'), ep, p256, auth_k);
  j := public.owner_push_state(pg_temp.tid('graphite'), ep);
  perform pg_temp.ok((j ->> 'ready')::boolean and (j ->> 'thisDevice')::boolean and (j ->> 'devices')::int = 1, 'устройство подписано один раз, кабинет это видит');
  perform pg_temp.as_admin();

  -- ---------- новая запись клиента → задание владельцу ----------
  delete from net.test_requests;
  b := pg_temp.book('graphite', 'wash', d, '12:00', 'OWN1');
  select * into job from public.status_push_jobs where booking_id = b and audience = 'owner' and kind = 'owner_new';
  perform pg_temp.ok(job.id is not null, 'новая запись клиента создала задание владельцу');
  perform pg_temp.ok(exists (select 1 from net.test_requests where url like '%/api/push' and body ->> 'job' = job.id::text), 'база вызвала функцию сайта');
  set local role anon;
  j := public.push_job_claim(job.id, job.nonce);
  reset role;
  perform pg_temp.ok(j #>> '{payload,title}' = 'Новая запись — GRAPHITE Detailing'
                     and position('Клиент OWN1' in j #>> '{payload,body}') > 0 and position('12:00' in j #>> '{payload,body}') > 0
                     and position('Машина OWN1' in j #>> '{payload,body}') > 0, 'в уведомлении клиент, время и машина');
  perform pg_temp.ok(j #>> '{payload,url}' = '/s/graphite/owner/?d=' || d || '&b=' || b, 'нажатие открывает запись в кабинете');
  perform pg_temp.ok(jsonb_array_length(j -> 'subscriptions') = 1 and j #>> '{subscriptions,0,endpoint}' = ep, 'отправка идёт на устройство владельца');
  set local role anon;
  perform public.push_job_done(job.id, job.nonce, true, null, null);
  reset role;

  -- запись владельцем — без уведомления; запись в другой студии — не этому владельцу
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform public.owner_create_booking(pg_temp.tid('graphite'), pg_temp.svc('graphite', 'wash'), d, '15:00', 'Звонок', '+375 29 222-33-44', 'Ауди', gen_random_uuid());
  perform pg_temp.as_admin();
  perform pg_temp.ok(not exists (select 1 from public.status_push_jobs j2 join public.bookings bb on bb.id = j2.booking_id where bb.client_name = 'Звонок'), 'свою запись владелец не получает уведомлением');
  perform pg_temp.book('protector', (select key from public.services where tenant_id = pg_temp.tid('protector') and active order by sort limit 1),
                       pg_temp.open_day('protector', 9, '12:00'), '12:00', 'OWN-OTHER');
  perform pg_temp.ok(not exists (select 1 from public.status_push_jobs where tenant_id = pg_temp.tid('protector') and audience = 'owner'), 'записи другой студии не приходят');

  -- ---------- отмена клиентом → владельцу ----------
  set local role anon;
  perform public.cancel_my_booking(b, rpad('tok-OWN1', 40, 'x'));
  reset role;
  select * into job from public.status_push_jobs where booking_id = b and kind = 'owner_cancelled';
  set local role anon;
  j := public.push_job_claim(job.id, job.nonce);
  -- исчезнувшее устройство удаляется
  perform public.push_job_done(job.id, job.nonce, false, '410 Gone', array[ep]);
  reset role;
  perform pg_temp.ok(j #>> '{payload,title}' like 'Клиент отменил запись%' and position('свободно' in j #>> '{payload,body}') > 0, 'отмена клиентом приходит владельцу');
  perform pg_temp.ok(not exists (select 1 from public.owner_push_subscriptions where endpoint = ep), 'исчезнувшее устройство владельца удалено');

  -- ---------- отписка и удаление владельца из студии ----------
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform public.owner_push_subscribe(pg_temp.tid('graphite'), ep, p256, auth_k);
  perform public.owner_push_unsubscribe(pg_temp.tid('graphite'), ep);
  perform pg_temp.ok(not (public.owner_push_state(pg_temp.tid('graphite'), ep) ->> 'thisDevice')::boolean, 'владелец отключает уведомления на устройстве');
  perform public.owner_push_subscribe(pg_temp.tid('graphite'), ep, p256, auth_k);
  perform pg_temp.as_admin();
  delete from public.tenant_members where tenant_id = pg_temp.tid('graphite') and user_id = 'a0000000-0000-0000-0000-00000000000a';
  perform pg_temp.ok(not exists (select 1 from public.owner_push_subscriptions where tenant_id = pg_temp.tid('graphite')), 'удалённый из студии владелец больше не получает её записи');

  -- без подписок заданий нет
  delete from net.test_requests;
  b := pg_temp.book('graphite', 'wash', d, '14:00', 'OWN2');
  select count(*) into n from public.status_push_jobs where booking_id = b;
  perform pg_temp.ok(n = 0 and not exists (select 1 from net.test_requests where url like '%/api/push'), 'нет устройств — нет заданий');
end $$;

rollback;
