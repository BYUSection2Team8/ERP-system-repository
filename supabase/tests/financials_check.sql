-- =============================================================================
-- financials_check.sql — Phase 8: P&L, inventory turnover, valuation, return preview.
-- Uses a TEST item and transactions dated January 2099, so only they fall in
-- the report period and it passes on a live database. ROLLED BACK at the end.
-- Success = "FINANCIALS CHECKS PASSED".
--
-- Numbers checked by hand:
--   Jan 2:  opening stock 10 x $4.00 at Campus             Inventory +40
--   Jan 10: POS sale 3 x $10 (no discount)                 sales 30, COGS 12
--   Jan 12: 1 returned, "changed my mind" (stocked item,   returns 10, COGS -4, no fee,
--           so no restocking fee)                          refund 10 + tax on 10
--   Jan 15: 1 lost (adjustment)                            realized loss 4
--   P&L Jan 2099: gross 30, returns -10, net sales 20, total revenue 20,
--     COGS -8, gross profit 12, adjustments -4, net income 8
--   Turnover Jan 2099 (31 days), X = Inventory balance before 2099:
--     average daily balance = X + (40x30 - 12x22 + 4x20 - 4x17) / 31 = X + 948/31
--     turnover = 8 / average, ending balance = X + 28
-- =============================================================================
begin;

do $$
declare
  v_cp uuid := (select id from locations where code = 'CAMPUS');
  v_rate numeric := setting_num('sales_tax_rate');
  v_x numeric := coalesce((select sum(debit - credit) from ledger where account_code = '1200'), 0);
  fg uuid; so uuid; v_line uuid; ret uuid;
  q jsonb; p jsonb;
  r record;
  v_returns int;
  v_oh numeric;
begin
  insert into items (sku, barcode, name, item_type, category, uom, price, stocking_policy)
  values ('FINTEST-FG', 'FINTEST-FG', 'Financials test product', 'finished', 'product', 'ea', 10, 'stock')
  returning id into fg;
  perform receive_opening_inventory(fg, v_cp, 10, 4.00, '2099-01-02 09:00-07');
  so := pos_sale(jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 3)),
          'order_date', '2099-01-10 12:00-07'));
  select id into v_line from sales_order_lines where so_id = so;

  -- ------------------------------------------- return preview saves nothing
  p := jsonb_build_object('so_id', so, 'returned_at', '2099-01-12 11:00-07',
         'lines', jsonb_build_array(jsonb_build_object('so_line_id', v_line, 'qty', 1, 'reason_code', 'RET_CHANGED_MIND')));
  v_returns := (select count(*) from returns);
  v_oh := (select sum(qty) from inventory_txn where item_id = fg);
  q := quote_return(p);
  assert (q->>'merchandise_credit')::numeric = 10 and (q->>'restocking_fee')::numeric = 0,
    format('preview credit %s fee %s', q->>'merchandise_credit', q->>'restocking_fee');
  assert (q->>'tax_credit')::numeric = round(10 * v_rate, 2), format('preview tax %s', q->>'tax_credit');
  assert (q->>'refund_amount')::numeric = 10 + round(10 * v_rate, 2), format('preview refund %s', q->>'refund_amount');
  assert q->'lines'->0->>'disposition' = 'restock', 'changed mind goes back to stock';
  assert (select count(*) from returns) = v_returns, 'preview saved no return';
  assert (select sum(qty) from inventory_txn where item_id = fg) = v_oh, 'preview moved no stock';
  assert (select qty_returned from sales_order_lines where id = v_line) = 0, 'preview changed no order line';

  -- Quality reason previews to QA Hold; past the window is refused.
  q := quote_return(jsonb_set(p, '{lines,0,reason_code}', '"RET_QUALITY_DEFECT"'));
  assert q->'lines'->0->>'disposition' = 'qa_hold', 'quality failure goes to QA Hold';
  begin
    perform quote_return(jsonb_set(p, '{returned_at}', '"2099-03-01 11:00-07"'));
    raise exception 'expected the 30-day window error';
  exception when others then
    assert sqlerrm like '%return window%', format('window error: %s', sqlerrm);
  end;

  -- The real return matches the preview.
  ret := process_return(p);
  assert (select refund_amount from returns where id = ret) = 10 + round(10 * v_rate, 2), 'saved refund = preview';
  perform adjust_inventory(fg, v_cp, -1, 'ADJ_LOST', null, '2099-01-15 10:00-07');

  -- ------------------------------------------------------------------ P&L
  for r in select * from (values
      ('Gross sales', 30), ('Sales discounts', 0), ('Sales returns', -10), ('Net sales', 20),
      ('Shipping revenue', 0), ('Restocking fees', 0), ('Total revenue', 20),
      ('Cost of goods sold', -8), ('Packaging & fulfillment', 0), ('Gross profit', 12),
      ('Inventory adjustments (realized losses)', -4), ('Production scrap (cost of poor quality)', 0),
      ('Net income', 8)) as x(label, expected) loop
    assert (select amount from pl_report('2099-01-01', '2099-01-31') where label = r.label) = r.expected,
      format('P&L %s = %s (expected %s)', r.label,
             (select amount from pl_report('2099-01-01', '2099-01-31') where label = r.label), r.expected);
  end loop;
  assert (select count(*) from pl_report('2099-01-01', '2099-01-31')) = 13, '13 P&L lines';
  assert (select amount from pl_report('2099-01-11', '2099-01-31') where label = 'Gross sales') = 0, 'date range filters';

  -- ------------------------------------------------------------- turnover
  select * into r from inventory_turnover('2099-01-01', '2099-01-31');
  assert r.days = 31 and r.cogs = 8, format('turnover inputs: %s days, COGS %s', r.days, r.cogs);
  assert r.begin_inventory = round(v_x, 2) and r.end_inventory = round(v_x + 28, 2),
    format('begin %s end %s (X = %s)', r.begin_inventory, r.end_inventory, v_x);
  assert r.avg_inventory = round(v_x + 948 / 31.0, 2), format('average inventory %s', r.avg_inventory);
  assert r.turnover = round(8 / (v_x + 948 / 31.0), 2), format('turnover %s', r.turnover);

  -- ------------------------------------------------------------ valuation
  assert (select qty_on_hand from v_inventory_by_location where item_id = fg and location_id = v_cp) = 7,
    '10 - 3 + 1 - 1 = 7 at Campus';
  assert (select inventory_value from v_inventory_by_location where item_id = fg and location_id = v_cp) = 28, '7 x $4.00';
  assert abs((select sum(inventory_value) from v_inventory_by_location)
             - (select sum(inventory_value) from v_inventory_valuation)) < 1,
    'value by location adds up to the item valuation';

  raise notice 'FINANCIALS CHECKS PASSED';
end $$;

rollback;
