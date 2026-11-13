-- =============================================================================
-- reports_portal_check.sql — Phase 9: sales reports, top sellers, customer portal.
-- Uses TEST items and transactions dated February 2099 (so only they fall in the
-- report period) and test logins. ROLLED BACK at the end, so it passes on a live
-- database too. Success = "REPORTS + PORTAL CHECKS PASSED".
--
-- Numbers checked by hand (2099-02-02 is a Monday):
--   Feb 2  opening stock 10 x $4.00 at Campus
--   Feb 3  POS sale 3 x $10, no discount             gross 30, COGS 12
--   Feb 4  1 returned, "changed my mind"             returns 10, COGS -4
--   Feb 10 POS sale 2 x $10, BYU discount (b)         gross 20, discount D = round(20 b, 2), COGS 8
--   By day, Feb 1-14: 14 rows; Feb 3 = 1 order, 3 units, net 30, gross profit 18;
--     Feb 4 = 0 orders, net -10, COGS -4; Feb 10 = net 20 - D, gross profit 12 - D
--   By week: weeks of Jan 26, Feb 2, Feb 9; week of Feb 2 = net 20, COGS 8
--   Top sellers Feb: 5 units in 2 orders, revenue 30 + (20 - D) = 50 - D,
--     COGS 20, 1 unit returned worth $10
--   Portal: 5 on hand at Campus, another customer reserved 1 -> 4 available;
--     BYU student orders 2 -> BYU discount applied automatically, 2 left available
-- =============================================================================
begin;

-- Test portal logins. The customer row exists first, so the 009 trigger links it.
do $$
begin
  insert into customers (name, state, email, is_byu, segment)
  values ('Portal Test Student', 'UT', 'portal.student@example.com', true, 'student');
  insert into customers (name, state, email)
  values ('Portal Test Other', 'UT', 'portal.other@example.com');
end $$;
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000d1', 'portal.student@example.com'),
  ('00000000-0000-0000-0000-0000000000d2', 'portal.unlinked@example.com');

create temp table t_ids (k text primary key, id uuid);
grant all on t_ids to authenticated;

do $$
declare
  v_cp uuid := (select id from locations where code = 'CAMPUS');
  v_byu numeric := setting_num('byu_discount_pct');
  v_d numeric;
  fg uuid; so uuid; v_line uuid;
  r record;
  v_today date := (now() at time zone setting_text('time_zone'))::date;
begin
  -- ------------------------------------------------------------- reports
  insert into items (sku, barcode, name, item_type, category, uom, price, stocking_policy)
  values ('RPTTEST-FG', 'RPTTEST-FG', 'Reports test product', 'finished', 'product', 'ea', 10, 'stock')
  returning id into fg;
  perform receive_opening_inventory(fg, v_cp, 10, 4.00, '2099-02-02 09:00-07');
  so := pos_sale(jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 3)),
          'order_date', '2099-02-03 12:00-07'));
  select id into v_line from sales_order_lines where so_id = so;
  perform process_return(jsonb_build_object('so_id', so, 'returned_at', '2099-02-04 11:00-07',
          'lines', jsonb_build_array(jsonb_build_object('so_line_id', v_line, 'qty', 1, 'reason_code', 'RET_CHANGED_MIND'))));
  perform pos_sale(jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('item_id', fg, 'qty', 2)),
          'discount_type', 'byu', 'order_date', '2099-02-10 12:00-07'));
  v_d := round(20 * v_byu, 2);

  assert extract(isodow from date '2099-02-02') = 1, '2099-02-02 is a Monday';
  assert (select count(*) from sales_by_period('2099-02-01', '2099-02-14', 'day')) = 14, '14 daily rows';
  select * into r from sales_by_period('2099-02-01', '2099-02-14', 'day') where period_start = '2099-02-03';
  assert r.orders = 1 and r.units = 3 and r.gross_sales = 30 and r.net_sales = 30 and r.cogs = 12 and r.gross_profit = 18,
    format('Feb 3: %s', row_to_json(r));
  select * into r from sales_by_period('2099-02-01', '2099-02-14', 'day') where period_start = '2099-02-04';
  assert r.orders = 0 and r.returns = 10 and r.net_sales = -10 and r.cogs = -4, format('Feb 4: %s', row_to_json(r));
  select * into r from sales_by_period('2099-02-01', '2099-02-14', 'day') where period_start = '2099-02-10';
  assert r.orders = 1 and r.units = 2 and r.gross_sales = 20 and r.discounts = v_d and r.net_sales = 20 - v_d
     and r.cogs = 8 and r.gross_profit = 12 - v_d, format('Feb 10: %s (D = %s)', row_to_json(r), v_d);
  select * into r from sales_by_period('2099-02-01', '2099-02-01', 'day');
  assert r.orders = 0 and r.net_sales = 0, 'quiet day is a zero row';

  assert (select array_agg(period_start order by period_start) from sales_by_period('2099-02-01', '2099-02-14', 'week'))
         = array['2099-01-26','2099-02-02','2099-02-09']::date[], 'weeks start on Monday';
  select * into r from sales_by_period('2099-02-01', '2099-02-14', 'week') where period_start = '2099-02-02';
  assert r.orders = 1 and r.net_sales = 20 and r.cogs = 8, format('week of Feb 2: %s', row_to_json(r));
  assert (select sum(net_sales) from sales_by_period('2099-02-01', '2099-02-14', 'week'))
       = (select sum(net_sales) from sales_by_period('2099-02-01', '2099-02-14', 'day')), 'weeks add up to days';
  assert (select sum(net_sales) from sales_by_period('2099-02-01', '2099-02-28', 'day'))
       = (select amount from pl_report('2099-02-01', '2099-02-28') where label = 'Net sales'), 'agrees with the P&L';

  select * into r from top_sellers('2099-02-01', '2099-02-28') where item_id = fg;
  assert r.units_sold = 5 and r.orders = 2 and r.net_revenue = 50 - v_d and r.cogs = 20
     and r.gross_profit = 30 - v_d and r.units_returned = 1 and r.returned_value = 10,
    format('top seller row: %s', row_to_json(r));
  assert (select count(*) from top_sellers('2099-02-01', '2099-02-28')) = 1, 'only test sales in Feb 2099';
  assert (select count(*) from top_sellers('2099-02-11', '2099-02-28')) = 0, 'date range filters';

  -- ------------------------------------------------------ portal set-up
  assert (select p.customer_id from profiles p where p.id = '00000000-0000-0000-0000-0000000000d1')
       = (select id from customers where email = 'portal.student@example.com'), 'portal login linked to its customer';
  insert into t_ids values ('student', (select id from customers where email = 'portal.student@example.com'));
  insert into t_ids values ('other', (select id from customers where email = 'portal.other@example.com'));

  insert into items (sku, barcode, name, item_type, category, uom, price, stocking_policy)
  values ('PORTAL-FG', 'PORTAL-FG', 'Portal stocked product', 'finished', 'product', 'ea', 10, 'stock') returning id into fg;
  insert into t_ids values ('fg', fg);
  perform receive_opening_inventory(fg, v_cp, 5, 2.00);
  insert into items (sku, barcode, name, item_type, category, uom, price, stocking_policy, lead_time_days)
  values ('PORTAL-MTO', 'PORTAL-MTO', 'Portal made-to-order product', 'finished', 'product', 'ea', 20, 'make_to_order', 3)
  returning id into fg;
  insert into t_ids values ('mto', fg);
  insert into items (sku, barcode, name, item_type, category, uom, price, stocking_policy, season_start, season_end)
  values ('PORTAL-SEAS', 'PORTAL-SEAS', 'Portal out-of-season product', 'finished', 'product', 'ea', 5, 'seasonal',
          to_char(v_today + 10, 'MM-DD'), to_char(v_today + 11, 'MM-DD'))
  returning id into fg;
  insert into t_ids values ('seas', fg);
  insert into t_ids values ('comp', (select id from items where category = 'component' limit 1));
  insert into t_ids values ('campus', v_cp);
  insert into t_ids values ('qa', (select id from locations where code = 'QA_HOLD'));
  -- Another customer's order, placed by staff.
  insert into t_ids values ('other_so', create_sales_order(jsonb_build_object(
    'customer_id', (select id from t_ids where k = 'other'), 'fulfillment_method', 'pickup',
    'lines', jsonb_build_array(jsonb_build_object('item_id', (select id from t_ids where k = 'fg'), 'qty', 1)))));
  update live_signals set changed_at = '2000-01-01' where topic = 'stock';
end $$;

-- ------------------------------------------------------- as the portal customer
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);

do $$
declare
  ids jsonb := (select jsonb_object_agg(k, id) from t_ids);
  v_byu numeric := setting_num('byu_discount_pct');
  v_rate numeric := setting_num('sales_tax_rate');
  q jsonb; v_so uuid; v_so2 uuid; v_ok boolean;
  bad jsonb;
begin
  assert not is_staff(), 'portal user is a customer';
  -- Catalog: stocked item at Campus, 5 on hand - 1 reserved by the other order = 4.
  assert (select qty_available from portal_catalog() where item_id = (ids->>'fg')::uuid and location_code = 'CAMPUS') = 4,
    format('available at Campus: %s', (select qty_available from portal_catalog() where item_id = (ids->>'fg')::uuid and location_code = 'CAMPUS'));
  assert (select est_available_date from portal_catalog() where item_id = (ids->>'fg')::uuid and location_code = 'CAMPUS') is null,
    'in stock: no estimated date';
  assert (select qty_available from portal_catalog() where item_id = (ids->>'mto')::uuid and location_code = 'CAMPUS') = 0
     and (select est_available_date from portal_catalog() where item_id = (ids->>'mto')::uuid and location_code = 'CAMPUS') >= current_date,
    'made to order: zero available, with an estimated date';
  assert not exists (select 1 from portal_catalog() where item_id = (ids->>'seas')::uuid), 'out-of-season item hidden';
  assert not exists (select 1 from portal_catalog() where item_id = (ids->>'comp')::uuid), 'components not sold online';
  assert not exists (select 1 from portal_catalog() where location_code in ('QA_HOLD', 'PRINT_FARM')), 'only pickup locations';

  -- Quote: BYU student discount applies by itself; pickup is taxed, no shipping.
  q := portal_quote_order(jsonb_build_object('location_id', ids->>'campus',
         'lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'fg', 'qty', 2))));
  assert (q->>'subtotal')::numeric = 20 and q->>'discount_type' = 'byu'
     and (q->>'discount_amount')::numeric = round(20 * v_byu, 2)
     and (q->>'shipping_amount')::numeric = 0
     and (q->>'tax_amount')::numeric = round((20 - round(20 * v_byu, 2)) * v_rate, 2)
     and q->>'channel' = 'portal' and q->>'fulfillment_method' = 'pickup', format('portal quote %s', q);

  -- Place it. A spoofed customer_id is ignored: the order is the signed-in customer's.
  v_so := portal_place_order(jsonb_build_object('location_id', ids->>'campus', 'customer_id', ids->>'other',
            'discount_type', 'manual', 'discount_pct', 0.5,
            'lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'fg', 'qty', 2))));
  assert (select customer_id from sales_orders where id = v_so) = (ids->>'student')::uuid, 'order belongs to the signed-in customer';
  assert (select status || '/' || channel || '/' || fulfillment_method || '/' || discount_type from sales_orders where id = v_so)
       = 'placed/portal/pickup/byu', 'placed, portal, pickup, BYU discount (manual discount ignored)';
  assert (select total from sales_orders where id = v_so) = (q->>'total')::numeric, 'saved total = quote';
  assert (select count(*) from sales_orders) = 1, 'customer sees only their own order';
  assert (select qty_available from portal_catalog() where item_id = (ids->>'fg')::uuid and location_code = 'CAMPUS') = 2,
    'reserved stock drops the available count';
  assert (select changed_at from live_signals where topic = 'stock') > '2000-01-02', 'live signal bumped';

  -- Made-to-order line waits as a backorder with an estimated date.
  v_so2 := portal_place_order(jsonb_build_object('location_id', ids->>'campus',
             'lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'mto', 'qty', 1))));
  assert exists (select 1 from portal_order_backorders() where so_id = v_so2 and est_available_date is not null),
    'backorder with an estimated date';
  assert not exists (select 1 from portal_order_backorders() where so_id = (ids->>'other_so')::uuid), 'no one else''s backorders';

  -- Unexpected input gets a plain-English refusal.
  for bad in select * from jsonb_array_elements(jsonb_build_array(
      jsonb_build_object('location_id', ids->>'campus', 'lines', '[]'::jsonb),
      jsonb_build_object('location_id', ids->>'qa', 'lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'fg', 'qty', 1))),
      jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'fg', 'qty', 1))),
      jsonb_build_object('location_id', ids->>'campus', 'lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'comp', 'qty', 1))),
      jsonb_build_object('location_id', ids->>'campus', 'lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'seas', 'qty', 1))),
      jsonb_build_object('location_id', ids->>'campus', 'lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'fg', 'qty', 0))),
      jsonb_build_object('location_id', ids->>'campus', 'lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'fg', 'qty', -2))),
      jsonb_build_object('location_id', ids->>'campus', 'lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'fg', 'qty', 1.5))),
      jsonb_build_object('location_id', ids->>'campus', 'lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'fg', 'qty', 'abc'))),
      jsonb_build_object('location_id', ids->>'campus', 'lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'fg', 'qty', 100000))),
      jsonb_build_object('location_id', ids->>'campus', 'lines', jsonb_build_array(jsonb_build_object('item_id', 'not-a-uuid', 'qty', 1))),
      jsonb_build_object('location_id', ids->>'campus', 'need_date', '2000-01-01', 'lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'fg', 'qty', 1)))
  )) loop
    v_ok := false;
    begin
      perform portal_place_order(bad);
    exception when others then
      v_ok := sqlerrm not like '%invalid input%' and sqlerrm not like '%syntax%';
      if not v_ok then raise notice 'technical error for %: %', bad, sqlerrm; end if;
    end;
    assert v_ok, format('refused with a plain message: %s', bad);
  end loop;
  assert (select count(*) from sales_orders) = 2, 'refused orders saved nothing';

  -- Cancel: own placed order yes, someone else's no.
  v_ok := false;
  begin
    perform portal_cancel_order((ids->>'other_so')::uuid);
  exception when others then v_ok := sqlerrm like '%not on your account%';
  end;
  assert v_ok, 'cannot cancel another customer''s order';
  perform portal_cancel_order(v_so);
  assert (select status from sales_orders where id = v_so) = 'cancelled', 'own order cancelled';
  v_ok := false;
  begin
    perform portal_cancel_order(v_so);
  exception when others then v_ok := true;
  end;
  assert v_ok, 'cannot cancel twice';

  -- Still no staff powers.
  v_ok := false;
  begin
    perform create_sales_order(jsonb_build_object('customer_id', ids->>'student', 'fulfillment_method', 'pickup',
              'lines', jsonb_build_array(jsonb_build_object('item_id', ids->>'fg', 'qty', 1))));
  exception when insufficient_privilege then v_ok := true;
  end;
  assert v_ok, 'customer cannot use the staff order function';
  assert (select count(*) from inventory_txn) = 0, 'customer still cannot read stock movements';
end $$;

-- ------------------------------------------------------- login with no customer record
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000d2","role":"authenticated"}', true);
do $$
declare v_ok boolean := false;
begin
  begin
    perform portal_place_order(jsonb_build_object('location_id', (select id from t_ids where k = 'campus'),
      'lines', jsonb_build_array(jsonb_build_object('item_id', (select id from t_ids where k = 'fg'), 'qty', 1))));
  exception when others then v_ok := sqlerrm like '%not linked%';
  end;
  assert v_ok, 'unlinked login is told to contact us';
end $$;

-- ------------------------------------------------------- not signed in
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$
declare v_ok boolean := false;
begin
  begin
    perform 1 from portal_catalog();
  exception when insufficient_privilege then v_ok := true;
  end;
  assert v_ok, 'anonymous visitors cannot read the catalog';
end $$;

reset role;
do $$ begin raise notice 'REPORTS + PORTAL CHECKS PASSED'; end $$;
rollback;
