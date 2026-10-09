import { defineConfig, devices } from "@playwright/test";

// BASE_URL — опубликованный сайт или `pnpm preview` (wrangler pages dev dist) на 4173.
export default defineConfig({
  testDir: "e2e",
  timeout: 90_000,
  retries: 0,
  reporter: [["list"], ["html", { open: "never" }]],
  use: { baseURL: process.env.BASE_URL ?? "http://localhost:4173", trace: "retain-on-failure", locale: "ru-RU", timezoneId: "Europe/Minsk" },
  projects: [
    { name: "phone", use: { ...devices["Pixel 7"] } },
    { name: "desktop", use: { ...devices["Desktop Chrome"], viewport: { width: 1366, height: 900 } } },
  ],
});
