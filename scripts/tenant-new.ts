/**
 * pnpm tenant:new <slug> --name "Название" --owner owner@mail.by [--phone "+375 29 …"] [--address "…"]
 *                        [--kind "Шиномонтаж · Гомель"] [--accent "#FF8A3D"] [--operator "ИП …" --unp 123456789]
 * Создаёт tenants/<slug>/ из шаблона: business.json + images/. Код приложения не меняется.
 */
import { cpSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { TENANTS_DIR, arg, fail, tenantDir, validateTenant } from "./lib";

const slug = process.argv[2];
if (!slug || !/^[a-z0-9-]{2,40}$/.test(slug)) fail('Укажите адрес латиницей: pnpm tenant:new polish-gomel --name "Полироль" --owner me@mail.by');
if (existsSync(tenantDir(slug))) fail(`Папка tenants/${slug} уже есть — студия не перезаписывается`);

cpSync(join(TENANTS_DIR, "_template"), tenantDir(slug), { recursive: true });
const file = join(tenantDir(slug), "business.json");
const b = JSON.parse(readFileSync(file, "utf8"));
b.slug = slug;
if (arg("name")) b.profile.name = arg("name");
if (arg("owner")) b.owner.email = arg("owner");
if (arg("phone")) b.profile.phone = arg("phone");
if (arg("address")) b.profile.address = arg("address");
if (arg("kind")) b.profile.kind = arg("kind");
if (arg("accent")) b.profile.accent = arg("accent");
if (arg("operator") || arg("unp")) {
  b.profile.legal = {
    operator: arg("operator") ?? "ИП Фамилия Имя Отчество",
    unp: arg("unp") ?? "000000000",
    legalAddress: arg("legal-address") ?? b.profile.address,
    email: arg("owner") ?? "privacy@example.com",
    retentionDays: 365,
  };
}
writeFileSync(file, JSON.stringify(b, null, 2) + "\n");

const v = validateTenant(slug);
console.log(`Создана студия tenants/${slug}/`);
v.errors.forEach((e) => console.log(`  ✗ ${e}`));
v.warnings.forEach((w) => console.log(`  ! ${w}`));
if (v.liveIssues.length) console.log(`  Для live ещё нужно:\n${v.liveIssues.map((x) => `    – ${x}`).join("\n")}`);
console.log(`Дальше: заполните business.json и images/, затем pnpm tenant:validate ${slug}`);
