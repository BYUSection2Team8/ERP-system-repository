-- =============================================================================
-- new_design_check.sql — Phase 10 (wow #8): New Design wizard.
-- ROLLED BACK at the end. Success = "NEW DESIGN CHECKS PASSED".
--
-- Hand-checked: a 2-color design (Red, Blue), 30 g per plate, 90 min print,
-- 2 units per plate, 4 min assembly, 1 LED tealight per plate:
--   unit cost (per color) = (30 g x red/blue cost per g + LED cost + 1.5 h x machine rate
--                            + (setup + cleanup + 4)/60 x labor rate) / 2
--   suggested price = ceil(highest unit cost x markup) - 0.01
--   after creating: 2 items CODE-RED / CODE-BLUE with barcodes PP-CODE-..., BOM = filament + LED,
--   and item_standard_cost() of each = the previewed unit cost (one formula)
-- =============================================================================
begin;

do $$
declare
  led uuid := (select id from items where sku = 'CMP-LED');
  p jsonb; d jsonb; ids uuid[]; v jsonb; r record;
  v_red numeric; v_exp numeric; v_max numeric := 0;
  v_ok boolean; bad jsonb;
begin
  p := jsonb_build_object('name', 'Check Rocket', 'code', 'ZQX', 'colors', jsonb_build_array('red', 'Blue'),
         'grams_per_plate', 30, 'print_minutes', 90, 'units_per_plate', 2, 'assembly_minutes', 4,
         'components', jsonb_build_array(jsonb_build_object('item_id', led, 'qty_per_plate', 1)),
         'length_in', 3, 'width_in', 2, 'height_in', 5, 'packing_class', 'fragile', 'stocking_policy', 'make_to_order');
  d := preview_product_design(p);
  assert jsonb_array_length(d->'variants') = 2, 'one variant per color';
  for v in select * from jsonb_array_elements(d->'variants') loop
    v_exp := round((30 * item_unit_cost((v->>'filament_item_id')::uuid) + item_unit_cost(led)) / 2, 6)
           + round(1.5 * machine_rate_per_hour() / 2, 6)
           + round((setting_num('setup_minutes_per_plate') + setting_num('cleanup_minutes_per_plate') + 4) / 60.0 * setting_num('labor_rate') / 2, 6);
    assert (v->>'unit_cost')::numeric = v_exp, format('%s unit cost %s, expected %s', v->>'color', v->>'unit_cost', v_exp);
    v_max := greatest(v_max, v_exp);
  end loop;
  assert (d->>'suggested_price')::numeric = ceil(v_max * setting_num('new_design_markup')) - 0.01, format('suggested price %s', d->>'suggested_price');
  assert d->'variants'->0->>'sku' = 'ZQX-RED' and d->'variants'->0->>'barcode' = 'PP-ZQX-RED', 'SKU and barcode pattern';
  assert not exists (select 1 from items where sku like 'ZQX-%'), 'preview saves nothing';

  ids := create_product_design(p || '{"price": 24.99}');
  assert array_length(ids, 1) = 2, 'two items created';
  for r in select i.id, i.sku, i.price, i.product_family, i.units_per_plate,
                  (select total_cost from item_standard_cost(i.id)) as std,
                  (select count(*) from boms b where b.parent_item_id = i.id) as bom_lines
             from items i where i.id = any(ids) loop
    assert r.price = 24.99 and r.product_family = 'Check Rocket' and r.units_per_plate = 2 and r.bom_lines = 2,
      format('item %s: %s', r.sku, row_to_json(r));
    assert r.std = (select (x->>'unit_cost')::numeric from jsonb_array_elements(d->'variants') x where x->>'sku' = r.sku),
      format('%s rolled-up cost %s = preview', r.sku, r.std);
  end loop;
  assert exists (select 1 from portal_catalog() where item_id = ids[1]), 'new product is in the customer catalog';

  -- Refusals (plain messages).
  for bad in select * from jsonb_array_elements(jsonb_build_array(
      p, p || '{"code": "NEWQ", "name": "Check Rocket"}', p || '{"name": "Other", "code": "DRG"}',
      p || '{"name": "Other", "code": "Q1"}', p || '{"name": "Other", "code": "QQQ", "colors": []}',
      p || '{"name": "Other", "code": "QQQ", "colors": ["Green"]}', p || '{"name": "Other", "code": "QQQ", "grams_per_plate": 0}',
      p || '{"name": "Other", "code": "QQQ", "print_minutes": "abc"}', p || '{"name": "Other", "code": "QQQ", "units_per_plate": 0}',
      p || '{"name": "Other", "code": "QQQ", "price": -1}', p || '{"name": "Other", "code": "QQQ", "stocking_policy": "seasonal"}',
      p || '{"name": "Other", "code": "QQQ", "lead_time_days": "x"}',
      p || jsonb_build_object('name', 'Other', 'code', 'QQQ', 'components',
             jsonb_build_array(jsonb_build_object('item_id', (select id from items where sku = 'FIL-PLA-RED'), 'qty_per_plate', 1)))
  )) loop
    v_ok := false;
    begin
      perform preview_product_design(bad);
    exception when others then v_ok := sqlerrm not like '%invalid input%';
    end;
    assert v_ok, format('refused with a plain message: %s', bad);
  end loop;
end $$;

-- A customer cannot create products.
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a9', 'design.customer@example.com');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a9","role":"authenticated"}', true);
do $$
declare v_ok boolean := false;
begin
  begin
    perform create_product_design('{"name": "Hack", "code": "HAK", "colors": ["Red"], "grams_per_plate": 1, "print_minutes": 1}');
  exception when insufficient_privilege then v_ok := true;
  end;
  assert v_ok, 'customers cannot create products';
end $$;
reset role;

do $$ begin raise notice 'NEW DESIGN CHECKS PASSED'; end $$;
rollback;
