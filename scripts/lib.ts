import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { BusinessSchema, liveReadiness, type Business } from "../src/shared/business";
import { upcomingHolidays } from "../src/shared/by";

export const ROOT = resolve(import.meta.dirname, "..");
export const TENANTS_DIR = join(ROOT, "tenants");
export const tenantDir = (slug: string) => join(TENANTS_DIR, slug);

export function listTenants(): string[] {
  return readdirSync(TENANTS_DIR, { withFileTypes: true })
    .filter((d) => d.isDirectory() && !d.name.startsWith("_") && existsSync(join(TENANTS_DIR, d.name, "business.json")))
    .map((d) => d.name)
    .sort();
}

export type Validation = { ok: boolean; errors: string[]; warnings: string[]; liveIssues: string[]; business?: Business };

/** Схема business.json + наличие картинок + согласованность slug и папки. */
export function validateTenant(slug: string): Validation {
  const errors: string[] = [];
  const warnings: string[] = [];
  const file = join(tenantDir(slug), "business.json");
  if (!existsSync(file)) return { ok: false, errors: [`Нет файла ${file}`], warnings, liveIssues: [] };
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(file, "utf8"));
  } catch (e) {
    return { ok: false, errors: [`business.json не читается: ${(e as Error).message}`], warnings, liveIssues: [] };
  }
  const parsed = BusinessSchema.safeParse(raw);
  if (!parsed.success) {
    for (const i of parsed.error.issues) errors.push(`${i.path.join(".") || "(корень)"}: ${i.message}`);
    return { ok: false, errors, warnings, liveIssues: [] };
  }
  const b = parsed.data;
  if (b.slug !== slug) errors.push(`slug = «${b.slug}», а папка называется «${slug}»`);
  for (const img of [b.images.hero, b.images.logo, ...b.works.map((w) => w.image)]) {
    if (!existsSync(join(tenantDir(slug), img))) errors.push(`Нет картинки ${img}`);
  }
  if (b.timezone !== "Europe/Minsk") warnings.push(`Часовой пояс ${b.timezone}, а не Europe/Minsk`);
  if (!b.services.some((s) => s.active)) errors.push("Нет ни одной активной услуги");
  return { ok: errors.length === 0, errors, warnings, liveIssues: liveReadiness(b), business: b };
}

/** Выходные дни из конфига: явные исключения + государственные праздники РБ на 18 месяцев. */
export function configExceptions(b: Business, today = new Date().toISOString().slice(0, 10)) {
  const map = new Map<string, { day: string; closed: boolean; opens: string | null; closes: string | null; note: string }>();
  if (b.holidays) for (const h of upcomingHolidays(today, 548)) map.set(h.date, { day: h.date, closed: true, opens: null, closes: null, note: h.name });
  for (const e of b.exceptions) map.set(e.day, { day: e.day, closed: e.closed, opens: e.opens ?? null, closes: e.closes ?? null, note: e.note });
  return [...map.values()].sort((a, c) => a.day.localeCompare(c.day));
}

export function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 ? process.argv[i + 1] : undefined;
}
export const flag = (name: string) => process.argv.includes(`--${name}`);
export function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) {
    console.error(`Нужна переменная окружения ${name} (см. .env.example)`);
    process.exit(1);
  }
  return v;
}
export function fail(msg: string): never {
  console.error(msg);
  process.exit(1);
}
