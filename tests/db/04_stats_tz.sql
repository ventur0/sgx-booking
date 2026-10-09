-- Статистика: границы суток в часовом поясе студии, а не UTC.
begin;
\ir 00_helpers.sql

do $$
declare d date := pg_temp.open_day('graphite', 7, '10:00'); b uuid; js jsonb;
begin
  b := pg_temp.book('graphite', 'wash', d, '10:00', 'TZ');
  -- 23:30 по Минску = 20:30 UTC того же дня; 00:30 следующего дня по Минску = 21:30 UTC текущего дня
  insert into public.payments (tenant_id, booking_id, kind, amount, paid_at) values
    (pg_temp.tid('graphite'), b, 'pay', 10, (d + '23:30'::time) at time zone 'Europe/Minsk'),
    (pg_temp.tid('graphite'), b, 'pay', 20, ((d + 1) + '00:30'::time) at time zone 'Europe/Minsk');
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  js := public.owner_stats(pg_temp.tid('graphite'), d, d);
  perform pg_temp.ok((js ->> 'received')::numeric = 10, 'оплата в 23:30 по Минску — в этот день, в 00:30 — уже в следующий');
  js := public.owner_stats(pg_temp.tid('graphite'), d + 1, d + 1);
  perform pg_temp.ok((js ->> 'received')::numeric = 20, 'следующие сутки считаются по времени студии');
  perform pg_temp.ok((js ->> 'timezone') = 'Europe/Minsk', 'статистика сообщает часовой пояс периода');
  perform pg_temp.throws(format($q$select public.owner_stats(%L, %L, %L)$q$, pg_temp.tid('graphite'), d, d - 1), 'bad_range', 'перевёрнутый период отклоняется');
  perform pg_temp.as_admin();
end $$;

rollback;
