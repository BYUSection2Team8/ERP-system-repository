-- =============================================================================
-- rls_check.sql — checks who can see and do what (row-level security).
-- Pretends to be a customer, a staff user and an anonymous visitor.
-- Runs inside a transaction that is rolled back. GitHub Actions runs it after
-- smoke_core.sql. Success = "ALL RLS CHECKS PASSED".
-- =============================================================================
begin;

-- ---------------------------------------------------------- data (as owner)
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000c1', 'customer.one@example.com'),
  ('00000000-0000-0000-0000-0000000000c2', 'customer.two@example.com'),
  ('00000000-0000-0000-0000-0000000000e1', 'new.staff@example.com');

do $$
declare
  v_c1 uuid; v_c2 uuid; v_prod uuid; v_comp uuid;
begin
  assert (select count(*) from profiles
           where id in ('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000c2',
                        '00000000-0000-0000-0000-0000000000e1') and role = 'customer') = 3,
    'new sign-ups always start as customers';
  update profiles set role = 'staff' where id = '00000000-0000-0000-0000-0000000000e1';

  insert into customers (name, state, email) values ('RLS Customer One', 'UT', 'customer.one@example.com') returning id into v_c1;
  insert into customers (name, state, email) values ('RLS Customer Two', 'UT', 'customer.two@example.com') returning id into v_c2;
  update profiles set customer_id = v_c1 where id = '00000000-0000-0000-0000-0000000000c1';
  update profiles set customer_id = v_c2 where id = '00000000-0000-0000-0000-0000000000c2';

  insert into items (sku, barcode, name, item_type, category, price, stocking_policy)
    values ('RLS-PROD', 'RLSPROD', 'RLS product', 'finished', 'product', 5, 'stock') returning id into v_prod;
  insert into items (sku, barcode, name, item_type, category, stocking_policy)
    values ('RLS-COMP', 'RLSCOMP', 'RLS component', 'purchased', 'component', 'not_sold') returning id into v_comp;
  perform receive_opening_inventory(v_prod, (select id from locations where code = 'CAMPUS'), 5, 1.00);

  perform create_sales_order(jsonb_build_object('customer_id', v_c1, 'fulfillment_method', 'pickup',
            'lines', jsonb_build_array(jsonb_build_object('item_id', v_prod, 'qty', 1))));
  perform create_sales_order(jsonb_build_object('customer_id', v_c2, 'fulfillment_method', 'pickup',
            'lines', jsonb_build_array(jsonb_build_object('item_id', v_prod, 'qty', 2))));
end $$;

-- ---------------------------------------------------------- as a customer
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}', true);

do $$
declare v_ok boolean;
begin
  assert not public.is_staff(), 'customer is not staff';
  assert (select count(*) from sales_orders) = 1, 'customer sees only their own order';
  assert (select count(*) from sales_order_lines) = 1, 'customer sees only their own order lines';
  assert (select count(*) from customers) = 1, 'customer sees only their own customer record';
  assert (select count(*) from inventory_txn) = 0, 'customer cannot read stock movements';
  assert (select count(*) from ledger) = 0, 'customer cannot read the ledger';
  assert (select count(*) from suppliers) = 0, 'customer cannot read suppliers';
  assert exists (select 1 from items where sku = 'RLS-PROD'), 'customer sees products';
  assert not exists (select 1 from items where sku = 'RLS-COMP'), 'customer does not see components';
  assert (select count(*) from settings) > 0, 'customer can read settings (tax rate etc.)';

  -- Cannot run staff business functions
  v_ok := false;
  begin
    perform pos_sale(jsonb_build_object('lines',
      jsonb_build_array(jsonb_build_object('item_id', (select id from items where sku = 'RLS-PROD'), 'qty', 1))));
  exception when insufficient_privilege then v_ok := true;
  end;
  assert v_ok, 'customer cannot make a POS sale';

  -- Cannot write master data or promote themselves
  v_ok := false;
  begin
    insert into items (sku, barcode, name, item_type, category) values ('HACK', 'HACK', 'x', 'finished', 'product');
  exception when insufficient_privilege then v_ok := true;
  end;
  assert v_ok, 'customer cannot insert items';

  update settings set value = '0' where key = 'sales_tax_rate';
  update profiles set role = 'staff' where id = auth.uid();
  assert not public.is_staff(), 'customer cannot promote themselves';

  -- Cannot write the ledger directly
  v_ok := false;
  begin
    insert into journals (source_type) values ('hack');
  exception when insufficient_privilege then v_ok := true;
  end;
  assert v_ok, 'customer cannot write journals';
end $$;

reset role;
do $$ begin
  assert (select value from settings where key = 'sales_tax_rate') <> '0', 'customer update of settings had no effect';
end $$;

-- ---------------------------------------------------------- as staff
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000e1","role":"authenticated"}', true);

do $$
begin
  assert public.is_staff(), 'promoted user is staff';
  assert (select count(*) from sales_orders) >= 2, 'staff sees all orders';
  assert (select count(*) from inventory_txn) > 0, 'staff sees stock movements';
  perform adjust_inventory((select id from items where sku = 'RLS-PROD'),
                           (select id from locations where code = 'CAMPUS'), -1, 'ADJ_DAMAGED');
  assert (select qty_on_hand from v_availability a join items i on i.id = a.item_id
           where i.sku = 'RLS-PROD' and a.location_id = (select id from locations where code = 'CAMPUS')) = 4,
    'staff adjustment worked';
  update settings set value = value where key = 'labor_rate';
  assert found, 'staff can edit settings';
end $$;

-- ---------------------------------------------------------- not signed in
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

do $$
declare v_ok boolean := false;
begin
  begin
    perform 1 from items limit 1;
  exception when insufficient_privilege then v_ok := true;
  end;
  assert v_ok, 'anonymous visitors cannot read items';
end $$;

reset role;
do $$ begin raise notice 'ALL RLS CHECKS PASSED'; end $$;
rollback;
