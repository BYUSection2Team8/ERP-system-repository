-- =============================================================================
-- capacity_overrides_check.sql — capacity warnings, overrides, rack room (wow #7).
-- ROLLED BACK. Success = "CAPACITY OVERRIDE CHECKS PASSED".
--   * moving N cubes of 12x12x12 in (1 cu ft each) to Campus adds N cu ft
--   * enough to pass 100% -> level "over" with a suggested other location
--   * an override needs an 'override' reason code and is recorded with who / why
--   * rack room = rack size - spools on hand - spools on open POs (floored, >= 0)
-- =============================================================================
begin;

do $$
declare
  v_cp uuid := (select id from locations where code = 'CAMPUS');
  big uuid; q jsonb; v_cap numeric; v_used numeric; v_n int; v_ok boolean; r record;
begin
  insert into items (sku, barcode, name, item_type, category, uom, price, stocking_policy, length_in, width_in, height_in)
  values ('CAPOV-FG', 'CAPOV-FG', 'Capacity override cube', 'finished', 'product', 'ea', 5, 'stock', 12, 12, 12) returning id into big;
  q := capacity_check(v_cp, jsonb_build_array(jsonb_build_object('item_id', big, 'qty', 2)));
  assert (q->>'adding_cuft')::numeric = 2, format('2 cubes = 2 cu ft: %s', q);
  v_cap := (q->>'capacity_cuft')::numeric; v_used := (q->>'used_cuft')::numeric;
  assert (q->>'projected_cuft')::numeric = round(v_used + 2, 2), 'projected = used + adding';

  v_n := ceil(v_cap - v_used + 1)::int;   -- enough to go over 100%
  q := capacity_check(v_cp, jsonb_build_array(jsonb_build_object('item_id', big, 'qty', v_n)));
  assert q->>'level' = 'over' and q->>'suggestion' like '%cu ft free%', format('over capacity: %s', q);

  v_ok := false;
  begin perform log_capacity_override(v_cp, 'ADJ_LOST', 'x'); exception when others then v_ok := sqlerrm like '%reason code%'; end;
  assert v_ok, 'override needs an override reason';
  perform log_capacity_override(v_cp, 'OVR_PEAK', 'Black Friday build-up', 'Transfer test', (q->>'projected_utilization')::numeric);
  select * into r from capacity_overrides order by id desc limit 1;
  assert r.location_id = v_cp and r.reason_code = 'OVR_PEAK' and r.note = 'Black Friday build-up', 'override recorded';

  select * into r from filament_rack_room();
  assert r.room = greatest(0, floor(setting_num('filament_rack_spools')
           - (select coalesce(sum(t.qty), 0) from inventory_txn t join items i on i.id = t.item_id where i.category = 'filament') / setting_num('spool_grams')
           - (select coalesce(sum((l.qty_ordered - l.qty_received) * l.stock_per_purchase_unit), 0)
                from purchase_order_lines l join purchase_orders po on po.id = l.po_id join items i on i.id = l.item_id
               where i.category = 'filament' and po.status in ('sent', 'partial') and l.qty_received < l.qty_ordered) / setting_num('spool_grams'))),
    format('rack room %s', row_to_json(r));
end $$;

do $$ begin raise notice 'CAPACITY OVERRIDE CHECKS PASSED'; end $$;
rollback;
