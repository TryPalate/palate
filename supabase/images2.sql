-- Run once in Supabase > SQL Editor (after images.sql). Lets the shared picture cache also accept
-- artist/album pictures from Deezer, game icons from Roblox and Pokémon artwork from PokeAPI.
alter table public.item_images drop constraint if exists item_images_url_check;
alter table public.item_images add constraint item_images_url_check check (
  char_length(url) <= 600 and
  url ~ '^https://(upload\.wikimedia\.org|[a-z0-9-]+\.mzstatic\.com|s[0-9]+\.anilist\.co|covers\.openlibrary\.org|image\.tmdb\.org|[a-z0-9-]+\.dzcdn\.net|[a-z0-9]+\.rbxcdn\.com|raw\.githubusercontent\.com/PokeAPI)/'
);
