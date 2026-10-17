import { describe, expect, it } from "vitest";
import { parseRange, pgTimestamp } from "../../src/shared/range";

describe("диапазоны времени из базы (блокировки постов)", () => {
  it("понимает смещение +00 и +03, как его пишет Postgres", () => {
    expect(pgTimestamp("2026-10-17 10:00:00+00")?.toISOString()).toBe("2026-10-17T10:00:00.000Z");
    expect(pgTimestamp("2026-10-17 13:00:00+03")?.toISOString()).toBe("2026-10-17T10:00:00.000Z");
    expect(pgTimestamp("2026-10-17 13:00:00.5+0300")?.toISOString()).toBe("2026-10-17T10:00:00.500Z");
  });
  it("разбирает tstzrange", () => {
    const r = parseRange('["2026-10-17 10:00:00+00","2026-10-17 11:00:00+00")');
    expect(r?.from.toISOString()).toBe("2026-10-17T10:00:00.000Z");
    expect(r?.to.toISOString()).toBe("2026-10-17T11:00:00.000Z");
  });
  it("на мусоре возвращает null, а не Invalid Date", () => {
    expect(parseRange("[x,y)")).toBeNull();
    expect(parseRange("empty")).toBeNull();
    expect(pgTimestamp("не дата")).toBeNull();
  });
});
