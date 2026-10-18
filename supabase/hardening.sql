-- Safety tightening before sharing Palate beyond friends. Run once in Supabase > SQL Editor. Safe to re-run.
-- It does not change anything people see. It only closes small gaps.

-- 1. Stronger invite links: longer and from a secure random source (old links keep working until rotated).
alter table public.profiles alter column invite_code
  set default substr(replace(gen_random_uuid()::text, '-', ''), 1, 16);
create or replace function public.rotate_invite_code() returns text
language plpgsql security definer set search_path = public as $$
declare c text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 16);
begin
  update public.profiles set invite_code = c where id = auth.uid();
  return c;
end $$;

-- 2. Nobody can stuff huge amounts of data into their own rows (storage abuse). Existing rows are not checked.
alter table public.shelves drop constraint if exists shelves_years_size;
alter table public.shelves add constraint shelves_years_size check (octet_length(years::text) <= 100000) not valid;
alter table public.user_settings drop constraint if exists user_settings_custom_size;
alter table public.user_settings add constraint user_settings_custom_size check (octet_length(custom::text) <= 100000) not valid;

-- 3. Photo links must be plain https links (no scripts, no odd characters).
alter table public.item_photos drop constraint if exists item_photos_url_safe;
alter table public.item_photos add constraint item_photos_url_safe
  check (char_length(url) <= 600 and url ~ '^https://[^[:space:]''"()\\]+$') not valid;

-- 4. Your original keepalive table: turn on row level security so the public key can only read it, never change it.
do $$
begin
  if to_regclass('public.keepalive') is not null then
    execute 'alter table public.keepalive enable row level security';
    execute 'drop policy if exists "read keepalive" on public.keepalive';
    execute 'create policy "read keepalive" on public.keepalive for select to anon, authenticated using (true)';
    execute 'revoke insert, update, delete, truncate on public.keepalive from anon, authenticated';
  end if;
end $$;
