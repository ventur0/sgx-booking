/**
 * Разбор диапазона tstzrange из PostgREST: ["2026-10-17 10:00:00+00","2026-10-17 15:00:00+00").
 * Postgres пишет смещение как «+00» или «+03», а браузеры понимают только «+00:00» — без нормализации
 * получается Invalid Date, и страница падает на форматировании даты.
 */
export function pgTimestamp(s: string): Date | null {
  let v = s.trim().replace(" ", "T");
  v = v.replace(/([+-]\d{2})$/, "$1:00").replace(/([+-]\d{2})(\d{2})$/, "$1:$2");
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}

export function parseRange(r: string): { from: Date; to: Date } | null {
  const m = r.match(/^[[(]"?([^",]+)"?,"?([^")\]]+)"?[)\]]$/);
  if (!m) return null;
  const from = pgTimestamp(m[1]), to = pgTimestamp(m[2]);
  return from && to ? { from, to } : null;
}
