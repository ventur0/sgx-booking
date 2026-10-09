import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { FunctionsHttpError } from "@supabase/supabase-js";
import { supabase } from "../lib/supabase";

/** Панель продавца: студии, владельцы, приостановка. Права проверяет сервер (platform_admins). */
export type StudioRow = {
  id: string; slug: string; name: string; mode: "preview" | "live"; suspended: boolean;
  createdAt: string; wentLiveAt: string | null; bookings30: number; lastBookingAt: string | null;
  owners: { userId: string; email: string }[];
};

export function useIsPlatformAdmin(userId: string | undefined) {
  return useQuery({
    queryKey: ["platform-admin", userId],
    enabled: !!userId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("is_platform_admin");
      if (error) throw error;
      return data as boolean;
    },
  });
}

export function useStudios(enabled: boolean) {
  return useQuery({
    queryKey: ["admin", "studios"],
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("admin_list_studios");
      if (error) throw error;
      return data as StudioRow[];
    },
  });
}

/** Вызов Edge Function admin-users; ошибки сервера приходят как { error: "код" }. */
export async function users<T>(body: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.functions.invoke("admin-users", { body });
  if (error) {
    if (error instanceof FunctionsHttpError) {
      const res = error.context as Response;
      const j = (await res.json().catch(() => null)) as { error?: string } | null;
      if (!j?.error && res.status === 404) throw new Error("functions_missing");
      throw Object.assign(new Error(j?.error ?? `http_${res.status}`), { details: j });
    }
    throw new Error(/Failed to send|fetch/i.test(error.message) ? "functions_missing" : error.message);
  }
  return data as T;
}

export function useAdminActions() {
  const qc = useQueryClient();
  const done = () => qc.invalidateQueries({ queryKey: ["admin", "studios"] });
  const rpc = async <T,>(fn: string, args: Record<string, unknown>) => {
    const { data, error } = await supabase.rpc(fn, args);
    if (error) throw error;
    return data as T;
  };
  return {
    createStudio: useMutation({ mutationFn: (a: { slug: string; name: string }) => rpc<string>("admin_create_studio", { p_slug: a.slug, p_name: a.name }), onSuccess: done }),
    createOwner: useMutation({
      mutationFn: (a: { tenantId: string; email: string; password: string; linkExisting?: boolean }) => users<{ userId: string; created: boolean }>({ action: "create_owner", ...a }),
      onSuccess: done,
    }),
    setPassword: useMutation({ mutationFn: (a: { userId: string; password: string }) => users<{ ok: true }>({ action: "set_password", ...a }) }),
    changeEmail: useMutation({ mutationFn: (a: { userId: string; email: string }) => users<{ ok: true }>({ action: "change_email", ...a }), onSuccess: done }),
    /** Подтверждение — почта удаляемого аккаунта, вписанная продавцом вручную. */
    deleteUser: useMutation({ mutationFn: (a: { userId: string; confirmEmail: string }) => users<{ ok: true }>({ action: "delete_user", ...a }), onSuccess: done }),
    removeOwner: useMutation({ mutationFn: (a: { tenantId: string; userId: string }) => rpc<void>("admin_remove_owner", { p_tenant: a.tenantId, p_user: a.userId }), onSuccess: done }),
    /** Подтверждение — почта владельца студии (если владельцев нет — почта продавца). Фото удаляются вместе со студией. */
    deleteStudio: useMutation({
      mutationFn: (a: { tenantId: string; confirmEmail: string }) => users<{ ok: true }>({ action: "delete_studio", ...a }),
      onSuccess: done,
    }),
    setSuspended: useMutation({ mutationFn: (a: { tenantId: string; suspended: boolean }) => rpc<void>("admin_set_suspended", { p_tenant: a.tenantId, p_suspended: a.suspended }), onSuccess: done }),
  };
}

/** Временный пароль: 12 символов без похожих букв (l/1, O/0). */
export function makePassword(len = 12) {
  const abc = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const v = crypto.getRandomValues(new Uint32Array(len));
  return Array.from(v, (x) => abc[x % abc.length]).join("");
}

const TR: Record<string, string> = {
  а: "a", б: "b", в: "v", г: "g", д: "d", е: "e", ё: "e", ж: "zh", з: "z", и: "i", й: "y", к: "k", л: "l", м: "m", н: "n", о: "o", п: "p",
  р: "r", с: "s", т: "t", у: "u", ф: "f", х: "h", ц: "ts", ч: "ch", ш: "sh", щ: "sch", ъ: "", ы: "y", ь: "", э: "e", ю: "yu", я: "ya", і: "i", ў: "u",
};
/** Адрес студии из названия: «Детейлинг Про» → detejling-pro */
export function slugify(name: string) {
  return name
    .toLowerCase()
    .split("")
    .map((c) => TR[c] ?? c)
    .join("")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40)
    .replace(/-+$/g, "");
}

/** Аккаунт с этой почтой уже существует: какие студии у него есть (для подтверждения привязки). */
export function existingAccount(e: unknown): string[] | null {
  const d = (e as { details?: { error?: string; studios?: string[] } })?.details;
  return d?.error === "user_exists" ? (d.studios ?? []) : null;
}

