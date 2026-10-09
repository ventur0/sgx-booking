/**
 * pnpm tenant:publish <slug> [--live] [--overwrite]
 *
 * Переносит tenants/<slug>/business.json и картинки в Supabase (service role, только на вашем компьютере).
 *  - Новая студия создаётся в режиме preview с помеченными демо-записями; реальные уведомления не шлются.
 *  - Повторная публикация НЕ трогает записи, оплаты и фото, загруженные владельцем.
 *    Тексты, цены и часы, которые владелец мог поменять в кабинете, перезаписываются только с --overwrite.
 *    Услуги и посты, убранные из файла, не удаляются, а выключаются (на них ссылаются старые записи).
 *  - --live: проверяет готовность (оператор ПД, телефон, фото), удаляет демо-записи и включает live.
 *  - Создаёт владельцу вход (без публичной регистрации) и членство в студии.
 * После публикации: pnpm build && pnpm deploy — оболочка студии /t/<slug>/ (иконки, манифест).
 */
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { createClient } from "@supabase/supabase-js";
import { configExceptions, fail, flag, requireEnv, tenantDir, validateTenant } from "./lib";
import { WEEKDAY_KEYS } from "../src/shared/business";

const slug = process.argv[2];
if (!slug || slug.startsWith("--")) fail("pnpm tenant:publish <slug> [--live] [--overwrite]");
const v = validateTenant(slug);
if (!v.ok || !v.business) fail(`Сначала исправьте ошибки:\n${v.errors.map((e) => "  ✗ " + e).join("\n")}`);
const b = v.business;
if (flag("live") && v.liveIssues.length) fail(`Для live не хватает:\n${v.liveIssues.map((e) => "  – " + e).join("\n")}`);

const sb = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false, autoRefreshToken: false } });
const must = <T>(r: { data: T; error: unknown }, what: string): T => {
  if (r.error) fail(`${what}: ${(r.error as { message?: string }).message ?? r.error}`);
  return r.data;
};

// ---------- 1. студия ----------
const existing = must(await sb.from("tenants").select("id, mode, profile").eq("slug", slug).maybeSingle(), "чтение студии");
const isNew = !existing;
let tenantId: string;
if (isNew) {
  const row = must(await sb.from("tenants").insert({ slug, timezone: b.timezone, mode: "preview", profile: { ...b.profile } }).select("id").single(), "создание студии");
  tenantId = (row as { id: string }).id;
} else {
  tenantId = existing.id as string;
}

// ---------- 2. картинки → Storage (папка config; папку owner публикация не трогает) ----------
const upload = async (rel: string) => {
  const file = join(tenantDir(slug), rel);
  const name = `${tenantId}/config/${basename(rel)}`;
  const type = rel.endsWith(".svg") ? "image/svg+xml" : rel.endsWith(".png") ? "image/png" : rel.endsWith(".webp") ? "image/webp" : "image/jpeg";
  must(await sb.storage.from("tenant-media").upload(name, readFileSync(file), { upsert: true, contentType: type, cacheControl: "3600" }), `загрузка ${rel}`);
  return sb.storage.from("tenant-media").getPublicUrl(name).data.publicUrl;
};
const heroUrl = await upload(b.images.hero);
const logoUrl = await upload(b.images.logo);

const prevProfile = (existing?.profile ?? {}) as { media?: { hero?: string; logo?: string } };
const isOwnerUrl = (u?: string) => !!u && u.includes(`/${tenantId}/owner/`);
const media = {
  hero: isOwnerUrl(prevProfile.media?.hero) ? prevProfile.media!.hero! : heroUrl,
  logo: isOwnerUrl(prevProfile.media?.logo) ? prevProfile.media!.logo! : logoUrl,
};
const overwrite = isNew || flag("overwrite");
const profile = overwrite ? { ...b.profile, media } : { ...(existing!.profile as object), media, legal: (existing!.profile as { legal?: unknown }).legal ?? b.profile.legal };
must(await sb.from("tenants").update({ profile, timezone: overwrite ? b.timezone : undefined }).eq("id", tenantId), "профиль");

// ---------- 3. посты и услуги (upsert по key; убранные — выключаются) ----------
const resRows = must(
  await sb.from("resources").upsert(b.resources.map((r, i) => ({ tenant_id: tenantId, key: r.key, name: r.name, sort: i, active: true })), { onConflict: "tenant_id,key", ignoreDuplicates: !overwrite }).select("id, key"),
  "посты",
) as { id: string; key: string }[];
must(await sb.from("resources").update({ active: false }).eq("tenant_id", tenantId).not("key", "in", `(${b.resources.map((r) => r.key).join(",")})`), "выключение лишних постов");
const allRes = must(await sb.from("resources").select("id, key").eq("tenant_id", tenantId), "посты") as { id: string; key: string }[];
void resRows;

if (overwrite) {
  must(
    await sb.from("services").upsert(
      b.services.map((s, i) => ({ tenant_id: tenantId, key: s.key, name: s.name, description: s.description, price: s.price, duration_min: s.durationMin, active: s.active, sort: i })),
      { onConflict: "tenant_id,key" },
    ),
    "услуги",
  );
  must(await sb.from("services").update({ active: false }).eq("tenant_id", tenantId).not("key", "in", `(${b.services.map((s) => s.key).join(",")})`), "выключение лишних услуг");
  const svcs = must(await sb.from("services").select("id, key").eq("tenant_id", tenantId), "услуги") as { id: string; key: string }[];
  for (const s of b.services) {
    const sid = svcs.find((x) => x.key === s.key)!.id;
    must(await sb.from("service_resources").delete().eq("service_id", sid), "посты услуги");
    if (s.resources?.length)
      must(await sb.from("service_resources").insert(s.resources.map((rk) => ({ tenant_id: tenantId, service_id: sid, resource_id: allRes.find((r) => r.key === rk)!.id }))), "посты услуги");
  }
  // ---------- 4. часы работы ----------
  must(await sb.from("working_hours").delete().eq("tenant_id", tenantId), "часы");
  const hours = WEEKDAY_KEYS.flatMap((k, wd) => (b.hours[k] ? [{ tenant_id: tenantId, weekday: wd, opens: b.hours[k]!.opens, closes: b.hours[k]!.closes }] : []));
  must(await sb.from("working_hours").insert(hours), "часы");
} else if (isNew === false) {
  // новые услуги из файла добавляются и при обычной публикации
  must(
    await sb.from("services").upsert(
      b.services.map((s, i) => ({ tenant_id: tenantId, key: s.key, name: s.name, description: s.description, price: s.price, duration_min: s.durationMin, active: s.active, sort: i })),
      { onConflict: "tenant_id,key", ignoreDuplicates: true },
    ),
    "новые услуги",
  );
}

// ---------- 5. праздники и исключения из конфига (исключения владельца не трогаем) ----------
must(await sb.from("schedule_exceptions").delete().eq("tenant_id", tenantId).eq("source", "config"), "исключения");
const ex = configExceptions(b).map((e) => ({ tenant_id: tenantId, ...e, source: "config" }));
if (ex.length) must(await sb.from("schedule_exceptions").upsert(ex, { onConflict: "tenant_id,day", ignoreDuplicates: true }), "исключения");

// ---------- 6. фото работ: config-карточки обновляются, карточки владельца остаются ----------
const works = [];
for (const [i, w] of b.works.entries()) works.push({ tenant_id: tenantId, key: w.key, photo_url: await upload(w.image), caption: w.caption, sort: i, source: "config" });
if (overwrite) {
  must(await sb.from("works").delete().eq("tenant_id", tenantId).eq("source", "config").not("key", "in", `(${b.works.map((w) => w.key).join(",") || "-"})`), "лишние работы");
  if (works.length) must(await sb.from("works").upsert(works, { onConflict: "tenant_id,key" }), "работы");
} else if (works.length) {
  must(await sb.from("works").upsert(works, { onConflict: "tenant_id,key", ignoreDuplicates: true }), "работы");
}

// ---------- 7. владелец: вход без публичной регистрации ----------
let ownerId: string | null = null;
for (let page = 1; page < 100 && !ownerId; page++) {
  const { data, error } = await sb.auth.admin.listUsers({ page, perPage: 200 });
  if (error) fail(`пользователи: ${error.message}`);
  ownerId = data.users.find((u) => u.email?.toLowerCase() === b.owner.email.toLowerCase())?.id ?? null;
  if (data.users.length < 200) break;
}
let tempPassword: string | null = null;
if (!ownerId) {
  tempPassword = randomBytes(12).toString("base64url");
  const { data, error } = await sb.auth.admin.createUser({ email: b.owner.email, password: tempPassword, email_confirm: true });
  if (error) fail(`создание владельца: ${error.message}`);
  ownerId = data.user.id;
}
must(await sb.from("tenant_members").upsert({ tenant_id: tenantId, user_id: ownerId, role: "owner" }, { onConflict: "tenant_id,user_id" }), "членство");

// ---------- 8. демо-записи (только preview) или переход в live ----------
const mode = flag("live") ? "live" : ((existing?.mode as string) ?? "preview");
if (mode === "preview") {
  for (const [i, d] of b.demo.bookings.entries()) {
    must(
      await sb.rpc("admin_insert_demo_booking", {
        p_tenant: tenantId, p_label: `demo-${i}`, p_service_key: d.service, p_resource_key: d.resource ?? null,
        p_day_offset: d.dayOffset, p_time: d.time, p_name: d.name, p_phone: d.phone, p_car: d.car, p_status: d.status, p_payments: d.payments,
      }),
      `демо-запись ${i}`,
    );
  }
} else if (existing?.mode !== "live") {
  if (!profile.legal) must(await sb.from("tenants").update({ profile: { ...profile, legal: b.profile.legal } }).eq("id", tenantId), "оператор ПД");
  const removed = must(await sb.rpc("admin_go_live", { p_tenant: tenantId }), "переход в live");
  console.log(`  демо-записей удалено: ${removed}`);
}

const site = process.env.PUBLIC_SITE_URL ?? "https://<ваш-домен>";
console.log(`✓ ${slug}: ${isNew ? "создана" : "обновлена"}, режим ${mode}${!overwrite ? " (настройки владельца сохранены; --overwrite перезапишет)" : ""}`);
console.log(`  Клиентам:  ${site}/s/${slug}/`);
console.log(`  Владельцу: ${site}/s/${slug}/owner/   вход: ${b.owner.email}${tempPassword ? `   временный пароль: ${tempPassword}` : " (аккаунт уже был)"}`);
console.log(`  Дальше: pnpm build && pnpm deploy, затем pnpm tenant:verify ${slug}`);
