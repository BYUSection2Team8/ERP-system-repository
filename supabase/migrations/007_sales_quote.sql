-- =============================================================================
-- 007_sales_quote.sql — one place that prices an order (Phase 4)
--
-- The POS and the New Sales Order screen show the subtotal, discount, shipping,
-- tax and total BEFORE the sale is saved. To keep the math in one place, the
-- pricing logic that used to live inside create_sales_order moves into
-- _price_sales_order(p). Both of these call it:
--   * quote_sales_order(p)  — read-only preview for the screens (saves nothing)
--   * create_sales_order(p) — saves the order using exactly the same numbers
-- Behavior and error messages of create_sales_order are unchanged.
-- =============================================================================

-- p is the same object create_sales_order takes (see 004_functions.sql).
-- Returns {
--   customer_id, customer_name, channel, fulfillment_method, location_id,
--   ship_state, tax_rate, payment_method, discount_type, discount_pct,
--   discount_reason, units, subtotal, discount_amount, shipping_amount,
--   tax_amount, total, need_date, customer_email, is_byu, terms_days,
--   business_min_units,
--   lines: [{line_no, item_id, sku, name, qty, unit_price, net_unit_price, line_total}]
-- }
create or replace function public._price_sales_order(p jsonb)
returns jsonb
language plpgsql stable security definer
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
  v_line    int := 0;
  v_lines   jsonb := '[]'::jsonb;
  r         jsonb;
  v_item    items%rowtype;
  v_qty     numeric;
begin
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') = 0 then
    raise exception 'An order needs at least one line.';
  end if;
  if v_channel not in ('online','phone','portal','pos') then
    raise exception 'Unknown channel %', v_channel;
  end if;
  v_method := coalesce(p->>'fulfillment_method', case when v_channel = 'pos' then 'counter' else 'ship' end);
  if v_method not in ('ship','pickup','counter') then
    raise exception 'Unknown fulfillment method %', v_method;
  end if;

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
    v_state := upper(coalesce(nullif(p->>'ship_state', ''), v_cust.state));
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
    v_lines := v_lines || jsonb_build_object(
      'line_no', v_line, 'item_id', v_item.id, 'sku', v_item.sku, 'name', v_item.name, 'qty', v_qty,
      'unit_price', v_item.price, 'net_unit_price', round(v_item.price * (1 - v_pct), 4),
      'line_total', round(v_qty * v_item.price, 2));
    v_sub := v_sub + round(v_qty * v_item.price, 2);
  end loop;

  v_disc := round(v_sub * v_pct, 2);
  if v_method = 'ship' and not coalesce((p->>'waive_shipping')::boolean, false) and p->>'exchange_of' is null then
    v_ship := public.setting_num('flat_shipping_fee');
  end if;
  v_tax := round((v_sub - v_disc) * v_rate, 2);

  return jsonb_build_object(
    'customer_id', v_cust.id, 'customer_name', v_cust.name, 'channel', v_channel,
    'fulfillment_method', v_method, 'location_id', v_loc.id, 'ship_state', v_state,
    'tax_rate', v_rate, 'payment_method', v_pay, 'discount_type', v_dtype,
    'discount_pct', v_pct, 'discount_reason', v_reason, 'units', v_units,
    'subtotal', v_sub, 'discount_amount', v_disc, 'shipping_amount', v_ship,
    'tax_amount', v_tax, 'total', v_sub - v_disc + v_ship + v_tax,
    'need_date', coalesce((p->>'need_date')::date, public._local_date(v_at)),
    'customer_email', coalesce(nullif(p->>'customer_email', ''), v_cust.email),
    'is_byu', coalesce(v_cust.is_byu, false), 'terms_days', coalesce(v_cust.terms_days, 0),
    'business_min_units', public.setting_num('business_discount_min_units'),
    'lines', v_lines);
end;
$$;

-- Preview an order's prices without saving anything (POS / New order screens).
create or replace function public.quote_sales_order(p jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform public._require_staff();
  return public._price_sales_order(p);
end;
$$;

-- Same contract as before (see 004_functions.sql); pricing now comes from
-- _price_sales_order so the preview and the saved order always agree.
create or replace function public.create_sales_order(p jsonb)
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
  perform public._require_staff();
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
    format('%s placed for %s: $%s', v_no, coalesce(q->>'customer_name', 'walk-in customer'),
           to_char((q->>'total')::numeric, 'FM999,999,990.00')),
    '/sales/' || v_id, v_at);
  return v_id;
end;
$$;

revoke execute on function public._price_sales_order(jsonb) from public, anon, authenticated;
revoke execute on function public.quote_sales_order(jsonb) from public, anon;
grant execute on function public.quote_sales_order(jsonb) to authenticated;
