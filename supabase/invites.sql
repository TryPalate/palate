-- INVITE PREVIEW. Run once in Supabase > SQL Editor. Safe to run again.
-- Lets the sign-up page say "Sam shared their top 5 albums" BEFORE the new person has an account.
-- It only returns the name and id of whoever owns the invite code, and only to someone who already holds that exact code.

create or replace function public.invite_preview(p_code text) returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select p.id, p.name from public.profiles p where p.invite_code = p_code and char_length(p_code) between 6 and 40 limit 1;
$$;
revoke all on function public.invite_preview(text) from public;
grant execute on function public.invite_preview(text) to anon, authenticated;
