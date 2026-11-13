-- =============================================================================
-- 008_production_mrp.sql — production report + metrics, and MRP (Phase 5)
--
-- Everything here is read-only calculation over stored rows, so the screens
-- (and later the "Show the math" panels) all use the same numbers:
--   * v_production_orders         one row per production order + cycle time, on-time flag
--   * production_metrics(from,to) first-pass yield, unit yield, scrap rate,
--                                 average cycle time, on-time completion
--   * production_scrap_by_reason(from,to)
--   * mrp_parent_plan(weeks)      open sales-order demand for made items, netted
--                                 against finished stock and open production orders
--   * mrp_component_plan(weeks)   planned production x BOM (+ planned orders not yet
--                                 issued) netted against on-hand and open POs ->
--                                 suggested order qty and order-by date per week
-- =============================================================================

-- _post_journal links stock movements to their journal by source_id; with six
-- months of history that lookup needs its own index.
create index if not exists inventory_txn_source_id_idx on public.inventory_txn (source_id);

-- ---------------------------------------------------------------------------
-- Production orders with derived measures
-- report_date = the business date the order belongs to in reports
-- (finished, else started, else created), in the company time zone.
-- ---------------------------------------------------------------------------
create or replace view public.v_production_orders with (security_invoker = true) as
select mo.id, mo.mo_no, mo.item_id, i.sku, i.name as item_name, i.product_family,
       mo.status, mo.qty_planned, mo.plates, mo.qty_started, mo.qty_good, mo.qty_scrap,
       mo.scrap_reason, mo.so_id, mo.due_date, mo.created_at, mo.started_at, mo.finished_at,
       mo.material_cost, mo.machine_cost, mo.labor_cost, mo.unit_cost,
       round(mo.qty_scrap * coalesce(mo.unit_cost, 0), 2) as scrap_cost,
       (coalesce(mo.finished_at, mo.started_at, mo.created_at)
          at time zone public.setting_text('time_zone'))::date as report_date,
       case when mo.finished_at is not null and mo.started_at is not null
            then round(extract(epoch from (mo.finished_at - mo.started_at)) / 3600.0, 2) end as cycle_hours,
       case when mo.status = 'completed' and mo.due_date is not null
            then (mo.finished_at at time zone public.setting_text('time_zone'))::date <= mo.due_date end as on_time
  from public.production_orders mo
  join public.items i on i.id = mo.item_id;

-- Production and quality metrics over a date range (completed orders):
--   first-pass yield  = completed orders with zero scrap / completed orders
--   unit yield        = good units / units started
--   scrap rate        = scrapped units / units started
--   avg cycle time    = average hours from issue (start) to completion (finish)
--   on-time rate      = orders finished on or before their due date / orders with a due date
create or replace function public.production_metrics(p_from date, p_to date)
returns table (
  orders_in_range int, orders_completed int, orders_open int,
  qty_started numeric, qty_good numeric, qty_scrap numeric,
  first_pass_yield numeric, unit_yield numeric, scrap_rate numeric,
  avg_cycle_hours numeric, orders_with_due int, orders_on_time int, on_time_rate numeric,
  scrap_cost numeric, production_cost numeric)
language sql stable
set search_path = public, pg_temp
as $$
  select count(*)::int,
         count(*) filter (where v.status = 'completed')::int,
         count(*) filter (where v.status in ('planned', 'in_progress'))::int,
         coalesce(sum(v.qty_started) filter (where v.status = 'completed'), 0),
         coalesce(sum(v.qty_good)    filter (where v.status = 'completed'), 0),
         coalesce(sum(v.qty_scrap)   filter (where v.status = 'completed'), 0),
         round(count(*) filter (where v.status = 'completed' and v.qty_scrap = 0)::numeric
               / nullif(count(*) filter (where v.status = 'completed'), 0), 4),
         round(sum(v.qty_good) filter (where v.status = 'completed')
               / nullif(sum(v.qty_started) filter (where v.status = 'completed'), 0), 4),
         round(sum(v.qty_scrap) filter (where v.status = 'completed')
               / nullif(sum(v.qty_started) filter (where v.status = 'completed'), 0), 4),
         round(avg(v.cycle_hours) filter (where v.status = 'completed'), 2),
         count(*) filter (where v.status = 'completed' and v.due_date is not null)::int,
         count(*) filter (where v.on_time)::int,
         round(count(*) filter (where v.on_time)::numeric
               / nullif(count(*) filter (where v.status = 'completed' and v.due_date is not null), 0), 4),
         coalesce(sum(v.scrap_cost) filter (where v.status = 'completed'), 0),
         coalesce(sum(v.material_cost + v.machine_cost + v.labor_cost) filter (where v.status = 'completed'), 0)
    from public.v_production_orders v
   where v.report_date between p_from and p_to;
$$;

create or replace function public.production_scrap_by_reason(p_from date, p_to date)
returns table (reason_code text, description text, orders int, qty_scrap numeric, scrap_cost numeric)
language sql stable
set search_path = public, pg_temp
as $$
  select v.scrap_reason, rc.description, count(*)::int, sum(v.qty_scrap), sum(v.scrap_cost)
    from public.v_production_orders v
    left join public.reason_codes rc on rc.code = v.scrap_reason
   where v.status = 'completed' and v.qty_scrap > 0 and v.report_date between p_from and p_to
   group by v.scrap_reason, rc.description
   order by sum(v.qty_scrap) desc;
$$;

-- ---------------------------------------------------------------------------
-- MRP, level 0: items we make.
-- Gross demand  = open (placed) sales-order lines, bucketed by need date into
--                 weeks starting Monday of this week (overdue -> this week).
-- Supply        = finished stock at sellable locations + open production orders
--                 (in progress: qty started; planned: plates x units per plate)
--                 in the week they are due.
-- Net           = cumulative demand - cumulative supply (never below 0).
-- Planned plates are whole plates (cumulative, so a lot of 10 covers later weeks);
-- start-by date = need date - production lead time.
-- ---------------------------------------------------------------------------
create or replace function public.mrp_parent_plan(p_weeks int default 4)
returns table (
  item_id uuid, week_no int, week_start date,
  gross_demand numeric, on_hand numeric, scheduled_output numeric,
  projected_balance numeric, net_requirement numeric,
  planned_plates int, planned_qty numeric,
  need_date date, start_by date, lead_days int)
language sql stable
set search_path = public, pg_temp
as $$
with p as (
  select x.d as today, date_trunc('week', x.d::timestamp)::date as w0,
         greatest(coalesce(p_weeks, 4), 1) as nw
    from (select (now() at time zone public.setting_text('time_zone'))::date as d) x
), dem as (
  select l.item_id,
         greatest(0, (coalesce(so.need_date, p.today) - p.w0) / 7) as wk,
         sum(l.qty - l.qty_fulfilled) as qty,
         min(greatest(coalesce(so.need_date, p.today), p.today)) as need_date
    from public.sales_order_lines l
    join public.sales_orders so on so.id = l.so_id
   cross join p
   where so.status = 'placed' and l.qty > l.qty_fulfilled
     and exists (select 1 from public.boms b where b.parent_item_id = l.item_id)
   group by l.item_id, 2
), parents as (
  select distinct d.item_id from dem d cross join p where d.wk < p.nw
), oh as (
  select t.item_id, sum(t.qty) as qty
    from public.inventory_txn t
    join public.locations loc on loc.id = t.location_id
   where loc.is_sellable and t.item_id in (select item_id from parents)
   group by t.item_id
), sched as (
  select mo.item_id,
         greatest(0, (coalesce(mo.due_date, p.today) - p.w0) / 7) as wk,
         sum(case when mo.status = 'in_progress' then mo.qty_started
                  else mo.plates * i.units_per_plate end) as qty
    from public.production_orders mo
    join public.items i on i.id = mo.item_id
   cross join p
   where mo.status in ('planned', 'in_progress') and mo.item_id in (select item_id from parents)
   group by mo.item_id, 2
), grid as (
  select pa.item_id, g.wk, p.w0 + 7 * g.wk as week_start,
         coalesce(d.qty, 0) as gross, coalesce(s.qty, 0) as sched, d.need_date,
         coalesce(oh.qty, 0) as on_hand, i.units_per_plate as upp,
         coalesce(i.lead_time_days, 0) as lead, p.today
    from parents pa
   cross join p
   cross join lateral generate_series(0, p.nw - 1) as g(wk)
    join public.items i on i.id = pa.item_id
    left join dem d   on d.item_id = pa.item_id and d.wk = g.wk
    left join sched s on s.item_id = pa.item_id and s.wk = g.wk
    left join oh      on oh.item_id = pa.item_id
), cum as (
  select g.*,
         sum(g.gross) over w as cum_gross,
         g.on_hand + sum(g.sched) over w as cum_supply
    from grid g
  window w as (partition by g.item_id order by g.wk)
), net as (
  select c.*,
         greatest(0, c.cum_gross - c.cum_supply) as net_cum,
         -- running max: supply that arrives after it is needed does not cancel
         -- the earlier requirement (it should be expedited instead)
         max(ceil(greatest(0, c.cum_gross - c.cum_supply) / c.upp)::int)
           over (partition by c.item_id order by c.wk rows unbounded preceding) as plates_cum
    from cum c
)
select n.item_id, n.wk, n.week_start, n.gross, n.on_hand, n.sched,
       n.cum_supply + n.plates_cum * n.upp - n.cum_gross,
       greatest(0, n.net_cum - coalesce(lag(n.net_cum) over w, 0)),
       n.plates_cum - coalesce(lag(n.plates_cum) over w, 0),
       ((n.plates_cum - coalesce(lag(n.plates_cum) over w, 0)) * n.upp)::numeric,
       n.need_date,
       n.need_date - n.lead,
       n.lead
  from net n
window w as (partition by n.item_id order by n.wk)
order by n.item_id, n.wk;
$$;

-- ---------------------------------------------------------------------------
-- MRP, level 1: components (filament, parts).
-- Gross requirement = planned production from mrp_parent_plan x BOM qty per plate,
--                     needed on the parent's start-by date (never before today),
--                   + components of planned production orders not yet issued.
-- Scheduled receipts = open PO lines (stock units) in the week they are expected.
-- Net requirement    = cumulative gross - (on hand + cumulative receipts).
-- Planned order      = net rounded up to whole purchase units (spools, each);
-- order-by date      = need date - the component's lead time.
-- ---------------------------------------------------------------------------
create or replace function public.mrp_component_plan(p_weeks int default 4)
returns table (
  item_id uuid, week_no int, week_start date,
  gross_requirement numeric, scheduled_receipts numeric, on_hand numeric,
  projected_balance numeric, net_requirement numeric,
  planned_order_qty numeric, planned_order_units numeric,
  purchase_uom text, stock_per_purchase_unit numeric,
  need_date date, order_by_date date, lead_days int,
  supplier_id uuid, unit_cost numeric)
language sql stable
set search_path = public, pg_temp
as $$
with p as (
  select x.d as today, date_trunc('week', x.d::timestamp)::date as w0,
         greatest(coalesce(p_weeks, 4), 1) as nw
    from (select (now() at time zone public.setting_text('time_zone'))::date as d) x
), req as (
  select b.component_item_id as item_id,
         greatest(pp.start_by, p.today) as need_date,
         pp.planned_plates * b.qty_per_plate as qty
    from public.mrp_parent_plan(p_weeks) pp
    join public.boms b on b.parent_item_id = pp.item_id
   cross join p
   where pp.planned_plates > 0
  union all
  select c.item_id,
         greatest(coalesce(mo.due_date - coalesce(i.lead_time_days, 0), p.today), p.today),
         c.qty_required - c.qty_issued
    from public.production_order_components c
    join public.production_orders mo on mo.id = c.mo_id
    join public.items i on i.id = mo.item_id
   cross join p
   where mo.status = 'planned' and c.qty_required > c.qty_issued
), gross as (
  select r.item_id, (r.need_date - p.w0) / 7 as wk, sum(r.qty) as qty, min(r.need_date) as need_date
    from req r cross join p
   group by r.item_id, 2
), comps as (
  select distinct g.item_id from gross g cross join p where g.wk < p.nw
), oh as (
  select t.item_id, sum(t.qty) as qty
    from public.inventory_txn t
    join public.locations loc on loc.id = t.location_id
   where loc.is_sellable and t.item_id in (select item_id from comps)
   group by t.item_id
), rcpt as (
  select l.item_id,
         greatest(0, (coalesce(po.expected_date, p.today) - p.w0) / 7) as wk,
         sum((l.qty_ordered - l.qty_received) * l.stock_per_purchase_unit) as qty
    from public.purchase_order_lines l
    join public.purchase_orders po on po.id = l.po_id
   cross join p
   where po.status in ('sent', 'partial') and l.qty_received < l.qty_ordered
     and l.item_id in (select item_id from comps)
   group by l.item_id, 2
), src as (
  select i.id as item_id, s.supplier_id, s.purchase_uom, s.stock_per_purchase_unit as pack, s.unit_cost,
         coalesce(i.lead_time_days, s.lead_time_days, sup.quoted_lead_days, 7) as lead
    from public.items i
    left join lateral (
      select x.* from public.item_suppliers x
       where x.item_id = i.id
       order by x.is_preferred desc, x.unit_cost
       limit 1) s on true
    left join public.suppliers sup on sup.id = s.supplier_id
   where i.id in (select item_id from comps)
), grid as (
  select c.item_id, g.wk, p.w0 + 7 * g.wk as week_start,
         coalesce(gr.qty, 0) as gross, coalesce(rc.qty, 0) as rcpt, gr.need_date,
         coalesce(oh.qty, 0) as on_hand, coalesce(src.pack, 1) as pack, coalesce(src.purchase_uom, i.uom) as uom,
         src.supplier_id, src.unit_cost, coalesce(src.lead, i.lead_time_days, 7) as lead
    from comps c
   cross join p
   cross join lateral generate_series(0, p.nw - 1) as g(wk)
    join public.items i on i.id = c.item_id
    left join gross gr on gr.item_id = c.item_id and gr.wk = g.wk
    left join rcpt rc  on rc.item_id = c.item_id and rc.wk = g.wk
    left join oh       on oh.item_id = c.item_id
    left join src      on src.item_id = c.item_id
), cum as (
  select g.*,
         sum(g.gross) over w as cum_gross,
         g.on_hand + sum(g.rcpt) over w as cum_supply
    from grid g
  window w as (partition by g.item_id order by g.wk)
), net as (
  select c.*,
         greatest(0, c.cum_gross - c.cum_supply) as net_cum,
         max(ceil(greatest(0, c.cum_gross - c.cum_supply) / c.pack))
           over (partition by c.item_id order by c.wk rows unbounded preceding) as units_cum
    from cum c
), out as (
  select n.*,
         n.units_cum - coalesce(lag(n.units_cum) over w, 0) as units_w,
         greatest(0, n.net_cum - coalesce(lag(n.net_cum) over w, 0)) as net_w
    from net n
  window w as (partition by n.item_id order by n.wk)
)
select o.item_id, o.wk, o.week_start, o.gross, o.rcpt, o.on_hand,
       o.cum_supply + o.units_cum * o.pack - o.cum_gross,
       o.net_w,
       o.units_w * o.pack,
       o.units_w,
       o.uom, o.pack, o.need_date,
       case when o.units_w > 0 then o.need_date - o.lead end,
       o.lead, o.supplier_id, o.unit_cost
  from out o
 order by o.item_id, o.wk;
$$;

grant select on public.v_production_orders to authenticated;
grant execute on function
  public.production_metrics(date, date),
  public.production_scrap_by_reason(date, date),
  public.mrp_parent_plan(int),
  public.mrp_component_plan(int)
  to authenticated;
