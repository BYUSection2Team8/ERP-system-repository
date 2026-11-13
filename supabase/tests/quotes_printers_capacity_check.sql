-- =============================================================================
-- quotes_printers_capacity_check.sql — Phase 10 (wow #4, #5, #7).
-- ROLLED BACK at the end. Success = "QUOTES + PRINTERS + CAPACITY CHECKS PASSED".
--
-- Hand-checked:
--   * quote for 2 x (2 h print, 50 g blue, 10 min assembly), pickup:
--       filament 50 x cost/g, machine 2 x rate, labor (setup + cleanup + 10) / 60 x labor rate,
--       packaging = packaging per order / 2, allowance = base x f / (1 - f) with f = recent scrap rate,
--       unit price = max(minimum, round(unit cost x markup, 2)); total = 2 x price + Utah tax
--   * a tiny job (0.1 h, 1 g) is priced at the minimum
--   * the order creates a custom item with a 50 g BOM, a placed order and a planned
--     2-plate production order with 100 g of filament, linked to the order
--   * issuing it puts it on a printer; estimated finish = start + ceil(2/4) x 120 + 2 x 10 min
--   * capacity: 3 units of a 12 x 12 x 12 in item at Campus = 3.00 cu ft more;
--     985 g of filament at the Print Farm = 1 spool more on the rack
-- =============================================================================
begin;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000f1', 'quote.customer@example.com');

do $$
declare
  v_cp uuid := (select id from locations where code = 'CAMPUS');
  v_pf uuid := (select id from locations where code = 'PRINT_FARM');
  v_blue uuid := (select id from items where sku = 'FIL-PLA-BLUE');
  v_cust uuid; big uuid; fil uuid; so uuid; mo uuid; it uuid;
  q jsonb; p jsonb; r record;
  v_cg numeric; v_rm numeric; v_rl numeric; v_setup numeric; v_pack numeric; v_mk numeric; v_min numeric;
  v_f numeric; v_st numeric; v_sc numeric;
  c_fil numeric; c_mach numeric; c_lab numeric; c_pack numeric; c_allow numeric; v_price numeric;
  u0 numeric; s0 numeric;
  v_ok boolean;
  bad jsonb;
begin
  -- ------------------------------------------------------------- capacity
  u0 := (select used_cuft from v_location_utilization where code = 'CAMPUS');
  s0 := (select spools from v_location_utilization where code = 'PRINT_FARM');
  insert into items (sku, barcode, name, item_type, category, uom, price, stocking_policy, length_in, width_in, height_in)
  values ('CAPTEST-FG', 'CAPTEST-FG', 'Capacity test cube', 'finished', 'product', 'ea', 5, 'stock', 12, 12, 12) returning id into big;
  perform receive_opening_inventory(big, v_cp, 3, 1.00);
  assert (select used_cuft from v_location_utilization where code = 'CAMPUS') = u0 + 3,
    format('Campus used %s, was %s', (select used_cuft from v_location_utilization where code = 'CAMPUS'), u0);
  assert abs((select utilization from v_location_utilization where code = 'CAMPUS')
           - (u0 + 3) / (select capacity_cuft from locations where code = 'CAMPUS')) < 0.001, 'utilization = used / capacity';
  insert into items (sku, barcode, name, item_type, category, uom) values ('CAPTEST-FIL', 'CAPTEST-FIL', 'Capacity test filament', 'purchased', 'filament', 'g')
  returning id into fil;
  perform receive_opening_inventory(fil, v_pf, setting_num('spool_grams'), 0.015);
  assert (select spools from v_location_utilization where code = 'PRINT_FARM') = s0 + 1, 'one more spool on the rack';
  assert (select rack_spools from v_location_utilization where code = 'PRINT_FARM') = setting_num('filament_rack_spools'), 'rack size from settings';

  -- ---------------------------------------------------------------- quote
  perform receive_opening_inventory(v_blue, v_pf, 500, 0.0152);   -- enough blue to start the print below
  p := jsonb_build_object('name', 'Rocket lamp', 'print_hours', 2, 'grams', 50, 'color', 'blue',
         'assembly_minutes', 10, 'qty', 2, 'fulfillment_method', 'pickup');
  q := quote_custom_print(p);
  v_cg := item_unit_cost(v_blue); v_rm := machine_rate_per_hour(); v_rl := setting_num('labor_rate');
  v_setup := setting_num('setup_minutes_per_plate') + setting_num('cleanup_minutes_per_plate');
  v_pack := setting_num('packaging_cost_per_order'); v_mk := setting_num('quote_markup'); v_min := setting_num('quote_minimum_price');
  select coalesce(sum(qty_started), 0), coalesce(sum(qty_scrap), 0) into v_st, v_sc
    from production_orders where status = 'completed' and finished_at >= now() - make_interval(days => setting_num('quote_failure_window_days')::int);
  v_f := case when v_st > 0 then least(v_sc / v_st, 0.5) else 0 end;
  c_fil := round(50 * v_cg, 4); c_mach := round(2 * v_rm, 4); c_lab := round((v_setup + 10) / 60.0 * v_rl, 4);
  c_pack := round(v_pack / 2, 4); c_allow := round((c_fil + c_mach + c_lab) * v_f / (1 - v_f), 4);
  v_price := greatest(v_min, round((c_fil + c_mach + c_lab + c_pack + c_allow) * v_mk, 2));
  assert (q->'cost'->>'filament')::numeric = c_fil and (q->'cost'->>'machine')::numeric = c_mach
     and (q->'cost'->>'labor')::numeric = c_lab and (q->'cost'->>'packaging')::numeric = c_pack
     and (q->'cost'->>'failure_allowance')::numeric = c_allow, format('cost parts %s', q->'cost');
  assert (q->>'unit_price')::numeric = v_price, format('unit price %s, expected %s', q->>'unit_price', v_price);
  assert (q->>'total')::numeric = 2 * v_price + round(2 * v_price * setting_num('sales_tax_rate'), 2), format('total %s', q->>'total');
  assert (q->>'ready_date')::date >= (now() at time zone setting_text('time_zone'))::date, 'ready date not in the past';
  q := quote_custom_print(jsonb_build_object('name', 'Tiny', 'print_hours', 0.1, 'grams', 1, 'color', 'Red'));
  assert (q->>'unit_price')::numeric = v_min and (q->>'minimum_applied')::boolean, 'minimum price applies';
  q := quote_custom_print(p || jsonb_build_object('fulfillment_method', 'ship', 'ship_state', 'az'));
  assert (q->>'tax_amount')::numeric = 0 and (q->>'shipping_amount')::numeric = setting_num('flat_shipping_fee')
     and q->>'est_delivery_date' is not null, 'shipped out of state: shipping, no tax, delivery date';

  for bad in select * from jsonb_array_elements(jsonb_build_array(
      p || '{"name": ""}', p || '{"print_hours": 0}', p || '{"print_hours": 100}', p || '{"print_hours": "abc"}',
      p || '{"grams": -5}', p || '{"color": "Green"}', p || '{"qty": 51}', p || '{"qty": 1.5}',
      p || '{"assembly_minutes": "x"}', p || '{"fulfillment_method": "ship"}', p || '{"fulfillment_method": "drone"}')) loop
    v_ok := false;
    begin
      perform quote_custom_print(bad);
    exception when others then
      v_ok := sqlerrm not like '%invalid input%';
    end;
    assert v_ok, format('refused with a plain message: %s', bad);
  end loop;

  -- ------------------------------------------------- quote -> order (staff)
  insert into customers (name, state, email) values ('Quote Test Customer', 'UT', 'quote.customer@example.com') returning id into v_cust;
  update profiles set customer_id = v_cust where id = '00000000-0000-0000-0000-0000000000f1';
  so := create_custom_print_order(p || jsonb_build_object('customer_id', v_cust));
  select l.item_id into it from sales_order_lines l where l.so_id = so;
  assert (select is_custom and stocking_policy = 'make_to_order' and price = v_price from items where id = it), 'custom item at the quoted price';
  assert (select qty_per_plate from boms where parent_item_id = it and component_item_id = v_blue) = 50, '50 g BOM';
  assert (select status = 'placed' and total = 2 * v_price + round(2 * v_price * setting_num('sales_tax_rate'), 2) from sales_orders where id = so),
    'order total = quote total';
  select * into r from production_orders where so_id = so;
  mo := r.id;
  assert r.status = 'planned' and r.plates = 2 and r.qty_planned = 2, 'planned 2-plate production order';
  assert (select qty_required from production_order_components where mo_id = mo) = 100, '100 g of filament required';
  assert track_order((select tracking_token from sales_orders where id = so))->>'stage' = 'queued', 'tracking shows queued';

  -- ------------------------------------------------------------- printers
  assert (select count(*) from printers where is_active) >= 4, 'four printers';
  perform issue_production_order(mo);
  assert (select printer_id is not null from production_orders where id = mo), 'started print is on a printer';
  assert mo_estimated_finish(mo) = (select started_at from production_orders where id = mo) + interval '140 minutes',
    format('estimated finish %s', mo_estimated_finish(mo));
  perform assign_printer(mo, (select id from printers where code = 'P2S-2'));
  assert (select printer_id from production_orders where id = mo) = (select id from printers where code = 'P2S-2'), 'moved to printer 2';
  assert (select count(*) from printer_stats(current_date - 7, current_date)) = (select count(*) from printers where is_active), 'stats per printer';
  assert (select jobs from printer_stats(current_date - 1, current_date) where code = 'P2S-2') >= 1, 'running job counted';
  begin
    perform assign_printer(mo, gen_random_uuid());
    v_ok := false;
  exception when others then v_ok := sqlerrm like '%active printer%';
  end;
  assert v_ok, 'unknown printer refused';
  perform set_config('pp.quote_item', it::text, true);
end $$;

-- ------------------------------------------------------- portal customer
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f1","role":"authenticated"}', true);
do $$
declare v_so uuid; v_ok boolean := false;
begin
  assert not exists (select 1 from portal_catalog() where item_id = current_setting('pp.quote_item')::uuid), 'custom items not in the catalog';
  begin
    perform portal_place_order(jsonb_build_object('location_id', (select id from locations where code = 'CAMPUS'),
      'lines', jsonb_build_array(jsonb_build_object('item_id', current_setting('pp.quote_item'), 'qty', 1))));
  exception when others then v_ok := sqlerrm like '%not available%';
  end;
  assert v_ok, 'a custom item cannot be ordered from the catalog';
  v_so := portal_create_custom_print_order(jsonb_build_object('name', 'Name tag', 'print_hours', 1, 'grams', 20,
            'color', 'Red', 'qty', 1, 'fulfillment_method', 'ship', 'location_id', (select id from locations where code = 'CAMPUS')));
  assert (select channel || '/' || fulfillment_method from sales_orders where id = v_so) = 'portal/pickup', 'portal custom order is a pickup';
  assert (select count(*) from sales_orders where id = v_so) = 1, 'customer sees their custom order';
  assert exists (select 1 from items i join sales_order_lines l on l.item_id = i.id where l.so_id = v_so), 'customer sees their own custom item';
  assert not exists (select 1 from items where id = current_setting('pp.quote_item')::uuid), 'but not other customers'' custom items';
  v_ok := false;
  begin
    perform create_custom_print_order(jsonb_build_object('name', 'x', 'print_hours', 1, 'grams', 1, 'color', 'Red'));
  exception when insufficient_privilege then v_ok := true;
  end;
  assert v_ok, 'customer cannot use the staff quote order';
end $$;

reset role;
do $$ begin raise notice 'QUOTES + PRINTERS + CAPACITY CHECKS PASSED'; end $$;
rollback;
