-- =============================================================================
-- 005_reference_data.sql — settings, chart of accounts, reason codes, locations
-- Every value here is editable later (Settings screen / reason code list).
-- Items, BOMs, suppliers and customers come in the Phase 2 seed.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
insert into public.settings (key, value, type, category, label, description) values
  -- Company
  ('company_name',        'Poulson Prints',  'text',    'company',  'Company name', null),
  ('time_zone',           'America/Denver',  'text',    'company',  'Time zone', 'Used for business dates (due dates, expected dates).'),
  ('staff_day_start_hour','8',               'number',  'company',  'Staff day starts (hour)', '24-hour clock. Prints finishing after hours are completed next morning.'),
  ('staff_day_end_hour',  '20',              'number',  'company',  'Staff day ends (hour)', null),
  -- Labor
  ('labor_rate',                 '20',  'number', 'labor', 'Labor rate ($/hr)', null),
  ('setup_minutes_per_plate',    '1',   'number', 'labor', 'Setup per plate (min)', 'Charged per plate, not per unit.'),
  ('cleanup_minutes_per_plate',  '1',   'number', 'labor', 'Cleanup per plate (min)', 'Charged per plate, not per unit.'),
  -- Machine (machine rate per hour is calculated from these)
  ('printer_cost',          '700',  'number', 'machine', 'Printer cost ($)', 'Bambu Lab P2S with AMS.'),
  ('printer_life_hours',    '5000', 'number', 'machine', 'Printer life (print hours)', null),
  ('printer_power_kw',      '0.15', 'number', 'machine', 'Printer power draw (kW)', null),
  ('electricity_per_kwh',   '0.11', 'number', 'machine', 'Electricity ($/kWh)', null),
  ('maintenance_per_hour',  '0.05', 'number', 'machine', 'Maintenance ($/print hr)', null),
  -- Filament
  ('spool_grams',             '985', 'number', 'filament', 'Grams per spool', 'Hobby Lobby spool net weight (confirm).'),
  ('ams_purge_g_per_change',  '0',   'number', 'filament', 'AMS purge per color change (g)', 'Stretch feature; estimate still to be measured.'),
  -- Sales
  ('sales_tax_rate',          '0.0745', 'number', 'sales', 'Sales tax rate', 'Provo combined rate — VERIFY before demo. Applies to Utah orders only; shipping is not taxed.'),
  ('tax_state',               'UT',     'text',   'sales', 'Taxable state', null),
  ('byu_discount_pct',        '0.10',   'number', 'sales', 'BYU student discount', null),
  ('business_discount_pct',   '0.15',   'number', 'sales', 'Business bulk discount', null),
  ('business_discount_min_units', '25', 'number', 'sales', 'Business discount minimum units', null),
  ('max_manual_discount_pct', '0.50',   'number', 'sales', 'Largest manual discount allowed', 'Manual discounts also need a reason code.'),
  ('return_window_days',      '30',     'number', 'sales', 'Return window (days)', null),
  ('restocking_fee_pct',      '0.10',   'number', 'sales', 'Restocking fee', 'Charged on "changed my mind" refunds of made-to-order items.'),
  -- Fulfillment
  ('flat_shipping_fee',         '5.99', 'number', 'fulfillment', 'Flat shipping fee ($/order)', 'Charged to the customer on shipped orders.'),
  ('packaging_cost_per_order',  '0.70', 'number', 'fulfillment', 'Packaging cost ($/order)', 'Small box $0.45 + 2 tissue sheets $0.10 + thank-you card $0.15. Expensed on shipped and pickup orders.'),
  -- Ordering / holding
  ('ordering_cost',             '15',   'number', 'ordering', 'Ordering cost per PO (S)', 'Used in EOQ.'),
  ('service_level_z',           '1.65', 'number', 'ordering', 'Service level z', '1.65 = 95% service level. Used in reorder points.'),
  ('review_interval_days',      '14',   'number', 'ordering', 'Periodic review interval (days)', null),
  ('carrying_rate_annual',      '0.18', 'number', 'ordering', 'Annual carrying rate', 'Cost of capital 10% + insurance 1% + shrinkage 2% + obsolescence 5%. Used in EOQ.'),
  ('carrying_rate_seasonal',    '0.33', 'number', 'ordering', 'Annual carrying rate (seasonal items)', 'Obsolescence 20% instead of 5%.'),
  -- Inventory
  ('allow_negative_inventory',  'false', 'boolean', 'inventory', 'Allow negative inventory', 'Keep false: shortages become backorders instead.');

-- ---------------------------------------------------------------------------
-- Chart of accounts
-- ---------------------------------------------------------------------------
insert into public.accounts (code, name, type, pl_section, sort_order) values
  ('1000', 'Cash',                                   'asset',          'Current assets',      10),
  ('1100', 'Accounts receivable',                    'asset',          'Current assets',      20),
  ('1200', 'Inventory',                              'asset',          'Current assets',      30),
  ('1250', 'Work in process',                        'asset',          'Current assets',      40),
  ('2000', 'Accounts payable',                       'liability',      'Current liabilities', 50),
  ('2100', 'Sales tax payable',                      'liability',      'Current liabilities', 60),
  ('2300', 'Accrued production labor & machine',     'liability',      'Current liabilities', 70),
  ('3000', 'Owner''s equity',                        'equity',         'Equity',              80),
  ('4000', 'Product sales',                          'revenue',        'Revenue',            100),
  ('4100', 'Sales discounts',                        'contra_revenue', 'Revenue',            110),
  ('4400', 'Sales returns',                          'contra_revenue', 'Revenue',            120),
  ('4200', 'Shipping revenue',                       'revenue',        'Revenue',            130),
  ('4300', 'Restocking fees',                        'revenue',        'Revenue',            140),
  ('5000', 'Cost of goods sold',                     'cogs',           'Cost of sales',      200),
  ('5100', 'Packaging & fulfillment',                'expense',        'Cost of sales',      210),
  ('5200', 'Inventory adjustments (realized losses)','expense',        'Operating expenses', 300),
  ('5300', 'Production scrap',                       'expense',        'Operating expenses', 310);

-- ---------------------------------------------------------------------------
-- Reason codes (one table; category says where each is used)
-- ---------------------------------------------------------------------------
insert into public.reason_codes (code, category, description, is_quality, charges_restocking_fee, sort_order) values
  -- Inventory adjustments
  ('ADJ_CYCLE_COUNT',   'adjustment', 'Cycle count correction',              false, false, 10),
  ('ADJ_DAMAGED',       'adjustment', 'Damaged in storage',                  false, false, 20),
  ('ADJ_LOST',          'adjustment', 'Lost / missing',                      false, false, 30),
  ('ADJ_OBSOLETE',      'adjustment', 'Obsolete / out of season',            false, false, 40),
  ('ADJ_FOUND',         'adjustment', 'Found stock',                         false, false, 50),
  ('ADJ_QA_SCRAP',      'adjustment', 'Scrapped after QA inspection',        true,  false, 60),
  -- Returns
  ('RET_QUALITY_DEFECT','return',     'Quality defect',                      true,  false, 10),
  ('RET_DAMAGED_SHIP',  'return',     'Arrived damaged',                     true,  false, 20),
  ('RET_WRONG_ITEM',    'return',     'We sent the wrong item',              false, false, 30),
  ('RET_WRONG_COLOR',   'return',     'Customer wants a different color/product', false, false, 40),
  ('RET_CHANGED_MIND',  'return',     'Changed my mind',                     false, true,  50),
  -- Production scrap (print failures)
  ('SCRAP_WARPING',     'scrap',      'Warping',                             true,  false, 10),
  ('SCRAP_BED_ADHESION','scrap',      'Bed adhesion failure',                true,  false, 20),
  ('SCRAP_SPAGHETTI',   'scrap',      'Spaghetti / detached print',          true,  false, 30),
  ('SCRAP_LAYER_SHIFT', 'scrap',      'Layer shift',                         true,  false, 40),
  ('SCRAP_NOZZLE_CLOG', 'scrap',      'Nozzle clog',                         true,  false, 50),
  ('SCRAP_RUNOUT',      'scrap',      'Filament runout',                     true,  false, 60),
  ('SCRAP_STRINGING',   'scrap',      'Stringing / cosmetic reject',         true,  false, 70),
  ('SCRAP_POWER',       'scrap',      'Power or network loss',               true,  false, 80),
  ('SCRAP_ASSEMBLY',    'scrap',      'Damaged during assembly',             true,  false, 90),
  -- Manual discounts
  ('DISC_PRICE_MATCH',  'discount',   'Price match',                         false, false, 10),
  ('DISC_SERVICE',      'discount',   'Service recovery (made it right)',    false, false, 20),
  ('DISC_LOYALTY',      'discount',   'Loyal customer',                      false, false, 30),
  ('DISC_MANAGER',      'discount',   'Manager discretion',                  false, false, 40),
  -- Overrides (stretch: capacity model)
  ('OVR_CAPACITY',      'override',   'Over capacity, approved by manager',  false, false, 10);

-- ---------------------------------------------------------------------------
-- Locations (3 + QA Hold). Functions look these up by code.
-- ---------------------------------------------------------------------------
insert into public.locations (code, name, kind, is_sellable, capacity_cuft, sort_order) values
  ('PRINT_FARM',  'Stansbury Park Print Farm',        'production', true,  40,  10),
  ('FULFILLMENT', 'Stansbury Park Fulfillment Center','storage',    true,  120, 20),
  ('CAMPUS',      'BYU Campus Pickup Counter',        'retail',     true,  12,  30);

insert into public.locations (code, name, kind, is_sellable, capacity_cuft, parent_location_id, sort_order)
select 'QA_HOLD', 'QA Hold (Print Farm quarantine)', 'quarantine', false, 8, id, 40
  from public.locations where code = 'PRINT_FARM';
