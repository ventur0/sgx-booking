/**
 * pnpm seed:build — собирает supabase/seed.sql из tenants/*\/business.json.
 * Seed нужен для локальной разработки (supabase db reset) и SQL-тестов:
 * все демо-записи помечены is_demo, студии в режиме preview.
 * Картинки в seed указывают на статические файлы студии: /t/<slug>/media/<файл>.
 */
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT, configExceptions, listTenants, validateTenant } from "./lib";
import { normalizeBYPhone } from "../src/shared/by";
import { WEEKDAY_KEYS } from "../src/shared/business";

const q = (s: string | null | undefined) => (s == null ? "null" : `'${String(s).replace(/'/g, "''")}'`);
const j = (v: unknown) => `${q(JSON.stringify(v))}::jsonb`;
const media = (slug: string, p: string) => `/t/${slug}/media/${p.replace(/^images\//, "")}`;

const out: string[] = [
  "-- СГЕНЕРИРОВАНО scripts/build-seed.ts из tenants/*/business.json. Не редактируйте вручную.",
  "-- Только демо-данные: студии в режиме preview, записи помечены is_demo.",
  "",

  "",
];

for (const slug of listTenants()) {
  const v = validateTenant(slug);
  if (!v.ok || !v.business) {
    console.error(`✗ ${slug}: ${v.errors.join("; ")}`);
    process.exit(1);
  }
  const b = v.business;
  const profile = { ...b.profile, media: { hero: media(slug, b.images.hero), logo: media(slug, b.images.logo) } };
  out.push(`-- ===== ${slug} =====`);
  out.push(`insert into public.tenants (slug, mode, timezone, profile) values (${q(slug)}, 'preview', ${q(b.timezone)}, ${j(profile)})
on conflict (slug) do update set profile = excluded.profile, timezone = excluded.timezone;`);
  const T = `(select id from public.tenants where slug = ${q(slug)})`;
  b.resources.forEach((r, i) =>
    out.push(`insert into public.resources (tenant_id, key, name, sort) values (${T}, ${q(r.key)}, ${q(r.name)}, ${i}) on conflict (tenant_id, key) do update set name = excluded.name, sort = excluded.sort;`),
  );
  b.services.forEach((s, i) => {
    out.push(`insert into public.services (tenant_id, key, name, description, price, duration_min, active, sort) values (${T}, ${q(s.key)}, ${q(s.name)}, ${q(s.description)}, ${s.price}, ${s.durationMin}, ${s.active}, ${i})
on conflict (tenant_id, key) do update set name = excluded.name, description = excluded.description, price = excluded.price, duration_min = excluded.duration_min, active = excluded.active, sort = excluded.sort;`);
    for (const rk of s.resources ?? [])
      out.push(`insert into public.service_resources (tenant_id, service_id, resource_id) select t.id, s.id, r.id from public.tenants t join public.services s on s.tenant_id = t.id and s.key = ${q(s.key)} join public.resources r on r.tenant_id = t.id and r.key = ${q(rk)} where t.slug = ${q(slug)} on conflict do nothing;`);
  });
  WEEKDAY_KEYS.forEach((k, wd) => {
    const h = b.hours[k];
    if (h) out.push(`insert into public.working_hours (tenant_id, weekday, opens, closes) values (${T}, ${wd}, ${q(h.opens)}, ${q(h.closes)}) on conflict (tenant_id, weekday) do update set opens = excluded.opens, closes = excluded.closes;`);
  });
  for (const e of configExceptions(b))
    out.push(`insert into public.schedule_exceptions (tenant_id, day, closed, opens, closes, note, source) values (${T}, ${q(e.day)}, ${e.closed}, ${q(e.opens)}, ${q(e.closes)}, ${q(e.note)}, 'config') on conflict (tenant_id, day) do nothing;`);
  b.works.forEach((w, i) =>
    out.push(`insert into public.works (tenant_id, key, photo_url, caption, sort, source) values (${T}, ${q(w.key)}, ${q(media(slug, w.image))}, ${q(w.caption)}, ${i}, 'config') on conflict (tenant_id, key) do update set photo_url = excluded.photo_url, caption = excluded.caption, sort = excluded.sort;`),
  );
  b.demo.bookings.forEach((d, i) => {
    if (!normalizeBYPhone(d.phone)) throw new Error(`demo ${slug}#${i}: телефон`);
    out.push(`select public.admin_insert_demo_booking(${T}, ${q(`demo-${i}`)}, ${q(d.service)}, ${q(d.resource ?? null)}, ${d.dayOffset}, ${q(d.time)}, ${q(d.name)}, ${q(d.phone)}, ${q(d.car)}, ${q(d.status)}, ${j(d.payments)});`);
  });
  out.push("");
}

// Демо-владельцы для локального Supabase (auth.users с паролем). На чистом PostgreSQL без схемы Supabase Auth шаг пропускается.
out.push(`-- ===== демо-владельцы (только локально) =====
do $$
declare s text; u uuid;
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    return;
  end if;
  foreach s in array array[${listTenants().map((x) => q(x)).join(", ")}] loop
    u := md5('owner-' || s)::uuid;
    execute $q$insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
      values ('00000000-0000-0000-0000-000000000000', $1, 'authenticated', 'authenticated', $2, crypt('demo-owner-pass', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}')
      on conflict (id) do nothing$q$ using u, 'owner@' || s || '.local';
    execute $q$insert into auth.identities (id, user_id, provider_id, identity_data, provider, created_at, updated_at, last_sign_in_at)
      values (gen_random_uuid(), $1, $1::text, jsonb_build_object('sub', $1::text, 'email', $2), 'email', now(), now(), now())
      on conflict do nothing$q$ using u, 'owner@' || s || '.local';
    insert into public.tenant_members (tenant_id, user_id) select id, u from public.tenants where slug = s on conflict do nothing;
  end loop;
end $$;`);

writeFileSync(join(ROOT, "supabase", "seed.sql"), out.join("\n") + "\n");
console.log(`✓ supabase/seed.sql: ${listTenants().join(", ")}`);
