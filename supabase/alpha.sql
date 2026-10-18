-- ALPHA: feedback, quality checks and a weekly report. Run once in Supabase > SQL Editor.
-- Safe to run again. Run supabase/catalog.sql and supabase/images5.sql first.

-- 1. Feedback and "I could not find it" reports ----------------------------------------------
create table if not exists public.feedback (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid(),
  kind       text not null check (kind in ('idea','bug','missing','miss')),
  cat        text check (cat is null or char_length(cat) <= 40),
  item       text check (item is null or char_length(item) <= 120),
  text       text check (text is null or char_length(text) <= 1000),
  created_at timestamptz not null default now(),
  check (item is not null or text is not null)
);
alter table public.feedback enable row level security;
drop policy if exists "send feedback" on public.feedback;
create policy "send feedback" on public.feedback for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "read own feedback" on public.feedback;
create policy "read own feedback" on public.feedback for select to authenticated using (user_id = auth.uid());

-- 2. Quality checks on what people add --------------------------------------------------------
-- No links, no markup, sensible lengths, and a daily cap per person so one account cannot flood the catalog.
alter table public.catalog_items drop constraint if exists catalog_items_clean;
alter table public.catalog_items add constraint catalog_items_clean check (
  char_length(trim(name)) between 2 and 120 and char_length(coalesce(sub, '')) <= 160
  and name !~* '(<|>|https?:|www\.)' and coalesce(sub, '') !~* '(<|>|https?:|www\.)') not valid;

create or replace function public.alpha_cap() returns trigger language plpgsql security definer set search_path = public as $$
declare lim int := tg_argv[0]::int; n int;
begin
  if auth.uid() is null then return new; end if;                       -- you, in the SQL editor
  execute format('select count(*) from public.%I where created_by = $1 and created_at > now() - interval ''1 day''', tg_table_name) into n using auth.uid();
  if n >= lim then raise exception 'daily limit reached'; end if;
  return new;
end $$;
drop trigger if exists cap_catalog on public.catalog_items;
create trigger cap_catalog before insert on public.catalog_items for each row execute function public.alpha_cap(300);
drop trigger if exists cap_images on public.item_images;
create trigger cap_images before insert on public.item_images for each row execute function public.alpha_cap(400);

create or replace function public.feedback_cap() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and (select count(*) from public.feedback where user_id = auth.uid() and created_at > now() - interval '1 day') >= 150
  then raise exception 'daily limit reached'; end if;
  return new;
end $$;
drop trigger if exists cap_feedback on public.feedback;
create trigger cap_feedback before insert on public.feedback for each row execute function public.feedback_cap();

-- 3. What to read each week (you only, in the SQL editor; the app cannot see these) -----------
create or replace view public.alpha_misses as
  select cat, lower(item) as wanted, count(*) as times, count(distinct user_id) as people, max(created_at) as last_seen
  from public.feedback where kind in ('miss','missing') group by 1, 2 order by people desc, times desc;

create or replace view public.alpha_feedback as
  select f.created_at, p.name, f.kind, f.cat, f.item, f.text
  from public.feedback f left join public.profiles p on p.id = f.user_id
  where f.kind in ('idea','bug') or f.text is not null order by f.created_at desc;

-- Most-loved things: how many people have each item in their current top 5 (public shelves only).
create or replace view public.alpha_popular as
  select s.cat, i->>'n' as name, count(distinct s.user_id) as people
  from public.shelves s
  cross join lateral jsonb_each(s.years) y
  cross join lateral jsonb_array_elements(coalesce(y.value->'top', '[]'::jsonb)) i
  where s.vis <> 'private' and y.key = (select max(k) from jsonb_object_keys(s.years) k)
  group by 1, 2 order by people desc, 1, 2;

create or replace view public.alpha_catalog_growth as
  select date_trunc('day', created_at)::date as day, 'items' as kind, count(*) from public.catalog_items group by 1
  union all select date_trunc('day', created_at)::date, 'pictures', count(*) from public.item_images group by 1 order by 1 desc;

revoke all on public.alpha_misses, public.alpha_feedback, public.alpha_popular, public.alpha_catalog_growth from anon, authenticated;
-- Read them with:  select * from alpha_misses limit 50;   select * from alpha_popular limit 50;
--                  select * from alpha_feedback limit 50; select * from alpha_catalog_growth;
-- Existing rows are not re-checked (NOT VALID); to clean one up: Table Editor > catalog_items > delete the row.
