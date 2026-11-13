-- =============================================================================
-- shipping_zones_check.sql — zone x weight shipping (wow #6). ROLLED BACK.
-- Success = "SHIPPING ZONE CHECKS PASSED".
--   * flat mode (default): shipping = the flat fee, as before
--   * zone mode, 3 Dragons to AZ (zone 4): parcel = 3 x (filament g + 10) + box g;
--     shipping = rate for that weight in zone 4 + handling; quote = saved order
--   * zone 8, 4 oz rate = 4.75 x 1.63 to the nearest 5 cents = 7.75
--   * unknown state refused; pickups pay no shipping
--   * custom quote shipped in zone mode = saved custom order
-- =============================================================================
begin;

do $$
declare
  drg uuid := (select id from items where product_family = 'Dragon' and is_active order by sku limit 1);
  v_cust uuid; q jsonb; so uuid; v_w numeric; v_oz numeric; v_exp numeric; v_ok boolean; cq jsonb;
begin
  insert into customers (name, state) values ('Zone Test Customer', 'AZ') returning id into v_cust;
  q := quote_sales_order(jsonb_build_object('customer_id', v_cust, 'fulfillment_method', 'ship',
         'lines', jsonb_build_array(jsonb_build_object('item_id', drg, 'qty', 3))));
  assert (q->>'shipping_amount')::numeric = setting_num('flat_shipping_fee'), 'flat mode unchanged';

  update settings set value = 'zone' where key = 'shipping_mode';
  v_w := coalesce((select sum(case when c.uom = 'g' then b.qty_per_unit else b.qty_per_unit * 5 end)
                     from v_bom_per_unit b join items c on c.id = b.component_item_id where b.parent_item_id = drg), 0) + 10;
  v_oz := (3 * v_w + setting_num('box_weight_g')) / 28.3495;
  v_exp := (select rate from shipping_rates where zone = 4 and max_oz >= v_oz order by max_oz limit 1) + setting_num('shipping_handling_fee');
  q := quote_sales_order(jsonb_build_object('customer_id', v_cust, 'fulfillment_method', 'ship',
         'lines', jsonb_build_array(jsonb_build_object('item_id', drg, 'qty', 3))));
  assert (q->>'shipping_amount')::numeric = v_exp and (q->'shipping'->>'zone')::int = 4,
    format('zone 4 shipping %s, expected %s (%s oz)', q->>'shipping_amount', v_exp, round(v_oz, 1));
  assert (q->>'tax_amount')::numeric = 0, 'AZ: no Utah tax';
  so := create_sales_order(jsonb_build_object('customer_id', v_cust, 'fulfillment_method', 'ship',
          'lines', jsonb_build_array(jsonb_build_object('item_id', drg, 'qty', 3))));
  assert (select shipping_amount from sales_orders where id = so) = v_exp, 'saved order = quote';
  assert (shipping_quote('AZ', jsonb_build_array(jsonb_build_object('item_id', drg, 'qty', 3)))->>'total')::numeric = v_exp,
    'shipping estimator = order';
  assert (select rate from shipping_rates where zone = 8 and max_oz = 4) = 7.75, 'zone 8, 4 oz = 7.75';
  assert (select zone from shipping_zones where state = 'UT') = 2, 'Utah is zone 2';

  v_ok := false;
  begin
    perform quote_sales_order(jsonb_build_object('customer_id', v_cust, 'fulfillment_method', 'ship', 'ship_state', 'ZZ',
      'lines', jsonb_build_array(jsonb_build_object('item_id', drg, 'qty', 1))));
  exception when others then v_ok := sqlerrm like '%do not ship%';
  end;
  assert v_ok, 'unknown state refused';
  q := quote_sales_order(jsonb_build_object('customer_id', v_cust, 'fulfillment_method', 'pickup',
         'lines', jsonb_build_array(jsonb_build_object('item_id', drg, 'qty', 3))));
  assert (q->>'shipping_amount')::numeric = 0, 'pickup: no shipping';

  cq := quote_custom_print(jsonb_build_object('name', 'Zone test', 'print_hours', 1, 'grams', 40, 'color', 'Red', 'qty', 2,
          'fulfillment_method', 'ship', 'ship_state', 'AZ'));
  v_oz := (2 * (40 + 10) + setting_num('box_weight_g')) / 28.3495;
  assert (cq->>'shipping_amount')::numeric
       = (select rate from shipping_rates where zone = 4 and max_oz >= v_oz order by max_oz limit 1) + setting_num('shipping_handling_fee'),
    format('custom quote shipping %s', cq->>'shipping_amount');
  so := create_custom_print_order(jsonb_build_object('name', 'Zone test', 'print_hours', 1, 'grams', 40, 'color', 'Red', 'qty', 2,
          'fulfillment_method', 'ship', 'ship_state', 'AZ', 'customer_id', v_cust));
  assert (select total from sales_orders where id = so) = (cq->>'total')::numeric,
    format('custom order total %s = quote %s', (select total from sales_orders where id = so), cq->>'total');
end $$;

do $$ begin raise notice 'SHIPPING ZONE CHECKS PASSED'; end $$;
rollback;
