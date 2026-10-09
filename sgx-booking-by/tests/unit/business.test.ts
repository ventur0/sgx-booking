import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { BusinessSchema, liveReadiness } from "../../src/shared/business";

const dir = new URL("../../tenants/", import.meta.url);
const slugs = readdirSync(dir).filter((d) => !d.startsWith("_") && existsSync(new URL(`${d}/business.json`, dir)));
const load = (slug: string) => JSON.parse(readFileSync(new URL(`${slug}/business.json`, dir), "utf8"));

describe("business.json демо-студий", () => {
  it("есть минимум две разные студии", () => expect(slugs.length >= 2).toBe(true));
  for (const slug of slugs) {
    it(`${slug}: проходит схему`, () => expect(BusinessSchema.safeParse(load(slug)).success).toBe(true));
  }
  it("студии отличаются брендом, постами и услугами", () => {
    const [a, b] = slugs.map(load);
    expect(a.profile.accent !== b.profile.accent && a.profile.name !== b.profile.name).toBe(true);
    expect(JSON.stringify(a.services.map((s: { key: string }) => s.key)) !== JSON.stringify(b.services.map((s: { key: string }) => s.key))).toBe(true);
  });
  it("демо-студия не готова к live без оператора ПД", () => {
    const b = BusinessSchema.parse(load(slugs[0]));
    expect(liveReadiness(b).some((x) => x.includes("оператора"))).toBe(true);
  });
});

describe("проверки схемы", () => {
  const base = () => load(slugs[0]);
  it("ловит услугу с несуществующим постом", () => {
    const b = base();
    b.services[0].resources = ["no-such-post"];
    expect(BusinessSchema.safeParse(b).success).toBe(false);
  });
  it("ловит закрытие раньше открытия", () => {
    const b = base();
    b.hours.mon = { opens: "20:00", closes: "09:00" };
    expect(BusinessSchema.safeParse(b).success).toBe(false);
  });
  it("ловит цену с тремя знаками после запятой", () => {
    const b = base();
    b.services[0].price = 10.555;
    expect(BusinessSchema.safeParse(b).success).toBe(false);
  });
  it("ловит повтор ключа услуги", () => {
    const b = base();
    b.services.push({ ...b.services[0] });
    expect(BusinessSchema.safeParse(b).success).toBe(false);
  });
});

describe("в src нет названий демо-бизнесов", () => {
  it("исходники не содержат имён из tenants/*", () => {
    const names = slugs.map((s) => load(s).profile.name as string);
    const walk = (p: URL): string[] =>
      readdirSync(p, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(new URL(`${e.name}/`, p)) : [readFileSync(new URL(e.name, p), "utf8")]));
    const src = walk(new URL("../../src/", import.meta.url)).join("\n");
    for (const n of names) expect(src.includes(n)).toBe(false);
  });
});
