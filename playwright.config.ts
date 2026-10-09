import { defineConfig, devices } from "@playwright/test";

const BASE_URL = process.env.BASE_URL ?? "http://localhost:4173";

export default defineConfig({
  testDir: "e2e",
  timeout: 60_000,
  retries: 0,
  reporter: [["list"], ["html", { open: "never" }]],
  use: { baseURL: BASE_URL, trace: "retain-on-failure", locale: "ru-RU" },
  projects: [
    { name: "phone", use: { ...devices["Pixel 7"] } },
    { name: "desktop", use: { ...devices["Desktop Chrome"], viewport: { width: 1366, height: 900 } } },
  ],
  webServer: process.env.BASE_URL ? undefined : { command: "pnpm build && pnpm preview --port 4173", port: 4173, reuseExistingServer: true, timeout: 180_000 },
});
