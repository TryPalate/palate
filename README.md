# Palate

Your taste, ranked. Just for your friends.

A plain website (no build step) that talks straight to Supabase. Live at https://trypalate.github.io/palate/ (GitHub Pages, about a minute after a push to `main`).

| File | What it is |
|---|---|
| `index.html` | The whole app |
| `config.js` | Public Supabase URL, publishable key, notification public key |
| `sw.js` | Service worker: keeps pictures on the device, shows notifications |
| `supabase/*.sql` | Database setup, run by hand in Supabase > SQL Editor |
| `scripts/notify.mjs` | Sends phone notifications (run by `.github/workflows/notify.yml`) |
| `.github/workflows/` | `keepalive` (daily), `notify` (every 10 minutes), `milestones` (Mondays) |

## Database files, in order

All are safe to run again. Run each one whole in Supabase > SQL Editor.

1. `schema.sql`, `catalog.sql`, `images.sql`, `images2.sql`, `images4.sql`, `images5.sql`
2. `push.sql`, `alpha.sql`, `friends_alpha.sql`, `badges.sql`, `invites.sql`, `unlocks.sql`, `growth.sql`, `hardening.sql`, `delete_account.sql`
3. New: `account.sql` (usernames, settings, notification switches), then `reactions.sql`, then `progression.sql` (new unlocks and the weekly topic), then `guess.sql` (guess a friend's #1 in the weekly topic)

The app works before the new files are run; their features simply stay hidden until then.

Each file ends with a short "Your controls" section: switches you can flip later.

## Before going public

- Run `hardening.sql` and `images4_revert.sql`, and set `SHARE_PHOTO_PICKS = false` in `index.html`.
- Turn off the alpha directory: `update app_config set value = 'off' where key = 'alpha_directory';`
- Supabase > Authentication: minimum password length 8, CAPTCHA on, email confirmation on.
- Supabase > Advisors > Security Advisor: fix anything it lists.
- Privacy policy, terms, minimum age, and a check of picture licences (see About and credits in the app).
- Never commit the `service_role` key.

## Topic links

Shared links and pictures point at a topic with a clean path, e.g. `trypalate.github.io/palate/albums`. Opening one lands a new account straight in building that shelf, free (no pick needed). A friend's `?join=CODE` rides along on links, but the typed address works without it.

- `albums/index.html`, `fastfood/index.html`, … are generated forwarders (a normal page with its own link preview that redirects to `./?c=albums`). After adding a topic to `CATS` in `index.html`, run `node scripts/make-topic-pages.mjs` and commit the new folder.
- `404.html` catches any topic without a folder and forwards it the same way.
