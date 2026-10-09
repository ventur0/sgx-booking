// Supabase Edge Function admin-users: аккаунты владельцев студий для панели продавца (/admin).
// Вызывает продавец (строка в platform_admins). Владелец студии может сам: сменить почту, удалить свою студию,
// удалить свой аккаунт — каждое действие подтверждается его текущим паролем.
// Ключ service role задаёт платформа, в браузер он не попадает.
//
// Действия (POST JSON):
//   { action: "create_owner", tenantId, email, password, linkExisting? } — создать аккаунт и выдать доступ к студии;
//     если аккаунт с этой почтой уже есть — 409 user_exists (со списком его студий), привязка только с linkExisting: true
//   { action: "purge_media", tenantId }                   — удалить фото уже удалённой студии из хранилища
//   { action: "set_password", userId, password }          — задать владельцу новый пароль
//   { action: "change_email", userId, email }             — сменить почту владельца (без письма-подтверждения)
//   { action: "delete_user", userId, confirmEmail }       — удалить аккаунт владельца целиком (студии остаются);
//     confirmEmail — почта этого аккаунта, которую продавец вписывает для подтверждения
//   { action: "delete_studio", tenantId, confirmEmail }   — продавец удаляет студию; подтверждение — почта её владельца
//     (если владельцев нет — почта самого продавца)
//   владелец, с подтверждением текущим паролем:
//   { action: "change_own_email", email, password }
//   { action: "delete_own_studio", tenantId, password }   — удалить свою студию со всеми записями и фото
//   { action: "delete_own_account", password }            — удалить свой аккаунт (студии остаются у продавца)
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
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail("bad_request");
  }

  const me = who.user;
  const { data: sellerRow } = await admin.from("platform_admins").select("user_id").eq("user_id", me.id).maybeSingle();
  const isSeller = !!sellerRow;

  // Пароль вызывающего: письма не нужны (встроенная почта Supabase не пишет посторонним адресам),
  // личность владельца подтверждаем его текущим паролем.
  const passwordOk = async (password: unknown) => {
    if (typeof password !== "string" || !password || !me.email) return false;
    const check = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
    const { error } = await check.auth.signInWithPassword({ email: me.email, password });
    return !error;
  };
  const isUuid = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f-]{36}$/i.test(v);
  const sameEmail = (a: unknown, b: string | undefined | null) => typeof a === "string" && !!b && a.trim().toLowerCase() === b.toLowerCase();

  // Удаление студии: строки базы (service_delete_studio — каскадом записи, оплаты, услуги, график, доступы),
  // затем её фото в хранилище.
  const deleteStudio = async (tenantId: string) => {
    const { error } = await admin.rpc("service_delete_studio", { p_tenant: tenantId });
    if (error) return error.message;
    const bucket = admin.storage.from("tenant-media");
    for (let i = 0; i < 100; i++) {
      const { data: files } = await bucket.list(`${tenantId}/owner`, { limit: 100 });
      if (!files?.length) break;
      await bucket.remove(files.map((f) => `${tenantId}/owner/${f.name}`));
    }
    return null;
  };

  if (body.action === "delete_own_studio") {
    if (!isUuid(body.tenantId)) return fail("bad_request");
    const { data: member } = await admin.from("tenant_members").select("tenant_id").eq("tenant_id", body.tenantId).eq("user_id", me.id).maybeSingle();
    if (!member) return fail("forbidden", 403);
    if (!(await passwordOk(body.password))) return fail("wrong_password", 403);
    const err = await deleteStudio(body.tenantId);
    return err ? fail(err, 500) : reply({ ok: true });
  }

  if (body.action === "delete_own_account") {
    if (isSeller) return fail("cannot_delete_self"); // аккаунт продавца так не удаляется
    if (!(await passwordOk(body.password))) return fail("wrong_password", 403);
    const { error } = await admin.auth.admin.deleteUser(me.id);
    return error ? fail(error.message, 500) : reply({ ok: true });
  }

  if (body.action === "change_own_email") {
    const { data: member } = await admin.from("tenant_members").select("tenant_id").eq("user_id", me.id).limit(1).maybeSingle();
    if (!member && !isSeller) return fail("forbidden", 403);
    if (!isEmail(body.email) || !me.email) return fail("bad_request");
    if (!(await passwordOk(body.password))) return fail("wrong_password", 403);
    const mail = body.email.trim().toLowerCase();
    if (mail === me.email.toLowerCase()) return reply({ ok: true });
    const taken = (await admin.rpc("service_user_id_by_email", { p_email: mail })).data;
    if (taken && taken !== me.id) return fail("email_taken", 409);
    const { error } = await admin.auth.admin.updateUserById(me.id, { email: mail, email_confirm: true });
    return error ? fail(error.message, 500) : reply({ ok: true });
  }

  if (!isSeller) return fail("forbidden", 403);

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
      if (userId && body.linkExisting !== true) {
        const { data: rows } = await admin.from("tenant_members").select("tenants(slug)").eq("user_id", userId);
        const studios = (rows ?? []).map((r) => (r as unknown as { tenants: { slug: string } | null }).tenants?.slug).filter(Boolean);
        return reply({ error: "user_exists", studios }, 409);
      }
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
    case "purge_media": {
      if (typeof body.tenantId !== "string" || !/^[0-9a-f-]{36}$/.test(body.tenantId)) return fail("bad_request");
      const { data: t } = await admin.from("tenants").select("id").eq("id", body.tenantId).maybeSingle();
      if (t) return fail("tenant_exists", 409); // фото действующей студии не трогаем
      const bucket = admin.storage.from("tenant-media");
      let removed = 0;
      for (;;) {
        const { data: files, error } = await bucket.list(`${body.tenantId}/owner`, { limit: 100 });
        if (error) return fail(error.message, 500);
        if (!files?.length) break;
        const { error: rmErr } = await bucket.remove(files.map((f) => `${body.tenantId}/owner/${f.name}`));
        if (rmErr) return fail(rmErr.message, 500);
        removed += files.length;
      }
      return reply({ removed });
    }
    case "delete_studio": {
      if (!isUuid(body.tenantId)) return fail("bad_request");
      const { data: t } = await admin.from("tenants").select("slug").eq("id", body.tenantId).maybeSingle();
      if (!t) return fail("tenant_not_found", 404);
      const { data: owners } = await admin.rpc("service_tenant_owner_emails", { p_tenant: body.tenantId });
      const emails = (owners ?? []) as string[];
      const confirmed = emails.length ? emails.some((e) => sameEmail(body.confirmEmail, e)) : sameEmail(body.confirmEmail, me.email);
      if (!confirmed) return fail("confirm_mismatch");
      const err = await deleteStudio(body.tenantId);
      return err ? fail(err, 500) : reply({ ok: true });
    }
    case "delete_user": {
      if (body.userId === who.user.id) return fail("cannot_delete_self");
      const bad = await guardTarget(body.userId);
      if (bad) return fail(bad, bad === "forbidden" ? 403 : 400);
      const { data: target } = await admin.auth.admin.getUserById(body.userId as string);
      if (!target?.user) return fail("not_found", 404);
      if (!sameEmail(body.confirmEmail, target.user.email)) return fail("confirm_mismatch");
      // доступы к студиям удаляются вместе с аккаунтом (tenant_members … on delete cascade)
      const { error } = await admin.auth.admin.deleteUser(body.userId as string);
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
