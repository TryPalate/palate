-- REACTIONS: friends can react to one pick on your shelf with "Same", "No way" or "Curious".
-- Only you (the shelf's owner) and the person who reacted can see a reaction. No public counts, no pile-ons.
-- Run once in Supabase > SQL Editor, after account.sql. Safe to run again.

create table if not exists public.reactions (
  owner      uuid not null references auth.users(id) on delete cascade,   -- whose shelf
  cat        text not null check (char_length(cat) <= 40),
  item       text not null check (char_length(item) between 1 and 120),
  reactor    uuid not null references auth.users(id) on delete cascade,   -- who reacted
  kind       text not null check (kind in ('same', 'nope', 'curious')),
  seen       boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (owner, cat, item, reactor),
  check (owner <> reactor)
);
create index if not exists reactions_owner_recent on public.reactions (owner, created_at desc);
alter table public.reactions enable row level security;
revoke all on public.reactions from anon, authenticated;
grant select on public.reactions to authenticated;
drop policy if exists reactions_read on public.reactions;
create policy reactions_read on public.reactions for select to authenticated using (owner = auth.uid() or reactor = auth.uid());

-- React to a pick, change your reaction, or take it back (p_kind null).
-- You must be able to see that shelf, and the pick must really be on it.
create or replace function public.react(p_owner uuid, p_cat text, p_item text, p_kind text) returns text
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); sh record;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if p_owner = uid then raise exception 'That is your own shelf'; end if;
  if p_kind is null or p_kind = '' then
    delete from public.reactions where owner = p_owner and cat = p_cat and item = p_item and reactor = uid;
    return null;
  end if;
  if p_kind not in ('same', 'nope', 'curious') then raise exception 'Unknown reaction'; end if;
  select s.years, s.vis into sh from public.shelves s where s.user_id = p_owner and s.cat = p_cat;
  if not found or not public.can_view(p_owner, sh.vis) then raise exception 'You can''t see that shelf'; end if;
  if not exists (select 1 from jsonb_each(sh.years) y,
                   jsonb_array_elements(coalesce(y.value -> 'top', '[]'::jsonb) || coalesce(y.value -> 'hm', '[]'::jsonb)) e
                 where e ->> 'n' = p_item) then raise exception 'That pick is not on the shelf'; end if;
  if (select count(*) from public.reactions where reactor = uid and created_at > now() - interval '1 day') >= 300 then
    raise exception 'That is a lot of reactions for one day. Try again tomorrow.';
  end if;
  insert into public.reactions (owner, cat, item, reactor, kind) values (p_owner, p_cat, p_item, uid, p_kind)
  on conflict (owner, cat, item, reactor) do update
    set kind = excluded.kind,
        created_at = case when reactions.kind = excluded.kind then reactions.created_at else now() end,
        seen = case when reactions.kind = excluded.kind then reactions.seen else false end;
  return p_kind;
end $$;

-- You opened your activity: mark reactions to your picks as seen.
create or replace function public.reactions_seen() returns void
language sql security definer set search_path = public as $$
  update public.reactions set seen = true where owner = auth.uid() and not seen;
$$;

revoke all on function public.react(uuid, text, text, text), public.reactions_seen() from public, anon;
grant execute on function public.react(uuid, text, text, text), public.reactions_seen() to authenticated;

-- Remove reactions when a friendship ends (they could no longer see the shelf anyway).
create or replace function public.drop_reactions_on_unfriend() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.reactions where (owner = old.user_id and reactor = old.friend_id) or (owner = old.friend_id and reactor = old.user_id);
  return old;
end $$;
drop trigger if exists friendships_drop_reactions on public.friendships;
create trigger friendships_drop_reactions after delete on public.friendships for each row execute function public.drop_reactions_on_unfriend();

-- Phone pings for new reactions, used by scripts/notify.mjs with the same key as friend updates.
-- Same rules: only to people who left "Reactions" on, and never between 10pm and 8am their time.
create or replace function public.push_reactions_pending(p_key text, p_as_of timestamptz)
returns table(endpoint text, p256dh text, auth_key text, friend text, cat text, item text, kind text, created_at timestamptz, as_of timestamptz)
language plpgsql security definer set search_path = public as $$
declare t timestamptz := coalesce(p_as_of, now());
begin
  if p_key is distinct from (select value from public.app_config where key = 'push_key') then raise exception 'no'; end if;
  return query
  select s.endpoint, s.p256dh, s.auth_key, p.name, r.cat, r.item, r.kind, r.created_at, t
    from public.push_subscriptions s
    join public.reactions r on r.owner = s.user_id
    join public.profiles p on p.id = r.reactor
    left join public.notify_prefs np on np.user_id = s.user_id
   where r.created_at > s.checked_at and r.created_at <= t and not r.seen
     and coalesce(np.reactions, true)
     and extract(hour from (t - make_interval(mins => s.tz_offset)))::int between 8 and 21
   order by r.created_at desc;
end $$;
revoke all on function public.push_reactions_pending(text, timestamptz) from public;
grant execute on function public.push_reactions_pending(text, timestamptz) to anon, authenticated;

-- ---- Your controls ----
-- Most reacted-to picks:   select cat, item, kind, count(*) from reactions group by 1,2,3 order by 4 desc limit 30;
