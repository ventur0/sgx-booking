-- Минимальная замена окружения Supabase для локальных SQL-тестов на чистом PostgreSQL.
-- В настоящем проекте Supabase эти объекты уже есть; файл не применяется к Supabase.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
grant usage on schema public to anon, authenticated, service_role;
grant all on all tables in schema public to service_role;
alter default privileges in schema public grant all on tables to service_role;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key, email text unique);
create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
create schema if not exists storage;
create table if not exists storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table if not exists storage.objects (id uuid default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;
create or replace function storage.foldername(name text) returns text[] language sql immutable as $$ select string_to_array(name, '/') $$;

-- Заглушка pg_net: запросы складываются в net.test_requests, ответы тест кладёт в net._http_response сам.
create schema if not exists net;
create table if not exists net.test_requests (id bigserial primary key, method text, url text, body jsonb, params jsonb, created timestamptz default now());
create table if not exists net._http_response (id bigint primary key, status_code int, content text, timed_out boolean, error_msg text, created timestamptz default now());
create or replace function net.http_get(url text, params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds integer default 5000)
returns bigint language sql as $$ insert into net.test_requests (method, url, params) values ('GET', url, params) returning id $$;
create or replace function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds integer default 5000)
returns bigint language sql as $$ insert into net.test_requests (method, url, body, params) values ('POST', url, body, params) returning id $$;
