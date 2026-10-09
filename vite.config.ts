import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import { VitePWA } from "vite-plugin-pwa";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = import.meta.dirname;

export default defineConfig({
  // студия по умолчанию для корня сайта (переменная DEFAULT_TENANT в Cloudflare)
  define: { __DEFAULT_TENANT__: JSON.stringify(process.env.DEFAULT_TENANT ?? "graphite") },
  plugins: [
    react(),
    // Только service worker: манифесты, иконки и оболочки студий генерирует scripts/build-shells.ts.
    VitePWA({
      strategies: "injectManifest",
      srcDir: "src",
      filename: "sw.ts",
      injectRegister: false,
      manifest: false,
      injectManifest: { globPatterns: ["assets/**/*.{js,css,woff2}"] },
      devOptions: { enabled: false },
    }),
    {
      // Разработка: /t/<slug>/media/* берём из tenants/<slug>/images (в сборке их копирует build-shells).
      name: "tenant-media-dev",
      configureServer(server) {
        server.middlewares.use((req, res, next) => {
          const m = req.url?.match(/^\/t\/(_default|[a-z0-9-]+)\/media\/([^?]+)/);
          if (!m) return next();
          const file = resolve(root, "tenants", m[1] === "_default" ? "_template" : m[1], "images", decodeURIComponent(m[2]));
          if (!file.startsWith(resolve(root, "tenants")) || !existsSync(file)) return next();
          res.setHeader("Content-Type", file.endsWith(".svg") ? "image/svg+xml" : file.endsWith(".png") ? "image/png" : "image/jpeg");
          res.end(readFileSync(file));
        });
      },
    },
  ],
  test: { include: ["tests/unit/**/*.test.ts"], environment: "node" },
});
