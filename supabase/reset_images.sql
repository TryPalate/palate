-- Run once in Supabase > SQL Editor. Clears the shared picture cache so every picture is looked up again
-- with the improved matching (fixes wrong ones like the Chipotle spice, logos instead of faces, odd book covers).
-- Your own uploaded photos are not touched.
delete from public.item_images;
