-- Clears cached photos for the categories whose picture rules changed, so they are looked up again with the new rules.
-- Photos a friend picked by hand ("Wrong photo?") are kept. Run once in the Supabase SQL Editor.
delete from public.item_images
where cat in ('albums','songs','superheroes','villains','characters','cars','motorcycles','watches','fragrances','weapons','aircraft','tech','sneakers',
              'fastfood','restaurants','cafes','brands','airlines','clubs','teams','universities','themeparks')
  and coalesce(src,'') <> 'user-pick';
