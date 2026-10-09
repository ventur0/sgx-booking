/** Версия текста согласия: сохраняется вместе с согласием клиента. Меняйте при правке политики. */
export const CONSENT_VERSION = "2026-10";

/**
 * Белорусская специфика: телефоны, деньги, государственные праздники.
 * Чистые функции — используются в браузере, командах tenant:* и тестах.
 */

/**
 * Приводит номер к виду +375XXXXXXXXX.
 * Понимает: +375 29 123-45-67, 375291234567, 8 029 123 45 67, 80291234567, 29 123-45-67.
 * Иностранный номер с «+» (например, +48…) оставляет как есть.
 * Возвращает null, если номер не распознан.
 */
export function normalizeBYPhone(input: string): string | null {
  const raw = String(input ?? "").trim();
  const d = raw.replace(/\D/g, "");
  if (/^375\d{9}$/.test(d)) return `+${d}`;
  if (/^80\d{9}$/.test(d)) return `+375${d.slice(2)}`;
  if (/^\d{9}$/.test(d) && /^(17|25|29|33|44|1[5-6]|2[1-3])/.test(d)) return `+375${d}`;
  if (raw.startsWith("+") && /^\d{10,15}$/.test(d)) return `+${d}`; // иностранные номера
  return null;
}

/** +375291234567 → +375 (29) 123-45-67 */
export function formatBYPhone(p: string): string {
  const m = p.match(/^\+375(\d{2})(\d{3})(\d{2})(\d{2})$/);
  return m ? `+375 (${m[1]}) ${m[2]}-${m[3]}-${m[4]}` : p;
}

/** Цена в белорусских рублях: 45 BYN, 45,50 BYN, 1 200 BYN. */
export function moneyBYN(n: number): string {
  const v = Math.round((n ?? 0) * 100) / 100;
  const s = new Intl.NumberFormat("ru-BY", { minimumFractionDigits: Number.isInteger(v) ? 0 : 2, maximumFractionDigits: 2 }).format(v);
  return `${s} BYN`;
}

/** Деньги считаем в копейках, чтобы 0,1 + 0,2 не давало 0,30000000000000004. */
export const toKop = (n: number) => Math.round(n * 100);
export const fromKop = (k: number) => k / 100;

/**
 * Пасха по православному календарю (юлианский расчёт + перевод в григорианский).
 * Радуница — вторник на 9-й день после Пасхи, нерабочий день в Беларуси.
 */
export function orthodoxEaster(year: number): string {
  const a = year % 4, b = year % 7, c = year % 19;
  const d = (19 * c + 15) % 30;
  const e = (2 * a + 4 * b - d + 34) % 7;
  const month = Math.floor((d + e + 114) / 31);
  const day = ((d + e + 114) % 31) + 1;
  const julian = new Date(Date.UTC(year, month - 1, day));
  julian.setUTCDate(julian.getUTCDate() + 13); // разница календарей в 1900–2099 гг.
  return julian.toISOString().slice(0, 10);
}

export function radunitsa(year: number): string {
  const d = new Date(`${orthodoxEaster(year)}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 9);
  return d.toISOString().slice(0, 10);
}

/** Государственные праздники и праздничные нерабочие дни Республики Беларусь за год. */
export function byHolidays(year: number): { date: string; name: string }[] {
  return [
    { date: `${year}-01-01`, name: "Новый год" },
    { date: `${year}-01-02`, name: "Новый год" },
    { date: `${year}-01-07`, name: "Рождество Христово (православное)" },
    { date: `${year}-03-08`, name: "День женщин" },
    { date: radunitsa(year), name: "Радуница" },
    { date: `${year}-05-01`, name: "Праздник труда" },
    { date: `${year}-05-09`, name: "День Победы" },
    { date: `${year}-07-03`, name: "День Независимости" },
    { date: `${year}-11-07`, name: "День Октябрьской революции" },
    { date: `${year}-12-25`, name: "Рождество Христово (католическое)" },
  ].sort((x, y) => x.date.localeCompare(y.date));
}

/** Праздники на ближайшие N дней начиная с даты (для кнопки в кабинете). */
export function upcomingHolidays(from: string, days = 365) {
  const y = Number(from.slice(0, 4));
  const end = new Date(`${from}T00:00:00Z`);
  end.setUTCDate(end.getUTCDate() + days);
  const to = end.toISOString().slice(0, 10);
  return [...byHolidays(y), ...byHolidays(y + 1)].filter((h) => h.date >= from && h.date <= to);
}
