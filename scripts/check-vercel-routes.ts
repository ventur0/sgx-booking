/**
 * Проверка .vercel/output/config.json без Vercel: упрощённо повторяет его маршрутизацию
 * (заголовки с continue, статусы, handle: filesystem, rewrite на файл или внешний адрес)
 * и сверяет результат для ключевых адресов. Запуск: `tsx scripts/check-vercel-routes.ts` после `pnpm build:vercel`.
 */
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

// Без ./lib (zod не нужен): тот же список студий, что и у build-shells — папки tenants/* с business.json, кроме _*.
const ROOT = join(import.meta.dirname, "..");
const listTenants = () =>
  readdirSync(join(ROOT, "tenants"), { withFileTypes: true })
    .filter((d) => d.isDirectory() && !d.name.startsWith("_") && existsSync(join(ROOT, "tenants", d.name, "business.json")))
    .map((d) => d.name)
    .sort();

type Route = { src?: string; dest?: string; status?: number; headers?: Record<string, string>; continue?: boolean; handle?: string };
const OUT = join(ROOT, ".vercel", "output");
const STATIC = join(OUT, "static");
const { version, routes } = JSON.parse(readFileSync(join(OUT, "config.json"), "utf8")) as { version: number; routes: Route[] };

const fileFor = (path: string): string | null => {
  const p = decodeURIComponent(path);
  const f = join(STATIC, p);
  if (existsSync(f) && statSync(f).isFile()) return p;
  const idx = join(f, "index.html");
  if (existsSync(idx)) return join(p, "index.html");
  return null;
};

type Result = { kind: "file" | "external" | "status" | "miss"; target?: string; status?: number; headers: Record<string, string> };
function resolve(path: string): Result {
  const headers: Record<string, string> = {};
  for (const r of routes) {
    if (r.handle === "filesystem") {
      const f = fileFor(path);
      if (f) return { kind: "file", target: f, headers };
      continue;
    }
    if (!r.src) continue;
    const m = path.match(new RegExp(r.src));
    if (!m) continue;
    const sub = (s: string) => s.replace(/\$(\d)/g, (_, i) => m[Number(i)] ?? "");
    if (r.headers) for (const [k, v] of Object.entries(r.headers)) headers[k] = sub(v);
    if (r.continue) continue;
    if (r.status) return { kind: "status", status: r.status, headers };
    if (r.dest) {
      const d = sub(r.dest);
      if (/^https?:\/\//.test(d)) return { kind: "external", target: d, headers };
      const f = fileFor(d);
      return f ? { kind: "file", target: f, headers } : { kind: "miss", target: d, headers };
    }
  }
  return { kind: "miss", headers };
}

let bad = 0;
const check = (name: string, ok: boolean, got: unknown) => {
  if (!ok) bad++;
  console.log(`${ok ? "✓" : "✗"} ${name}${ok ? "" : ` — получено ${JSON.stringify(got)}`}`);
};

check("Build Output API v3", version === 3, version);
const slugs = listTenants();
const slug = slugs[0];
for (const s of [slug, slugs[slugs.length - 1]]) {
  for (const p of [`/s/${s}/`, `/s/${s}/owner/`, `/s/${s}/my`, `/s/${s}/services`]) {
    const r = resolve(p);
    check(`${p} → /t/${s}/index.html`, r.kind === "file" && r.target === `/t/${s}/index.html` && r.headers["Cache-Control"] === "no-cache", r);
  }
}
{
  const r = resolve(`/s/${slug}`);
  check(`/s/${slug} → 308 на /s/${slug}/`, r.kind === "status" && r.status === 308 && r.headers.Location === `/s/${slug}/`, r);
}
{
  const r = resolve("/s/studiya-iz-paneli/owner/");
  check("студия только в БД → общая оболочка /index.html", r.kind === "file" && r.target === "/index.html", r);
}
{
  const r = resolve(`/t/${slug}/sw.js`);
  check("service worker студии с Service-Worker-Allowed", r.kind === "file" && r.headers["Service-Worker-Allowed"] === "/", r);
}
{
  const r = resolve(`/t/${slug}/manifest.webmanifest`);
  check("манифест студии", r.kind === "file" && r.headers["Content-Type"] === "application/manifest+json", r);
}
{
  const r = resolve(`/t/${slug}/icon-512.png`);
  check("иконка 512 отдаётся как файл", r.kind === "file", r);
}
{
  const r = resolve("/sb/rest/v1/tenants");
  check("/sb/rest/v1/* → Supabase", r.kind === "external" && /^https:\/\/[a-z0-9-]+\.supabase\.co\/rest\/v1\/tenants$/.test(r.target ?? ""), r);
  const a = resolve("/sb/auth/v1/token");
  check("/sb/auth/v1/* → Supabase", a.kind === "external" && (a.target ?? "").endsWith("/auth/v1/token"), a);
}
{
  const r = resolve("/sb/realtime/v1/websocket");
  check("/sb/realtime закрыт (WebSocket идёт напрямую)", r.kind === "status" && r.status === 404, r);
  const x = resolve("/sb/../etc/passwd");
  check("/sb с чужим путём → 404", x.kind === "status" && x.status === 404, x);
}
{
  const r = resolve("/admin");
  check("/admin → SPA /index.html", r.kind === "file" && r.target === "/index.html", r);
  check("заголовки безопасности", r.headers["X-Content-Type-Options"] === "nosniff", r.headers);
}
for (const f of ["_redirects", "_headers", "_routes.json"]) check(`нет ${f} в static`, !existsSync(join(STATIC, f)), f);

if (bad) {
  console.error(`\nОшибок: ${bad}`);
  process.exit(1);
}
console.log(`\nМаршруты Vercel в порядке (${slugs.length} студий)`);
