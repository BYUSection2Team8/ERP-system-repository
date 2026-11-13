-- =============================================================================
-- 021_glue_tubes.sql — super glue is bought and stored in tubes, not spools
--
-- Glue stays stocked in grams (BOMs use grams), but the supplier price list now
-- buys it in 20 g tubes at 20 x the per-gram price (same cost per gram), so POs,
-- reorder suggestions and the inventory screens count tubes. Only rows still
-- priced per gram change, so this is safe to run again.
-- =============================================================================
update public.item_suppliers s
   set purchase_uom = 'tube',
       stock_per_purchase_unit = 20,
       unit_cost = round(s.unit_cost * 20 / s.stock_per_purchase_unit, 4)
  from public.items i
 where i.id = s.item_id and i.sku = 'CMP-GLUE' and s.purchase_uom = 'g';

update public.items set name = 'Super glue (grams, 20 g tubes)'
 where sku = 'CMP-GLUE' and name = 'Super glue (gram)';
