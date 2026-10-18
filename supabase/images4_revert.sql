-- Run this before opening Palate to the public: stops anyone from replacing shared photos.
drop policy if exists "replace shared artwork" on public.item_images;
