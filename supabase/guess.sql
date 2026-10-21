-- GUESS THEIR #1: after you answer the weekly topic, guess each friend's #1 before their picks are shown.
-- A right guess is worth 1 point toward your next shelf pick, at most 2 points a week. The server decides if a guess is right.
-- Run once in Supabase > SQL Editor, after progression.sql. Safe to run again.

create table if not exists public.weekly_guesses (
  guesser    uuid not null references auth.users(id) on delete cascade,
  friend     uuid not null references auth.users(id) on delete cascade,
  week       date not null,
  guess      text,                                  -- null when you chose "just show me"
  correct    boolean not null default false,
  skipped    boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (guesser, friend, week),
  check (guesser <> friend)
);
alter table public.weekly_guesses enable row level security;
revoke all on public.weekly_guesses from anon, authenticated;
grant select on public.weekly_guesses to authenticated;
drop policy if exists weekly_guesses_own on public.weekly_guesses;
create policy weekly_guesses_own on public.weekly_guesses for select to authenticated using (guesser = auth.uid());

-- One guess per friend per week. p_item null (or empty) means "just show me": no points, and it is recorded so it cannot be retried.
create or replace function public.guess_weekly(p_friend uuid, p_item text) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); w date := public.week_start(); ans jsonb; answer text; g public.weekly_guesses; ok boolean; skip boolean; n int; awarded boolean := false;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if p_friend = uid then raise exception 'That is you'; end if;
  if not exists (select 1 from public.friendships f where f.user_id = uid and f.friend_id = p_friend) then raise exception 'You can only guess friends'; end if;
  if not public.answered_week(w) then raise exception 'Answer the weekly topic first'; end if;
  select a.top into ans from public.weekly_answers a where a.user_id = p_friend and a.week = w;
  if ans is null then raise exception 'They have not answered yet'; end if;
  answer := ans -> 0 ->> 'n';
  perform pg_advisory_xact_lock(hashtext(uid::text || p_friend::text));
  select * into g from public.weekly_guesses where guesser = uid and friend = p_friend and week = w;
  if found then
    return json_build_object('correct', g.correct, 'answer', answer, 'skipped', g.skipped, 'awarded', false, 'already', true);
  end if;
  skip := p_item is null or btrim(p_item) = '';
  if not skip and not exists (select 1 from jsonb_array_elements(ans) e where lower(e ->> 'n') = lower(btrim(p_item))) then raise exception 'Pick one of the options'; end if;
  ok := not skip and lower(btrim(p_item)) = lower(answer);
  insert into public.weekly_guesses (guesser, friend, week, guess, correct, skipped) values (uid, p_friend, w, case when skip then null else btrim(p_item) end, ok, skip);
  if ok then select count(*) into n from public.weekly_guesses where guesser = uid and week = w and correct; awarded := n <= 2; end if;
  return json_build_object('correct', ok, 'answer', answer, 'skipped', skip, 'awarded', awarded, 'already', false);
end $$;
revoke all on function public.guess_weekly(uuid, text) from public, anon;
grant execute on function public.guess_weekly(uuid, text) to authenticated;

-- The unlock meter now counts correct guesses (this replaces unlock_state() from progression.sql).
create or replace function public.unlock_state() returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); inv int; d int; sh int; wk int; gp int; pts int; per int; rev boolean; fresh text[] := '{}';
        gifts int; earned int; used int; cats text[]; cust boolean; t public.weekly_topics;
begin
  if uid is null then return null; end if;
  insert into public.activity_days (user_id, day) values (uid, current_date) on conflict do nothing;
  select count(*) into inv from public.profiles p where p.invited_by = uid and exists (select 1 from public.shelves s where s.user_id = p.id);
  select count(*) into d   from public.activity_days where user_id = uid;
  select count(*) into sh  from public.shelves where user_id = uid and cat not like 'my:%';
  select count(*) into wk  from public.weekly_answers where user_id = uid;
  per := greatest(1, coalesce((select value::int from public.app_config where key = 'unlock_points_per_pick'), 3));
  -- correct guesses at friends' weekly #1: 1 point each, at most 2 a week
  select coalesce(sum(least(2, n)), 0) into gp from (select count(*) as n from public.weekly_guesses where guesser = uid and correct group by week) g;
  pts := d + 2 * wk + 5 * inv + gp;
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
    'revealed', rev, 'invites', inv, 'days', d, 'shelves', sh, 'weekly', wk, 'guess_points', gp,
    'points', pts, 'per_pick', per, 'to_next', case when rev then per - (pts % per) else null end,
    'picks_left', greatest(0, earned - used), 'unlocked', to_json(cats), 'custom', cust, 'fresh', to_json(fresh),
    'free_cat', t.free_cat);
end $$;
revoke all on function public.unlock_state() from public, anon;
grant execute on function public.unlock_state() to authenticated;

-- ---- Your controls ----
-- Guesses made this week:   select count(*), count(*) filter (where correct) from weekly_guesses where week = week_start();
-- Change what a guess is worth: edit the "least(2, n)" cap and the "+ gp" term in unlock_state() above.
