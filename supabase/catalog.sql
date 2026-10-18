-- Shared catalog of things people add that were not in the built-in lists.
-- Run once in Supabase > SQL Editor. Safe to run twice.
-- When someone adds something new, Palate looks up the year, creator or country,
-- then saves it here so every friend can find it in search straight away.

create table if not exists public.catalog_items (
  cat        text not null check (char_length(cat) <= 40),
  name       text not null check (char_length(name) between 1 and 200),
  sub        text not null default '' check (char_length(sub) <= 160),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  primary key (cat, name)
);
create unique index if not exists catalog_items_cat_lower_name on public.catalog_items (cat, lower(name));

alter table public.catalog_items enable row level security;

drop policy if exists "read catalog items" on public.catalog_items;
create policy "read catalog items" on public.catalog_items for select to authenticated using (true);
drop policy if exists "add catalog items" on public.catalog_items;
create policy "add catalog items" on public.catalog_items for insert to authenticated with check (created_by = auth.uid());

-- To fix a wrong entry for everyone: Table Editor > catalog_items > edit or delete the row.
