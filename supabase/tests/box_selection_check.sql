-- =============================================================================
-- box_selection_check.sql — Phase 10 (wow #6): automatic box selection.
-- ROLLED BACK at the end. Success = "BOX SELECTION CHECKS PASSED".
--
-- Boxes (inside): small 6x4x4 (96 in3), medium 9x7x5 (315), large 12x10x6 (720); fill limit 80%.
--   3 Dragons (4x2x1.5 = 12 in3 each)        -> 1 small box (36 <= 76.8);  packing 3 + 3 x 1 = 6 min
--   1 Temple (5x4x4 = 80 in3)                -> fits small by size but 80 > 76.8 -> 1 medium box
--   1 Airplane (10x9x3 = 270) + 2 Temples + 3 Dragons, largest first:
--     Airplane needs the large box (10 > 9); 270 + 80 + 80 + 3 x 12 = 466 <= 576 -> everything in 1 large box;
--     packing 3 + 2 + 2 x 2 + 3 x 1 = 12 min
-- =============================================================================
begin;

do $$
declare
  v_cust uuid;
  drg uuid := (select id from items where product_family = 'Dragon' and is_active order by sku limit 1);
  tmp uuid := (select id from items where product_family = 'Temple LED Tealight' and is_active order by sku limit 1);
  air uuid := (select id from items where product_family = 'Airplane' and is_active order by sku limit 1);
  so uuid; r jsonb;
begin
  insert into customers (name, state) values ('Box Test Customer', 'UT') returning id into v_cust;

  so := create_sales_order(jsonb_build_object('customer_id', v_cust, 'fulfillment_method', 'ship', 'ship_state', 'UT',
          'lines', jsonb_build_array(jsonb_build_object('item_id', drg, 'qty', 3))));
  r := pack_order(so);
  assert (r->>'box_count')::int = 1 and r->'boxes'->0->>'sku' = 'PKG-BOX-S' and (r->'boxes'->0->>'units')::int = 3, format('3 dragons: %s', r);
  assert (r->>'packing_minutes')::numeric = 6, format('packing minutes %s', r->>'packing_minutes');
  assert (r->'boxes'->0->>'fill')::numeric = round(36 / 96.0, 3), 'fill = 36 / 96';

  so := create_sales_order(jsonb_build_object('customer_id', v_cust, 'fulfillment_method', 'ship', 'ship_state', 'UT',
          'lines', jsonb_build_array(jsonb_build_object('item_id', tmp, 'qty', 1))));
  r := pack_order(so);
  assert (r->>'box_count')::int = 1 and r->'boxes'->0->>'sku' = 'PKG-BOX-M', format('temple goes in a medium box: %s', r->'boxes');

  so := create_sales_order(jsonb_build_object('customer_id', v_cust, 'fulfillment_method', 'ship', 'ship_state', 'UT',
          'lines', jsonb_build_array(jsonb_build_object('item_id', drg, 'qty', 3), jsonb_build_object('item_id', air, 'qty', 1),
                                     jsonb_build_object('item_id', tmp, 'qty', 2))));
  r := pack_order(so);
  assert (r->>'box_count')::int = 1 and r->'boxes'->0->>'sku' = 'PKG-BOX-L' and (r->'boxes'->0->>'units')::int = 6,
    format('mixed order: %s', r->'boxes');
  assert (r->>'packing_minutes')::numeric = 12, format('packing minutes %s', r->>'packing_minutes');
  assert (r->>'packaging_cost')::numeric = round((r->>'box_cost')::numeric + (r->>'tissue_cost')::numeric + (r->>'card_cost')::numeric, 2),
    'packaging cost adds up';

  -- 8 Temples: 640 in3 > 576 -> two boxes (a large with 7, then a medium for the last).
  so := create_sales_order(jsonb_build_object('customer_id', v_cust, 'fulfillment_method', 'ship', 'ship_state', 'UT',
          'lines', jsonb_build_array(jsonb_build_object('item_id', tmp, 'qty', 8))));
  r := pack_order(so);
  assert (r->>'box_count')::int = 2 and (r->>'units')::int = 8, format('8 temples: %s', r->'boxes');

  -- Counter sales have no box.
  so := create_sales_order(jsonb_build_object('customer_id', v_cust, 'fulfillment_method', 'counter',
          'lines', jsonb_build_array(jsonb_build_object('item_id', drg, 'qty', 1))));
  assert (pack_order(so)->>'counter')::boolean, 'counter sale: no box';
end $$;

do $$ begin raise notice 'BOX SELECTION CHECKS PASSED'; end $$;
rollback;
