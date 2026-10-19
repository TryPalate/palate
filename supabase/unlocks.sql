-- UNLOCKS + "MAKE YOUR OWN" SHELVES. Run once in Supabase > SQL Editor. Safe to run again (it replaces the earlier version).
-- How it works: everyone starts with the big, popular categories open. The rest are locked, and you EARN PICKS: each pick
-- lets you unlock any one category you choose. Picks come from: finishing your first shelf, friends who join through your link
-- and make a shelf, and opening the app on different days. Supporters and the Creator have everything.
-- One switch turns all of it off (see the bottom).
-- Needs growth.sql (profiles.invited_by), badges.sql (supporter badge) and the friendships table.

insert into public.app_config values ('unlock_gate', 'on') on conflict (key) do nothing;

-- 1. Which days someone opened the app
create table if not exists public.activity_days (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day     date not null default current_date,
  primary key (user_id, day)
);
alter table public.activity_days enable row level security;
revoke all on public.activity_days from anon, authenticated;
create or replace function public.touch_day() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.activity_days (user_id, day) values (auth.uid(), current_date) on conflict do nothing;
end $$;
revoke all on function public.touch_day() from public, anon;
grant execute on function public.touch_day() to authenticated;

-- 2. What earns a pick. kind: shelves (shelves you have made), invites (friends who joined through your link AND made a shelf),
--    days (different days you opened the app). grants: 'pick' = one category of your choice, 'custom' = make-your-own shelves.
create table if not exists public.unlock_rewards (
  id text primary key, kind text not null check (kind in ('invites','days','shelves')), n int not null,
  grants text not null default 'pick' check (grants in ('pick','custom')), sort int not null default 0
);
alter table public.unlock_rewards enable row level security;
revoke all on public.unlock_rewards from anon, authenticated;
insert into public.unlock_rewards (id, kind, n, grants, sort) values
  ('first_shelf', 'shelves', 1, 'pick', 1),
  ('invite_1',    'invites', 1, 'pick', 2),
  ('days_3',      'days',    3, 'pick', 3),
  ('invite_3',    'invites', 3, 'pick', 4),
  ('custom',      'invites', 3, 'custom', 5),
  ('days_7',      'days',    7, 'pick', 6),
  ('invite_5',    'invites', 5, 'pick', 7),
  ('days_14',     'days',   14, 'pick', 8)
  on conflict (id) do update set kind = excluded.kind, n = excluded.n, grants = excluded.grants, sort = excluded.sort;

-- Rewards you have earned live in user_unlocks as 'reward:<id>'; categories you unlocked are stored by their id ('countries').
create table if not exists public.user_unlocks (
  user_id uuid not null references public.profiles(id) on delete cascade,
  pack text not null, unlocked_at timestamptz not null default now(),
  primary key (user_id, pack)
);
alter table public.user_unlocks enable row level security;
revoke all on public.user_unlocks from anon, authenticated;
drop table if exists public.unlock_packs;   -- from the first version

create or replace function public.is_supporter(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_badges where user_id = uid and badge in ('supporter','creator'));
$$;
revoke all on function public.is_supporter(uuid) from public, anon, authenticated;

create or replace function public.unlock_state() returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); inv int; d int; sh int; fresh text[] := '{}'; r record; cats text[]; earned int; used int; cust boolean;
begin
  if uid is null then return null; end if;
  insert into public.activity_days (user_id, day) values (uid, current_date) on conflict do nothing;
  select count(*) into inv from public.profiles p where p.invited_by = uid and exists (select 1 from public.shelves s where s.user_id = p.id);
  select count(*) into d   from public.activity_days where user_id = uid;
  select count(*) into sh  from public.shelves where user_id = uid;
  for r in select * from public.unlock_rewards order by sort loop
    if (r.kind = 'invites' and inv >= r.n) or (r.kind = 'days' and d >= r.n) or (r.kind = 'shelves' and sh >= r.n) then
      insert into public.user_unlocks (user_id, pack) values (uid, 'reward:' || r.id) on conflict do nothing;
      if found then fresh := fresh || r.id; end if;
    end if;
  end loop;
  select count(*) into earned from public.user_unlocks u join public.unlock_rewards w on 'reward:' || w.id = u.pack where u.user_id = uid and w.grants = 'pick';
  select coalesce(array_agg(pack), '{}') into cats from public.user_unlocks
    where user_id = uid and pack not like 'reward:%' and pack not in ('eats','screen','places','style','culture','deep','custom');
  used := coalesce(array_length(cats, 1), 0);
  cust := exists (select 1 from public.user_unlocks where user_id = uid and pack in ('reward:custom', 'custom'));
  return json_build_object(
    'gate', coalesce((select value from public.app_config where key = 'unlock_gate'), 'off') = 'on',
    'supporter', public.is_supporter(uid),
    'invites', inv, 'days', d, 'shelves', sh,
    'picks_left', greatest(0, earned - used), 'unlocked', to_json(cats), 'custom', cust, 'fresh', to_json(fresh),
    'rewards', (select coalesce(json_agg(json_build_object('id', w.id, 'kind', w.kind, 'n', w.n, 'grants', w.grants,
        'done', exists (select 1 from public.user_unlocks u where u.user_id = uid and u.pack = 'reward:' || w.id)) order by w.sort), '[]'::json)
      from public.unlock_rewards w));
end $$;
revoke all on function public.unlock_state() from public, anon;
grant execute on function public.unlock_state() to authenticated;

-- Spend a pick on one category.
create or replace function public.unlock_category(p_cat text) returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); st json;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if p_cat is null or p_cat !~ '^[a-z0-9]{2,30}$' then raise exception 'That is not a category'; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  st := public.unlock_state();
  if exists (select 1 from public.user_unlocks where user_id = uid and pack = p_cat) then return st; end if;
  if (st->>'picks_left')::int < 1 then raise exception 'You have no picks left'; end if;
  insert into public.user_unlocks (user_id, pack) values (uid, p_cat) on conflict do nothing;
  return public.unlock_state();
end $$;
revoke all on function public.unlock_category(text) from public, anon;
grant execute on function public.unlock_category(text) to authenticated;

-- 3. Make-your-own shelves ("Who is the smartest in the group?"). Friends see the name, so they can rank it too.
create table if not exists public.custom_cats (
  id text primary key, owner uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 40), created_at timestamptz not null default now()
);
alter table public.custom_cats enable row level security;
revoke all on public.custom_cats from anon, authenticated;
grant select on public.custom_cats to authenticated;
drop policy if exists custom_cats_read on public.custom_cats;
create policy custom_cats_read on public.custom_cats for select to authenticated
  using (owner = auth.uid() or exists (select 1 from public.friendships f where f.user_id = auth.uid() and f.friend_id = owner));

create or replace function public.make_custom_cat(p_name text) returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text := btrim(regexp_replace(coalesce(p_name,''), '\s+', ' ', 'g')); open boolean; cid text;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if char_length(nm) < 2 or char_length(nm) > 40 then raise exception 'Give it a name of 2 to 40 characters'; end if;
  if nm ~ '[<>]' or nm ~* 'https?:|www\.' then raise exception 'That name can''t have links or brackets'; end if;
  open := coalesce((select value from public.app_config where key = 'unlock_gate'), 'off') <> 'on'
          or public.is_supporter(uid)
          or exists (select 1 from public.user_unlocks where user_id = uid and pack in ('reward:custom', 'custom'))
          or (select count(*) from public.profiles p where p.invited_by = uid and exists (select 1 from public.shelves s where s.user_id = p.id)) >= 3;
  if not open then raise exception 'Make-your-own shelves are still locked'; end if;
  if (select count(*) from public.custom_cats where owner = uid) >= 8 then raise exception 'You have 8 shelves of your own already'; end if;
  cid := 'my:' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  insert into public.custom_cats (id, owner, name) values (cid, uid, nm);
  return json_build_object('id', cid, 'name', nm);
end $$;
revoke all on function public.make_custom_cat(text) from public, anon;
grant execute on function public.make_custom_cat(text) to authenticated;

-- ---- Your controls ----
-- Turn the whole gate off (everything open to everyone):   update app_config set value = 'off' where key = 'unlock_gate';
-- Turn it back on:                                        update app_config set value = 'on'  where key = 'unlock_gate';
-- Make a reward easier or harder:   update unlock_rewards set n = 2 where id = 'days_3';
-- Give someone a pick by hand (it counts as an earned reward):  insert into user_unlocks (user_id, pack) values ('PASTE-THEIR-ID', 'reward:gift1') on conflict do nothing;
--   (a pick is any 'reward:...' row whose id is in unlock_rewards; to gift one, add a row there first:  insert into unlock_rewards values ('gift1','shelves',0,'pick',99);)
-- See which categories people unlock:  select pack, count(*) from user_unlocks where pack not like 'reward:%' group by 1 order by 2 desc;
