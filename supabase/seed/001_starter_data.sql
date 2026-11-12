-- =============================================================================
-- seed/001_starter_data.sql — Phase 2 starter data
-- Run ONCE in Supabase SQL Editor, after all migrations. Safe to re-run: it
-- stops without changes if the items already exist.
--
--   7 suppliers, 18 purchased items (filament stocked in grams), 30 finished
--   items (9 products), 9 BOM families, 5 test customers, opening inventory.
--
-- Nothing here types in an on-hand quantity or a cost: opening stock is POSTED
-- through receive_opening_inventory (Dr Inventory / Cr Owner's equity) so every
-- balance is derived from transactions. Purchased items come in at supplier
-- price; finished goods at their rolled-up BOM cost.
-- Opening stock is dated 184 days ago, before the 6-month history (Phase 6).
-- The other 55 customers are added in Phase 6 (skip names that already exist).
-- =============================================================================
do $$
declare
  v_open timestamptz := date_trunc('day', now() - interval '184 days') + interval '8 hours';
  v_pf uuid := (select id from locations where code = 'PRINT_FARM');
  v_ff uuid := (select id from locations where code = 'FULFILLMENT');
  v_cp uuid := (select id from locations where code = 'CAMPUS');
  s_hl uuid; s_bl uuid; s_ul uuid; s_am uuid; s_kj uuid; s_vx uuid; s_vp uuid;
  c text;
  v_suffix text;
  colors text[] := array['Red','White','Blue','Black'];
  v_parent uuid;
  r record;
begin
  if exists (select 1 from items where sku = 'DRG-RED') then
    raise notice 'Starter data already loaded; nothing changed.';
    return;
  end if;

  -- --------------------------------------------------------------- suppliers
  insert into suppliers (name, contact_name, email, phone, website, quoted_lead_days, payment_terms, terms_days, notes) values
    ('Hobby Lobby',     'Dana Whitlock',  'orders.hobbylobby@example.com', '801-555-0141', 'https://www.hobbylobby.com', 2,  'Paid at purchase', 0,  'Primary PLA filament (985 g spool, part 2589638); ribbon hangers. Frequent sales.'),
    ('Bambu Lab',       'Kevin Zhao',     'orders.bambulab@example.com',   '888-555-0102', 'https://bambulab.com',       7,  'Paid at purchase', 0,  'Backup PLA filament source (1 kg spool).'),
    ('Uline',           'Marissa Groves', 'orders.uline@example.com',      '800-555-0199', 'https://www.uline.com',      2,  'Net 30',           30, 'Shipping boxes and tissue paper.'),
    ('Amazon Business', 'Account Team',   'orders.amazonbiz@example.com',  '888-555-0128', 'https://business.amazon.com', 3, 'Net 30',           30, 'Glue, LED tealights, keychain hardware, figure bases, hex nuts.'),
    ('K&J Magnetics',   'Brian Hollis',   'orders.kjmagnetics@example.com','215-555-0167', 'https://www.kjmagnetics.com', 6, 'Net 15',           15, 'Neodymium magnets for alphabet sets.'),
    ('VXB Bearings',    'Lena Ortiz',     'orders.vxb@example.com',        '714-555-0133', 'https://www.vxb.com',        8,  'Net 30',           30, '608ZZ bearings for fidget spinners.'),
    ('Vistaprint',      'Customer Care',  'orders.vistaprint@example.com', '866-555-0175', 'https://www.vistaprint.com', 10, 'Paid at purchase', 0,  'Thank-you cards.');
  select id into s_hl from suppliers where name = 'Hobby Lobby';
  select id into s_bl from suppliers where name = 'Bambu Lab';
  select id into s_ul from suppliers where name = 'Uline';
  select id into s_am from suppliers where name = 'Amazon Business';
  select id into s_kj from suppliers where name = 'K&J Magnetics';
  select id into s_vx from suppliers where name = 'VXB Bearings';
  select id into s_vp from suppliers where name = 'Vistaprint';

  -- --------------------------------------------------------- purchased items
  -- Filament: one item per color, stocked in grams; bought as 985 g spools.
  foreach c in array colors loop
    insert into items (sku, barcode, name, item_type, category, color, uom, stocking_policy, preferred_supplier_id)
    values ('FIL-PLA-' || upper(c), 'PP-FIL-' || upper(c), 'PLA filament - ' || c, 'purchased', 'filament', c, 'g', 'not_sold', s_hl);
  end loop;

  insert into items (sku, barcode, name, item_type, category, uom, stocking_policy, preferred_supplier_id, length_in, width_in, height_in) values
    ('CMP-RIBBON',  'PP-CMP-RIBBON',  'Ribbon hanger',               'purchased', 'component', 'ea', 'not_sold', s_hl, null, null, null),
    ('PKG-BOX-S',   'PP-PKG-BOX-S',   'Shipping box - small 6x4x4',  'purchased', 'packaging', 'ea', 'not_sold', s_ul, 6, 4, 4),
    ('PKG-BOX-M',   'PP-PKG-BOX-M',   'Shipping box - medium 9x7x5', 'purchased', 'packaging', 'ea', 'not_sold', s_ul, 9, 7, 5),
    ('PKG-BOX-L',   'PP-PKG-BOX-L',   'Shipping box - large 12x10x6','purchased', 'packaging', 'ea', 'not_sold', s_ul, 12, 10, 6),
    ('PKG-TISSUE',  'PP-PKG-TISSUE',  'Tissue paper (sheet)',        'purchased', 'packaging', 'ea', 'not_sold', s_ul, null, null, null),
    ('CMP-GLUE',    'PP-CMP-GLUE',    'Super glue (gram)',           'purchased', 'component', 'g',  'not_sold', s_am, null, null, null),
    ('CMP-LED',     'PP-CMP-LED',     'LED tealight',                'purchased', 'component', 'ea', 'not_sold', s_am, null, null, null),
    ('CMP-RING',    'PP-CMP-RING',    'Split ring',                  'purchased', 'component', 'ea', 'not_sold', s_am, null, null, null),
    ('CMP-CHAIN',   'PP-CMP-CHAIN',   'Keychain chain',              'purchased', 'component', 'ea', 'not_sold', s_am, null, null, null),
    ('CMP-BASE',    'PP-CMP-BASE',    'Figure base 25 mm',           'purchased', 'component', 'ea', 'not_sold', s_am, null, null, null),
    ('CMP-HEXNUT',  'PP-CMP-HEXNUT',  'Hex nut',                     'purchased', 'component', 'ea', 'not_sold', s_am, null, null, null),
    ('CMP-MAGNET',  'PP-CMP-MAGNET',  'Neodymium magnet 6x2 mm',     'purchased', 'component', 'ea', 'not_sold', s_kj, null, null, null),
    ('CMP-BEARING', 'PP-CMP-BEARING', '608ZZ bearing',               'purchased', 'component', 'ea', 'not_sold', s_vx, null, null, null),
    ('PKG-CARD',    'PP-PKG-CARD',    'Thank-you card',              'purchased', 'packaging', 'ea', 'not_sold', s_vp, null, null, null);

  -- Supplier price lists (unit cost per purchase unit).
  insert into item_suppliers (item_id, supplier_id, supplier_part_no, purchase_uom, stock_per_purchase_unit, unit_cost, is_preferred)
  select i.id, s_hl, '2589638', 'spool', 985, 14.99, true from items i where i.category = 'filament';
  insert into item_suppliers (item_id, supplier_id, supplier_part_no, purchase_uom, stock_per_purchase_unit, unit_cost, is_preferred)
  select i.id, s_bl, 'PLA-BASIC-1KG', 'spool', 1000, 19.99, false from items i where i.category = 'filament';
  insert into item_suppliers (item_id, supplier_id, purchase_uom, stock_per_purchase_unit, unit_cost, is_preferred)
  select i.id, x.sup, 'ea', 1, x.cost, true
    from (values
      ('CMP-RIBBON', s_hl, 0.08), ('PKG-BOX-S', s_ul, 0.45), ('PKG-BOX-M', s_ul, 0.75), ('PKG-BOX-L', s_ul, 1.25),
      ('PKG-TISSUE', s_ul, 0.05), ('CMP-GLUE', s_am, 0.30), ('CMP-LED', s_am, 0.40), ('CMP-RING', s_am, 0.06),
      ('CMP-CHAIN', s_am, 0.05), ('CMP-BASE', s_am, 0.10), ('CMP-HEXNUT', s_am, 0.05), ('CMP-MAGNET', s_kj, 0.06),
      ('CMP-BEARING', s_vx, 0.60), ('PKG-CARD', s_vp, 0.15)
    ) as x(sku, sup, cost)
    join items i on i.sku = x.sku;
  -- Glue is priced per gram.
  update item_suppliers set purchase_uom = 'g' where item_id = (select id from items where sku = 'CMP-GLUE');

  -- ---------------------------------------------------------- finished items
  -- One row per product: per-plate print/assembly data, price, size, policy.
  create temp table _products (
    code text, name text, colors text[], units_per_plate int, print_min numeric, assembly_min numeric,
    price numeric, policy text, season_start text, season_end text, lead_days int,
    l numeric, w numeric, h numeric, box text, packing text, grams numeric, suffixes text[]
  ) on commit drop;
  insert into _products values
    ('DRG', 'Dragon',               colors,  1,  69,  0, 8.99,  'stock',         null,    null,    1, 4,  2, 1.5,  'small',  'standard',    10.43, null),
    ('SPN', 'Fidget Spinner',       colors,  1,  45,  3, 7.99,  'stock',         null,    null,    1, 3,  3, 0.5,  'small',  'standard',    18, null),
    ('ORN', 'Christmas Ornament',   colors,  1,  50,  1, 7.99,  'seasonal',      '11-01', '12-31', 1, 3,  3, 0.5,  'small',  'standard',    12, null),
    ('TMP', 'Temple LED Tealight',  colors,  1, 305, 10, 27.99, 'make_to_order', null,    null,    2, 4,  4, 5,    'medium', 'fragile',     58.36, null),
    ('ARM', 'Army Soldiers (lot of 10)', colors, 1, 180, 20, 19.99, 'make_to_order', null, null, 1, 5,  3, 2,    'small',  'multi_piece', 27.7, null),
    ('BYU', 'BYU Logo',             colors,  1, 104,  0, 14.99, 'make_to_order', null,    null,    1, 7,  5, 0.75, 'medium', 'standard',    84.44, null),
    ('MAG', 'Magnet Alphabet Set',  colors,  1, 119, 20, 22.99, 'make_to_order', null,    null,    1, 5,  4, 1.5,  'small',  'multi_piece', 41.52, null),
    ('KEY', 'Keychain',             array['Blue/White'], 10, 188, 20, 4.99, 'stock', null, null, 1, 2,  1, 0.25, 'small',  'small',       null, array['BW']),
    ('AIR', 'Airplane',             array['Multicolor'],  1, 469, 15, 39.99, 'make_to_order', null, null, 2, 10, 9, 3, 'large', 'fragile',     null, array['MC']);

  for r in select * from _products loop
    foreach c in array r.colors loop
      -- Short suffix keeps barcodes narrow enough for a 2-5/8" label (KEY-BW, AIR-MC).
      v_suffix := coalesce(r.suffixes[1], upper(c));
      insert into items (sku, barcode, name, item_type, category, product_family, color, uom, price,
                         stocking_policy, season_start, season_end, units_per_plate, print_minutes,
                         assembly_minutes, color_changes, lead_time_days, packing_class, box_size,
                         length_in, width_in, height_in)
      values (r.code || '-' || v_suffix,
              'PP-' || r.code || '-' || v_suffix,
              r.name || ' - ' || c, 'finished', 'product', r.name, c, 'ea', r.price,
              r.policy, r.season_start, r.season_end, r.units_per_plate, r.print_min,
              r.assembly_min, case when r.code in ('KEY','AIR') then 1 else 0 end, r.lead_days,
              r.packing, r.box, r.l, r.w, r.h)
      returning id into v_parent;

      -- Single-color products: filament of the chosen color.
      if r.grams is not null then
        insert into boms (parent_item_id, component_item_id, qty_per_plate)
        values (v_parent, (select id from items where sku = 'FIL-PLA-' || upper(c)), r.grams);
      end if;
    end loop;
  end loop;

  -- Components (per plate) and multi-color filament.
  insert into boms (parent_item_id, component_item_id, qty_per_plate)
  select p.id, comp.id, x.qty
    from (values
      ('TMP', 'CMP-GLUE', 1.0), ('TMP', 'CMP-LED', 1.0),
      ('ARM', 'CMP-GLUE', 2.0), ('ARM', 'CMP-BASE', 10.0),
      ('MAG', 'CMP-MAGNET', 26.0), ('MAG', 'CMP-GLUE', 2.5),
      ('SPN', 'CMP-BEARING', 1.0), ('SPN', 'CMP-HEXNUT', 3.0),
      ('ORN', 'CMP-RIBBON', 1.0),
      ('KEY', 'FIL-PLA-BLUE', 13.96), ('KEY', 'FIL-PLA-WHITE', 2.47), ('KEY', 'CMP-RING', 10.0), ('KEY', 'CMP-CHAIN', 10.0),
      ('AIR', 'FIL-PLA-BLACK', 14.77), ('AIR', 'FIL-PLA-BLUE', 55.59), ('AIR', 'FIL-PLA-WHITE', 84.99),
      ('AIR', 'FIL-PLA-RED', 16.29), ('AIR', 'CMP-GLUE', 1.5)
    ) as x(code, comp_sku, qty)
    join items p on p.sku like x.code || '-%' and p.item_type = 'finished'
    join items comp on comp.sku = x.comp_sku;

  -- ------------------------------------------------------------ customers
  insert into customers (name, email, city, state, segment, is_byu, terms_days, contact_name) values
    ('Ethan Caldwell',      'ethan.caldwell@example.com',     'Provo',          'UT', 'student',      true,  0,  null),
    ('Rebecca Holloway',    'rebecca.holloway@example.com',   'Salt Lake City', 'UT', 'gift_buyer',   false, 0,  null),
    ('Marcus Bellweather',  'marcus.bellweather@example.com', 'West Jordan',    'UT', 'hobbyist',     false, 0,  null),
    ('Jennifer Olsen',      'jennifer.olsen@example.com',     'Stansbury Park', 'UT', 'local_family', false, 0,  null),
    ('Summit Ridge Gifts',  'dana.moffat@example.com',        'Park City',      'UT', 'business',     false, 30, 'Dana Moffat');

  -- ------------------------------------------------------ opening inventory
  -- Purchased goods first (at supplier price), so finished goods can roll up.
  for r in select i.id, x.loc, x.qty
             from (values
               ('FIL-PLA-RED',   v_pf, 6 * 985), ('FIL-PLA-WHITE', v_pf, 8 * 985),
               ('FIL-PLA-BLUE',  v_pf, 8 * 985), ('FIL-PLA-BLACK', v_pf, 6 * 985),
               ('CMP-RIBBON', v_pf, 100), ('CMP-GLUE', v_pf, 250), ('CMP-LED', v_pf, 40),
               ('CMP-RING', v_pf, 300), ('CMP-CHAIN', v_pf, 300), ('CMP-BASE', v_pf, 200),
               ('CMP-HEXNUT', v_pf, 300), ('CMP-MAGNET', v_pf, 520), ('CMP-BEARING', v_pf, 80),
               ('PKG-BOX-S', v_ff, 150), ('PKG-BOX-M', v_ff, 60), ('PKG-BOX-L', v_ff, 20),
               ('PKG-TISSUE', v_ff, 500), ('PKG-CARD', v_ff, 300),
               ('PKG-BOX-S', v_cp, 25), ('PKG-CARD', v_cp, 50)
             ) as x(sku, loc, qty)
             join items i on i.sku = x.sku
  loop
    perform receive_opening_inventory(r.id, r.loc, r.qty, null, v_open, 'Opening balance');
  end loop;

  -- Stocked finished goods at the Fulfillment Center and Campus Counter.
  for r in select i.id, x.loc, x.qty
             from items i
             join (values
               ('DRG', v_ff, 12), ('DRG', v_cp, 6),
               ('SPN', v_ff, 10), ('SPN', v_cp, 5),
               ('KEY', v_ff, 40), ('KEY', v_cp, 20)
             ) as x(code, loc, qty) on i.sku like x.code || '-%' and i.item_type = 'finished'
  loop
    perform receive_opening_inventory(r.id, r.loc, r.qty, null, v_open + interval '1 hour', 'Opening balance');
  end loop;

  raise notice 'Starter data loaded: % items, % BOM lines, % suppliers, % customers.',
    (select count(*) from items), (select count(*) from boms),
    (select count(*) from suppliers), (select count(*) from customers);
end $$;
