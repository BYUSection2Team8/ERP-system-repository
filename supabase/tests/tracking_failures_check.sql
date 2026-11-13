-- =============================================================================
-- tracking_failures_check.sql — Phase 10: order tracking + print failures.
-- Uses TEST items, a test customer and production dated March 2099.
-- ROLLED BACK at the end. Success = "TRACKING + FAILURE CHECKS PASSED".
--
-- Hand-checked:
--   * a pickup order for an item in stock -> stage "ready", 3 steps, token is 32 hex
--   * a pickup order for a made-to-order item -> "queued" while its production order
--     is planned, "printing" (0 < progress < 1) once issued, "ready" once completed,
--     "picked up" after fulfillment
--   * a shipped order after fulfillment -> "shipped", delivery = ship date + transit days
--   * Report failure on a 1-plate print: 1 scrapped with the reason, reprint created
--     for the same order and started (components on hand); filament wasted = 10 g
--   * analytics for March 2099: 2 completed orders (one failed, one good after the
--     reprint) -> 2 started, 1 scrapped, scrap rate 0.5, wasted 10 g
-- =============================================================================
begin;

do $$
declare
  v_cp uuid := (select id from locations where code = 'CAMPUS');
  v_pf uuid := (select id from locations where code = 'PRINT_FARM');
  v_ff uuid := (select id from locations where code = 'FULFILLMENT');
  v_cust uuid; fg uuid; mto uuid; fil uuid;
  so1 uuid; so2 uuid; so3 uuid; mo uuid; mo2 uuid;
  t jsonb; v_tok text; r record;
  v_scrap_before numeric;
  v_ok boolean;
begin
  insert into customers (name, contact_name, state, email) values ('Tracking Test Co', 'Avery Tester', 'UT', 'trk@example.com')
  returning id into v_cust;
  insert into items (sku, barcode, name, item_type, category, uom, price, stocking_policy)
  values ('TRK-FG', 'TRK-FG', 'Tracking stocked product', 'finished', 'product', 'ea', 10, 'stock') returning id into fg;
  perform receive_opening_inventory(fg, v_cp, 5, 2.00);
  perform receive_opening_inventory(fg, v_ff, 5, 2.00);
  insert into items (sku, barcode, name, item_type, category, uom) values ('TRK-FIL', 'TRK-FIL', 'Tracking test filament', 'purchased', 'filament', 'g')
  returning id into fil;
  perform receive_opening_inventory(fil, v_pf, 1000, 0.02);
  insert into items (sku, barcode, name, item_type, category, uom, price, stocking_policy, units_per_plate, print_minutes, lead_time_days, product_family, color)
  values ('TRK-MTO', 'TRK-MTO', 'Tracking made-to-order product', 'finished', 'product', 'ea', 25, 'make_to_order', 1, 120, 2, 'Tracking test', 'Teal')
  returning id into mto;
  insert into boms (parent_item_id, component_item_id, qty_per_plate) values (mto, fil, 10);

  -- ------------------------------------------------- in stock, pickup -> ready
  so1 := create_sales_order(jsonb_build_object('customer_id', v_cust, 'fulfillment_method', 'pickup', 'location_id', v_cp,
           'lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 2))));
  select tracking_token into v_tok from sales_orders where id = so1;
  assert v_tok ~ '^[0-9a-f]{32}$', format('token %s', v_tok);
  t := track_order(v_tok);
  assert t->>'stage' = 'ready' and jsonb_array_length(t->'steps') = 3 and t->>'first_name' = 'Avery'
     and t->>'order_no' = (select order_no from sales_orders where id = so1), format('ready: %s', t);
  assert t->'email' is null and t::text not like '%trk@example.com%', 'no email address on the public page';
  assert track_order('0123456789abcdef0123456789abcdef') is null, 'unknown token';
  assert track_order('x'' or 1=1 --') is null, 'malformed token';
  perform set_config('pp.trk_so1', so1::text, true);
  perform set_config('pp.trk_tok1', v_tok, true);

  -- ------------------------------------- made to order: queued -> printing -> ready
  so2 := create_sales_order(jsonb_build_object('customer_id', v_cust, 'fulfillment_method', 'pickup', 'location_id', v_cp,
           'lines', jsonb_build_array(jsonb_build_object('item_id', mto, 'qty', 1))));
  select tracking_token into v_tok from sales_orders where id = so2;
  t := track_order(v_tok);
  assert t->>'stage' = 'waiting' and t->>'ready_date' is not null, format('no production yet -> waiting: %s', t);
  assert t->'steps'->1->>'key' = 'printing' and (t->'steps'->1->>'done')::boolean = false, 'printing step shown, not done';
  mo := create_production_order(mto, 1, null, so2, null, null, null, '2099-03-02 09:00-07');
  t := track_order(v_tok);
  assert t->>'stage' = 'queued', format('queued: %s', t->>'stage');
  perform issue_production_order(mo, now() - interval '30 minutes');
  t := track_order(v_tok);
  assert t->>'stage' = 'printing' and (t->>'progress')::numeric > 0 and (t->>'progress')::numeric < 1
     and t->>'ready_at' is not null, format('printing: %s', t);

  -- ---------------------------------------- Report failure -> reprint (started)
  update production_orders set started_at = '2099-03-02 09:30-07' where id = mo;   -- keep it in March 2099 for the analytics
  v_scrap_before := coalesce((select sum(debit - credit) from ledger where account_code = '5300'), 0);
  begin
    perform report_print_failure(mo, 'NOT_A_REASON', null, '2099-03-02 11:00-07');
    v_ok := false;
  exception when others then v_ok := sqlerrm like '%scrap reason%';
  end;
  assert v_ok, 'a reason is required';
  mo2 := report_print_failure(mo, 'SCRAP_WARPING', null, '2099-03-02 11:00-07');
  select * into r from production_orders where id = mo;
  assert r.status = 'completed' and r.qty_good = 0 and r.qty_scrap = 1 and r.scrap_reason = 'SCRAP_WARPING', 'failed print scrapped';
  select * into r from production_orders where id = mo2;
  assert r.status = 'in_progress' and r.so_id = so2 and r.qty_planned = 1, format('reprint started for the same order: %s', r.status);
  assert coalesce((select sum(debit - credit) from ledger where account_code = '5300'), 0) > v_scrap_before, 'scrap cost on the P&L';
  assert (select sum(qty) from inventory_txn where item_id = fil) = 1000 - 20, 'filament for both prints issued';
  t := track_order(v_tok);
  assert t->>'stage' = 'printing', 'tracking follows the reprint';

  perform complete_production_order(mo2, 1, 0, null, '2099-03-03 10:00-07');
  -- The good unit went to Fulfillment; the order picks up at Campus.
  perform transfer_inventory(v_ff, v_cp, jsonb_build_array(jsonb_build_object('item_id', mto, 'qty', 1)));
  t := track_order(v_tok);
  assert t->>'stage' = 'ready' and (t->'steps'->1->>'done')::boolean, format('ready after printing: %s', t->>'stage');
  perform fulfill_sales_order(so2);
  t := track_order(v_tok);
  assert t->>'stage' = 'picked_up' and (t->'steps'->3->>'done')::boolean, format('picked up: %s', t->>'stage');

  -- ------------------------------------------------------------ shipped order
  so3 := create_sales_order(jsonb_build_object('customer_id', v_cust, 'fulfillment_method', 'ship', 'ship_state', 'UT',
           'lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 1))));
  t := track_order((select tracking_token from sales_orders where id = so3));
  assert t->>'stage' = 'packing' and t->>'est_delivery_date' is not null, format('packing: %s', t->>'stage');
  perform fulfill_sales_order(so3);
  t := track_order((select tracking_token from sales_orders where id = so3));
  assert t->>'stage' = 'shipped'
     and (t->>'est_delivery_date')::date = (now() at time zone setting_text('time_zone'))::date + setting_num('transit_days_estimate')::int,
    format('shipped: %s', t);

  -- ---------------------------------------------------------------- analytics
  select * into r from print_failure_analytics('2099-03-01', '2099-03-31') where dimension = 'total';
  assert r.orders = 2 and r.failed_orders = 1 and r.units_started = 2 and r.units_scrapped = 1 and r.scrap_rate = 0.5
     and r.wasted_grams = 10, format('total: %s', row_to_json(r));
  select * into r from print_failure_analytics('2099-03-01', '2099-03-31') where dimension = 'reason';
  assert r.key = 'SCRAP_WARPING' and r.units_scrapped = 1 and r.scrap_rate = 0.5, format('reason: %s', row_to_json(r));
  assert (select units_scrapped from print_failure_analytics('2099-03-01', '2099-03-31') where dimension = 'color' and key = 'Teal') = 1, 'by color';
  assert (select count(*) from print_failure_analytics('2099-03-01', '2099-03-31') where dimension = 'week') = 1, 'one week';

  -- ------------------------------------------------------------- email log
  perform log_tracking_email(so1, 'Avery@Example.com', 'sent');
  assert (select status || ' ' || to_email from email_log where so_id = so1) = 'sent avery@example.com', 'email logged';
  begin
    perform log_tracking_email(so1, 'not-an-email', 'sent');
    v_ok := false;
  exception when others then v_ok := sqlerrm like '%valid email%';
  end;
  assert v_ok, 'bad address refused';
end $$;

-- ------------------------------------------------------- tracking without a login
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$
declare v_ok boolean := false;
begin
  assert track_order(current_setting('pp.trk_tok1'))->>'stage' = 'ready', 'anonymous visitor can track with the link';
  begin
    perform log_tracking_email(current_setting('pp.trk_so1')::uuid, 'a@b.co', 'sent');
  exception when insufficient_privilege then v_ok := true;
  end;
  assert v_ok, 'anonymous visitors cannot log emails';
  v_ok := false;
  begin
    perform 1 from email_log;
  exception when insufficient_privilege then v_ok := true;
  end;
  assert v_ok, 'anonymous visitors cannot read the email log';
end $$;

reset role;
do $$ begin raise notice 'TRACKING + FAILURE CHECKS PASSED'; end $$;
rollback;
