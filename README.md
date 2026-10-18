# Palate

Your taste, ranked. Just for your friends.

A plain website (no build step) that talks straight to Supabase.

| File | What it is |
|---|---|
| `index.html` | The whole app |
| `config.js` | Your Supabase URL and publishable key |
| `supabase/schema.sql` | Creates every table, privacy rule and the photo bucket |
| `.github/workflows/keepalive.yml` | Daily ping so the free Supabase project never pauses |

## Setup (about 15 minutes)

1. **Supabase, database.** SQL Editor > New query > paste all of `supabase/schema.sql` > Run. You should see "Success".
2. **Supabase, sign-in.** Authentication > Sign In / Providers > Email: turn **Confirm email** OFF (the free email sender is limited to a couple of emails per hour, so confirmation emails would block your friends). Save.
3. **config.js.** The URL is already filled in. Replace `YOUR_PUBLISHABLE_KEY` with your `sb_publishable_...` key.
4. **GitHub.** In your `palate` repo: Add file > Upload files > drag in everything from this folder (including the `.github` and `supabase` folders). Commit.
5. **Vercel.** vercel.com > sign in with GitHub > Add New Project > pick `palate` > Deploy. No settings to change. You get a link like `palate-xxxx.vercel.app`.
6. **Supabase, link.** Authentication > URL Configuration > set Site URL to your Vercel link.

## Try it

Make an account, add a shelf, then open **Friends**, copy your invite link, and open it in a private window to create a second account. The two should appear as friends, and a shelf set to "Only me" should not show up for the other account.

## Notes

- Changes go live a minute after you commit to GitHub.
- Photos are resized to about 30 KB and stored in Supabase Storage (1 GB free).
- There is no password reset yet. Don't forget your password while testing.

## Before going public (reminder)
Friends can currently replace the shared photo for an item via "Wrong photo?". Before opening the app up:
1. Set `SHARE_PHOTO_PICKS = false` in `index.html`.
2. Run `supabase/images4_revert.sql` in the Supabase SQL Editor.
Also review image licensing (see earlier notes) before charging for anything.


## Safety checklist before sharing beyond friends
- Run `supabase/hardening.sql` and `supabase/images4_revert.sql`, and set `SHARE_PHOTO_PICKS = false` in `index.html`.
- Supabase > Authentication: minimum password length 8, turn on CAPTCHA, keep email confirmation on.
- Supabase > Advisors > Security Advisor: fix anything it lists.
- Never commit the `service_role` key.
