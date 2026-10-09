import { formatInTimeZone } from "date-fns-tz";

export type CalEvent = { id: string; title: string; startsAt: string; endsAt: string; location: string; details: string };
const utc = (iso: string) => formatInTimeZone(new Date(iso), "UTC", "yyyyMMdd'T'HHmmss'Z'");
const esc = (s: string) => s.replace(/[\\,;]/g, (x) => `\\${x}`).replace(/\n/g, "\\n");

/** .ics с напоминанием за сутки: работает в календаре iPhone, Android и на компьютере. */
export function icsBlob(e: CalEvent): Blob {
  const lines = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//SGX//Booking//RU", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
    "BEGIN:VEVENT", `UID:${e.id}@sgx-booking`, `DTSTAMP:${utc(new Date().toISOString())}`,
    `DTSTART:${utc(e.startsAt)}`, `DTEND:${utc(e.endsAt)}`, `SUMMARY:${esc(e.title)}`,
    `LOCATION:${esc(e.location)}`, `DESCRIPTION:${esc(e.details)}`,
    "BEGIN:VALARM", "TRIGGER:-P1D", "ACTION:DISPLAY", `DESCRIPTION:${esc("Завтра: " + e.title)}`, "END:VALARM",
    "END:VEVENT", "END:VCALENDAR",
  ];
  return new Blob([lines.join("\r\n")], { type: "text/calendar;charset=utf-8" });
}

export function downloadIcs(e: CalEvent) {
  const url = URL.createObjectURL(icsBlob(e));
  const a = document.createElement("a");
  a.href = url;
  a.download = "zapis.ics";
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}
