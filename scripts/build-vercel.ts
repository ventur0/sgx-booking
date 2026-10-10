/**
 * Запускается после `pnpm build` (команда `pnpm build:vercel`, её вызывает Vercel).
 * Собирает готовый вывод для Vercel (Build Output API v3) в .vercel/output/ из dist/:
 *   static/       — тот же сайт, что и для Cloudflare (оболочки студий в /t/<slug>/)
 *   config.json   — маршруты и заголовки вместо dist/_redirects, dist/_headers и functions/sb
 *
 * Маршруты:
 *   /sb/{rest,auth,storage,functions}/v1/* → проксируются на Supabase проекта (адрес из VITE_SUPABASE_URL)
 *   /s/<slug>                               → 308 на /s/<slug>/
 *   /s/<slug>/*                             → оболочка /t/<slug>/index.html (студии из tenants/)
 *   /s/<другая>/*                           → общая оболочка /index.html (студии из панели продавца, только в БД)
 *   остальное без файла                     → /index.html (как SPA-фолбэк Cloudflare Pages)
 * Realtime (WebSocket) Vercel не проксирует: на Vercel кабинет подключается к Realtime напрямую (см. src/lib/supabase.ts).
 */
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";

// Без ./lib (zod не нужен): тот же список студий, что и у build-shells — папки tenants/* с business.json, кроме _*.
const ROOT = join(import.meta.dirname, "..");
const listTenants = () =>
  readdirSync(join(ROOT, "tenants"), { withFileTypes: true })
    .filter((d) => d.isDirectory() && !d.name.startsWith("_") && existsSync(join(ROOT, "tenants", d.name, "business.json")))
    .map((d) => d.name)
    .sort();

const DIST = join(ROOT, "dist");
const OUT = join(ROOT, ".vercel", "output");

if (!existsSync(join(DIST, "index.html")) || !existsSync(join(DIST, "t"))) {
  console.error("Сначала pnpm build (нужны dist/index.html и dist/t/)");
  process.exit(1);
}

const slugs = listTenants();
for (const s of slugs) {
  if (!/^[a-z0-9-]+$/.test(s)) throw new Error(`Недопустимый slug: ${s}`);
  if (!existsSync(join(DIST, "t", s, "index.html"))) throw new Error(`Нет оболочки dist/t/${s}/index.html — запустите pnpm build`);
}

const upstream = (process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL || "").replace(/\/+$/, "");
const proxyOk = /^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(upstream);
if (!proxyOk) console.warn(`⚠ VITE_SUPABASE_URL не похож на https://<ref>.supabase.co ("${upstream}") — /sb не будет работать`);

rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });
const SKIP = new Set(["_redirects", "_headers", "_routes.json", ".shell-template.html"]);
cpSync(DIST, join(OUT, "static"), { recursive: true, filter: (src) => !SKIP.has(basename(src)) });

type Route = Record<string, unknown>;
const security = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
};
const routes: Route[] = [
  // ---------- заголовки (continue: маршрутизация идёт дальше) ----------
  { src: "^/.*$", headers: security, continue: true },
  { src: "^/t/[^/]+/sw\\.js$", headers: { "Service-Worker-Allowed": "/", "Cache-Control": "no-cache" }, continue: true },
  { src: "^/t/[^/]+/manifest\\.webmanifest$", headers: { "Content-Type": "application/manifest+json", "Cache-Control": "no-cache" }, continue: true },
  { src: "^/(s/.*|t/[^/]+/(index\\.html)?|index\\.html)?$", headers: { "Cache-Control": "no-cache" }, continue: true },
  { src: "^/assets/.*$", headers: { "Cache-Control": "public, max-age=31536000, immutable" }, continue: true },

  // ---------- прокси к Supabase через адрес сайта ----------
  ...(proxyOk ? [{ src: "^/sb/((?:rest|auth|storage|functions)/v1(?:/.*)?)$", dest: `${upstream}/$1` }] : []),
  { src: "^/sb(?:/.*)?$", status: 404 },

  // ---------- адреса студий ----------
  { src: "^/s/([a-z0-9-]+)$", status: 308, headers: { Location: "/s/$1/" } },
  { handle: "filesystem" },
  { src: `^/s/(${slugs.join("|")})/.*$`, dest: "/t/$1/index.html" },
  { src: "^/s/[^/]+/.*$", dest: "/index.html" },
  { src: "^/.*$", dest: "/index.html" },
];

writeFileSync(join(OUT, "config.json"), JSON.stringify({ version: 3, routes }, null, 2) + "\n");
console.log(`✓ .vercel/output: ${slugs.length} студий, прокси /sb → ${proxyOk ? upstream : "выключен"}`);
