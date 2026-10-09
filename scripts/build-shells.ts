/**
 * Запускается после vite build (pnpm build). Для каждой студии из tenants/ создаёт в dist/t/<slug>/:
 *   index.html                — оболочка с метаданными студии (title, description, theme-color, manifest, иконки)
 *   manifest.webmanifest      — id/start_url/scope = /s/<slug>/, своя иконка и maskable-иконка
 *   icon-192.png, icon-512.png, maskable-512.png, apple-touch-icon.png, favicon.png
 *   startup/*.png             — заставки iOS для установленного приложения
 *   media/*                   — картинки из business.json (для preview и локального запуска)
 *   sw.js                     — копия общего service worker; scope /s/<slug>/, свои имена кэшей
 * А также dist/_redirects и dist/_headers для Cloudflare Pages.
 * JS/CSS-бандл один на всех: в оболочке меняются только метаданные.
 */
import { copyFileSync, cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import sharp from "sharp";
import { ROOT, listTenants, tenantDir, validateTenant } from "./lib";

const DIST = join(ROOT, "dist");
const BG = "#050607";
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// iOS: размеры экранов в CSS-пикселях и плотность (портрет)
const STARTUP = [
  { w: 430, h: 932, r: 3 }, // 14/15/16 Pro Max, Plus
  { w: 393, h: 852, r: 3 }, // 14/15/16 Pro, 15/16
  { w: 390, h: 844, r: 3 }, // 12/13/14
  { w: 375, h: 812, r: 3 }, // X/XS/11 Pro/mini
  { w: 414, h: 896, r: 2 }, // XR/11
  { w: 375, h: 667, r: 2 }, // SE 2/3, 8
];

async function iconFrom(logo: string, size: number, padding: number, out: string) {
  const inner = Math.round(size * (1 - padding * 2));
  const img = await sharp(logo, { density: 384 }).resize(inner, inner, { fit: "contain", background: BG }).png().toBuffer();
  await sharp({ create: { width: size, height: size, channels: 4, background: BG } })
    .composite([{ input: img, gravity: "center" }])
    .png()
    .toFile(out);
}

async function buildTenant(slug: string, template: string) {
  const v = validateTenant(slug);
  if (!v.ok || !v.business) throw new Error(`${slug}: ${v.errors.join("; ")}`);
  const b = v.business;
  const out = join(DIST, "t", slug);
  mkdirSync(join(out, "startup"), { recursive: true });
  cpSync(join(tenantDir(slug), "images"), join(out, "media"), { recursive: true });

  const logo = join(tenantDir(slug), b.images.logo);
  await iconFrom(logo, 192, 0, join(out, "icon-192.png"));
  await iconFrom(logo, 512, 0, join(out, "icon-512.png"));
  await iconFrom(logo, 512, 0.12, join(out, "maskable-512.png")); // безопасная зона maskable — 80%
  await iconFrom(logo, 180, 0.06, join(out, "apple-touch-icon.png"));
  await iconFrom(logo, 64, 0, join(out, "favicon.png"));

  const startupLinks: string[] = [];
  for (const s of STARTUP) {
    const W = s.w * s.r, H = s.h * s.r;
    const name = `startup/${W}x${H}.png`;
    const logoPx = Math.round(Math.min(W, H) * 0.28);
    const img = await sharp(logo, { density: 384 }).resize(logoPx, logoPx, { fit: "contain", background: BG }).png().toBuffer();
    await sharp({ create: { width: W, height: H, channels: 4, background: BG } }).composite([{ input: img, gravity: "center" }]).png().toFile(join(out, name));
    startupLinks.push(`<link rel="apple-touch-startup-image" href="/t/${slug}/${name}" media="(device-width: ${s.w}px) and (device-height: ${s.h}px) and (-webkit-device-pixel-ratio: ${s.r}) and (orientation: portrait)" />`);
  }

  const manifest = {
    id: `/s/${slug}/`,
    name: b.profile.name,
    short_name: b.profile.shortName ?? b.profile.name.slice(0, 12),
    description: b.profile.tagline,
    lang: "ru-BY",
    dir: "ltr",
    start_url: `/s/${slug}/`,
    scope: `/s/${slug}/`,
    display: "standalone",
    background_color: BG,
    theme_color: BG,
    icons: [
      { src: `/t/${slug}/icon-192.png`, sizes: "192x192", type: "image/png", purpose: "any" },
      { src: `/t/${slug}/icon-512.png`, sizes: "512x512", type: "image/png", purpose: "any" },
      { src: `/t/${slug}/maskable-512.png`, sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  };
  writeFileSync(join(out, "manifest.webmanifest"), JSON.stringify(manifest, null, 2));

  const head = [
    `<title>${esc(b.profile.name)} — онлайн-запись</title>`,
    `<meta name="description" content="${esc(b.profile.tagline)}" />`,
    `<meta name="sgx-tenant" content="${slug}" />`,
    `<meta name="theme-color" content="${BG}" />`,
    `<meta name="apple-mobile-web-app-title" content="${esc(manifest.short_name)}" />`,
    `<meta property="og:title" content="${esc(b.profile.name)}" />`,
    `<meta property="og:description" content="${esc(b.profile.tagline)}" />`,
    `<meta property="og:type" content="website" />`,
    `<link rel="manifest" href="/t/${slug}/manifest.webmanifest" />`,
    `<link rel="icon" type="image/png" href="/t/${slug}/favicon.png" />`,
    `<link rel="apple-touch-icon" href="/t/${slug}/apple-touch-icon.png" />`,
    ...startupLinks,
  ].join("\n    ");
  const html = template.replace(/<title>[\s\S]*?<\/title>/, "").replace("<!--tenant-head-->", head);
  writeFileSync(join(out, "index.html"), html);
  copyFileSync(join(DIST, "sw.js"), join(out, "sw.js"));
  return slug;
}

if (!existsSync(join(DIST, "index.html")) || !existsSync(join(DIST, "sw.js"))) {
  console.error("Сначала vite build (нужны dist/index.html и dist/sw.js)");
  process.exit(1);
}
// Чистый шаблон сохраняем отдельно: dist/index.html ниже получает общие иконки, а повторный запуск
// (например, `tsx scripts/build-shells.ts graphite`) должен снова найти метку <!--tenant-head-->.
const TEMPLATE = join(DIST, ".shell-template.html");
if (!existsSync(TEMPLATE)) copyFileSync(join(DIST, "index.html"), TEMPLATE);
const template = readFileSync(TEMPLATE, "utf8");
if (!template.includes("<!--tenant-head-->")) {
  console.error("В index.html нет метки <!--tenant-head-->");
  process.exit(1);
}
// Общая оболочка для студий из панели продавца (есть только в базе): картинки-заготовки и иконки.
{
  const out = join(DIST, "t", "_default");
  mkdirSync(out, { recursive: true });
  cpSync(join(tenantDir("_template"), "images"), join(out, "media"), { recursive: true });
  const logo = join(tenantDir("_template"), "images", "logo.svg");
  await iconFrom(logo, 180, 0.06, join(out, "apple-touch-icon.png"));
  await iconFrom(logo, 64, 0, join(out, "favicon.png"));
  const head = [
    `<meta name="theme-color" content="${BG}" />`,
    `<link rel="icon" type="image/png" href="/t/_default/favicon.png" />`,
    `<link rel="apple-touch-icon" href="/t/_default/apple-touch-icon.png" />`,
  ].join("\n    ");
  writeFileSync(join(DIST, "index.html"), template.replace("<!--tenant-head-->", head));
  console.log("✓ /t/_default/ — оболочка студий из панели продавца");
}

const only = process.argv[2];
const slugs = only ? [only] : listTenants();
for (const slug of slugs) {
  await buildTenant(slug, template);
  console.log(`✓ /s/${slug}/ → /t/${slug}/`);
}

// Cloudflare Pages: глубокие ссылки студии отдают её оболочку. Правила _redirects применяются
// и к существующим файлам, поэтому статика студий лежит в /t/, а не в /s/.
writeFileSync(
  join(DIST, "_redirects"),
  [
    "/s/:slug /s/:slug/ 301",
    "/s/:slug/* /t/:slug/ 200",
    // корень сайта ведёт на студию по умолчанию (DEFAULT_TENANT или первая по алфавиту)
    `/ /s/${process.env.DEFAULT_TENANT ?? listTenants()[0]}/ 302`,
    "",
  ].join("\n"),
);
writeFileSync(
  join(DIST, "_headers"),
  [
    "/t/*/sw.js",
    "  Service-Worker-Allowed: /",
    "  Cache-Control: no-cache",
    "/t/*/index.html",
    "  Cache-Control: no-cache",
    "/t/*/manifest.webmanifest",
    "  Content-Type: application/manifest+json",
    "  Cache-Control: no-cache",
    "/assets/*",
    "  Cache-Control: public, max-age=31536000, immutable",
    "/*",
    "  X-Content-Type-Options: nosniff",
    "  Referrer-Policy: strict-origin-when-cross-origin",
    "  Permissions-Policy: camera=(), microphone=(), geolocation=()",
    "",
  ].join("\n"),
);
console.log("✓ dist/_redirects, dist/_headers");
