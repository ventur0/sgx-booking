# AGENTS.md — правила для агентов и разработчиков

## Инварианты (не нарушать)
1. Один JS/CSS-билд на все студии. Названия, цены, тексты бизнесов — только в `tenants/*/business.json` и в БД.
   В `src/` их быть не должно (это проверяет `tests/unit/business.test.ts`).
2. Каждая зависимая таблица содержит `tenant_id`; связи — составными FK `(tenant_id, id)`.
3. Вся занятость постов — в `resource_occupancies` с `EXCLUDE USING gist (resource_id with =, period with &&)`.
   Создание/перенос/отмена — только SQL-функции (одна транзакция). Клиент не передаёт цену, студию, длительность, пост.
4. Клиентский доступ — токен из браузера, в БД только `sha256`. Повтор с тем же ключом идемпотентности и токеном
   возвращает ту же запись.
5. anon не получает персональные данные, платежи, токены, outbox. Новые таблицы: `enable row level security`
   + явные GRANT. Новые функции: `revoke all … from public, anon, authenticated`, затем точечный grant.
6. Статистику считает SQL (`owner_stats`). Полученные деньги ≠ ожидаемая стоимость.
7. Студия в preview: только `is_demo` данные, уведомления `skipped`. live — через `tenant:publish --live`
   или кнопкой владельца «Запуск» (`owner_go_live`: нужны данные оператора ПД и настоящий телефон).
9. Панель продавца `/admin`: права только у `platform_admins`. Аккаунты владельцев создаёт Edge Function
   `admin-users` (service role остаётся на сервере). Студии из панели живут только в БД (оболочка `/t/_default/`).
8. Service worker не кэширует ничего, что пришло с JWT владельца.

## Проверки перед коммитом
```bash
pnpm typecheck && pnpm test
DATABASE_URL=… pnpm test:db          # обязательно при изменении supabase/migrations
pnpm build && pnpm preview && pnpm test:e2e
```

## Где что лежит
- `supabase/migrations/` — схема, функции, права (по порядку: core → bookings → functions → owner → security → pipeline → platform)
- `tests/db/` — SQL-тесты и тест конкуренции
- `scripts/` — конвейер `tenant:*`, `build-shells`, `build-seed`
- `src/shared/` — схемы и чистые функции, общие для браузера и скриптов
- `src/data/` — запросы TanStack Query; `src/pages/client`, `src/pages/owner` — экраны
