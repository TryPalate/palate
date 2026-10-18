-- Notifications: a ping when friends update their shelves. Run once in Supabase > SQL Editor. Safe to run twice.
-- Afterwards, get your notification key by running:  select value from app_config where key = 'push_key';

-- 1. Know when a shelf's picks really changed (re-ordering shelves must not ping anyone).
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='shelves' and column_name='years_updated_at') then
    alter table public.shelves add column years_updated_at timestamptz not null default now();
    update public.shelves set years_updated_at = updated_at;
  end if;
end $$;
create or replace function public.touch_years() returns trigger language plpgsql as $$
begin
  if new.years is distinct from old.years then new.years_updated_at = now(); end if;
  return new;
end $$;
drop trigger if exists shelves_touch_years on public.shelves;
create trigger shelves_touch_years before update on public.shelves for each row execute function public.touch_years();

-- 2. Which phones and browsers want pings. The app can only use the two functions below, never read this table.
create table if not exists public.push_subscriptions (
  endpoint   text primary key check (char_length(endpoint) <= 1000),
  user_id    uuid not null references auth.users(id) on delete cascade,
  p256dh     text not null check (char_length(p256dh) <= 200),
  auth_key   text not null check (char_length(auth_key) <= 100),
  tz_offset  int  not null default 0,
  checked_at timestamptz not null default now(),    -- friends' updates before this were already handled
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon, authenticated;

create or replace function public.push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_tz int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  insert into public.push_subscriptions as s (endpoint, user_id, p256dh, auth_key, tz_offset)
    values (p_endpoint, auth.uid(), p_p256dh, p_auth, coalesce(p_tz, 0))
  on conflict (endpoint) do update set
    p256dh = excluded.p256dh, auth_key = excluded.auth_key, tz_offset = excluded.tz_offset,
    checked_at = case when s.user_id = auth.uid() then s.checked_at else now() end,
    user_id = auth.uid();
end $$;
grant execute on function public.push_subscribe(text, text, text, int) to authenticated;

create or replace function public.push_unsubscribe(p_endpoint text) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
end $$;
grant execute on function public.push_unsubscribe(text) to authenticated;

-- 3. Used by the GitHub Action that sends the pings. Protected by a secret key, like growth_snapshot.
create table if not exists public.app_config (key text primary key, value text not null);
alter table public.app_config enable row level security;
revoke all on public.app_config from anon, authenticated;
insert into public.app_config values ('push_key', md5(random()::text || clock_timestamp()::text) || md5(random()::text || clock_timestamp()::text))
  on conflict do nothing;

-- Friends' shelf changes each phone has not been told about yet. Only shelves that phone's owner is allowed to see,
-- and nothing between 10pm and 8am in their time zone (it waits for the morning instead).
create or replace function public.push_pending(p_key text)
returns table(endpoint text, p256dh text, auth_key text, friend text, cat text, changed_at timestamptz, as_of timestamptz)
language plpgsql security definer set search_path = public as $$
declare t timestamptz := now();
begin
  if p_key is distinct from (select value from public.app_config where key = 'push_key') then raise exception 'no'; end if;
  return query
  select s.endpoint, s.p256dh, s.auth_key, p.name, sh.cat, sh.years_updated_at, t
    from public.push_subscriptions s
    join public.friendships f on f.friend_id = s.user_id          -- f.user_id is the friend who owns the shelf
    join public.shelves sh on sh.user_id = f.user_id
    join public.profiles p on p.id = f.user_id
   where sh.years_updated_at > s.checked_at and sh.years_updated_at <= t
     and sh.user_id <> s.user_id
     and sh.vis <> 'private' and (sh.vis = 'friends' or f.close)
     and extract(hour from (t - make_interval(mins => s.tz_offset)))::int between 8 and 21
   order by sh.years_updated_at desc;
end $$;
grant execute on function public.push_pending(text) to anon, authenticated;

create or replace function public.push_done(p_key text, p_endpoints text[], p_as_of timestamptz) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_key is distinct from (select value from public.app_config where key = 'push_key') then raise exception 'no'; end if;
  update public.push_subscriptions s set checked_at = greatest(s.checked_at, p_as_of) where s.endpoint = any(p_endpoints);
end $$;
grant execute on function public.push_done(text, text[], timestamptz) to anon, authenticated;

create or replace function public.push_drop(p_key text, p_endpoint text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_key is distinct from (select value from public.app_config where key = 'push_key') then raise exception 'no'; end if;
  delete from public.push_subscriptions where endpoint = p_endpoint;
end $$;
grant execute on function public.push_drop(text, text) to anon, authenticated;
