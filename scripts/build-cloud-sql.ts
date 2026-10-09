/**
 * pnpm cloud-sql — собирает supabase/cloud-setup.sql: все миграции + демо-студии одним файлом,
 * чтобы вставить его в SQL Editor облачного Supabase и нажать Run.
 * Демо-владельцы с известным паролем в облачный файл НЕ попадают: владельца создают в Authentication → Add user.
 */
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT } from "./lib";

const dir = join(ROOT, "supabase", "migrations");
const parts = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort().map((f) => `-- ===== ${f} =====\n${readFileSync(join(dir, f), "utf8")}`);
const seed = readFileSync(join(ROOT, "supabase", "seed.sql"), "utf8");
const cut = seed.indexOf("-- ===== демо-владельцы");
parts.push(`-- ===== демо-студии (seed без локальных владельцев) =====\n${cut > 0 ? seed.slice(0, cut) : seed}`);
writeFileSync(join(ROOT, "supabase", "cloud-setup.sql"), parts.join("\n\n"));
console.log("✓ supabase/cloud-setup.sql");
