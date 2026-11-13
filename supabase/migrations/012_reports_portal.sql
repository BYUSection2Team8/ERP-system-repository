-- =============================================================================
-- 012_reports_portal.sql — manager reports, customer portal, live stock signal (Phase 9)
--
--   * sales_by_period(from, to, grain)  sales by day or week, from the ledger
--   * top_sellers(from, to, limit)      units, revenue, COGS and margin per item
--   * portal_catalog()                  what a signed-in customer may order, with
--                                       available stock by pickup location
--   * portal_quote_order(p) / portal_place_order(p) / portal_cancel_order(id)
--                                       customer pickup orders (same pricing as staff)
--   * portal_order_backorders()         estimated dates for the customer's own short lines
--   * live_signals                      one row bumped whenever stock or orders change,
--                                       so customer screens (which cannot read stock
--                                       movements) still refresh live through Realtime
-- Low stock, inventory by location and supplier performance reuse the views from
-- 003 / 010 / 011 (v_reorder_plan, v_availability, v_supplier_scorecard).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Sales by day or week (business dates in the company time zone).
-- Money comes from the ledger (revenue is recognized when an order is fulfilled):
--   gross = 4000, discounts = 4100, returns = 4400, COGS = 5000 (net of returns)
--   net sales = gross - discounts - returns; gross profit = net sales - COGS
-- Orders / units = sales orders fulfilled in the period and their quantities.
-- Every day (or week) in the range gets a row, zero if nothing happened.
-- ---------------------------------------------------------------------------
create or replace function public.sales_by_period(p_from date, p_to date, p_grain text default 'day')
returns table (period_start date, orders bigint, units numeric, gross_sales numeric, discounts numeric,
               returns numeric, net_sales numeric, cogs numeric, gross_profit numeric)
language sql stable
set search_path = public, pg_temp
as $$
with p as (
  select public.setting_text('time_zone') as tz,
         case when p_grain = 'week' then 'week' else 'day' end as g,
         (p_from::timestamp at time zone public.setting_text('time_zone')) as t0,
         ((p_to + 1)::timestamp at time zone public.setting_text('time_zone')) as t1
), periods as (
  select distinct date_trunc(p.g, d)::date as ps
    from p cross join generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
), led as (
  select date_trunc(p.g, l.posted_at at time zone p.tz)::date as ps,
         sum(case when l.account_code = '4000' then l.credit - l.debit else 0 end) as gross,
         sum(case when l.account_code = '4100' then l.debit - l.credit else 0 end) as disc,
         sum(case when l.account_code = '4400' then l.debit - l.credit else 0 end) as ret,
         sum(case when l.account_code = '5000' then l.debit - l.credit else 0 end) as cogs
    from public.ledger l cross join p
   where l.posted_at >= p.t0 and l.posted_at < p.t1
     and l.account_code in ('4000','4100','4400','5000')
   group by 1
), ord as (
  select date_trunc(p.g, so.fulfilled_at at time zone p.tz)::date as ps,
         count(distinct so.id) as n, coalesce(sum(sl.qty), 0) as units
    from public.sales_orders so
    cross join p
    join public.sales_order_lines sl on sl.so_id = so.id
   where so.fulfilled_at >= p.t0 and so.fulfilled_at < p.t1
   group by 1
)
select pr.ps,
       coalesce(o.n, 0),
       coalesce(o.units, 0),
       coalesce(led.gross, 0),
       coalesce(led.disc, 0),
       coalesce(led.ret, 0),
       coalesce(led.gross, 0) - coalesce(led.disc, 0) - coalesce(led.ret, 0),
       coalesce(led.cogs, 0),
       coalesce(led.gross, 0) - coalesce(led.disc, 0) - coalesce(led.ret, 0) - coalesce(led.cogs, 0)
  from periods pr
  left join led on led.ps = pr.ps
  left join ord o on o.ps = pr.ps
 order by pr.ps;
$$;

-- ---------------------------------------------------------------------------
-- Top sellers: per item, for orders fulfilled in the period.
--   net revenue = qty x net unit price (after the order discount)
--   COGS = qty x weighted-average cost at fulfillment
--   units returned / returned value = returns processed in the period
-- p_limit null = every item that sold.
-- ---------------------------------------------------------------------------
create or replace function public.top_sellers(p_from date, p_to date, p_limit int default null)
returns table (item_id uuid, sku text, name text, product_family text, orders bigint, units_sold numeric,
               net_revenue numeric, cogs numeric, gross_profit numeric, margin_pct numeric,
               units_returned numeric, returned_value numeric)
language sql stable
set search_path = public, pg_temp
as $$
with p as (
  select (p_from::timestamp at time zone public.setting_text('time_zone')) as t0,
         ((p_to + 1)::timestamp at time zone public.setting_text('time_zone')) as t1
), sold as (
  select sl.item_id, count(distinct so.id) as orders, sum(sl.qty) as units,
         sum(round(sl.qty * sl.net_unit_price, 2)) as revenue,
         sum(round(sl.qty * coalesce(sl.unit_cost, 0), 2)) as cogs
    from public.sales_orders so
    cross join p
    join public.sales_order_lines sl on sl.so_id = so.id
   where so.fulfilled_at >= p.t0 and so.fulfilled_at < p.t1
   group by sl.item_id
), ret as (
  select rl.item_id, sum(rl.qty) as units, sum(round(rl.qty * rl.net_unit_price, 2)) as value
    from public.returns r
    cross join p
    join public.return_lines rl on rl.return_id = r.id
   where r.returned_at >= p.t0 and r.returned_at < p.t1
   group by rl.item_id
)
select i.id, i.sku, i.name, i.product_family, s.orders, s.units,
       s.revenue, s.cogs, s.revenue - s.cogs,
       case when s.revenue > 0 then round((s.revenue - s.cogs) / s.revenue, 4) end,
       coalesce(r.units, 0), coalesce(r.value, 0)
  from sold s
  join public.items i on i.id = s.item_id
  left join ret r on r.item_id = s.item_id
 order by s.revenue desc, s.units desc, i.name
 limit p_limit;
$$;

grant execute on function
  public.sales_by_period(date, date, text),
  public.top_sellers(date, date, int)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Live signal for screens that cannot read stock movements (customer portal).
-- A statement-level trigger bumps one row; Realtime pushes the change to every
-- signed-in user, whose screen then reloads what it is allowed to see.
-- ---------------------------------------------------------------------------
create table if not exists public.live_signals (
  topic      text primary key,
  changed_at timestamptz not null default now()
);
alter table public.live_signals enable row level security;
drop policy if exists signed_in_read on public.live_signals;
create policy signed_in_read on public.live_signals for select to authenticated using (true);
revoke all on public.live_signals from anon;
insert into public.live_signals (topic) values ('stock') on conflict (topic) do nothing;

create or replace function public._signal_stock_change()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  update public.live_signals set changed_at = clock_timestamp() where topic = 'stock';
  return null;
end;
$$;

drop trigger if exists inventory_txn_live_signal on public.inventory_txn;
create trigger inventory_txn_live_signal
  after insert on public.inventory_txn
  for each statement execute function public._signal_stock_change();
drop trigger if exists sales_orders_live_signal on public.sales_orders;
create trigger sales_orders_live_signal
  after insert or update on public.sales_orders
  for each statement execute function public._signal_stock_change();

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'live_signals') then
    alter publication supabase_realtime add table public.live_signals;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Sales order insert, shared by staff (create_sales_order) and the portal.
-- Same body as 007's create_sales_order, without the staff check; the callers
-- decide who may place what. Not callable from the app.
-- ---------------------------------------------------------------------------
create or replace function public._insert_sales_order(p jsonb)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_at timestamptz := coalesce((p->>'order_date')::timestamptz, now());
  q    jsonb;
  r    jsonb;
  v_id uuid;
  v_no text;
begin
  q := public._price_sales_order(p);

  insert into sales_orders (customer_id, channel, fulfillment_method, location_id, status, order_date,
                            need_date, ship_state, discount_type, discount_pct, discount_reason,
                            tax_rate, payment_method, customer_email, notes, created_by, created_at,
                            subtotal, discount_amount, shipping_amount, tax_amount, total)
  values ((q->>'customer_id')::uuid, q->>'channel', q->>'fulfillment_method', (q->>'location_id')::uuid,
          'placed', v_at, (q->>'need_date')::date, q->>'ship_state', q->>'discount_type',
          (q->>'discount_pct')::numeric, q->>'discount_reason', (q->>'tax_rate')::numeric,
          q->>'payment_method', q->>'customer_email', nullif(p->>'notes', ''), auth.uid(), v_at,
          (q->>'subtotal')::numeric, (q->>'discount_amount')::numeric, (q->>'shipping_amount')::numeric,
          (q->>'tax_amount')::numeric, (q->>'total')::numeric)
  returning id, order_no into v_id, v_no;

  for r in select * from jsonb_array_elements(q->'lines') loop
    insert into sales_order_lines (so_id, line_no, item_id, qty, unit_price, net_unit_price, line_total)
    values (v_id, (r->>'line_no')::int, (r->>'item_id')::uuid, (r->>'qty')::numeric,
            (r->>'unit_price')::numeric, (r->>'net_unit_price')::numeric, (r->>'line_total')::numeric);
  end loop;

  perform public._log('sales_order.placed', 'sales_order', v_id,
    format('%s placed for %s%s: $%s', v_no, coalesce(q->>'customer_name', 'walk-in customer'),
           case when q->>'channel' = 'portal' then ' (customer portal)' else '' end,
           to_char((q->>'total')::numeric, 'FM999,999,990.00')),
    '/sales/' || v_id, v_at);
  return v_id;
end;
$$;

create or replace function public.create_sales_order(p jsonb)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform public._require_staff();
  return public._insert_sales_order(p);
end;
$$;

-- ---------------------------------------------------------------------------
-- Customer portal
-- ---------------------------------------------------------------------------

-- Is an item sellable on this date? Seasonal items only inside their MM-DD window
-- (the window may wrap past New Year).
create or replace function public._in_season(p_policy text, p_start text, p_end text, p_day date)
returns boolean
language sql stable
set search_path = public, pg_temp
as $$
  select p_policy <> 'seasonal' or p_start is null or p_end is null
      or case when p_start <= p_end then to_char(p_day, 'MM-DD') between p_start and p_end
              else to_char(p_day, 'MM-DD') >= p_start or to_char(p_day, 'MM-DD') <= p_end end;
$$;

-- Signed in (any role), or a trusted direct session.
create or replace function public._require_signed_in()
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null and not public.is_trusted() then
    raise exception 'Please sign in first.' using errcode = '42501';
  end if;
end;
$$;

-- Products a customer may order, by pickup location, with available stock
-- (on hand minus what open orders already reserved, never below zero) and, when
-- none is available there, the estimated date it will be.
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
     and i.stocking_policy <> 'not_sold'
     and public._in_season(i.stocking_policy, i.season_start, i.season_end, v_today)
     and l.is_active and l.is_sellable and l.kind in ('retail','storage')
   order by i.product_family nulls last, i.name, l.sort_order;
end;
$$;

-- Turn what the customer sent into a create_sales_order payload. Everything that
-- matters is set here, not by the browser: the customer is the signed-in one,
-- channel = portal, pickup only, discount by the customer's own eligibility
-- (BYU student, or business at the bulk minimum), pay at pickup or on account.
-- p = {location_id, lines: [{item_id, qty}], need_date?, notes?}
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
       or v_item.stocking_policy = 'not_sold'
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

-- Price a portal order without saving it (same numbers the order will have).
create or replace function public.portal_quote_order(p jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  return public._price_sales_order(public._portal_order_payload(p));
end;
$$;

-- Place a pickup order. It starts as Order placed; staff fulfill it when the
-- customer picks it up. Short lines wait as backorders (MRP plans them).
create or replace function public.portal_place_order(p jsonb)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  return public._insert_sales_order(public._portal_order_payload(p));
end;
$$;

-- A customer may cancel their own order while it is still Order placed.
create or replace function public.portal_cancel_order(p_so_id uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare so sales_orders%rowtype;
begin
  if auth.uid() is null then raise exception 'Please sign in first.' using errcode = '42501'; end if;
  select * into so from sales_orders where id = p_so_id for update;
  if not found or so.customer_id is distinct from public.my_customer_id() then
    raise exception 'That order is not on your account.';
  end if;
  if so.status <> 'placed' then
    raise exception 'Order % is already %; please contact us for a return instead.', so.order_no,
      case so.status when 'fulfilled' then 'fulfilled' when 'closed' then 'closed' else so.status end;
  end if;
  if exists (select 1 from production_orders where so_id = so.id and status = 'in_progress') then
    raise exception 'Order % is already being printed; please contact us to change it.', so.order_no;
  end if;
  update sales_orders set status = 'cancelled', cancelled_at = now(), cancel_reason = 'Cancelled by customer (portal)'
   where id = so.id;
  update production_orders set status = 'cancelled', notes = coalesce(notes || ' ', '') || '(order cancelled)'
   where so_id = so.id and status = 'planned';
  perform public._log('sales_order.cancelled', 'sales_order', so.id,
    so.order_no || ' cancelled by the customer in the portal', '/sales/' || so.id, now());
end;
$$;

-- The customer's own short order lines with estimated available dates
-- (customers cannot read stock, so v_backorders must run as the owner).
create or replace function public.portal_order_backorders()
returns table (so_id uuid, so_line_id uuid, item_id uuid, qty_backordered numeric, est_available_date date)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform public._require_signed_in();
  return query
  select b.so_id, b.so_line_id, b.item_id, b.qty_backordered, b.est_available_date
    from v_backorders b
   where b.customer_id = public.my_customer_id();
end;
$$;

revoke execute on function
  public._insert_sales_order(jsonb), public._portal_order_payload(jsonb),
  public._signal_stock_change(), public._in_season(text, text, text, date)
  from public, anon, authenticated;
revoke execute on function
  public._require_signed_in(), public.portal_catalog(), public.portal_quote_order(jsonb),
  public.portal_place_order(jsonb), public.portal_cancel_order(uuid), public.portal_order_backorders(),
  public.create_sales_order(jsonb)
  from public, anon;
grant execute on function
  public.portal_catalog(), public.portal_quote_order(jsonb), public.portal_place_order(jsonb),
  public.portal_cancel_order(uuid), public.portal_order_backorders(), public.create_sales_order(jsonb)
  to authenticated;
