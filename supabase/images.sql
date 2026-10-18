-- Shared artwork cache. Run this once in Supabase > SQL Editor (a new query tab).
-- The first person whose browser finds a picture for "Interstellar" saves it here,
-- and everyone after that gets it instantly without searching again.

create table public.item_images (
  cat        text not null check (char_length(cat) <= 40),
  name       text not null check (char_length(name) <= 200),
  url        text not null check (
               char_length(url) <= 600 and
               url ~ '^https://(upload\.wikimedia\.org|[a-z0-9-]+\.mzstatic\.com|s[0-9]+\.anilist\.co|covers\.openlibrary\.org|image\.tmdb\.org)/'),
  h          int,
  s          int,
  src        text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  primary key (cat, name)
);

alter table public.item_images enable row level security;

-- Any signed-in friend can read. They can add new rows, but only from the trusted
-- picture sites above, and nobody can edit or delete a row from the app.
create policy "read shared artwork" on public.item_images for select to authenticated using (true);
create policy "add shared artwork"  on public.item_images for insert to authenticated with check (created_by = auth.uid());

-- To fix a wrong picture for everyone: Table Editor > item_images > delete that row.
