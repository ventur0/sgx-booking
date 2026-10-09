import { describe, expect, it } from "vitest";
import { byHolidays, formatBYPhone, moneyBYN, normalizeBYPhone, orthodoxEaster, radunitsa } from "../../src/shared/by";

describe("телефоны РБ", () => {
  it("разные записи одного номера", () => {
    for (const v of ["+375 29 123-45-67", "375291234567", "8 029 123 45 67", "80291234567", "29 123-45-67", "+375(29)1234567"])
      expect(normalizeBYPhone(v)).toBe("+375291234567");
  });
  it("городской Минск и иностранный номер", () => {
    expect(normalizeBYPhone("8 017 222-33-44")).toBe("+375172223344");
    expect(normalizeBYPhone("+48 512 345 678")).toBe("+48512345678");
  });
  it("мусор не проходит", () => {
    expect(normalizeBYPhone("12345")).toBe(null);
    expect(normalizeBYPhone("900 123 45 67")).toBe(null);
  });
  it("красивый вид", () => expect(formatBYPhone("+375291234567")).toBe("+375 (29) 123-45-67"));
});

describe("деньги BYN", () => {
  it("формат", () => {
    expect(moneyBYN(45).replace(/\s/g, " ")).toBe("45 BYN");
    expect(moneyBYN(45.5).replace(/\s/g, " ")).toBe("45,50 BYN");
    expect(moneyBYN(1200).replace(/\s/g, " ")).toBe("1 200 BYN");
  });
});

describe("праздники РБ", () => {
  it("православная Пасха и Радуница", () => {
    expect(orthodoxEaster(2026)).toBe("2026-04-12");
    expect(radunitsa(2026)).toBe("2026-04-21");
    expect(orthodoxEaster(2027)).toBe("2027-05-02");
    expect(radunitsa(2027)).toBe("2027-05-11");
  });
  it("10 нерабочих праздничных дней в году", () => expect(byHolidays(2026).length).toBe(10));
});

