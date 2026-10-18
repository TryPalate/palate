-- ALPHA: a list of everyone on Palate, with one-tap "Add friend". Run once in Supabase > SQL Editor. Safe to run again.
-- Only for the alpha, while everyone on Palate is your friend. Before beta, turn it off (one line at the bottom)
-- and replace it with contacts or invite links, because this shows every member's name to every other member.

create table if not exists public.app_config (key text primary key, value text not null);
alter table public.app_config enable row level security;
revoke all on public.app_config from anon, authenticated;
insert into public.app_config values ('alpha_directory', 'on') on conflict (key) do nothing;

-- Profile picture: which of the 3 gradients a person picked (0, 1 or 2).
alter table public.profiles add column if not exists avatar smallint not null default 0 check (avatar between 0 and 2);
create or replace function public.set_avatar(p_i int) returns void language sql security definer set search_path = public as $$
  update public.profiles set avatar = greatest(0, least(2, p_i)) where id = auth.uid();
$$;
revoke all on function public.set_avatar(int) from public, anon;
grant execute on function public.set_avatar(int) to authenticated;

drop function if exists public.alpha_people();
create or replace function public.alpha_people() returns table (id uuid, name text, avatar smallint)
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if coalesce((select value from public.app_config where key = 'alpha_directory'), 'off') <> 'on' then return; end if;
  return query
    select p.id, p.name, p.avatar from public.profiles p
    where p.id <> auth.uid()
      and not exists (select 1 from public.friendships f where f.user_id = auth.uid() and f.friend_id = p.id)
    order by lower(p.name), p.created_at limit 300;
end $$;

create or replace function public.alpha_add_friend(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare other_name text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if coalesce((select value from public.app_config where key = 'alpha_directory'), 'off') <> 'on' then raise exception 'Adding from the list is turned off'; end if;
  if p_id = auth.uid() then raise exception 'That is you'; end if;
  select name into other_name from public.profiles where id = p_id;
  if not found then raise exception 'That person was not found'; end if;
  insert into public.friendships (user_id, friend_id) values (auth.uid(), p_id), (p_id, auth.uid()) on conflict do nothing;
  return other_name;
end $$;

revoke all on function public.alpha_people(), public.alpha_add_friend(uuid) from public, anon;
grant execute on function public.alpha_people(), public.alpha_add_friend(uuid) to authenticated;

-- Turn it off later:   update app_config set value = 'off' where key = 'alpha_directory';

-- Your own accounts (you only, in the SQL editor): who is who, so you can tell which one is your main one.
--   select u.email, p.name, p.created_at::date as made, (select count(*) from shelves s where s.user_id = p.id) as shelves,
--          (select count(*) from friendships f where f.user_id = p.id) as friends
--   from profiles p join auth.users u on u.id = p.id order by p.created_at;
-- To remove an extra account: Supabase > Authentication > Users > the account > Delete user. Its shelves and friendships go with it.
