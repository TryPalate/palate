-- PROGRESSION v3 + THE WEEKLY TOPIC. Run once in Supabase > SQL Editor, after unlocks.sql and account.sql. Safe to run again.
--
-- How unlocking works now:
--   * The first days are free: the popular topics are open and nothing locked is shown at all.
--   * After 3 different days, or 6 shelves, the rest is "revealed" as a gift, with one free pick.
--   * From then on one simple meter: every 3 points = one pick (open any shelf you like).
--       1 point  for each new day you open Palate
--       2 points for answering the weekly topic
--       5 points when a friend joins through your link and makes a shelf
--   * Each week one locked topic is free for everyone. Make that shelf and you keep it.
-- Picks you already used under the old system stay used, and the shelves you opened stay open.

-- 1. The weekly topic. Everyone gets the same one; friends' answers stay hidden until you answer.
create table if not exists public.weekly_topics (
  week     date primary key,                      -- the Monday the week starts
  title    text not null check (char_length(title) between 2 and 60),
  prompt   text not null default '' check (char_length(prompt) <= 120),
  base_cat text not null,                         -- which kind of thing you search for (movies, songs...)
  free_cat text                                   -- a locked topic that is open for everyone this week
);
-- When a week has no row of its own, Palate takes the next one from this list, in order, round and round.
create table if not exists public.weekly_bank (
  id       int primary key,
  title    text not null, prompt text not null default '', base_cat text not null, free_cat text
);
alter table public.weekly_topics enable row level security;
alter table public.weekly_bank enable row level security;
revoke all on public.weekly_topics, public.weekly_bank from anon, authenticated;
insert into public.weekly_bank (id, title, prompt, base_cat, free_cat) values
  (0,  'Comfort movies',                  'The ones you rewatch when you need a lift',  'movies',      'desserts'),
  (1,  'Songs of the year so far',        'What got you through this year',             'songs',       'podcasts'),
  (2,  'No-skip albums',                  'Front to back, every track',                 'albums',      'kdramas'),
  (3,  'Desert island snacks',            'Five snacks, forever',                       'snacks',      'themeparks'),
  (4,  'Cities you''d move to tomorrow',  'Pack up and go: where?',                     'cities',      'manga'),
  (5,  'Shows you''d make a friend watch','The ones you keep recommending',             'tv',          'boardgames'),
  (6,  'Games you lost weekends to',      'Worth every hour',                           'games',       'superheroes'),
  (7,  'Fast food orders you''d defend',  'Your order, your hill',                      'fastfood',    'cocktails'),
  (8,  'Books you''d hand a friend',      'The ones you lend out',                      'books',       'watches'),
  (9,  'Artists you''d see live again',   'Best shows, or the ones you want to see',    'artists',     'comedians'),
  (10, 'Anime to start someone on',       'First-timer friendly',                       'anime',       'pokemon'),
  (11, 'Holiday songs',                   'The ones you play first',                    'songs',       'holidays'),
  (12, 'Best breakfasts',                 'Morning, sorted',                            'breakfast',   'cafes'),
  (13, 'Dream trips',                     'Countries you most want to visit',           'countries',   'wonders'),
  (14, 'Dinner guests',                   'Celebrities you''d want at the table',       'celebrities', 'mythology'),
  (15, 'Sneakers you''d actually wear',   'Not the hype, the ones you''d wear',         'sneakers',    'fragrances')
  on conflict (id) do nothing;

create or replace function public.week_start(t timestamptz default now()) returns date
language sql immutable as $$ select date_trunc('week', t at time zone 'utc')::date $$;

create or replace function public.topic_for(w date) returns public.weekly_topics
language plpgsql stable security definer set search_path = public as $$
declare r public.weekly_topics; b public.weekly_bank; n int;
begin
  select * into r from public.weekly_topics where week = w;
  if found then return r; end if;
  select count(*) into n from public.weekly_bank;
  if n = 0 then return null; end if;
  select * into b from public.weekly_bank order by id offset (((w - date '2026-10-19') / 7) % n + n) % n limit 1;
  r.week := w; r.title := b.title; r.prompt := b.prompt; r.base_cat := b.base_cat; r.free_cat := b.free_cat;
  return r;
end $$;

create table if not exists public.weekly_answers (
  user_id    uuid not null references auth.users(id) on delete cascade,
  week       date not null,
  title      text not null,
  base_cat   text not null,
  top        jsonb not null check (jsonb_typeof(top) = 'array' and jsonb_array_length(top) between 1 and 5 and octet_length(top::text) <= 4000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, week)
);
alter table public.weekly_answers enable row level security;
revoke all on public.weekly_answers from anon, authenticated;
grant select on public.weekly_answers to authenticated;

create or replace function public.answered_week(w date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.weekly_answers where user_id = auth.uid() and week = w);
$$;
-- You see your own answers, and a friend's answer for a week only once you have answered that week yourself.
drop policy if exists weekly_read on public.weekly_answers;
create policy weekly_read on public.weekly_answers for select to authenticated using (
  user_id = auth.uid()
  or (public.answered_week(week) and exists (select 1 from public.friendships f where f.user_id = auth.uid() and f.friend_id = weekly_answers.user_id)));

-- Save (or change) your answer for this week. Up to 5 picks: [{"n":"Name","s":"subtitle","why":"reason"}].
create or replace function public.weekly_answer(p_top jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); w date := public.week_start(); t public.weekly_topics; e jsonb; clean jsonb := '[]'::jsonb;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  t := public.topic_for(w); if t is null then raise exception 'There is no topic this week'; end if;
  if p_top is null or jsonb_typeof(p_top) <> 'array' or jsonb_array_length(p_top) < 1 or jsonb_array_length(p_top) > 5 then raise exception 'Pick 1 to 5'; end if;
  for e in select * from jsonb_array_elements(p_top) loop
    if jsonb_typeof(e) <> 'object' or char_length(coalesce(e->>'n', '')) not between 1 and 120 or char_length(coalesce(e->>'s', '')) > 160 or char_length(coalesce(e->>'why', '')) > 300
       or coalesce(e->>'n', '') ~ '[<>]' or coalesce(e->>'why', '') ~ '[<>]' then raise exception 'One of those picks is not valid'; end if;
    clean := clean || jsonb_build_array(jsonb_build_object('n', e->>'n', 's', coalesce(e->>'s', ''), 'why', coalesce(e->>'why', '')));
  end loop;
  insert into public.weekly_answers (user_id, week, title, base_cat, top) values (uid, w, t.title, t.base_cat, clean)
  on conflict (user_id, week) do update set top = excluded.top, updated_at = now();
  return public.weekly_state();
end $$;

create or replace function public.weekly_state() returns json
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid(); w date := public.week_start(); t public.weekly_topics; mine jsonb; nf int;
begin
  if uid is null then return null; end if;
  t := public.topic_for(w); if t is null then return null; end if;
  select a.top into mine from public.weekly_answers a where a.user_id = uid and a.week = w;
  select count(*) into nf from public.weekly_answers a join public.friendships f on f.user_id = a.user_id and f.friend_id = uid where a.week = w;
  return json_build_object('week', w, 'ends', w + 7, 'title', t.title, 'prompt', t.prompt, 'base_cat', t.base_cat, 'free_cat', t.free_cat,
    'answered', mine is not null, 'mine', mine, 'friends_answered', nf);
end $$;

revoke all on function public.weekly_answer(jsonb), public.weekly_state(), public.answered_week(date), public.topic_for(date) from public, anon;
grant execute on function public.weekly_answer(jsonb), public.weekly_state(), public.answered_week(date) to authenticated;

-- 2. The new unlock state. Same name as before, so older copies of the app keep working.
insert into public.app_config values ('unlock_points_per_pick', '3') on conflict (key) do nothing;
create or replace function public.unlock_state() returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); inv int; d int; sh int; wk int; pts int; per int; rev boolean; fresh text[] := '{}';
        gifts int; earned int; used int; cats text[]; cust boolean; t public.weekly_topics;
begin
  if uid is null then return null; end if;
  insert into public.activity_days (user_id, day) values (uid, current_date) on conflict do nothing;
  select count(*) into inv from public.profiles p where p.invited_by = uid and exists (select 1 from public.shelves s where s.user_id = p.id);
  select count(*) into d   from public.activity_days where user_id = uid;
  select count(*) into sh  from public.shelves where user_id = uid and cat not like 'my:%';
  select count(*) into wk  from public.weekly_answers where user_id = uid;
  per := greatest(1, coalesce((select value::int from public.app_config where key = 'unlock_points_per_pick'), 3));
  pts := d + 2 * wk + 5 * inv;
  rev := exists (select 1 from public.user_unlocks where user_id = uid and pack = 'reward:reveal');
  if not rev and (d >= 3 or sh >= 6) then
    insert into public.user_unlocks (user_id, pack) values (uid, 'reward:reveal') on conflict do nothing; rev := true; fresh := fresh || 'reveal'::text;
  end if;
  if inv >= 3 then
    insert into public.user_unlocks (user_id, pack) values (uid, 'reward:custom') on conflict do nothing;
    if found then fresh := fresh || 'custom'::text; end if;
  end if;
  select count(*) into gifts from public.user_unlocks where user_id = uid and pack like 'reward:gift%';
  earned := (case when rev then 1 + pts / per else 0 end) + gifts;
  select coalesce(array_agg(pack), '{}') into cats from public.user_unlocks
    where user_id = uid and pack not like 'reward:%' and pack not in ('eats','screen','places','style','culture','deep','custom');
  used := coalesce(array_length(cats, 1), 0);
  -- Nobody gets fewer picks than the old rules already gave them
  earned := greatest(earned, gifts + (select count(*) from public.user_unlocks u join public.unlock_rewards w on u.pack = 'reward:' || w.id
                                       where u.user_id = uid and w.grants = 'pick' and u.pack not like 'reward:gift%'));
  cust := exists (select 1 from public.user_unlocks where user_id = uid and pack in ('reward:custom', 'custom'));
  t := public.topic_for(public.week_start());
  return json_build_object(
    'v', 3,
    'gate', coalesce((select value from public.app_config where key = 'unlock_gate'), 'off') = 'on',
    'supporter', public.is_supporter(uid),
    'revealed', rev, 'invites', inv, 'days', d, 'shelves', sh, 'weekly', wk,
    'points', pts, 'per_pick', per, 'to_next', case when rev then per - (pts % per) else null end,
    'picks_left', greatest(0, earned - used), 'unlocked', to_json(cats), 'custom', cust, 'fresh', to_json(fresh),
    'free_cat', t.free_cat);
end $$;
revoke all on function public.unlock_state() from public, anon;
grant execute on function public.unlock_state() to authenticated;

-- 3. A weekly ping when the new topic is out (Monday, from 10am your time), for people who left "Weekly topic" on
--    and have not answered yet. Used by scripts/notify.mjs.
alter table public.push_subscriptions add column if not exists weekly_sent date;
create or replace function public.push_weekly_pending(p_key text)
returns table(endpoint text, p256dh text, auth_key text, title text, prompt text, week date)
language plpgsql security definer set search_path = public as $$
declare w date := public.week_start(); t public.weekly_topics;
begin
  if p_key is distinct from (select value from public.app_config where key = 'push_key') then raise exception 'no'; end if;
  t := public.topic_for(w); if t is null then return; end if;
  return query
  select s.endpoint, s.p256dh, s.auth_key, t.title, t.prompt, w
    from public.push_subscriptions s
    left join public.notify_prefs np on np.user_id = s.user_id
   where coalesce(np.weekly, true)
     and (s.weekly_sent is null or s.weekly_sent < w)
     and not exists (select 1 from public.weekly_answers a where a.user_id = s.user_id and a.week = w)
     and extract(hour from (now() - make_interval(mins => s.tz_offset)))::int between 10 and 20;
end $$;
create or replace function public.push_weekly_done(p_key text, p_endpoints text[], p_week date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_key is distinct from (select value from public.app_config where key = 'push_key') then raise exception 'no'; end if;
  update public.push_subscriptions set weekly_sent = p_week where endpoint = any(p_endpoints);
end $$;
revoke all on function public.push_weekly_pending(text), public.push_weekly_done(text, text[], date) from public;
grant execute on function public.push_weekly_pending(text), public.push_weekly_done(text, text[], date) to anon, authenticated;

-- ---- Your controls ----
-- Faster or slower unlocking (points per pick):   update app_config set value = '4' where key = 'unlock_points_per_pick';
-- Set a specific week's topic (it wins over the list):
--   insert into weekly_topics (week, title, prompt, base_cat, free_cat) values ('2026-11-02', 'Comfort movies', 'The ones you rewatch', 'movies', 'desserts')
--   on conflict (week) do update set title = excluded.title, prompt = excluded.prompt, base_cat = excluded.base_cat, free_cat = excluded.free_cat;
-- Add to the rotating list:   insert into weekly_bank values (16, 'Title', 'Short line', 'movies', 'cheese');
-- How many answered this week:   select count(*) from weekly_answers where week = week_start();
-- Give someone a free pick:   insert into user_unlocks (user_id, pack) values ('PASTE-THEIR-ID', 'reward:gift-' || gen_random_uuid()) on conflict do nothing;
-- Turn all locks off (everything open):   update app_config set value = 'off' where key = 'unlock_gate';
