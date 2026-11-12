# HANDOFF — Poulson Prints ERP

**Any AI or teammate picking this up: start here.** Read this file, then `SPEC.md` (the design) and `RUBRIC.md` (the grading).
Do **not** read the PDF unless you must; it costs far more tokens than `SPEC.md`, which contains the same content.

## Project in one paragraph

GSCM 401 (BYU) team project: build a working mini-ERP for a fictional 3D-printing business, Poulson Prints. It must cover all 12 required capabilities in `RUBRIC.md`, add wow factors, and every displayed number must be computed from stored data. Stack: React + TypeScript (Vite) on GitHub Pages, Supabase (Postgres + Auth + Realtime), EmailJS. **Due Dec 2, 2026, 11:30pm.** Live 10-minute demo for Dr. Wright.

## Repo

- GitHub: https://github.com/BYUSection2Team8/ERP-system-repository
- Branch: `main`
- Only one person pushes at a time. Run `git pull` before starting work.

## Rules for working on this project

1. **Work one phase at a time** (see below). Start each phase in a fresh AI session to keep token use down.
2. At the end of every work session: update the **Status** and **Session log** sections below, then commit and push.
3. Never put secrets in code or chat: no Supabase service_role key, no DB password. The anon key goes in GitHub Actions secrets / a local `.env` that is gitignored.
4. Inventory, costs, and financials are always **derived from transactions** (ledger), never typed in.
5. Multi-step business actions (sale, return, receive, production issue/complete, transfer) are **Postgres functions** so they succeed or fail as a whole.
6. Verify behavior, don't assume it: after each phase, run the app and check the numbers by hand on at least one example.

## Scope: LEAN CORE first

We are building the **lean core** now: the 12 rubric capabilities done correctly, nothing extra.
The exact core vs. stretch split is the table at the top of `SPEC.md`. **Do not build stretch features until Phase 10.**

## Extension points (leave room for the stretch features)

Build the core so later features plug in without rewrites:

1. **Feature folders.** Each module lives in `src/features/<module>/` (inventory, pos, sales, production, purchasing, mrp, returns, finance, reports, portal). Navigation is generated from one route registry file (`src/app/routes.ts`), so a new module is one new folder + one registry entry.
2. **Settings are key/value rows** in a `settings` table (key, value, type, description). New settings (shipping zones, purge grams, capacity limits…) are new rows, not schema changes.
3. **One way to move inventory and money.** Every business action is a Postgres function that writes to `inventory_txn` (item, location, qty, unit_cost, `source_type`, `source_id`) and `ledger` (account, debit, credit, `source_type`, `source_id`). Stretch features (spools, failures, quotes) post the same way with new `source_type` values.
4. **Generic reason codes** in one `reason_codes` table with a `category` column (adjustment, return, scrap). Failure analytics later just adds a `print_failure` category and reads existing data.
5. **`activity_log` table in core** (who, what, when, link). Core writes to it from every Postgres function; the live activity feed UI comes later.
6. **Room in key tables:** `sales_orders.tracking_token` (nullable, for order tracking), `sales_orders.stage` (nullable, for detailed tracking stages), `customers.email`, `items.length_in/width_in/height_in` (nullable, for box selection and capacity), `production_orders.printer_id` (nullable; `printers` table added later).
7. **Database changes as numbered migration files** in `supabase/migrations/` (`001_schema.sql`, `002_functions.sql`, …). Never edit an applied migration; add a new one.
8. **Calculations live in one place.** ROP, EOQ, MRP netting, cost roll-up, turnover go in SQL views/functions or `src/lib/calc/`, never inside screens, so "Show the math" panels can later display the same inputs.

## Phased build plan

Each phase is sized for roughly one focused AI session. Check boxes as phases finish.

| # | Phase | Delivers | Rubric caps |
|---|---|---|---|
| 0 | **Setup** | Accounts (team Gmail, Supabase), Vite + React + TS skeleton, GitHub Pages deploy via Actions, Supabase connection, login screen | 12 (partial) |
| 1 | **Database schema** | Core tables + extension-point columns above, ledger, RLS policies, core Postgres functions (sale, transfer, adjust, receive, production issue/complete, return), settings rows | foundation |
| 2 | **Starter seed data** | 47 items (filament stocked in grams), BOMs, locations incl. QA Hold, suppliers, ~5 test customers, opening inventory posted as receipts. Enough to build and test screens. | Starting Data (partial) |
| 3 | **App shell + Inventory + Barcodes** | Navigation, layout/branding, on-hand by location, transfers, adjustments w/ reason codes, backorders, Code 128 label printing, camera scanning | 2, 3 |
| 4 | **POS + Sales Orders** | POS with scan-to-add, tax, discount, receipt; SO create & status flow (Placed → Fulfilled → Closed/Cancelled) | 1, 4 |
| 5 | **Production + MRP** | Production orders (issue/complete/scrap), cost roll-up, production report & 3 metrics; MRP 4-week view with one-click PO | 6, 8 |
| 6 | **Full customers + 6-month history** | All 60 customers (11 portal logins + demo), 6 months of sales from the demand model, PO history, production history, failures — generated by running the real Postgres functions from phases 1–5 so every balance is derived | Starting Data |
| 7 | **Purchasing + Suppliers** | Suppliers, POs, receiving, ROP/EOQ/periodic review, supplier scorecard, AP | 7 |
| 8 | **Returns + Financials** | Returns/exchanges with QA Hold & restocking fee; P&L, valuation, turnover | 5, 9 |
| 9 | **Reports + Customer portal + Realtime** | Manager reports; customer login, inventory by location, pickup orders; Realtime refresh across users; "About this system" page (AI tools + database) | 10, 11, 12 |
| 10 | **Wow factors (stretch)** | One at a time, in the priority order at the top of `SPEC.md`. At least #1 (order tracking + email/QR) before the demo. EmailJS account needed here. | Wow |
| 11 | **Polish + demo prep** | Bug bash on phones/laptops, test with unexpected inputs, printed barcode labels, practice runs | all |

**Core is done after Phase 9.** That covers all 12 capabilities.

Why phase 6 sits where it does: the history is generated by the same sale/receive/production functions built in phases 1–5, so it can't come earlier; and reorder points, EOQ, the supplier scorecard and turnover (phases 7–8) are computed from it, so it can't come much later. The rubric still requires ≥10 customers and ≥6 months of history at demo time.

If time gets short: phases 0–9 plus one wow factor cover every requirement. Everything else raises the grade.

## Status

- [x] Spec written (`SPEC.md`, PDF in repo)
- [x] Rubric saved (`RUBRIC.md`)
- [x] Git repo connected to GitHub
- [x] Phase 0 — Setup (live at https://byusection2team8.github.io/ERP-system-repository/ ; staff sign-in verified 2026-11-12)
- [ ] Phase 1 — Database schema
- [ ] Phase 2 — Starter seed data
- [ ] Phase 3 — Inventory + Barcodes
- [ ] Phase 4 — POS + Sales Orders
- [ ] Phase 5 — Production + MRP
- [ ] Phase 6 — Full customers + 6-month history
- [ ] Phase 7 — Purchasing + Suppliers
- [ ] Phase 8 — Returns + Financials
- [ ] Phase 9 — Reports + Portal + Realtime
- [ ] Phase 10 — Wow factors (stretch)
- [ ] Phase 11 — Polish + demo prep

**Next step:** Phase 1 — Database schema. Start a fresh AI session: "Read HANDOFF.md and do Phase 1."
Phase 1 delivers SQL migration files in `supabase/migrations/`; a human pastes each into Supabase → SQL Editor → Run (no database password needed).

### Gotchas learned in Phase 0

- `VITE_SUPABASE_URL` must be the plain Project URL (`https://<ref>.supabase.co`). It was first pasted as `…/rest/v1/`, which gave "Invalid path specified in request URL" at sign-in. `src/lib/supabase.ts` now strips any path, but keep the secret clean.
- The anon key is the newer **publishable** format (`sb_publishable_…`); it works with supabase-js 2.45.4.
- Secrets are only read at build time: after changing one, run the workflow again.
- After a deploy, browsers may keep the old version cached. Test in a private window or with Ctrl+F5.
- The build log step "Check Supabase secrets are set" says whether each secret is set (never prints values).

### No local Node.js (decided 2026-11-12)

The builder's computer does **not** have Node.js. GitHub Actions installs, type-checks and builds on every push to `main`, then publishes to GitHub Pages.
- There is no `package-lock.json`; CI runs `npm install` with exact versions pinned in `package.json`.
- To check a change, push it, wait ~2 minutes, then check the **Actions** tab (a red X means the build or type check failed; open it to read the error) and the live site.
- If anyone does have Node.js: `npm install`, copy `.env.example` to `.env`, then `npm run dev`.

### Phase 0 manual steps (a human does these once)

1. **Repo public**: GitHub repo → Settings → General → Danger Zone → Change visibility → Public. (Free GitHub Pages requires it.)
2. **Pages on**: Settings → Pages → Source: **GitHub Actions**.
3. **Secrets**: Supabase → Project Settings → API (or Data API): copy **Project URL** and the **anon / publishable** key. GitHub repo → Settings → Secrets and variables → Actions → New repository secret:
   - `VITE_SUPABASE_URL` = the Project URL
   - `VITE_SUPABASE_ANON_KEY` = the anon/publishable key
   (Never the service_role/secret key or the database password.)
4. **Re-run deploy**: Actions tab → "Build and deploy to GitHub Pages" → Run workflow.
5. **Staff login**: Supabase → Authentication → Users → Add user → Create new user (email + password, tick "Auto Confirm User"). Use the team Gmail with `+staff1` (e.g. `team+staff1@gmail.com`) or any address you control.
6. **Site URL**: Supabase → Authentication → URL Configuration → Site URL = `https://byusection2team8.github.io/ERP-system-repository/`
7. **Test**: open that URL, sign in with the user from step 5. You should see the Dashboard and the "About this system" page.

### Code layout (Phase 0)

- `src/app/routes.tsx` — route registry; sidebar is generated from it. New module = folder in `src/features/` + one entry here.
- `src/app/Layout.tsx` — sidebar + top bar. `src/app/Logo.tsx` — brand mark.
- `src/features/auth/` — Supabase email/password sign-in (`AuthProvider`, `LoginPage`). Roles (staff vs customer) come in Phase 1.
- `src/features/about/AboutPage.tsx` — AI tools + database documentation (rubric requirement). Keep it updated.
- `src/lib/supabase.ts` — client; shows a "not connected" notice instead of crashing if secrets are missing.
- `src/styles.css` — navy/teal theme tokens at the top.
- Uses `HashRouter` so refreshing a page works on GitHub Pages (URLs look like `/#/about`).
- `.github/workflows/deploy.yml` — build + deploy.

## Open questions / decisions needed

- Repository visibility: free GitHub Pages requires the repo to be **public** (or the org needs a paid plan). Confirm.
- Open items listed at the bottom of `SPEC.md` (tax rate, purge grams, team names, etc.).

## Session log

- **2026-11-12** — Connected local folder to GitHub. Added `RUBRIC.md`, `SPEC.md` (text copy of the PDF spec), and this handoff with the phased plan. No app code yet. Moved the 60 customers and 6-month history out of the first seed into their own later phase (now Phase 6). Switched to a lean-core build: core vs. stretch table added to `SPEC.md`, extension points added here, wow factors deferred to Phase 10.
- **2026-11-12** — Phase 0 code: Vite + React + TS skeleton, Supabase sign-in, sidebar layout driven by route registry, About page, GitHub Actions deploy to Pages. Built without local Node.js (CI builds). Not yet verified live: waiting on repo visibility, Pages setting, secrets and a Supabase staff user.
- **2026-11-12** — Phase 0 complete. Pages enabled, secrets added, workflow actions bumped to v5/v4 (Node 24 warning), CI secret check added, URL path-stripping fix. Staff sign-in works on the live site.
