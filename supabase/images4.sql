-- Lets a friend's "Wrong photo?" pick replace the shared photo for everyone. Run once in the Supabase SQL Editor.
-- TEMPORARY while the app is friends-only. Before going public, run images4_revert.sql and set SHARE_PHOTO_PICKS = false in index.html.
create policy "replace shared artwork" on public.item_images for update to authenticated
  using (true) with check (created_by = auth.uid());
