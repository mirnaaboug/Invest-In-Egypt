# Subscriptions backend

Built 19 Nov 2026. Supabase project **Egypt Trade Gateway** (`sobptlqqazhcfooytqav`, London). Stripe account **Invest In Egypt**, test mode.

## What is already set up

| Part | Where | Status |
|---|---|---|
| Database: 19 tables, row-level security, access rules, print queue, admin views | Supabase | Live |
| Catalogue: 12 modules, 8 plans, 9 prices | Supabase | Live |
| Storage buckets: `reports` (private PDFs), `report-covers` (public) | Supabase | Live |
| Scheduled jobs: expire lapsed subscriptions (daily), publish scheduled reports (every 30 min) | Supabase pg_cron | Live |
| Edge Functions: `create-checkout`, `billing-portal`, `stripe-webhook` | Supabase | Deployed |
| 6 products and 9 prices, linked to the database | Stripe (test mode) | Live |
| Website: sign in/up, pricing, paywall on 9 modules, checkout, account area (subscriptions, reports, deliveries, profile), EN/AR | `index.html` on GitHub Pages | In this repo |
| Admin page: sign in with an admin or editor account | `admin/index.html` on GitHub Pages | In this repo |

## Packages (placeholder prices, GBP, excl. VAT)

| Package | Unlocks | Price |
|---|---|---|
| Explorer (free account) | Figures, Why Egypt, Sources, a preview of every module | Free |
| Trade Access | Agreements, UK–Egypt trade, Hubs, Toolkit | £39/month or £390/year |
| Market Intelligence | Africa map, Sectors, Market gaps, News | £59/month or £590/year |
| Full Gateway | All 9 paid modules, every report as a PDF, 3 seats, 7-day trial | £99/month or £990/year |
| Institutional | Full Gateway for 25 seats, invoiced | By enquiry |
| Monthly Trade Monitor | 12-page printed brief every month, plus PDF and News | £49/month |
| Quarterly Outlook | 40-page printed report every quarter, plus PDF, News and Sectors | £149/quarter |
| Annual Yearbook | 2 bound copies a year, plus PDF, News, Sectors and Agreements | £349/year |

To change a price: create the new price in Stripe, then update `plan_prices.amount_minor` and `provider_price_id`.

## Setup status (19 Nov 2026)

Done:
- Website and admin page are live on GitHub Pages.
- Supabase login addresses (Site URL and redirect URLs) are set.
- The `SITE_URL` secret is set.
- The Stripe webhook endpoint exists (test mode) and sends the 9 events the backend uses.
- The Stripe customer portal is set up as the default (test mode).

Still to do:
1. **Add the two Stripe secrets** in Supabase → Edge Functions → Secrets (https://supabase.com/dashboard/project/sobptlqqazhcfooytqav/functions/secrets):
   - `STRIPE_SECRET_KEY`: from https://dashboard.stripe.com/test/apikeys (Secret key, starts `sk_test_`).
   - `STRIPE_WEBHOOK_SECRET`: from https://dashboard.stripe.com/test/webhooks → the Egypt Gateway endpoint → Signing secret (starts `whsec_`).
   Until both are set, checkout shows "Online payments aren't switched on yet".
2. **Make yourself admin.** Create an account on the site, then run this in the Supabase SQL editor:
   `update public.profiles set role = 'admin' where email = 'you@example.com';`
   Use `role = 'editor'` for content staff who upload reports.
3. **For real users,** add your own email sender under Supabase → Authentication → Emails → SMTP. Supabase's built-in sender is rate-limited.

Test purchases use Stripe's test card 4242 4242 4242 4242, any future expiry date and any CVC.

## Admin page

**https://mirnaaboug.github.io/Invest-In-Egypt/admin/**

Sign in with your website account. It needs the **admin** or **editor** role (see "Make yourself admin" above). Editors can run the print queue, reports and enquiries. Only admins can grant access, end access or change roles. The database checks every action, so the page can't do anything your role doesn't allow, and anyone else who opens it sees nothing.

| Tab | What you do there |
|---|---|
| Overview | Monthly revenue, active subscriptions, users, payment problems, conversion, a to-do list, the 30-day trend and the most-hit paywalls |
| Subscribers | Search and filter every subscription; open Stripe ones in Stripe; end manual access |
| Print queue | Copy address labels, mark a run as printing, add the carrier and tracking number per delivery |
| Reports | Set each edition's PDF path, publish it (this queues the print run), schedule new editions |
| Users | Grant complimentary or invoiced access; make someone an editor or admin |
| Enquiries | Institutional leads, with a status for each |
| Payments | Stripe invoices and any payment sync errors |
| Leads | Newsletter sign-ups, with a button to copy the emails |

If there are no customers yet, "Preview with sample data" shows it filled in without saving anything.

There's also a copy inside claude.ai that works through your Supabase connector: https://claude.ai/artifact/VG8eUHtw3nKrqtKxgayG5j

## Deploying changes

- **Website and admin page:** commit to `main`. GitHub Pages republishes within a minute or two.
- **Database and server functions:** the code is in `supabase/`. Go to Actions → "Deploy Supabase backend" → Run workflow. This needs two repository secrets, `SUPABASE_ACCESS_TOKEN` and `SUPABASE_DB_PASSWORD`; the workflow file explains where to get them. Everything in `supabase/` is already live, so you only need this when you change something.

## Running it

**Publishing a report**
1. Upload the PDF to the `reports` bucket as `month/…`, `quarter/…` or `year/…`. The folder decides which subscribers can download it.
2. In `public.reports`, set `pdf_path`, then set `status = 'published'`. You can also leave it as `scheduled`, and it publishes automatically at `publish_at`.
3. Publishing queues one print delivery per active subscriber of that frequency, using their saved address. Subscribers without an address are set to `on_hold` until they add one.

**Daily views** (Supabase SQL editor, signed in as admin)
- `select * from admin_print_queue;` lists what to print and post. Update `print_deliveries.status` to `dispatched`, along with `carrier` and `tracking_number`, and subscribers see this in their account.
- `select * from admin_mrr;` shows monthly recurring revenue per package.
- `select * from admin_subscriptions order by created_at desc;` lists every subscriber.
- `select * from admin_funnel_daily order by day desc;` shows paywall views, plan clicks and checkouts.
- `select * from enquiries where status = 'new';` lists institutional leads.
- `select * from webhook_events where error is not null;` shows payment sync problems.

**Institutional or invoiced customers:** insert a row into `subscriptions` with `source = 'invoice'`, `status = 'active'` and a `current_period_end`. You can also attach an `organisation_id` so everyone in `organisation_members` gets access.

## Going live with real payments

The company that collects the money must be registered in a Stripe-supported country (for example the UK). Egypt isn't supported, so an Egyptian entity would need a local gateway such as Paymob. The database is provider-agnostic, so only the three functions would change.

1. Recreate the 6 products and 9 prices in Stripe live mode, then update `plan_prices.provider_price_id`.
2. Swap `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` for the live values, using a new live webhook endpoint.
3. Optionally set up Stripe Tax and add the secret `STRIPE_AUTOMATIC_TAX=true` to charge VAT automatically.

## Files

- `index.html`: the website, including the subscription portal. Backend settings are in `window.GATEWAY_CONFIG` near the end of the file.
- `admin/index.html`: the admin page.
- `supabase/migrations/`: the 4 database migrations, as applied.
- `supabase/functions/`: the 3 server functions, as deployed.
- `supabase/config.toml`: Supabase CLI settings.
- `.github/workflows/supabase-deploy.yml`: the manual deploy workflow.
