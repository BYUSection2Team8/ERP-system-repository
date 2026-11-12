-- =============================================================================
-- 001_schema.sql — Poulson Prints ERP core tables
-- Run in Supabase -> SQL Editor. Never edit after it has been applied;
-- add a new numbered migration instead.
--
-- Design rules (see HANDOFF.md):
--   * On-hand quantities, costs and financials are NEVER stored as typed numbers.
--     They are derived from inventory_txn (stock movements) and ledger (money).
--   * Multi-step business actions are Postgres functions (004_functions.sql).
--   * Settings are key/value rows, reason codes are one table with a category.
--   * Nullable "room to grow" columns exist for stretch features.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Settings (key/value; new settings are new rows, not schema changes)
-- ---------------------------------------------------------------------------
create table public.settings (
  key          text primary key,
  value        text not null,
  type         text not null default 'number' check (type in ('number','text','boolean','json')),
  category     text not null default 'general',
  label        text,
  description  text,
  updated_at   timestamptz not null default now(),
  updated_by   uuid
);

-- ---------------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------------
create table public.locations (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,          -- e.g. PRINT_FARM, QA_HOLD
  name          text not null,
  kind          text not null default 'storage' check (kind in ('storage','production','retail','quarantine')),
  is_sellable   boolean not null default true,  -- QA Hold = false
  parent_location_id uuid references public.locations(id),
  capacity_cuft numeric(10,2),                  -- stretch: capacity model
  sort_order    int not null default 0,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

create table public.reason_codes (
  code         text primary key,                -- e.g. ADJ_DAMAGED, RET_QUALITY
  category     text not null check (category in ('adjustment','return','scrap','discount','override','print_failure')),
  description  text not null,
  is_quality   boolean not null default false,  -- quality failures -> QA Hold, no restocking fee
  charges_restocking_fee boolean not null default false,  -- "changed my mind" on made-to-order
  is_active    boolean not null default true,
  sort_order   int not null default 0
);

-- Chart of accounts for the ledger.
create table public.accounts (
  code         text primary key,                -- e.g. '1200'
  name         text not null,
  type         text not null check (type in ('asset','liability','equity','revenue','contra_revenue','cogs','expense')),
  pl_section   text,                            -- grouping label for the P&L / balance sheet
  sort_order   int not null default 0
);

-- ---------------------------------------------------------------------------
-- Parties
-- ---------------------------------------------------------------------------
create table public.suppliers (
  id               uuid primary key default gen_random_uuid(),
  name             text not null unique,
  contact_name     text,
  email            text,
  phone            text,
  website          text,
  address          text,
  quoted_lead_days int  not null default 7 check (quoted_lead_days >= 0),
  payment_terms    text not null default 'Net 30',  -- display text
  terms_days       int  not null default 30 check (terms_days >= 0),  -- 0 = paid at purchase
  notes            text,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now()
);

create sequence public.customer_no_seq start 1001;

create table public.customers (
  id            uuid primary key default gen_random_uuid(),
  customer_no   text not null unique default ('C-' || nextval('public.customer_no_seq')),
  name          text not null,                 -- person or business name
  contact_name  text,
  email         text,
  phone         text,
  address1      text,
  city          text,
  state         text,                          -- 2-letter; drives sales tax (UT only)
  postal_code   text,
  segment       text check (segment in ('student','gift_buyer','hobbyist','local_family','business','walk_in')),
  is_byu        boolean not null default false,
  terms_days    int not null default 0 check (terms_days >= 0),  -- businesses: Net 30
  notes         text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- User profiles (staff vs customer). One row per Supabase auth user.
-- ---------------------------------------------------------------------------
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  role         text not null default 'customer' check (role in ('staff','customer')),
  full_name    text,
  customer_id  uuid references public.customers(id),
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Items (finished goods + purchased components/filament/packaging)
-- Quantities are in the item's stock unit (uom): 'ea' or 'g' (filament).
-- No on-hand or average-cost columns: those are derived from inventory_txn.
-- ---------------------------------------------------------------------------
create table public.items (
  id                  uuid primary key default gen_random_uuid(),
  sku                 text not null unique,
  barcode             text not null unique,     -- Code 128 value printed on labels
  name                text not null,
  description         text,
  item_type           text not null check (item_type in ('finished','purchased')),
  category            text not null check (category in ('product','filament','component','packaging')),
  product_family      text,                     -- e.g. 'Dragon' groups the 4 colors
  color               text,
  uom                 text not null default 'ea' check (uom in ('ea','g')),
  price               numeric(12,2),            -- selling price (finished goods)
  stocking_policy     text not null default 'stock' check (stocking_policy in ('stock','make_to_order','seasonal','not_sold')),
  season_start        text,                     -- 'MM-DD' for seasonal items
  season_end          text,
  -- Production data (finished goods), per plate
  units_per_plate     int  not null default 1 check (units_per_plate > 0),
  print_minutes       numeric(10,2),            -- printer time per plate
  assembly_minutes    numeric(10,2) default 0,  -- assembly labor per plate
  color_changes       int not null default 0,   -- stretch: AMS purge waste
  -- Planning
  lead_time_days      int check (lead_time_days >= 0),  -- finished: production lead time; purchased: overrides supplier quote
  reorder_point_manual numeric(14,4),           -- optional manual override; computed ROP comes from history
  safety_stock_manual numeric(14,4),
  -- Fulfillment / size (stretch: box selection, capacity)
  packing_class       text check (packing_class in ('small','standard','multi_piece','fragile')),
  box_size            text check (box_size in ('small','medium','large')),
  length_in           numeric(8,2),
  width_in            numeric(8,2),
  height_in           numeric(8,2),
  weight_g            numeric(10,2),
  preferred_supplier_id uuid references public.suppliers(id),
  is_active           boolean not null default true,
  created_at          timestamptz not null default now()
);
create index on public.items (item_type, category);
create index on public.items (product_family);

-- What each supplier sells us, and in what purchase unit.
-- Filament: purchase_uom 'spool', stock_per_purchase_unit 985 (grams).
create table public.item_suppliers (
  item_id                 uuid not null references public.items(id) on delete cascade,
  supplier_id             uuid not null references public.suppliers(id),
  supplier_part_no        text,
  purchase_uom            text not null default 'ea',
  stock_per_purchase_unit numeric(12,4) not null default 1 check (stock_per_purchase_unit > 0),
  unit_cost               numeric(12,4) not null check (unit_cost >= 0),   -- per purchase unit
  lead_time_days          int check (lead_time_days >= 0),  -- null = supplier's quoted lead time
  min_order_qty           numeric(12,4) not null default 1,
  is_preferred            boolean not null default false,
  primary key (item_id, supplier_id)
);

-- Single-level bills of material. Quantity is per PLATE (one print job);
-- per-unit quantity = qty_per_plate / items.units_per_plate (see v_bom_per_unit).
create table public.boms (
  parent_item_id    uuid not null references public.items(id) on delete cascade,
  component_item_id uuid not null references public.items(id),
  qty_per_plate     numeric(14,4) not null check (qty_per_plate > 0),
  notes             text,
  primary key (parent_item_id, component_item_id),
  check (parent_item_id <> component_item_id)
);

-- ---------------------------------------------------------------------------
-- The two books: stock movements and money.
-- ---------------------------------------------------------------------------
create table public.journals (
  id           uuid primary key default gen_random_uuid(),
  posted_at    timestamptz not null default now(),
  source_type  text not null,   -- sale, sale_return, po_receipt, production_issue, ...
  source_id    uuid,
  memo         text,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index on public.journals (source_type, source_id);
create index on public.journals (posted_at);

create table public.ledger (
  id           bigint generated always as identity primary key,
  journal_id   uuid not null references public.journals(id),
  posted_at    timestamptz not null,
  account_code text not null references public.accounts(code),
  debit        numeric(14,2) not null default 0 check (debit >= 0),
  credit       numeric(14,2) not null default 0 check (credit >= 0),
  source_type  text not null,
  source_id    uuid,
  item_id      uuid references public.items(id),
  location_id  uuid references public.locations(id),
  customer_id  uuid references public.customers(id),
  supplier_id  uuid references public.suppliers(id),
  memo         text,
  check (debit = 0 or credit = 0)
);
create index on public.ledger (account_code, posted_at);
create index on public.ledger (journal_id);
create index on public.ledger (source_type, source_id);

create table public.inventory_txn (
  id             bigint generated always as identity primary key,
  txn_at         timestamptz not null default now(),
  item_id        uuid not null references public.items(id),
  location_id    uuid not null references public.locations(id),
  qty            numeric(14,4) not null check (qty <> 0),  -- + in, - out (stock uom)
  unit_cost      numeric(14,6) not null check (unit_cost >= 0),
  ext_cost       numeric(16,6) generated always as (qty * unit_cost) stored,
  source_type    text not null,  -- receipt, opening, sale, sale_return, transfer_out, transfer_in,
                                 -- adjustment, production_issue, production_output, ...
  source_id      uuid,
  source_line_id uuid,
  reason_code    text references public.reason_codes(code),
  journal_id     uuid references public.journals(id),
  note           text,
  created_by     uuid,
  created_at     timestamptz not null default now()
);
create index on public.inventory_txn (item_id, location_id);
create index on public.inventory_txn (item_id, txn_at);
create index on public.inventory_txn (source_type, source_id);
create index on public.inventory_txn (txn_at);

-- ---------------------------------------------------------------------------
-- Sales orders (POS sales are sales orders with channel = 'pos')
-- Rubric statuses: placed -> fulfilled -> closed, or cancelled.
-- Money columns are written by the functions (computed from lines + settings
-- at order time, e.g. the tax rate in force), never typed in by a user.
-- ---------------------------------------------------------------------------
create sequence public.so_no_seq start 10001;

create table public.sales_orders (
  id                 uuid primary key default gen_random_uuid(),
  order_no           text not null unique default ('SO-' || nextval('public.so_no_seq')),
  customer_id        uuid references public.customers(id),   -- null = walk-in POS
  channel            text not null default 'online' check (channel in ('pos','online','phone','portal')),
  fulfillment_method text not null default 'ship' check (fulfillment_method in ('ship','pickup','counter')),
  location_id        uuid not null references public.locations(id),  -- ships/picks from here
  status             text not null default 'placed' check (status in ('placed','fulfilled','closed','cancelled')),
  stage              text,                    -- stretch: detailed tracking stage
  tracking_token     text unique,             -- stretch: private tracking link
  order_date         timestamptz not null default now(),
  need_date          date,                    -- when the customer needs it (drives MRP)
  ship_state         text,                    -- tax: Utah orders only
  discount_type      text not null default 'none' check (discount_type in ('none','byu','business','manual')),
  discount_pct       numeric(6,4) not null default 0 check (discount_pct >= 0 and discount_pct <= 1),
  discount_reason    text references public.reason_codes(code),
  subtotal           numeric(12,2) not null default 0,   -- sum of qty * list price
  discount_amount    numeric(12,2) not null default 0,
  shipping_amount    numeric(12,2) not null default 0,
  tax_rate           numeric(7,5)  not null default 0,
  tax_amount         numeric(12,2) not null default 0,
  total              numeric(12,2) not null default 0,
  payment_method     text check (payment_method in ('cash','card','account','exchange')),
  customer_email     text,                    -- stretch: receipt / tracking email
  notes              text,
  fulfilled_at       timestamptz,
  closed_at          timestamptz,
  cancelled_at       timestamptz,
  cancel_reason      text,
  created_by         uuid,
  created_at         timestamptz not null default now()
);
create index on public.sales_orders (status);
create index on public.sales_orders (customer_id);
create index on public.sales_orders (order_date);

create table public.sales_order_lines (
  id             uuid primary key default gen_random_uuid(),
  so_id          uuid not null references public.sales_orders(id) on delete cascade,
  line_no        int not null,
  item_id        uuid not null references public.items(id),
  qty            numeric(14,4) not null check (qty > 0),
  unit_price     numeric(12,2) not null check (unit_price >= 0),  -- list price at order time
  net_unit_price numeric(12,4) not null,      -- after order discount (used for refunds)
  line_total     numeric(12,2) not null,      -- qty * unit_price (before discount)
  unit_cost      numeric(14,6),               -- weighted-average cost at fulfillment (COGS)
  qty_fulfilled  numeric(14,4) not null default 0,
  qty_returned   numeric(14,4) not null default 0,
  unique (so_id, line_no)
);
create index on public.sales_order_lines (item_id);

-- ---------------------------------------------------------------------------
-- Returns and exchanges
-- ---------------------------------------------------------------------------
create sequence public.rma_no_seq start 5001;

create table public.returns (
  id               uuid primary key default gen_random_uuid(),
  return_no        text not null unique default ('RMA-' || nextval('public.rma_no_seq')),
  so_id            uuid not null references public.sales_orders(id),
  customer_id      uuid references public.customers(id),
  return_type      text not null check (return_type in ('refund','exchange')),
  returned_at      timestamptz not null default now(),
  merchandise_credit numeric(12,2) not null default 0,  -- net price of returned goods
  tax_credit       numeric(12,2) not null default 0,
  restocking_fee   numeric(12,2) not null default 0,
  exchange_so_id   uuid references public.sales_orders(id),
  exchange_total   numeric(12,2) not null default 0,
  refund_amount    numeric(12,2) not null default 0,    -- + paid to customer, - collected
  notes            text,
  created_by       uuid,
  created_at       timestamptz not null default now()
);
create index on public.returns (so_id);

create table public.return_lines (
  id             uuid primary key default gen_random_uuid(),
  return_id      uuid not null references public.returns(id) on delete cascade,
  so_line_id     uuid not null references public.sales_order_lines(id),
  item_id        uuid not null references public.items(id),
  qty            numeric(14,4) not null check (qty > 0),
  reason_code    text not null references public.reason_codes(code),
  disposition    text not null check (disposition in ('restock','qa_hold')),
  location_id    uuid not null references public.locations(id),
  net_unit_price numeric(12,4) not null,
  unit_cost      numeric(14,6) not null
);

-- ---------------------------------------------------------------------------
-- Production orders (work orders)
-- planned -> in_progress (issued) -> completed, or cancelled.
-- ---------------------------------------------------------------------------
create sequence public.mo_no_seq start 3001;

create table public.production_orders (
  id                 uuid primary key default gen_random_uuid(),
  mo_no              text not null unique default ('MO-' || nextval('public.mo_no_seq')),
  item_id            uuid not null references public.items(id),
  qty_planned        numeric(14,4) not null check (qty_planned > 0),
  plates             int not null check (plates > 0),
  location_id        uuid not null references public.locations(id),        -- where it is built / components consumed
  output_location_id uuid not null references public.locations(id),        -- where good units are received
  status             text not null default 'planned' check (status in ('planned','in_progress','completed','cancelled')),
  so_id              uuid references public.sales_orders(id),  -- made-to-order link
  due_date           date,
  printer_id         uuid,                                     -- stretch: printers table
  qty_started        numeric(14,4) not null default 0,
  qty_good           numeric(14,4) not null default 0,
  qty_scrap          numeric(14,4) not null default 0,
  scrap_reason       text references public.reason_codes(code),
  started_at         timestamptz,
  finished_at        timestamptz,
  material_cost      numeric(14,4) not null default 0,   -- from components issued
  labor_cost         numeric(14,4) not null default 0,   -- from settings at completion
  machine_cost       numeric(14,4) not null default 0,
  unit_cost          numeric(14,6),                      -- rolled-up cost per unit started
  notes              text,
  created_by         uuid,
  created_at         timestamptz not null default now()
);
create index on public.production_orders (status);
create index on public.production_orders (item_id);
create index on public.production_orders (finished_at);

create table public.production_order_components (
  mo_id          uuid not null references public.production_orders(id) on delete cascade,
  item_id        uuid not null references public.items(id),
  qty_required   numeric(14,4) not null,
  qty_issued     numeric(14,4) not null default 0,
  unit_cost      numeric(14,6),
  primary key (mo_id, item_id)
);

-- ---------------------------------------------------------------------------
-- Purchasing
-- Rubric statuses: sent -> received -> closed (plus draft, partial, cancelled).
-- ---------------------------------------------------------------------------
create sequence public.po_no_seq start 7001;

create table public.purchase_orders (
  id               uuid primary key default gen_random_uuid(),
  po_no            text not null unique default ('PO-' || nextval('public.po_no_seq')),
  supplier_id      uuid not null references public.suppliers(id),
  status           text not null default 'draft' check (status in ('draft','sent','partial','received','closed','cancelled')),
  ship_to_location_id uuid not null references public.locations(id),
  order_date       timestamptz,          -- when sent
  lead_days        int,                  -- quoted lead time snapshot at send
  expected_date    date,                 -- order_date + lead_days
  terms_days       int not null default 30,  -- snapshot of supplier terms
  source           text not null default 'manual' check (source in ('manual','mrp','reorder','review')),
  notes            text,
  closed_at        timestamptz,
  created_by       uuid,
  created_at       timestamptz not null default now()
);
create index on public.purchase_orders (supplier_id);
create index on public.purchase_orders (status);

create table public.purchase_order_lines (
  id                      uuid primary key default gen_random_uuid(),
  po_id                   uuid not null references public.purchase_orders(id) on delete cascade,
  line_no                 int not null,
  item_id                 uuid not null references public.items(id),
  qty_ordered             numeric(14,4) not null check (qty_ordered > 0),  -- purchase units (spools, ea)
  purchase_uom            text not null default 'ea',
  stock_per_purchase_unit numeric(12,4) not null default 1 check (stock_per_purchase_unit > 0),
  unit_cost               numeric(12,4) not null check (unit_cost >= 0),   -- per purchase unit
  qty_received            numeric(14,4) not null default 0,               -- purchase units
  need_date               date,                                           -- from MRP
  unique (po_id, line_no)
);
create index on public.purchase_order_lines (item_id);

create table public.po_receipts (
  id           uuid primary key default gen_random_uuid(),
  po_id        uuid not null references public.purchase_orders(id),
  received_at  timestamptz not null default now(),
  location_id  uuid not null references public.locations(id),
  amount       numeric(12,2) not null default 0,
  due_date     date,                 -- received date + terms days (AP)
  notes        text,
  created_by   uuid
);
create index on public.po_receipts (po_id);

create table public.po_receipt_lines (
  receipt_id   uuid not null references public.po_receipts(id) on delete cascade,
  po_line_id   uuid not null references public.purchase_order_lines(id),
  qty_received numeric(14,4) not null check (qty_received > 0),   -- purchase units
  primary key (receipt_id, po_line_id)
);

create table public.supplier_payments (
  id           uuid primary key default gen_random_uuid(),
  supplier_id  uuid not null references public.suppliers(id),
  receipt_id   uuid references public.po_receipts(id),
  amount       numeric(12,2) not null check (amount > 0),
  paid_at      timestamptz not null default now(),
  method       text,
  created_by   uuid
);
create index on public.supplier_payments (supplier_id);

-- ---------------------------------------------------------------------------
-- Activity log (written by every business function; feed UI is stretch)
-- ---------------------------------------------------------------------------
create table public.activity_log (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  user_id      uuid,
  actor        text,
  action       text not null,      -- e.g. 'sale.completed'
  entity_type  text,
  entity_id    uuid,
  summary      text not null,
  link         text                -- app route, e.g. '/sales/<id>'
);
create index on public.activity_log (at desc);
