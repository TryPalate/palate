-- Makes a photo you upload the shared photo for everyone, and lets the shared table hold uploads.
-- Run once in Supabase > SQL Editor (after images4.sql). Safe to run twice.
-- TEMPORARY while Palate is friends-only. Before going public, run images4_revert.sql and set SHARE_PHOTO_PICKS = false in index.html.

-- 1. Let shared artwork point at your own Supabase photo storage, not only the trusted picture sites.
alter table public.item_images drop constraint if exists item_images_url_check;
alter table public.item_images add constraint item_images_url_check check (
  char_length(url) <= 600 and
  url ~ '^https://([a-z0-9-]+\.mzstatic\.com|upload\.wikimedia\.org|s[0-9]+\.anilist\.co|covers\.openlibrary\.org|image\.tmdb\.org|[a-z0-9-]+\.dzcdn\.net|[a-z0-9]+\.rbxcdn\.com|raw\.githubusercontent\.com/PokeAPI|[a-z0-9]+\.supabase\.co/storage/v1/object/public/photos/)'
);

-- 2. CHECK FIRST: what is the shared picture for these three right now, and what did you upload?
select 'shared default' as kind, cat, name, left(url, 70) as url, src from public.item_images
 where lower(name) in ('panda express','babson college','chick-fil-a')
union all
select 'your upload', cat, name, left(url, 70), null from public.item_photos
 where lower(name) in ('panda express','babson college','chick-fil-a');

-- 3. Make the photos you already uploaded for these three the shared default.
insert into public.item_images (cat, name, url, h, s, src, created_by)
select p.cat, p.name, p.url, p.h, p.s, 'user-upload', p.user_id
  from public.item_photos p
 where lower(p.name) in ('panda express','babson college','chick-fil-a')
   and p.url like 'https://%.supabase.co/storage/v1/object/public/photos/%'
on conflict (cat, name) do update
  set url = excluded.url, h = excluded.h, s = excluded.s, src = excluded.src, created_by = excluded.created_by;
