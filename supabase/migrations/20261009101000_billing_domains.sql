-- =====================================================================
-- 11. Панель продавца: учёт оплат покупателей и собственные домены студий.
-- =====================================================================

-- Учёт оплат: видит и меняет только продавец (через функции). Владельцы студий эту таблицу не видят.
create table if not exists public.platform_billing (
  tenant_id     uuid primary key references public.tenants (id) on delete cascade,
  paid_until    date,
  monthly_price numeric(10,2) check (monthly_price is null or monthly_price >= 0),
  note          text not null default '' check (char_length(note) <= 300),
  updated_at    timestamptz not null default now()
);
alter table public.platform_billing enable row level security;
revoke all on public.platform_billing from anon, authenticated;
grant all on public.platform_billing to service_role;

-- Собственный домен студии (например zapis.studio.by): сайт на этом домене открывает именно эту студию.
alter table public.tenants add column if not exists custom_domain text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'tenants_custom_domain_check') then
    alter table public.tenants add constraint tenants_custom_domain_check
      check (custom_domain is null or custom_domain ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$');
  end if;
end $$;
create unique index if not exists tenants_custom_domain_key on public.tenants (custom_domain) where custom_domain is not null;
grant select (custom_domain) on public.tenants to anon, authenticated;

create or replace function public.admin_list_studios() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r jsonb;
begin
  perform public.require_platform_admin();
  select coalesce(jsonb_agg(x order by x ->> 'createdAt' desc), '[]'::jsonb) into r from (
    select jsonb_build_object(
      'id', t.id, 'slug', t.slug, 'name', t.profile ->> 'name', 'mode', t.mode, 'suspended', t.suspended,
      'createdAt', t.created_at, 'wentLiveAt', t.went_live_at, 'customDomain', t.custom_domain,
      'paidUntil', pb.paid_until, 'monthlyPrice', pb.monthly_price, 'billingNote', coalesce(pb.note, ''),
      'owners', coalesce((select jsonb_agg(jsonb_build_object('userId', u.id, 'email', u.email) order by u.email)
                            from tenant_members m join auth.users u on u.id = m.user_id where m.tenant_id = t.id), '[]'::jsonb),
      'bookings30', (select count(*) from bookings b where b.tenant_id = t.id and not b.is_demo and b.created_at > now() - interval '30 days'),
      'lastBookingAt', (select max(b.created_at) from bookings b where b.tenant_id = t.id and not b.is_demo)
    ) x
    from tenants t left join platform_billing pb on pb.tenant_id = t.id
  ) s;
  return r;
end $$;

-- Оплата: дата «оплачено до», цена в месяц, заметка. p_extend_months > 0 — продлить на N месяцев
-- от «оплачено до» (или от сегодня, если срок уже прошёл) и снять приостановку.
create or replace function public.admin_set_billing(
  p_tenant uuid, p_paid_until date, p_monthly_price numeric, p_note text, p_extend_months integer default 0
) returns date
language plpgsql security definer set search_path = public, extensions as $$
declare v_until date; v_today date := (now() at time zone 'Europe/Minsk')::date;
begin
  perform public.require_platform_admin();
  if not exists (select 1 from tenants where id = p_tenant) then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
  if p_monthly_price is not null and (p_monthly_price < 0 or p_monthly_price <> round(p_monthly_price, 2)) then
    raise exception 'bad_amount' using errcode = '22023';
  end if;
  v_until := p_paid_until;
  if coalesce(p_extend_months, 0) > 0 then
    v_until := (greatest(coalesce(p_paid_until, v_today), v_today) + make_interval(months => p_extend_months))::date;
    update tenants set suspended = false where id = p_tenant;
  end if;
  insert into platform_billing (tenant_id, paid_until, monthly_price, note, updated_at)
  values (p_tenant, v_until, p_monthly_price, left(coalesce(p_note, ''), 300), now())
  on conflict (tenant_id) do update set paid_until = excluded.paid_until, monthly_price = excluded.monthly_price,
                                        note = excluded.note, updated_at = now();
  return v_until;
end $$;

create or replace function public.admin_set_domain(p_tenant uuid, p_domain text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v text := nullif(regexp_replace(lower(btrim(coalesce(p_domain, ''))), '^https?://|/.*$', '', 'g'), '');
begin
  perform public.require_platform_admin();
  if v is not null and (v !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' or v like '%pages.dev' or v like '%supabase.co') then
    raise exception 'bad_domain' using errcode = 'P0001';
  end if;
  if v is not null and exists (select 1 from tenants where custom_domain = v and id <> p_tenant) then
    raise exception 'domain_taken' using errcode = 'P0001';
  end if;
  update tenants set custom_domain = v where id = p_tenant;
  if not found then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
  return v;
end $$;

revoke all on function public.admin_list_studios() from public, anon, authenticated;
revoke all on function public.admin_set_billing(uuid, date, numeric, text, integer) from public, anon, authenticated;
revoke all on function public.admin_set_domain(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_list_studios() to authenticated;
grant execute on function public.admin_set_billing(uuid, date, numeric, text, integer) to authenticated;
grant execute on function public.admin_set_domain(uuid, text) to authenticated;
