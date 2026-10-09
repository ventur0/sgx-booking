#!/usr/bin/env bash
# Конкурентная запись: N клиентов одновременно берут одно время у студии с двумя постами.
# Ожидание: успешных записей ровно столько, сколько подходящих постов; двойной клик — одна запись.
set -euo pipefail
DB_URL="${DATABASE_URL:?DATABASE_URL}"
N="${N:-12}"
SLUG=graphite
DAY=$(psql "$DB_URL" -Atq -c "\ir $(dirname "$0")/00_helpers.sql" -c "select pg_temp.open_day('$SLUG', 21, '15:00')" | tail -1)
SVC=$(psql "$DB_URL" -Atq -c "select s.id from services s join tenants t on t.id = s.tenant_id where t.slug='$SLUG' and s.key='wash'")
RUN=$(date +%s%N)
cleanup() { psql "$DB_URL" -Atq -c "delete from bookings where consent_version = 'race'; delete from rate_counters;" >/dev/null; rm -f /tmp/race-$RUN-* /tmp/dbl-$RUN-*; }
trap cleanup EXIT
call() { # $1 = метка, $2 = ключ идемпотентности
  psql "$DB_URL" -Atq -c "set role anon; select public.create_booking('$SLUG', '$SVC', '$DAY', '15:00', 'Гонка $1', '+37529$(printf '%07d' $1)', 'Car', '$2', rpad('race-$RUN-$1', 40, 'x'), true, 'race')" 2>&1 | grep -oE '^[0-9a-f-]{36}$|slot_taken|ERROR.*' | head -1 || true
}
for i in $(seq 1 "$N"); do (call "$i" "$(cat /proc/sys/kernel/random/uuid)" > "/tmp/race-$RUN-$i") & done; wait
OK=$(cat /tmp/race-$RUN-* | grep -cE '^[0-9a-f-]{36}$' || true); TAKEN=$(cat /tmp/race-$RUN-* | grep -c slot_taken || true)
# двойное нажатие: 6 параллельных запросов с одним ключом и токеном
KEY=$(cat /proc/sys/kernel/random/uuid)
for i in $(seq 1 6); do (psql "$DB_URL" -Atq -c "set role anon; select public.create_booking('$SLUG', '$SVC', '$DAY', '18:00', 'Дубль', '+375290000099', 'Car', '$KEY', rpad('dbl-$RUN', 40, 'x'), true, 'race')" > "/tmp/dbl-$RUN-$i" 2>&1) & done; wait
DBL_IDS=$(cat /tmp/dbl-$RUN-* | sort -u | grep -cE '^[0-9a-f-]{36}$' || true)
ROWS=$(psql "$DB_URL" -Atq -c "select count(*) from bookings where idempotency_key = '$KEY'")
echo "одновременных запросов: $N, успешно: $OK, отклонено slot_taken: $TAKEN"
echo "двойное нажатие: разных id в ответах: $DBL_IDS, строк в базе: $ROWS"
[ "$OK" -eq 2 ] && [ "$TAKEN" -eq $((N - 2)) ] && [ "$DBL_IDS" -eq 1 ] && [ "$ROWS" -eq 1 ] && echo "ok  конкурентная запись и идемпотентность" || { echo "FAIL"; exit 1; }
