// Supabase Edge Function admin-users: аккаунты владельцев студий для панели продавца (/admin).
// Вызывает только продавец (строка в platform_admins). Ключ service role задаёт платформа, в браузер он не попадает.
//
// Действия (POST JSON):
//   { action: "create_owner", tenantId, email, password } — создать аккаунт (или взять существующий) и выдать доступ к студии
//   { action: "set_password", userId, password }          — задать владельцу новый пароль
//   { action: "change_email", userId, email }             — сменить почту владельца (без письма-подтверждения)
//
// Установка без командной строки: Supabase → Edge Functions → Deploy a new function → Via Editor,
// имя admin-users, вставить этот файл, Deploy. В настройках функции выключить «Verify JWT» —
// токен проверяет сама функция.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) => Response.json(body, { status, headers: cors });
const fail = (code: string, status = 400) => reply({ error: code }, status);
const isEmail = (s: unknown): s is string => typeof s === "string" && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s.trim());
const isPassword = (s: unknown): s is string => typeof s === "string" && s.length >= 8 && s.length <= 72;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return fail("method_not_allowed", 405);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // кто вызывает: проверяем токен пользователя и что он продавец
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: who, error: whoErr } = await admin.auth.getUser(jwt);
  if (whoErr || !who.user) return fail("forbidden", 401);
  const { data: seller } = await admin.from("platform_admins").select("user_id").eq("user_id", who.user.id).maybeSingle();
  if (!seller) return fail("forbidden", 403);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail("bad_request");
  }

  // менять чужие аккаунты продавцов нельзя (свой — можно)
  const guardTarget = async (userId: unknown) => {
    if (typeof userId !== "string") return "bad_request";
    if (userId === who.user.id) return null;
    const { data } = await admin.from("platform_admins").select("user_id").eq("user_id", userId).maybeSingle();
    return data ? "forbidden" : null;
  };

  switch (body.action) {
    case "create_owner": {
      const { tenantId, email, password } = body;
      if (typeof tenantId !== "string" || !isEmail(email)) return fail("bad_request");
      const { data: t } = await admin.from("tenants").select("id").eq("id", tenantId).maybeSingle();
      if (!t) return fail("tenant_not_found", 404);
      const mail = email.trim().toLowerCase();
      let userId: string | null = (await admin.rpc("service_user_id_by_email", { p_email: mail })).data ?? null;
      let created = false;
      if (!userId) {
        if (!isPassword(password)) return fail("weak_password");
        const { data, error } = await admin.auth.admin.createUser({ email: mail, password, email_confirm: true });
        if (error || !data.user) return fail(error?.message ?? "create_failed", 500);
        userId = data.user.id;
        created = true;
      }
      const { error } = await admin.from("tenant_members").upsert({ tenant_id: tenantId, user_id: userId }, { onConflict: "tenant_id,user_id", ignoreDuplicates: true });
      if (error) return fail(error.message, 500);
      return reply({ userId, created });
    }
    case "set_password": {
      const bad = await guardTarget(body.userId);
      if (bad) return fail(bad, bad === "forbidden" ? 403 : 400);
      if (!isPassword(body.password)) return fail("weak_password");
      const { error } = await admin.auth.admin.updateUserById(body.userId as string, { password: body.password });
      return error ? fail(error.message, 500) : reply({ ok: true });
    }
    case "change_email": {
      const bad = await guardTarget(body.userId);
      if (bad) return fail(bad, bad === "forbidden" ? 403 : 400);
      if (!isEmail(body.email)) return fail("bad_request");
      const mail = body.email.trim().toLowerCase();
      const taken = (await admin.rpc("service_user_id_by_email", { p_email: mail })).data;
      if (taken && taken !== body.userId) return fail("email_taken", 409);
      const { error } = await admin.auth.admin.updateUserById(body.userId as string, { email: mail, email_confirm: true });
      return error ? fail(error.message, 500) : reply({ ok: true });
    }
    default:
      return fail("bad_request");
  }
});
