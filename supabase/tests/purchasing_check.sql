-- =============================================================================
-- purchasing_check.sql — Phase 7: reorder point, EOQ, periodic review, scorecard.
-- Uses its own TEST item and supplier and a 10-day demand window, so it passes
-- on a live database. Everything is ROLLED BACK. Success = "PURCHASING CHECKS PASSED".
--
-- Numbers checked by hand (window = last 10 days, z = 1.65, R = 14 days):
--   PCTEST-FG sells 2/day on 5 of the 10 days, 0 on the other 5:
--     d = 10/10 = 1.0/day, sigma = sqrt(10 x 1^2 / 9) = 1.0541
--   production lead L = 4 days, unit cost $2.00, carrying 18% -> H = $0.36/yr
--     ROP = 1 x 4 + 1.65 x 1.0541 x sqrt(4)        = 4 + 3.48 = 7.48
--     EOQ = sqrt(2 x 365 x $5 setup / 0.36)          = 100.69
--     order-up-to = 1 x 18 + 1.65 x 1.0541 x sqrt(18) = 18 + 7.38 = 25.38
--   on hand 100 - 10 sold = 90 -> above the reorder point.
--   Supplier PCTEST (quoted 3 days, Net 30), two POs of 10 x $1:
--     PO1 sent day -20, expected -17, received in full day -17 (3 days, on time)
--     PO2 sent day -10, expected -7, 8 received day -5 (5 days, late), closed short
--     on-time 1/2 = 50%, fill (value) 18/20 = 90%, actual lead avg 4 vs quoted 3,
--     lead accuracy 1 - avg(|3-3|, |5-3|)/3 = 0.6667, price stability 100%
--     overall = 40x0.5 + 30x0.9 + 20x0.6667 + 10x1 = 70.3 -> Watch
--     owed $18 (two Net 30 bills); after paying PO1's bill $8.
-- =============================================================================
begin;

do $$
declare
  v_cp uuid := (select id from locations where code = 'CAMPUS');
  v_pf uuid := (select id from locations where code = 'PRINT_FARM');
  v_today date := (now() at time zone 'America/Denver')::date;
  fg uuid; comp uuid; s uuid; po1 uuid; po2 uuid; rc1 uuid;
  r record;
  k int;
begin
  update settings set value = '10'   where key = 'demand_history_days';
  update settings set value = '1.65' where key = 'service_level_z';
  update settings set value = '14'   where key = 'review_interval_days';
  update settings set value = '0.18' where key = 'carrying_rate_annual';
  update settings set value = '5'    where key = 'production_setup_cost';

  -- ---------------------------------------------------------- ROP and EOQ
  insert into items (sku, barcode, name, item_type, category, uom, price, stocking_policy, lead_time_days)
  values ('PCTEST-FG', 'PCTEST-FG', 'Purchasing test product', 'finished', 'product', 'ea', 5, 'stock', 4)
  returning id into fg;
  perform receive_opening_inventory(fg, v_cp, 100, 2.00, ((v_today - 15)::timestamp + interval '9 hours') at time zone 'America/Denver');
  for k in 1 .. 5 loop
    perform pos_sale(jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 2)),
             'order_date', ((v_today - 2 * k)::timestamp + interval '12 hours') at time zone 'America/Denver'));
  end loop;

  select * into r from v_reorder_plan where item_id = fg;
  assert r.days_observed = 10 and r.total_usage = 10, format('10 days, 10 sold (%s, %s)', r.days_observed, r.total_usage);
  assert r.avg_daily = 1 and r.sd_daily = 1.0541, format('d %s sigma %s', r.avg_daily, r.sd_daily);
  assert r.lead_days = 4 and r.unit_cost = 2, format('lead %s cost %s', r.lead_days, r.unit_cost);
  assert r.reorder_point = 7.48, format('reorder point %s', r.reorder_point);
  assert r.eoq = 100.69 and r.eoq_units = 101, format('EOQ %s (%s)', r.eoq, r.eoq_units);
  assert r.order_up_to = 25.38, format('order-up-to %s', r.order_up_to);
  assert r.position = 90 and not r.below_reorder_point and r.suggested_qty is null, format('position %s', r.position);
  assert r.replenish_by = 'production' and r.order_cost = 5, 'made items use the setup cost';
  -- Days until the position reaches the reorder point: floor((90 - 7.48) / 1) = 82.
  assert r.order_by_date = v_today + 82, format('order-by %s', r.order_by_date);

  -- Below the reorder point: sell down to 6 -> suggest EOQ (101) since it is more than ROP - position.
  perform pos_sale(jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 84))));
  select * into r from v_reorder_plan where item_id = fg;
  assert r.position = 6 and r.below_reorder_point, format('below ROP at %s', r.position);
  assert r.suggested_units = 101 and r.order_by_date = v_today, format('suggest %s by %s', r.suggested_units, r.order_by_date);
  assert r.review_units = 20, format('periodic review orders up to 25.38: %s', r.review_units);

  -- A manual reorder point overrides the computed one.
  update items set reorder_point_manual = 3 where id = fg;
  assert (select reorder_point from v_reorder_plan where item_id = fg) = 3, 'manual reorder point wins';
  assert not (select below_reorder_point from v_reorder_plan where item_id = fg), 'position 6 is above a manual ROP of 3';

  -- ------------------------------------------------------------ scorecard
  insert into suppliers (name, quoted_lead_days, payment_terms, terms_days)
  values ('PCTEST Supplier', 3, 'Net 30', 30) returning id into s;
  insert into items (sku, barcode, name, item_type, category, uom, stocking_policy)
  values ('PCTEST-PART', 'PCTEST-PART', 'Purchasing test part', 'purchased', 'component', 'ea', 'not_sold')
  returning id into comp;
  insert into item_suppliers (item_id, supplier_id, purchase_uom, stock_per_purchase_unit, unit_cost, is_preferred)
  values (comp, s, 'ea', 1, 1.00, true);

  po1 := create_purchase_order(jsonb_build_object('supplier_id', s, 'order_date',
           ((v_today - 20)::timestamp + interval '9 hours') at time zone 'America/Denver',
           'lines', jsonb_build_array(jsonb_build_object('item_id', comp, 'qty', 10))));
  assert (select expected_date from purchase_orders where id = po1) = v_today - 17, 'expected = sent + quoted lead';
  rc1 := receive_purchase_order(po1, null, v_pf, ((v_today - 17)::timestamp + interval '10 hours') at time zone 'America/Denver');
  perform close_purchase_order(po1, ((v_today - 16)::timestamp + interval '10 hours') at time zone 'America/Denver');

  po2 := create_purchase_order(jsonb_build_object('supplier_id', s, 'order_date',
           ((v_today - 10)::timestamp + interval '9 hours') at time zone 'America/Denver',
           'lines', jsonb_build_array(jsonb_build_object('item_id', comp, 'qty', 10))));
  perform receive_purchase_order(po2,
    jsonb_build_array(jsonb_build_object('po_line_id', (select id from purchase_order_lines where po_id = po2), 'qty', 8)),
    v_pf, ((v_today - 5)::timestamp + interval '10 hours') at time zone 'America/Denver');
  assert (select status from purchase_orders where id = po2) = 'partial', 'partial receipt';
  perform close_purchase_order(po2, ((v_today - 3)::timestamp + interval '10 hours') at time zone 'America/Denver');

  select * into r from v_supplier_scorecard where supplier_id = s;
  assert r.pos_delivered = 2 and r.pos_on_time = 1 and r.on_time_rate = 0.5, format('on time %s/%s', r.pos_on_time, r.pos_delivered);
  assert r.fill_rate = 0.9, format('fill rate %s', r.fill_rate);
  assert r.avg_actual_lead_days = 4 and r.avg_quoted_lead_days = 3, format('lead %s vs %s', r.avg_actual_lead_days, r.avg_quoted_lead_days);
  assert r.lead_accuracy = 0.6667, format('lead accuracy %s', r.lead_accuracy);
  assert r.price_stability = 1, format('price stability %s', r.price_stability);
  assert r.overall_score = 70.3 and r.rating = 'Watch', format('overall %s %s', r.overall_score, r.rating);
  assert r.amount_owed = 18 and r.open_bills = 2 and r.amount_overdue = 0, format('owed %s', r.amount_owed);
  assert r.next_due_date = v_today - 17 + 30, format('next due %s', r.next_due_date);

  perform record_supplier_payment(rc1, null, now());
  select * into r from v_supplier_scorecard where supplier_id = s;
  assert r.amount_owed = 8 and r.payments = 1 and r.paid_on_time_rate = 1, format('after payment owed %s', r.amount_owed);

  -- ------------------------------------------------------ periodic review
  perform record_inventory_review('Test review', array[po1]);
  assert (select next_review_date from v_review_status) = v_today + 14, 'next review = today + 14 days';

  raise notice 'PURCHASING CHECKS PASSED';
end $$;

rollback;
