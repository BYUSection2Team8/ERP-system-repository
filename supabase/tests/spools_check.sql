-- =============================================================================
-- spools_check.sql — spool tracking (wow #5). ROLLED BACK. Success = "SPOOL CHECKS PASSED".
--
-- Hand-checked with a test filament (spool size S = setting spool_grams, 985 g):
--   receive 2S + 300 g        -> 3 spools: S, S, 300
--   print needing 400 g       -> the 300 g partial is loaded and emptied, the next spool is
--                                loaded into the same printer and gives 100 g (S - 100 left)
--   weigh that spool at 800 g -> cycle count of (800 - (S - 100)) g on the ledger; spool = 800
--   lose 100 g (adjustment)   -> comes off the spool in stock with the least left
--   every filament: grams on spools = grams on hand (the whole seeded history too)
-- =============================================================================
begin;

do $$
declare
  v_pf uuid := (select id from locations where code = 'PRINT_FARM');
  v_s numeric := setting_num('spool_grams');
  fil uuid; fg uuid; mo uuid; v_pr uuid;
  sp text[]; r record; v_ok boolean;
begin
  -- The seeded history (or the live data) is in step.
  assert not exists (select 1 from v_spool_reconciliation where abs(grams_on_hand - grams_on_spools) > 0.05),
    format('spools out of step: %s', (select json_agg(x) from v_spool_reconciliation x where abs(grams_on_hand - grams_on_spools) > 0.05));

  insert into items (sku, barcode, name, item_type, category, uom) values ('SPTEST-FIL', 'SPTEST-FIL', 'Spool test filament', 'purchased', 'filament', 'g')
  returning id into fil;
  perform receive_opening_inventory(fil, v_pf, 2 * v_s + 300, 0.02);
  assert (select array_agg(grams_left order by grams_left) from spools where item_id = fil) = array[300, v_s, v_s]::numeric[], 'spools S, S, 300';
  select array_agg(barcode order by grams_left, spool_no) into sp from spools where item_id = fil;
  assert sp[1] ~ '^PP-SP-\d+$', 'spool barcode pattern';

  insert into items (sku, barcode, name, item_type, category, uom, price, stocking_policy, units_per_plate, print_minutes)
  values ('SPTEST-FG', 'SPTEST-FG', 'Spool test product', 'finished', 'product', 'ea', 10, 'make_to_order', 1, 60) returning id into fg;
  insert into boms (parent_item_id, component_item_id, qty_per_plate) values (fg, fil, 400);
  mo := create_production_order(fg, 1);
  perform issue_production_order(mo);
  v_pr := (select printer_id from production_orders where id = mo);
  assert v_pr is not null, 'print has a printer';
  assert (select status from spools where barcode = sp[1]) = 'empty', 'partial spool used up';
  select * into r from spools where barcode = sp[2];
  assert r.status = 'loaded' and r.printer_id = v_pr and r.grams_left = v_s - 100, format('next spool loaded on the printer: %s', row_to_json(r));
  assert (select sum(grams) from spool_usage where mo_id = mo) = 400, '400 g drawn for the print';

  perform weigh_spool(sp[2], 800);
  assert (select grams_left from spools where barcode = sp[2]) = 800, 'weighed spool = 800 g';
  assert (select qty from inventory_txn where item_id = fil and source_type = 'adjustment' order by id desc limit 1) = 800 - (v_s - 100),
    'weighing posted a cycle count';

  perform adjust_inventory(fil, v_pf, -100, 'ADJ_DAMAGED');
  assert (select grams_left from spools where barcode = sp[3]) = v_s - 100, 'loss taken from the spool in stock';

  -- Load / unload
  perform load_spool(sp[3], v_pr, 4);
  assert (select status = 'loaded' and ams_slot = 4 from spools where barcode = sp[3]), 'loaded into slot 4';
  perform load_spool(sp[2], v_pr, 4);
  assert (select status from spools where barcode = sp[3]) = 'in_stock', 'the spool that was in slot 4 went back to stock';
  perform unload_spool(sp[2]);
  assert (select status from spools where barcode = sp[2]) = 'in_stock', 'unloaded';
  v_ok := false;
  begin perform load_spool(sp[1], v_pr, 1); exception when others then v_ok := sqlerrm like '%empty%'; end;
  assert v_ok, 'an empty spool cannot be loaded';
  v_ok := false;
  begin perform load_spool(sp[2], v_pr, 5); exception when others then v_ok := sqlerrm like '%slot%'; end;
  assert v_ok, 'slot must be 1-4';
  v_ok := false;
  begin perform weigh_spool('PP-SP-0', 10); exception when others then v_ok := sqlerrm like '%No spool%'; end;
  assert v_ok, 'unknown spool';

  assert not exists (select 1 from v_spool_reconciliation where abs(grams_on_hand - grams_on_spools) > 0.05), 'still in step';
end $$;

do $$ begin raise notice 'SPOOL CHECKS PASSED'; end $$;
rollback;
