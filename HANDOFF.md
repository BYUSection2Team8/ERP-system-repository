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
| 11 | **Polish + demo prep** | Run every deferred live-site checklist (Phase 4 onward), bug bash on phones/laptops, test with unexpected inputs, printed barcode labels, practice runs | all |

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
- [x] Phase 4 — POS + Sales Orders (007 applied in Supabase; all checks passed. Live-site checklist deferred to Phase 11)
- [x] Phase 5 — Production + MRP (008 applied in Supabase; Paste 2 passed. Live-site checklist deferred to Phase 11)
- [x] Phase 6 — Full customers + 6-month history (009 + seed/002 applied in Supabase; Paste 2 passed)
- [x] Phase 7 — Purchasing + Suppliers (010 applied in Supabase; Paste 2 passed)
- [ ] Phase 8 — Returns + Financials
- [ ] Phase 9 — Reports + Portal + Realtime
- [ ] Phase 10 — Wow factors (stretch)
- [ ] Phase 11 — Polish + demo prep

**Next step:** Phase 8 — Returns + Financials. Start a fresh AI session: "Read HANDOFF.md and do Phase 8."
**Reading CI without signing in:** every SQL file, the type check and the build report their result as a GitHub *annotation* (job logs need a login, annotations don't): `curl -s https://api.github.com/repos/BYUSection2Team8/ERP-system-repository/check-runs/<job id>/annotations`. Job ids come from `.../actions/runs?head_sha=<commit>` → `jobs_url`. A failing SQL file shows the database error text there.
**Live-site checklists are deferred to Phase 11** (team decision 2026-11-12): from Phase 4 on, each phase ends when CI is green and Paste 2 passes in Supabase. Write that phase's checklist into this file anyway, and run them all in Phase 11.
Database changes from now on: add a new numbered migration, run `bash supabase/make_paste_files.sh`, and paste only the NEW migration into the SQL Editor (Paste 1 is for an empty database). Paste 2 (checks) can be re-run any time.
New staff logins: add the user in Supabase → Authentication → Users (tick Auto Confirm), then SQL Editor: `update profiles set role = 'staff' where id = (select id from auth.users where email = '...');`. Logins created after setup start as `customer`.

### Database manual steps (a human does these once, in this order)

1. Supabase → **SQL Editor** → New query. Paste each file from `supabase/migrations/` **in number order** (`001_schema.sql` … `007_sales_quote.sql`) and click **Run**. Each should say "Success. No rows returned."
2. Paste `supabase/seed/001_starter_data.sql` and Run (loads the Phase 2 starter data). Then paste `supabase/tests/seed_check.sql` and Run → **SEED CHECKS PASSED**.
3. Paste `supabase/tests/smoke_core.sql` and Run. The output should end with **ALL PHASE 1 CHECKS PASSED** (it rolls back, so nothing is left behind). Then the same with `supabase/tests/rls_check.sql` → **ALL RLS CHECKS PASSED**.
4. Supabase → Authentication → Sign In / Providers → turn **off** "Allow new users to sign up" (staff and portal logins are created by us). Even if left on, new sign-ups are only `customer` with no data access.
5. Every user that existed when `002_security.sql` ran became **staff** (the Phase 0 login). To make a later user staff: SQL Editor → `update profiles set role = 'staff' where id = (select id from auth.users where email = '...');`

### Phases 5–7 Supabase steps (a human does these once, in this order)

1. SQL Editor → paste and Run each NEW migration, in order: `008_production_mrp.sql`, `009_customer_logins.sql`, `010_purchasing_planning.sql`. Each: "Success. No rows returned."
2. Paste `supabase/seed/002_customers_history.sql` and Run. The result row says either **HISTORY COMPLETE: …** or **HISTORY PARTLY GENERATED … Run this file again to continue.** Each run works ~45 seconds and keeps what it did; paste and Run it again until it says COMPLETE (in CI the whole 6 months takes ~10 s, so expect one or two runs). Never edit it between runs.
3. Run `bash supabase/make_paste_files.sh` (or use the copy CI made) and run **Paste 2** → `ALL CHECKS PASSED`. It now includes `history_check.sql`, `production_mrp_check.sql` and `purchasing_check.sql`.
4. Portal logins (needed in Phase 9, can be done now): Authentication → Users → Add user (tick Auto Confirm) with each customer's email — the 12 customers whose notes say "Has a customer-portal login" (Ethan Caldwell, Hannah Lindqvist, Emma Kawamoto, Grace Sorensen, Rebecca Holloway, Linda Castellanos, Marcus Bellweather, Jennifer Olsen, Summit Ridge Gifts = dana.moffat@, Wasatch Tinkerers Guild = jordan.ellis@, Provo Peak Party Supply = ben.hartley@, Demo Customer = demo.customer@example.com). Emails are `first.last@example.com`. The new login links itself to the customer record (009 trigger). Logins made before 009 ran: SQL Editor → `select link_customer_logins();`.
5. Three staff logins total are required (rubric 12): add two more users and promote them with the `update profiles set role = 'staff' …` line above.

### Phase 5 live-site checklist (deferred to Phase 11)

1. Production orders → New → Dragon - Red, qty 6 → plates 6, components 62.58 g red filament; Create and issue → status In progress, journal Dr 1250 WIP / Cr 1200 Inventory; Dashboard "Work in process" rises by the same amount.
2. Complete it with 5 good, 1 scrapped, reason Warping → 5 Dragons arrive at Fulfillment; cost roll-up card shows materials + machine (6 × 1.15 h × $0.2065) + labor (6 × 2 min × $20/h) ÷ 6; journal Dr Inventory (5 units) + Dr 5300 Scrap (1 unit) / Cr WIP / Cr 2300 accrued labor & machine.
3. Try to complete with good + scrap ≠ started, or scrap without a reason → plain-English error.
4. Production report → Last 30 days → first-pass yield, scrap rate, avg cycle time, on-time %, scrap by reason, orders table; change the date range and the numbers change.
5. MRP → open orders from the history (Provo Peak 150 Keychains, Summit Ridge ornaments, Lakeview magnet sets…) show as gross demand; components show net requirements with order-by dates. "Create & send PO" for a supplier → the PO opens; back on MRP the item's scheduled receipt appears and the planned order disappears. "Plan it" on a product → production order created; its components stay as requirements.
6. Second browser as another user sees the new MO / PO appear without refreshing.

### Phase 6 live-site checklist (deferred to Phase 11)

1. Sales orders → All → ~1,200 orders over six months (plus ~650 production orders, ~75 POs); customer names from the spec's 60; Closed orders dominate, the last few days are Placed / Fulfilled.
2. Dashboard inventory value, A/R (on-account businesses) and WIP are non-zero and come from the ledger.
3. Item page for Keychain → months of movements: sales, production output, transfers to Campus on Tue/Fri.
4. Suppliers → every supplier has PO history; VXB Bearings is late often (Watch/Replace), Hobby Lobby on time (Keep).

### Phase 7 live-site checklist (deferred to Phase 11)

1. Suppliers & scorecard → one screen with on-time %, fill rate, actual vs quoted lead, price stability, owed, next due date, overall score, Keep/Watch/Replace. Edit a supplier's quoted lead time → new POs use it.
2. Reorder planning → each row shows d̄, σ, L, ROP and EOQ with the math under the number. Settings → change "Ordering cost per PO" from 15 to 30 → back on Reorder planning, every EOQ grows by √2 (41%). Change service level z → reorder points change. Put both back.
3. "Create & send PO" for a supplier below its reorder point → PO opens (status Order sent, expected = today + quoted lead).
4. On that PO: scan an item's barcode (USB or 📷) → its Receive-now count goes up by one per scan; receive part of it into Fulfillment → status Partly received, stock at Fulfillment up, bill due in Net-terms days (or paid at once for paid-at-purchase suppliers); journal Dr Inventory / Cr A/P. Receive the rest → Received → Close PO.
5. Purchase orders → Bills to pay → Pay → owed drops, journal Dr A/P / Cr Cash; the supplier's scorecard "Owed" changes.
6. Periodic review → items below their order-up-to level with suggested quantities → Send POs and record review → next review date moves 14 days out.

### Production, MRP and history design (Phases 5–7) — read before Phase 8

- **008_production_mrp.sql**: `v_production_orders` (cycle hours, on-time flag, `report_date` = finish/start/created date in Utah time), `production_metrics(from, to)` (first-pass yield = completed orders with no scrap ÷ completed; unit yield; scrap rate = scrapped ÷ started; avg cycle hours; on-time rate), `production_scrap_by_reason(from, to)`, `mrp_parent_plan(weeks)`, `mrp_component_plan(weeks)`. MRP weeks start Monday of this week; overdue demand lands in week 1. Parent netting: demand − finished stock (sellable locations) − open MOs; planned production in whole plates using a cumulative running max (late supply never cancels an earlier need). Component gross = planned plates × BOM + unissued components of *planned* MOs; netted against stock + open POs by expected week; planned orders rounded up to purchase units (spools). Order-by = need date − component lead time. Also adds an index on `inventory_txn(source_id)`.
- **009_customer_logins.sql**: `handle_new_user` fills `profiles.customer_id` by matching email; `link_customer_logins()` links existing ones.
- **seed/002_customers_history.sql**: adds the other 55 customers + "Demo Customer", then simulates each day from `history_start_date` (≈ today − 180) to yesterday by calling the business functions: PO receipts (per-supplier delay/split/short patterns from a hash of the PO id), overnight print completions at 8am, closes (cards after delivery, on-account ≈ Net 30), production planning (restock rules for Dragon/Spinner/Keychain/Ornament, made-to-order for the rest) and issue when components are on hand, Tue/Fri delivery runs to Campus, weekday purchasing from trailing 28-day usage, the demand model, returns (~3%), bill payments (K&J paid late), PO closes, fulfillment at 4:30pm, cycle counts on the 1st/15th, QA Hold inspections on Mondays. At the end it places 8 confirmed orders with need dates over the next 4 weeks so MRP has work. Progress is kept in settings rows `history_start_date`, `history_generated_through`, `history_complete`; decisions are derived from stored rows + hashes, so a later run continues exactly. CI sets `pp.history_budget_seconds` to run it in one go.
- **010_purchasing_planning.sql**: settings `demand_history_days` (180) and `production_setup_cost` ($5); `v_reorder_plan` (d̄, σ incl. zero days, L, ROP = d̄L + zσ√L or the item's `reorder_point_manual`, EOQ = √(2DS/H), order-up-to = d̄(R+L) + zσ√(R+L), position = on hand + on order − committed, suggested qty and order-by date); `v_supplier_scorecard` (on-time = last receipt ≤ expected date; fill rate by value on finished POs; lead accuracy = 1 − avg|actual − quoted| ÷ quoted; price stability = 1 − 2·CV; owed/overdue/next due from `v_ap_open`; overall 40/30/20/10 → Keep ≥ 80, Watch ≥ 60, Replace); `inventory_reviews` + `record_inventory_review()` + `v_review_status`.
- **Screens**: `features/production/` (list, new, detail with issue/complete/cancel + cost roll-up + journal, report), `features/mrp/MrpPage`, `features/purchasing/` (PO list + bills to pay, new PO, PO detail with scan-to-receive / partial receipts / close short / pay, suppliers scorecard, supplier add/edit + price list, reorder planning, periodic review), `features/settings/SettingsPage` (edit any setting), `app/JournalTables` (shared journal display).
- `seed_check.sql` now compares rolled-up costs at **price-list** cost: live weighted averages move once purchase history exists (Hobby Lobby sale weeks at $8.99).
- Not built yet: returns UI and P&L / turnover (Phase 8), manager reports and the customer portal (Phase 9).

### Phase 4 live-site checklist (deferred to Phase 11; do on a laptop AND a phone)

1. Point of sale → scan (or type) `PP-KEY-BW` three times → one line, qty 3, subtotal $14.97. Choose BYU student → discount −$1.50, tax 7.45% = $1.00, total **$14.47** (same numbers `sales_quote_check.sql` checks).
2. Cash → Cash received $20 → "Change due $5.53" → Complete sale. The receipt shows the order number, lines, totals and a Code 128 order barcode. Print receipt prints only the receipt.
3. View order & accounting → status Closed; journal: Dr Cash 14.47 + Dr Sales discounts 1.50 = Cr Product sales 14.97 + Cr Sales tax 1.00, plus Dr COGS / Cr Inventory. Inventory → Keychain at Campus is 3 lower; the Dashboard inventory value dropped by the COGS amount.
4. Try to sell more Keychains than Campus has → warning, Complete is disabled. Manual discount with no reason → the totals panel shows "A manual discount needs a reason code."
5. New sales order → Rebecca Holloway, Ship, 1 Temple LED Tealight (made to order, 0 in stock) → $5.99 shipping + UT tax → Place order. The order shows Backordered with an estimated date and appears on Backorders and in the Dashboard "Open sales orders" stat.
6. New sales order → change ship-to state to AZ → tax becomes $0.00. Place it, then Cancel order… with a reason → Cancelled, nothing posted.
7. New sales order → Summit Ridge Gifts, Pickup, 25 Keychains → Business 15% unlocks, payment On account (Net 30). Place → Fulfill → the journal debits A/R → Record payment & close → Cash debited, A/R credited.
8. With a second browser signed in as another user, complete a POS sale: the other user's Sales orders list, Inventory and Dashboard update by themselves.

### Sales screens (Phase 4)

- **Pricing lives in the database only.** `007_sales_quote.sql` moved the discount / shipping / tax math out of `create_sales_order` into `_price_sales_order(p)`. `quote_sales_order(p)` (staff) returns the priced order without saving; `create_sales_order` and `pos_sale` save using the same function. Screens call `useQuote(payload)` (debounced) and never compute money themselves. `supabase/tests/sales_quote_check.sql` checks quote = saved order (also in Paste 2).
- `src/features/sales/`: `salesShared.tsx` (status/channel labels, `useSalesRefData` = customers + discount reasons + settings, `useQuote`, `CartTable`, `DiscountPicker`, `TotalsTable`, `QuotePanel`), `useOrder.ts` (one order + lines, customer, ledger rows, backorders, returns, stock at its location; live), `PosPage` (`/pos`), `SalesOrdersPage` (`/sales`, status tabs with counts, latest 200), `NewSalesOrderPage` (`/sales/new`), `SalesOrderDetailPage` (`/sales/:id`: status steps, Fulfill / Close / Cancel, lines with COGS unit cost, journal entries), `Receipt` (`/sales/:id/receipt`; prints via `.print-area`).
- Defaults: POS sells from Campus; shipped orders leave from Fulfillment, pickups are at Campus; BYU customers get the BYU discount pre-selected; customers with terms default to On account. The business discount unlocks only at the settings' minimum units.
- Cash "change due" is screen-only (not stored). Returns/exchanges screens come in Phase 8 (the database function already exists). There is no customer master-data screen yet (Phase 6 adds the other 55 customers).
- CI gotcha: Paste 1 grew past Linux's 128 KB limit for one command-line argument (`psql -c` failed with exit 126). The workflow now feeds each paste file through psql `\set` + `\gexec`, which still sends it as one query string like the SQL Editor.

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
- **Not built yet (later phases):** returns UI (Phase 8), ROP/EOQ/MRP/scorecard calculations (Phases 5, 7), P&L/turnover views (Phase 8), portal functions (Phase 9). Packaging uses the flat setting; boxes bought on POs are not yet consumed per order (stretch: box selection).

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
- **2026-11-12** — Phase 4 code: migration `007_sales_quote.sql` (one pricing function shared by the live quote, sales orders and POS) + `sales_quote_check.sql`; POS (scan to add, BYU / business / manual-with-reason discounts, Utah tax, cash change, printable receipt with order barcode), sales order list / new order / detail with Placed → Fulfilled → Closed / Cancelled, backorder warnings and the journal entries each order posted; dashboard open-orders stat and clickable activity. CI green (build + all database tests, including the paste files after fixing the 128 KB argument limit). Not yet tried on the live site: 007 must be pasted into Supabase first.
- **2026-11-12** — 007 applied in Supabase; Paste 2 passed after making the seed and smoke checks work on a database with real activity (they compared absolute balances that only hold on a fresh seed). Phase 4 complete. Live-site checklists moved to Phase 11.
- **2026-11-12** — Phases 5–7 code, CI green (build + every database check, including both paste files as single batches). Phase 5: `008_production_mrp.sql` (production report view + metrics, scrap by reason, 4-week MRP for products and components) + production screens (list, new, detail with issue / complete with scrap reason / cost roll-up / journal, report) + MRP screen with one-click PO and "plan production". Phase 6: `009_customer_logins.sql` + `seed/002_customers_history.sql` (55 more customers + demo customer; 180 days of sales, production with print failures, POs with late/split/short deliveries, payments, returns, transfers, counts — all through the business functions; ~1,180 orders, 0 skipped calls, ~9 s in CI; resumable in 45-second chunks for the SQL Editor). Phase 7: `010_purchasing_planning.sql` (ROP / EOQ / periodic review view, supplier scorecard view, review log) + PO list with bills to pay, new PO, PO detail with scan-to-receive and partial receipts, suppliers scorecard, supplier add/edit, reorder planning, periodic review, Settings screen. New checks: `production_mrp_check.sql`, `history_check.sql`, `purchasing_check.sql` (hand-calculated numbers). CI now reports results as annotations. **Not yet done in Supabase:** paste 008, 009, 010, run seed/002 until COMPLETE, then Paste 2 (see "Phases 5–7 Supabase steps"); until then the new screens show a "function does not exist" error on the live site.
- **2026-11-12** — 008, 009, 010 and seed/002 applied in Supabase; Paste 2 → ALL CHECKS PASSED. Phases 5–7 complete. (The seed now skips linking portal logins if 009 is missing, instead of failing.) Still to do by hand: the 12 portal logins and 2 more staff logins (step 4–5 of "Phases 5–7 Supabase steps").
