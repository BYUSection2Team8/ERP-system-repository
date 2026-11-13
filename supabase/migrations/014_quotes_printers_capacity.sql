-- =============================================================================
-- 014_quotes_printers_capacity.sql — more wow factors (Phase 10)
--
-- 4) Custom quote calculator: price a one-off print from print hours, grams,
--    color and assembly time; one click turns the quote into a real made-to-order
--    item (with a BOM), a sales order and a planned production order, so MRP,
--    tracking, costing and the P&L all work exactly like for catalog items.
--      price/unit = max(minimum, (filament + machine + labor + packaging share
--                   + failure allowance) x markup); the failure allowance uses the
--                   actual scrap rate of recent production.
-- 5) Printers: the 4 P2S printers as records; a print goes to the least busy
--    printer when it starts; printer board, utilization, failures by printer.
-- 7) Capacity: cubic feet used per location (item size x quantity on hand) and the
--    Print Farm filament rack (spools), with warning levels. Warn, never block.
-- =============================================================================

insert into public.settings (key, value, type, category, label, description) values
  ('quote_markup',              '2.5',  'number', 'quotes',   'Custom quote markup (x cost)', 'Price = cost x markup, at least the minimum.'),
  ('quote_minimum_price',       '10',   'number', 'quotes',   'Custom quote minimum price ($ per unit)', null),
  ('quote_failure_window_days', '180',  'number', 'quotes',   'Failure history for quotes (days)', 'Failure allowance = scrap rate of production completed in this many days.'),
  ('filament_rack_spools',      '60',   'number', 'capacity', 'Filament rack capacity (spools)', 'Print Farm filament rack.'),
  ('capacity_warn_pct',         '0.85', 'number', 'capacity', 'Capacity warning level', 'Yellow above this share of capacity; red above 100%. Never blocks.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Printers
-- ---------------------------------------------------------------------------
create table if not exists public.printers (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  model       text,
  is_active   boolean not null default true,
  notes       text,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);
alter table public.printers enable row level security;
drop policy if exists staff_read on public.printers;
drop policy if exists staff_write on public.printers;
create policy staff_read on public.printers for select to authenticated using (public.is_staff());
create policy staff_write on public.printers for all to authenticated using (public.is_staff()) with check (public.is_staff());
revoke all on public.printers from anon;

insert into public.printers (code, name, model, sort_order) values
  ('P2S-1', 'Printer 1', 'Bambu Lab P2S + AMS', 1),
  ('P2S-2', 'Printer 2', 'Bambu Lab P2S + AMS', 2),
  ('P2S-3', 'Printer 3', 'Bambu Lab P2S + AMS', 3),
  ('P2S-4', 'Printer 4', 'Bambu Lab P2S + AMS', 4)
on conflict (code) do nothing;

-- Prints that already ran (the generated history) get a printer. The seed's
-- story is that one printer was overdue for maintenance mid-Sept to mid-Oct, so
-- that window's nozzle clogs and layer shifts go to Printer 3; the rest spread
-- evenly. (Simulated history, like the rest of the six months.)
update public.production_orders mo
   set printer_id = (select p.id from public.printers p where p.code = 'P2S-' ||
         case when mo.scrap_reason in ('SCRAP_NOZZLE_CLOG', 'SCRAP_LAYER_SHIFT')
                   and to_char(mo.started_at at time zone 'America/Denver', 'MM-DD') between '09-15' and '10-20' then 3
              else 1 + abs(hashtext(mo.id::text)) % 4 end)
 where mo.printer_id is null and mo.status in ('in_progress', 'completed') and mo.started_at is not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'production_orders_printer_fk') then
    alter table public.production_orders
      add constraint production_orders_printer_fk foreign key (printer_id) references public.printers(id);
  end if;
end $$;
create index if not exists production_orders_printer_idx on public.production_orders (printer_id);

-- When a print starts, put it on the active printer with the fewest running jobs.
create or replace function public._assign_printer()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'in_progress' and old.status = 'planned' and new.printer_id is null then
    select p.id into new.printer_id
      from printers p
     where p.is_active
     order by (select count(*) from production_orders mo where mo.printer_id = p.id and mo.status = 'in_progress'), p.sort_order
     limit 1;
  end if;
  return new;
end;
$$;
drop trigger if exists production_orders_assign_printer on public.production_orders;
create trigger production_orders_assign_printer
  before update of status on public.production_orders
  for each row execute function public._assign_printer();

-- Move a planned or running print to another printer.
create or replace function public.assign_printer(p_mo_id uuid, p_printer_id uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare mo production_orders%rowtype; v_name text;
begin
  perform public._require_staff();
  select * into mo from production_orders where id = p_mo_id for update;
  if not found then raise exception 'Unknown production order.'; end if;
  if mo.status not in ('planned', 'in_progress') then
    raise exception '% is %; only planned or running prints can move.', mo.mo_no, mo.status;
  end if;
  select name into v_name from printers where id = p_printer_id and is_active;
  if not found then raise exception 'Choose an active printer.'; end if;
  update production_orders set printer_id = p_printer_id where id = mo.id;
  perform public._log('production.printer', 'production_order', mo.id, format('%s moved to %s', mo.mo_no, v_name),
    '/production/' || mo.id, now());
end;
$$;

-- Estimated finish of a running print (same rule as the tracking page):
-- start + ceil(plates / printers) x print minutes + plates x assembly minutes.
create or replace function public.mo_estimated_finish(p_mo_id uuid)
returns timestamptz
language sql stable
set search_path = public, pg_temp
as $$
  select mo.started_at + make_interval(mins => (ceil(mo.plates::numeric / greatest(public.setting_num('printer_count'), 1))
                                                 * coalesce(i.print_minutes, 60) + mo.plates * coalesce(i.assembly_minutes, 0))::int)
    from public.production_orders mo join public.items i on i.id = mo.item_id
   where mo.id = p_mo_id;
$$;

-- Printer use over a date range: jobs, units, scrap and utilization
-- (busy hours = start to finish, or to now if still printing, clipped to the
--  range; utilization = busy hours / hours in the range up to now).
create or replace function public.printer_stats(p_from date, p_to date)
returns table (printer_id uuid, code text, name text, jobs bigint, units_started numeric, units_scrapped numeric,
               scrap_rate numeric, busy_hours numeric, utilization numeric)
language sql stable
set search_path = public, pg_temp
as $$
with r as (
  select (p_from::timestamp at time zone public.setting_text('time_zone')) as t0,
         least(now(), ((p_to + 1)::timestamp at time zone public.setting_text('time_zone'))) as t1
), j as (
  select mo.printer_id, mo.qty_started, mo.qty_scrap, mo.status,
         greatest(mo.started_at, r.t0) as s, least(coalesce(mo.finished_at, now()), r.t1) as f
    from public.production_orders mo cross join r
   where mo.printer_id is not null and mo.started_at is not null
     and mo.started_at <= r.t1 and coalesce(mo.finished_at, now()) >= r.t0
)
select p.id, p.code, p.name, count(j.printer_id),
       coalesce(sum(j.qty_started) filter (where j.status = 'completed'), 0),
       coalesce(sum(j.qty_scrap) filter (where j.status = 'completed'), 0),
       round(sum(j.qty_scrap) filter (where j.status = 'completed')
             / nullif(sum(j.qty_started) filter (where j.status = 'completed'), 0), 4),
       round(coalesce(sum(extract(epoch from (j.f - j.s)) / 3600.0), 0), 1),
       round(coalesce(sum(extract(epoch from (j.f - j.s)) / 3600.0), 0)
             / nullif(extract(epoch from ((select r.t1 from r) - (select r.t0 from r))) / 3600.0, 0), 4)
  from public.printers p
  left join j on j.printer_id = p.id
 where p.is_active
 group by p.id, p.code, p.name, p.sort_order
 order by p.sort_order;
$$;

-- ---------------------------------------------------------------------------
-- Print failure analytics, now also by printer (replaces 013's version).
-- ---------------------------------------------------------------------------
create or replace function public.print_failure_analytics(p_from date, p_to date)
returns table (dimension text, key text, label text, orders bigint, failed_orders bigint, units_started numeric,
               units_scrapped numeric, scrap_rate numeric, wasted_grams numeric, scrap_cost numeric)
language sql stable
set search_path = public, pg_temp
as $$
with mo as (
  select v.id, coalesce(v.product_family, v.item_name) as fam, coalesce(i.color, 'Multicolor') as color,
         coalesce(pr.name, 'Not assigned') as printer,
         v.scrap_reason, v.report_date, v.qty_started, v.qty_scrap, v.scrap_cost,
         coalesce((select sum(c.qty_issued) from public.production_order_components c
                     join public.items ci on ci.id = c.item_id
                    where c.mo_id = v.id and ci.category = 'filament'), 0)
           * v.qty_scrap / nullif(v.qty_started, 0) as grams
    from public.v_production_orders v
    join public.items i on i.id = v.item_id
    join public.production_orders po on po.id = v.id
    left join public.printers pr on pr.id = po.printer_id
   where v.status = 'completed' and v.report_date between p_from and p_to
), tot as (
  select coalesce(sum(qty_started), 0) as started from mo
), g as (
  select 'total' as dim, 'all' as k, 'All production' as lbl, mo.* from mo
  union all select 'product', fam, fam, mo.* from mo
  union all select 'color', color, color, mo.* from mo
  union all select 'printer', printer, printer, mo.* from mo
  union all select 'week', to_char(date_trunc('week', report_date), 'YYYY-MM-DD'),
                   'Week of ' || to_char(date_trunc('week', report_date), 'Mon FMDD'), mo.* from mo
)
select g.dim, g.k, g.lbl, count(*), count(*) filter (where g.qty_scrap > 0), sum(g.qty_started), sum(g.qty_scrap),
       round(sum(g.qty_scrap) / nullif(sum(g.qty_started), 0), 4), round(sum(g.grams), 1), coalesce(sum(g.scrap_cost), 0)
  from g group by g.dim, g.k, g.lbl
union all
select 'reason', r.code, r.description, count(*), count(*), (select started from tot), sum(mo.qty_scrap),
       round(sum(mo.qty_scrap) / nullif((select started from tot), 0), 4), round(sum(mo.grams), 1), coalesce(sum(mo.scrap_cost), 0)
  from mo join public.reason_codes r on r.code = mo.scrap_reason
 where mo.qty_scrap > 0
 group by r.code, r.description;
$$;

-- ---------------------------------------------------------------------------
-- Capacity: cubic feet of finished goods on hand per location (length x width
-- x height x qty / 1728) and filament spools on the Print Farm rack.
-- ---------------------------------------------------------------------------
create or replace view public.v_location_utilization with (security_invoker = true) as
with prod as (
  select t.location_id, sum(t.qty * coalesce(i.length_in * i.width_in * i.height_in, 0)) / 1728.0 as cuft
    from public.inventory_txn t join public.items i on i.id = t.item_id
   where i.category = 'product'
   group by t.location_id
), fil as (
  select t.location_id, sum(t.qty) / public.setting_num('spool_grams') as spools
    from public.inventory_txn t join public.items i on i.id = t.item_id
   where i.category = 'filament'
   group by t.location_id
)
select l.id as location_id, l.code, l.name, l.capacity_cuft,
       round(coalesce(prod.cuft, 0), 2) as used_cuft,
       round(coalesce(prod.cuft, 0) / nullif(l.capacity_cuft, 0), 4) as utilization,
       round(coalesce(fil.spools, 0), 1) as spools,
       case when l.code = 'PRINT_FARM' then public.setting_num('filament_rack_spools') end as rack_spools,
       case when l.code = 'PRINT_FARM'
            then round(coalesce(fil.spools, 0) / nullif(public.setting_num('filament_rack_spools'), 0), 4) end as rack_utilization,
       public.setting_num('capacity_warn_pct') as warn_pct
  from public.locations l
  left join prod on prod.location_id = l.id
  left join fil on fil.location_id = l.id
 where l.is_active;

-- ---------------------------------------------------------------------------
-- Custom quote calculator
-- ---------------------------------------------------------------------------
alter table public.items add column if not exists is_custom boolean not null default false;
create sequence if not exists public.custom_item_seq start 1001;

-- Customers see catalog products, and custom items only when they ordered them.
drop policy if exists catalog_read on public.items;
create policy catalog_read on public.items for select to authenticated using (
  is_active and category = 'product'
  and (not is_custom or exists (select 1 from public.sales_order_lines l join public.sales_orders so on so.id = l.so_id
                                 where l.item_id = items.id and so.customer_id = public.my_customer_id())));

-- p = {name, description?, print_hours, grams, color (Red/White/Blue/Black),
--      assembly_minutes?, qty?, fulfillment_method (pickup|ship), ship_state?}
-- Returns the whole calculation with every input, for the "show the math" panel.
create or replace function public._custom_quote(p jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_name   text := left(trim(coalesce(p->>'name', '')), 40);
  v_hours  numeric;
  v_grams  numeric;
  v_asm    numeric;
  v_qty    numeric;
  v_color  text := initcap(trim(coalesce(p->>'color', '')));
  v_method text := coalesce(nullif(p->>'fulfillment_method', ''), 'pickup');
  v_state  text;
  v_fil    items%rowtype;
  v_cg     numeric;
  v_rm     numeric := public.machine_rate_per_hour();
  v_rl     numeric := public.setting_num('labor_rate');
  v_setup  numeric := public.setting_num('setup_minutes_per_plate') + public.setting_num('cleanup_minutes_per_plate');
  v_pack   numeric := public.setting_num('packaging_cost_per_order');
  v_markup numeric := public.setting_num('quote_markup');
  v_min    numeric := public.setting_num('quote_minimum_price');
  v_days   int := public.setting_num('quote_failure_window_days')::int;
  v_printers int := greatest(public.setting_num('printer_count'), 1)::int;
  v_tz     text := public.setting_text('time_zone');
  v_fail   numeric;
  v_started numeric;
  v_scrapped numeric;
  c_fil numeric; c_mach numeric; c_lab numeric; c_pack numeric; c_base numeric; c_allow numeric; c_unit numeric;
  v_price numeric; v_sub numeric; v_ship numeric := 0; v_rate numeric := 0; v_tax numeric;
  v_queue numeric; v_start timestamptz; v_finish timestamptz; v_local timestamp; v_ready date; v_deliver date;
begin
  if v_name = '' then raise exception 'Give the design a name.'; end if;
  if coalesce(p->>'print_hours', '') !~ '^\s*\d+(\.\d+)?\s*$' then raise exception 'Enter the print time in hours (for example 2.5).'; end if;
  v_hours := (p->>'print_hours')::numeric;
  if v_hours <= 0 or v_hours > 48 then raise exception 'Print time must be more than 0 and at most 48 hours.'; end if;
  if coalesce(p->>'grams', '') !~ '^\s*\d+(\.\d+)?\s*$' then raise exception 'Enter the filament weight in grams.'; end if;
  v_grams := (p->>'grams')::numeric;
  if v_grams <= 0 or v_grams > 2000 then raise exception 'Filament must be more than 0 and at most 2,000 g.'; end if;
  if coalesce(p->>'assembly_minutes', '') = '' then
    v_asm := 0;
  elsif p->>'assembly_minutes' !~ '^\s*\d+(\.\d+)?\s*$' then
    raise exception 'Assembly time must be a number of minutes.';
  else
    v_asm := (p->>'assembly_minutes')::numeric;
  end if;
  if v_asm > 240 then raise exception 'Assembly time must be at most 240 minutes.'; end if;
  if coalesce(nullif(p->>'qty', ''), '1') !~ '^\s*\d+\s*$' then raise exception 'Quantity must be a whole number.'; end if;
  v_qty := coalesce(nullif(p->>'qty', ''), '1')::numeric;
  if v_qty < 1 or v_qty > 50 then raise exception 'Quantity must be from 1 to 50 (for more, ask for a bulk quote).'; end if;
  if v_method not in ('pickup', 'ship') then raise exception 'Choose pickup or shipping.'; end if;

  select * into v_fil from items where sku = 'FIL-PLA-' || upper(v_color) and category = 'filament' and is_active;
  if not found then raise exception 'Choose a filament color (Red, White, Blue or Black).'; end if;
  v_cg := public.item_unit_cost(v_fil.id);

  -- Failure allowance from real production history (capped at 50%).
  select coalesce(sum(qty_started), 0), coalesce(sum(qty_scrap), 0) into v_started, v_scrapped
    from production_orders where status = 'completed' and finished_at >= now() - make_interval(days => v_days);
  v_fail := case when v_started > 0 then least(v_scrapped / v_started, 0.5) else 0 end;

  c_fil   := round(v_grams * v_cg, 4);
  c_mach  := round(v_hours * v_rm, 4);
  c_lab   := round((v_setup + v_asm) / 60.0 * v_rl, 4);
  c_pack  := round(v_pack / v_qty, 4);
  c_base  := c_fil + c_mach + c_lab;
  c_allow := round(c_base * v_fail / (1 - v_fail), 4);   -- expected cost of reprints
  c_unit  := c_base + c_pack + c_allow;
  v_price := greatest(v_min, round(c_unit * v_markup, 2));
  v_sub   := v_price * v_qty;

  if v_method = 'ship' then
    v_state := upper(nullif(trim(coalesce(p->>'ship_state', '')), ''));
    if v_state is null or v_state !~ '^[A-Z]{2}$' then raise exception 'Enter the 2-letter ship-to state.'; end if;
    v_ship := public.setting_num('flat_shipping_fee');
  else
    v_state := upper(public.setting_text('tax_state'));
  end if;
  if v_state = upper(public.setting_text('tax_state')) then v_rate := public.setting_num('sales_tax_rate'); end if;
  v_tax := round(v_sub * v_rate, 2);

  -- Ready date: wait for the print queue (remaining print hours of running and
  -- planned prints, spread over the printers), then print, then assemble. A print
  -- that ends outside staff hours is finished at the next day start.
  select coalesce(sum(greatest(0,
           mo.plates * coalesce(i.print_minutes, 60) / 60.0
           - case when mo.status = 'in_progress' then extract(epoch from (now() - mo.started_at)) / 3600.0 else 0 end)), 0)
    into v_queue
    from production_orders mo join items i on i.id = mo.item_id
   where mo.status in ('planned', 'in_progress');
  v_queue  := v_queue / v_printers;
  v_start  := now() + make_interval(mins => (v_queue * 60)::int);
  v_finish := v_start + make_interval(mins => (ceil(v_qty / v_printers) * v_hours * 60 + v_qty * v_asm)::int);
  v_local  := v_finish at time zone v_tz;
  if extract(hour from v_local) >= public.setting_num('staff_day_end_hour') then
    v_local := v_local::date + 1 + make_interval(hours => public.setting_num('staff_day_start_hour')::int);
  elsif extract(hour from v_local) < public.setting_num('staff_day_start_hour') then
    v_local := v_local::date + make_interval(hours => public.setting_num('staff_day_start_hour')::int);
  end if;
  v_finish := v_local at time zone v_tz;
  v_ready  := v_local::date;
  if v_method = 'ship' then v_deliver := v_ready + 1 + public.setting_num('transit_days_estimate')::int; end if;

  return jsonb_build_object(
    'name', v_name, 'description', left(nullif(trim(p->>'description'), ''), 300),
    'print_hours', v_hours, 'grams', v_grams, 'assembly_minutes', v_asm, 'qty', v_qty,
    'color', v_color, 'filament_item_id', v_fil.id, 'fulfillment_method', v_method, 'ship_state', v_state,
    'inputs', jsonb_build_object('filament_cost_per_g', v_cg, 'machine_rate_per_hour', round(v_rm, 4),
              'labor_rate', v_rl, 'setup_cleanup_minutes', v_setup, 'packaging_per_order', v_pack,
              'markup', v_markup, 'minimum_price', v_min, 'failure_rate', round(v_fail, 4),
              'failure_window_days', v_days, 'units_started', v_started, 'units_scrapped', v_scrapped,
              'printers', v_printers, 'queue_hours', round(v_queue, 1), 'tax_rate', v_rate),
    'cost', jsonb_build_object('filament', c_fil, 'machine', c_mach, 'labor', c_lab, 'packaging', c_pack,
              'failure_allowance', c_allow, 'unit_cost', round(c_unit, 4)),
    'unit_price', v_price, 'minimum_applied', round(c_unit * v_markup, 2) < v_min,
    'subtotal', v_sub, 'shipping_amount', v_ship, 'tax_amount', v_tax, 'total', v_sub + v_ship + v_tax,
    'ready_at', v_finish, 'ready_date', v_ready, 'est_delivery_date', v_deliver);
end;
$$;

-- Preview a custom quote (staff and signed-in customers; saves nothing).
create or replace function public.quote_custom_print(p jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform public._require_signed_in();
  return public._custom_quote(p);
end;
$$;

-- Turn a quote into a real item + BOM + sales order + planned production order.
create or replace function public._create_custom_order(p jsonb, p_customer uuid, p_channel text)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  q      jsonb := public._custom_quote(p);
  v_item uuid;
  v_sku  text := 'CUST-' || nextval('public.custom_item_seq');
  v_so   uuid;
  v_mo   uuid;
  v_no   text;
  v_qty  numeric := (q->>'qty')::numeric;
begin
  insert into items (sku, barcode, name, description, item_type, category, product_family, color, uom, price,
                     stocking_policy, units_per_plate, print_minutes, assembly_minutes, lead_time_days, is_custom)
  values (v_sku, 'PP-' || v_sku, 'Custom: ' || (q->>'name'), q->>'description', 'finished', 'product',
          'Custom print', q->>'color', 'ea', (q->>'unit_price')::numeric, 'make_to_order', 1,
          round((q->>'print_hours')::numeric * 60, 2), (q->>'assembly_minutes')::numeric, 2, true)
  returning id into v_item;
  insert into boms (parent_item_id, component_item_id, qty_per_plate)
  values (v_item, (q->>'filament_item_id')::uuid, (q->>'grams')::numeric);

  v_so := public._insert_sales_order(jsonb_build_object(
    'customer_id', p_customer, 'channel', p_channel, 'fulfillment_method', q->>'fulfillment_method',
    'ship_state', q->>'ship_state', 'location_id', nullif(p->>'location_id', ''),
    'location_code', case when q->>'fulfillment_method' = 'ship' then 'FULFILLMENT' else 'CAMPUS' end,
    'need_date', q->>'ready_date', 'notes', left(nullif(trim(p->>'notes'), ''), 500),
    'payment_method', nullif(p->>'payment_method', ''),
    'lines', jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', v_qty))));

  -- Planned production order for the custom item (one plate per unit).
  insert into production_orders (item_id, qty_planned, plates, location_id, output_location_id, status, so_id, due_date, notes, created_by)
  values (v_item, v_qty, v_qty::int, public._location_id('PRINT_FARM'), public._location_id('FULFILLMENT'),
          'planned', v_so, (q->>'ready_date')::date, 'Custom print from a quote', auth.uid())
  returning id, mo_no into v_mo, v_no;
  insert into production_order_components (mo_id, item_id, qty_required)
  values (v_mo, (q->>'filament_item_id')::uuid, (q->>'grams')::numeric * v_qty);
  perform public._log('production.created', 'production_order', v_mo,
    format('%s planned: %s x Custom: %s (from a quote)', v_no, trim_scale(v_qty), q->>'name'), '/production/' || v_mo, now());
  return v_so;
end;
$$;

-- Staff: p also has customer_id (and optional location_id, payment_method).
create or replace function public.create_custom_print_order(p jsonb)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform public._require_staff();
  if coalesce(p->>'customer_id', '') !~ '^[0-9a-fA-F-]{36}$' then raise exception 'Choose a customer for this order.'; end if;
  return public._create_custom_order(p, (p->>'customer_id')::uuid, 'phone');
end;
$$;

-- Customer portal: own account, pickup at a pickup location, pay at pickup / on account.
create or replace function public.portal_create_custom_print_order(p jsonb)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_cust customers%rowtype; v_loc uuid;
begin
  if auth.uid() is null then raise exception 'Please sign in first.' using errcode = '42501'; end if;
  select c.* into v_cust from customers c where c.id = public.my_customer_id() and c.is_active;
  if not found then raise exception 'Your login is not linked to a customer account yet. Please contact Poulson Prints.'; end if;
  select l.id into v_loc from locations l
   where l.id = case when coalesce(p->>'location_id', '') ~ '^[0-9a-fA-F-]{36}$' then (p->>'location_id')::uuid end
     and l.is_active and l.is_sellable and l.kind in ('retail', 'storage');
  if v_loc is null then raise exception 'Choose a pickup location.'; end if;
  return public._create_custom_order(
    jsonb_build_object('name', p->'name', 'description', p->'description', 'print_hours', p->'print_hours',
      'grams', p->'grams', 'color', p->'color', 'assembly_minutes', p->'assembly_minutes', 'qty', p->'qty',
      'fulfillment_method', 'pickup', 'location_id', v_loc, 'notes', p->'notes',
      'payment_method', case when v_cust.terms_days > 0 then 'account' else 'card' end),
    v_cust.id, 'portal');
end;
$$;

-- Portal catalog and portal orders never include other customers' custom items
-- (same functions as 012, plus "not is_custom").
create or replace function public.portal_catalog()
returns table (item_id uuid, sku text, barcode text, name text, description text, product_family text,
               color text, price numeric, stocking_policy text, lead_time_days int,
               location_id uuid, location_code text, location_name text,
               qty_available numeric, est_available_date date)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v_today date := public._local_date(now());
begin
  perform public._require_signed_in();
  return query
  select i.id, i.sku, i.barcode, i.name, i.description, i.product_family, i.color, i.price,
         i.stocking_policy, i.lead_time_days,
         l.id, l.code, l.name,
         greatest(coalesce(a.qty_available, 0), 0),
         case when coalesce(a.qty_available, 0) <= 0 then public.estimate_available_date(i.id) end
    from items i
    cross join locations l
    left join v_availability a on a.item_id = i.id and a.location_id = l.id
   where i.category = 'product' and i.is_active and i.price is not null
     and i.stocking_policy <> 'not_sold' and not i.is_custom
     and public._in_season(i.stocking_policy, i.season_start, i.season_end, v_today)
     and l.is_active and l.is_sellable and l.kind in ('retail','storage')
   order by i.product_family nulls last, i.name, l.sort_order;
end;
$$;

create or replace function public._portal_order_payload(p jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_cust  customers%rowtype;
  v_loc   locations%rowtype;
  v_item  items%rowtype;
  v_today date := public._local_date(now());
  v_lines jsonb := '[]'::jsonb;
  v_units numeric := 0;
  v_qty   numeric;
  v_need  date;
  v_dtype text := 'none';
  r       jsonb;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.' using errcode = '42501';
  end if;
  select c.* into v_cust from customers c where c.id = public.my_customer_id() and c.is_active;
  if not found then
    raise exception 'Your login is not linked to a customer account yet. Please contact Poulson Prints.';
  end if;
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') = 0 then
    raise exception 'Add at least one item to your order.';
  end if;
  if jsonb_array_length(p->'lines') > 50 then
    raise exception 'Please keep an online order to 50 lines or fewer.';
  end if;

  select l.* into v_loc from locations l
   where l.id = case when coalesce(p->>'location_id', '') ~ '^[0-9a-fA-F-]{36}$' then (p->>'location_id')::uuid end
     and l.is_active and l.is_sellable and l.kind in ('retail','storage');
  if not found then raise exception 'Choose a pickup location.'; end if;

  for r in select * from jsonb_array_elements(p->'lines') loop
    if coalesce(r->>'item_id', '') !~ '^[0-9a-fA-F-]{36}$' then
      raise exception 'One of the items is not available to order online.';
    end if;
    select i.* into v_item from items i where i.id = (r->>'item_id')::uuid;
    if not found or v_item.category <> 'product' or not v_item.is_active or v_item.price is null
       or v_item.stocking_policy = 'not_sold' or v_item.is_custom
       or not public._in_season(v_item.stocking_policy, v_item.season_start, v_item.season_end, v_today) then
      raise exception 'One of the items is not available to order online.';
    end if;
    if coalesce(r->>'qty', '') !~ '^\s*\d+\s*$' then
      raise exception 'Quantity of % must be a whole number.', v_item.name;
    end if;
    v_qty := (r->>'qty')::numeric;
    if v_qty < 1 then raise exception 'Quantity of % must be at least 1.', v_item.name; end if;
    if v_qty > 500 then
      raise exception 'For more than 500 of % please contact us for a bulk quote.', v_item.name;
    end if;
    v_units := v_units + v_qty;
    v_lines := v_lines || jsonb_build_object('item_id', v_item.id, 'qty', v_qty);
  end loop;

  if coalesce(p->>'need_date', '') <> '' then
    if p->>'need_date' !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Enter a valid date you need the order by.'; end if;
    v_need := (p->>'need_date')::date;
    if v_need < v_today then raise exception 'The date you need it by cannot be in the past.'; end if;
  end if;

  if v_cust.is_byu then
    v_dtype := 'byu';
  elsif v_cust.segment = 'business' and v_units >= public.setting_num('business_discount_min_units') then
    v_dtype := 'business';
  end if;

  return jsonb_build_object(
    'customer_id', v_cust.id, 'channel', 'portal', 'fulfillment_method', 'pickup',
    'location_id', v_loc.id, 'discount_type', v_dtype,
    'payment_method', case when v_cust.terms_days > 0 then 'account' else 'card' end,
    'need_date', v_need, 'notes', left(nullif(trim(p->>'notes'), ''), 500),
    'lines', v_lines);
end;
$$;

revoke execute on function public._assign_printer(), public._custom_quote(jsonb), public._create_custom_order(jsonb, uuid, text)
  from public, anon, authenticated;
revoke execute on function public.assign_printer(uuid, uuid), public.mo_estimated_finish(uuid), public.printer_stats(date, date),
  public.quote_custom_print(jsonb), public.create_custom_print_order(jsonb), public.portal_create_custom_print_order(jsonb)
  from public, anon;
grant execute on function public.assign_printer(uuid, uuid), public.mo_estimated_finish(uuid), public.printer_stats(date, date),
  public.quote_custom_print(jsonb), public.create_custom_print_order(jsonb), public.portal_create_custom_print_order(jsonb)
  to authenticated;
grant select on public.v_location_utilization to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'printers') then
    alter publication supabase_realtime add table public.printers;
  end if;
end $$;
