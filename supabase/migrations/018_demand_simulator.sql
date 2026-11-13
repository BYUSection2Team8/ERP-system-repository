-- =============================================================================
-- 018_demand_simulator.sql — demand simulator (rest of wow #8)
--
-- simulate_demand(days, event, seed): creates the orders the next 1-7 days would
-- bring, from the business's own recent history:
--   expected units per item per day = average daily units sold over the last
--     28 days x weekday factor (that weekday's share of the last 56 days)
--     x event factor (BYU home game: BYU Logo and blue items x2, others x1.2;
--     Black Friday: x2.5; slow week: x0.5)
--   units = Poisson(expected); units are grouped into orders of the usual size;
--   customers drawn from the customer list; ~80% ship, ~20% campus pickup.
-- The orders arrive now as "Order placed" (need dates spread over the simulated
-- days), so MRP, backorders, production and the dashboard react like real demand.
-- Every simulated order is marked "[Simulated demand]" in its notes.
-- =============================================================================

create or replace function public._poisson(p_lambda numeric)
returns int
language plpgsql volatile
set search_path = public, pg_temp
as $$
declare v_l float8; v_p float8 := 1; v_k int := 0;
begin
  if p_lambda is null or p_lambda <= 0 then return 0; end if;
  if p_lambda > 30 then   -- normal approximation for large means
    return greatest(0, round(p_lambda + sqrt(p_lambda) * sqrt(-2 * ln(greatest(random(), 1e-12))) * cos(2 * pi() * random())))::int;
  end if;
  v_l := exp(-p_lambda);
  loop
    v_k := v_k + 1;
    v_p := v_p * random();
    exit when v_p <= v_l;
  end loop;
  return v_k - 1;
end;
$$;

create or replace function public.simulate_demand(p_days int default 1, p_event text default null, p_seed float8 default null)
returns jsonb
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_tz      text := public.setting_text('time_zone');
  v_today   date := public._local_date(now());
  v_day     date;
  v_k       int;
  v_dow_f   numeric;
  v_units_per_order numeric;
  v_expected numeric := 0;
  v_units   int := 0;
  v_orders  int := 0;
  v_value   numeric := 0;
  v_pool    uuid[] := '{}';
  v_n       int;
  v_i       int;
  v_lines   jsonb;
  v_cust    customers%rowtype;
  v_ship    boolean;
  v_so      uuid;
  v_ids     uuid[] := '{}';
  r         record;
  v_size    int;
  v_take    int;
begin
  perform public._require_staff();
  if p_days is null or p_days < 1 or p_days > 7 then raise exception 'Simulate 1 to 7 days.'; end if;
  if p_event is not null and p_event not in ('byu_game', 'black_friday', 'slow') then raise exception 'Unknown event %.', p_event; end if;
  if p_seed is not null then perform setseed(least(greatest(p_seed, -1), 1)); end if;

  -- Usual order size from the last 28 days (units per fulfilled order).
  select coalesce(sum(l.qty)::numeric / nullif(count(distinct so.id), 0), 2) into v_units_per_order
    from sales_orders so join sales_order_lines l on l.so_id = so.id
   where so.fulfilled_at >= now() - interval '28 days' and so.channel <> 'pos';
  v_units_per_order := greatest(1, least(v_units_per_order, 6));

  for v_k in 0 .. p_days - 1 loop
    v_day := v_today + v_k;
    -- Weekday factor from the last 56 days of units sold.
    select coalesce(avg(case when extract(isodow from d) = extract(isodow from v_day) then u end)
                    / nullif(avg(u), 0), 1)
      into v_dow_f
      from (select g::date as d,
                   coalesce((select sum(l.qty) from sales_orders so join sales_order_lines l on l.so_id = so.id
                              where (so.fulfilled_at at time zone v_tz)::date = g::date), 0) as u
              from generate_series(v_today - 56, v_today - 1, interval '1 day') g) x;
    v_dow_f := coalesce(v_dow_f, 1);

    -- Units per item for the day.
    v_pool := '{}';
    for r in
      select i.id, i.product_family, i.color,
             coalesce((select sum(l.qty) from sales_orders so join sales_order_lines l on l.so_id = so.id
                        where l.item_id = i.id and so.fulfilled_at >= now() - interval '28 days'), 0) / 28.0 as base
        from items i
       where i.category = 'product' and i.is_active and i.price is not null and not i.is_custom
         and i.stocking_policy <> 'not_sold'
         and public._in_season(i.stocking_policy, i.season_start, i.season_end, v_day)
    loop
      declare v_lambda numeric := r.base * v_dow_f
        * case p_event
            when 'black_friday' then 2.5
            when 'slow' then 0.5
            when 'byu_game' then case when r.product_family = 'BYU Logo' or r.color = 'Blue' then 2 else 1.2 end
            else 1 end;
      begin
        v_expected := v_expected + v_lambda;
        v_n := public._poisson(v_lambda);
        for v_i in 1 .. v_n loop v_pool := v_pool || r.id; end loop;
      end;
    end loop;

    -- Shuffle the units and group them into orders of the usual size.
    select coalesce(array_agg(x order by random()), '{}') into v_pool from unnest(v_pool) x;
    v_i := 1;
    while v_i <= coalesce(array_length(v_pool, 1), 0) loop
      v_size := greatest(1, public._poisson(v_units_per_order - 1) + 1);
      select jsonb_agg(jsonb_build_object('item_id', item_id, 'qty', n)) into v_lines
        from (select x as item_id, count(*) as n from unnest(v_pool[v_i : v_i + v_size - 1]) x group by x) g;
      v_take := least(v_size, array_length(v_pool, 1) - v_i + 1);
      v_i := v_i + v_size;

      select * into v_cust from customers
       where is_active and segment is distinct from 'walk_in' and name not like 'Demo%'
       order by random() limit 1;
      v_ship := random() < 0.8 or v_cust.state is distinct from 'UT';
      v_so := public._insert_sales_order(jsonb_build_object(
        'customer_id', v_cust.id, 'channel', 'online',
        'fulfillment_method', case when v_ship then 'ship' else 'pickup' end,
        'location_code', case when v_ship then 'FULFILLMENT' else 'CAMPUS' end,
        'ship_state', coalesce(v_cust.state, 'UT'),
        'discount_type', case when v_cust.is_byu then 'byu' else 'none' end,
        'need_date', v_day + case when v_ship then 3 else 1 end,
        'notes', '[Simulated demand]' || coalesce(' ' || replace(p_event, '_', ' '), ''),
        'lines', v_lines));
      v_ids := v_ids || v_so;
      v_orders := v_orders + 1;
      v_units := v_units + v_take;
      v_value := v_value + (select total from sales_orders where id = v_so);
    end loop;
  end loop;

  perform public._log('demand.simulated', 'sales_order', null,
    format('Simulated %s day(s)%s: %s orders, %s units, $%s', p_days, coalesce(' (' || replace(p_event, '_', ' ') || ')', ''),
           v_orders, v_units, to_char(v_value, 'FM999,990.00')), '/sales', now());
  return jsonb_build_object('days', p_days, 'event', p_event, 'orders', v_orders, 'units', v_units,
                            'value', round(v_value, 2), 'expected_units', round(v_expected, 2),
                            'units_per_order', round(v_units_per_order, 2), 'order_ids', to_jsonb(v_ids));
end;
$$;

revoke execute on function public._poisson(numeric) from public, anon, authenticated;
revoke execute on function public.simulate_demand(int, text, float8) from public, anon;
grant execute on function public.simulate_demand(int, text, float8) to authenticated;
