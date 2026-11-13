-- =============================================================================
-- 013_tracking_failures.sql — wow factors (Phase 10)
--
-- 1) Live order tracking (wow #1)
--    * every sales order gets a private, unguessable tracking_token
--    * track_order(token): public (no login) tracking data for one order:
--      stage, steps, % printed, estimated ready / delivery date. Computed from
--      the stored order, its backorders and its production orders.
--    * email_log + log_tracking_email(): every tracking email the app sends
--      (through EmailJS, from the browser) is logged as sent / failed / skipped
-- 2) Print failure analytics + Report failure (wow #2)
--    * report_print_failure(mo, reason, qty): writes off a failed print as
--      scrap and queues (and, if components allow, starts) the reprint
--    * print_failure_analytics(from, to): scrap by product, color, reason, week
--      with wasted filament grams and dollars
-- =============================================================================

insert into public.settings (key, value, type, category, label, description) values
  ('printer_count',         '4', 'number', 'machine',  'Printers running in parallel', 'Bambu Lab P2S printers. Used for print-time estimates on the tracking page.'),
  ('transit_days_estimate', '3', 'number', 'shipping', 'Shipping transit days (estimate)', 'Shown as the estimated delivery date on the tracking page.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Tracking tokens: 32 random hex characters (122 random bits). Existing orders
-- get one now; new orders get one by default.
-- ---------------------------------------------------------------------------
alter table public.sales_orders
  alter column tracking_token set default replace(gen_random_uuid()::text, '-', '');
update public.sales_orders set tracking_token = replace(gen_random_uuid()::text, '-', '')
 where tracking_token is null;

-- Tracking data for one order (internal; callers check who may see it).
-- Customer details are limited to a first name: the link is meant to be shared.
create or replace function public._order_tracking(p_so_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  so         sales_orders%rowtype;
  v_loc      locations%rowtype;
  v_first    text;
  v_now      timestamptz := now();
  v_tz       text := public.setting_text('time_zone');
  v_today    date := public._local_date(now());
  v_printers int := greatest(public.setting_num('printer_count'), 1)::int;
  v_transit  int := public.setting_num('transit_days_estimate')::int;
  v_bo_count int;
  v_bo_date  date;
  v_made     boolean;
  v_queued   boolean;
  v_print    record;
  v_stage    text;
  v_label    text;
  v_detail   text;
  v_progress numeric;
  v_ready_at timestamptz;
  v_ready_d  date;
  v_deliver  date;
  v_steps    jsonb := '[]'::jsonb;
  v_lines    jsonb;
begin
  select * into so from sales_orders where id = p_so_id;
  if not found then return null; end if;
  select * into v_loc from locations where id = so.location_id;
  select split_part(coalesce(nullif(c.contact_name, ''), c.name), ' ', 1) into v_first
    from customers c where c.id = so.customer_id;

  select count(*), max(b.est_available_date) into v_bo_count, v_bo_date
    from v_backorders b where b.so_id = so.id;

  -- Lines made for this order, or lines we are printing to fill it.
  v_made := exists (select 1 from production_orders mo where mo.so_id = so.id and mo.status <> 'cancelled')
         or exists (select 1 from sales_order_lines l join items i on i.id = l.item_id
                     where l.so_id = so.id and i.stocking_policy = 'make_to_order')
         or v_bo_count > 0;

  -- The print that will fill a backorder: one made for this order first, else any
  -- running print of a backordered item. Finish = start + plates on N printers + assembly.
  select mo.mo_no, mo.started_at,
         mo.started_at + make_interval(mins => (ceil(mo.plates::numeric / v_printers) * coalesce(i.print_minutes, 60)
                                                + mo.plates * coalesce(i.assembly_minutes, 0))::int) as finish_at
    into v_print
    from production_orders mo join items i on i.id = mo.item_id
   where mo.status = 'in_progress'
     and (mo.so_id = so.id or mo.item_id in (select b.item_id from v_backorders b where b.so_id = so.id))
   order by (mo.so_id = so.id) desc, mo.started_at
   limit 1;
  v_queued := exists (select 1 from production_orders mo
                       where mo.status = 'planned'
                         and (mo.so_id = so.id or mo.item_id in (select b.item_id from v_backorders b where b.so_id = so.id)));

  if so.status = 'cancelled' then
    v_stage := 'cancelled'; v_label := 'Cancelled';
    v_detail := 'This order was cancelled' || coalesce(' on ' || to_char(so.cancelled_at at time zone v_tz, 'Mon FMDD'), '') || '.';
  elsif so.status in ('fulfilled', 'closed') then
    if so.fulfillment_method = 'ship' then
      v_deliver := (so.fulfilled_at at time zone v_tz)::date + v_transit;
      if so.status = 'closed' or v_today >= v_deliver then
        v_stage := 'delivered'; v_label := 'Delivered';
        v_detail := 'Your package should have arrived. Enjoy!';
      else
        v_stage := 'shipped'; v_label := 'Shipped';
        v_detail := 'On its way. Estimated delivery ' || to_char(v_deliver, 'Dy, Mon FMDD') || '.';
      end if;
    else
      v_stage := 'picked_up'; v_label := 'Picked up';
      v_detail := 'Picked up at ' || v_loc.name || '. Thank you!';
    end if;
  elsif v_bo_count > 0 and v_print.started_at is not null then
    v_stage := 'printing'; v_label := 'Printing';
    v_ready_at := v_print.finish_at;
    v_progress := least(0.99, greatest(0.01, extract(epoch from (v_now - v_print.started_at))
                                         / nullif(extract(epoch from (v_print.finish_at - v_print.started_at)), 0)));
    v_detail := 'On the printers now (' || v_print.mo_no || ').';
    v_ready_d := greatest(coalesce(v_bo_date, v_today), (v_ready_at at time zone v_tz)::date);
  elsif v_bo_count > 0 and v_queued then
    v_stage := 'queued'; v_label := 'Queued for printing';
    v_ready_d := coalesce(v_bo_date, v_today);
    v_detail := 'In the print queue. Estimated ready ' || to_char(v_ready_d, 'Dy, Mon FMDD') || '.';
  elsif v_bo_count > 0 then
    v_stage := 'waiting'; v_label := 'Waiting for stock';
    v_ready_d := coalesce(v_bo_date, v_today);
    v_detail := 'We are restocking. Estimated ready ' || to_char(v_ready_d, 'Dy, Mon FMDD') || '.';
  elsif so.fulfillment_method = 'ship' then
    v_stage := 'packing'; v_label := 'Packing';
    v_ready_d := v_today;
    v_deliver := v_today + 1 + v_transit;
    v_detail := 'Everything is here; we are packing it. Estimated delivery ' || to_char(v_deliver, 'Dy, Mon FMDD') || '.';
  else
    v_stage := 'ready'; v_label := 'Ready for pickup';
    v_ready_d := v_today;
    v_detail := 'Ready for pickup at ' || v_loc.name || '.';
  end if;

  -- Steps (timeline). Printing appears only for orders that needed printing.
  v_steps := jsonb_build_array(jsonb_build_object('key', 'placed', 'label', 'Order placed', 'done', true, 'at', so.order_date));
  if so.fulfillment_method = 'counter' then
    v_steps := v_steps || jsonb_build_object('key', 'picked_up', 'label', 'Paid & picked up',
                 'done', so.fulfilled_at is not null, 'at', so.fulfilled_at);
  else
    if v_made then
      v_steps := v_steps || jsonb_build_object('key', 'printing', 'label', 'Printed',
                   'done', so.status in ('fulfilled', 'closed') or (so.status = 'placed' and v_bo_count = 0),
                   'at', (select max(mo.finished_at) from production_orders mo where mo.so_id = so.id and mo.status = 'completed'));
    end if;
    if so.fulfillment_method = 'ship' then
      v_steps := v_steps
        || jsonb_build_object('key', 'shipped', 'label', 'Packed & shipped', 'done', so.fulfilled_at is not null, 'at', so.fulfilled_at)
        || jsonb_build_object('key', 'delivered', 'label', 'Delivered', 'done', v_stage = 'delivered', 'at', null);
    else
      v_steps := v_steps
        || jsonb_build_object('key', 'ready', 'label', 'Ready for pickup',
             'done', so.status in ('fulfilled', 'closed') or (so.status = 'placed' and v_bo_count = 0), 'at', null)
        || jsonb_build_object('key', 'picked_up', 'label', 'Picked up', 'done', so.fulfilled_at is not null, 'at', so.fulfilled_at);
    end if;
  end if;

  select jsonb_agg(jsonb_build_object('name', i.name, 'qty', l.qty,
           'backordered', coalesce(b.qty_backordered, 0), 'est_available_date', b.est_available_date) order by l.line_no)
    into v_lines
    from sales_order_lines l
    join items i on i.id = l.item_id
    left join v_backorders b on b.so_line_id = l.id
   where l.so_id = so.id;

  return jsonb_build_object(
    'order_no', so.order_no, 'order_date', so.order_date, 'status', so.status,
    'fulfillment_method', so.fulfillment_method, 'location_name', v_loc.name,
    'first_name', v_first, 'total', so.total, 'company', public.setting_text('company_name'),
    'stage', v_stage, 'stage_label', v_label, 'stage_detail', v_detail,
    'progress', round(v_progress, 3), 'ready_at', v_ready_at, 'ready_date', v_ready_d,
    'est_delivery_date', v_deliver, 'steps', v_steps, 'lines', coalesce(v_lines, '[]'::jsonb),
    'checked_at', v_now);
end;
$$;

-- Public tracking: anyone with the link (no login). Unknown or malformed
-- tokens return null, so the page says "not found" without giving hints.
create or replace function public.track_order(p_token text)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then return null; end if;
  select id into v_id from sales_orders where tracking_token = p_token;
  if not found then return null; end if;
  return public._order_tracking(v_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Tracking emails (sent by the browser through EmailJS; logged here)
-- ---------------------------------------------------------------------------
create table if not exists public.email_log (
  id         bigint generated always as identity primary key,
  so_id      uuid not null references public.sales_orders(id),
  to_email   text not null,
  kind       text not null default 'tracking',
  status     text not null check (status in ('sent', 'failed', 'skipped')),
  error      text,
  sent_at    timestamptz not null default now(),
  sent_by    uuid
);
create index if not exists email_log_so_idx on public.email_log (so_id);
alter table public.email_log enable row level security;
drop policy if exists staff_read on public.email_log;
create policy staff_read on public.email_log for select to authenticated using (public.is_staff());
revoke all on public.email_log from anon;

-- Staff, or the customer whose order it is (portal), may log an email.
-- Also remembers the address on the order if it had none.
create or replace function public.log_tracking_email(p_so_id uuid, p_to text, p_status text, p_error text default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare so sales_orders%rowtype;
begin
  select * into so from sales_orders where id = p_so_id;
  if not found then raise exception 'Unknown sales order.'; end if;
  if not public.is_trusted() and (auth.uid() is null or so.customer_id is distinct from public.my_customer_id()) then
    raise exception 'Only staff can do this.' using errcode = '42501';
  end if;
  if p_status not in ('sent', 'failed', 'skipped') then raise exception 'Unknown email status %.', p_status; end if;
  if coalesce(p_to, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
  insert into email_log (so_id, to_email, status, error, sent_by)
  values (so.id, lower(trim(p_to)), p_status, left(p_error, 500), auth.uid());
  if so.customer_email is null then
    update sales_orders set customer_email = lower(trim(p_to)) where id = so.id;
  end if;
  perform public._log('email.' || p_status, 'sales_order', so.id,
    format('Tracking email for %s %s: %s', so.order_no,
           case p_status when 'sent' then 'sent' when 'failed' then 'FAILED' else 'not sent (email not set up)' end,
           lower(trim(p_to))),
    '/sales/' || so.id, now());
end;
$$;

-- ---------------------------------------------------------------------------
-- Report a failed print: scrap what failed (good units, if any, go to stock as
-- usual), then create the reprint for the failed quantity with the same sales
-- order link and due date, and start it right away if components are on hand.
-- Returns the reprint's id.
-- ---------------------------------------------------------------------------
create or replace function public.report_print_failure(
  p_mo_id uuid, p_reason text, p_qty_failed numeric default null, p_at timestamptz default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  mo       production_orders%rowtype;
  v_at     timestamptz := coalesce(p_at, now());
  v_failed numeric;
  v_reason text;
  v_new    uuid;
  v_new_no text;
  v_issued boolean := false;
begin
  perform public._require_staff();
  select * into mo from production_orders where id = p_mo_id;
  if not found then raise exception 'Unknown production order.'; end if;
  if mo.status <> 'in_progress' then
    raise exception '% is %; only a print in progress can fail.', mo.mo_no, mo.status;
  end if;
  select description into v_reason from reason_codes where code = p_reason and category = 'scrap' and is_active;
  if not found then raise exception 'Choose what went wrong (a scrap reason).'; end if;
  v_failed := coalesce(p_qty_failed, mo.qty_started);
  if v_failed <= 0 or v_failed > mo.qty_started or v_failed <> trunc(v_failed) then
    raise exception 'Failed quantity must be a whole number from 1 to %.', trim_scale(mo.qty_started);
  end if;

  perform public.complete_production_order(mo.id, mo.qty_started - v_failed, v_failed, p_reason, v_at);

  v_new := public.create_production_order(mo.item_id, least(v_failed, mo.qty_planned), mo.due_date, mo.so_id,
             mo.location_id, mo.output_location_id, format('Reprint of %s (%s)', mo.mo_no, v_reason), v_at);
  select mo_no into v_new_no from production_orders where id = v_new;
  begin
    perform public.issue_production_order(v_new, v_at);
    v_issued := true;
  exception when others then
    v_issued := false;  -- not enough components: the reprint waits as planned
  end;

  perform public._log('production.failure', 'production_order', mo.id,
    format('%s failed (%s, %s scrapped); reprint %s %s', mo.mo_no, v_reason, trim_scale(v_failed), v_new_no,
           case when v_issued then 'started' else 'queued (components short)' end),
    '/production/' || v_new, v_at);
  return v_new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Print failure analytics over completed production orders (by report date).
-- dimension = total | product | color | reason | week
--   scrap_rate  = units scrapped / units started (for reasons: of all units started)
--   wasted_grams = filament issued x scrapped share; scrap_cost = scrapped x rolled-up unit cost
-- ---------------------------------------------------------------------------
create or replace function public.print_failure_analytics(p_from date, p_to date)
returns table (dimension text, key text, label text, orders bigint, failed_orders bigint, units_started numeric,
               units_scrapped numeric, scrap_rate numeric, wasted_grams numeric, scrap_cost numeric)
language sql stable
set search_path = public, pg_temp
as $$
with mo as (
  select v.id, coalesce(v.product_family, v.item_name) as fam, coalesce(i.color, 'Multicolor') as color,
         v.scrap_reason, v.report_date, v.qty_started, v.qty_scrap, v.scrap_cost,
         coalesce((select sum(c.qty_issued) from public.production_order_components c
                     join public.items ci on ci.id = c.item_id
                    where c.mo_id = v.id and ci.category = 'filament'), 0)
           * v.qty_scrap / nullif(v.qty_started, 0) as grams
    from public.v_production_orders v
    join public.items i on i.id = v.item_id
   where v.status = 'completed' and v.report_date between p_from and p_to
), tot as (
  select coalesce(sum(qty_started), 0) as started from mo
), g as (
  select 'total' as dim, 'all' as k, 'All production' as lbl, 0 as sort, mo.* from mo
  union all select 'product', fam, fam, 0, mo.* from mo
  union all select 'color', color, color, 0, mo.* from mo
  union all select 'week', to_char(date_trunc('week', report_date), 'YYYY-MM-DD'),
                   'Week of ' || to_char(date_trunc('week', report_date), 'Mon FMDD'), 0, mo.* from mo
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

revoke execute on function public._order_tracking(uuid) from public, anon, authenticated;
revoke execute on function public.log_tracking_email(uuid, text, text, text), public.report_print_failure(uuid, text, numeric, timestamptz),
  public.print_failure_analytics(date, date) from public, anon;
grant execute on function public.track_order(text) to anon, authenticated;
grant execute on function public.log_tracking_email(uuid, text, text, text), public.report_print_failure(uuid, text, numeric, timestamptz),
  public.print_failure_analytics(date, date) to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'email_log') then
    alter publication supabase_realtime add table public.email_log;
  end if;
end $$;
