-- =============================================================================
-- 010_purchasing_planning.sql — inventory ordering rules + supplier scorecard (Phase 7)
--
--   * v_reorder_plan        per item: daily usage from history -> reorder point,
--                           EOQ, periodic-review order-up-to level, inventory
--                           position, suggested order and order-by date
--   * v_supplier_scorecard  per supplier, from PO history: on-time rate, actual vs
--                           quoted lead time, fill rate, price stability, amounts
--                           owed and due dates -> overall rating Keep / Watch / Replace
--   * inventory_reviews     log of periodic manual reviews (record_inventory_review)
--   * v_review_status       last review and when the next one is due
--
-- Formulas (SPEC.md "Key formulas"); every input is a stored row or an editable setting:
--   d  = average daily usage over the last `demand_history_days` days (sales for
--        finished goods, production issues for components; seasonal items use
--        in-season days only), sigma = its standard deviation (zero days included)
--   L  = lead time in days (supplier lead for purchased items, production lead
--        time for items we make)
--   reorder point = d*L + z*sigma*sqrt(L)                 (z = service_level_z)
--   EOQ           = sqrt(2*D*S / H)   D = 365*d, S = ordering_cost per PO
--                   (production_setup_cost per batch for items we make),
--                   H = unit cost * carrying rate (seasonal rate for seasonal items)
--   order-up-to   = d*(R+L) + z*sigma*sqrt(R+L)           (R = review_interval_days)
--   position      = on hand + on order - committed
-- =============================================================================

insert into public.settings (key, value, type, category, label, description) values
  ('demand_history_days',   '180', 'number', 'ordering', 'Demand history window (days)',
   'Days of sales / usage history behind average daily demand, reorder points and EOQ.'),
  ('production_setup_cost', '5',   'number', 'ordering', 'Setup cost per production batch (S)',
   'Used in the economic batch size for items we make (planning, slicing, loading the printer).')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Reorder plan
-- ---------------------------------------------------------------------------
create or replace view public.v_reorder_plan with (security_invoker = true) as
with p as (
  select (now() at time zone public.setting_text('time_zone'))::date as today,
         public.setting_text('time_zone') as tz,
         greatest(public.setting_num('demand_history_days'), 7)::int as n,
         public.setting_num('service_level_z') as z,
         public.setting_num('ordering_cost') as s_po,
         public.setting_num('production_setup_cost') as s_mo,
         public.setting_num('carrying_rate_annual') as h_std,
         public.setting_num('carrying_rate_seasonal') as h_seas,
         public.setting_num('review_interval_days')::int as r_days
), its as (
  select i.*
    from public.items i
   where i.is_active
     and (i.item_type = 'purchased' or i.stocking_policy in ('stock', 'seasonal'))
), days as (
  select its.id as item_id, g::date as day
    from its
   cross join p
   cross join lateral generate_series((p.today - p.n)::timestamp, (p.today - 1)::timestamp, interval '1 day') as g
   where its.stocking_policy <> 'seasonal'
      or to_char(g, 'MM-DD') between coalesce(its.season_start, '01-01') and coalesce(its.season_end, '12-31')
), usage as (
  select t.item_id, (t.txn_at at time zone p.tz)::date as day, -sum(t.qty) as q
    from public.inventory_txn t
   cross join p
   where t.source_type in ('sale', 'production_issue')
     and t.txn_at >= ((p.today - p.n)::timestamp at time zone p.tz)
     and t.txn_at <  (p.today::timestamp at time zone p.tz)
   group by t.item_id, 2
), stats as (
  select d.item_id, count(*) as n_days, coalesce(sum(u.q), 0) as total_usage,
         avg(coalesce(u.q, 0)) as d_avg, coalesce(stddev_samp(coalesce(u.q, 0)), 0) as d_sd
    from days d
    left join usage u on u.item_id = d.item_id and u.day = d.day
   group by d.item_id
), src as (
  select its.id as item_id, s.supplier_id, sup.name as supplier_name, s.purchase_uom,
         coalesce(s.stock_per_purchase_unit, 1) as pack, s.unit_cost as purchase_unit_cost,
         case when its.item_type = 'purchased'
              then coalesce(its.lead_time_days, s.lead_time_days, sup.quoted_lead_days, 7)
              else coalesce(its.lead_time_days, 1) end as lead_days
    from its
    left join lateral (
      select x.* from public.item_suppliers x
       where x.item_id = its.id order by x.is_preferred desc, x.unit_cost limit 1) s on its.item_type = 'purchased'
    left join public.suppliers sup on sup.id = s.supplier_id
), oh as (
  select t.item_id, sum(t.qty) as qty
    from public.inventory_txn t join public.locations l on l.id = t.location_id
   where l.is_sellable
   group by t.item_id
), po_open as (
  select l.item_id, sum((l.qty_ordered - l.qty_received) * l.stock_per_purchase_unit) as qty
    from public.purchase_order_lines l join public.purchase_orders po on po.id = l.po_id
   where po.status in ('sent', 'partial') and l.qty_received < l.qty_ordered
   group by l.item_id
), mo_open as (
  select mo.item_id, sum(case when mo.status = 'in_progress' then mo.qty_started else mo.plates * i.units_per_plate end) as qty
    from public.production_orders mo join public.items i on i.id = mo.item_id
   where mo.status in ('planned', 'in_progress')
   group by mo.item_id
), so_open as (
  select l.item_id, sum(l.qty - l.qty_fulfilled) as qty
    from public.sales_order_lines l join public.sales_orders so on so.id = l.so_id
   where so.status = 'placed'
   group by l.item_id
), mo_alloc as (
  select c.item_id, sum(c.qty_required - c.qty_issued) as qty
    from public.production_order_components c join public.production_orders mo on mo.id = c.mo_id
   where mo.status = 'planned'
   group by c.item_id
), base as (
  select its.id as item_id, its.sku, its.name, its.category, its.item_type, its.uom, its.stocking_policy,
         its.reorder_point_manual,
         case when its.item_type = 'purchased' then 'purchase' else 'production' end as replenish_by,
         src.supplier_id, src.supplier_name, coalesce(src.purchase_uom, its.uom) as purchase_uom,
         coalesce(src.pack, 1) as pack, src.purchase_unit_cost, src.lead_days,
         coalesce(st.n_days, 0) as days_observed, coalesce(st.total_usage, 0) as total_usage,
         coalesce(st.d_avg, 0) as avg_daily, coalesce(st.d_sd, 0) as sd_daily,
         public.item_unit_cost(its.id) as unit_cost,
         case when its.stocking_policy = 'seasonal' then p.h_seas else p.h_std end as carrying_rate,
         case when its.item_type = 'purchased' then p.s_po else p.s_mo end as order_cost,
         p.z, p.r_days, p.today,
         coalesce(oh.qty, 0) as on_hand,
         coalesce(case when its.item_type = 'purchased' then po_open.qty else mo_open.qty end, 0) as on_order,
         coalesce(case when its.item_type = 'purchased' then mo_alloc.qty else so_open.qty end, 0) as committed
    from its
   cross join p
    left join stats st   on st.item_id = its.id
    left join src        on src.item_id = its.id
    left join oh         on oh.item_id = its.id
    left join po_open    on po_open.item_id = its.id
    left join mo_open    on mo_open.item_id = its.id
    left join so_open    on so_open.item_id = its.id
    left join mo_alloc   on mo_alloc.item_id = its.id
), calc as (
  select b.*,
         round(b.avg_daily * 365, 2) as annual_demand,
         round(b.unit_cost * b.carrying_rate, 6) as holding_cost_unit,
         round(b.avg_daily * b.lead_days, 2) as lead_time_demand,
         round(b.z * b.sd_daily * sqrt(b.lead_days::numeric), 2) as safety_stock,
         round(b.avg_daily * b.lead_days + b.z * b.sd_daily * sqrt(b.lead_days::numeric), 2) as rop_calc,
         case when b.avg_daily > 0 and b.unit_cost * b.carrying_rate > 0
              then round(sqrt(2 * b.avg_daily * 365 * b.order_cost / (b.unit_cost * b.carrying_rate)), 2) end as eoq,
         round(b.avg_daily * (b.r_days + b.lead_days) + b.z * b.sd_daily * sqrt((b.r_days + b.lead_days)::numeric), 2) as order_up_to,
         b.on_hand + b.on_order - b.committed as position
    from base b
), fin as (
  select c.*,
         coalesce(c.reorder_point_manual, c.rop_calc) as reorder_point,
         c.position <= coalesce(c.reorder_point_manual, c.rop_calc) and c.avg_daily > 0 as below_reorder_point
    from calc c
)
select f.item_id, f.sku, f.name, f.category, f.item_type, f.uom, f.stocking_policy, f.replenish_by,
       f.supplier_id, f.supplier_name, f.purchase_uom, f.pack, f.purchase_unit_cost, f.lead_days,
       f.days_observed, f.total_usage, round(f.avg_daily, 4) as avg_daily, round(f.sd_daily, 4) as sd_daily,
       f.annual_demand, f.unit_cost, f.carrying_rate, f.holding_cost_unit, f.order_cost, f.z,
       f.lead_time_demand, f.safety_stock, f.rop_calc, f.reorder_point_manual, f.reorder_point,
       f.eoq, case when f.eoq is not null then greatest(1, ceil(f.eoq / f.pack)) end as eoq_units,
       f.on_hand, f.on_order, f.committed, f.position, f.below_reorder_point,
       case when f.avg_daily > 0 then round(f.position / f.avg_daily, 1) end as days_of_supply,
       -- Continuous review: when position reaches the reorder point, order EOQ
       -- (or enough to get back above the reorder point, if that is more).
       case when f.below_reorder_point
            then greatest(1, ceil(greatest(coalesce(f.eoq, 0), f.reorder_point - f.position + f.avg_daily) / f.pack)) * f.pack end as suggested_qty,
       case when f.below_reorder_point
            then greatest(1, ceil(greatest(coalesce(f.eoq, 0), f.reorder_point - f.position + f.avg_daily) / f.pack)) end as suggested_units,
       -- Date the position is expected to reach the reorder point.
       case when f.avg_daily > 0
            then f.today + greatest(0, floor((f.position - f.reorder_point) / f.avg_daily))::int end as order_by_date,
       -- Periodic review: order up to the target level every R days.
       f.r_days as review_interval_days, f.order_up_to,
       case when f.avg_daily > 0 and f.order_up_to > f.position
            then ceil((f.order_up_to - f.position) / f.pack) end as review_units,
       case when f.avg_daily > 0 and f.order_up_to > f.position
            then ceil((f.order_up_to - f.position) / f.pack) * f.pack end as review_qty
  from fin f;

-- ---------------------------------------------------------------------------
-- Supplier scorecard (everything from PO history)
-- ---------------------------------------------------------------------------
create or replace view public.v_supplier_scorecard with (security_invoker = true) as
with p as (
  select public.setting_text('time_zone') as tz, (now() at time zone public.setting_text('time_zone'))::date as today
), po as (
  select po.id, po.supplier_id, po.status, po.expected_date, po.lead_days,
         (po.order_date at time zone p.tz)::date as sent_date,
         (select (max(r.received_at) at time zone p.tz)::date from public.po_receipts r where r.po_id = po.id) as last_rcpt,
         (select count(*) from public.po_receipts r where r.po_id = po.id) as n_rcpt
    from public.purchase_orders po cross join p
   where po.status in ('sent', 'partial', 'received', 'closed')
), done as (
  -- Deliveries that are finished: fully received, or closed (including closed short).
  select * from po where status in ('received', 'closed') and last_rcpt is not null
), del as (
  select d.supplier_id,
         count(*) as pos_delivered,
         count(*) filter (where d.last_rcpt <= d.expected_date) as pos_on_time,
         avg(d.last_rcpt - d.sent_date) as avg_actual_lead,
         avg(abs((d.last_rcpt - d.sent_date) - d.lead_days)) as avg_lead_error,
         avg(d.lead_days) as avg_quoted_lead,
         avg(greatest(0, d.last_rcpt - d.expected_date)) as avg_days_late,
         sum(d.n_rcpt) as receipts
    from done d group by d.supplier_id
), fill as (
  select d.supplier_id,
         sum(least(l.qty_received, l.qty_ordered) * l.unit_cost) / nullif(sum(l.qty_ordered * l.unit_cost), 0) as fill_rate,
         sum(l.qty_ordered * l.unit_cost) as ordered_value
    from done d join public.purchase_order_lines l on l.po_id = d.id
   group by d.supplier_id
), price as (
  select x.supplier_id, avg(x.cv) as price_cv
    from (select po.supplier_id, l.item_id,
                 coalesce(stddev_pop(l.unit_cost) / nullif(avg(l.unit_cost), 0), 0) as cv
            from public.purchase_order_lines l join po on po.id = l.po_id
           group by po.supplier_id, l.item_id) x
   group by x.supplier_id
), open_po as (
  select po.supplier_id, count(*) as open_pos,
         sum((l.qty_ordered - l.qty_received) * l.unit_cost) as open_value
    from po join public.purchase_order_lines l on l.po_id = po.id
   where po.status in ('sent', 'partial')
   group by po.supplier_id
), ap as (
  select a.supplier_id,
         sum(a.balance) as amount_owed,
         sum(a.balance) filter (where a.is_overdue) as amount_overdue,
         min(a.due_date) filter (where a.balance > 0) as next_due_date,
         count(*) filter (where a.balance > 0) as open_bills,
         sum(a.amount) as total_billed
    from public.v_ap_open a group by a.supplier_id
), paid as (
  select r_po.supplier_id,
         count(*) as payments,
         count(*) filter (where (sp.paid_at at time zone p.tz)::date <= r.due_date) as paid_on_time
    from public.supplier_payments sp
    join public.po_receipts r on r.id = sp.receipt_id
    join public.purchase_orders r_po on r_po.id = r.po_id
   cross join p
   group by r_po.supplier_id
), score as (
  select s.id as supplier_id, s.name, s.contact_name, s.email, s.phone, s.quoted_lead_days, s.payment_terms, s.terms_days, s.is_active,
         coalesce(del.pos_delivered, 0) as pos_delivered,
         coalesce(del.pos_on_time, 0) as pos_on_time,
         round(del.pos_on_time::numeric / nullif(del.pos_delivered, 0), 4) as on_time_rate,
         round(del.avg_actual_lead, 2) as avg_actual_lead_days,
         round(del.avg_quoted_lead, 2) as avg_quoted_lead_days,
         round(del.avg_days_late, 2) as avg_days_late,
         round(greatest(0, 1 - del.avg_lead_error / greatest(del.avg_quoted_lead, 1)), 4) as lead_accuracy,
         round(fill.fill_rate, 4) as fill_rate,
         round(price.price_cv, 4) as price_cv,
         round(greatest(0, 1 - 2 * coalesce(price.price_cv, 0)), 4) as price_stability,
         coalesce(del.receipts, 0) as receipts,
         coalesce(open_po.open_pos, 0) as open_pos,
         coalesce(open_po.open_value, 0) as open_po_value,
         coalesce(ap.amount_owed, 0) as amount_owed,
         coalesce(ap.amount_overdue, 0) as amount_overdue,
         ap.next_due_date,
         coalesce(ap.open_bills, 0) as open_bills,
         coalesce(ap.total_billed, 0) as total_billed,
         coalesce(paid.payments, 0) as payments,
         round(paid.paid_on_time::numeric / nullif(paid.payments, 0), 4) as paid_on_time_rate
    from public.suppliers s
    left join del     on del.supplier_id = s.id
    left join fill    on fill.supplier_id = s.id
    left join price   on price.supplier_id = s.id
    left join open_po on open_po.supplier_id = s.id
    left join ap      on ap.supplier_id = s.id
    left join paid    on paid.supplier_id = s.id
)
select sc.*,
       -- Overall = on-time 40% + fill rate 30% + lead-time accuracy 20% + price stability 10%
       case when sc.pos_delivered > 0 then
         round(100 * (0.4 * sc.on_time_rate + 0.3 * coalesce(sc.fill_rate, 0)
                      + 0.2 * coalesce(sc.lead_accuracy, 0) + 0.1 * sc.price_stability), 1) end as overall_score,
       case when sc.pos_delivered = 0 then 'No history'
            when 100 * (0.4 * sc.on_time_rate + 0.3 * coalesce(sc.fill_rate, 0)
                        + 0.2 * coalesce(sc.lead_accuracy, 0) + 0.1 * sc.price_stability) >= 80 then 'Keep'
            when 100 * (0.4 * sc.on_time_rate + 0.3 * coalesce(sc.fill_rate, 0)
                        + 0.2 * coalesce(sc.lead_accuracy, 0) + 0.1 * sc.price_stability) >= 60 then 'Watch'
            else 'Replace' end as rating
  from score sc;

-- ---------------------------------------------------------------------------
-- Periodic manual review log
-- ---------------------------------------------------------------------------
create table public.inventory_reviews (
  id           uuid primary key default gen_random_uuid(),
  reviewed_at  timestamptz not null default now(),
  reviewed_by  uuid,
  reviewer     text,
  notes        text,
  items_below  int not null default 0,
  po_ids       uuid[] not null default '{}'
);
alter table public.inventory_reviews enable row level security;
create policy staff_read on public.inventory_reviews for select to authenticated using (public.is_staff());

-- Record that a periodic review was done (and which POs it created).
create or replace function public.record_inventory_review(p_notes text default null, p_po_ids uuid[] default null,
                                                          p_at timestamptz default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_at timestamptz := coalesce(p_at, now());
  v_below int;
begin
  perform public._require_staff();
  select count(*) into v_below from v_reorder_plan where review_units > 0;
  insert into inventory_reviews (reviewed_at, reviewed_by, reviewer, notes, items_below, po_ids)
  values (v_at, auth.uid(), public._actor(), nullif(trim(p_notes), ''), v_below, coalesce(p_po_ids, '{}'))
  returning id into v_id;
  perform public._log('inventory.review', 'inventory_review', v_id,
    format('Periodic inventory review: %s item(s) below target, %s PO(s) created', v_below, coalesce(array_length(p_po_ids, 1), 0)),
    '/purchasing/review', v_at);
  return v_id;
end;
$$;

create or replace view public.v_review_status with (security_invoker = true) as
select r.reviewed_at as last_reviewed_at, r.reviewer as last_reviewer,
       public.setting_num('review_interval_days')::int as review_interval_days,
       coalesce((r.reviewed_at at time zone public.setting_text('time_zone'))::date
                + public.setting_num('review_interval_days')::int,
                (now() at time zone public.setting_text('time_zone'))::date) as next_review_date
  from (select 1) one
  left join lateral (select * from public.inventory_reviews order by reviewed_at desc limit 1) r on true;

grant select on public.v_reorder_plan, public.v_supplier_scorecard, public.v_review_status, public.inventory_reviews to authenticated;
revoke execute on function public.record_inventory_review(text, uuid[], timestamptz) from public, anon;
grant execute on function public.record_inventory_review(text, uuid[], timestamptz) to authenticated;

-- Live refresh for the purchasing screens.
do $$
declare t text;
begin
  foreach t in array array['suppliers', 'item_suppliers', 'supplier_payments', 'inventory_reviews', 'production_order_components'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
