-- Palate database. Paste this whole file into Supabase > SQL Editor > Run.
-- Safe to run once on a fresh project. Your existing `keepalive` table is left alone.

-- ============ Tables ============

create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 40),
  invite_code text not null unique default substr(md5(random()::text || clock_timestamp()::text), 1, 10),
  created_at  timestamptz not null default now()
);

-- One row per direction. (user_id, friend_id) means "friend_id is one of user_id's friends".
-- `close` is user_id's own choice: do I count friend_id as a close friend?
create table public.friendships (
  user_id    uuid not null references auth.users(id) on delete cascade,
  friend_id  uuid not null references auth.users(id) on delete cascade,
  close      boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);

-- One row per person per category. `years` holds the whole history, e.g.
-- {"2025": {"top":[{"n":"SZA","s":"Artist","why":""}], "hm":[]}, "2026": {...}}
create table public.shelves (
  user_id    uuid not null references auth.users(id) on delete cascade,
  cat        text not null check (char_length(cat) <= 40),
  years      jsonb not null default '{}'::jsonb,
  vis        text not null default 'friends' check (vis in ('friends', 'close', 'private')),
  pos        int  not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, cat)
);

create table public.item_photos (
  user_id uuid not null references auth.users(id) on delete cascade,
  cat     text not null,
  name    text not null,
  url     text not null,
  h       int,
  s       int,
  primary key (user_id, cat, name)
);

-- Private per-user extras (custom items someone added to a category).
create table public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  custom  jsonb not null default '{}'::jsonb
);

create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

create trigger shelves_touch before update on public.shelves
  for each row execute function public.touch_updated_at();

-- ============ Who can see a shelf ============
-- You always see your own. Others need to be in your friends list, and a
-- 'close' shelf also needs you to have marked them as a close friend.

create or replace function public.can_view(owner uuid, v text) returns boolean
language sql stable security definer set search_path = public as $$
  select owner = auth.uid()
      or (v <> 'private' and exists (
            select 1 from public.friendships f
            where f.user_id = owner and f.friend_id = auth.uid()
              and (v = 'friends' or f.close)));
$$;

-- ============ Row level security ============

alter table public.profiles      enable row level security;
alter table public.friendships   enable row level security;
alter table public.shelves       enable row level security;
alter table public.item_photos   enable row level security;
alter table public.user_settings enable row level security;

create policy "see me and my friends" on public.profiles for select to authenticated
  using (id = auth.uid() or exists (
    select 1 from public.friendships f where f.user_id = auth.uid() and f.friend_id = profiles.id));
create policy "create my profile" on public.profiles for insert to authenticated
  with check (id = auth.uid());
create policy "edit my profile" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy "see my friend list" on public.friendships for select to authenticated
  using (user_id = auth.uid());
create policy "edit my close flags" on public.friendships for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
-- Friendships are created and removed only through the functions below.

create policy "see shelves I am allowed to" on public.shelves for select to authenticated
  using (public.can_view(user_id, vis));
create policy "add my shelves" on public.shelves for insert to authenticated
  with check (user_id = auth.uid());
create policy "change my shelves" on public.shelves for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "delete my shelves" on public.shelves for delete to authenticated
  using (user_id = auth.uid());

-- A photo is visible only if the shelf it belongs to is visible to you.
create policy "see photos of visible shelves" on public.item_photos for select to authenticated
  using (user_id = auth.uid() or exists (
    select 1 from public.shelves s where s.user_id = item_photos.user_id and s.cat = item_photos.cat));
create policy "add my photos" on public.item_photos for insert to authenticated
  with check (user_id = auth.uid());
create policy "change my photos" on public.item_photos for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "delete my photos" on public.item_photos for delete to authenticated
  using (user_id = auth.uid());

create policy "my settings" on public.user_settings for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- People may only change their name and the close flag, nothing else.
revoke update on public.profiles    from authenticated;
revoke update on public.friendships from authenticated;
grant  update (name)  on public.profiles    to authenticated;
grant  update (close) on public.friendships to authenticated;

-- ============ Friend invites ============

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
  return other.name;
end $$;

create or replace function public.remove_friend(fid uuid) returns void
language sql security definer set search_path = public as $$
  delete from public.friendships
   where (user_id = auth.uid() and friend_id = fid) or (user_id = fid and friend_id = auth.uid());
$$;

create or replace function public.rotate_invite_code() returns text
language plpgsql security definer set search_path = public as $$
declare c text := substr(md5(random()::text || clock_timestamp()::text), 1, 10);
begin
  update public.profiles set invite_code = c where id = auth.uid();
  return c;
end $$;

revoke all on function public.add_friend_by_code(text) from public, anon;
revoke all on function public.remove_friend(uuid)      from public, anon;
revoke all on function public.rotate_invite_code()     from public, anon;
grant execute on function public.add_friend_by_code(text) to authenticated;
grant execute on function public.remove_friend(uuid)      to authenticated;
grant execute on function public.rotate_invite_code()     to authenticated;

-- ============ Photo storage ============
-- Public bucket, but every file lives at <your user id>/<random id>.jpg, so a link
-- is only discoverable by people who can already see that shelf.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 1048576, array['image/jpeg'])
on conflict (id) do nothing;

create policy "photos: upload to my folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos: see my files" on storage.objects for select to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos: replace my files" on storage.objects for update to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos: delete my files" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
