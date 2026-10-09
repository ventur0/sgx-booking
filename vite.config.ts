import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import { VitePWA } from "vite-plugin-pwa";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = import.meta.dirname;

export default defineConfig({
  plugins: [
    react(),
    // Манифест у каждой студии свой (dist/s/<slug>/manifest.webmanifest, scripts/build-tenants.ts),
    // поэтому плагин собирает только service worker.
    VitePWA({
      strategies: "injectManifest",
      srcDir: "src",
      filename: "sw.ts",
      injectRegister: false,
      manifest: false,
      injectManifest: { globPatterns: ["**/*.{js,css,html,woff2}"] },
      devOptions: { enabled: false },
    }),
    {
      // В режиме разработки отдаём фото студий из tenants/<slug>/photos по адресу /s/<slug>/photos.
      // В сборке их копирует scripts/build-tenants.ts.
      name: "tenant-photos-dev",
      configureServer(server) {
        server.middlewares.use((req, res, next) => {
          const m = req.url?.match(/^\/s\/([a-z0-9-]+)\/(photos\/[^?]+)/);
          if (!m) return next();
          const file = resolve(root, "tenants", m[1], decodeURIComponent(m[2]));
          if (!file.startsWith(resolve(root, "tenants")) || !existsSync(file)) return next();
          res.setHeader("Content-Type", file.endsWith(".svg") ? "image/svg+xml" : file.endsWith(".png") ? "image/png" : "image/jpeg");
          res.end(readFileSync(file));
        });
      },
    },
  ],
  test: {
    include: ["tests/**/*.test.ts"],
    environment: "node",
  },
});
