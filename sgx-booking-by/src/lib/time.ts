import { format } from "date-fns";
import { ru } from "date-fns/locale";
import { formatInTimeZone, fromZonedTime } from "date-fns-tz";

/** Все даты показываем в часовом поясе студии — так же, как считает сервер. */
export const localDate = (at: Date | string, tz: string) => formatInTimeZone(new Date(at), tz, "yyyy-MM-dd");
export const localTime = (at: Date | string, tz: string) => formatInTimeZone(new Date(at), tz, "HH:mm");
export const todayIn = (tz: string) => localDate(new Date(), tz);
/** Начало локальных суток студии как момент времени. */
export const dayStart = (ymd: string, tz: string) => fromZonedTime(`${ymd}T00:00:00`, tz);
export const atLocal = (ymd: string, hhmm: string, tz: string) => fromZonedTime(`${ymd}T${hhmm}:00`, tz);

const asDate = (ymd: string) => {
  const [y, m, d] = ymd.split("-").map(Number);
  return new Date(y, m - 1, d, 12);
};
export const addDays = (ymd: string, n: number) => {
  const d = asDate(ymd);
  d.setDate(d.getDate() + n);
  return format(d, "yyyy-MM-dd");
};
export const dayLabel = (ymd: string) => format(asDate(ymd), "d MMMM, EEEEEE", { locale: ru });
export const dayLong = (ymd: string) => format(asDate(ymd), "EEEE, d MMMM", { locale: ru });
export const weekdayShort = (ymd: string) => format(asDate(ymd), "EEEEEE", { locale: ru });
export const dayNum = (ymd: string) => asDate(ymd).getDate();
export const weekStart = (ymd: string) => {
  const d = asDate(ymd);
  d.setDate(d.getDate() - ((d.getDay() + 6) % 7));
  return format(d, "yyyy-MM-dd");
};
export const trimTime = (t: string) => t.slice(0, 5);

export function durationLabel(min: number) {
  if (min >= 1440 && min % 1440 === 0) {
    const d = min / 1440;
    return d === 1 ? "1 сутки" : `${d} суток`;
  }
  const h = Math.floor(min / 60);
  const m = min % 60;
  return [h ? `${h} ч` : "", m ? `${m} мин` : ""].filter(Boolean).join(" ");
}

/** Интервал записи словами: «12 октября, пн, 10:00–11:30» или «12 октября 09:00 — 14 октября 09:00». */
export function rangeLabel(startsAt: string, endsAt: string, tz: string) {
  const sd = localDate(startsAt, tz), ed = localDate(endsAt, tz);
  return sd === ed
    ? `${dayLabel(sd)}, ${localTime(startsAt, tz)}–${localTime(endsAt, tz)}`
    : `${dayLabel(sd)} ${localTime(startsAt, tz)} — ${dayLabel(ed)} ${localTime(endsAt, tz)}`;
}
