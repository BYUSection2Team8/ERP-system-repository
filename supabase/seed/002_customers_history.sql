-- =============================================================================
-- seed/002_customers_history.sql — Phase 6: all 60 customers + 6 months of history
--
-- Run AFTER seed/001_starter_data.sql and every migration.
--
-- Nothing here inserts a balance, a cost or an order total. The history is
-- produced by calling the SAME business functions the app uses, one simulated
-- day at a time (about 180 days ending yesterday):
--   * customers order from the demand model below -> create_sales_order / pos_sale
--   * made-to-order items and low stock trigger production orders
--     -> create / issue / complete_production_order (with realistic print failures)
--   * low components trigger purchase orders -> create_purchase_order, receipts that
--     arrive on time, late, split or short by supplier -> receive / close PO,
--     Net-terms bills paid near their due date -> record_supplier_payment
--   * Tue/Fri delivery runs to campus -> transfer_inventory
--   * orders are fulfilled and closed (on-account orders when the customer pays),
--     a few are returned or exchanged -> process_return, QA Hold inspections,
--     cycle counts -> count_inventory / adjust_inventory
-- so every balance, cost, reorder point, EOQ and scorecard is DERIVED.
--
-- The simulator itself lives in migrations/024_simulator_reseed.sql (schema sim).
-- Demand model (SPEC.md): daily orders per segment =
--   base x trend (5%/month) x season x day-of-week x events (BYU home games,
--   Thanksgiving week) with Poisson noise. Colors, products and quantities follow
--   each segment's preferences.
--
-- Safe to re-run: it continues where it stopped and does nothing once complete.
-- Each run works for at most ~45 seconds (the SQL Editor may time out on longer
-- requests) and then COMMITS what it did. If the result row says
-- "run this file again", paste and run it again until it says COMPLETE.
-- =============================================================================
set statement_timeout = 0;

select sim.run_history(make_interval(secs =>
         coalesce(nullif(current_setting('pp.history_budget_seconds', true), '')::double precision, 45)));

select case when exists (select 1 from settings where key = 'history_complete' and value = 'true')
            then 'HISTORY COMPLETE: ' || (select count(*) from customers) || ' customers, '
                 || (select count(*) from sales_orders) || ' sales orders, '
                 || (select count(*) from purchase_orders) || ' purchase orders, '
                 || (select count(*) from production_orders) || ' production orders'
            else 'HISTORY PARTLY GENERATED through ' || (select value from settings where key = 'history_generated_through')
                 || '. Run this file again to continue.' end as result;
