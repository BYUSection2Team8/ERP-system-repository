-- =============================================================================
-- 023_temples_white_promo_codes.sql
--
-- 1) Temples are printed in white only: the red, blue and black Temple items are
--    retired (is_active = false). Their history and any open orders stay; they
--    can no longer be sold, ordered or planned. (A fresh database retires them at
--    the end of seed/002, after the six months of history.)
-- 2) Promo codes: a customer can type a code in the portal cart. Codes are data
--    (promo_codes: code, % off, active, optional start / end dates) that staff can
--    edit. One discount per order: the best of BYU / business / promo applies.
--    Seeded code: PASSWORD = 11% off (any capitalization).
--    _price_sales_order, _insert_sales_order and _portal_order_payload are
--    re-created from 020 / 012 / 014 with only the promo additions.
-- =============================================================================

update public.items set is_active = false
 where product_family = 'Temple LED Tealight' and color is distinct from 'White' and is_active;

create table if not exists public.promo_codes (
  code        text primary key check (code = upper(code) and code ~ '^[A-Z0-9_-]{3,30}$'),
  pct         numeric(5,4) not null check (pct > 0 and pct <= 0.5),
  description text,
  is_active   boolean not null default true,
  starts_on   date,
  ends_on     date,
  created_at  timestamptz not null default now()
);
alter table public.promo_codes enable row level security;
drop policy if exists staff_read on public.promo_codes;
drop policy if exists staff_write on public.promo_codes;
create policy staff_read on public.promo_codes for select to authenticated using (public.is_staff());
create policy staff_write on public.promo_codes for all to authenticated using (public.is_staff()) with check (public.is_staff());
revoke all on public.promo_codes from anon;
insert into public.promo_codes (code, pct, description) values ('PASSWORD', 0.11, 'Demo promo code: 11% off')
on conflict (code) do nothing;

alter table public.sales_orders add column if not exists promo_code text;
alter table public.sales_orders drop constraint if exists sales_orders_discount_type_check;
alter table public.sales_orders add constraint sales_orders_discount_type_check
  check (discount_type in ('none', 'byu', 'business', 'manual', 'promo'));

-- % off for a valid, active promo code (any capitalization), else a plain error.
create or replace function public._promo_pct(p_code text)
returns numeric
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v numeric; v_today date := public._local_date(now());
begin
  select pct into v from promo_codes
   where code = upper(trim(coalesce(p_code, ''))) and is_active
     and (starts_on is null or starts_on <= v_today) and (ends_on is null or ends_on >= v_today);
  if not found then raise exception 'That promo code is not valid.'; end if;
  return v;
end;
$$;

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
  v_weight  numeric := 0;
  v_postage jsonb;
  v_promo   text;
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

  if p->>'customer_id' is not null then
    select * into v_cust from customers where id = (p->>'customer_id')::uuid;
    if not found then raise exception 'Unknown customer.'; end if;
  elsif v_channel <> 'pos' then
    raise exception 'Choose a customer for this order.';
  end if;

  select * into v_loc from locations
   where id = coalesce((p->>'location_id')::uuid, public._location_id(coalesce(p->>'location_code',
           case when v_method = 'ship' then 'FULFILLMENT' else 'CAMPUS' end)));
  if not found or not v_loc.is_sellable or not v_loc.is_active then
    raise exception 'Orders cannot be filled from that location.';
  end if;

  if v_method = 'ship' then
    v_state := upper(coalesce(nullif(p->>'ship_state', ''), v_cust.state));
    if v_state is null then raise exception 'Enter the ship-to state (needed for sales tax).'; end if;
  else
    v_state := upper(public.setting_text('tax_state'));
  end if;
  if v_state = upper(public.setting_text('tax_state')) then
    v_rate := public.setting_num('sales_tax_rate');
  end if;

  v_pay := coalesce(p->>'payment_method',
                    case when coalesce(v_cust.terms_days, 0) > 0 then 'account' else 'card' end);

  select coalesce(sum((x->>'qty')::numeric), 0) into v_units from jsonb_array_elements(p->'lines') x;

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
  elsif v_dtype = 'promo' then
    v_pct := public._promo_pct(p->>'promo_code');
    v_promo := upper(trim(p->>'promo_code'));
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
    v_weight := v_weight + v_qty * coalesce(public._item_ship_weight_g(v_item.id), 0);
  end loop;

  v_disc := round(v_sub * v_pct, 2);
  if v_method = 'ship' and not coalesce((p->>'waive_shipping')::boolean, false) and p->>'exchange_of' is null then
    if public.setting_text('shipping_mode') = 'zone' then
      v_postage := public._zone_postage(v_state, v_weight);
      v_ship := (v_postage->>'total')::numeric;
    else
      v_ship := public.setting_num('flat_shipping_fee');
    end if;
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
    'shipping', v_postage,
    'promo_code', v_promo,
    'lines', v_lines);
end;
$$;

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
                            subtotal, discount_amount, shipping_amount, tax_amount, total, promo_code)
  values ((q->>'customer_id')::uuid, q->>'channel', q->>'fulfillment_method', (q->>'location_id')::uuid,
          'placed', v_at, (q->>'need_date')::date, q->>'ship_state', q->>'discount_type',
          (q->>'discount_pct')::numeric, q->>'discount_reason', (q->>'tax_rate')::numeric,
          q->>'payment_method', q->>'customer_email', nullif(p->>'notes', ''), auth.uid(), v_at,
          (q->>'subtotal')::numeric, (q->>'discount_amount')::numeric, (q->>'shipping_amount')::numeric,
          (q->>'tax_amount')::numeric, (q->>'total')::numeric, q->>'promo_code')
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
  v_promo text;
  v_ppct  numeric;
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

  -- Promo code: one discount per order, the best one applies.
  if coalesce(trim(p->>'promo_code'), '') <> '' then
    v_ppct := public._promo_pct(p->>'promo_code');
    if v_ppct > case v_dtype when 'byu' then public.setting_num('byu_discount_pct')
                             when 'business' then public.setting_num('business_discount_pct') else 0 end then
      v_dtype := 'promo';
      v_promo := upper(trim(p->>'promo_code'));
    end if;
  end if;

  return jsonb_build_object(
    'customer_id', v_cust.id, 'channel', 'portal', 'fulfillment_method', 'pickup',
    'location_id', v_loc.id, 'discount_type', v_dtype,
    'payment_method', case when v_cust.terms_days > 0 then 'account' else 'card' end,
    'promo_code', v_promo,
    'need_date', v_need, 'notes', left(nullif(trim(p->>'notes'), ''), 500),
    'lines', v_lines);
end;
$$;

revoke execute on function public._promo_pct(text) from public, anon, authenticated;
