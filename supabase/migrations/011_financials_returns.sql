-- =============================================================================
-- 011_financials_returns.sql — P&L, inventory valuation, turnover, return preview (Phase 8)
--
-- All financial reports read the ledger (journals posted by the business
-- functions), so they change live when a sale, return, receipt, production
-- order or adjustment is posted anywhere in the system.
--   * pl_report(from, to)            Profit & Loss lines for a date range
--   * inventory_turnover(from, to)   COGS / average inventory value (daily ledger balance)
--   * v_inventory_by_location        stock value by item and location at weighted-average cost
--   * quote_return(p)                preview of process_return: runs the real
--                                    function, reads the result, then undoes it
-- Dates are business dates in the company time zone.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Profit & Loss
--   Gross sales - discounts - returns = net sales
--   + shipping revenue + restocking fees = total revenue
--   - COGS - packaging & fulfillment = gross profit
--   - inventory adjustments (realized losses) - production scrap (cost of poor quality)
--   = net income
-- Revenue amounts are credits - debits; contra-revenue and expenses are debits - credits.
-- ---------------------------------------------------------------------------
create or replace function public.pl_report(p_from date, p_to date)
returns table (line_no int, label text, account_code text, amount numeric, kind text)
language sql stable
set search_path = public, pg_temp
as $$
with p as (
  select public.setting_text('time_zone') as tz
), b as (
  select l.account_code as code, sum(l.credit - l.debit) as cr, sum(l.debit - l.credit) as dr
    from public.ledger l cross join p
   where l.posted_at >= (p_from::timestamp at time zone p.tz)
     and l.posted_at <  ((p_to + 1)::timestamp at time zone p.tz)
   group by l.account_code
), a as (
  select coalesce((select cr from b where code = '4000'), 0) as gross,
         coalesce((select dr from b where code = '4100'), 0) as disc,
         coalesce((select dr from b where code = '4400'), 0) as ret,
         coalesce((select cr from b where code = '4200'), 0) as ship,
         coalesce((select cr from b where code = '4300'), 0) as fee,
         coalesce((select dr from b where code = '5000'), 0) as cogs,
         coalesce((select dr from b where code = '5100'), 0) as pack,
         coalesce((select dr from b where code = '5200'), 0) as adj,
         coalesce((select dr from b where code = '5300'), 0) as scrap
)
select x.line_no, x.label, x.code, x.amount, x.kind
  from a cross join lateral (values
    ( 1, 'Gross sales',                                   '4000', a.gross,                                 'line'),
    ( 2, 'Sales discounts',                               '4100', -a.disc,                                 'line'),
    ( 3, 'Sales returns',                                 '4400', -a.ret,                                  'line'),
    ( 4, 'Net sales',                                     null,   a.gross - a.disc - a.ret,                'subtotal'),
    ( 5, 'Shipping revenue',                              '4200', a.ship,                                  'line'),
    ( 6, 'Restocking fees',                               '4300', a.fee,                                   'line'),
    ( 7, 'Total revenue',                                 null,   a.gross - a.disc - a.ret + a.ship + a.fee, 'subtotal'),
    ( 8, 'Cost of goods sold',                            '5000', -a.cogs,                                 'line'),
    ( 9, 'Packaging & fulfillment',                       '5100', -a.pack,                                 'line'),
    (10, 'Gross profit',                                  null,   a.gross - a.disc - a.ret + a.ship + a.fee - a.cogs - a.pack, 'subtotal'),
    (11, 'Inventory adjustments (realized losses)',       '5200', -a.adj,                                  'line'),
    (12, 'Production scrap (cost of poor quality)',       '5300', -a.scrap,                                'line'),
    (13, 'Net income',                                    null,   a.gross - a.disc - a.ret + a.ship + a.fee - a.cogs - a.pack - a.adj - a.scrap, 'total')
  ) as x(line_no, label, code, amount, kind)
 order by x.line_no;
$$;

-- ---------------------------------------------------------------------------
-- Inventory turnover = COGS in the period / average inventory value, where the
-- average is the mean of the end-of-day Inventory (1200) ledger balance over
-- every day in the period. Annualized = turnover x 365 / days.
-- ---------------------------------------------------------------------------
create or replace function public.inventory_turnover(p_from date, p_to date)
returns table (cogs numeric, begin_inventory numeric, end_inventory numeric, avg_inventory numeric,
               days int, turnover numeric, annualized_turnover numeric, days_of_inventory numeric)
language sql stable
set search_path = public, pg_temp
as $$
with p as (
  select public.setting_text('time_zone') as tz
), opening as (
  select coalesce(sum(l.debit - l.credit), 0) as v
    from public.ledger l cross join p
   where l.account_code = '1200' and l.posted_at < (p_from::timestamp at time zone p.tz)
), daily as (
  select (l.posted_at at time zone p.tz)::date as d, sum(l.debit - l.credit) as v
    from public.ledger l cross join p
   where l.account_code = '1200'
     and l.posted_at >= (p_from::timestamp at time zone p.tz)
     and l.posted_at <  ((p_to + 1)::timestamp at time zone p.tz)
   group by 1
), series as (
  select g::date as d,
         (select v from opening) + coalesce(sum(daily.v) over (order by g rows unbounded preceding), 0) as bal
    from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') g
    left join daily on daily.d = g::date
), c as (
  select coalesce(sum(l.debit - l.credit), 0) as v
    from public.ledger l cross join p
   where l.account_code = '5000'
     and l.posted_at >= (p_from::timestamp at time zone p.tz)
     and l.posted_at <  ((p_to + 1)::timestamp at time zone p.tz)
), s as (
  select avg(bal) as avg_bal, count(*)::int as n,
         (select v from opening) as begin_bal,
         (select bal from series order by d desc limit 1) as end_bal
    from series
)
select c.v, round(s.begin_bal, 2), round(s.end_bal, 2), round(s.avg_bal, 2), s.n,
       round(c.v / nullif(s.avg_bal, 0), 2),
       round(c.v / nullif(s.avg_bal, 0) * 365 / s.n, 2),
       round(s.n / nullif(c.v / nullif(s.avg_bal, 0), 0), 1)
  from c cross join s;
$$;

-- Stock value by item and location (weighted-average cost is per item).
create or replace view public.v_inventory_by_location with (security_invoker = true) as
select t.item_id, t.location_id, sum(t.qty) as qty_on_hand,
       public.item_unit_cost(t.item_id) as avg_unit_cost,
       round(sum(t.qty) * public.item_unit_cost(t.item_id), 2) as inventory_value
  from public.inventory_txn t
 group by t.item_id, t.location_id
having sum(t.qty) <> 0;

-- ---------------------------------------------------------------------------
-- Return preview. Same input as process_return. The real function runs inside a
-- sub-transaction so the preview uses exactly the same rules (QA Hold, 30-day
-- window, restocking fee, tax, exchange pricing); then it is rolled back, so
-- nothing is saved. Errors are the same plain-English messages.
-- Returns { merchandise_credit, tax_credit, restocking_fee, exchange_total,
--   refund_amount, return_type, refund_to, exchange: {subtotal, discount_amount,
--   tax_amount, total, will_ship_now}, lines: [{so_line_id, item_id, qty,
--   reason_code, disposition, location_id, net_unit_price, unit_cost}] }
-- ---------------------------------------------------------------------------
create or replace function public.quote_return(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
  v_id uuid;
begin
  perform public._require_staff();
  begin
    v_id := public.process_return(p);
    select jsonb_build_object(
             'return_type', r.return_type,
             'merchandise_credit', r.merchandise_credit, 'tax_credit', r.tax_credit,
             'restocking_fee', r.restocking_fee, 'exchange_total', r.exchange_total,
             'refund_amount', r.refund_amount,
             'refund_to', case when so.payment_method = 'account' and so.status <> 'closed'
                               then 'account' else coalesce(so.payment_method, 'card') end,
             'exchange', (select jsonb_build_object('subtotal', x.subtotal, 'discount_amount', x.discount_amount,
                                                    'tax_amount', x.tax_amount, 'total', x.total,
                                                    'will_ship_now', x.status = 'fulfilled')
                            from sales_orders x where x.id = r.exchange_so_id),
             'lines', (select jsonb_agg(jsonb_build_object('so_line_id', rl.so_line_id, 'item_id', rl.item_id,
                                                           'qty', rl.qty, 'reason_code', rl.reason_code,
                                                           'disposition', rl.disposition, 'location_id', rl.location_id,
                                                           'net_unit_price', rl.net_unit_price, 'unit_cost', rl.unit_cost))
                         from return_lines rl where rl.return_id = r.id))
      into v
      from returns r join sales_orders so on so.id = r.so_id
     where r.id = v_id;
    -- Undo everything process_return did (the variable v keeps the result).
    raise exception using errcode = 'QRBK1', message = 'quote rollback';
  exception when sqlstate 'QRBK1' then
    return v;
  end;
end;
$$;

grant execute on function
  public.pl_report(date, date),
  public.inventory_turnover(date, date)
  to authenticated;
revoke execute on function public.quote_return(jsonb) from public, anon;
grant execute on function public.quote_return(jsonb) to authenticated;
grant select on public.v_inventory_by_location to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'return_lines') then
    alter publication supabase_realtime add table public.return_lines;
  end if;
end $$;
