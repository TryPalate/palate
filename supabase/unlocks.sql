-- UNLOCKS + "MAKE YOUR OWN" SHELVES. Run once in Supabase > SQL Editor. Safe to run again.
-- Everyone starts with 8 popular categories. The rest come in packs that open by doing things that make people come back:
-- friends who join and rank, days they open the app, shelves they fill. Supporters and the Creator have everything.
-- The app reads the gate switch below, so you can turn all of this off with one line (see the bottom).
-- Needs growth.sql (profiles.invited_by), badges.sql (supporter badge) and friends_alpha.sql/schema.sql (friendships).

insert into public.app_config values ('unlock_gate', 'on') on conflict (key) do nothing;

-- 1. Which days someone opened the app (one row per person per day)
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

-- 2. The packs and what they ask for. kind: invites (friends who joined through your link AND made a shelf),
--    days (different days opened), shelves (shelves you have made). Change a number here and everyone follows.
create table if not exists public.unlock_packs (id text primary key, kind text not null check (kind in ('invites','days','shelves')), n int not null);
alter table public.unlock_packs enable row level security;
revoke all on public.unlock_packs from anon, authenticated;
insert into public.unlock_packs (id, kind, n) values
  ('eats', 'invites', 1), ('screen', 'days', 3), ('places', 'shelves', 3),
  ('style', 'invites', 3), ('culture', 'days', 7), ('deep', 'days', 14), ('custom', 'invites', 5)
  on conflict (id) do update set kind = excluded.kind, n = excluded.n;

create table if not exists public.user_unlocks (
  user_id uuid not null references public.profiles(id) on delete cascade,
  pack text not null, unlocked_at timestamptz not null default now(),
  primary key (user_id, pack)
);
alter table public.user_unlocks enable row level security;
revoke all on public.user_unlocks from anon, authenticated;

create or replace function public.is_supporter(uid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_badges where user_id = uid and badge in ('supporter','creator'));
$$;
revoke all on function public.is_supporter(uuid) from public, anon, authenticated;

-- 3. The app calls this when it opens: it records today, opens any pack you now qualify for (for good), and returns where you stand.
create or replace function public.unlock_state() returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); inv int; d int; sh int; fresh text[] := '{}'; r record; got text[];
begin
  if uid is null then return null; end if;
  insert into public.activity_days (user_id, day) values (uid, current_date) on conflict do nothing;
  select count(*) into inv from public.profiles p where p.invited_by = uid and exists (select 1 from public.shelves s where s.user_id = p.id);
  select count(*) into d   from public.activity_days where user_id = uid;
  select count(*) into sh  from public.shelves where user_id = uid;
  for r in select * from public.unlock_packs loop
    if (r.kind = 'invites' and inv >= r.n) or (r.kind = 'days' and d >= r.n) or (r.kind = 'shelves' and sh >= r.n) then
      insert into public.user_unlocks (user_id, pack) values (uid, r.id) on conflict do nothing;
      if found then fresh := fresh || r.id; end if;
    end if;
  end loop;
  select coalesce(array_agg(pack), '{}') into got from public.user_unlocks where user_id = uid;
  return json_build_object(
    'gate', coalesce((select value from public.app_config where key = 'unlock_gate'), 'off') = 'on',
    'supporter', public.is_supporter(uid),
    'invites', inv, 'days', d, 'shelves', sh,
    'unlocked', to_json(got), 'fresh', to_json(fresh),
    'rules', (select coalesce(json_agg(json_build_object('id', id, 'kind', kind, 'n', n)), '[]'::json) from public.unlock_packs));
end $$;
revoke all on function public.unlock_state() from public, anon;
grant execute on function public.unlock_state() to authenticated;

-- 4. Make-your-own shelves ("Who is the smartest in the group?"). Friends see the name, so they can rank it too.
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
          or exists (select 1 from public.user_unlocks where user_id = uid and pack = 'custom');
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
-- Make a pack easier or harder (eats, screen, places, style, culture, deep, custom):
--   update unlock_packs set n = 2 where id = 'eats';
-- Open a pack for one person by hand:  insert into user_unlocks (user_id, pack) values ('PASTE-THEIR-ID', 'eats') on conflict do nothing;
-- See how it is going:  select pack, count(*) from user_unlocks group by 1 order by 2 desc;
