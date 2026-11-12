-- =============================================================================
-- seed_check.sql — checks the Phase 2 starter data against SPEC.md.
-- Read-only. Run after seed/001_starter_data.sql. Success = "SEED CHECKS PASSED".
-- Rolled-up costs use the exact machine rate ($0.2065/hr) and weighted-average
-- filament cost ($14.99/985 g), so long prints land a few cents under the
-- spec's table (which rounds the machine rate to $0.21).
-- =============================================================================
do $$
declare r record;
begin
  assert (select count(*) from items) >= 48, 'at least 48 items (30 finished + 18 purchased)';
  assert (select count(*) from items where item_type = 'finished') = 30, '30 finished items';
  assert (select count(*) from items where item_type = 'purchased') = 18, '18 purchased items';
  assert (select count(distinct parent_item_id) from boms) = 30, 'every finished item has a BOM';
  assert (select count(distinct product_family) from items where item_type = 'finished') = 9, '9 products';
  assert (select count(*) from suppliers) >= 7, '7 suppliers';
  assert (select count(*) from customers) >= 5, '5 customers';
  assert (select count(*) from locations) = 4, '3 locations + QA Hold';
  assert not exists (select 1 from items where barcode is null or barcode = ''), 'every item has a barcode';
  assert (select max(length(barcode)) from items) <= 14, 'barcodes fit on a 2-5/8 inch label (14 characters max)';
  assert not exists (select 1 from items i where item_type = 'purchased'
                      and not exists (select 1 from item_suppliers s where s.item_id = i.id and s.is_preferred)),
    'every purchased item has a preferred supplier price';

  -- Rolled-up unit cost vs the BOM table in SPEC.md (within 5 cents).
  for r in select * from (values
      ('DRG-RED', 1.07), ('KEY-BW', 0.93), ('SPN-BLUE', 2.85), ('ORN-WHITE', 1.44),
      ('TMP-WHITE', 6.65), ('ARM-BLACK', 9.98), ('AIR-MC', 10.37), ('BYU-BLUE', 2.31),
      ('MAG-RED', 10.69)) as x(sku, spec_cost)
  loop
    assert abs((select total_cost from v_item_standard_cost where sku = r.sku) - r.spec_cost) <= 0.05,
      format('%s rolled-up cost %s vs spec %s', r.sku,
             (select round(total_cost, 4) from v_item_standard_cost where sku = r.sku), r.spec_cost);
  end loop;

  -- Opening stock was posted, not typed: it exists in the ledger.
  assert (select qty_on_hand from v_availability a join items i on i.id = a.item_id
           where i.sku = 'FIL-PLA-BLUE' and a.location_id = (select id from locations where code = 'PRINT_FARM')) = 8 * 985,
    '8 spools of blue filament (7,880 g)';
  assert (select balance from v_account_balances where code = '1200') > 0, 'inventory on the books';
  assert (select balance from v_account_balances where code = '3000') =
         (select balance from v_account_balances where code = '1200'), 'opening inventory funded by owner''s equity';

  raise notice 'SEED CHECKS PASSED: % items, inventory value $%', (select count(*) from items),
    (select balance from v_account_balances where code = '1200');
end $$;
