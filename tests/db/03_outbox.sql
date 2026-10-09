-- Outbox напоминаний: preview не шлёт, live ставит задание за сутки, перенос и отмена
-- обновляют задания, дедупликация, аренда (lease) при выдаче воркеру.
begin;
\ir 00_helpers.sql

do $$
declare d date := pg_temp.open_day('graphite', 7, '12:00'); b uuid; demo uuid; st text; n int; j1 uuid; tok text;
begin
  -- preview: подписка есть, но задание помечено skipped
  demo := pg_temp.book('graphite', 'wash', d, '12:00', 'PRE');
  -- push отключён (миграция 101400): подписку сохраняет только сервер; для клиента функция закрыта
  st := public.save_push_subscription(demo, rpad('tok-PRE', 40, 'x'), 'https://push.example/pre', 'k', 'a');
  perform pg_temp.throws(format($q$set local role anon; select public.save_push_subscription(%L, 'x', 'https://p', 'k', 'a')$q$, demo), 'permission denied', 'клиент больше не сохраняет push-подписки');
  reset role;
  perform pg_temp.ok(st = 'skipped', 'в режиме preview реальное уведомление не планируется');
  perform pg_temp.ok((select is_demo from public.bookings where id = demo), 'записи в preview помечены как demo');

  -- переводим студию в live (нужны данные оператора ПД)
  perform pg_temp.throws($q$update public.tenants set mode = 'live' where slug = 'graphite'$q$, 'config_invalid', 'live без данных оператора ПД запрещён');
  update public.tenants set mode = 'live',
    profile = profile || '{"legal": {"operator": "ИП Тест", "unp": "191234567", "legalAddress": "Минск", "email": "a@b.by", "retentionDays": 365}}'::jsonb
   where slug = 'graphite';

  b := pg_temp.book('graphite', 'wash', d, '14:00', 'LIVE');
  perform pg_temp.ok(not (select is_demo from public.bookings where id = b), 'в live запись настоящая');
  perform pg_temp.ok(not exists (select 1 from public.notification_jobs where booking_id = b), 'без подписки задания нет (ICS остаётся единственным каналом)');
  tok := rpad('tok-LIVE', 40, 'x');

  st := public.save_push_subscription(b, tok, 'https://push.example/live', 'p256', 'auth');
  st := public.save_push_subscription(b, tok, 'https://push.example/live', 'p256', 'auth');

  perform pg_temp.ok(st = 'pending', 'после подписки задание pending');
  perform pg_temp.ok((select count(*) from public.notification_jobs where booking_id = b) = 1, 'повторная подписка не дублирует задание');
  perform pg_temp.ok((select run_at = b2.starts_at - interval '1 day' from public.notification_jobs j join public.bookings b2 on b2.id = j.booking_id where j.booking_id = b),
                     'напоминание запланировано ровно за сутки');

  -- перенос: старое задание отменено, новое на новое время
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform public.owner_move_booking(b, d, '16:00');
  perform pg_temp.as_admin();
  perform pg_temp.ok((select count(*) from public.notification_jobs where booking_id = b and status = 'cancelled') = 1
                 and (select count(*) from public.notification_jobs where booking_id = b and status = 'pending') = 1, 'перенос: старое задание отменено, новое создано');
  perform pg_temp.ok((select (run_at at time zone 'Europe/Minsk')::time = '16:00' from public.notification_jobs where booking_id = b and status = 'pending'), 'новое задание под новое время');

  -- выдача воркеру с арендой
  update public.notification_jobs set run_at = now() - interval '1 minute' where booking_id = b and status = 'pending';
  select count(*) into n from public.claim_notification_jobs(10, 60);
  perform pg_temp.ok(n = 1, 'воркер получил одно задание');
  select count(*) into n from public.claim_notification_jobs(10, 60);
  perform pg_temp.ok(n = 0, 'пока аренда действует, задание не выдаётся второй раз');
  update public.notification_jobs set lease_until = now() - interval '1 second' where booking_id = b and status = 'processing';
  select job_id into j1 from public.claim_notification_jobs(10, 60);
  perform pg_temp.ok(j1 is not null, 'после истечения аренды задание выдаётся снова');
  perform public.complete_notification_job(j1, 'sent');
  perform pg_temp.ok((select status = 'sent' and attempts = 2 from public.notification_jobs where id = j1), 'задание отмечено отправленным, попытки учтены');

  -- отмена записи отменяет ожидающие задания
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform public.owner_move_booking(b, d, '17:00');
  perform public.owner_set_status(b, 'cancelled');
  perform pg_temp.as_admin();
  perform pg_temp.ok(not exists (select 1 from public.notification_jobs where booking_id = b and status in ('pending', 'processing')), 'после отмены нет ожидающих напоминаний');

  -- ПД: обезличивание удаляет подписку и закрывает доступ
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform public.owner_anonymize_booking(b);
  perform pg_temp.as_admin();
  perform pg_temp.ok((select client_name = 'Обезличено' and anonymized_at is not null from public.bookings where id = b), 'данные клиента обезличены по просьбе');
  perform pg_temp.ok(not exists (select 1 from public.push_subscriptions where booking_id = b), 'подписка на уведомления удалена');
  perform pg_temp.throws(format($q$select public.get_my_booking(%L, %L)$q$, b, tok), 'not_found', 'старый токен больше не открывает запись');
end $$;

-- срок хранения: старые записи обезличиваются автоматически
do $$
declare b uuid;
begin
  select id into b from public.bookings where client_name like 'Демо: Сергей%';
  update public.resource_occupancies set period = tstzrange(now() - interval '400 days', now() - interval '399 days') where booking_id = b;
  update public.bookings set starts_at = now() - interval '400 days', ends_at = now() - interval '399 days' where id = b;
  perform pg_temp.ok(public.purge_expired_personal_data() >= 1, 'просроченные персональные данные обезличены');
  perform pg_temp.ok((select client_phone = '+375000000000' from public.bookings where id = b), 'телефон удалён, суммы и даты остались');
  perform pg_temp.ok((select count(*) from public.payments where booking_id = b) = 1, 'платёж для учёта сохранён');
end $$;

rollback;
