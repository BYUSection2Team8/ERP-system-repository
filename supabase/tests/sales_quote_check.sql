-- =============================================================================
-- sales_quote_check.sql — Phase 4: the price preview the POS / New order
-- screens show (quote_sales_order) must equal what is saved.
-- Runs on the starter data, inside a transaction that is rolled back.
-- Success = "ALL SALES QUOTE CHECKS PASSED".
--
-- Numbers checked by hand (Keychain $4.99, Utah tax 7.45%, shipping $5.99):
--   POS 3 Keychains, BYU 10%:   14.97 - 1.50 = 13.47, tax 1.00      -> $14.47
--   Ship 2 Keychains to AZ:     9.98 + 5.99 shipping, no tax        -> $15.97
--   Business 25 Keychains:      124.75 - 18.71 = 106.04, tax 7.90   -> $113.94
-- =============================================================================
begin;

do $$
declare
  key_bw uuid := (select id from items where sku = 'KEY-BW');
  c_byu  uuid := (select id from customers where name = 'Ethan Caldwell');
  c_biz  uuid := (select id from customers where name = 'Summit Ridge Gifts');
  p      jsonb;
  q      jsonb;
  so     sales_orders%rowtype;
  v_id   uuid;
  v_n    bigint;
  ln     sales_order_lines%rowtype;
begin
  assert key_bw is not null and c_byu is not null and c_biz is not null, 'starter data present';

  -- POS: quote then sell; quote saves nothing.
  p := jsonb_build_object('channel', 'pos', 'fulfillment_method', 'counter', 'location_code', 'CAMPUS',
         'discount_type', 'byu', 'payment_method', 'cash',
         'lines', jsonb_build_array(jsonb_build_object('item_id', key_bw, 'qty', 3)));
  select count(*) into v_n from sales_orders;
  q := quote_sales_order(p);
  assert (select count(*) from sales_orders) = v_n, 'quote saved nothing';
  assert (q->>'subtotal')::numeric = 14.97 and (q->>'discount_amount')::numeric = 1.50
     and (q->>'tax_amount')::numeric = 1.00 and (q->>'total')::numeric = 14.47,
    format('POS quote %s', q);
  v_id := pos_sale(p - 'channel' - 'fulfillment_method');
  select * into so from sales_orders where id = v_id;
  assert so.status = 'closed' and so.total = (q->>'total')::numeric
     and so.tax_amount = (q->>'tax_amount')::numeric and so.discount_amount = (q->>'discount_amount')::numeric,
    format('POS saved %s vs quote %s', so.total, q->>'total');
  select * into ln from sales_order_lines where so_id = v_id;
  assert ln.net_unit_price = ((q->'lines'->0)->>'net_unit_price')::numeric and ln.unit_cost is not null,
    'line net price and cost';

  -- Shipped out of state: shipping, no tax.
  p := jsonb_build_object('customer_id', c_byu, 'ship_state', 'az',
         'lines', jsonb_build_array(jsonb_build_object('item_id', key_bw, 'qty', 2)));
  q := quote_sales_order(p);
  assert (q->>'shipping_amount')::numeric = 5.99 and (q->>'tax_amount')::numeric = 0
     and (q->>'total')::numeric = 15.97 and q->>'ship_state' = 'AZ', format('AZ quote %s', q);
  v_id := create_sales_order(p);
  select * into so from sales_orders where id = v_id;
  assert so.status = 'placed' and so.total = 15.97 and so.shipping_amount = 5.99 and so.tax_amount = 0,
    'AZ order saved like the quote';
  assert (q->>'is_byu')::boolean, 'quote says customer is BYU';

  -- Business bulk discount, on account (Net 30).
  p := jsonb_build_object('customer_id', c_biz, 'fulfillment_method', 'pickup', 'location_code', 'FULFILLMENT',
         'discount_type', 'business',
         'lines', jsonb_build_array(jsonb_build_object('item_id', key_bw, 'qty', 25)));
  q := quote_sales_order(p);
  assert (q->>'discount_amount')::numeric = 18.71 and (q->>'tax_amount')::numeric = 7.90
     and (q->>'total')::numeric = 113.94 and q->>'payment_method' = 'account', format('business quote %s', q);
  v_id := create_sales_order(p);
  assert (select total from sales_orders where id = v_id) = 113.94, 'business order saved like the quote';

  -- Status flow: placed -> fulfilled -> closed; A/R opened then paid.
  perform fulfill_sales_order(v_id);
  assert (select status from sales_orders where id = v_id) = 'fulfilled', 'fulfilled';
  assert exists (select 1 from ledger where source_id = v_id and account_code = '1100' and debit = 113.94), 'A/R debited';
  perform close_sales_order(v_id);
  assert (select status from sales_orders where id = v_id) = 'closed', 'closed';
  assert exists (select 1 from ledger where source_id = v_id and account_code = '1000' and debit = 113.94), 'paid on close';

  -- Same validation as saving: errors surface in the preview.
  begin
    perform quote_sales_order(jsonb_build_object('customer_id', c_byu, 'discount_type', 'business',
              'lines', jsonb_build_array(jsonb_build_object('item_id', key_bw, 'qty', 2))));
    raise exception 'business discount under 25 units should fail';
  exception when others then
    assert sqlerrm like 'The business discount needs at least 25 units.', sqlerrm;
  end;
  begin
    perform quote_sales_order(jsonb_build_object('lines', '[]'::jsonb));
    raise exception 'empty order should fail';
  exception when others then
    assert sqlerrm = 'An order needs at least one line.', sqlerrm;
  end;

  raise notice 'ALL SALES QUOTE CHECKS PASSED';
end $$;

rollback;
