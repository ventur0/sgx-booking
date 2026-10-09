/**
 * pnpm tenant:validate [<slug>] [--live]
 * Проверяет business.json (схема, ключи, ресурсы услуг, демо-записи), картинки (наличие, размер, формат)
 * и, с --live, готовность к реальным клиентам (оператор ПД, настоящий телефон, фото).
 * Без аргумента проверяет все студии.
 */
import { join } from "node:path";
import sharp from "sharp";
import { flag, listTenants, tenantDir, validateTenant } from "./lib";

const slugs = process.argv[2] && !process.argv[2].startsWith("--") ? [process.argv[2]] : listTenants();
let failed = 0;
for (const slug of slugs) {
  const v = validateTenant(slug);
  if (v.ok && v.business) {
    const b = v.business;
    const check = async (path: string, minW: number, label: string) => {
      try {
        const m = await sharp(join(tenantDir(slug), path)).metadata();
        if (m.format !== "svg" && (m.width ?? 0) < minW) v.warnings.push(`${label} ${path}: ширина ${m.width}px, лучше от ${minW}px`);
      } catch {
        v.errors.push(`${label} ${path}: файл не читается как изображение`);
      }
    };
    await check(b.images.hero, 1600, "Главное фото");
    await check(b.images.logo, 512, "Логотип");
    for (const w of b.works) await check(w.image, 800, "Фото работы");
    if (flag("live")) v.errors.push(...v.liveIssues);
  }
  const ok = v.errors.length === 0;
  console.log(`${ok ? "✓" : "✗"} ${slug}`);
  v.errors.forEach((e) => console.log(`    ✗ ${e}`));
  v.warnings.forEach((w) => console.log(`    ! ${w}`));
  if (!flag("live") && v.liveIssues.length) console.log(`    до live: ${v.liveIssues.join("; ")}`);
  if (!ok) failed++;
}
if (failed) {
  console.error(`\nСтудий с ошибками: ${failed}`);
  process.exit(1);
}
