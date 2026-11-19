# Invest in Egypt — Trade & Investment Gateway (prototype)

A single-page, mobile-friendly website positioning Egypt as a gateway for trade and investment into Africa, the Middle East and Europe. Built for UK investors, UK exporters, Egyptian businesses and policymakers.

> **Prototype.** Not an official government website. Egypt and UK–Egypt figures are a dated launch snapshot; other African country figures are indicative and must be refreshed before launch.

## What's inside

- `index.html` — the whole site (HTML, CSS and JavaScript in one file, no build step), including sign-in, packages and the subscriber account area.
- `admin/index.html` — the admin page: subscribers, revenue, print queue, reports, users, enquiries, payments, leads.
- `supabase/` — the backend: database migrations, server functions (Stripe checkout, billing, webhook) and CLI settings.
- `.github/workflows/supabase-deploy.yml` — deploys `supabase/` on demand.
- `docs/subscriptions-backend.md` — how the subscriptions backend works and the setup steps.
- `docs/project-brief.md` — the master brief.
- `docs/build-notes.md` — design direction, data status and open items.
- `.nojekyll` — lets GitHub Pages serve the site as-is.

## Features

- Interactive dotted map of Africa, Europe and the Middle East: region, trade-bloc and market-size views, Egypt's industrial hubs, trade routes, and a profile panel for every African country.
- All 12 brief modules: trade agreements, bilateral framework, UK–Egypt trade charts, sector profiles, Suez Canal and SCZone, investor toolkit, market gaps, news, foreign policy, sources.
- English / Arabic switch (right-to-left layout) and three branding modes (UK Gov style, co-branded, neutral).
- Responsive layout with a mobile menu, touch-friendly map and stacked tables on small screens.
- Every figure links to its source and date in the Data and sources table.
- Subscriptions: free preview, then paid packages to unlock modules (monthly or yearly) and printed report packages (monthly, quarterly, yearly). Payments through Stripe, accounts and data in Supabase.

## Run it

Publish with GitHub Pages: **Settings → Pages → Deploy from a branch → `main` / root**.

- Website: https://mirnaaboug.github.io/Invest-In-Egypt/
- Admin: https://mirnaaboug.github.io/Invest-In-Egypt/admin/

Opened as a local file or on the claude.ai preview, sign-in and payments run in a clearly labelled demo mode. To take real payments, finish the setup steps in `docs/subscriptions-backend.md`.

The map outline loads at runtime from `cdn.jsdelivr.net` (jsVectorMap 1.5.3) and fonts from Google Fonts, so an internet connection is needed.

## Before launch

- Replace indicative African country population/GDP with World Bank / IMF data.
- Verify treaty dates (UK–Egypt BIT 1975, Double Taxation Convention 1977).
- Finish the payment setup in `docs/subscriptions-backend.md` (Stripe keys, webhook, customer portal, admin account).
- Replace the placeholder package prices.
- Connect live currency and news feeds.
- Add photography in place of the dot-map and line-illustration panels.
- Complete Arabic body text (navigation and headings are translated).
