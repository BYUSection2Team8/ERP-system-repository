-- =============================================================================
-- 004_functions.sql — core business functions (all-or-nothing transactions)
--
-- Every business action that moves stock or money is ONE function call, so it
-- succeeds or fails as a whole. Each one:
--   1. checks the caller is staff (or a trusted SQL Editor session),
--   2. writes stock movements to inventory_txn via _inv_move,
--   3. posts a balanced journal to ledger via _post_journal,
--   4. writes a line to activity_log.
-- Every function takes an optional timestamp (p_at / *_date) so Phase 6 can
-- generate six months of history by calling these same functions.
--
-- Called from the app with supabase.rpc('<name>', {...}).
--
-- Accounts used (rows in 005_reference_data.sql):
--   1000 Cash  1100 A/R  1200 Inventory  1250 WIP
--   2000 A/P  2100 Sales tax payable  2300 Accrued production labor & machine
--   3000 Owner's equity
--   4000 Product sales  4100 Sales discounts  4200 Shipping revenue
--   4300 Restocking fees  4400 Sales returns
--   5000 COGS  5100 Packaging & fulfillment  5200 Inventory adjustments
--   5300 Production scrap
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Internal helpers (not callable from the app)
-- ---------------------------------------------------------------------------
create or replace function public._require_staff()
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_trusted() then
    raise exception 'Only staff can do this.' using errcode = '42501';
  end if;
end;
$$;

create or replace function public._actor()
returns text
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce((select nullif(full_name, '') from profiles where id = auth.uid()), 'system');
$$;

create or replace function public._log(
  p_action text, p_entity_type text, p_entity_id uuid, p_summary text,
  p_link text default null, p_at timestamptz default null)
returns void
language sql security definer
set search_path = public, pg_temp
as $$
  insert into activity_log (at, user_id, actor, action, entity_type, entity_id, summary, link)
  values (coalesce(p_at, now()), auth.uid(), public._actor(), p_action, p_entity_type,
          p_entity_id, p_summary, p_link);
$$;

create or replace function public._location_id(p_code text)
returns uuid
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v uuid;
begin
  select id into v from locations where code = p_code;
  if not found then raise exception 'Unknown location code %', p_code; end if;
  return v;
end;
$$;

-- Business date in the company's time zone (Utah).
create or replace function public._local_date(p_at timestamptz)
returns date
language sql stable
set search_path = public, pg_temp
as $$ select (p_at at time zone public.setting_text('time_zone'))::date; $$;

-- Post a balanced journal. p_lines = [{account, debit, credit, item_id?,
-- location_id?, customer_id?, supplier_id?, memo?}, ...]. Amounts are rounded
-- to cents; a negative amount flips to the other side; zero lines are skipped.
-- Raises if debits <> credits. Returns the journal id (null if all zero).
create or replace function public._post_journal(
  p_source_type text, p_source_id uuid, p_at timestamptz, p_memo text, p_lines jsonb)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  r     jsonb;
  v_net numeric;
  v_dr  numeric := 0;
  v_cr  numeric := 0;
  v_id  uuid;
begin
  for r in select * from jsonb_array_elements(p_lines) loop
    v_net := round(coalesce((r->>'debit')::numeric, 0), 2) - round(coalesce((r->>'credit')::numeric, 0), 2);
    if v_net > 0 then v_dr := v_dr + v_net; else v_cr := v_cr - v_net; end if;
  end loop;

  if v_dr <> v_cr then
    raise exception 'Journal out of balance for % %: debits % vs credits %',
      p_source_type, p_source_id, v_dr, v_cr;
  end if;
  if v_dr = 0 then return null; end if;

  insert into journals (posted_at, source_type, source_id, memo, created_by)
  values (p_at, p_source_type, p_source_id, p_memo, auth.uid())
  returning id into v_id;

  for r in select * from jsonb_array_elements(p_lines) loop
    v_net := round(coalesce((r->>'debit')::numeric, 0), 2) - round(coalesce((r->>'credit')::numeric, 0), 2);
    continue when v_net = 0;
    insert into ledger (journal_id, posted_at, account_code, debit, credit, source_type, source_id,
                        item_id, location_id, customer_id, supplier_id, memo)
    values (v_id, p_at, r->>'account', greatest(v_net, 0), greatest(-v_net, 0), p_source_type, p_source_id,
            (r->>'item_id')::uuid, (r->>'location_id')::uuid, (r->>'customer_id')::uuid,
            (r->>'supplier_id')::uuid, coalesce(r->>'memo', p_memo));
  end loop;

  -- Link the stock movements of this transaction to its journal.
  update inventory_txn set journal_id = v_id
   where source_id = p_source_id and journal_id is null;
  return v_id;
end;
$$;

-- Move stock. qty > 0 = in, qty < 0 = out. Outflows default to the current
-- weighted-average cost; inflows must say their cost (or default to average).
-- Locks the item row so concurrent users cannot oversell. Returns the unit cost used.
create or replace function public._inv_move(
  p_item uuid, p_location uuid, p_qty numeric, p_unit_cost numeric,
  p_source_type text, p_source_id uuid, p_source_line_id uuid,
  p_reason text, p_at timestamptz, p_note text)
returns numeric
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_name text;
  v_have numeric;
  v_loc  text;
  v_cost numeric;
begin
  if p_qty is null or p_qty = 0 then
    raise exception 'Quantity must not be zero.';
  end if;

  select name into v_name from items where id = p_item for update;
  if not found then raise exception 'Unknown item %', p_item; end if;

  if p_qty < 0 and not public.setting_text('allow_negative_inventory')::boolean then
    select coalesce(sum(qty), 0) into v_have
      from inventory_txn where item_id = p_item and location_id = p_location;
    if v_have + p_qty < 0 then
      select name into v_loc from locations where id = p_location;
      raise exception 'Not enough % at %: on hand %, needed %.',
        v_name, coalesce(v_loc, '?'), trim_scale(v_have), trim_scale(-p_qty);
    end if;
  end if;

  v_cost := round(coalesce(p_unit_cost, public.item_unit_cost(p_item)), 6);

  insert into inventory_txn (txn_at, item_id, location_id, qty, unit_cost, source_type,
                             source_id, source_line_id, reason_code, note, created_by)
  values (coalesce(p_at, now()), p_item, p_location, p_qty, v_cost, p_source_type,
          p_source_id, p_source_line_id, p_reason, p_note, auth.uid());
  return v_cost;
end;
$$;

-- ===========================================================================
-- INVENTORY
-- ===========================================================================

-- Opening balance: stock that existed before the system went live.
-- Dr Inventory / Cr Owner's equity.
create or replace function public.receive_opening_inventory(
  p_item uuid, p_location uuid, p_qty numeric, p_unit_cost numeric default null,
  p_at timestamptz default null, p_note text default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id   uuid := gen_random_uuid();
  v_at   timestamptz := coalesce(p_at, now());
  v_cost numeric;
begin
  perform public._require_staff();
  if p_qty is null or p_qty <= 0 then raise exception 'Opening quantity must be positive.'; end if;
  v_cost := public._inv_move(p_item, p_location, p_qty, p_unit_cost, 'opening', v_id, null, null, v_at,
                             coalesce(p_note, 'Opening balance'));
  perform public._post_journal('opening', v_id, v_at, 'Opening inventory', jsonb_build_array(
    jsonb_build_object('account', '1200', 'debit',  p_qty * v_cost, 'item_id', p_item, 'location_id', p_location),
    jsonb_build_object('account', '3000', 'credit', p_qty * v_cost)));
  perform public._log('inventory.opening', 'item', p_item,
    format('Opening balance %s of %s', trim_scale(p_qty), (select name from items where id = p_item)),
    '/inventory', v_at);
  return v_id;
end;
$$;

-- Move stock between locations. p_lines = [{"item_id": "...", "qty": 5}, ...]
-- Cost moves with the goods (no ledger effect: inventory stays inventory).
create or replace function public.transfer_inventory(
  p_from uuid, p_to uuid, p_lines jsonb, p_note text default null, p_at timestamptz default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id   uuid := gen_random_uuid();
  v_at   timestamptz := coalesce(p_at, now());
  r      jsonb;
  v_qty  numeric;
  v_cost numeric;
  v_n    int := 0;
begin
  perform public._require_staff();
  if p_from = p_to then raise exception 'Choose two different locations.'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A transfer needs at least one line.';
  end if;

  for r in select * from jsonb_array_elements(p_lines) loop
    v_qty := (r->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'Transfer quantities must be positive.'; end if;
    v_cost := public._inv_move((r->>'item_id')::uuid, p_from, -v_qty, null, 'transfer_out', v_id, null, null, v_at, p_note);
    perform public._inv_move((r->>'item_id')::uuid, p_to, v_qty, v_cost, 'transfer_in', v_id, null, null, v_at, p_note);
    v_n := v_n + 1;
  end loop;

  perform public._log('inventory.transfer', 'transfer', v_id,
    format('Transferred %s item line(s) from %s to %s', v_n,
      (select name from locations where id = p_from), (select name from locations where id = p_to)),
    '/inventory', v_at);
  return v_id;
end;
$$;

-- Adjust on-hand by a signed quantity with a reason code (damaged, lost, count...).
-- Loss: Dr Inventory adjustments (realized loss) / Cr Inventory. Gain: reverse.
create or replace function public.adjust_inventory(
  p_item uuid, p_location uuid, p_qty_delta numeric, p_reason text,
  p_note text default null, p_at timestamptz default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id   uuid := gen_random_uuid();
  v_at   timestamptz := coalesce(p_at, now());
  v_cost numeric;
  v_val  numeric;
begin
  perform public._require_staff();
  if p_qty_delta is null or p_qty_delta = 0 then raise exception 'Adjustment quantity must not be zero.'; end if;
  if not exists (select 1 from reason_codes where code = p_reason and category = 'adjustment' and is_active) then
    raise exception 'Choose an adjustment reason code.';
  end if;

  v_cost := public._inv_move(p_item, p_location, p_qty_delta, null, 'adjustment', v_id, null, p_reason, v_at, p_note);
  v_val  := abs(p_qty_delta) * v_cost;

  perform public._post_journal('adjustment', v_id, v_at, 'Inventory adjustment ' || p_reason,
    case when p_qty_delta < 0 then jsonb_build_array(
      jsonb_build_object('account', '5200', 'debit',  v_val, 'item_id', p_item, 'location_id', p_location),
      jsonb_build_object('account', '1200', 'credit', v_val, 'item_id', p_item, 'location_id', p_location))
    else jsonb_build_array(
      jsonb_build_object('account', '1200', 'debit',  v_val, 'item_id', p_item, 'location_id', p_location),
      jsonb_build_object('account', '5200', 'credit', v_val, 'item_id', p_item, 'location_id', p_location))
    end);

  perform public._log('inventory.adjust', 'item', p_item,
    format('Adjusted %s by %s at %s (%s)', (select name from items where id = p_item),
      trim_scale(p_qty_delta), (select name from locations where id = p_location), p_reason),
    '/inventory', v_at);
  return v_id;
end;
$$;

-- Cycle count: enter what is physically there; the system posts the difference.
-- Returns null when the count matches.
create or replace function public.count_inventory(
  p_item uuid, p_location uuid, p_counted numeric, p_reason text default 'ADJ_CYCLE_COUNT',
  p_note text default null, p_at timestamptz default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_have numeric;
begin
  perform public._require_staff();
  if p_counted is null or p_counted < 0 then raise exception 'Counted quantity cannot be negative.'; end if;
  select coalesce(sum(qty), 0) into v_have
    from inventory_txn where item_id = p_item and location_id = p_location;
  if p_counted = v_have then return null; end if;
  return public.adjust_inventory(p_item, p_location, p_counted - v_have, p_reason,
    coalesce(p_note, format('Counted %s, system had %s', trim_scale(p_counted), trim_scale(v_have))), p_at);
end;
$$;

-- ===========================================================================
-- SALES ORDERS + POS
-- ===========================================================================

-- Create a sales order (status 'placed'). Prices, discount, shipping and tax
-- are computed here from items + settings, never passed in.
-- p = {
--   customer_id, channel ('online'|'phone'|'portal'|'pos'),
--   fulfillment_method ('ship'|'pickup'|'counter'), location_id | location_code,
--   need_date, ship_state, discount_type ('none'|'byu'|'business'|'manual'),
--   discount_pct (manual only), discount_reason (manual only),
--   payment_method ('cash'|'card'|'account'), customer_email, notes, order_date,
--   waive_shipping (bool), exchange_of (so id; copies that order's discount),
--   lines: [{item_id, qty}, ...]
-- }
create or replace function public.create_sales_order(p jsonb)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_at      timestamptz := coalesce((p->>'order_date')::timestamptz, now());
  v_channel text := coalesce(p->>'channel', 'online');
  v_method  text;
  v_loc     locations%rowtype;
  v_cust    customers%rowtype;
  v_orig    sales_orders%rowtype;
  v_dtype   text := coalesce(p->>'discount_type', 'none');
  v_pct     numeric := 0;
  v_reason  text;
  v_state   text;
  v_rate    numeric := 0;
  v_pay     text;
  v_sub     numeric := 0;
  v_units   numeric := 0;
  v_disc    numeric;
  v_ship    numeric := 0;
  v_tax     numeric;
  v_id      uuid;
  v_no      text;
  v_line    int := 0;
  r         jsonb;
  v_item    items%rowtype;
  v_qty     numeric;
begin
  perform public._require_staff();

  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') = 0 then
    raise exception 'An order needs at least one line.';
  end if;
  if v_channel not in ('online','phone','portal','pos') then
    raise exception 'Unknown channel %', v_channel;
  end if;
  v_method := coalesce(p->>'fulfillment_method', case when v_channel = 'pos' then 'counter' else 'ship' end);

  -- Customer (optional only for walk-in POS sales)
  if p->>'customer_id' is not null then
    select * into v_cust from customers where id = (p->>'customer_id')::uuid;
    if not found then raise exception 'Unknown customer.'; end if;
  elsif v_channel <> 'pos' then
    raise exception 'Choose a customer for this order.';
  end if;

  -- Location the order ships / is picked up from
  select * into v_loc from locations
   where id = coalesce((p->>'location_id')::uuid, public._location_id(coalesce(p->>'location_code',
           case when v_method = 'ship' then 'FULFILLMENT' else 'CAMPUS' end)));
  if not found or not v_loc.is_sellable or not v_loc.is_active then
    raise exception 'Orders cannot be filled from that location.';
  end if;

  -- Tax: Utah orders only; pickup/counter sales happen in Utah. Shipping is not taxed.
  if v_method = 'ship' then
    v_state := upper(coalesce(p->>'ship_state', v_cust.state));
    if v_state is null then raise exception 'Enter the ship-to state (needed for sales tax).'; end if;
  else
    v_state := upper(public.setting_text('tax_state'));
  end if;
  if v_state = upper(public.setting_text('tax_state')) then
    v_rate := public.setting_num('sales_tax_rate');
  end if;

  -- Payment: customers with terms (businesses) default to on-account.
  v_pay := coalesce(p->>'payment_method',
                    case when coalesce(v_cust.terms_days, 0) > 0 then 'account' else 'card' end);

  -- Units on the order (business discount threshold)
  select coalesce(sum((x->>'qty')::numeric), 0) into v_units from jsonb_array_elements(p->'lines') x;

  -- Discount: one per order.
  if p->>'exchange_of' is not null then
    select * into v_orig from sales_orders where id = (p->>'exchange_of')::uuid;
    v_dtype := v_orig.discount_type; v_pct := v_orig.discount_pct; v_reason := v_orig.discount_reason;
  elsif v_dtype = 'none' then
    v_pct := 0;
  elsif v_dtype = 'byu' then
    v_pct := public.setting_num('byu_discount_pct');
  elsif v_dtype = 'business' then
    if v_units < public.setting_num('business_discount_min_units') then
      raise exception 'The business discount needs at least % units.', trim_scale(public.setting_num('business_discount_min_units'));
    end if;
    v_pct := public.setting_num('business_discount_pct');
  elsif v_dtype = 'manual' then
    v_pct := (p->>'discount_pct')::numeric;
    v_reason := p->>'discount_reason';
    if v_pct is null or v_pct <= 0 or v_pct > public.setting_num('max_manual_discount_pct') then
      raise exception 'Manual discount must be between 0 and % percent.', trim_scale(public.setting_num('max_manual_discount_pct') * 100);
    end if;
    if not exists (select 1 from reason_codes where code = v_reason and category = 'discount' and is_active) then
      raise exception 'A manual discount needs a reason code.';
    end if;
  else
    raise exception 'Unknown discount type %', v_dtype;
  end if;

  insert into sales_orders (customer_id, channel, fulfillment_method, location_id, status, order_date,
                            need_date, ship_state, discount_type, discount_pct, discount_reason,
                            tax_rate, payment_method, customer_email, notes, created_by, created_at)
  values (v_cust.id, v_channel, v_method, v_loc.id, 'placed', v_at,
          coalesce((p->>'need_date')::date, public._local_date(v_at)),
          v_state, v_dtype, v_pct, v_reason, v_rate, v_pay,
          coalesce(p->>'customer_email', v_cust.email), p->>'notes', auth.uid(), v_at)
  returning id, order_no into v_id, v_no;

  for r in select * from jsonb_array_elements(p->'lines') loop
    v_qty := (r->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'Line quantities must be positive.'; end if;
    select * into v_item from items where id = (r->>'item_id')::uuid;
    if not found then raise exception 'Unknown item on line %.', v_line + 1; end if;
    if not v_item.is_active or v_item.price is null then
      raise exception '% is not for sale.', v_item.name;
    end if;
    if v_item.uom = 'ea' and v_qty <> trunc(v_qty) then
      raise exception 'Quantity of % must be a whole number.', v_item.name;
    end if;
    v_line := v_line + 1;
    insert into sales_order_lines (so_id, line_no, item_id, qty, unit_price, net_unit_price, line_total)
    values (v_id, v_line, v_item.id, v_qty, v_item.price,
            round(v_item.price * (1 - v_pct), 4), round(v_qty * v_item.price, 2));
    v_sub := v_sub + round(v_qty * v_item.price, 2);
  end loop;

  v_disc := round(v_sub * v_pct, 2);
  if v_method = 'ship' and not coalesce((p->>'waive_shipping')::boolean, false) and p->>'exchange_of' is null then
    v_ship := public.setting_num('flat_shipping_fee');
  end if;
  v_tax := round((v_sub - v_disc) * v_rate, 2);

  update sales_orders
     set subtotal = v_sub, discount_amount = v_disc, shipping_amount = v_ship,
         tax_amount = v_tax, total = v_sub - v_disc + v_ship + v_tax
   where id = v_id;

  perform public._log('sales_order.placed', 'sales_order', v_id,
    format('%s placed for %s: $%s', v_no, coalesce(v_cust.name, 'walk-in customer'),
           to_char(v_sub - v_disc + v_ship + v_tax, 'FM999,999,990.00')),
    '/sales/' || v_id, v_at);
  return v_id;
end;
$$;

-- Ship / hand over a placed order: takes stock out of the order's location,
-- records revenue, discount, shipping, tax, COGS and packaging cost.
-- Fails as a whole if any line is short (the order stays 'placed' = backordered).
create or replace function public.fulfill_sales_order(p_so_id uuid, p_at timestamptz default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  so      sales_orders%rowtype;
  l       sales_order_lines%rowtype;
  v_at    timestamptz := coalesce(p_at, now());
  v_cost  numeric;
  v_cogs  numeric := 0;
  v_pack  numeric := 0;
  v_acct  text;
begin
  perform public._require_staff();
  select * into so from sales_orders where id = p_so_id for update;
  if not found then raise exception 'Unknown sales order.'; end if;
  if so.status <> 'placed' then
    raise exception 'Order % is %; only placed orders can be fulfilled.', so.order_no, so.status;
  end if;

  -- Lock the items in a fixed order so two users never deadlock.
  perform 1 from items where id in (select item_id from sales_order_lines where so_id = p_so_id)
   order by id for update;

  for l in select * from sales_order_lines where so_id = p_so_id order by line_no loop
    v_cost := public._inv_move(l.item_id, so.location_id, -(l.qty - l.qty_fulfilled), null,
                               'sale', so.id, l.id, null, v_at, so.order_no);
    update sales_order_lines set unit_cost = v_cost, qty_fulfilled = qty where id = l.id;
    v_cogs := v_cogs + round((l.qty - l.qty_fulfilled) * v_cost, 2);
  end loop;

  if so.fulfillment_method in ('ship','pickup') then
    v_pack := public.setting_num('packaging_cost_per_order');
  end if;
  v_acct := case when so.payment_method = 'account' then '1100' else '1000' end;

  perform public._post_journal('sale', so.id, v_at, 'Sale ' || so.order_no, jsonb_build_array(
    jsonb_build_object('account', v_acct,  'debit',  so.total, 'customer_id', so.customer_id),
    jsonb_build_object('account', '4100',  'debit',  so.discount_amount, 'customer_id', so.customer_id),
    jsonb_build_object('account', '4000',  'credit', so.subtotal, 'customer_id', so.customer_id),
    jsonb_build_object('account', '4200',  'credit', so.shipping_amount, 'customer_id', so.customer_id),
    jsonb_build_object('account', '2100',  'credit', so.tax_amount),
    jsonb_build_object('account', '5000',  'debit',  v_cogs, 'customer_id', so.customer_id),
    jsonb_build_object('account', '1200',  'credit', v_cogs, 'location_id', so.location_id),
    jsonb_build_object('account', '5100',  'debit',  v_pack, 'memo', 'Packaging ' || so.order_no),
    jsonb_build_object('account', '1000',  'credit', v_pack, 'memo', 'Packaging ' || so.order_no)));

  update sales_orders set status = 'fulfilled', fulfilled_at = v_at where id = so.id;

  perform public._log('sales_order.fulfilled', 'sales_order', so.id,
    format('%s fulfilled ($%s)', so.order_no, to_char(so.total, 'FM999,999,990.00')),
    '/sales/' || so.id, v_at);
end;
$$;

-- Close a fulfilled order (paid and done). On-account orders record the
-- customer's payment here: Dr Cash / Cr A/R.
create or replace function public.close_sales_order(p_so_id uuid, p_at timestamptz default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  so   sales_orders%rowtype;
  v_at timestamptz := coalesce(p_at, now());
  v_returned numeric;
begin
  perform public._require_staff();
  select * into so from sales_orders where id = p_so_id for update;
  if not found then raise exception 'Unknown sales order.'; end if;
  if so.status <> 'fulfilled' then
    raise exception 'Order % is %; only fulfilled orders can be closed.', so.order_no, so.status;
  end if;

  if so.payment_method = 'account' then
    -- Amount still owed = order total minus refunds already credited to A/R.
    select coalesce(sum(credit - debit), 0) into v_returned
      from ledger where account_code = '1100' and source_type = 'sale_return'
       and source_id in (select id from returns where so_id = so.id);
    perform public._post_journal('customer_payment', so.id, v_at, 'Payment ' || so.order_no, jsonb_build_array(
      jsonb_build_object('account', '1000', 'debit',  so.total - v_returned, 'customer_id', so.customer_id),
      jsonb_build_object('account', '1100', 'credit', so.total - v_returned, 'customer_id', so.customer_id)));
  end if;

  update sales_orders set status = 'closed', closed_at = v_at where id = so.id;
  perform public._log('sales_order.closed', 'sales_order', so.id, so.order_no || ' closed', '/sales/' || so.id, v_at);
end;
$$;

-- Cancel an order that has not been fulfilled. Also cancels its planned
-- (not yet started) production orders.
create or replace function public.cancel_sales_order(p_so_id uuid, p_reason text default null, p_at timestamptz default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  so   sales_orders%rowtype;
  v_at timestamptz := coalesce(p_at, now());
begin
  perform public._require_staff();
  select * into so from sales_orders where id = p_so_id for update;
  if not found then raise exception 'Unknown sales order.'; end if;
  if so.status <> 'placed' then
    raise exception 'Order % is %; only placed orders can be cancelled (use a return instead).', so.order_no, so.status;
  end if;
  update sales_orders set status = 'cancelled', cancelled_at = v_at, cancel_reason = p_reason where id = so.id;
  update production_orders set status = 'cancelled', notes = coalesce(notes || ' ', '') || '(order cancelled)'
   where so_id = so.id and status = 'planned';
  perform public._log('sales_order.cancelled', 'sales_order', so.id,
    so.order_no || ' cancelled' || coalesce(': ' || p_reason, ''), '/sales/' || so.id, v_at);
end;
$$;

-- Point of sale: create + fulfill + close in one transaction.
-- p is the same as create_sales_order; defaults to the Campus Counter.
create or replace function public.pos_sale(p jsonb)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_at timestamptz := coalesce((p->>'order_date')::timestamptz, now());
begin
  perform public._require_staff();
  if coalesce(p->>'payment_method', 'card') not in ('cash','card') then
    raise exception 'POS payments must be cash or card.';
  end if;
  v_id := public.create_sales_order(
    p || jsonb_build_object('channel', 'pos', 'fulfillment_method', 'counter',
                            'payment_method', coalesce(p->>'payment_method', 'card'),
                            'location_code', coalesce(p->>'location_code', 'CAMPUS'),
                            'order_date', v_at));
  perform public.fulfill_sales_order(v_id, v_at);
  perform public.close_sales_order(v_id, v_at);
  return v_id;
end;
$$;

-- ===========================================================================
-- RETURNS AND EXCHANGES
-- ===========================================================================

-- p = {
--   so_id, returned_at, notes,
--   lines: [{so_line_id, qty, reason_code, location_id?}],   -- items coming back
--   exchange_lines: [{item_id, qty}]                          -- optional: items going out
-- }
-- Quality-failure reasons send goods to QA Hold and get a full refund.
-- Other returns go back to stock; a "changed my mind" refund (not exchange)
-- of a made-to-order item pays the restocking fee. Revenue is reversed through Sales Returns,
-- tax is refunded, and COGS is reversed at the original cost.
-- An exchange creates a new order (same discount, no shipping charge) and
-- fulfills it right away if stock allows; otherwise it waits as a backorder.
create or replace function public.process_return(p jsonb)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  so        sales_orders%rowtype;
  sl        sales_order_lines%rowtype;
  rc        reason_codes%rowtype;
  v_item    items%rowtype;
  v_at      timestamptz := coalesce((p->>'returned_at')::timestamptz, now());
  v_type    text;
  v_ret     uuid;
  v_no      text;
  v_rl      uuid;
  v_qty     numeric;
  v_loc     uuid;
  v_disp    text;
  v_merch   numeric := 0;
  v_cost    numeric := 0;
  v_feebase numeric := 0;
  v_fee     numeric;
  v_tax     numeric;
  v_ex      uuid;
  v_extotal numeric := 0;
  v_acct    text;
  r         jsonb;
begin
  perform public._require_staff();
  select * into so from sales_orders where id = (p->>'so_id')::uuid for update;
  if not found then raise exception 'Unknown sales order.'; end if;
  if so.status not in ('fulfilled','closed') then
    raise exception 'Order % is %; only fulfilled or closed orders can be returned.', so.order_no, so.status;
  end if;
  if v_at > so.fulfilled_at + make_interval(days => public.setting_num('return_window_days')::int) then
    raise exception 'Order % is past the %-day return window.', so.order_no, public.setting_num('return_window_days');
  end if;
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') = 0 then
    raise exception 'Choose at least one item to return.';
  end if;
  v_type := case when jsonb_typeof(p->'exchange_lines') = 'array' and jsonb_array_length(p->'exchange_lines') > 0
                 then 'exchange' else 'refund' end;

  insert into returns (so_id, customer_id, return_type, returned_at, notes, created_by, created_at)
  values (so.id, so.customer_id, v_type, v_at, p->>'notes', auth.uid(), v_at)
  returning id, return_no into v_ret, v_no;

  for r in select * from jsonb_array_elements(p->'lines') loop
    select * into sl from sales_order_lines where id = (r->>'so_line_id')::uuid and so_id = so.id for update;
    if not found then raise exception 'That line is not on order %.', so.order_no; end if;
    select * into v_item from items where id = sl.item_id;
    v_qty := (r->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'Return quantities must be positive.'; end if;
    if v_qty > sl.qty_fulfilled - sl.qty_returned then
      raise exception 'Only % of % can still be returned on %.',
        trim_scale(sl.qty_fulfilled - sl.qty_returned), v_item.name, so.order_no;
    end if;
    select * into rc from reason_codes where code = r->>'reason_code' and category = 'return' and is_active;
    if not found then raise exception 'Choose a return reason code.'; end if;

    if rc.is_quality then
      v_disp := 'qa_hold';
      v_loc  := public._location_id('QA_HOLD');
    else
      v_disp := 'restock';
      v_loc  := coalesce((r->>'location_id')::uuid, so.location_id);
    end if;

    insert into return_lines (return_id, so_line_id, item_id, qty, reason_code, disposition,
                              location_id, net_unit_price, unit_cost)
    values (v_ret, sl.id, sl.item_id, v_qty, rc.code, v_disp, v_loc, sl.net_unit_price, sl.unit_cost)
    returning id into v_rl;

    -- Back into stock at the cost it left with.
    perform public._inv_move(sl.item_id, v_loc, v_qty, sl.unit_cost, 'sale_return', v_ret, v_rl,
                             rc.code, v_at, v_no || ' / ' || so.order_no);
    update sales_order_lines set qty_returned = qty_returned + v_qty where id = sl.id;

    v_merch := v_merch + round(v_qty * sl.net_unit_price, 2);
    v_cost  := v_cost  + round(v_qty * sl.unit_cost, 2);
    if rc.charges_restocking_fee and v_item.stocking_policy = 'make_to_order' and v_type = 'refund' then
      v_feebase := v_feebase + round(v_qty * sl.net_unit_price, 2);
    end if;
  end loop;

  v_tax := round(v_merch * so.tax_rate, 2);
  v_fee := round(v_feebase * public.setting_num('restocking_fee_pct'), 2);
  -- Refund goes back the way they paid (open on-account orders reduce A/R).
  v_acct := case when so.payment_method = 'account' and so.status <> 'closed' then '1100' else '1000' end;

  perform public._post_journal('sale_return', v_ret, v_at, 'Return ' || v_no || ' of ' || so.order_no, jsonb_build_array(
    jsonb_build_object('account', '4400', 'debit',  v_merch, 'customer_id', so.customer_id),
    jsonb_build_object('account', '2100', 'debit',  v_tax),
    jsonb_build_object('account', '4300', 'credit', v_fee, 'customer_id', so.customer_id),
    jsonb_build_object('account', v_acct, 'credit', v_merch + v_tax - v_fee, 'customer_id', so.customer_id),
    jsonb_build_object('account', '1200', 'debit',  v_cost),
    jsonb_build_object('account', '5000', 'credit', v_cost, 'customer_id', so.customer_id)));

  if v_type = 'exchange' then
    v_ex := public.create_sales_order(jsonb_build_object(
      'customer_id', so.customer_id, 'channel', so.channel,
      'fulfillment_method', so.fulfillment_method, 'location_id', so.location_id,
      'ship_state', so.ship_state, 'payment_method', so.payment_method,
      'exchange_of', so.id, 'order_date', v_at,
      'notes', 'Exchange for ' || so.order_no || ' (' || v_no || ')',
      'lines', p->'exchange_lines'));
    begin
      perform public.fulfill_sales_order(v_ex, v_at);
    exception when raise_exception then
      null;  -- not enough stock yet: the exchange order stays placed (backordered)
    end;
    select total into v_extotal from sales_orders where id = v_ex;
  end if;

  update returns
     set merchandise_credit = v_merch, tax_credit = v_tax, restocking_fee = v_fee,
         exchange_so_id = v_ex, exchange_total = v_extotal,
         refund_amount = v_merch + v_tax - v_fee - v_extotal
   where id = v_ret;

  perform public._log('return.processed', 'return', v_ret,
    format('%s %s on %s: credit $%s', v_no, v_type, so.order_no,
           to_char(v_merch + v_tax - v_fee, 'FM999,999,990.00')),
    '/returns/' || v_ret, v_at);
  return v_ret;
end;
$$;

-- ===========================================================================
-- PRODUCTION ORDERS
-- ===========================================================================

-- Plan a production order. Whole plates are printed, so the quantity started
-- is plates × units per plate. Components = BOM qty per plate × plates.
create or replace function public.create_production_order(
  p_item uuid, p_qty numeric, p_due_date date default null, p_so_id uuid default null,
  p_location uuid default null, p_output_location uuid default null,
  p_notes text default null, p_at timestamptz default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_item   items%rowtype;
  v_at     timestamptz := coalesce(p_at, now());
  v_plates int;
  v_id     uuid;
  v_no     text;
begin
  perform public._require_staff();
  select * into v_item from items where id = p_item;
  if not found or v_item.item_type <> 'finished' then
    raise exception 'Production orders are only for items we make.';
  end if;
  if not exists (select 1 from boms where parent_item_id = p_item) then
    raise exception '% has no bill of material.', v_item.name;
  end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Quantity must be positive.'; end if;

  v_plates := ceil(p_qty / v_item.units_per_plate)::int;

  insert into production_orders (item_id, qty_planned, plates, location_id, output_location_id,
                                 status, so_id, due_date, notes, created_by, created_at)
  values (p_item, p_qty, v_plates,
          coalesce(p_location, public._location_id('PRINT_FARM')),
          coalesce(p_output_location, public._location_id('FULFILLMENT')),
          'planned', p_so_id, p_due_date, p_notes, auth.uid(), v_at)
  returning id, mo_no into v_id, v_no;

  insert into production_order_components (mo_id, item_id, qty_required)
  select v_id, b.component_item_id, b.qty_per_plate * v_plates
    from boms b where b.parent_item_id = p_item;

  perform public._log('production.created', 'production_order', v_id,
    format('%s planned: %s × %s (%s plate%s)', v_no, trim_scale(p_qty), v_item.name, v_plates,
           case when v_plates = 1 then '' else 's' end),
    '/production/' || v_id, v_at);
  return v_id;
end;
$$;

-- Issue: consume all BOM components from the build location into WIP and
-- start the clock. Dr WIP / Cr Inventory.
create or replace function public.issue_production_order(p_mo_id uuid, p_at timestamptz default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  mo     production_orders%rowtype;
  c      production_order_components%rowtype;
  v_at   timestamptz := coalesce(p_at, now());
  v_cost numeric;
  v_mat  numeric := 0;
  v_upp  int;
begin
  perform public._require_staff();
  select * into mo from production_orders where id = p_mo_id for update;
  if not found then raise exception 'Unknown production order.'; end if;
  if mo.status <> 'planned' then
    raise exception '% is %; only planned orders can be issued.', mo.mo_no, mo.status;
  end if;

  perform 1 from items where id in (select item_id from production_order_components where mo_id = p_mo_id)
   order by id for update;

  for c in select * from production_order_components where mo_id = p_mo_id order by item_id loop
    v_cost := public._inv_move(c.item_id, mo.location_id, -c.qty_required, null,
                               'production_issue', mo.id, null, null, v_at, mo.mo_no);
    update production_order_components set qty_issued = qty_required, unit_cost = v_cost
     where mo_id = c.mo_id and item_id = c.item_id;
    v_mat := v_mat + c.qty_required * v_cost;
  end loop;

  v_mat := round(v_mat, 4);
  select units_per_plate into v_upp from items where id = mo.item_id;

  update production_orders
     set status = 'in_progress', started_at = v_at, material_cost = v_mat,
         qty_started = plates * v_upp
   where id = mo.id;

  perform public._post_journal('production_issue', mo.id, v_at, 'Issue ' || mo.mo_no, jsonb_build_array(
    jsonb_build_object('account', '1250', 'debit',  round(v_mat, 2), 'item_id', mo.item_id),
    jsonb_build_object('account', '1200', 'credit', round(v_mat, 2), 'location_id', mo.location_id)));

  perform public._log('production.issued', 'production_order', mo.id,
    format('%s started; components issued ($%s)', mo.mo_no, to_char(v_mat, 'FM999,999,990.00')),
    '/production/' || mo.id, v_at);
end;
$$;

-- Complete: good + scrapped must equal quantity started. Cost rolls up as
-- materials issued + machine time + labor (from settings), spread over every
-- unit started. Good units go into stock at that unit cost; scrapped units'
-- cost is expensed as production scrap (cost of poor quality).
-- Dr Inventory + Dr Scrap / Cr WIP + Cr Accrued labor & machine.
create or replace function public.complete_production_order(
  p_mo_id uuid, p_qty_good numeric, p_qty_scrap numeric default 0,
  p_scrap_reason text default null, p_at timestamptz default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  mo      production_orders%rowtype;
  v_item  items%rowtype;
  v_at    timestamptz := coalesce(p_at, now());
  v_scrap numeric := coalesce(p_qty_scrap, 0);
  v_mach  numeric;
  v_lab   numeric;
  v_uc    numeric;
  v_cr_wip  numeric;
  v_cr_conv numeric;
  v_dr_inv  numeric;
begin
  perform public._require_staff();
  select * into mo from production_orders where id = p_mo_id for update;
  if not found then raise exception 'Unknown production order.'; end if;
  if mo.status <> 'in_progress' then
    raise exception '% is %; only orders in progress can be completed.', mo.mo_no, mo.status;
  end if;
  if p_qty_good is null or p_qty_good < 0 or v_scrap < 0 then
    raise exception 'Quantities cannot be negative.';
  end if;
  if p_qty_good + v_scrap <> mo.qty_started then
    raise exception 'Good (%) + scrapped (%) must equal the % started.',
      trim_scale(p_qty_good), trim_scale(v_scrap), trim_scale(mo.qty_started);
  end if;
  if v_scrap > 0 and not exists (select 1 from reason_codes where code = p_scrap_reason and category = 'scrap' and is_active) then
    raise exception 'Scrapped units need a scrap reason code.';
  end if;
  if v_at < mo.started_at then raise exception 'Finish time cannot be before the start time.'; end if;

  select * into v_item from items where id = mo.item_id;
  v_mach := round(mo.plates * coalesce(v_item.print_minutes, 0) / 60.0 * public.machine_rate_per_hour(), 4);
  v_lab  := round(mo.plates * (public.setting_num('setup_minutes_per_plate') + public.setting_num('cleanup_minutes_per_plate')
                    + coalesce(v_item.assembly_minutes, 0)) / 60.0 * public.setting_num('labor_rate'), 4);
  v_uc   := round((mo.material_cost + v_mach + v_lab) / mo.qty_started, 6);

  if p_qty_good > 0 then
    perform public._inv_move(mo.item_id, mo.output_location_id, p_qty_good, v_uc,
                             'production_output', mo.id, null, null, v_at, mo.mo_no);
  end if;

  v_cr_wip  := round(mo.material_cost, 2);
  v_cr_conv := round(v_mach + v_lab, 2);
  v_dr_inv  := case when v_scrap = 0 then v_cr_wip + v_cr_conv else round(p_qty_good * v_uc, 2) end;

  perform public._post_journal('production_complete', mo.id, v_at, 'Complete ' || mo.mo_no, jsonb_build_array(
    jsonb_build_object('account', '1200', 'debit',  v_dr_inv, 'item_id', mo.item_id, 'location_id', mo.output_location_id),
    jsonb_build_object('account', '5300', 'debit',  v_cr_wip + v_cr_conv - v_dr_inv, 'item_id', mo.item_id,
                       'memo', 'Scrap ' || mo.mo_no || coalesce(' ' || p_scrap_reason, '')),
    jsonb_build_object('account', '1250', 'credit', v_cr_wip, 'item_id', mo.item_id),
    jsonb_build_object('account', '2300', 'credit', v_cr_conv, 'item_id', mo.item_id)));

  update production_orders
     set status = 'completed', finished_at = v_at, qty_good = p_qty_good, qty_scrap = v_scrap,
         scrap_reason = case when v_scrap > 0 then p_scrap_reason end,
         machine_cost = v_mach, labor_cost = v_lab, unit_cost = v_uc
   where id = mo.id;

  perform public._log('production.completed', 'production_order', mo.id,
    format('%s completed: %s good, %s scrapped at $%s each', mo.mo_no, trim_scale(p_qty_good),
           trim_scale(v_scrap), to_char(v_uc, 'FM999,990.00')),
    '/production/' || mo.id, v_at);
end;
$$;

create or replace function public.cancel_production_order(p_mo_id uuid, p_reason text default null, p_at timestamptz default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare mo production_orders%rowtype;
begin
  perform public._require_staff();
  select * into mo from production_orders where id = p_mo_id for update;
  if not found then raise exception 'Unknown production order.'; end if;
  if mo.status <> 'planned' then
    raise exception '% is %; only planned orders can be cancelled (complete it with scrap instead).', mo.mo_no, mo.status;
  end if;
  update production_orders set status = 'cancelled', notes = coalesce(notes || ' ', '') || coalesce('Cancelled: ' || p_reason, 'Cancelled')
   where id = mo.id;
  perform public._log('production.cancelled', 'production_order', mo.id, mo.mo_no || ' cancelled',
    '/production/' || mo.id, coalesce(p_at, now()));
end;
$$;

-- ===========================================================================
-- PURCHASING
-- ===========================================================================

-- p = { supplier_id, ship_to_location_id?, source?, notes?, order_date?, send? (default true),
--       lines: [{item_id, qty (purchase units, e.g. spools), unit_cost?, need_date?}] }
-- Unit cost and pack size default from the supplier's price list (item_suppliers).
create or replace function public.create_purchase_order(p jsonb)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_sup   suppliers%rowtype;
  v_at    timestamptz := coalesce((p->>'order_date')::timestamptz, now());
  v_id    uuid;
  v_no    text;
  v_line  int := 0;
  r       jsonb;
  v_is    item_suppliers%rowtype;
  v_item  items%rowtype;
  v_cost  numeric;
  v_qty   numeric;
begin
  perform public._require_staff();
  select * into v_sup from suppliers where id = (p->>'supplier_id')::uuid;
  if not found or not v_sup.is_active then raise exception 'Choose an active supplier.'; end if;
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') = 0 then
    raise exception 'A purchase order needs at least one line.';
  end if;

  insert into purchase_orders (supplier_id, status, ship_to_location_id, terms_days, source, notes, created_by, created_at)
  values (v_sup.id, 'draft',
          coalesce((p->>'ship_to_location_id')::uuid, public._location_id('PRINT_FARM')),
          v_sup.terms_days, coalesce(p->>'source', 'manual'), p->>'notes', auth.uid(), v_at)
  returning id, po_no into v_id, v_no;

  for r in select * from jsonb_array_elements(p->'lines') loop
    select * into v_item from items where id = (r->>'item_id')::uuid;
    if not found then raise exception 'Unknown item on line %.', v_line + 1; end if;
    v_qty := (r->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'Order quantities must be positive.'; end if;
    select * into v_is from item_suppliers where item_id = v_item.id and supplier_id = v_sup.id;
    v_cost := coalesce((r->>'unit_cost')::numeric, v_is.unit_cost);
    if v_cost is null then
      raise exception '% does not sell %; enter a unit cost.', v_sup.name, v_item.name;
    end if;
    v_line := v_line + 1;
    insert into purchase_order_lines (po_id, line_no, item_id, qty_ordered, purchase_uom,
                                      stock_per_purchase_unit, unit_cost, need_date)
    values (v_id, v_line, v_item.id, v_qty, coalesce(v_is.purchase_uom, v_item.uom),
            coalesce(v_is.stock_per_purchase_unit, 1), v_cost, (r->>'need_date')::date);
  end loop;

  perform public._log('purchase_order.created', 'purchase_order', v_id,
    format('%s drafted for %s', v_no, v_sup.name), '/purchasing/' || v_id, v_at);

  if coalesce((p->>'send')::boolean, true) then
    perform public.send_purchase_order(v_id, v_at);
  end if;
  return v_id;
end;
$$;

-- Send: expected receipt date = sent date + supplier's quoted lead time.
create or replace function public.send_purchase_order(p_po_id uuid, p_at timestamptz default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  po    purchase_orders%rowtype;
  v_sup suppliers%rowtype;
  v_at  timestamptz := coalesce(p_at, now());
begin
  perform public._require_staff();
  select * into po from purchase_orders where id = p_po_id for update;
  if not found then raise exception 'Unknown purchase order.'; end if;
  if po.status <> 'draft' then raise exception '% is already %.', po.po_no, po.status; end if;
  select * into v_sup from suppliers where id = po.supplier_id;

  update purchase_orders
     set status = 'sent', order_date = v_at, lead_days = v_sup.quoted_lead_days,
         expected_date = public._local_date(v_at) + v_sup.quoted_lead_days,
         terms_days = v_sup.terms_days
   where id = po.id;

  perform public._log('purchase_order.sent', 'purchase_order', po.id,
    format('%s sent to %s, expected %s', po.po_no, v_sup.name,
           to_char(public._local_date(v_at) + v_sup.quoted_lead_days, 'Mon DD')),
    '/purchasing/' || po.id, v_at);
end;
$$;

-- Pay a supplier bill (a receipt). Dr A/P / Cr Cash. Default = full balance.
create or replace function public.record_supplier_payment(
  p_receipt_id uuid, p_amount numeric default null, p_at timestamptz default null, p_method text default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_bal  numeric;
  v_sup  uuid;
  v_po   text;
  v_amt  numeric;
  v_id   uuid;
  v_at   timestamptz := coalesce(p_at, now());
begin
  perform public._require_staff();
  select balance, supplier_id, po_no into v_bal, v_sup, v_po from v_ap_open where receipt_id = p_receipt_id;
  if not found then raise exception 'Unknown supplier bill.'; end if;
  v_amt := coalesce(p_amount, v_bal);
  if v_amt <= 0 or v_amt > v_bal then
    raise exception 'Payment must be between $0 and the $% still owed.', v_bal;
  end if;

  insert into supplier_payments (supplier_id, receipt_id, amount, paid_at, method, created_by)
  values (v_sup, p_receipt_id, v_amt, v_at, p_method, auth.uid())
  returning id into v_id;

  perform public._post_journal('supplier_payment', v_id, v_at, 'Payment for ' || v_po, jsonb_build_array(
    jsonb_build_object('account', '2000', 'debit',  v_amt, 'supplier_id', v_sup),
    jsonb_build_object('account', '1000', 'credit', v_amt, 'supplier_id', v_sup)));

  perform public._log('supplier.paid', 'purchase_order', p_receipt_id,
    format('Paid $%s on %s', to_char(v_amt, 'FM999,999,990.00'), v_po), '/purchasing', v_at);
  return v_id;
end;
$$;

-- Receive against a PO into a chosen location (partial receipts allowed).
-- p_lines = [{po_line_id, qty (purchase units)}]; null = everything still open.
-- Stock comes in at PO cost per stock unit (e.g. $/gram for filament).
-- Dr Inventory / Cr A/P; suppliers paid at purchase are paid immediately.
create or replace function public.receive_purchase_order(
  p_po_id uuid, p_lines jsonb default null, p_location uuid default null,
  p_at timestamptz default null, p_allow_over boolean default false, p_notes text default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  po      purchase_orders%rowtype;
  pol     purchase_order_lines%rowtype;
  v_at    timestamptz := coalesce(p_at, now());
  v_loc   uuid;
  v_rcpt  uuid;
  v_amt   numeric := 0;
  v_qty   numeric;
  v_n     int := 0;
  r       jsonb;
  v_lines jsonb := p_lines;
begin
  perform public._require_staff();
  select * into po from purchase_orders where id = p_po_id for update;
  if not found then raise exception 'Unknown purchase order.'; end if;
  if po.status not in ('sent','partial') then
    raise exception '% is %; only sent or partly received orders can be received.', po.po_no, po.status;
  end if;
  if v_at < po.order_date then raise exception 'Receipt date cannot be before the order was sent.'; end if;
  v_loc := coalesce(p_location, po.ship_to_location_id);

  if v_lines is null then
    select coalesce(jsonb_agg(jsonb_build_object('po_line_id', id, 'qty', qty_ordered - qty_received)), '[]'::jsonb)
      into v_lines
      from purchase_order_lines where po_id = po.id and qty_received < qty_ordered;
  end if;

  insert into po_receipts (po_id, received_at, location_id, due_date, notes, created_by)
  values (po.id, v_at, v_loc, public._local_date(v_at) + po.terms_days, p_notes, auth.uid())
  returning id into v_rcpt;

  for r in select * from jsonb_array_elements(v_lines) loop
    v_qty := (r->>'qty')::numeric;
    continue when v_qty is null or v_qty = 0;
    if v_qty < 0 then raise exception 'Received quantities must be positive.'; end if;
    select * into pol from purchase_order_lines where id = (r->>'po_line_id')::uuid and po_id = po.id for update;
    if not found then raise exception 'That line is not on %.', po.po_no; end if;
    if pol.qty_received + v_qty > pol.qty_ordered and not p_allow_over then
      raise exception 'Receiving % would exceed the % ordered of %. Confirm the over-receipt to accept it.',
        trim_scale(pol.qty_received + v_qty), trim_scale(pol.qty_ordered),
        (select name from items where id = pol.item_id);
    end if;

    insert into po_receipt_lines (receipt_id, po_line_id, qty_received) values (v_rcpt, pol.id, v_qty);
    update purchase_order_lines set qty_received = qty_received + v_qty where id = pol.id;
    perform public._inv_move(pol.item_id, v_loc, v_qty * pol.stock_per_purchase_unit,
                             pol.unit_cost / pol.stock_per_purchase_unit,
                             'po_receipt', v_rcpt, pol.id, null, v_at, po.po_no);
    v_amt := v_amt + round(v_qty * pol.unit_cost, 2);
    v_n := v_n + 1;
  end loop;

  if v_n = 0 then raise exception 'Enter a quantity to receive.'; end if;
  update po_receipts set amount = v_amt where id = v_rcpt;

  perform public._post_journal('po_receipt', v_rcpt, v_at, 'Receipt ' || po.po_no, jsonb_build_array(
    jsonb_build_object('account', '1200', 'debit',  v_amt, 'location_id', v_loc, 'supplier_id', po.supplier_id),
    jsonb_build_object('account', '2000', 'credit', v_amt, 'supplier_id', po.supplier_id)));

  update purchase_orders
     set status = case when exists (select 1 from purchase_order_lines
                                     where po_id = po.id and qty_received < qty_ordered)
                       then 'partial' else 'received' end
   where id = po.id;

  perform public._log('purchase_order.received', 'purchase_order', po.id,
    format('%s received ($%s)', po.po_no, to_char(v_amt, 'FM999,999,990.00')),
    '/purchasing/' || po.id, v_at);

  -- "Paid at purchase" suppliers: settle the bill right away.
  if po.terms_days = 0 and v_amt > 0 then
    perform public.record_supplier_payment(v_rcpt, v_amt, v_at, 'paid at purchase');
  end if;
  return v_rcpt;
end;
$$;

-- Close a received (or short-shipped, partly received) PO.
create or replace function public.close_purchase_order(p_po_id uuid, p_at timestamptz default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  po   purchase_orders%rowtype;
  v_at timestamptz := coalesce(p_at, now());
begin
  perform public._require_staff();
  select * into po from purchase_orders where id = p_po_id for update;
  if not found then raise exception 'Unknown purchase order.'; end if;
  if po.status not in ('received','partial') then
    raise exception '% is %; only received orders can be closed.', po.po_no, po.status;
  end if;
  update purchase_orders set status = 'closed', closed_at = v_at where id = po.id;
  perform public._log('purchase_order.closed', 'purchase_order', po.id,
    po.po_no || ' closed' || case when po.status = 'partial' then ' short' else '' end,
    '/purchasing/' || po.id, v_at);
end;
$$;

create or replace function public.cancel_purchase_order(p_po_id uuid, p_at timestamptz default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare po purchase_orders%rowtype;
begin
  perform public._require_staff();
  select * into po from purchase_orders where id = p_po_id for update;
  if not found then raise exception 'Unknown purchase order.'; end if;
  if po.status not in ('draft','sent') then
    raise exception '% is %; only orders with nothing received can be cancelled.', po.po_no, po.status;
  end if;
  update purchase_orders set status = 'cancelled', closed_at = coalesce(p_at, now()) where id = po.id;
  perform public._log('purchase_order.cancelled', 'purchase_order', po.id, po.po_no || ' cancelled',
    '/purchasing/' || po.id, coalesce(p_at, now()));
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants: the app may call the business functions; helpers stay private.
-- (Each function still checks for staff itself.)
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
revoke execute on function
  public._require_staff(), public._actor(), public._log(text, text, uuid, text, text, timestamptz),
  public._location_id(text), public._local_date(timestamptz),
  public._post_journal(text, uuid, timestamptz, text, jsonb),
  public._inv_move(uuid, uuid, numeric, numeric, text, uuid, uuid, text, timestamptz, text)
  from authenticated;
grant execute on function
  public.receive_opening_inventory(uuid, uuid, numeric, numeric, timestamptz, text),
  public.transfer_inventory(uuid, uuid, jsonb, text, timestamptz),
  public.adjust_inventory(uuid, uuid, numeric, text, text, timestamptz),
  public.count_inventory(uuid, uuid, numeric, text, text, timestamptz),
  public.create_sales_order(jsonb),
  public.fulfill_sales_order(uuid, timestamptz),
  public.close_sales_order(uuid, timestamptz),
  public.cancel_sales_order(uuid, text, timestamptz),
  public.pos_sale(jsonb),
  public.process_return(jsonb),
  public.create_production_order(uuid, numeric, date, uuid, uuid, uuid, text, timestamptz),
  public.issue_production_order(uuid, timestamptz),
  public.complete_production_order(uuid, numeric, numeric, text, timestamptz),
  public.cancel_production_order(uuid, text, timestamptz),
  public.create_purchase_order(jsonb),
  public.send_purchase_order(uuid, timestamptz),
  public.record_supplier_payment(uuid, numeric, timestamptz, text),
  public.receive_purchase_order(uuid, jsonb, uuid, timestamptz, boolean, text),
  public.close_purchase_order(uuid, timestamptz),
  public.cancel_purchase_order(uuid, timestamptz)
  to authenticated;
