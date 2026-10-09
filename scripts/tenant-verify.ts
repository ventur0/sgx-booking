/**
 * pnpm tenant:verify <slug> [--url https://ваш-домен] [--e2e]
 * Проверяет опубликованную студию по-настоящему, по сети:
 *  - /s/<slug>/ и глубокая ссылка /s/<slug>/owner/ отдают оболочку именно этой студии;
 *  - манифест: id/start_url/scope = /s/<slug>/, иконки 192/512 и maskable доступны, apple-touch-icon есть;
 *  - service worker /t/<slug>/sw.js отдаётся с Service-Worker-Allowed;
 *  - база: публичный профиль и услуги читаются anon-ключом, get_availability отвечает,
 *    а записи, платежи и outbox для anon закрыты;
 *  - --e2e: Playwright-сценарий «запись → видна владельцу» (нужны OWNER_EMAIL/OWNER_PASSWORD).
 */
import { spawnSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { arg, fail, flag, requireEnv } from "./lib";

const slug = process.argv[2];
if (!slug || slug.startsWith("--")) fail("pnpm tenant:verify <slug> [--url https://…] [--e2e]");
const base = (arg("url") ?? process.env.PUBLIC_SITE_URL ?? "").replace(/\/$/, "");
if (!base) fail("Передайте --url или задайте PUBLIC_SITE_URL");

const results: { ok: boolean; name: string; detail?: string }[] = [];
const check = (name: string, ok: boolean, detail?: string) => results.push({ ok, name, detail });

async function get(path: string) {
  const r = await fetch(base + path, { redirect: "follow" });
  return { status: r.status, headers: r.headers, text: await r.text() };
}

// ---------- оболочка и глубокие ссылки ----------
for (const path of [`/s/${slug}/`, `/s/${slug}/owner/`, `/s/${slug}/my`]) {
  const r = await get(path);
  check(`${path} → оболочка студии`, r.status === 200 && r.text.includes(`name="sgx-tenant" content="${slug}"`), `HTTP ${r.status}`);
}

// ---------- манифест и иконки ----------
const m = await get(`/t/${slug}/manifest.webmanifest`);
let manifest: { id?: string; start_url?: string; scope?: string; icons?: { src: string; purpose?: string }[] } = {};
try {
  manifest = JSON.parse(m.text);
} catch {
  /* проверка ниже */
}
check("manifest id/start_url/scope", manifest.id === `/s/${slug}/` && manifest.start_url === `/s/${slug}/` && manifest.scope === `/s/${slug}/`, JSON.stringify({ id: manifest.id, scope: manifest.scope }));
check("maskable-иконка в манифесте", !!manifest.icons?.some((i) => i.purpose === "maskable"));
for (const icon of manifest.icons ?? []) {
  const r = await fetch(base + icon.src);
  check(`иконка ${icon.src}`, r.ok && (r.headers.get("content-type") ?? "").startsWith("image/"), `HTTP ${r.status}`);
}
const apple = await fetch(`${base}/t/${slug}/apple-touch-icon.png`);
check("apple-touch-icon", apple.ok);
const sw = await get(`/t/${slug}/sw.js`);
check("service worker и Service-Worker-Allowed", sw.status === 200 && !!sw.headers.get("service-worker-allowed"), `allowed=${sw.headers.get("service-worker-allowed")}`);

// ---------- база через anon-ключ ----------
const sb = createClient(requireEnv("VITE_SUPABASE_URL"), requireEnv("VITE_SUPABASE_ANON_KEY"), { auth: { persistSession: false } });
const { data: t, error: te } = await sb.from("tenants").select("id, mode, profile").eq("slug", slug).maybeSingle();
check("профиль студии читается", !te && !!t, te?.message);
if (t) {
  const { data: svcs } = await sb.from("services").select("id, name").eq("tenant_id", t.id).eq("active", true).order("sort");
  check("есть активные услуги", (svcs?.length ?? 0) > 0);
  if (svcs?.length) {
    const today = new Date().toISOString().slice(0, 10);
    const { data: av, error: ae } = await sb.rpc("get_availability", { p_slug: slug, p_service_id: svcs[0].id, p_from: today, p_days: 14 });
    check("get_availability отвечает", !ae && Array.isArray(av), ae?.message);
    check("есть свободное время на 2 недели", Array.isArray(av) && av.some((x: { free: boolean }) => x.free));
  }
  for (const table of ["bookings", "payments", "notification_jobs", "push_subscriptions", "resource_occupancies"]) {
    const { error } = await sb.from(table).select("id").limit(1);
    check(`anon не читает ${table}`, !!error);
  }
  console.log(`Режим студии: ${t.mode}${t.mode === "preview" ? " (образец: демо-данные, без реальных уведомлений)" : ""}`);
}

// ---------- сквозной сценарий ----------
if (flag("e2e")) {
  const r = spawnSync("pnpm", ["exec", "playwright", "test", "e2e/booking-flow.spec.ts"], { stdio: "inherit", env: { ...process.env, BASE_URL: base, TENANT: slug } });
  check("Playwright: запись → видна владельцу", r.status === 0);
}

for (const r of results) console.log(`${r.ok ? "✓" : "✗"} ${r.name}${!r.ok && r.detail ? ` — ${r.detail}` : ""}`);
const bad = results.filter((r) => !r.ok).length;
console.log(bad ? `\nНе прошло проверок: ${bad}` : `\nВсе проверки пройдены: ${results.length}`);
process.exit(bad ? 1 : 0);
