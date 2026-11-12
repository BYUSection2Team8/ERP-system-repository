# GSCM 401 — Mini-ERP Project Rubric (from the course assignment)

## Learning objectives

- Gain a greater understanding of how business functions connect within a system, and of the people across an organization who depend on that information accuracy.
- Understand how ERP systems reveal and structure business operations, leading to better decisions and leadership.
- Build confidence in tackling complex and unfamiliar work with new tools, taking responsibility for verifying the accuracy of your output.

## Assignment

Each team will build a working mini-ERP system for a small business using GenAI coding tools (Base44, Lovable, Claude Code, etc.) and some type of database (e.g., Supabase). Your system should demonstrate how ERP modules connect across sales, purchasing, inventory, finance, and customers. Teams should create a fake company in any of the four following domains: manufacturing, restaurant, distribution, or retail. There are no specific requirements regarding the business you invent, so long as it clearly exercises the functionality below and is BYU appropriate. Remember that GenAI tools will produce plausible-looking code that does not always work; you are responsible for verifying that your system actually behaves correctly.

## ERP System Required Capabilities

1. **Point of Sale** — multi-line-item sales, simple taxes/discounts, and a basic receipt. Completing a sale must reduce inventory and record revenue and costs for financial reporting.
2. **Inventory Management** — on-hand quantity by item and location (must have at least 3), transfers between locations, adjustments for cycle counts/damage with a reason code, backordered, and estimated date available based on lead time from supplier.
3. **Barcode Support** — each item carries a physical barcode value. Support "scan to add" in POS and "scan to receive/adjust" in inventory. Phone camera scan, USB scanner, etc. are all acceptable so long as it works. Must work using printed bar codes that can be attached to physical items — bring bar codes with you to your demo.
4. **Sales Orders** — create orders (customer, location, items, quantities), track status through Order Placed, Fulfilled, and Closed/Cancelled.
5. **Returns and Exchanges** — process a customer return and an exchange, returning items to inventory (including a quality failure with a reason code for the return/exchange) and reversing or adjusting revenue and costs appropriately.
6. **Production Orders** — create a production order (also called a work order or build) for any item you make, kit, package, move, or otherwise process in-house, specifying the item, quantity, and location. Issuing the order consumes components from inventory per that item's bill of material; completing it receives the finished item into inventory at a cost rolled up from the components used. Record quantity started, quantity completed good, and quantity scrapped or reworked with a reason code for quality issues, plus start and finish times. From this history, compute production and quality metrics of your choosing (at least 3) and show a production report of orders over a date range.
7. **Purchase Orders and Suppliers** — add/edit suppliers with contact info, a quoted lead time, and payment terms (e.g., Net 30), create and send POs, receive items against a PO (increasing inventory in a chosen location and recording date and quantities), and track status from Order Sent, Received, and Closed. Each PO should include an expected receipt date calculated from the supplier's lead time, and the system should compare actual receipt dates against it. Your system must also support inventory ordering rules: reorder points that incorporate lead time demand, periodic manual review, and EOQ calculated from average usage derived from your sales history, using ordering cost and holding cost values stored as editable settings in your system. Systems should include at least 6 months of sales histories that can be generated during system creation. Finally, include a scorecard for each supplier, computed from purchase order history (not static entry): on-time delivery rate, average actual lead time versus quoted lead time, fill rate (quantity received versus ordered), and payment tracking (amounts owed and due dates based on payment terms). Display each supplier's measures on one screen with a simple overall rating so a manager could decide which suppliers to keep, watch, or replace.
8. **Material Requirements Planning (MRP)** — at least 5 items must be parent items with a bill of material listing their child components and the quantity of each required per unit. Single-level BOMs (parent to component) are sufficient; nested subassemblies are optional. Making or selling a parent must consume those components from inventory. Each component must carry a lead time. Your system should take the parent quantities on confirmed sales orders, multiply them through the BOM to get component requirements, subtract on-hand inventory and quantities already on open purchase orders, and show what's left as a suggested order quantity along with an order-by date backed off from the requirement date by the component's lead time. A simple weekly view over the next 4 weeks is fine. Manufacturing teams can model assemblies, food service teams recipes, and retail teams bundled kits.
9. **Financial Reporting** — Profit & Loss, inventory valuation (weighted average cost is fine), and inventory turnover that updates live with changes made elsewhere in the system.
10. **Reporting** — reports that would be useful to managers (e.g., sales by day/week, top-selling items, low stock with suggested order quantities and order-by dates, inventory by location, supplier performance such as average actual lead time versus quoted lead time).
11. **Customer-Facing ERP** — customer login, visibility into available inventory and item location, and the ability to place an order for pickup.
12. **Multi-user logins** — the system should update for all users after changes are made (e.g., if a sale is input by one user, the system should update inventory for other users' logins).

## Other capabilities

**Starting Data** — your system must launch with realistic data (generated by AI for your system) already in place: at least 25 items (these include the child components), each with a barcode, cost, price, reorder point, and lead time; at least 5 of those items must be parent items with bills of material; at least 3 inventory locations; at least 6 suppliers, each with a quoted lead time; at least 10 customers; and at least 6 months of sales history. These may be generated by the AI, but it must vary realistically across items and time — flat or purely random data will not produce sensible reorder points or EOQ values, and that will be obvious.

**"Wow" factor(s)** — be creative; this should be something that could really help the business; teams receiving top scores will show that teams went the extra mile in effort.

## Final deliverable

A working ERP system that can perform all 12 required capabilities listed above plus some wow factor(s). It will be demonstrated live for Dr. Wright in 10 minutes (including questions). No slides or prepared scenarios; Dr. Wright determines the scenario. The demo occurs during class time at the team's assigned slot.

Checked in **every** demo:
- Point of Sale OR Sales Orders
- Inventory Management
- Returns and Exchanges
- Production Orders
- Financial Reporting
- Material Requirements Planning (MRP)

Also:
- Dr. Wright will select 2–4 additional Required Capabilities from the list of 12
- Show the "Wow" factor(s)
- Every teammate must present at least one feature
- **Every number the system displays must be computed from stored data, not static entry.** You may be asked to change an input and re-show the result.
- Teams dressed professionally
- AI coding tools, database(s), etc. used must be clearly documented somewhere within the system
- A significant portion of the score is based on illustrating understanding of ERP and MRP concepts through the demo

## Rubric (intentionally vague)

| Criteria | Poor | Average | Elite |
|---|---|---|---|
| Required Capabilities | Only a few work correctly; the rest failed in some way | Most work correctly | All work correctly, handled perfectly and without issue |
| System Usability & Professionalism | Clearly an unfinished prototype with bugs, broken links, etc. | Usable and mostly clean, but clunky and not self-explanatory | Looks and behaves like real commercial software (credible in front of an actual business owner) |
| Demo presentation delivery and ERP Understanding | Team cannot explain how features connect; limited grasp of basic ERP concepts | Team explains the system, but members mostly know only their own portion. Dressed professionally | Team illustrates mastery of basic ERP concepts. Demo highly polished and professional. Dressed professionally |
| Wow Factor | No wow factor attempted | — | Works perfectly; ingenious feature showing creativity and effort that would generate substantial value |

(The rubric also has "Good" and "Strong" columns between Average and Elite, with no descriptions.)
