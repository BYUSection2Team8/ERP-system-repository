-- =============================================================================
-- 003_calc_views.sql — shared calculations and derived views
--
-- "Calculations live in one place": costs, availability, backorder dates and
-- balances are computed here from stored rows, so every screen (and later the
-- "Show the math" panels) uses the same numbers.
-- All views use security_invoker so row-level security still applies.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Settings accessors
-- ---------------------------------------------------------------------------
create or replace function public.setting_text(p_key text)
returns text
language plpgsql stable
set search_path = public, pg_temp
as $$
declare v text;
begin
  select value into v from settings where key = p_key;
  if not found then
    raise exception 'Missing setting "%". Add it on the Settings screen.', p_key;
  end if;
  return v;
end;
$$;

create or replace function public.setting_num(p_key text)
returns numeric
language sql stable
set search_path = public, pg_temp
as $$ select public.setting_text(p_key)::numeric; $$;

-- Machine cost per print hour = depreciation + electricity + maintenance.
-- Defaults: 700/5000 + 0.15*0.11 + 0.05 = 0.2065 ≈ $0.21/hr.
create or replace function public.machine_rate_per_hour()
returns numeric
language sql stable
set search_path = public, pg_temp
as $$
  select setting_num('printer_cost') / nullif(setting_num('printer_life_hours'), 0)
       + setting_num('printer_power_kw') * setting_num('electricity_per_kwh')
       + setting_num('maintenance_per_hour');
$$;

-- ---------------------------------------------------------------------------
-- Weighted-average unit cost of an item (per stock unit: each or gram).
--
-- Moving weighted average: receipts come in at their cost, every issue goes
-- out at the current average, so SUM(qty*cost)/SUM(qty) over all movements
-- equals the current average cost. Fallbacks when nothing is on hand:
-- last receipt cost -> preferred supplier price -> rolled-up standard cost.
-- ---------------------------------------------------------------------------
create or replace function public.item_unit_cost(p_item uuid)
returns numeric
language plpgsql stable
set search_path = public, pg_temp
as $$
declare
  v_qty  numeric;
  v_val  numeric;
  v_cost numeric;
begin
  select coalesce(sum(qty), 0), coalesce(sum(ext_cost), 0)
    into v_qty, v_val
    from inventory_txn where item_id = p_item;
  if v_qty > 0 then
    return round(greatest(v_val, 0) / v_qty, 6);
  end if;

  select unit_cost into v_cost
    from inventory_txn
   where item_id = p_item and qty > 0
   order by txn_at desc, id desc limit 1;
  if found then return v_cost; end if;

  select round(s.unit_cost / s.stock_per_purchase_unit, 6) into v_cost
    from item_suppliers s
   where s.item_id = p_item
   order by s.is_preferred desc, s.unit_cost
   limit 1;
  if found then return v_cost; end if;

  if exists (select 1 from boms where parent_item_id = p_item) then
    return (select total_cost from public.item_standard_cost(p_item));
  end if;
  return 0;
end;
$$;

-- Rolled-up cost of ONE unit of a made item, from its BOM and settings:
-- unit cost = (Σ component qty × avg cost + print hrs × machine rate
--              + (setup + cleanup + assembly min)/60 × labor rate) / units per plate
create or replace function public.item_standard_cost(p_item uuid)
returns table (material_cost numeric, machine_cost numeric, labor_cost numeric, total_cost numeric)
language plpgsql stable
set search_path = public, pg_temp
as $$
declare
  i items%rowtype;
  v_mat numeric;
  v_mach numeric;
  v_lab numeric;
begin
  select * into i from items where id = p_item;
  if not found then return; end if;

  select coalesce(sum(b.qty_per_plate * public.item_unit_cost(b.component_item_id)), 0)
    into v_mat from boms b where b.parent_item_id = p_item;
  v_mach := coalesce(i.print_minutes, 0) / 60.0 * public.machine_rate_per_hour();
  v_lab  := (setting_num('setup_minutes_per_plate') + setting_num('cleanup_minutes_per_plate')
             + coalesce(i.assembly_minutes, 0)) / 60.0 * setting_num('labor_rate');

  material_cost := round(v_mat  / i.units_per_plate, 6);
  machine_cost  := round(v_mach / i.units_per_plate, 6);
  labor_cost    := round(v_lab  / i.units_per_plate, 6);
  total_cost    := material_cost + machine_cost + labor_cost;
  return next;
end;
$$;

-- Best estimate of when an item that is short will be available.
-- Purchased: earliest open PO expected date, else today + supplier lead time.
-- Made: earliest open production order due date, else today + production lead time.
create or replace function public.estimate_available_date(p_item uuid)
returns date
language plpgsql stable
set search_path = public, pg_temp
as $$
declare
  i items%rowtype;
  v_date date;
  v_lead int;
begin
  select * into i from items where id = p_item;
  if not found then return null; end if;

  if i.item_type = 'purchased' then
    select min(po.expected_date) into v_date
      from purchase_order_lines l join purchase_orders po on po.id = l.po_id
     where l.item_id = p_item and po.status in ('sent','partial') and l.qty_received < l.qty_ordered;
    if v_date is not null then return greatest(v_date, current_date); end if;

    select coalesce(i.lead_time_days, s.lead_time_days, sup.quoted_lead_days) into v_lead
      from item_suppliers s join suppliers sup on sup.id = s.supplier_id
     where s.item_id = p_item
     order by s.is_preferred desc limit 1;
    return current_date + coalesce(v_lead, i.lead_time_days, 7);
  end if;

  select min(due_date) into v_date
    from production_orders where item_id = p_item and status in ('planned','in_progress');
  if v_date is not null then return greatest(v_date, current_date); end if;
  return current_date + coalesce(i.lead_time_days, 2);
end;
$$;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

-- On hand by item and location (only non-zero rows).
create view public.v_stock_on_hand with (security_invoker = true) as
select t.item_id, t.location_id, sum(t.qty) as qty_on_hand
  from public.inventory_txn t
 group by t.item_id, t.location_id
having sum(t.qty) <> 0;

-- On hand, committed to open sales orders, and available, by item and location.
create view public.v_availability with (security_invoker = true) as
with oh as (
  select item_id, location_id, sum(qty) as q
    from public.inventory_txn group by item_id, location_id
), cm as (
  select l.item_id, so.location_id, sum(l.qty - l.qty_fulfilled) as q
    from public.sales_order_lines l
    join public.sales_orders so on so.id = l.so_id
   where so.status = 'placed'
   group by l.item_id, so.location_id
)
select item_id, location_id,
       coalesce(oh.q, 0)                      as qty_on_hand,
       coalesce(cm.q, 0)                      as qty_committed,
       coalesce(oh.q, 0) - coalesce(cm.q, 0)  as qty_available
  from oh full join cm using (item_id, location_id);

-- Inventory valuation at weighted-average cost, per item.
create view public.v_inventory_valuation with (security_invoker = true) as
select i.id as item_id, i.sku, i.name, i.category, i.uom,
       coalesce(s.qty, 0)                                    as qty_on_hand,
       public.item_unit_cost(i.id)                           as avg_unit_cost,
       round(coalesce(s.qty, 0) * public.item_unit_cost(i.id), 2) as inventory_value
  from public.items i
  left join (select item_id, sum(qty) as qty from public.inventory_txn group by item_id) s
         on s.item_id = i.id;

-- Supply already on order (stock units) and the next expected date.
create view public.v_open_po_supply with (security_invoker = true) as
select l.item_id,
       sum((l.qty_ordered - l.qty_received) * l.stock_per_purchase_unit) as qty_on_order,
       min(po.expected_date) as next_expected_date
  from public.purchase_order_lines l
  join public.purchase_orders po on po.id = l.po_id
 where po.status in ('sent','partial') and l.qty_received < l.qty_ordered
 group by l.item_id;

-- BOM quantities per single finished unit (BOMs are stored per plate).
create view public.v_bom_per_unit with (security_invoker = true) as
select b.parent_item_id, b.component_item_id, b.qty_per_plate, p.units_per_plate,
       b.qty_per_plate / p.units_per_plate as qty_per_unit
  from public.boms b join public.items p on p.id = b.parent_item_id;

-- Rolled-up standard cost and margin for every made item.
create view public.v_item_standard_cost with (security_invoker = true) as
select i.id as item_id, i.sku, i.name, i.price, c.material_cost, c.machine_cost,
       c.labor_cost, c.total_cost,
       case when i.price > 0 then round((i.price - c.total_cost) / i.price, 4) end as margin_pct
  from public.items i
  cross join lateral public.item_standard_cost(i.id) c
 where i.item_type = 'finished';

-- Open sales-order lines that cannot be filled from stock at their location,
-- allocated first-come-first-served by order date.
create view public.v_backorders with (security_invoker = true) as
with lines as (
  select l.id as so_line_id, so.id as so_id, so.order_no, so.customer_id, so.location_id,
         l.item_id, so.order_date, so.need_date,
         l.qty - l.qty_fulfilled as qty_open,
         sum(l.qty - l.qty_fulfilled) over (
           partition by l.item_id, so.location_id
           order by so.order_date, so.order_no, l.line_no) as cum_demand
    from public.sales_order_lines l
    join public.sales_orders so on so.id = l.so_id
   where so.status = 'placed' and l.qty > l.qty_fulfilled
), oh as (
  select item_id, location_id, sum(qty) as q
    from public.inventory_txn group by item_id, location_id
)
select lines.so_line_id, lines.so_id, lines.order_no, lines.customer_id, lines.location_id,
       lines.item_id, lines.order_date, lines.need_date, lines.qty_open,
       coalesce(oh.q, 0) as qty_on_hand,
       least(lines.qty_open, lines.cum_demand - coalesce(oh.q, 0)) as qty_backordered,
       public.estimate_available_date(lines.item_id) as est_available_date
  from lines
  left join oh on oh.item_id = lines.item_id and oh.location_id = lines.location_id
 where lines.cum_demand - coalesce(oh.q, 0) > 0;

-- Accounts payable: each receipt is a bill due on received date + terms.
create view public.v_ap_open with (security_invoker = true) as
select r.id as receipt_id, po.id as po_id, po.po_no, po.supplier_id, s.name as supplier_name,
       r.received_at, r.due_date, r.amount,
       coalesce(p.paid, 0)            as amount_paid,
       r.amount - coalesce(p.paid, 0) as balance,
       (r.amount - coalesce(p.paid, 0) > 0 and r.due_date < current_date) as is_overdue
  from public.po_receipts r
  join public.purchase_orders po on po.id = r.po_id
  join public.suppliers s on s.id = po.supplier_id
  left join (select receipt_id, sum(amount) as paid
               from public.supplier_payments group by receipt_id) p on p.receipt_id = r.id;

-- Account balances from the ledger (positive = normal balance).
create view public.v_account_balances with (security_invoker = true) as
select a.code, a.name, a.type, a.pl_section,
       coalesce(sum(l.debit), 0)  as total_debit,
       coalesce(sum(l.credit), 0) as total_credit,
       case when a.type in ('asset','expense','cogs','contra_revenue')
            then coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0)
            else coalesce(sum(l.credit), 0) - coalesce(sum(l.debit), 0) end as balance
  from public.accounts a
  left join public.ledger l on l.account_code = a.code
 group by a.code, a.name, a.type, a.pl_section, a.sort_order
 order by a.sort_order, a.code;

grant execute on function
  public.setting_text(text), public.setting_num(text), public.machine_rate_per_hour(),
  public.item_unit_cost(uuid), public.item_standard_cost(uuid), public.estimate_available_date(uuid)
  to authenticated;
