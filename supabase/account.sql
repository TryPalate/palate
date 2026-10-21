-- ACCOUNT: usernames, editing your name, notification switches, and a safer profiles table.
-- Run once in Supabase > SQL Editor. Safe to run again. Needs push.sql and growth.sql first.

-- 1. Usernames. Lowercase letters, numbers, dot and underscore, 3 to 20 characters. Two people can never have the same one
--    (Frank and frank count as the same). People without one yet simply have none until they pick one in Settings.
alter table public.profiles add column if not exists username text;
alter table public.profiles drop constraint if exists profiles_username_ok;
alter table public.profiles add constraint profiles_username_ok
  check (username is null or (username ~ '^[a-z0-9_.]{3,20}$' and username !~ '^\.|\.$|\.\.'));
create unique index if not exists profiles_username_key on public.profiles (lower(username));

create table if not exists public.reserved_usernames (name text primary key);
alter table public.reserved_usernames enable row level security;
revoke all on public.reserved_usernames from anon, authenticated;
insert into public.reserved_usernames values
  ('palate'),('trypalate'),('admin'),('administrator'),('support'),('help'),('team'),('staff'),('official'),('mod'),('moderator'),
  ('root'),('system'),('null'),('undefined'),('settings'),('account'),('login'),('signup'),('about'),('privacy'),('terms'),('security'),
  ('me'),('you'),('everyone'),('anonymous'),('claude'),('anthropic'),('king')
  on conflict do nothing;

-- Is this username free? (Used while you type.)
create or replace function public.username_free(p_username text) returns boolean
language sql stable security definer set search_path = public as $$
  select lower(btrim(coalesce(p_username, ''))) ~ '^[a-z0-9_.]{3,20}$'
     and lower(btrim(p_username)) !~ '^\.|\.$|\.\.'
     and not exists (select 1 from public.reserved_usernames r where r.name = lower(btrim(p_username)))
     and not exists (select 1 from public.profiles p where lower(p.username) = lower(btrim(p_username)) and p.id <> auth.uid());
$$;

-- Change your display name and/or username. Pass null to leave one as it is.
create or replace function public.set_profile(p_name text, p_username text) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')); un text := lower(btrim(coalesce(p_username, '')));
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if p_name is not null then
    if char_length(nm) < 1 or char_length(nm) > 40 then raise exception 'Names are 1 to 40 characters'; end if;
    if nm ~ '[<>]' or nm ~* 'https?:|www\.' then raise exception 'Names can''t have links or brackets'; end if;
    update public.profiles set name = nm where id = uid;
  end if;
  if p_username is not null then
    if un !~ '^[a-z0-9_.]{3,20}$' then raise exception 'Usernames are 3 to 20 letters, numbers, dots or underscores'; end if;
    if un ~ '^\.|\.$|\.\.' then raise exception 'Usernames can''t start or end with a dot, or have two in a row'; end if;
    if exists (select 1 from public.reserved_usernames where name = un) then raise exception 'That username is taken'; end if;
    perform pg_advisory_xact_lock(hashtext('username:' || un));
    if exists (select 1 from public.profiles where lower(username) = un and id <> uid) then raise exception 'That username is taken'; end if;
    update public.profiles set username = un where id = uid;
  end if;
  return (select json_build_object('name', p.name, 'username', p.username) from public.profiles p where p.id = uid);
exception when unique_violation then raise exception 'That username is taken';
end $$;

-- Find someone by their exact username (no browsing, no partial matches).
create or replace function public.find_person(p_username text) returns table (id uuid, name text, avatar smallint, username text, is_friend boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.avatar, p.username,
         exists (select 1 from public.friendships f where f.user_id = auth.uid() and f.friend_id = p.id)
    from public.profiles p
   where auth.uid() is not null and lower(p.username) = lower(btrim(coalesce(p_username, ''))) and p.id <> auth.uid()
   limit 1;
$$;

revoke all on function public.username_free(text), public.set_profile(text, text), public.find_person(text) from public, anon;
grant execute on function public.username_free(text), public.set_profile(text, text), public.find_person(text) to authenticated;

-- 2. The profiles table can only be changed through the functions (name, username, picture, invite link).
--    This stops anyone editing their own row directly, for example to fake who invited them.
revoke update on public.profiles from anon, authenticated;
revoke insert on public.profiles from anon, authenticated;
grant insert (id, name) on public.profiles to authenticated;

-- 3. Notification switches, one row per person. No row means everything is on.
create table if not exists public.notify_prefs (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  friends    boolean not null default true,     -- a friend updated a shelf
  reactions  boolean not null default true,     -- a friend reacted to one of your picks
  weekly     boolean not null default true,     -- the weekly topic is out, and when friends' answers are ready
  updated_at timestamptz not null default now()
);
alter table public.notify_prefs enable row level security;
revoke all on public.notify_prefs from anon, authenticated;
grant select, insert, update on public.notify_prefs to authenticated;
drop policy if exists notify_prefs_own on public.notify_prefs;
create policy notify_prefs_own on public.notify_prefs for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Friend-update pings now respect the "friends" switch.
create or replace function public.push_pending(p_key text)
returns table(endpoint text, p256dh text, auth_key text, friend text, cat text, changed_at timestamptz, as_of timestamptz)
language plpgsql security definer set search_path = public as $$
declare t timestamptz := now();
begin
  if p_key is distinct from (select value from public.app_config where key = 'push_key') then raise exception 'no'; end if;
  return query
  select s.endpoint, s.p256dh, s.auth_key, p.name, sh.cat, sh.years_updated_at, t
    from public.push_subscriptions s
    join public.friendships f on f.friend_id = s.user_id
    join public.shelves sh on sh.user_id = f.user_id
    join public.profiles p on p.id = f.user_id
    left join public.notify_prefs np on np.user_id = s.user_id
   where sh.years_updated_at > s.checked_at and sh.years_updated_at <= t
     and sh.user_id <> s.user_id
     and coalesce(np.friends, true)
     and sh.cat not like 'wk:%'
     and sh.vis <> 'private' and (sh.vis = 'friends' or f.close)
     and extract(hour from (t - make_interval(mins => s.tz_offset)))::int between 8 and 21
   order by sh.years_updated_at desc;
end $$;
grant execute on function public.push_pending(text) to anon, authenticated;

-- ---- Your controls ----
-- Who has picked a username:   select name, username from profiles order by username nulls last;
-- Free up a username:          update profiles set username = null where username = 'theirname';
-- Reserve another name:        insert into reserved_usernames values ('somename') on conflict do nothing;
