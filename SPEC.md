# Poulson Prints ERP — Spec (text version)

> Condensed text copy of `Poulson Prints ERP — System Spec.pdf` (23 pages, Nov 11 2026).
> **AI assistants: read this file instead of the PDF.** The PDF is rendered as images and costs
> far more tokens to read. Only open the PDF if something here looks wrong or missing.

## ⚠️ Build scope: LEAN CORE first (decided 2026-11-12)

The full spec below is the long-term vision. **Build only the Core column now.** Everything in the Stretch
column waits until the core passes all 12 rubric capabilities, but the code must leave room for it
(see "Extension points" in `HANDOFF.md`). Where this table and the sections below disagree, this table wins.

| Area | CORE (build now) | STRETCH (later, do not build yet) |
|---|---|---|
| Items | 30 finished + 17 purchased items, each with barcode, cost, price, reorder point, lead time | New Design wizard, product lifecycle, "like item" forecasting |
| Filament | Each filament color is one item stocked in **grams**; bought as 985 g spools (PO qty in spools × 985 g) | Per-spool barcodes, gram tracking per spool, loading spools onto printers, near-empty flags |
| Locations | Print Farm, Fulfillment Center, Campus Counter, QA Hold | Capacity (cu ft) model, utilization warnings, manager overrides, space-capped EOQ |
| Costing | Unit cost = components + labor + machine time, from settings and weighted-average cost | Multi-color purge waste setting |
| POS | Multi-line, scan to add, Utah sales tax, BYU 10% / manual discount with reason, printable receipt | Business 15% bulk rule, emailed receipt, tracking QR |
| Sales orders | Rubric statuses: Order Placed → Fulfilled → Closed/Cancelled; backorders with est. available date | Detailed tracking stages (Queued, Printing, …), printer queue, ready-date countdown |
| Shipping/packing | Flat shipping fee setting and flat packaging cost per order (both editable settings) | USPS zone rate table, delivery runs, automatic box selection, packing-time model |
| Returns | Return + exchange, reason codes, quality failures go to QA Hold, 10% restocking fee, revenue/COGS reversed | Failure analytics tie-in |
| Production | Issue/complete, BOM consumption, good/scrap qty with reason, start/finish times, 3+ metrics (first-pass yield, scrap rate, avg cycle time), report by date range | Printer assignment, printer utilization, Report Failure button with auto-reprint |
| Purchasing | Suppliers, POs, partial receipts, expected vs actual dates, ROP, EOQ, periodic review screen, scorecard with Keep/Watch/Replace, amounts owed + due dates from terms | Full AR/AP payment recording, price stability weighting can be simple |
| MRP | 4-week weekly view, netting vs on-hand and open POs, order-by dates, one-click create PO | — |
| Holding cost | One editable annual carrying rate (default 18%, seasonal 33%) feeding EOQ | Three-bucket holding cost report, storage cost per cu ft, slow-mover flags |
| Financials | P&L (sales, discounts, net sales, shipping revenue, COGS, packaging cost, realized losses from adjustments), inventory valuation (weighted avg), turnover, all from ledger | Cost of poor quality line, holding cash costs on P&L |
| Reports | Sales by day/week, top sellers, low stock with suggested qty + order-by date, inventory by location, supplier performance | Failure analytics, holding cost report |
| Customer portal | Login, available inventory by location, place pickup order, see own orders | Shipped orders with delivered-by date, quote calculator, tracking page |
| Multi-user | 3 staff logins + 1 demo customer, Supabase Realtime refresh on all screens | Live activity feed panel (the `activity_log` table is core; only the UI panel is stretch) |
| Data | Phase 2: items, BOMs, suppliers, ~5 customers. Phase 6: all 60 customers + 6 months of history from the demand model | Demand simulator button |
| Docs/demo | Simple "About this system" page listing AI tools + database (rubric requirement) | Requirements map page, Show-the-math panels everywhere, Reset demo data button |

**Wow factor priority (build in this order once core is done):** 1) Live order tracking with email + QR, 2) Print failure analytics + Report Failure, 3) Show-the-math panels + Requirements map, 4) Quote calculator, 5) Spool tracking + printer board, 6) Box selection + shipping zones, 7) Capacity model, 8) New Design wizard / demand simulator. The rubric requires at least one wow factor, so at minimum #1 must be built before the demo.

## Company

Fictional Utah 3D-printing business. Sells mostly online, plus a campus pickup counter at BYU.
4 Bambu Lab P2S printers, each with an AMS multicolor unit. Pull model: popular items stocked, the rest printed to order.

- Staff hours 8am–8pm. Prints can run past 8pm; completion waits until 8am next morning.
- Labor $20/hr. Setup 1 min + cleanup 1 min **per plate** (not per unit).
- Delivery runs Tue & Fri, Stansbury Park → BYU, ~65 mi each way, ~$0.70/mile.
- Brand: navy with teal accent; logo = "P" built from stacked print layers with a nozzle printing the top layer.

### Locations

| Location | Role | Capacity |
|---|---|---|
| Stansbury Park Print Farm | Printers, filament, raw materials, WIP | 40 cu ft general shelving + filament rack of 60 spools |
| QA Hold (quarantine inside Print Farm) | Returned quality failures awaiting inspection | own 8 cu ft shelf, tracked separately |
| Stansbury Park Fulfillment Center | Finished goods, packaging, packing, shipping | 120 cu ft |
| BYU Campus Pickup Counter | Walk-up POS, display stock, pickup orders | 12 cu ft |

Warnings: yellow >85%, red >100%. QA Hold >85% → dashboard flags inspection backlog.

## Products (9 products → 30 sellable items)

Single-color products come in red, white, blue, black; each color is its own item + barcode.
Prices are final; margins recalc live as costs change.

| Product | Variants | Stocking | Unit cost | Price | Size (in) | Box | Packing class |
|---|---|---|---|---|---|---|---|
| Dragon | 4 colors | In stock | $1.07 | $8.99 | 4×2×1.5 | Small | Standard (1 min) |
| Keychain (blue/white, printed in lots of 10) | 1 | In stock | $0.93 | $4.99 | 2×1×0.25 | Small | Small (0.5 min) |
| Fidget Spinner | 4 colors | In stock | $2.85 | $7.99 | 3×3×0.5 | Small | Standard (1 min) |
| Christmas Ornament (seasonal Nov 1–Dec 31) | 4 colors | In stock in season | $1.44 | $7.99 | 3×3×0.5 | Small | Standard (1 min) |
| Temple (LED tealight) | 4 colors | Made to order | $6.65 | $27.99 | 4×4×5 | Medium | Fragile (2 min) |
| Army Soldiers (lot of 10, sold only as lot) | 4 colors | Made to order | $9.98 | $19.99 | 5×3×2 | Small | Multi-piece (1.5 min) |
| Airplane (black/blue/white/red multicolor) | 1 | Made to order | $10.37 | $39.99 | 10×9×3 | Large | Fragile (2 min) |
| BYU Logo | 4 colors | Made to order | $2.31 | $14.99 | 7×5×0.75 | Medium | Standard (1 min) |
| Magnet Alphabet Set (26 letters) | 4 colors | Made to order | $10.69 | $22.99 | 5×4×1.5 | Small | Multi-piece (1.5 min) |

- Unit cost = product cost only (filament + machine + labor + components). Packing labor, packaging, postage = fulfillment cost per order.
- Units per plate: default 1, editable per product. Hints: Dragon 6, Spinner 4, Ornament 8.
- Multi-color AMS purge waste: setting (g per color change) added to Keychain and Airplane cost.
- Ornament shows in customer portal only inside its window; forecast "sells like Dragon × 1.5" until it has history.

## BOMs (single level, 9 parents)

| Product (per plate) | Print time | Filament | Components | Assembly | Fil $ | Mach $ | Labor $ | Parts $ | Total |
|---|---|---|---|---|---|---|---|---|---|
| Temple (1) | 5h05m | 58.36 g chosen color | 1 g glue, 1 LED tealight | 10 min | 0.89 | 1.07 | 4.00 | 0.70 | 6.65 |
| Dragon (1) | 1h09m | 10.43 g chosen color | none | 0 | 0.16 | 0.24 | 0.67 | 0.00 | 1.07 |
| Keychain (lot of 10) | 3h08m | 13.96 g blue + 2.47 g white | 10 split rings, 10 chains | 2 min each (20) | 0.25 | 0.66 | 7.33 | 1.10 | 9.34/lot = 0.93 ea |
| Army Soldiers (lot of 10) | 3h00m | 27.7 g chosen color | 2 g glue, 10 figure bases | 20 min/lot | 0.42 | 0.63 | 7.33 | 1.60 | 9.98 |
| Airplane (1) | 7h49m | 14.77 g black, 55.59 g blue, 84.99 g white, 16.29 g red | 1.5 g glue | 15 min | 2.61 | 1.64 | 5.67 | 0.45 | 10.37 |
| BYU Logo (1) | 1h44m | 84.44 g chosen color | none | 0 | 1.28 | 0.36 | 0.67 | 0.00 | 2.31 |
| Magnet Alphabet Set (1) | 1h59m | 41.52 g chosen color | 26 magnets, 2.5 g glue | 20 min | 0.63 | 0.42 | 7.33 | 2.31 | 10.69 |
| Fidget Spinner (1) | 45m | 18 g chosen color | 1 608ZZ bearing, 3 hex nuts | 3 min | 0.27 | 0.16 | 1.67 | 0.75 | 2.85 |
| Christmas Ornament (1) | 50m | 12 g chosen color | 1 ribbon hanger | 1 min | 0.18 | 0.18 | 1.00 | 0.08 | 1.44 |

Costs are calculated live from settings + weighted-average component costs (these are starting points, not stored values):

`Unit cost = (g·c_g + h·r_m + ((2 + a)/60)·r_l + Σ component costs) / units_per_plate`

g = filament grams, c_g = $0.0152/g, h = print hours, r_m = $0.21/hr machine, a = assembly min, r_l = $20/hr.

## Suppliers (7) and purchased items (17)

Real companies; contact names fictional; scorecard performance from simulated PO history (screen says so).

| Supplier | Items | Unit cost | Quoted lead | Terms |
|---|---|---|---|---|
| Hobby Lobby | PLA filament red/white/blue/black (985 g spool, part 2589638); ribbon hanger | $14.99/spool; $0.08 | 2 days | Paid at purchase |
| Bambu Lab | PLA filament backup source (1 kg) | $19.99/spool | 7 days | Paid at purchase |
| Uline | Boxes Small 6×4×4, Medium 9×7×5, Large 12×10×6; tissue paper | $0.45, $0.75, $1.25; $0.05/sheet | 2 days | Net 30 |
| Amazon Business | Super glue (per g), LED tealight, split ring, keychain chain, figure base 25 mm, hex nut | $0.30, $0.40, $0.06, $0.05, $0.10, $0.05 | 3 days | Net 30 |
| K&J Magnetics | Neodymium magnet 6×2 mm | $0.06 | 6 days | Net 15 |
| VXB Bearings | 608ZZ bearing | $0.60 | 8 days | Net 30 |
| Vistaprint | Thank-you card | $0.15 | 10 days | Paid at purchase |

- 30 finished + 17 purchased = 47 items.
- Each spool has its own barcode, tracked to the gram (starts 985 g).
- Purchase prices vary in history (Hobby Lobby sales) so weighted-average cost moves.
- Packaging rule: box + tissue per box shipped; 1 thank-you card per order.

## Inventory, capacity, holding cost

- Inventory is **never typed in**: on-hand, spool grams and values are derived from transactions (receipts, production, sales, returns, transfers, adjustments).
- Utilization = item dimensions × qty on hand (boxes counted folded flat). Optional max stock per item per location.
- Over capacity = **warn, never block**. Over 100% needs manager override with reason code (who/when/why logged); system suggests fix (transfer, split delivery, pull production forward). Returns, completed production for existing orders, and received goods always allowed but flagged.
- EOQ / reorder / MRP suggestions capped by available space ("EOQ says 18 spools, rack has room for 11").

Holding cost rates (editable):

| Component | Rate | Bucket |
|---|---|---|
| Cost of capital | 10%/yr | Opportunity |
| Insurance | 1%/yr | Cash |
| Expected shrinkage | 2%/yr | Opportunity (estimate) |
| Expected obsolescence | 5%/yr; 20% seasonal | Opportunity (estimate) |
| Storage space | $1.50/cu ft/month | Cash |

Total carrying rate 18%/yr standard, 33% seasonal, plus space.
Holding cost report, 3 buckets: (1) Cash costs → P&L operating expense; (2) Realized losses from adjustments with reason codes → P&L; (3) Opportunity/risk → management report only, feeds EOQ. Compares expected shrinkage (2%) vs. actual, flags slow movers (no sales 60 days), shows leftover seasonal stock after window.

## The 12 capabilities — how Poulson Prints does them

1. **POS** — multi-line sales at campus counter; scan to add; Utah sales tax; discounts (BYU student 10%, business 15% on 25+ units, manual with manager reason; one discount per order, best applies); printed/emailed receipt with tracking QR. → inventory, ledger (revenue, discounts, tax, COGS), tracking email.
2. **Inventory** — on-hand by item & location (3 + QA Hold); transfers; adjustments with reason codes (cycle count, damaged, lost, obsolete); backorders with estimated available date; capacity & holding costs. Adjustments feed realized losses on P&L.
3. **Barcodes** — Code 128 on every item and every spool; printable label sheet; phone-camera scanning (typed entry backup); scan-to-add in POS; scan to receive/adjust/transfer/count in inventory; spool loading.
4. **Sales Orders** — customer, location, items, qty; status Order Placed → Fulfilled → Closed/Cancelled, with tracking stages underneath (Queued, Printing, Assembly, Packing, Shipped/Ready for Pickup). → MRP demand, printer queue, box selection, shipping, tracking email.
5. **Returns & Exchanges** — 30-day policy; exchange for different color/product; quality failures get reason code, full refund, go to QA Hold; "changed my mind" on made-to-order = 10% restocking fee; revenue and COGS reversed/adjusted. → inventory, ledger, failure analytics.
6. **Production Orders** — item, qty, location; issue consumes BOM components (filament from specific spools); complete receives finished goods at rolled-up cost; qty started / good / scrapped-reworked with reason; start & finish times; Report Failure button. Metrics: first-pass yield, scrap rate, avg cycle time, on-time completion, printer utilization. Production report over date range.
7. **POs & Suppliers** — supplier records (contact, quoted lead time, terms); PO status Order Sent → Received → Closed; expected receipt = sent date + lead time; partial receipts into chosen location; reorder points; periodic review screen; EOQ from sales history; supplier scorecard with overall rating.
8. **MRP** — confirmed SOs × BOM = component requirements − on-hand − open POs = suggested order qty; order-by date = need date − lead time; 4-week weekly view; one click creates the PO.
9. **Financials** — P&L (gross sales, discounts, net sales, shipping revenue, COGS, fulfillment cost, cost of poor quality, operating expenses); inventory valuation at weighted average cost; inventory turnover; all live from ledger.
10. **Reporting** — sales by day/week, top sellers, low stock with suggested qty & order-by date, inventory by location, supplier performance, production report, holding cost report, failure analytics.
11. **Customer portal** — customer login; available inventory by location; pickup or shipped orders; out-of-stock items still orderable with delivered-by date; quote calculator; order tracking.
12. **Multi-user** — 3 identical staff logins + 1 demo customer login; Supabase Realtime pushes changes to every open screen; live activity feed.

### Key formulas (shown in "Show the math" panels)

- Reorder point = d̄ × L + z·σ_d·√L  (d̄ avg daily usage from sales history, σ_d its std dev, L lead time days, z setting default 1.65 = 95%)
- EOQ = √(2DS / H)  (D annual demand from history, S ordering cost setting default $15, H annual holding cost per unit from rates)
- For in-house finished goods: L = production lead time, EOQ = economic production batch size, S = setup cost.
- Inventory turnover = COGS (period) / average inventory value
- Supplier overall rating = on-time 40% + fill rate 30% + lead-time accuracy 20% + price stability 10% → Keep (80+), Watch (60–79), Replace (<60). Scorecard also shows payment tracking (amounts owed, due dates from terms). All from PO history.

## Wow factors

1. **Live order tracking with email link** — after any order (online, quote, POS) ask for email, send "Track your order" link via EmailJS from team Gmail. Private unguessable link, no login. Shows stage, % printed, countdown to ready/delivered (from print time, staff hours, printer queue). Safety net: confirmation screen shows link + QR; every email logged sent/failed.
2. **Custom quote calculator** — customer enters design name/description, est. print hours, grams, color; shipping or BYU pickup; optional file attachment (stored, not analyzed). Price = (filament + machine + labor + packaging + failure allowance from actual failure history) × markup, min $10, + shipping + tax. Ready date = next open printer slot + print + assembly + packing + transit/next delivery run. One click → sales order.
3. **Automatic box selection** — packs largest first into fewest, smallest boxes (80% fill limit, longest-side check). Packing slip explains choice; box drives packing time, packaging cost, postage.
4. **Live filament spool tracking** — each spool barcoded, starts 985 g; scan to load into a printer's AMS slot; grams deducted as prints run and on failures; near-empty flagged; runout is a failure reason. Printer board: each P2S, loaded spools, current job, time remaining.
5. **Print failure analytics** — reasons: warping, bed adhesion, spaghetti/detached, layer shift, nozzle clog, filament runout, stringing/quality reject, power/network loss. Failure rate by printer/product/color/reason; wasted grams & dollars; trends. Seeded patterns: one printer due for maintenance, tall Airplane warps more, runouts near spool ends. Report Failure on running print writes off filament, records scrap, auto-queues reprint, pushes back tracking date. Optional auto-simulate toggle (off by default).

Also included: New Design wizard (print data, components, size, colors, stocking policy → items, barcodes, BOM, cost, suggested price; lifecycle Draft → Active → Seasonal → Retired; "like item" forecasting); Demand simulator ("Simulate next day/week" with events like BYU game); Shipping estimator (USPS Ground Advantage–style zone × weight table from Stansbury Park; shipping revenue vs postage on P&L; free BYU pickup via Tue/Fri runs); Show-the-math panel on every calculated number; QA Hold; Cost of poor quality line on P&L; AR & AP with payment recording; Live activity feed; Requirements map page (every rubric line → its screen) + AI tools/database documentation; Reset demo data button.

## Settings (all editable, stored in DB; changes ripple everywhere)

| Area | Setting | Default |
|---|---|---|
| Labor | Labor rate | $20/hr |
| Labor | Setup / cleanup per plate | 1 / 1 min |
| Labor | Staff hours | 8am–8pm daily |
| Machine | Printer cost / life | ~$700 / 5,000 print hrs |
| Machine | Electricity | 0.15 kW × ~$0.11/kWh |
| Machine | Maintenance | $0.05/hr |
| Machine | Machine rate (calc) | ≈ $0.21/hr |
| Filament | Spool weight / cost per g (calc) | 985 g / ≈ $0.0152 |
| Filament | AMS purge per color change | TBD grams |
| Packing | Per box | 3 min |
| Packing | Per item by class | Small 0.5, Standard 1, Multi-piece 1.5, Fragile 2 min |
| Packing | Pickup (no label) / counter sale | −1 min per box / 1 min per item |
| Ordering | Ordering cost per PO (S) | $15 |
| Ordering | Service level (z) | 95% (1.65) |
| Ordering | Periodic review interval | 14 days |
| Holding | Carrying rates | see above |
| Sales | Sales tax | Provo combined rate (verify); Utah orders only; shipping not taxed |
| Sales | Discounts | BYU 10%, business 15% on 25+ units, manual with reason |
| Sales | Returns | 30 days; 10% restocking fee on changed-mind made-to-order |
| Quotes | Markup / minimum | 2.5× / $10 |
| Shipping | Rate table | Zones 1–8 by weight bracket |
| Shipping | Transit days | 2–5 by zone |
| Delivery | Runs / distance / rate | Tue & Fri / 65 mi each way / $0.70/mi |
| Capacity | Location capacities & warnings | see Locations |
| Products | Units per plate | 1 (hints Dragon 6, Spinner 4, Ornament 8) |

## Starting data & demand model

6 months of history (≈ June–Nov 2026) generated as **real transactions** so every balance is derived.
47 items, 9 BOM parents, 3 locations + QA Hold, 7 suppliers, 60 customers (11 with portal logins + 1 demo customer).

Daily demand = base × trend × season × day-of-week × events × noise

- Base: e.g. keychains ~6/day, dragons ~3/day, airplanes ~2/week.
- Trend ~3%/month growth.
- Season: summer slow; late Aug–Sep back-to-school spike; Nov–Dec holiday ramp; ornament only in season.
- Day of week: online peaks Sun/Mon evenings; campus counter weekdays only.
- Events: BYU home football games lift BYU Logo and blue items; Black Friday.
- Color mix: blue leads BYU items, white leads temples, black leads soldiers.
- Channel ~80% online shipped, 20% campus counter/pickup.
- Noise: Poisson-style, never flat or uniform random.
- Same model powers the demand simulator.

Customer segments: BYU Student 18 (keychains, BYU logo, spinners, dragons; small frequent; mostly campus pickup), Gift Buyer 16 (temples, magnet sets, airplanes; larger; Nov–Dec; mostly shipped, many out of state), Hobbyist 12 (soldiers, airplanes, dragons, custom quotes; steady; shipped), Local Family 9 (magnet sets, dragons, spinners, keychains; summer & holiday; shipped and pickup), Business 5 (bulk keychains, spinners, dragons; large infrequent; Net 30; shipped).

Emails use `firstname.lastname@example.com`. 🔑 = portal login.

Students: 1 Ethan Caldwell, Provo 🔑 · 2 Madison Reeves, Provo · 3 Tyler Okafor, Orem · 4 Hannah Lindqvist, Provo 🔑 · 5 Jacob Tuilagi, Provo · 6 Abigail Navarro, Orem · 7 Caleb Whitfield, Provo · 8 Emma Kawamoto, Provo 🔑 · 9 Samuel Brightwater, Springville · 10 Olivia Marchetti, Provo · 11 Noah Delacroix, Orem · 12 Grace Sorensen, Provo 🔑 · 13 Isaac Fonoti, Provo · 14 Lily Ashcroft, Lehi · 15 Daniel Park, Provo · 16 Chloe Vandermeer, Provo · 17 Mason Ellsworth, Orem · 18 Ava Thibodeaux, Provo

Gift Buyers: 19 Rebecca Holloway, Salt Lake City UT 🔑 · 20 Mark Jensen, Sandy UT · 21 Linda Castellanos, Mesa AZ 🔑 · 22 Karen Whitaker, Boise ID · 23 Steven Albright, Las Vegas NV · 24 Rachel Nakamura, St. George UT · 25 Paul Esposito, Sacramento CA · 26 Julie Pemberton, Logan UT · 27 Brian Oyelaran, Denver CO · 28 Megan Halvorsen, Draper UT · 29 Thomas Brennan, Idaho Falls ID · 30 Susan Mortensen, Ogden UT · 31 Gregory Lam, Seattle WA · 32 Diane Fairbanks, Gilbert AZ · 33 Kevin Andersen, Dallas TX · 34 Natalie Crowther, Tooele UT

Hobbyists: 35 Marcus Bellweather, West Jordan UT 🔑 · 36 Derek Stroud, Tooele UT · 37 Aaron Velasquez, Phoenix AZ · 38 Brandon Kowalski, Chicago IL · 39 Jared Pettersen, Grantsville UT · 40 Victor Ramos, Reno NV · 41 Colton Hayes, Stansbury Park UT · 42 Wesley Chandler, Portland OR · 43 Trevor Lindgren, American Fork UT · 44 Dustin Moreau, Austin TX · 45 Kyle Fujimoto, Layton UT · 46 Russell Ngata, Kearns UT

Local Families: 47 Jennifer Olsen, Stansbury Park UT 🔑 · 48 Amanda Christiansen, Erda UT · 49 Heather Larsen, Tooele UT · 50 Michelle Barlow, Herriman UT · 51 Stephanie Gutierrez, Spanish Fork UT · 52 Laura McAllister, Kaysville UT · 53 Nicole Haddad, Eagle Mountain UT · 54 Crystal Pulsipher, Cedar City UT · 55 Angela Whitmore, Saratoga Springs UT

Businesses: 56 Summit Ridge Gifts (Dana Moffat), Park City UT 🔑 · 57 Lakeview Toy Chest (Ryan Castillo), Bountiful UT · 58 Wasatch Tinkerers Guild (Jordan Ellis), Salt Lake City UT 🔑 · 59 Canyon View Boutique (Priya Raman), Heber City UT · 60 Provo Peak Party Supply (Ben Hartley), Provo UT 🔑

## Technical architecture

Claude Code → GitHub → GitHub Pages (built by GitHub Actions on every push); data in Supabase. All $0.

| Piece | Choice |
|---|---|
| Frontend | React + TypeScript (Vite) |
| Database | Supabase (Postgres): data, logins, realtime |
| Hosting | GitHub Pages via GitHub Actions (HTTPS needed for phone camera) |
| Email | EmailJS + team Gmail |
| Barcodes | Code 128 labels generated in app; phone-camera scanning library |

- **All-or-nothing transactions**: sales, returns, receiving, production issue/complete, transfers run as Postgres functions so inventory and financials never get out of sync.
- **Ledger table**: every transaction posts journal entries; P&L, valuation, turnover calculated from it.
- **Security**: repo must be public for free GitHub Pages → row-level security required; service-role key never in code. Anon key OK only with RLS on.
- Documentation page in app lists Claude Code, Supabase, GitHub, GitHub Pages, EmailJS.

### Setup steps (owner does clicks; AI writes code)

1. Accounts: team Gmail; GitHub; Supabase (project `poulson-prints`, US West, Free; save DB password in a password manager, never in code/chat); EmailJS (Gmail service).
2. Install Git and Node.js LTS on builder's computer.
3. Repo created (public for Pages). Supabase Project Settings → API: copy Project URL + anon/publishable key (NOT service_role). Add them + EmailJS Service ID / Template ID / Public Key as GitHub Actions secrets. Settings → Pages → Source: GitHub Actions. Run SQL files in Supabase SQL Editor (schema, then seed). Supabase Auth → URL Configuration → Site URL = Pages address. Test staff + customer logins and one sale.
4. Everyday: ask for change → run locally → commit & push → site updates in 1–2 min; re-run changed SQL in Supabase when told. Only one teammate pushes at a time; others pull first.

Supabase free projects pause after ~1 week idle — log in the week before the demo and that morning.

## Demo plan (6 teammates)

| Teammate | Owns | Backs up | Wow factor |
|---|---|---|---|
| 1 | POS, Sales Orders, Customer portal | Returns | Live order tracking + email/QR |
| 2 | Inventory, Barcodes, capacity & holding costs | Production | Live spool tracking |
| 3 | Returns & Exchanges, Financials | POS | Cost of poor quality on P&L |
| 4 | Production Orders, production report | Inventory | Failure analytics + Report Failure |
| 5 | MRP, POs & Suppliers, EOQ/ROP, scorecard | Financials | Capacity-capped EOQ |
| 6 | Reporting, Multi-user, New Design wizard | MRP | Quote calculator + box selection |

Everyone can tell the end-to-end story: customer order → MRP & printer queue → consumes filament & components → packed & shipped → revenue, COGS, fulfillment cost on P&L.
Demo day: two laptops as different staff users + one as demo customer; phone for scanning; printed barcode labels on real items and a spool; reset demo data night before; requirements map open; professional dress.

## Schedule (due Dec 2, 2026, 11:30pm)

1. Nov 11–17: setup, database, starting data, inventory, barcodes, POS, sales orders.
2. Nov 18–24: production, purchasing & suppliers, MRP, returns, financials, customer portal.
3. Nov 25–Dec 1: wow factors, polish, testing on several computers/phones, practice (Thanksgiving week).

## Risks

Supabase paused on demo day → log in final week & that morning. Email in spam → QR + link on confirmation. Camera can't read barcode → good light, typed backup. Unexpected input (negative qty, oversell, over-receipt) → validation, auto backorders, over-receipt warning. Messy practice data → Reset button. Teammates only know their section → end-to-end practice. Date drift → history generated relative to launch date; ornament in season in December.

## Open items (from spec)

- [ ] Fill in teammate names in demo plan
- [ ] Choose team Gmail name
- [ ] Verify Provo combined sales tax rate before seeding
- [ ] Estimate AMS purge waste grams per color change
- [ ] Confirm Hobby Lobby spool net weight (985 g assumed)
- [ ] Team review of spec, then "Begin coding"
