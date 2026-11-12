-- =============================================================================
-- smoke_core.sql — end-to-end check of every Phase 1 business function.
--
-- Safe to run in Supabase SQL Editor: everything happens inside a transaction
-- that is ROLLED BACK at the end, so no test data is left behind (order-number
-- sequences do advance, which is harmless).
-- Success = the message "ALL PHASE 1 CHECKS PASSED". Any failed check stops
-- with an error naming the check. GitHub Actions runs this on every push.
--
-- Numbers checked by hand:
--   Filament: 2 spools x $14.99 / 1970 g          = $0.015218/g
--   Component: 100 @ $0.50 + 100 @ $0.80          = $0.65 weighted average
--   Machine rate: 700/5000 + 0.15*0.11 + 0.05     = $0.2065/hr
--   MO for 10 TEST-FG (2/plate -> 5 plates):
--     material 100 g * 0.015218 + 10 * 0.65       = $8.0218
--     machine 5 plates * 1 h * 0.2065             = $1.0325
--     labor 5 plates * (1+1+3) min / 60 * $20     = $8.3333
--     total $17.3876 / 10 started                 = $1.73876 per unit
--     9 good -> inventory $15.65, 1 scrap -> $1.74
--   POS 2 x $10, BYU 10%: 20 - 2.00 + tax(18 * 7.45% = 1.34) = $19.34
--   Ship 1 x $20 in UT: 20 + 5.99 shipping + tax 1.49           = $27.48
--   Changed-mind refund: 20 + 1.49 tax - 2.00 restocking fee     = $19.49
-- =============================================================================
begin;

create function pg_temp.expect_error(p_sql text, p_like text) returns void
language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm ilike p_like then return; end if;
    raise exception 'Expected an error like "%" but got: %', p_like, sqlerrm;
  end;
  raise exception 'Expected an error like "%" but it succeeded: %', p_like, p_sql;
end;
$$;

do $$
declare
  v_pf    uuid := (select id from locations where code = 'PRINT_FARM');
  v_ff    uuid := (select id from locations where code = 'FULFILLMENT');
  v_cp    uuid := (select id from locations where code = 'CAMPUS');
  v_qa    uuid := (select id from locations where code = 'QA_HOLD');
  s1 uuid; s2 uuid; c_ut uuid; c_az uuid; c_biz uuid;
  fil uuid; comp uuid; fg uuid; mto uuid;
  po1 uuid; po2 uuid; po3 uuid; rc2 uuid; mo1 uuid; mo2 uuid;
  so1 uuid; so2 uuid; so3 uuid; so4 uuid; so5 uuid; so6 uuid;
  ret uuid; v_line uuid;
  so  sales_orders%rowtype;
  rt  returns%rowtype;
  mo  production_orders%rowtype;
  v_n numeric; v_m numeric;
  v_orders int;
begin
  -- ---------------------------------------------------------------- setup
  insert into suppliers (name, quoted_lead_days, payment_terms, terms_days)
    values ('TEST Supplier Net30', 3, 'Net 30', 30) returning id into s1;
  insert into suppliers (name, quoted_lead_days, payment_terms, terms_days)
    values ('TEST Supplier Prepaid', 2, 'Paid at purchase', 0) returning id into s2;
  insert into customers (name, state, segment) values ('TEST Utah Buyer', 'UT', 'gift_buyer') returning id into c_ut;
  insert into customers (name, state, segment) values ('TEST Arizona Buyer', 'AZ', 'gift_buyer') returning id into c_az;
  insert into customers (name, state, segment, terms_days) values ('TEST Business', 'UT', 'business', 30) returning id into c_biz;

  insert into items (sku, barcode, name, item_type, category, uom, stocking_policy)
    values ('TEST-FIL', 'TESTFIL', 'TEST filament', 'purchased', 'filament', 'g', 'not_sold') returning id into fil;
  insert into items (sku, barcode, name, item_type, category, uom, stocking_policy)
    values ('TEST-COMP', 'TESTCOMP', 'TEST component', 'purchased', 'component', 'ea', 'not_sold') returning id into comp;
  insert into items (sku, barcode, name, item_type, category, price, units_per_plate, print_minutes, assembly_minutes, stocking_policy)
    values ('TEST-FG', 'TESTFG', 'TEST stocked product', 'finished', 'product', 10, 2, 60, 3, 'stock') returning id into fg;
  insert into items (sku, barcode, name, item_type, category, price, units_per_plate, print_minutes, assembly_minutes, stocking_policy)
    values ('TEST-MTO', 'TESTMTO', 'TEST made-to-order product', 'finished', 'product', 20, 1, 120, 0, 'make_to_order') returning id into mto;

  insert into item_suppliers (item_id, supplier_id, purchase_uom, stock_per_purchase_unit, unit_cost, is_preferred)
    values (fil, s2, 'spool', 985, 14.99, true), (comp, s1, 'ea', 1, 0.50, true);
  insert into boms (parent_item_id, component_item_id, qty_per_plate)
    values (fg, fil, 20), (fg, comp, 2), (mto, fil, 50), (mto, comp, 1);

  -- ------------------------------------------------------ purchasing
  po1 := create_purchase_order(jsonb_build_object('supplier_id', s2,
           'lines', jsonb_build_array(jsonb_build_object('item_id', fil, 'qty', 2))));
  assert (select status from purchase_orders where id = po1) = 'sent', 'PO should be sent';
  assert (select expected_date from purchase_orders where id = po1) = _local_date(now()) + 2,
    'expected date = sent date + 2-day lead time';
  select id into v_line from purchase_order_lines where po_id = po1;
  perform receive_purchase_order(po1, jsonb_build_array(jsonb_build_object('po_line_id', v_line, 'qty', 1)));
  assert (select status from purchase_orders where id = po1) = 'partial', 'PO should be partial';
  assert (select qty_on_hand from v_availability where item_id = fil and location_id = v_pf) = 985,
    '1 spool = 985 g on hand';
  assert (select coalesce(sum(balance), 0) from v_ap_open where po_id = po1) = 0,
    'paid-at-purchase supplier has nothing owed';
  perform receive_purchase_order(po1);
  assert (select status from purchase_orders where id = po1) = 'received', 'PO should be received';
  perform close_purchase_order(po1);
  assert (select status from purchase_orders where id = po1) = 'closed', 'PO should be closed';
  assert item_unit_cost(fil) = 0.015218, format('filament avg cost %s', item_unit_cost(fil));

  po2 := create_purchase_order(jsonb_build_object('supplier_id', s1,
           'lines', jsonb_build_array(jsonb_build_object('item_id', comp, 'qty', 100))));
  po3 := create_purchase_order(jsonb_build_object('supplier_id', s1,
           'lines', jsonb_build_array(jsonb_build_object('item_id', comp, 'qty', 100, 'unit_cost', 0.80))));
  rc2 := receive_purchase_order(po2);
  select id into v_line from purchase_order_lines where po_id = po3;
  perform pg_temp.expect_error(format('select receive_purchase_order(%L, %L)', po3,
            jsonb_build_array(jsonb_build_object('po_line_id', v_line, 'qty', 150))), '%would exceed%');
  perform receive_purchase_order(po3);
  assert item_unit_cost(comp) = 0.65, format('component weighted avg %s', item_unit_cost(comp));
  assert (select sum(balance) from v_ap_open where supplier_id = s1) = 130, 'owe $130 on Net 30';
  assert (select due_date from v_ap_open where receipt_id = rc2) = _local_date(now()) + 30, 'due in 30 days';
  perform record_supplier_payment(rc2);
  assert (select sum(balance) from v_ap_open where supplier_id = s1) = 80, 'owe $80 after paying $50';

  -- ------------------------------------------------------ production
  mo1 := create_production_order(fg, 10);
  select * into mo from production_orders where id = mo1;
  assert mo.plates = 5, '10 units at 2 per plate = 5 plates';
  assert (select qty_required from production_order_components where mo_id = mo1 and item_id = fil) = 100, '100 g filament';
  perform issue_production_order(mo1);
  select * into mo from production_orders where id = mo1;
  assert mo.status = 'in_progress' and mo.qty_started = 10, 'issued, 10 started';
  assert mo.material_cost = 8.0218, format('material cost %s', mo.material_cost);
  assert (select qty_on_hand from v_availability where item_id = comp and location_id = v_pf) = 190, 'components consumed';
  perform pg_temp.expect_error(format('select complete_production_order(%L, 9, 0)', mo1), '%must equal%');
  perform pg_temp.expect_error(format('select complete_production_order(%L, 9, 1)', mo1), '%scrap reason%');
  perform complete_production_order(mo1, 9, 1, 'SCRAP_WARPING');
  select * into mo from production_orders where id = mo1;
  assert mo.status = 'completed', 'MO completed';
  assert mo.machine_cost = 1.0325 and mo.labor_cost = 8.3333, format('machine %s labor %s', mo.machine_cost, mo.labor_cost);
  assert mo.unit_cost = 1.738760, format('rolled-up unit cost %s', mo.unit_cost);
  assert (select qty_on_hand from v_availability where item_id = fg and location_id = v_ff) = 9, '9 good units received';
  assert (select sum(debit) from ledger where source_id = mo1 and account_code = '5300') = 1.74, 'scrap cost $1.74';
  assert (select sum(debit) from ledger where source_id = mo1 and account_code = '1200') = 15.65, 'FG inventory $15.65';

  -- ------------------------------------------------------ transfer
  perform transfer_inventory(v_ff, v_cp, jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 4)), 'stock the counter');
  assert (select qty_on_hand from v_availability where item_id = fg and location_id = v_cp) = 4, 'campus has 4';
  assert (select qty_on_hand from v_availability where item_id = fg and location_id = v_ff) = 5, 'fulfillment has 5';
  perform pg_temp.expect_error(format('select transfer_inventory(%L, %L, %L)', v_ff, v_cp,
            jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 50))), 'Not enough%');

  -- ------------------------------------------------------ POS
  so1 := pos_sale(jsonb_build_object('discount_type', 'byu', 'payment_method', 'cash',
           'lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 2))));
  select * into so from sales_orders where id = so1;
  assert so.status = 'closed', 'POS sale closed';
  assert so.subtotal = 20 and so.discount_amount = 2 and so.tax_amount = 1.34 and so.total = 19.34,
    format('POS totals %s/%s/%s/%s', so.subtotal, so.discount_amount, so.tax_amount, so.total);
  assert (select qty_on_hand from v_availability where item_id = fg and location_id = v_cp) = 2, 'campus down to 2';
  assert (select sum(debit) from ledger where source_id = so1 and account_code = '5000') = 3.48, 'COGS 2 x 1.73876';
  assert (select sum(credit) from ledger where source_id = so1 and account_code = '4000') = 20, 'gross sales $20';

  select count(*) into v_orders from sales_orders;
  perform pg_temp.expect_error(format('select pos_sale(%L)', jsonb_build_object(
            'lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 5)))), 'Not enough%');
  assert (select count(*) from sales_orders) = v_orders, 'failed sale left nothing behind';
  perform pg_temp.expect_error(format('select pos_sale(%L)', jsonb_build_object(
            'discount_type', 'manual', 'discount_pct', 0.2,
            'lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 1)))), '%reason code%');

  -- ------------------------------------------------------ sales order + backorder + made to order
  so2 := create_sales_order(jsonb_build_object('customer_id', c_ut,
           'lines', jsonb_build_array(jsonb_build_object('item_id', mto, 'qty', 1))));
  select * into so from sales_orders where id = so2;
  assert so.status = 'placed' and so.location_id = v_ff, 'placed, ships from fulfillment';
  assert so.shipping_amount = 5.99 and so.tax_amount = 1.49 and so.total = 27.48,
    format('SO totals ship %s tax %s total %s', so.shipping_amount, so.tax_amount, so.total);
  assert (select qty_backordered from v_backorders where so_id = so2) = 1, 'backordered 1';
  assert (select est_available_date from v_backorders where so_id = so2) is not null, 'has an estimated date';
  perform pg_temp.expect_error(format('select fulfill_sales_order(%L)', so2), 'Not enough%');
  assert (select status from sales_orders where id = so2) = 'placed', 'still placed after failed fulfill';

  mo2 := create_production_order(mto, 1, current_date + 2, so2);
  assert (select est_available_date from v_backorders where so_id = so2) = current_date + 2, 'est date = MO due date';
  perform issue_production_order(mo2);
  perform complete_production_order(mo2, 1);
  assert (select unit_cost from production_orders where id = mo2) between 2.4 and 2.6, 'MTO cost about $2.49';
  perform fulfill_sales_order(so2);
  assert (select status from sales_orders where id = so2) = 'fulfilled', 'SO fulfilled';
  assert not exists (select 1 from v_backorders where so_id = so2), 'no longer backordered';
  assert (select sum(debit) from ledger where source_id = so2 and account_code = '5100') = 0.70, 'packaging expensed';
  assert (select sum(credit) from ledger where source_id = so2 and account_code = '4200') = 5.99, 'shipping revenue';

  -- ------------------------------------------------------ return: changed mind, restocking fee
  select id into v_line from sales_order_lines where so_id = so2;
  ret := process_return(jsonb_build_object('so_id', so2, 'lines', jsonb_build_array(
           jsonb_build_object('so_line_id', v_line, 'qty', 1, 'reason_code', 'RET_CHANGED_MIND'))));
  select * into rt from returns where id = ret;
  assert rt.restocking_fee = 2 and rt.tax_credit = 1.49 and rt.refund_amount = 19.49,
    format('changed-mind refund fee %s tax %s refund %s', rt.restocking_fee, rt.tax_credit, rt.refund_amount);
  assert (select qty_on_hand from v_availability where item_id = mto and location_id = v_ff) = 1, 'MTO back in stock';
  assert (select sum(credit) from ledger where source_id = ret and account_code = '5000')
       = (select round(unit_cost, 2) from production_orders where id = mo2), 'COGS reversed at original cost';
  perform pg_temp.expect_error(format('select process_return(%L)', jsonb_build_object('so_id', so2,
            'lines', jsonb_build_array(jsonb_build_object('so_line_id', v_line, 'qty', 1, 'reason_code', 'RET_CHANGED_MIND')))),
          '%can still be returned%');

  -- ------------------------------------------------------ out-of-state tax, cancel
  so3 := create_sales_order(jsonb_build_object('customer_id', c_az,
           'lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 1))));
  assert (select tax_amount from sales_orders where id = so3) = 0, 'no tax outside Utah';
  perform cancel_sales_order(so3, 'customer cancelled');
  assert (select status from sales_orders where id = so3) = 'cancelled', 'cancelled';
  perform pg_temp.expect_error(format('select fulfill_sales_order(%L)', so3), '%only placed%');

  -- ------------------------------------------------------ return: quality failure -> QA Hold
  so4 := pos_sale(jsonb_build_object('location_code', 'FULFILLMENT',
           'lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 1))));
  select id into v_line from sales_order_lines where so_id = so4;
  ret := process_return(jsonb_build_object('so_id', so4, 'lines', jsonb_build_array(
           jsonb_build_object('so_line_id', v_line, 'qty', 1, 'reason_code', 'RET_QUALITY_DEFECT'))));
  select * into rt from returns where id = ret;
  assert rt.restocking_fee = 0 and rt.refund_amount = 10.75, format('quality refund %s', rt.refund_amount);
  assert (select qty_on_hand from v_availability where item_id = fg and location_id = v_qa) = 1, 'defect sits in QA Hold';
  assert (select disposition from return_lines where return_id = ret) = 'qa_hold', 'disposition qa_hold';

  -- ------------------------------------------------------ exchange
  so5 := pos_sale(jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 1))));
  select id into v_line from sales_order_lines where so_id = so5;
  ret := process_return(jsonb_build_object('so_id', so5,
           'lines', jsonb_build_array(jsonb_build_object('so_line_id', v_line, 'qty', 1, 'reason_code', 'RET_WRONG_COLOR')),
           'exchange_lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 1))));
  select * into rt from returns where id = ret;
  assert rt.return_type = 'exchange' and rt.refund_amount = 0, format('even exchange refund %s', rt.refund_amount);
  assert (select status from sales_orders where id = rt.exchange_so_id) = 'fulfilled', 'exchange order fulfilled';
  assert (select qty_on_hand from v_availability where item_id = fg and location_id = v_cp) = 1, 'campus: 2 - 1 + 1 - 1 = 1';

  -- ------------------------------------------------------ adjustments / cycle count
  perform count_inventory(fg, v_ff, 3);
  assert (select qty_on_hand from v_availability where item_id = fg and location_id = v_ff) = 3, 'count set on hand to 3';
  assert (select balance from v_account_balances where code = '5200') > 0, 'realized loss recorded';
  perform pg_temp.expect_error(format('select adjust_inventory(%L, %L, -1, %L)', fg, v_ff, 'NOPE'), '%reason code%');
  perform adjust_inventory(fg, v_qa, -1, 'ADJ_QA_SCRAP', 'failed inspection');
  assert coalesce((select qty_on_hand from v_availability where item_id = fg and location_id = v_qa), 0) = 0, 'QA hold cleared';

  -- ------------------------------------------------------ on-account order: A/R
  so6 := create_sales_order(jsonb_build_object('customer_id', c_biz, 'fulfillment_method', 'pickup',
           'location_code', 'CAMPUS', 'lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 1))));
  select * into so from sales_orders where id = so6;
  assert so.payment_method = 'account' and so.shipping_amount = 0 and so.total = 10.75, 'business order on account';
  perform fulfill_sales_order(so6);
  assert (select balance from v_account_balances where code = '1100') = 10.75, 'A/R open $10.75';
  perform close_sales_order(so6);
  assert (select balance from v_account_balances where code = '1100') = 0, 'A/R paid on close';

  -- ------------------------------------------------------ return window
  perform pg_temp.expect_error(format('select process_return(%L)', jsonb_build_object('so_id', so1,
            'returned_at', now() + interval '31 days',
            'lines', jsonb_build_array(jsonb_build_object('so_line_id',
              (select id from sales_order_lines where so_id = so1), 'qty', 1, 'reason_code', 'RET_CHANGED_MIND')))),
          '%return window%');

  -- ------------------------------------------------------ books balance
  assert not exists (select journal_id from ledger group by journal_id having sum(debit) <> sum(credit)),
    'every journal balances';
  assert (select sum(debit) - sum(credit) from ledger) = 0, 'ledger balances';
  assert (select balance from v_account_balances where code = '1250') = 0, 'no WIP left';
  select balance into v_n from v_account_balances where code = '1200';
  select sum(ext_cost) into v_m from inventory_txn;
  -- Ledger rounds each journal to cents: allow half a cent per journal.
  assert abs(v_n - v_m) <= 0.005 * (select count(distinct journal_id) from ledger where account_code = '1200') + 0.01,
    format('ledger inventory %s vs stock records %s', v_n, v_m);
  assert not exists (select 1 from v_stock_on_hand where qty_on_hand < 0), 'no negative stock';
  assert (select count(*) from v_item_standard_cost where item_id in (fg, mto) and total_cost > 0) = 2, 'standard costs';
  assert (select count(*) from activity_log) >= 20, 'activity logged';
  assert exists (select 1 from profiles where id = '00000000-0000-0000-0000-00000000aaaa' and role = 'staff')
      or not exists (select 1 from auth.users where id = '00000000-0000-0000-0000-00000000aaaa'),
    'pre-existing user became staff';

  raise notice 'ALL PHASE 1 CHECKS PASSED';
end $$;

rollback;
