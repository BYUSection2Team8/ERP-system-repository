-- =============================================================================
-- 020_shipping_zones.sql — zone x weight shipping (rest of wow #6)
--
-- Setting shipping_mode: 'flat' (default: the flat shipping fee, as before) or
-- 'zone': postage from a USPS Ground Advantage-style table (zone from Stansbury
-- Park, UT by destination state x parcel weight) plus a handling fee.
--   parcel weight = sum(qty x item weight) + box weight
--   item weight   = items.weight_g, else filament grams per unit + 5 g per
--                   counted component + 10 g
-- The rate table and zones are data (shipping_zones, shipping_rates), editable by staff.
-- _price_sales_order and _custom_quote are re-created with this one change, so
-- every quote still equals the saved order.
-- =============================================================================

insert into public.settings (key, value, type, category, label, description) values
  ('shipping_mode',          'flat', 'text',   'fulfillment', 'Shipping pricing (flat or zone)', 'flat = flat shipping fee; zone = zone x weight table + handling fee.'),
  ('shipping_handling_fee',  '1.00', 'number', 'fulfillment', 'Handling fee per shipped order (zone mode)', null),
  ('box_weight_g',           '150',  'number', 'fulfillment', 'Box + packing weight (g)', 'Added to every parcel weight.')
on conflict (key) do nothing;

create table if not exists public.shipping_zones (
  state text primary key check (state ~ '^[A-Z]{2}$'),
  zone  int not null check (zone between 1 and 9)
);
create table if not exists public.shipping_rates (
  zone   int not null check (zone between 1 and 9),
  max_oz numeric(8,2) not null check (max_oz > 0),
  rate   numeric(8,2) not null check (rate >= 0),
  primary key (zone, max_oz)
);
alter table public.shipping_zones enable row level security;
alter table public.shipping_rates enable row level security;
drop policy if exists signed_in_read on public.shipping_zones;
drop policy if exists signed_in_read on public.shipping_rates;
drop policy if exists staff_write on public.shipping_zones;
drop policy if exists staff_write on public.shipping_rates;
create policy signed_in_read on public.shipping_zones for select to authenticated using (true);
create policy signed_in_read on public.shipping_rates for select to authenticated using (true);
create policy staff_write on public.shipping_zones for all to authenticated using (public.is_staff()) with check (public.is_staff());
create policy staff_write on public.shipping_rates for all to authenticated using (public.is_staff()) with check (public.is_staff());
revoke all on public.shipping_zones, public.shipping_rates from anon;

-- Zones from Stansbury Park, UT (84074).
insert into public.shipping_zones (state, zone)
select s, z from (values
  (2, array['UT']),
  (4, array['ID','NV','AZ','WY','CO']),
  (5, array['MT','NM','OR','CA','WA']),
  (6, array['ND','SD','NE','KS','OK','TX']),
  (7, array['MN','IA','MO','AR','LA','WI','IL','MS','AL','TN','KY','IN','MI']),
  (8, array['OH','GA','FL','SC','NC','VA','WV','PA','NY','NJ','DE','MD','DC','CT','RI','MA','VT','NH','ME','AK','HI'])
) as x(z, states) cross join unnest(x.states) s
on conflict (state) do nothing;

-- Ground Advantage-style rates: base by weight bracket, +9% per zone, to the nearest 5 cents.
insert into public.shipping_rates (zone, max_oz, rate)
select z, b.max_oz, round(b.base * (1 + 0.09 * (z - 1)) * 20) / 20
  from generate_series(1, 8) z
  cross join (values (4, 4.75), (8, 5.25), (12, 6.00), (15.99, 7.25), (32, 8.40), (48, 9.90), (80, 12.75), (160, 18.50), (320, 27.00)) as b(max_oz, base)
on conflict (zone, max_oz) do nothing;

-- Shipping weight of one unit of an item (grams).
create or replace function public._item_ship_weight_g(p_item uuid)
returns numeric
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(i.weight_g,
           coalesce((select sum(case when c.uom = 'g' then b.qty_per_unit else b.qty_per_unit * 5 end)
                       from public.v_bom_per_unit b join public.items c on c.id = b.component_item_id
                      where b.parent_item_id = i.id), 0) + 10)
    from public.items i where i.id = p_item;
$$;

-- Postage for a parcel (grams of goods) to a state: zone, weight, rate + handling.
create or replace function public._zone_postage(p_state text, p_goods_g numeric)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_zone int;
  v_oz   numeric := (coalesce(p_goods_g, 0) + public.setting_num('box_weight_g')) / 28.3495;
  v_rate numeric;
  v_hand numeric := public.setting_num('shipping_handling_fee');
begin
  select zone into v_zone from shipping_zones where state = upper(p_state);
  if not found then raise exception 'We do not ship to % yet.', upper(coalesce(p_state, '?')); end if;
  select rate into v_rate from shipping_rates where zone = v_zone and max_oz >= v_oz order by max_oz limit 1;
  if not found then raise exception 'This order is too heavy for one parcel (% oz). Please split it.', round(v_oz, 1); end if;
  return jsonb_build_object('zone', v_zone, 'weight_oz', round(v_oz, 1), 'postage', v_rate,
                            'handling', v_hand, 'total', v_rate + v_hand);
end;
$$;

-- Shipping estimate for lines [{item_id, qty}] to a state (any signed-in user).
create or replace function public.shipping_quote(p_state text, p_lines jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v_g numeric := 0; x jsonb;
begin
  perform public._require_signed_in();
  if jsonb_typeof(p_lines) = 'array' then
    for x in select * from jsonb_array_elements(p_lines) loop
      if coalesce(x->>'item_id', '') ~ '^[0-9a-fA-F-]{36}$' and coalesce(x->>'qty', '') ~ '^\s*\d+(\.\d+)?\s*$' then
        v_g := v_g + (x->>'qty')::numeric * coalesce(public._item_ship_weight_g((x->>'item_id')::uuid), 0);
      end if;
    end loop;
  end if;
  return public._zone_postage(p_state, v_g) || jsonb_build_object('mode', public.setting_text('shipping_mode'));
end;
$$;

-- ---------------------------------------------------------------------------
-- _price_sales_order: same as 007, shipping now follows shipping_mode.
-- ---------------------------------------------------------------------------
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
    'lines', v_lines);
end;
$$;


-- _custom_quote: same as 014, shipping now follows shipping_mode (custom item weight = grams + 10 per unit).
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
    v_ship := case when public.setting_text('shipping_mode') = 'zone'
                   then (public._zone_postage(v_state, v_qty * (v_grams + 10))->>'total')::numeric
                   else public.setting_num('flat_shipping_fee') end;
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

revoke execute on function public._item_ship_weight_g(uuid), public._zone_postage(text, numeric) from public, anon, authenticated;
revoke execute on function public.shipping_quote(text, jsonb) from public, anon;
grant execute on function public.shipping_quote(text, jsonb) to authenticated;
