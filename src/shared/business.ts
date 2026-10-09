import { z } from "zod";
import { normalizeBYPhone } from "./by";

/**
 * Схема business.json — вход конвейера (tenant:new/validate/publish).
 * В рантайме источник данных — база; этот файл только переносит бизнес в базу.
 */
const hhmm = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, "Время ЧЧ:ММ");
const ymd = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Дата ГГГГ-ММ-ДД");
const key = z.string().regex(/^[a-z0-9_-]{1,40}$/, "key: латиница в нижнем регистре, цифры, - и _");
const imagePath = z.string().regex(/^images\/[a-zA-Z0-9._-]+\.(jpe?g|png|webp|svg)$/, "Путь вида images/hero.jpg");
const money = z.number().min(0).max(1_000_000).refine((v) => Math.abs(v * 100 - Math.round(v * 100)) < 1e-6, "Не больше двух знаков после запятой");
const toMin = (s: string) => Number(s.slice(0, 2)) * 60 + Number(s.slice(3, 5));

const Window = z.object({ opens: hhmm, closes: hhmm }).refine((w) => toMin(w.closes) > toMin(w.opens), "Закрытие позже открытия");

export const BookingRulesSchema = z.object({
  bufferMin: z.number().int().min(0).max(240),
  stepMin: z.union([z.literal(15), z.literal(30), z.literal(60)]),
  leadMin: z.number().int().min(0).max(2880),
  cancelHours: z.number().int().min(0).max(168),
  horizonDays: z.number().int().min(1).max(90),
});

export const LegalSchema = z.object({
  operator: z.string().trim().min(3).max(160),
  unp: z.string().regex(/^\d{9}$/, "УНП — 9 цифр"),
  legalAddress: z.string().trim().min(5).max(200),
  email: z.string().email(),
  retentionDays: z.number().int().min(30).max(3650).default(365),
  dataLocation: z.string().trim().min(2).max(120).default("Германия (ЕС), Supabase, регион Frankfurt"),
});

/** Публичный профиль студии — то, что хранится в tenants.profile и редактируется в кабинете. */
export const ProfileSchema = z.object({
  name: z.string().trim().min(1).max(60),
  /** Подпись под иконкой на телефоне, до 12 символов */
  shortName: z.string().trim().min(1).max(12).optional(),
  kind: z.string().trim().max(60),
  tagline: z.string().trim().max(140),
  description: z.string().trim().max(600),
  address: z.string().trim().min(5).max(200),
  phone: z.string().refine((p) => normalizeBYPhone(p) !== null, "Телефон: например +375 29 123-45-67"),
  accent: z.string().regex(/^#[0-9a-fA-F]{6}$/, "Акцент — цвет вида #4690FF"),
  cards: z.array(z.object({ title: z.string().trim().min(1).max(40), text: z.string().trim().max(160) })).length(3),
  booking: BookingRulesSchema,
  legal: LegalSchema.optional(),
  media: z.object({ hero: z.string().min(1), logo: z.string().min(1) }).optional(),
});
export type Profile = z.infer<typeof ProfileSchema>;

const DemoBookingSchema = z.object({
  service: key,
  resource: key.optional(),
  dayOffset: z.number().int().min(-30).max(30),
  time: hhmm,
  name: z.string().min(2),
  phone: z.string(),
  car: z.string().min(2),
  status: z.enum(["new", "accepted", "ready", "done", "cancelled"]).default("new"),
  payments: z.array(z.object({ kind: z.enum(["pay", "refund"]), amount: money, method: z.enum(["cash", "card", "erip", "other"]).default("cash") })).default([]),
});

export const BusinessSchema = z
  .object({
    slug: z.string().regex(/^[a-z0-9-]{2,40}$/, "slug: латиница в нижнем регистре, цифры и дефис"),
    timezone: z.string().default("Europe/Minsk"),
    owner: z.object({ email: z.string().email("Почта владельца") }),
    profile: ProfileSchema.omit({ media: true }),
    images: z.object({ hero: imagePath, logo: imagePath }),
    resources: z.array(z.object({ key, name: z.string().trim().min(1).max(40) })).min(1).max(20),
    services: z
      .array(
        z.object({
          key,
          name: z.string().trim().min(2).max(80),
          description: z.string().trim().max(200).default(""),
          price: money,
          durationMin: z.number().int().min(15).max(20160),
          resources: z.array(key).optional(),
          active: z.boolean().default(true),
        }),
      )
      .min(1)
      .max(60),
    hours: z.object({ mon: Window.nullable(), tue: Window.nullable(), wed: Window.nullable(), thu: Window.nullable(), fri: Window.nullable(), sat: Window.nullable(), sun: Window.nullable() }),
    /** Государственные праздники РБ как выходные на 18 месяцев вперёд. */
    holidays: z.boolean().default(true),
    exceptions: z
      .array(z.object({ day: ymd, closed: z.boolean().default(true), opens: hhmm.optional(), closes: hhmm.optional(), note: z.string().max(80).default("") }))
      .default([]),
    works: z.array(z.object({ key, image: imagePath, caption: z.string().trim().min(1).max(120) })).max(40),
    demo: z.object({ bookings: z.array(DemoBookingSchema).default([]) }).default({ bookings: [] }),
  })
  .superRefine((b, ctx) => {
    const dupes = (arr: { key: string }[], label: string) => {
      const seen = new Set<string>();
      for (const x of arr) {
        if (seen.has(x.key)) ctx.addIssue({ code: z.ZodIssueCode.custom, message: `${label}: повторяется key «${x.key}»` });
        seen.add(x.key);
      }
    };
    dupes(b.resources, "resources");
    dupes(b.services, "services");
    dupes(b.works, "works");
    const res = new Set(b.resources.map((r) => r.key));
    for (const s of b.services) for (const r of s.resources ?? []) if (!res.has(r)) ctx.addIssue({ code: z.ZodIssueCode.custom, message: `Услуга ${s.key}: нет ресурса «${r}»` });
    const svc = new Set(b.services.map((s) => s.key));
    for (const d of b.demo.bookings) {
      if (!svc.has(d.service)) ctx.addIssue({ code: z.ZodIssueCode.custom, message: `demo: нет услуги «${d.service}»` });
      if (d.resource && !res.has(d.resource)) ctx.addIssue({ code: z.ZodIssueCode.custom, message: `demo: нет ресурса «${d.resource}»` });
    }
    if (!Object.values(b.hours).some(Boolean)) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Нужен хотя бы один рабочий день" });
  });
export type Business = z.infer<typeof BusinessSchema>;

export const WEEKDAY_KEYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"] as const;

/** Проверки для перевода студии в live: настоящие контакты и оператор ПД. */
export function liveReadiness(b: Business): string[] {
  const issues: string[] = [];
  if (!b.profile.legal) issues.push("Нет данных оператора персональных данных (profile.legal)");
  else if (b.profile.legal.unp === "000000000" || b.profile.legal.email.endsWith("@example.com")) issues.push("Данные оператора ПД ещё из шаблона");
  if (/000-?00-?00/.test(b.profile.phone)) issues.push("Телефон студии — заглушка");
  if (b.owner.email.endsWith("@example.com") || b.owner.email.endsWith(".example")) issues.push("Почта владельца — заглушка");
  if (b.images.hero.endsWith(".svg")) issues.push("Главное фото — временная картинка (.svg)");
  return issues;
}
