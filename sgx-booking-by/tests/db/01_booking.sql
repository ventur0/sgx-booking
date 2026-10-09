-- Запись, два ресурса, буфер, многодневная занятость, блокировка, перенос, отмена,
-- идемпотентность, историческая цена, платежи и статистика.
begin;
\ir 00_helpers.sql

do $$
declare d date := pg_temp.open_day('graphite', 7, '10:00');
        d2 date; b1 uuid; b2 uuid; b3 uuid; c1 uuid; m1 uuid; blk uuid; st timestamptz; en timestamptz;
        r1 uuid := pg_temp.res('graphite', 'post-1'); r2 uuid := pg_temp.res('graphite', 'post-2');
        free_cnt int; js jsonb;
begin
  -- ---------- свободное время ----------
  select count(*) into free_cnt from public.get_availability('graphite', pg_temp.svc('graphite', 'wash'), d, 1) where free;
  perform pg_temp.ok(free_cnt > 10, 'в рабочий день есть свободные окна для мойки');

  -- ---------- создание и идемпотентность ----------
  b1 := pg_temp.book('graphite', 'wash', d, '10:00', 'A1');
  perform pg_temp.ok(b1 is not null, 'клиент записался без регистрации');
  perform pg_temp.ok(pg_temp.book('graphite', 'wash', d, '10:00', 'A1') = b1, 'повтор с тем же ключом и токеном возвращает ту же запись');
  perform pg_temp.ok((select count(*) from public.bookings where idempotency_key = md5('A1')::uuid) = 1, 'копия не создана');
  perform pg_temp.throws(format($q$select public.create_booking('graphite', %L, %L, '10:00', 'Злоумышленник', '+375291112233', 'Car', %L, %L, true, 'x')$q$,
           pg_temp.svc('graphite', 'wash'), d, md5('A1')::uuid, rpad('другой-токен', 40, 'y')), 'idempotency_conflict', 'чужой токен с тем же ключом не получает доступ');
  perform pg_temp.ok((select access_token_hash = digest(rpad('tok-A1', 40, 'x'), 'sha256') from public.bookings where id = b1), 'в базе хранится только sha256 токена');
  perform pg_temp.ok((select resource_id = r1 from public.bookings where id = b1), 'занят первый подходящий пост');
  perform pg_temp.ok((select price = 45.50 and service_name = 'Детейлинг-мойка' from public.bookings where id = b1), 'цена и название взяты сервером из услуги');

  -- ---------- второй ресурс и полная занятость ----------
  b2 := pg_temp.book('graphite', 'wash', d, '10:00', 'A2', '+375 29 222-33-44');
  perform pg_temp.ok((select resource_id = r2 from public.bookings where id = b2), 'второй клиент на то же время попал на второй пост');
  perform pg_temp.throws(format($q$select pg_temp.book('graphite', 'wash', %L, '10:00', 'A3', '+375293334455')$q$, d), 'slot_taken', 'третьему клиенту время недоступно');
  perform pg_temp.ok(not (select free from public.get_availability('graphite', pg_temp.svc('graphite', 'wash'), d, 1) where slot_time = '10:00'), 'в расписании 10:00 отмечено занятым');

  -- ---------- буфер 15 минут ----------
  -- мойка 10:00–11:30 + 15 мин подготовки: 11:30 занято, 12:00 свободно
  perform pg_temp.ok(not (select free from public.get_availability('graphite', pg_temp.svc('graphite', 'wash'), d, 1) where slot_time = '11:30'), 'конец работ + буфер: 11:30 ещё занято');
  perform pg_temp.ok((select free from public.get_availability('graphite', pg_temp.svc('graphite', 'wash'), d, 1) where slot_time = '12:00'), 'после буфера 12:00 свободно');

  -- ---------- шаг, часы и запас по времени ----------
  perform pg_temp.throws(format($q$select pg_temp.book('graphite', 'wash', %L, '10:10', 'X1')$q$, d), 'outside_hours', 'время не по шагу отклоняется');
  perform pg_temp.throws(format($q$select pg_temp.book('graphite', 'wash', %L, '20:00', 'X2')$q$, d), 'outside_hours', 'короткая работа не может закончиться после закрытия');
  perform pg_temp.throws(format($q$select pg_temp.book('graphite', 'wash', %L, '10:00', 'X3')$q$, (now() at time zone 'Europe/Minsk')::date - 1), 'too_soon', 'в прошлое записаться нельзя');
  perform pg_temp.throws(format($q$select public.create_booking('graphite', %L, %L, '12:00', 'Иван', '12345', 'Car', %L, %L, true, 'x')$q$,
           pg_temp.svc('graphite', 'wash'), d, md5('bad-phone')::uuid, rpad('t', 40, 'z')), 'bad_phone', 'неверный телефон отклоняется');
  perform pg_temp.throws(format($q$select public.create_booking('graphite', %L, %L, '12:00', 'Иван', '+375291234567', 'Car', %L, %L, false, 'x')$q$,
           pg_temp.svc('graphite', 'wash'), d, md5('no-consent')::uuid, rpad('t', 40, 'w')), 'consent_required', 'без согласия на обработку ПД запись не создаётся');

  -- ---------- многодневная занятость ----------
  d2 := pg_temp.open_day('graphite', 14, '09:00');
  c1 := pg_temp.book('graphite', 'ppf', d2, '09:00', 'PPF', '+375 44 555-66-77');
  select starts_at, ends_at into st, en from public.bookings where id = c1;
  perform pg_temp.ok(en - st = interval '48 hours', 'плёнка занимает пост непрерывно 48 часов');
  perform pg_temp.ok((select resource_id = r2 from public.bookings where id = c1), 'плёнка только на подходящем посту 2');
  perform pg_temp.ok((select upper(period) = en + interval '15 minutes' from public.resource_occupancies where booking_id = c1), 'занятость включает буфер после работ');
  -- на следующий день пост 2 занят весь день, мойка идёт на пост 1
  b3 := pg_temp.book('graphite', 'wash', pg_temp.open_day('graphite', (d2 - (now() at time zone 'Europe/Minsk')::date) + 1, '12:00'), '12:00', 'NEXT', '+375 29 777-88-99');
  perform pg_temp.ok((select resource_id = r1 from public.bookings where id = b3), 'в дни плёнки мойка на свободном посту 1');
  perform pg_temp.throws(format($q$select pg_temp.book('graphite', 'ppf', %L, '09:00', 'PPF2', '+375447778899')$q$, d2), 'slot_taken', 'вторая плёнка на те же дни невозможна');

  -- ---------- блокировка поста ----------
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  blk := public.owner_block_resource(r1, (d + '14:00'::time) at time zone 'Europe/Minsk', (d + '17:00'::time) at time zone 'Europe/Minsk', 'ремонт подъёмника');
  perform pg_temp.as_admin();
  m1 := pg_temp.book('graphite', 'wash', d, '14:00', 'B1', '+375 29 100-00-01');
  perform pg_temp.ok((select resource_id = r2 from public.bookings where id = m1), 'при блокировке поста 1 запись идёт на пост 2');
  perform pg_temp.throws(format($q$select pg_temp.book('graphite', 'wash', %L, '14:00', 'B2', '+375291000002')$q$, d), 'slot_taken', 'блок + занятый пост 2 = время недоступно');
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform pg_temp.throws(format($q$select public.owner_block_resource(%L, %L, %L, 'x')$q$, r1, (d + '09:30'::time) at time zone 'Europe/Minsk', (d + '10:30'::time) at time zone 'Europe/Minsk'),
           'block_conflict', 'блокировку нельзя поставить поверх записи');
  perform public.owner_unblock(blk);
  perform pg_temp.as_admin();

  -- ---------- перенос ----------
  -- занимаем оба поста на 18:30 другими клиентами
  perform pg_temp.book('graphite', 'wash', d, '18:30', 'C1', '+375 29 120-00-01');
  perform pg_temp.book('graphite', 'wash', d, '18:30', 'C2', '+375 29 120-00-02');
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  select starts_at, resource_id into st, m1 from public.bookings where id = b2;
  perform pg_temp.throws(format($q$select public.owner_move_booking(%L, %L, '18:30')$q$, b2, d), 'slot_taken', 'перенос на занятое время отклонён');
  perform pg_temp.ok((select starts_at = st and resource_id = m1 from public.bookings where id = b2)
                     and (select lower(period) = st from public.resource_occupancies where booking_id = b2), 'после неудачного переноса исходная запись и занятость не изменились');
  perform public.owner_move_booking(b2, d, '16:00');
  perform pg_temp.ok((select (starts_at at time zone 'Europe/Minsk')::time = '16:00' from public.bookings where id = b2), 'перенос на свободное время выполнен');
  perform pg_temp.ok((select lower(period) = (d + '16:00'::time) at time zone 'Europe/Minsk' from public.resource_occupancies where booking_id = b2), 'занятость перенесена вместе с записью');
  perform pg_temp.as_admin();
  perform pg_temp.ok((select free from public.get_availability('graphite', pg_temp.svc('graphite', 'wash'), d, 1) where slot_time = '10:00'), 'старое время освободилось после переноса');

  -- ---------- отмена клиентом ----------
  set local role anon;
  js := public.get_my_booking(b1, rpad('tok-A1', 40, 'x'));
  perform pg_temp.ok((js ->> 'status') = 'new' and (js ->> 'canCancel')::boolean, 'клиент видит свою запись по токену');
  perform pg_temp.throws(format($q$select public.get_my_booking(%L, %L)$q$, b1, rpad('чужой', 40, 'q')), 'not_found', 'по чужому токену запись не видна');
  perform public.cancel_my_booking(b1, rpad('tok-A1', 40, 'x'));
  reset role;
  perform pg_temp.ok((select status = 'cancelled' and cancelled_by = 'client' from public.bookings where id = b1), 'клиент отменил запись');
  perform pg_temp.ok(not exists (select 1 from public.resource_occupancies where booking_id = b1), 'занятость удалена в той же транзакции');

  -- ---------- историческая цена ----------
  update public.services set price = 60 where id = pg_temp.svc('graphite', 'wash');
  perform pg_temp.ok((select price = 45.50 from public.bookings where id = b2), 'старая запись сохранила цену 45,50 после изменения прайса');
  m1 := pg_temp.book('graphite', 'wash', d, '09:00', 'P60', '+375 29 600-00-60');
  perform pg_temp.ok((select price = 60 from public.bookings where id = m1), 'новая запись по новой цене');

  -- ---------- платежи ----------
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform public.owner_set_status(b2, 'accepted');
  perform public.owner_add_payment(b2, 'pay', 45.50, 'erip');
  perform pg_temp.throws(format($q$select public.owner_add_payment(%L, 'refund', 45.51)$q$, b2), 'refund_exceeds_paid', 'возврат больше оплаты запрещён');
  perform pg_temp.throws(format($q$select public.owner_add_payment(%L, 'pay', 10.555)$q$, b2), 'bad_amount', 'три знака после запятой отклоняются');
  perform public.owner_add_payment(b2, 'refund', 5.25);
  perform pg_temp.throws(format($q$select public.owner_set_status(%L, 'new')$q$, c1), 'bad_transition', 'недопустимый переход статуса отклонён');
  perform public.owner_set_status(b2, 'ready');
  perform public.owner_set_status(b2, 'done');
  js := public.owner_stats(pg_temp.tid('graphite'), (now() at time zone 'Europe/Minsk')::date, (now() at time zone 'Europe/Minsk')::date);
  perform pg_temp.ok((js ->> 'received')::numeric = 45.50 and (js ->> 'refunded')::numeric = 5.25 and (js ->> 'net')::numeric = 40.25,
                     'деньги за сегодня: получено 45,50, возврат 5,25, итого 40,25');
  js := public.owner_stats(pg_temp.tid('graphite'), d, d);
  perform pg_temp.ok((js ->> 'completed')::int = 1, 'выполненные заказы считаются отдельно');
  perform pg_temp.ok((js ->> 'visits')::int >= 3 and (js ->> 'expected')::numeric > 0, 'заезды и ожидаемая стоимость отдельно от полученных денег');
  perform pg_temp.as_admin();
end $$;

rollback;
