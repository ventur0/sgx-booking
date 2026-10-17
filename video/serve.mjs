// Локальный сервер собранного сайта для записи видео: как на хостинге, /s/<slug>/* → оболочка /t/<slug>/.
import { createServer } from "node:http";
import { existsSync, readFileSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const DIST = join(process.cwd(), "dist");
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png",
  ".jpg": "image/jpeg", ".webp": "image/webp", ".woff2": "font/woff2", ".json": "application/json", ".webmanifest": "application/manifest+json" };
const file = (p) => { const f = normalize(join(DIST, p)); return f.startsWith(DIST) && existsSync(f) && statSync(f).isFile() ? f : null; };

createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  let p = decodeURIComponent(url.pathname);
  let f = file(p) ?? file(join(p, "index.html"));
  const m = p.match(/^\/s\/([a-z0-9-]+)\/?/);
  if (m && !p.endsWith("/") && p === `/s/${m[1]}`) { res.writeHead(301, { Location: `/s/${m[1]}/` }); return res.end(); }
  if (!f && m) f = file(`/t/${m[1]}/index.html`) ?? file("/index.html");
  if (!f) f = file("/index.html");
  const headers = { "Content-Type": TYPES[extname(f)] ?? "application/octet-stream", "Cache-Control": "no-cache" };
  if (/\/t\/[^/]+\/sw\.js$/.test(f)) headers["Service-Worker-Allowed"] = "/";
  res.writeHead(200, headers);
  res.end(readFileSync(f));
}).listen(4173, () => console.log("http://localhost:4173"));
