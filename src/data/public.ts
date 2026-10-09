import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { z } from "zod";
import { supabase } from "../lib/supabase";
import { ProfileSchema, type Profile } from "../shared/business";

/* ---------------------------- типы публичных данных ---------------------------- */
export type Tenant = { id: string; slug: string; mode: "preview" | "live"; suspended: boolean; timezone: string; profile: Profile };
export type Service = { id: string; key: string; name: string; description: string; price: number; duration_min: number; active: boolean; sort: number };
export type Resource = { id: string; key: string; name: string; active: boolean; sort: number };
export type Hours = { weekday: number; opens: string; closes: string };
export type Exception = { day: string; closed: boolean; opens: string | null; closes: string | null; note: string; source: "config" | "owner" };
export type Work = { id: string; key: string | null; photo_url: string; caption: string; sort: number; source: "config" | "owner" };
export type Slot = { day: string; closed: boolean; slot_time: string | null; starts_at: string | null; free: boolean };

const num = (v: unknown) => Number(v);

/** Профиль, услуги, посты, график и фото одной студии — одним запросом на каждую таблицу. */
export function useStudio(slug: string) {
  return useQuery({
    queryKey: ["studio", slug],
    staleTime: 60_000,
    queryFn: async () => {
      const t = await supabase.from("tenants").select("id, slug, mode, suspended, timezone, profile").eq("slug", slug).maybeSingle();
      if (t.error) throw t.error;
      if (!t.data) throw new Error("tenant_not_found");
      const profile = ProfileSchema.safeParse(t.data.profile);
      if (!profile.success) throw new Error("config_invalid");
      const id = t.data.id as string;
      const [svc, res, hrs, exc, wrk, sres] = await Promise.all([
        supabase.from("services").select("id, key, name, description, price, duration_min, active, sort").eq("tenant_id", id).order("sort"),
        supabase.from("resources").select("id, key, name, active, sort").eq("tenant_id", id).order("sort"),
        supabase.from("working_hours").select("weekday, opens, closes").eq("tenant_id", id),
        supabase.from("schedule_exceptions").select("day, closed, opens, closes, note, source").eq("tenant_id", id).gte("day", new Date(Date.now() - 864e5).toISOString().slice(0, 10)).order("day"),
        supabase.from("works").select("id, key, photo_url, caption, sort, source").eq("tenant_id", id).order("sort"),
        supabase.from("service_resources").select("service_id, resource_id").eq("tenant_id", id),
      ]);
      for (const r of [svc, res, hrs, exc, wrk, sres]) if (r.error) throw r.error;
      return {
        tenant: { ...(t.data as Omit<Tenant, "profile">), profile: profile.data } as Tenant,
        services: (svc.data as Service[]).map((s) => ({ ...s, price: num(s.price) })),
        resources: res.data as Resource[],
        hours: hrs.data as Hours[],
        exceptions: exc.data as Exception[],
        works: wrk.data as Work[],
        /** На каких постах оказывается услуга; услуги без строк — на любом активном посту */
        serviceResources: sres.data as { service_id: string; resource_id: string }[],
      };
    },
  });
}
export type Studio = NonNullable<ReturnType<typeof useStudio>["data"]>;

/** Свободное время считает сервер: график, исключения, занятость постов, длительность и буфер. */
export function useAvailability(slug: string, serviceId: string | null, from: string, days = 14) {
  return useQuery({
    queryKey: ["availability", slug, serviceId, from, days],
    enabled: !!serviceId,
    refetchInterval: 30_000,
    refetchOnWindowFocus: true,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_availability", { p_slug: slug, p_service_id: serviceId, p_from: from, p_days: days });
      if (error) throw error;
      return data as Slot[];
    },
  });
}

/* ------------------------------- запись клиента ------------------------------- */
export const BookingInputSchema = z.object({
  serviceId: z.string().uuid(),
  day: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  time: z.string().regex(/^\d{2}:\d{2}$/),
});

export function useCreateBooking(slug: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (p: { serviceId: string; day: string; time: string; name: string; phone: string; car: string; key: string; token: string; consentVersion: string }) => {
      const { data, error } = await supabase.rpc("create_booking", {
        p_slug: slug, p_service_id: p.serviceId, p_day: p.day, p_time: p.time,
        p_name: p.name, p_phone: p.phone, p_car: p.car,
        p_idempotency_key: p.key, p_access_token: p.token, p_consent: true, p_consent_version: p.consentVersion,
      });
      if (error) throw error;
      return data as string;
    },
    onSettled: () => qc.invalidateQueries({ queryKey: ["availability", slug] }),
  });
}

export type MyBooking = {
  id: string; slug: string; timezone: string; serviceName: string; price: number; startsAt: string; endsAt: string;
  resourceName: string; status: "new" | "accepted" | "ready" | "done" | "cancelled"; clientName: string; clientCar: string;
  isDemo: boolean; cancelHours: number; canCancel: boolean; reminder: "none" | "pending" | "processing" | "sent" | "skipped" | "cancelled" | "failed";
};

export function useMyBooking(id: string, token: string) {
  return useQuery({
    queryKey: ["my", id],
    retry: (n, e) => n < 2 && !String((e as Error)?.message).includes("not_found"),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_my_booking", { p_booking: id, p_token: token });
      if (error) throw error;
      const b = data as MyBooking;
      return { ...b, price: Number(b.price) };
    },
  });
}

export function useCancelMyBooking() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (p: { id: string; token: string }) => {
      const { error } = await supabase.rpc("cancel_my_booking", { p_booking: p.id, p_token: p.token });
      if (error) throw error;
    },
    onSuccess: (_d, p) => {
      qc.invalidateQueries({ queryKey: ["my", p.id] });
      qc.invalidateQueries({ queryKey: ["availability"] });
    },
  });
}
