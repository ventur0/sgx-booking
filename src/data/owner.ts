import { useEffect } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "../lib/supabase";
import type { Profile } from "../shared/business";

export type BookingStatus = "new" | "accepted" | "ready" | "done" | "cancelled";
export type OwnerBooking = {
  id: string; service_id: string; resource_id: string; status: BookingStatus; starts_at: string; ends_at: string;
  service_name: string; price: number; client_name: string; client_phone: string; client_car: string;
  source: "client" | "owner"; is_demo: boolean; consent_at: string | null; anonymized_at: string | null;
  payments: { id: string; kind: "pay" | "refund"; amount: number; method: string; paid_at: string }[];
};
export type Block = { id: string; resource_id: string; period: string; note: string };
export type Stats = { from: string; to: string; timezone: string; visits: number; completed: number; cancelled: number; received: number; refunded: number; net: number; expected: number };

const BOOKING_COLS =
  "id, service_id, resource_id, status, starts_at, ends_at, service_name, price, client_name, client_phone, client_car, source, is_demo, consent_at, anonymized_at, payments(id, kind, amount, method, paid_at)";

/** Сессия владельца. При выходе очищаем весь кэш запросов, чтобы чужие данные не остались в памяти. */
export function useSession() {
  const qc = useQueryClient();
  useEffect(() => {
    const { data } = supabase.auth.onAuthStateChange((event) => {
      if (event === "SIGNED_OUT") qc.clear();
      qc.invalidateQueries({ queryKey: ["session"] });
      qc.invalidateQueries({ queryKey: ["membership"] });
    });
    return () => data.subscription.unsubscribe();
  }, [qc]);
  return useQuery({ queryKey: ["session"], queryFn: async () => (await supabase.auth.getSession()).data.session });
}

/** Смена пароля самим владельцем (письмо не нужно: пользователь уже вошёл). */
export async function changeOwnPassword(password: string) {
  const { error } = await supabase.auth.updateUser({ password });
  if (error) throw error;
}

/** Смена своей почты: через Edge Function admin-users, с подтверждением текущим паролем. */
export async function changeOwnEmail(email: string, password: string) {
  const { users } = await import("./admin");
  await users<{ ok: true }>({ action: "change_own_email", email, password });
  await supabase.auth.refreshSession(); // новая почта сразу видна в кабинете
}

/** Владелец удаляет свою студию (подтверждение — его пароль). Удаляются записи, оплаты, услуги, фото. */
export async function deleteOwnStudio(tenantId: string, password: string) {
  const { users } = await import("./admin");
  await users<{ ok: true }>({ action: "delete_own_studio", tenantId, password });
}

/** Владелец удаляет свой аккаунт (подтверждение — его пароль); студия остаётся у продавца. */
export async function deleteOwnAccount(password: string) {
  const { users } = await import("./admin");
  await users<{ ok: true }>({ action: "delete_own_account", password });
}

/**
 * Выход: закрываем сессию, стираем её следы в браузере и перезагружаем страницу —
 * так на экране гарантированно не остаётся данных кабинета, а показывается форма входа.
 * Даже если сервер недоступен или аккаунт уже удалён, локальный выход всё равно происходит.
 */
export async function signOut(redirectTo?: string) {
  try {
    const { error } = await supabase.auth.signOut();
    if (error) await supabase.auth.signOut({ scope: "local" });
  } catch {
    /* сеть недоступна — чистим вручную ниже */
  }
  try {
    for (const k of Object.keys(localStorage)) if (k.startsWith("sb-") && k.includes("auth")) localStorage.removeItem(k);
    sessionStorage.clear();
  } catch {
    /* хранилище недоступно (приватный режим) */
  }
  if (redirectTo) window.location.replace(redirectTo);
  else window.location.reload();
}

/** Членство подтверждается сервером (RLS на tenant_members), а не интерфейсом. */
export function useMembership(tenantId: string, userId: string | undefined) {
  return useQuery({
    queryKey: ["membership", tenantId, userId],
    enabled: !!userId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("is_member", { p_tenant: tenantId });
      if (error) throw error;
      return data as boolean;
    },
  });
}

/** Записи, пересекающие период [fromIso; toIso), + живые обновления Realtime (тоже под RLS). */
export function useOwnerBookings(tenantId: string, fromIso: string, toIso: string) {
  const qc = useQueryClient();
  useEffect(() => {
    const refresh = () => qc.invalidateQueries({ queryKey: ["owner", tenantId] });
    const ch = supabase
      .channel(`owner-${tenantId}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "bookings", filter: `tenant_id=eq.${tenantId}` }, refresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "payments", filter: `tenant_id=eq.${tenantId}` }, refresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "resource_occupancies", filter: `tenant_id=eq.${tenantId}` }, refresh)
      .subscribe();
    return () => void supabase.removeChannel(ch);
  }, [tenantId, qc]);
  return useQuery({
    queryKey: ["owner", tenantId, "bookings", fromIso, toIso],
    queryFn: async () => {
      const { data, error } = await supabase.from("bookings").select(BOOKING_COLS).eq("tenant_id", tenantId).lt("starts_at", toIso).gt("ends_at", fromIso).order("starts_at");
      if (error) throw error;
      return (data as OwnerBooking[]).map((b) => ({ ...b, price: Number(b.price), payments: b.payments.map((p) => ({ ...p, amount: Number(p.amount) })) }));
    },
  });
}

export function useBlocks(tenantId: string, fromIso: string, toIso: string) {
  return useQuery({
    queryKey: ["owner", tenantId, "blocks", fromIso, toIso],
    queryFn: async () => {
      const { data, error } = await supabase.from("resource_occupancies").select("id, resource_id, period, note").eq("tenant_id", tenantId).eq("kind", "block")
        .overlaps("period", `[${fromIso},${toIso})`);
      if (error) throw error;
      return data as Block[];
    },
  });
}

/** Статистика считается в SQL (owner_stats) в часовом поясе студии. */
export function useStats(tenantId: string, from: string, to: string) {
  return useQuery({
    queryKey: ["owner", tenantId, "stats", from, to],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("owner_stats", { p_tenant: tenantId, p_from: from, p_to: to });
      if (error) throw error;
      const s = data as Stats;
      return { ...s, received: Number(s.received), refunded: Number(s.refunded), net: Number(s.net), expected: Number(s.expected) };
    },
  });
}

export const parseRange = (r: string) => {
  const m = r.match(/^[[(]"?([^",]+)"?,"?([^")\]]+)"?[)\]]$/);
  return m ? { from: new Date(m[1].replace(" ", "T")), to: new Date(m[2].replace(" ", "T")) } : null;
};

export function useOwnerActions(tenantId: string, slug: string) {
  const qc = useQueryClient();
  const done = () => {
    qc.invalidateQueries({ queryKey: ["owner", tenantId] });
    qc.invalidateQueries({ queryKey: ["availability", slug] });
  };
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await supabase.rpc(fn, args);
    if (error) throw error;
    return data;
  };
  return {
    create: useMutation({ mutationFn: (a: { serviceId: string; day: string; time: string; name: string; phone: string; car: string; key: string; resourceId: string | null }) =>
      rpc("owner_create_booking", { p_tenant: tenantId, p_service_id: a.serviceId, p_day: a.day, p_time: a.time, p_name: a.name, p_phone: a.phone, p_car: a.car, p_idempotency_key: a.key, p_resource_id: a.resourceId }), onSuccess: done }),
    move: useMutation({ mutationFn: (a: { id: string; day: string; time: string; resourceId: string | null }) =>
      rpc("owner_move_booking", { p_booking: a.id, p_day: a.day, p_time: a.time, p_resource_id: a.resourceId }), onSuccess: done }),
    status: useMutation({ mutationFn: (a: { id: string; status: BookingStatus }) => rpc("owner_set_status", { p_booking: a.id, p_status: a.status }), onSuccess: done }),
    pay: useMutation({ mutationFn: (a: { id: string; kind: "pay" | "refund"; amount: number; method: string }) =>
      rpc("owner_add_payment", { p_booking: a.id, p_kind: a.kind, p_amount: a.amount, p_method: a.method }), onSuccess: done }),
    block: useMutation({ mutationFn: (a: { resourceId: string; from: string; to: string; note: string }) =>
      rpc("owner_block_resource", { p_resource_id: a.resourceId, p_from: a.from, p_to: a.to, p_note: a.note }), onSuccess: done }),
    unblock: useMutation({ mutationFn: (id: string) => rpc("owner_unblock", { p_occupancy: id }), onSuccess: done }),
    anonymize: useMutation({ mutationFn: (id: string) => rpc("owner_anonymize_booking", { p_booking: id }), onSuccess: done }),
  };
}

/** Настройки студии: прямые записи в таблицы, доступ ограничен RLS по членству. */
export function useSettingsActions(tenantId: string, slug: string) {
  const qc = useQueryClient();
  const done = () => qc.invalidateQueries({ queryKey: ["studio", slug] });
  const ok = <T,>(r: { error: unknown; data?: T }) => {
    if (r.error) throw r.error;
    return r.data as T;
  };
  return {
    saveProfile: useMutation({ mutationFn: async (profile: Profile) => ok(await supabase.from("tenants").update({ profile }).eq("id", tenantId)), onSuccess: done }),
    /** Услуга и её посты — одной транзакцией (owner_save_service). Пустой список постов = любой активный пост. */
    saveService: useMutation({
      mutationFn: async (a: { id?: string; name: string; description: string; price: number; duration_min: number; active: boolean; sort: number; resourceIds: string[] }) => {
        const { data, error } = await supabase.rpc("owner_save_service", {
          p_tenant: tenantId, p_id: a.id ?? null, p_name: a.name, p_description: a.description, p_price: a.price,
          p_duration_min: a.duration_min, p_active: a.active, p_sort: a.sort, p_resource_ids: a.resourceIds,
        });
        if (error) throw error;
        return data as string;
      },
      onSuccess: done,
    }),
    goLive: useMutation({
      mutationFn: async () => {
        const { data, error } = await supabase.rpc("owner_go_live", { p_tenant: tenantId });
        if (error) throw error;
        return data as number;
      },
      onSuccess: done,
    }),
    saveResource: useMutation({
      mutationFn: async (r: { id?: string; key: string; name: string; active: boolean; sort: number }) =>
        ok(r.id ? await supabase.from("resources").update(r).eq("id", r.id) : await supabase.from("resources").insert({ ...r, tenant_id: tenantId })),
      onSuccess: done,
    }),
    saveHours: useMutation({
      mutationFn: async (rows: { weekday: number; opens: string; closes: string }[]) => {
        ok(await supabase.from("working_hours").delete().eq("tenant_id", tenantId));
        if (rows.length) ok(await supabase.from("working_hours").insert(rows.map((r) => ({ ...r, tenant_id: tenantId }))));
      },
      onSuccess: done,
    }),
    saveException: useMutation({
      mutationFn: async (e: { day: string; closed: boolean; opens: string | null; closes: string | null; note: string }) =>
        ok(await supabase.from("schedule_exceptions").upsert({ ...e, tenant_id: tenantId, source: "owner" }, { onConflict: "tenant_id,day" })),
      onSuccess: done,
    }),
    removeException: useMutation({ mutationFn: async (day: string) => ok(await supabase.from("schedule_exceptions").delete().eq("tenant_id", tenantId).eq("day", day)), onSuccess: done }),
    upload: async (blob: Blob) => {
      const path = `${tenantId}/owner/${crypto.randomUUID()}.jpg`;
      ok(await supabase.storage.from("tenant-media").upload(path, blob, { contentType: "image/jpeg", cacheControl: "31536000" }));
      return supabase.storage.from("tenant-media").getPublicUrl(path).data.publicUrl;
    },
    removeUpload: async (url: string) => {
      const marker = "/tenant-media/";
      const i = url.indexOf(marker);
      if (i < 0 || !url.includes(`${marker}${tenantId}/owner/`)) return; // картинки конвейера не трогаем
      await supabase.storage.from("tenant-media").remove([url.slice(i + marker.length)]);
    },
    addWork: useMutation({ mutationFn: async (w: { photo_url: string; caption: string; sort: number }) => ok(await supabase.from("works").insert({ ...w, tenant_id: tenantId, source: "owner" })), onSuccess: done }),
    // правка владельца отвязывает карточку от business.json (key = null, source = owner): переиздание её не тронет
    updateWork: useMutation({ mutationFn: async (w: { id: string; photo_url?: string; caption?: string }) => ok(await supabase.from("works").update({ ...w, key: null, source: "owner" }).eq("id", w.id)), onSuccess: done }),
    removeWork: useMutation({ mutationFn: async (id: string) => ok(await supabase.from("works").delete().eq("id", id)), onSuccess: done }),
  };
}
