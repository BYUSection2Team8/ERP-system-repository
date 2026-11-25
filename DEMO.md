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
- [x] (done 2026-11-12) Paste and Run, in order, `supabase/migrations/017_spools.sql`, `018_demand_simulator.sql`, `019_capacity_overrides.sql`, `020_shipping_zones.sql`; then Paste 2 (or their check scripts: spools, demand_simulator, capacity_overrides, shipping_zones).
- [x] (done 2026-11-16) Run **Paste 2** (`supabase/paste/2_run_checks.sql`) → `ALL CHECKS PASSED` (now includes the reports/portal and tracking/failure checks).
- [x] (done 2026-11-16: demo.customer@example.com linked to Demo Customer) **Portal logins** (rubric 11): Supabase → Authentication → Users → Add user (tick Auto Confirm) for at least **Demo Customer** (`demo.customer@example.com`) and one student (e.g. `ethan.caldwell@example.com`, BYU discount). They link to their customer records by email. If made before 009 ran: SQL Editor → `select link_customer_logins();`
- [x] (done 2026-11-16: demo.staff1-3 + the original login = 4 staff) **Three staff logins** (rubric 12): add two more users, then for each: `update profiles set role = 'staff' where id = (select id from auth.users where email = '...');`
- [ ] **EmailJS** (wow #1 email), optional but recommended:
  1. emailjs.com → sign up with the team Gmail → Email Services → Add → Gmail → connect the team Gmail. Note the **Service ID**.
  2. Email Templates → Create. Subject: `Track your Poulson Prints order {{order_no}}`. To email: `{{to_email}}`. Body, for example:
     `Hi {{to_name}}, thanks for your order {{order_no}}! Follow it live (printing progress and ready date): {{tracking_url}} — {{company}}`. Note the **Template ID**.
  3. Account → General → **Public Key**.
  4. GitHub repo → Settings → Secrets and variables → Actions → add `VITE_EMAILJS_SERVICE_ID`, `VITE_EMAILJS_TEMPLATE_ID`, `VITE_EMAILJS_PUBLIC_KEY`.
  5. Actions → "Build and deploy to GitHub Pages" → Run workflow. (Without these, the app still shows the link + QR and logs emails as "not sent".)
  6. EmailJS free plan: 200 emails/month. Check the team Gmail's spam folder the first time.
- [x] (done 2026-11-16) Supabase → Authentication → Sign In / Providers: "Allow new users to sign up" **on** and "Confirm email" **off** (needed for Create account; self sign-ups are always customers). New logins can also be made by staff in System → Users & access.

## 0b. Database 2 (Demo) — a clean database for the presentation

Database 1 (the current Supabase project) = **Practice**: rehearse freely, nothing to clean. Database 2 = **Demo**: built
fresh, with the clearer demand patterns (migration 024), and only used during the demo. Database 1 is not changed.

**Dry run now, real build on Dec 1** (the history always ends the day before it is generated; Dec 1 puts Black Friday in it).

1. supabase.com → New project (free) → note its **Project URL** and **anon public key** (Project Settings → API).
2. SQL Editor → paste **all of** `supabase/paste/1_setup_database.sql` (run `bash supabase/make_paste_files.sh` first) → Run.
   If the last result says "HISTORY PARTLY GENERATED", paste `supabase/seed/002_customers_history.sql` and Run again until it says **HISTORY COMPLETE**.
3. Paste `supabase/paste/2_run_checks.sql` → **ALL CHECKS PASSED** (includes the new PATTERN CHECKS).
4. Authentication → Sign In / Providers: "Allow new users to sign up" on, "Confirm email" off (same as database 1).
5. Authentication → Users → Add user (Auto Confirm) for the staff logins and `demo.customer@example.com`; then SQL Editor:
   `update profiles set role = 'staff' where id in (select id from auth.users where email in ('...', '...'));` and `select link_customer_logins();`
6. GitHub repo → Settings → Secrets and variables → Actions → add `VITE_SUPABASE_DEMO_URL` and `VITE_SUPABASE_DEMO_ANON_KEY` (database 2's values).
   Actions → "Build and deploy to GitHub Pages" → Run workflow.
7. On the site's sign-in page pick **Demo (database 2)**; the top bar shows a green "Demo DB" pill (yellow "Practice DB" on database 1).
   Each device remembers its choice. Tracking links / QR codes carry `?db=…`, so a phone opens the right database.
8. Rebuild on Dec 1: in database 2, Settings → **Reseed data through yesterday** (type RESEED) — wipes and regenerates the history
   ending Nov 30 (~1–2 minutes, keep the page open). Logins, products and settings stay. Then set **System → Allow "Reseed data" = false**
   so nobody can press it during the demo. (Demo morning: turn it on, reseed once more for a Dec 1 "yesterday", turn it off — optional.)
9. Reports → **Demand patterns** shows the patterns by order date (weekday, game days, back to school, product life cycle, Thanksgiving week).

## 1. Live-site checklists (deferred from Phases 4–10)

Run each phase's checklist in `HANDOFF.md`, on a laptop **and** a phone:

- [ ] Phase 4 — POS + Sales Orders
- [ ] Phase 5 — Production + MRP
- [ ] Phase 6 — 6-month history
- [ ] Phase 7 — Purchasing + Suppliers
- [ ] Phase 8 — Returns + Financials
- [ ] Phase 9 — Reports + Portal + Realtime
- [ ] Phase 10 — Order tracking, print failures, quotes, printer board, packing slip, capacity

### Run of 2026-11-25 (AI in the browser pane, staff login demo.staff1)

Staff-side steps passed unless listed in the bug log. Test data it made: SO-12562/12565/12566 (POS + Summit Ridge 25 keychains),
SO-12563 (Rebecca, Temple, now shipped), SO-12564 (cancelled), SO-12568 (exchange), SO-12569 + MO-4395 (custom quote "Checklist test widget"),
MO-4391/4393/4394 (Dragon 5+1 scrap, Temple failure + reprint), MO-4392 (Airplane 18, planned from MRP), PO-7174 (K&J, received + closed),
RMA-5107/5109/5112, bill PO-7147 paid. Settings changed and put back: ordering cost 15 → 30 → 15.

**Still needs a person** (not possible from one browser login):
- Two users at once: Phase 4 #8, Phase 5 #6, Phase 9 #6 (live update on a second screen).
- Portal as Demo Customer: Phase 9 #5–7, portal half of Phase 10 #7.
- Hardware: QR scan with a phone (Phase 10 #1), USB/camera scan-to-receive (Phase 7 #4), "Print receipt prints only the receipt" (Phase 4 #2).
- EmailJS arrival (Phase 10 #2): not set up; "not sent" logging works.

**Not run** (would change settings or add permanent data): custom quote markup change (10 #7), capacity warning level (10 #10),
New product design "Rocket" create (10 #12, page loads), spool load/unload/weigh (10 #13, page + reconciliation OK),
demand simulator (10 #14), transfer capacity override (10 #15), zone shipping (10 #16), periodic review "Send POs" (7 #6, page OK),
supplier lead-time edit (7 #1).

**Phone (375 px)**: 33 pages loaded; production order detail and MRP scrolled sideways (fixed in code, see bug log). The rest fit.

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
| 1 | AI 11-25 | Production order | Create and issue, then Complete in the same minute | Completes | "Finish time cannot be before the start time." (box sends 10:53:00, start was 10:53:xx) | Code: untouched time box sends the exact current time (also PO receipts). Needs deploy |
| 2 | AI 11-25 | Production / sales / PO detail | Complete, cancel, fulfill, receive | Page shows the new status at once | Old status + buttons stay clickable ~5 s until Realtime catches up | Code: page reloads right after the action. Needs deploy |
| 3 | AI 11-25 | New return | Return from a closed on-account order (SO-12565) | Preview says refund in cash (what posts) | Preview says "off the customer's account (A/R)"; journal correctly credits Cash | Code: label fixed in the screen. Needs deploy |
| 4 | AI 11-25 | Production order detail, MRP (phone) | Open at 375 px | No sideways scroll | Page 427 / 385 px wide | Code: phone grid columns use minmax(0, 1fr). Needs deploy |
| 5 | AI 11-25 | Everywhere | Search "Temple" | White only | Black/Blue/Red still sellable | Not a code bug: paste `023_temples_white_promo_codes.sql` in the SQL Editor |
| 6 | AI 11-25 | Dashboard, Reports, Backorders | Look at the last 30 days | Steady daily sales | No sales Nov 12–22; 92 backorder lines, most "after need date" (history stopped Nov 16; nothing fulfilled since) | **Open** — needs a catch-up of the history to yesterday before the demo |
| 7 | AI 11-25 | P&L | Nov column | Realized losses ≤ 0 | Inventory adjustments **+$308** (gain): someone's Nov 24 test adjusted Dragon - White +10,000 then −10,000; shrinks "cost of poor quality" | **Open** — data, decide: offsetting adjustment or leave |
| 8 | AI 11-25 | Printer board | Queue | Real jobs | MO-4387 + MO-4388: duplicate 77-plate Fidget Spinner Blue (test data) add ~116 h and push quote ready dates out | **Open** — cancel them? |
| 9 | AI 11-25 | Printer board / spools | AMS slots | 4 colors per printer | Printer 4 empty, 2–3 partly; 0 spools in stock, Black only 701 g | Demo prep: receive a Hobby Lobby filament PO into the Print Farm |
| 10 | AI 11-25 | Sales order | Cancel with empty reason | Reason required (checklist says "with a reason") | Cancels with no reason | Open (polish) |
| 11 | AI 11-25 | Sales order (backordered) | SO-12563 before production | Backorder + est. date on the order | Badge "Backordered" but card says "All lines are in stock… Fulfill (ship)" (on-hand units are promised to older orders); est. date only on Backorders page | Open (polish) |
| 12 | AI 11-25 | Suppliers | Scorecard | Every supplier has history | Target: no POs | Open (minor) |
| 13 | AI 11-25 | Print failures report | By reason | Useful denominator | "Orders with failures 20 of 20" | Open (minor) |
