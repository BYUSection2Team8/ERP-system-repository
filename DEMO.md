# Phase 11 — Polish & demo prep runbook

Everything in this file needs a person at a browser signed in to the live site
(https://byusection2team8.github.io/ERP-system-repository/). Work top to bottom. Tick boxes as you go,
and write anything that breaks into the **Bug log** at the bottom with the exact steps (an AI session can fix it from that).

Demo: **Dec 2, 2026**, 10 minutes, Dr. Wright picks the scenario. Every demo checks: POS or Sales Orders,
Inventory, Returns & Exchanges, Production, Financials, MRP + 2–4 more capabilities + wow factors.

---

## 0. One-time setup (do first, ~20 minutes)

- [x] **Supabase SQL Editor** (done 2026-11-12): paste and Run, in order, `supabase/migrations/012_reports_portal.sql`, `013_tracking_failures.sql`, `014_quotes_printers_capacity.sql`, `015_box_selection.sql` → each "Success. No rows returned."
- [x] (done 2026-11-12) Paste and Run `supabase/migrations/016_new_design.sql`, then `supabase/tests/new_design_check.sql` → result **NEW DESIGN CHECKS PASSED** (or re-run Paste 2, which now includes it).
- [ ] Paste and Run, in order, `supabase/migrations/017_spools.sql`, `018_demand_simulator.sql`, `019_capacity_overrides.sql`, `020_shipping_zones.sql`; then Paste 2 (or their check scripts: spools, demand_simulator, capacity_overrides, shipping_zones).
- [ ] Run **Paste 2** (`supabase/paste/2_run_checks.sql`) → `ALL CHECKS PASSED` (now includes the reports/portal and tracking/failure checks).
- [ ] **Portal logins** (rubric 11): Supabase → Authentication → Users → Add user (tick Auto Confirm) for at least **Demo Customer** (`demo.customer@example.com`) and one student (e.g. `ethan.caldwell@example.com`, BYU discount). They link to their customer records by email. If made before 009 ran: SQL Editor → `select link_customer_logins();`
- [ ] **Three staff logins** (rubric 12): add two more users, then for each: `update profiles set role = 'staff' where id = (select id from auth.users where email = '...');`
- [ ] **EmailJS** (wow #1 email), optional but recommended:
  1. emailjs.com → sign up with the team Gmail → Email Services → Add → Gmail → connect the team Gmail. Note the **Service ID**.
  2. Email Templates → Create. Subject: `Track your Poulson Prints order {{order_no}}`. To email: `{{to_email}}`. Body, for example:
     `Hi {{to_name}}, thanks for your order {{order_no}}! Follow it live (printing progress and ready date): {{tracking_url}} — {{company}}`. Note the **Template ID**.
  3. Account → General → **Public Key**.
  4. GitHub repo → Settings → Secrets and variables → Actions → add `VITE_EMAILJS_SERVICE_ID`, `VITE_EMAILJS_TEMPLATE_ID`, `VITE_EMAILJS_PUBLIC_KEY`.
  5. Actions → "Build and deploy to GitHub Pages" → Run workflow. (Without these, the app still shows the link + QR and logs emails as "not sent".)
  6. EmailJS free plan: 200 emails/month. Check the team Gmail's spam folder the first time.
- [ ] Supabase → Authentication → Sign In / Providers → "Allow new users to sign up" is **off**.

## 1. Live-site checklists (deferred from Phases 4–10)

Run each phase's checklist in `HANDOFF.md`, on a laptop **and** a phone:

- [ ] Phase 4 — POS + Sales Orders
- [ ] Phase 5 — Production + MRP
- [ ] Phase 6 — 6-month history
- [ ] Phase 7 — Purchasing + Suppliers
- [ ] Phase 8 — Returns + Financials
- [ ] Phase 9 — Reports + Portal + Realtime
- [ ] Phase 10 — Order tracking, print failures, quotes, printer board, packing slip, capacity

## 2. Bug bash with unexpected inputs (Dr. Wright may try these)

Each of these should be refused with a plain-English message and save nothing. Confirm that on screen; anything else goes in the bug log.

- [ ] POS: quantity 0, −1, 1.5, 99999; sell more than on hand; manual discount 80% (max is 50%) or with no reason.
- [ ] Sales order: no customer; ship with no state; cancel a fulfilled order; fulfill twice (two browsers, same order, click together).
- [ ] Transfer to the same location; transfer more than on hand; adjust with no reason code.
- [ ] Receive more than ordered on a PO; receive into QA Hold; pay a bill twice.
- [ ] Production: complete with good + scrap ≠ started; scrap with no reason; issue with components short.
- [ ] Return more than was sold; return an order older than 30 days; return a cancelled order.
- [ ] Portal: order 0 / 1.5 / 600 units; order something, then cancel it; open another customer's tracking link with one character changed (→ "could not find").
- [ ] Settings: type text into a number setting; set ordering cost to 0 (reorder planning must still load), then put it back.
- [ ] Every page on a phone (portrait): no sideways scrolling, buttons reachable, camera scanner opens.
- [ ] Refresh on every page (HashRouter: the page should come back, not 404).

## 3. Physical props

- [ ] Barcode labels → print one sheet (Avery 5160 or plain paper at 100% scale) with every product + a filament spool + a few components. Stick them on real items.
- [ ] Test-scan each printed label with a phone (Inventory → 📷) and, if available, a USB scanner.
- [ ] Print one POS receipt; scan its QR code with a phone → tracking page opens.

## 4. Night before / morning of

- [ ] Log in to Supabase the week before and that morning (free projects pause after ~1 week idle).
- [ ] Hard-refresh the site (Ctrl+F5) on every demo device.
- [ ] Laptop 1: staff user A. Laptop 2: staff user B (different login). Phone or laptop 3: **Demo Customer** in the portal. Phone: scanner.
- [ ] Check the "Live" badge is green on every device.
- [ ] Practice data gets messy: that's fine, the ledger stays consistent. Nothing needs resetting.

## 5. Suggested 10-minute flow (end-to-end story)

1. **Customer portal** (laptop 3): Demo Customer orders 2 Dragons for pickup at Campus + 1 Temple (made to order) → order confirmation with QR → scan it with the phone: "Queued for printing", ready date.
2. **Multi-user** (laptop 1 & 2): the order appears on Sales orders / Dashboard of both staff screens without refreshing.
3. **MRP** (laptop 1): the Temple shows as demand → components netted against on-hand and open POs → "Plan it" / "Create & send PO".
4. **Production**: open the Temple production order → Issue (components leave inventory, WIP up) → the phone's tracking page now says **Printing** with % and countdown → **Report print failure** (warping) → scrap posted, reprint started automatically, tracking still "Printing". Complete the reprint → tracking: "Ready for pickup".
5. **POS** (laptop 2): scan 3 printed labels → BYU discount → cash → receipt with QR. Inventory at Campus drops on laptop 1 and in the portal.
6. **Returns**: return one Dragon as "Quality defect" → QA Hold, full refund; exchange a red for a blue.
7. **Financials**: P&L (sales, returns, COGS, production scrap = cost of poor quality), valuation, turnover — all moved live.
8. **Reports**: sales by week, top sellers, low stock with order-by dates, supplier performance, print failures (Airplane warps most; mid-Sept–Oct printer maintenance spike).
   **Wow extras**: Demand simulator ("Black Friday" → watch MRP and backorders react), Filament spools (scan a spool into a printer), New product design (create a product live, sell it at the POS), Custom quote (Show the math, accept → order + production), Printer board, packing slip on a shipped order, Space used on the Dashboard.
9. **Purchasing**: supplier scorecard (VXB = Watch/Replace), reorder planning: change ordering cost in Settings → EOQ grows by √2.
10. **About this system**: tools + database + the capability map.

ERP talking points: one transaction updates inventory **and** the ledger atomically; every number is derived from stored transactions
(nothing typed in); MRP turns confirmed demand × BOM into dated purchase/production suggestions; pull model (stock the fast movers, print to order);
cost of poor quality shows up on the P&L the moment a print fails.

## Bug log

| # | Found by | Page | Steps to reproduce | Expected | Actual | Fixed? |
|---|---|---|---|---|---|---|
| | | | | | | |
