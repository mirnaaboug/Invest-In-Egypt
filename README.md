# Invest in Egypt — Trade & Investment Gateway (prototype)

A single-page, mobile-friendly website positioning Egypt as a gateway for trade and investment into Africa, the Middle East and Europe. Built for UK investors, UK exporters, Egyptian businesses and policymakers.

> **Prototype.** Not an official government website. Egypt and UK–Egypt figures are a dated launch snapshot; other African country figures are indicative and must be refreshed before launch.

## What's inside

- `index.html` — the whole site (HTML, CSS and JavaScript in one file, no build step).
- `docs/project-brief.md` — the master brief.
- `docs/build-notes.md` — design direction, data status and open items.
- `.nojekyll` — lets GitHub Pages serve the site as-is.

## Features

- Interactive dotted map of Africa, Europe and the Middle East: region, trade-bloc and market-size views, Egypt's industrial hubs, trade routes, and a profile panel for every African country.
- All 12 brief modules: trade agreements, bilateral framework, UK–Egypt trade charts, sector profiles, Suez Canal and SCZone, investor toolkit, market gaps, news, foreign policy, sources.
- English / Arabic switch (right-to-left layout) and three branding modes (UK Gov style, co-branded, neutral).
- Responsive layout with a mobile menu, touch-friendly map and stacked tables on small screens.
- Every figure links to its source and date in the Data and sources table.

## Run it

Open `index.html` in a browser, or publish with GitHub Pages: **Settings → Pages → Deploy from a branch → `main` / root**.

The map outline loads at runtime from `cdn.jsdelivr.net` (jsVectorMap 1.5.3) and fonts from Google Fonts, so an internet connection is needed.

## Before launch

- Replace indicative African country population/GDP with World Bank / IMF data.
- Verify treaty dates (UK–Egypt BIT 1975, Double Taxation Convention 1977).
- Connect the newsletter form, live currency and news feeds, and PDF one-pagers.
- Add photography in place of the dot-map and line-illustration panels.
- Complete Arabic body text (navigation and headings are translated).
