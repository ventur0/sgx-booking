#!/usr/bin/env bash
# pnpm test:db — SQL/интеграционные тесты базы.
#   DATABASE_URL — пустая база PostgreSQL 15+ (локальный Supabase: postgresql://postgres:postgres@127.0.0.1:54322/postgres
#   после `supabase db reset` — тогда SKIP_SETUP=1, миграции и seed уже применены).
#   Без SKIP_SETUP скрипт сам применит заглушку окружения Supabase, миграции и seed.
set -euo pipefail
cd "$(dirname "$0")"
DB_URL="${DATABASE_URL:?Укажите DATABASE_URL}"
if [ "${SKIP_SETUP:-0}" != "1" ]; then
  psql "$DB_URL" -q -v ON_ERROR_STOP=1 -f supabase_shim.sql
  for f in ../../supabase/migrations/*.sql; do psql "$DB_URL" -q -v ON_ERROR_STOP=1 -f "$f"; done
  psql "$DB_URL" -q -v ON_ERROR_STOP=1 -o /dev/null -f ../../supabase/seed.sql
fi
fail=0; pass=0
for f in 01_booking.sql 02_rls.sql 03_outbox.sql 04_stats_tz.sql 05_platform.sql 06_billing.sql; do
  out=$(psql "$DB_URL" -q -v ON_ERROR_STOP=1 -f "$f" 2>&1) || { echo "$out" | grep -E "ERROR|FAIL" | sed 's/^psql:[^ ]* //'; echo "✗ $f"; fail=1; continue; }
  n=$(echo "$out" | grep -c "NOTICE:  ok" || true); pass=$((pass + n)); echo "✓ $f — проверок: $n"
done
bash concurrency.sh || fail=1
echo "Всего успешных проверок: $((pass + 1))"
exit $fail
