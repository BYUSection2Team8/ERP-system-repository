-- =============================================================================
-- production_mrp_check.sql — Phase 5: MRP netting and production metrics.
-- Uses its own TEST items, so it passes on a live database. Everything is
-- ROLLED BACK. Success = "PRODUCTION + MRP CHECKS PASSED".
--
-- Numbers checked by hand:
--   Parent MRPTEST-P: 2 per plate, BOM per plate = 3 x part + 100 g filament,
--   production lead 1 day. Open order: 5 needed in 14 days; 1 on hand.
--     net 5 - 1 = 4 -> 2 plates -> 4 planned, projected balance 1 + 4 - 5 = 0
--     start by = need date - 1 day
--   Components (needed on the start-by date):
--     part:     2 plates x 3   = 6,   on hand 2   -> order 4 each
--     filament: 2 plates x 100 = 200 g, on hand 150 g -> short 50 g -> 1 spool (1000 g)
--     order-by = start-by - supplier lead 3 days = today + 10
--   After the PO is sent (arrives today + 3) and a production order is planned:
--     nothing left to order.
--   Metrics (orders dated 2099 so only these count):
--     A: 4 started, 4 good, 4 h, on time    B: 4 started, 3 good + 1 warped, 26 h, late
--     first-pass yield 1/2, unit yield 7/8, scrap rate 1/8, avg cycle 15 h, on time 1/2
-- =============================================================================
begin;

do $$
declare
  v_pf uuid := (select id from locations where code = 'PRINT_FARM');
  v_ff uuid := (select id from locations where code = 'FULFILLMENT');
  v_today date := (now() at time zone setting_text('time_zone'))::date;
  v_w0 date := date_trunc('week', ((now() at time zone setting_text('time_zone'))::date)::timestamp)::date;
  v_need date;
  v_wp int; v_wc int;
  s uuid; cust uuid; part uuid; fil uuid; par uuid; so uuid; po uuid; mo uuid; moa uuid; mob uuid;
  r record;
  m record;
begin
  v_need := v_today + 14;
  v_wp := (v_need - v_w0) / 7;
  v_wc := (v_need - 1 - v_w0) / 7;

  insert into suppliers (name, quoted_lead_days, payment_terms, terms_days)
  values ('MRPTEST Supplier', 3, 'Net 30', 30) returning id into s;
  insert into customers (name, state) values ('MRPTEST Customer', 'UT') returning id into cust;
  insert into items (sku, barcode, name, item_type, category, uom, stocking_policy)
  values ('MRPTEST-PART', 'MRPTEST-PART', 'MRP test part', 'purchased', 'component', 'ea', 'not_sold')
  returning id into part;
  insert into items (sku, barcode, name, item_type, category, uom, stocking_policy)
  values ('MRPTEST-FIL', 'MRPTEST-FIL', 'MRP test filament', 'purchased', 'filament', 'g', 'not_sold')
  returning id into fil;
  insert into items (sku, barcode, name, item_type, category, uom, price, stocking_policy,
                     units_per_plate, print_minutes, assembly_minutes, lead_time_days)
  values ('MRPTEST-P', 'MRPTEST-P', 'MRP test product', 'finished', 'product', 'ea', 10, 'make_to_order',
          2, 60, 0, 1)
  returning id into par;
  insert into item_suppliers (item_id, supplier_id, purchase_uom, stock_per_purchase_unit, unit_cost, is_preferred)
  values (part, s, 'ea', 1, 0.50, true), (fil, s, 'spool', 1000, 20.00, true);
  insert into boms (parent_item_id, component_item_id, qty_per_plate) values (par, part, 3), (par, fil, 100);

  perform receive_opening_inventory(part, v_pf, 2, 0.50);
  perform receive_opening_inventory(fil, v_pf, 150, 0.02);
  perform receive_opening_inventory(par, v_ff, 1, 4.00);

  so := create_sales_order(jsonb_build_object('customer_id', cust, 'fulfillment_method', 'ship',
          'ship_state', 'UT', 'need_date', v_need, 'lines', jsonb_build_array(jsonb_build_object('item_id', par, 'qty', 5))));

  -- ------------------------------------------------------------ parent level
  select * into r from mrp_parent_plan(4) where item_id = par and week_no = v_wp;
  if v_wp < 4 then
    assert r.gross_demand = 5 and r.on_hand = 1, format('parent demand %s on hand %s', r.gross_demand, r.on_hand);
    assert r.planned_plates = 2 and r.planned_qty = 4, format('parent planned %s plates / %s units', r.planned_plates, r.planned_qty);
    assert r.net_requirement = 4, format('parent net %s', r.net_requirement);
    assert r.projected_balance = 0, format('parent projected %s', r.projected_balance);
    assert r.start_by = v_need - 1, 'start by = need date - production lead time';
    assert (select sum(planned_plates) from mrp_parent_plan(4) where item_id = par) = 2, 'plates planned once';

    -- -------------------------------------------------------- component level
    select * into r from mrp_component_plan(4) where item_id = part and week_no = v_wc;
    assert r.gross_requirement = 6 and r.on_hand = 2, format('part gross %s on hand %s', r.gross_requirement, r.on_hand);
    assert r.planned_order_units = 4 and r.planned_order_qty = 4, format('part planned %s', r.planned_order_units);
    assert r.order_by_date = v_need - 1 - 3, format('part order-by %s', r.order_by_date);
    assert r.supplier_id = s and r.lead_days = 3, 'preferred supplier and its lead time';

    select * into r from mrp_component_plan(4) where item_id = fil and week_no = v_wc;
    assert r.gross_requirement = 200 and r.net_requirement = 50, format('filament gross %s net %s', r.gross_requirement, r.net_requirement);
    assert r.planned_order_units = 1 and r.planned_order_qty = 1000 and r.purchase_uom = 'spool',
      format('filament planned %s %s', r.planned_order_units, r.purchase_uom);
    assert r.projected_balance = 950, format('filament projected %s', r.projected_balance);

    -- One click: the PO the MRP screen would create (sent, expected today + 3).
    po := create_purchase_order(jsonb_build_object('supplier_id', s, 'source', 'mrp', 'lines', jsonb_build_array(
            jsonb_build_object('item_id', part, 'qty', 4, 'need_date', v_need - 1),
            jsonb_build_object('item_id', fil, 'qty', 1, 'need_date', v_need - 1))));
    assert (select status from purchase_orders where id = po) = 'sent', 'MRP PO is sent';
    assert (select coalesce(sum(planned_order_units), 0) from mrp_component_plan(4) where item_id in (part, fil)) = 0,
      'open PO covers the requirement';
    assert (select sum(scheduled_receipts) from mrp_component_plan(4) where item_id = fil) = 1000, 'PO shows as a scheduled receipt';

    -- Plan the production order: parent is covered, its components still count.
    mo := create_production_order(par, 4, v_need - 1);
    assert (select coalesce(sum(planned_plates), 0) from mrp_parent_plan(4) where item_id = par) = 0, 'MO covers parent demand';
    assert (select sum(gross_requirement) from mrp_component_plan(4) where item_id = part) = 6, 'planned MO still needs 6 parts';
    assert (select coalesce(sum(planned_order_units), 0) from mrp_component_plan(4) where item_id in (part, fil)) = 0,
      'still nothing to order';
    perform cancel_production_order(mo);
  else
    raise notice 'need date falls outside the 4-week window this week; MRP number checks skipped';
  end if;

  -- ---------------------------------------------------------- production metrics
  perform receive_opening_inventory(part, v_pf, 20, 0.50);
  perform receive_opening_inventory(fil, v_pf, 1000, 0.02);

  moa := create_production_order(par, 4, '2099-01-06');
  perform issue_production_order(moa, '2099-01-05 08:00-07');
  perform complete_production_order(moa, 4, 0, null, '2099-01-05 12:00-07');
  mob := create_production_order(par, 4, '2099-01-06');
  perform issue_production_order(mob, '2099-01-06 08:00-07');
  perform complete_production_order(mob, 3, 1, 'SCRAP_WARPING', '2099-01-07 10:00-07');

  select * into m from production_metrics('2099-01-01', '2099-01-31');
  assert m.orders_completed = 2 and m.qty_started = 8 and m.qty_good = 7 and m.qty_scrap = 1,
    format('metric counts %s/%s/%s/%s', m.orders_completed, m.qty_started, m.qty_good, m.qty_scrap);
  assert m.first_pass_yield = 0.5, format('first-pass yield %s', m.first_pass_yield);
  assert m.unit_yield = 0.875 and m.scrap_rate = 0.125, format('unit yield %s scrap rate %s', m.unit_yield, m.scrap_rate);
  assert m.avg_cycle_hours = 15, format('avg cycle %s', m.avg_cycle_hours);
  assert m.on_time_rate = 0.5 and m.orders_on_time = 1, format('on time %s', m.on_time_rate);
  assert (select qty_scrap from production_scrap_by_reason('2099-01-01', '2099-01-31') where reason_code = 'SCRAP_WARPING') = 1,
    'scrap by reason';
  assert (select cycle_hours from v_production_orders where id = mob) = 26, 'cycle time 26 h';
  assert (select on_time from v_production_orders where id = mob) = false, 'B finished late';

  raise notice 'PRODUCTION + MRP CHECKS PASSED';
end $$;

rollback;
