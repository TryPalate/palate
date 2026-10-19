-- BADGES. Run once in Supabase > SQL Editor. Safe to run again.
-- What each badge looks like and says lives in index.html (BADGES). This file decides who HAS which badge.
-- Everyone can see badges of themselves, their friends and (while the alpha directory is on) everyone on Palate.
-- Nobody can give themselves a badge: the tables are closed to the app, only the functions below and you (SQL editor) can write.

create table if not exists public.badges (id text primary key, name text not null);
insert into public.badges (id, name) values ('alpha', 'Alpha'), ('creator', 'Creator'), ('supporter', 'Supporter'),
  ('dayone', 'Day One'), ('builder', 'Catalog Builder'), ('hunter', 'Bug Hunter'), ('contrarian', 'Contrarian'), ('timetraveler', 'Time Traveler')
  on conflict (id) do update set name = excluded.name;

create table if not exists public.user_badges (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  badge      text not null references public.badges(id) on delete cascade,
  awarded_at timestamptz not null default now(),
  primary key (user_id, badge)
);
alter table public.badges      enable row level security;
alter table public.user_badges enable row level security;
revoke all on public.badges, public.user_badges from anon, authenticated;

-- Alpha badge: everyone who has an account now, and everyone who signs up while 'alpha_badge' is on.
insert into public.app_config values ('alpha_badge', 'on') on conflict (key) do nothing;
create or replace function public.give_alpha_badge() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce((select value from public.app_config where key = 'alpha_badge'), 'off') = 'on' then
    insert into public.user_badges (user_id, badge) values (new.id, 'alpha') on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists give_alpha_badge on public.profiles;
create trigger give_alpha_badge after insert on public.profiles for each row execute function public.give_alpha_badge();
insert into public.user_badges (user_id, badge, awarded_at)
  select id, 'alpha', created_at from public.profiles on conflict do nothing;

-- Creator badge: you.
insert into public.user_badges (user_id, badge)
  select p.id, 'creator' from public.profiles p join auth.users u on u.id = p.id
  where lower(u.email) = 'kingoung1@gmail.com' on conflict do nothing;


-- Day One: the first 10 accounts, ever. Closed after that.
create or replace function public.give_dayone_badge() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.user_badges where badge = 'dayone') < 10 then
    insert into public.user_badges (user_id, badge) values (new.id, 'dayone') on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists give_dayone_badge on public.profiles;
create trigger give_dayone_badge after insert on public.profiles for each row execute function public.give_dayone_badge();
insert into public.user_badges (user_id, badge, awarded_at)
  select id, 'dayone', created_at from public.profiles order by created_at limit 10 on conflict do nothing;

-- Earned badges. The app asks for a check when you open it; the rules are decided here, so nobody can fake them.
--   Catalog Builder: 25+ researched items you added to the shared catalog.
--   Time Traveler:   shelves kept in 3 different years, with an account at least 2 calendar years old (earliest: Jan 2028).
--   Contrarian:      once 10+ people are here: your #1 is a pick nobody else ranks, in 3 topics (each with 3+ other people), held for 7 days.
create or replace function public.refresh_my_badges() returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); cnt int;
begin
  if uid is null then return; end if;

  if (select count(*) from public.catalog_items where created_by = uid and sub <> '') >= 25 then
    insert into public.user_badges (user_id, badge) values (uid, 'builder') on conflict do nothing;
  end if;

  if (select extract(year from created_at)::int from public.profiles where id = uid) <= extract(year from now())::int - 2 then
    select count(distinct k) into cnt from public.shelves s, jsonb_object_keys(s.years) k
     where s.user_id = uid and k ~ '^[0-9]{4}$' and coalesce(s.years -> k ->> 'removed', 'false') <> 'true'
       and jsonb_typeof(s.years -> k -> 'top') = 'array' and jsonb_array_length(s.years -> k -> 'top') > 0;
    if cnt >= 3 then insert into public.user_badges (user_id, badge) values (uid, 'timetraveler') on conflict do nothing; end if;
  end if;

  if (select count(*) from public.profiles) >= 10 then
    with latest as (
      select s.user_id, s.cat, s.updated_at,
             s.years -> (select k from jsonb_object_keys(s.years) k where k ~ '^[0-9]{4}$' and k::int <= extract(year from now())::int order by k::int desc limit 1) as snap
        from public.shelves s),
    live as (
      select user_id, cat, updated_at, snap -> 'top' as top from latest
       where snap is not null and coalesce(snap ->> 'removed', 'false') <> 'true'
         and jsonb_typeof(snap -> 'top') = 'array' and jsonb_array_length(snap -> 'top') > 0),
    mine as (select cat, top -> 0 ->> 'n' as pick from live where user_id = uid and updated_at <= now() - interval '7 days')
    select count(*) into cnt from mine m
     where (select count(*) from live l where l.cat = m.cat and l.user_id <> uid) >= 3
       and not exists (select 1 from live l, jsonb_array_elements(l.top) e
                        where l.cat = m.cat and l.user_id <> uid and lower(e ->> 'n') = lower(m.pick));
    if cnt >= 3 then insert into public.user_badges (user_id, badge) values (uid, 'contrarian') on conflict do nothing; end if;
  end if;
end $$;
revoke all on function public.refresh_my_badges() from public, anon;
grant execute on function public.refresh_my_badges() to authenticated;

-- Bug Hunter is by hand: when someone's feedback leads to a real fix, run the Supporter-style line below with 'hunter'.

-- Who has which badge (only for people you are allowed to see).
create or replace function public.badge_board() returns table (user_id uuid, badge text, awarded_at timestamptz)
language sql stable security definer set search_path = public as $$
  select ub.user_id, ub.badge, ub.awarded_at from public.user_badges ub
  where auth.uid() is not null and (
    ub.user_id = auth.uid()
    or exists (select 1 from public.friendships f where f.user_id = auth.uid() and f.friend_id = ub.user_id)
    or coalesce((select value from public.app_config where key = 'alpha_directory'), 'off') = 'on');
$$;
-- How many people hold each badge, out of everyone (for "only 4% of people have this badge").
create or replace function public.badge_stats() returns table (badge text, holders bigint, total bigint)
language sql stable security definer set search_path = public as $$
  select b.id, (select count(*) from public.user_badges ub where ub.badge = b.id), (select count(*) from public.profiles)
  from public.badges b where auth.uid() is not null;
$$;
revoke all on function public.badge_board(), public.badge_stats() from public, anon;
grant execute on function public.badge_board(), public.badge_stats() to authenticated;

-- ---- Your controls (run these yourself in the SQL editor) ----
-- Give someone the Supporter badge (find their id with:  select id, name from profiles;):
--   insert into user_badges (user_id, badge) values ('PASTE-THEIR-ID', 'supporter') on conflict do nothing;
-- Give Bug Hunter the same way (swap 'supporter' for 'hunter'). Find who sent which bug:  select * from alpha_feedback;
-- Take a badge away:
--   delete from user_badges where user_id = 'PASTE-THEIR-ID' and badge = 'supporter';
-- Stop handing out Alpha to new sign-ups (do this when the alpha ends):
--   update app_config set value = 'off' where key = 'alpha_badge';
