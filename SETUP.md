# SETUP: локальный запуск, Supabase, напоминания и публикация

Стек: React 19, TypeScript strict, Vite, React Router, TanStack Query, Zod, Supabase (Postgres/Auth/Storage/Edge Functions),
vite-plugin-pwa (injectManifest). Сайт статический, публикуется на Cloudflare Pages. Отдельного Node-бэкенда нет.
ИИ-функций в этой версии нет.

## 1. Что нужно

- Node.js 20.11+ и pnpm 10 (`npm i -g pnpm`)
- Docker (для локального Supabase) или проект на supabase.com в регионе **Frankfurt (eu-central-1)**
- Аккаунт Cloudflare (Pages) — для публикации
- `psql` — для SQL-тестов

## 2. Локальный запуск

```bash
pnpm install                     # создаст pnpm-lock.yaml — закоммитьте его
cp .env.example .env
pnpm exec supabase start         # локальные Postgres, Auth, Storage, Realtime
# в .env впишите VITE_SUPABASE_URL=http://127.0.0.1:54321 и anon key из вывода supabase start
pnpm seed:build                  # supabase/seed.sql из tenants/*/business.json
pnpm exec supabase db reset      # миграции + seed (две демо-студии, демо-владельцы)
pnpm dev                         # http://localhost:5173/s/graphite/ и /s/protector/
```

Демо-владельцы (только локально): `owner@graphite.local` и `owner@protector.local`, пароль `demo-owner-pass`.
Кабинет: `/s/graphite/owner/`.

## 3. Проверки

```bash
pnpm test                                    # Vitest: схема business.json, телефоны, BYN, праздники
DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres SKIP_SETUP=1 pnpm test:db
                                             # SQL: запись, конкуренция, RLS, outbox, статистика
pnpm build && pnpm preview                   # сборка + оболочки студий + локальный Cloudflare Pages
BASE_URL=http://localhost:4173 pnpm test:e2e # Playwright: клиент записался → владелец видит
pnpm exec playwright install chromium        # один раз перед e2e
```

`pnpm test:db` без `SKIP_SETUP=1` сам применит миграции и seed к пустой базе PostgreSQL 15+
(используется заглушка окружения Supabase из `tests/db/supabase_shim.sql`).

## 4. Supabase в облаке

```bash
pnpm exec supabase login
pnpm exec supabase link --project-ref <ref>
pnpm db:push                                 # миграции из supabase/migrations
```

В Dashboard → Authentication → Sign In / Providers выключите **Allow new users to sign up**.
Владельцев создаёт только `tenant:publish` через service role.

Ключи:
- `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` — в Cloudflare Pages (Environment variables) и в `.env`;
- `SUPABASE_SERVICE_ROLE_KEY` — **только** в `.env` на вашем компьютере, для команд `tenant:*`.

## 5. Напоминания за сутки (Web Push)

```bash
npx web-push generate-vapid-keys             # публичный ключ → VITE_VAPID_PUBLIC_KEY
pnpm exec supabase secrets set \
  VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... VAPID_SUBJECT=mailto:you@mail.by \
  PUBLIC_SITE_URL=https://<домен> CRON_SECRET=$(openssl rand -hex 24)
pnpm functions:deploy
```

В SQL Editor включите расширения `pg_cron` и `pg_net` (Database → Extensions) и создайте задания
(подставьте ref проекта и тот же CRON_SECRET):

```sql
select cron.schedule('sgx-send-reminders', '*/5 * * * *', $$
  select net.http_post(
    url := 'https://<ref>.supabase.co/functions/v1/send-reminders',
    headers := jsonb_build_object('Authorization', 'Bearer <CRON_SECRET>', 'Content-Type', 'application/json'),
    body := '{}'::jsonb);
$$);

-- ежедневно: обезличивание персональных данных старше срока хранения (Закон РБ № 99-З)
select cron.schedule('sgx-purge-personal-data', '15 3 * * *', $$ select public.purge_expired_personal_data(); $$);
```

Как это работает:
- клиент нажимает «Включить напоминание» → подписка сохраняется → в `notification_jobs` появляется задание на «начало − 24 ч»;
- перенос записи отменяет старое задание и создаёт новое (ключ дедупликации включает время), отмена — отменяет;
- функция берёт задания через `claim_notification_jobs` (аренда + SKIP LOCKED), отправляет, отмечает `sent`
  или возвращает с задержкой; после 5 попыток — `failed`;
- студии в режиме preview и демо-записи получают задания со статусом `skipped` — реальных уведомлений нет;
- на iPhone push работает только у приложения, добавленного на экран «Домой» (iOS 16.4+). В обычной вкладке
  интерфейс прямо говорит об этом и предлагает .ics с напоминанием.

## 6. Публикация на Cloudflare Pages

```bash
pnpm build                                   # dist/ + dist/t/<slug>/ для каждой студии + _redirects/_headers
pnpm exec wrangler login
pnpm deploy                                  # wrangler pages deploy dist
```

Или подключите репозиторий в Cloudflare Pages: команда сборки `pnpm build`, каталог `dist`,
переменные `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_VAPID_PUBLIC_KEY`, `DEFAULT_TENANT`.

Маршрутизация (`dist/_redirects`): `/s/<slug>/*` отдаёт оболочку `/t/<slug>/` с метаданными и манифестом этой студии.
Статика студий лежит в `/t/`, потому что правила `_redirects` в Cloudflare Pages применяются и к существующим файлам.

## 7. Новая студия

См. [CLONE-IN-6-MINUTES.md](CLONE-IN-6-MINUTES.md).

## Панель продавца (/admin) — много покупателей без SQL

1. Supabase → SQL Editor: выполнить по порядку `20261009100600_platform.sql`, `20261009100700_delete_studio.sql`
   `20261009100800_fixes.sql` и `20261009100900_delete_by_function.sql` из `supabase/migrations/` (после каждой правки `supabase/functions/admin-users/index.ts` функцию нужно заново развернуть в Supabase) (для уже настроенной базы) и сделать себя продавцом:
   `insert into public.platform_admins select id from auth.users where email = 'ваша@почта';`
2. Supabase → Edge Functions → Deploy a new function → Via Editor: имя `admin-users`,
   код из `supabase/functions/admin-users/index.ts`, Deploy. В деталях функции выключить «Verify JWT».
3. Открыть `https://<сайт>/admin`, войти. «Новая студия» создаёт заготовку и аккаунт владельца;
   кнопка «Скопировать» даёт текст для покупателя (ссылки, логин, временный пароль).
4. Владелец сам меняет всё в кабинете `/s/<адрес>/owner` → Настройки (услуги и посты, график,
   фото, данные ИП, пароль) и сам нажимает «Запуск». Продавец может приостановить студию,
   сменить владельцу пароль или почту, выдать или убрать доступ.

Напоминания через Web Push отключены (миграция `20261009101200_disable_push.sql`); клиентам остаётся событие календаря (.ics).
Собственные домены студий и учёт оплат убраны (миграции `20261009101100_drop_billing.sql`, `20261009101300_drop_domains.sql`).
