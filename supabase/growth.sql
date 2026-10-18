-- Growth tracking, "who else picked this" insights, and a milestone feed. Run once in the Supabase SQL Editor.
-- Safe to re-run.

-- 1. Events: what people do (share a picture, copy an invite). The app can only add rows for itself; nobody can read them from the app.
create table if not exists public.events (
  id         bigint generated always as identity primary key,
  user_id    uuid default auth.uid() references auth.users(id) on delete cascade,
  kind       text not null check (char_length(kind) <= 40),
  cat        text check (char_length(cat) <= 40),
  created_at timestamptz not null default now()
);
alter table public.events enable row level security;
drop policy if exists "log own events" on public.events;
create policy "log own events" on public.events for insert to authenticated with check (user_id = auth.uid());
revoke all on public.events from anon, authenticated;
grant insert on public.events to authenticated;
create index if not exists events_kind_time on public.events (kind, created_at);

-- 2. Who invited whom
alter table public.profiles add column if not exists invited_by uuid references auth.users(id) on delete set null;

create or replace function public.add_friend_by_code(code text) returns text
language plpgsql security definer set search_path = public as $$
declare other public.profiles;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into other from public.profiles where invite_code = code;
  if not found then raise exception 'That invite link is not valid anymore'; end if;
  if other.id = auth.uid() then raise exception 'That is your own invite link'; end if;
  insert into public.friendships (user_id, friend_id)
    values (auth.uid(), other.id), (other.id, auth.uid())
    on conflict do nothing;
  -- a brand-new account that arrives through a link counts as invited by that person
  update public.profiles set invited_by = other.id
    where id = auth.uid() and invited_by is null and created_at > now() - interval '2 days';
  return other.name;
end $$;

-- 3. Your dashboard: open these in Table Editor, or run  select * from growth_summary;
create or replace view public.growth_summary as
select
  (select count(*) from public.profiles)                                                        as total_users,
  (select count(*) from public.profiles where created_at > now() - interval '7 days')           as new_last_7_days,
  (select count(distinct user_id) from public.shelves where updated_at > now() - interval '7 days') as active_last_7_days,
  (select count(*) from public.profiles where invited_by is not null)                           as joined_through_an_invite,
  (select count(*) from public.profiles p where p.invited_by is not null
     and exists (select 1 from public.shelves s where s.user_id = p.id))                        as invited_who_made_a_shelf,
  (select count(distinct user_id) from public.events
     where kind in ('share_save','share_native','share_copy_image','share_sms'))                as people_who_shared_a_picture,
  (select count(*) from public.events
     where kind in ('share_save','share_native','share_copy_image','share_sms'))                as pictures_shared,
  (select count(*) from public.events where kind = 'invite_copy')                               as invite_links_copied;

create or replace view public.growth_weekly as
select date_trunc('week', created_at)::date as week,
  count(*) filter (where kind = 'share_open')                                                  as share_screens_opened,
  count(*) filter (where kind in ('share_save','share_native','share_copy_image','share_sms')) as pictures_shared,
  count(distinct user_id) filter (where kind in ('share_save','share_native','share_copy_image','share_sms')) as people_who_shared,
  count(*) filter (where kind = 'invite_copy')                                                 as invite_links_copied
from public.events group by 1 order by 1 desc;

revoke all on public.growth_summary, public.growth_weekly from anon, authenticated;

-- 4. A private key so the weekly GitHub check can read your totals (and nothing else).
create table if not exists public.app_config (key text primary key, value text not null);
alter table public.app_config enable row level security;
revoke all on public.app_config from anon, authenticated;
insert into public.app_config values ('stats_key', md5(random()::text || clock_timestamp()::text) || md5(random()::text || clock_timestamp()::text))
  on conflict (key) do nothing;

create or replace function public.growth_snapshot(p_key text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if p_key is distinct from (select value from public.app_config where key = 'stats_key') then raise exception 'no'; end if;
  return (select row_to_json(g) from public.growth_summary g);
end $$;
grant execute on function public.growth_snapshot(text) to anon, authenticated;

-- 5. "Who else picked this": counts only, never names. Private shelves are not counted.
create or replace function public.pick_stats(p_cat text, p_names text[])
returns table(name text, picked int, first_pick int, shelves int)
language sql security definer set search_path = public stable as $$
  with latest as (
    select s.user_id,
      s.years -> (select k from jsonb_object_keys(s.years) k
                   where k ~ '^[0-9]{4}$' and k::int <= extract(year from now())::int order by k::int desc limit 1) as snap
    from public.shelves s where s.cat = p_cat and s.vis <> 'private'),
  live as (
    select snap -> 'top' as top from latest
    where snap is not null and coalesce(snap ->> 'removed', 'false') <> 'true'
      and jsonb_typeof(snap -> 'top') = 'array' and jsonb_array_length(snap -> 'top') > 0)
  select n,
    (select count(*) from live where exists (select 1 from jsonb_array_elements(top) e where e ->> 'n' = n))::int,
    (select count(*) from live where top -> 0 ->> 'n' = n)::int,
    (select count(*) from live)::int
  from unnest((p_names)[1:10]) n;
$$;
revoke all on function public.pick_stats(text, text[]) from public, anon;
grant execute on function public.pick_stats(text, text[]) to authenticated;
