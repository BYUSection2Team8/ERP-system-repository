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
- [x] Phase 1 — Database schema (applied in Supabase via the paste files; all checks passed)
- [x] Phase 2 — Starter seed data (applied in Supabase; seed check passed)
- [x] Phase 3 — Inventory + Barcodes (live-site checklist passed)
- [ ] Phase 4 — POS + Sales Orders
- [ ] Phase 5 — Production + MRP
- [ ] Phase 6 — Full customers + 6-month history
- [ ] Phase 7 — Purchasing + Suppliers
- [ ] Phase 8 — Returns + Financials
- [ ] Phase 9 — Reports + Portal + Realtime
- [ ] Phase 10 — Wow factors (stretch)
- [ ] Phase 11 — Polish + demo prep

**Next step:** Phase 4 — POS + Sales Orders. Start a fresh AI session: "Read HANDOFF.md and do Phase 4."
Database changes from now on: add a new numbered migration, run `bash supabase/make_paste_files.sh`, and paste only the NEW migration into the SQL Editor (Paste 1 is for an empty database). Paste 2 (checks) can be re-run any time.
New staff logins: add the user in Supabase → Authentication → Users (tick Auto Confirm), then SQL Editor: `update profiles set role = 'staff' where id = (select id from auth.users where email = '...');`. Logins created after setup start as `customer`.

### Database manual steps (a human does these once, in this order)

1. Supabase → **SQL Editor** → New query. Paste each file from `supabase/migrations/` **in number order** (`001_schema.sql` … `006_realtime.sql`) and click **Run**. Each should say "Success. No rows returned."
2. Paste `supabase/seed/001_starter_data.sql` and Run (loads the Phase 2 starter data). Then paste `supabase/tests/seed_check.sql` and Run → **SEED CHECKS PASSED**.
3. Paste `supabase/tests/smoke_core.sql` and Run. The output should end with **ALL PHASE 1 CHECKS PASSED** (it rolls back, so nothing is left behind). Then the same with `supabase/tests/rls_check.sql` → **ALL RLS CHECKS PASSED**.
4. Supabase → Authentication → Sign In / Providers → turn **off** "Allow new users to sign up" (staff and portal logins are created by us). Even if left on, new sign-ups are only `customer` with no data access.
5. Every user that existed when `002_security.sql` ran became **staff** (the Phase 0 login). To make a later user staff: SQL Editor → `update profiles set role = 'staff' where id = (select id from auth.users where email = '...');`

### Phase 3 live-site checklist (do on a laptop AND a phone)

1. Sign in → Dashboard shows inventory on the books (about $1,200 of opening stock: ~$420 filament, ~$250 components, ~$225 packaging, ~$300 finished goods) and recent activity.
2. Inventory → 48 items across Print Farm / Fulfillment / Campus / QA Hold; filament shows grams and spools.
3. Click an item → barcode, stock by location, rolled-up cost and BOM (finished items), movement history.
4. Transfers: move 2 Dragons Fulfillment → Campus. Both columns change; a second browser signed in as another user updates by itself (Realtime).
5. Adjust & count: count a Spinner at Campus one lower with "Cycle count" → value written off is shown and the movement appears on the item page.
6. Barcode labels → +1 of each Product → Print (100% scale) on Avery 5160 or plain paper. Then on a phone: Inventory → 📷 Scan a printed label → opens that item. A USB scanner typing into the box + Enter works too.
7. Backorders page shows "Nothing is backordered" (sales orders arrive in Phase 4).

### Starter data (Phase 2) — `supabase/seed/001_starter_data.sql`

- 7 suppliers with price lists (`item_suppliers`), 18 purchased items (4 PLA filaments in grams, 9 components, 5 packaging), 30 finished items (9 products), BOMs per plate, 5 customers (Ethan Caldwell, Rebecca Holloway, Marcus Bellweather, Jennifer Olsen, Summit Ridge Gifts — Phase 6 adds the other 55 and must skip these names).
- **48 items, not 47:** the spec's supplier table lists 18 purchased items (its "17" is a miscount). Every one is used by a BOM or the packaging rule.
- SKU pattern `DRG-RED`, barcode `PP-DRG-RED` (Keychain `KEY-BW`, Airplane `AIR-MC`). Barcodes are ≤14 characters so Code 128 fits a 2⅝" label.
- Opening stock is **posted** with `receive_opening_inventory`, dated 184 days before the seed runs (before the Phase 6 history window): filament 28 spools, components, packaging, and stocked products (Dragon, Spinner, Keychain) at Fulfillment + Campus. Made-to-order and out-of-season products start at zero.
- Rolled-up costs match the SPEC BOM table within 5¢ (checked by `seed_check.sql`); they run a few cents low on long prints because the exact machine rate is $0.2065/hr, not the spec's rounded $0.21.
- `reorder_point_manual` is left empty on purpose: reorder points are computed from history in Phase 7.

### Front-end layout (Phase 3)

- `src/lib/db.ts` (`db()`, `unwrap`, `rpc`), `src/lib/useLiveQuery.ts` (load + auto-reload on Realtime changes to listed tables — use it on every screen), `src/lib/types.ts`, `src/lib/format.ts`, `src/app/ui.tsx` (PageHeader, Stat, Loading, ErrorNotice, shortLocation).
- `AuthProvider` now loads `role` from `profiles`; customers see `features/portal/CustomerHome` (placeholder until Phase 9).
- `features/inventory/`: `useInventoryData` (items, locations, availability, valuation, reason codes), Inventory list, Item detail (`/inventory/item/:id`, hidden route), Transfer, Adjust & count, Backorders.
- `features/barcodes/`: `Barcode` (JsBarcode, Code 128 SVG), `CameraScanner` (@zxing/browser, rear camera), `ScanItemInput` (one box for USB scanner / camera / typing — reuse it in POS and receiving), `LabelsPage` (Avery 5160 print layout, "skip first N" for partly used sheets).
- Routes in `src/app/routes.tsx` support `hidden: true` for detail pages.

### Database design (Phase 1) — read this before writing screens

- **Migrations:** `001_schema` tables · `002_security` roles + RLS · `003_calc_views` shared calculations + views · `004_functions` business functions · `005_reference_data` settings, chart of accounts, reason codes, 4 locations · `006_realtime` publication. CI (`.github/workflows/db-test.yml`) applies them all to a fresh Postgres 17 and runs `supabase/tests/*.sql` on every push that touches `supabase/`. Supabase stand-in for CI: `supabase/tests/ci_supabase_stub.sql` (never run that one in Supabase).
- **Stock** = `inventory_txn` rows (signed qty in stock units: `ea` or grams). On hand = `v_availability` / `v_stock_on_hand`. **Cost** = moving weighted average per item across locations, `item_unit_cost(item)`; valuation `v_inventory_valuation`.
- **Money** = `journals` + `ledger` (balanced debits/credits). Accounts 1000 Cash, 1100 A/R, 1200 Inventory, 1250 WIP, 2000 A/P, 2100 Sales tax, 2300 Accrued production labor & machine, 3000 Equity, 4000 Sales, 4100 Discounts, 4200 Shipping rev, 4300 Restocking fees, 4400 Sales returns, 5000 COGS, 5100 Packaging, 5200 Inventory adjustments, 5300 Production scrap. Balances: `v_account_balances`.
- **Business functions** (call with `supabase.rpc`): `receive_opening_inventory`, `transfer_inventory`, `adjust_inventory`, `count_inventory`, `create_sales_order`, `fulfill_sales_order`, `close_sales_order`, `cancel_sales_order`, `pos_sale`, `process_return`, `create_production_order`, `issue_production_order`, `complete_production_order`, `cancel_production_order`, `create_purchase_order`, `send_purchase_order`, `receive_purchase_order`, `close_purchase_order`, `cancel_purchase_order`, `record_supplier_payment`. Parameters are documented in comments above each function in `004_functions.sql`. Every one takes an optional timestamp so Phase 6 can backdate history. Errors are plain-English messages meant to be shown to the user.
- **Locations by code:** `PRINT_FARM`, `FULFILLMENT`, `CAMPUS`, `QA_HOLD` (not sellable). POS defaults to CAMPUS; shipped orders default to FULFILLMENT; production consumes at PRINT_FARM and outputs to FULFILLMENT.
- **BOMs are per plate**; `items.units_per_plate` converts (`v_bom_per_unit`). Production starts whole plates: qty started = plates × units per plate. Rolled-up cost: `item_standard_cost(item)` / `v_item_standard_cost`.
- **Filament:** item uom `g`; supplier price list (`item_suppliers`) says purchase unit `spool` = 985 g. PO quantities are in spools; stock is in grams.
- **Rules built in:** no negative stock (setting `allow_negative_inventory`); fulfillment fails as a whole if any line is short (order stays `placed` = backorder, see `v_backorders` with estimated date); one discount per order (BYU / business 25+ / manual with reason, max 50%); tax only for UT; flat shipping on shipped orders; flat packaging cost expensed on shipped + pickup orders; returns within 30 days; quality reasons → QA Hold, full refund; "changed my mind" refund of made-to-order → 10% restocking fee; exchanges create a new order with the same discount and no shipping; paid-at-purchase suppliers are paid automatically on receipt; on-account (Net 30) customer orders hit A/R and are paid when the order is closed.
- **Security:** anon gets nothing. Staff read everything and edit master data tables directly; transaction tables can only change through the functions. Customers read products, locations, settings and their own customer row/orders. Portal ordering functions come in Phase 9.
- **Not built yet (later phases):** ROP/EOQ/MRP/scorecard calculations (Phases 5, 7), P&L/turnover views (Phase 8), portal functions (Phase 9). Packaging uses the flat setting; boxes bought on POs are not yet consumed per order (stretch: box selection).

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
- **2026-11-12** — Phase 1 code: 6 migrations (schema, RLS, calc views, 20 business functions, reference data, realtime) plus CI database tests that apply them to Postgres 17 and check every function's numbers by hand-calculated examples (all green on first CI run). Not yet applied to Supabase: waiting on the Phase 1 manual steps.
- **2026-11-12** — Phase 2 code: starter seed (48 items, BOMs, 7 suppliers, 5 customers, opening stock posted as transactions) + `seed_check.sql` in CI (green; seed is safe to re-run). Phase 3 code: inventory list, item detail with movements and rolled-up cost, transfers, adjustments/cycle counts with reason codes, backorders with estimated dates, Code 128 label sheet, camera + USB scanning, Realtime refresh, dashboard KPIs. Builds in CI; not yet tried against the real database (migrations not applied yet).
- **2026-11-12** — Database applied in Supabase with the two paste files (`supabase/make_paste_files.sh` builds them; CI tests them as single batches like the SQL Editor). All checks passed; Phase 3 live-site checklist passed. Phases 1–3 complete.
