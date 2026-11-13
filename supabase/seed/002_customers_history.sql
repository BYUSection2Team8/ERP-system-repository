-- =============================================================================
-- seed/002_customers_history.sql — Phase 6: all 60 customers + 6 months of history
--
-- Run AFTER seed/001_starter_data.sql and every migration.
--
-- Nothing here inserts a balance, a cost or an order total. The history is
-- produced by calling the SAME business functions the app uses, one simulated
-- day at a time (about 180 days ending yesterday):
--   * customers order from the demand model below -> create_sales_order / pos_sale
--   * made-to-order items and low stock trigger production orders
--     -> create / issue / complete_production_order (with realistic print failures)
--   * low components trigger purchase orders -> create_purchase_order, receipts that
--     arrive on time, late, split or short by supplier -> receive / close PO,
--     Net-terms bills paid near their due date -> record_supplier_payment
--   * Tue/Fri delivery runs to campus -> transfer_inventory
--   * orders are fulfilled and closed (on-account orders when the customer pays),
--     a few are returned or exchanged -> process_return, QA Hold inspections,
--     cycle counts -> count_inventory / adjust_inventory
-- so every balance, cost, reorder point, EOQ and scorecard is DERIVED.
--
-- Demand model (SPEC.md): daily orders per segment =
--   base x trend (3%/month) x season x day-of-week x events (BYU home games,
--   Black Friday) with Poisson noise. Colors, products and quantities follow
--   each segment's preferences.
--
-- Safe to re-run: it continues where it stopped and does nothing once complete.
-- Each run works for at most ~45 seconds (the SQL Editor may time out on longer
-- requests) and then COMMITS what it did. If the result row says
-- "run this file again", paste and run it again until it says COMPLETE.
-- =============================================================================
set statement_timeout = 0;

-- ---------------------------------------------------------------------------
-- Helpers (pg_temp: they exist only for this session)
-- ---------------------------------------------------------------------------
create or replace function pg_temp.h_ts(p_d date, p_hours double precision)
returns timestamptz language sql immutable as $$
  select ((p_d::timestamp + make_interval(secs => p_hours * 3600)) at time zone 'America/Denver');
$$;

create or replace function pg_temp.h_local(p_at timestamptz)
returns date language sql immutable as $$
  select (p_at at time zone 'America/Denver')::date;
$$;

-- Deterministic 0..999 from a key: lets later runs re-derive decisions
-- (delivery delays, payment days, returns) instead of storing them.
create or replace function pg_temp.h_hash(p_key text, p_salt text)
returns int language sql immutable as $$
  select (((hashtext(p_key || ':' || p_salt))::bigint % 1000 + 1000) % 1000)::int;
$$;

create or replace function pg_temp.h_poisson(p_lambda numeric)
returns int language plpgsql volatile as $$
declare
  l double precision;
  k int := 0;
  p double precision := 1;
begin
  if p_lambda is null or p_lambda <= 0 then return 0; end if;
  l := exp(-p_lambda::double precision);
  loop
    p := p * random();
    exit when p <= l;
    k := k + 1;
  end loop;
  return k;
end;
$$;

create or replace function pg_temp.h_pick(p_choices text[], p_weights numeric[])
returns text language plpgsql volatile as $$
declare
  v_total numeric := 0;
  v_r numeric;
  i int;
begin
  for i in 1 .. array_length(p_weights, 1) loop v_total := v_total + p_weights[i]; end loop;
  v_r := random()::numeric * v_total;
  for i in 1 .. array_length(p_weights, 1) loop
    if p_weights[i] > 0 then
      v_r := v_r - p_weights[i];
      if v_r <= 0 then return p_choices[i]; end if;
    end if;
  end loop;
  for i in reverse array_length(p_weights, 1) .. 1 loop
    if p_weights[i] > 0 then return p_choices[i]; end if;
  end loop;
  return p_choices[1];
end;
$$;

-- BYU home football: five Saturdays every other week from the first Saturday of
-- September; demand lifts the two days before and on game day.
create or replace function pg_temp.h_game_day(p_d date)
returns boolean language plpgsql immutable as $$
declare
  v_s1 date := make_date(extract(year from p_d)::int, 9, 1);
  v_sat date;
begin
  v_sat := v_s1 + ((6 - extract(dow from v_s1)::int + 7) % 7);
  for k in 0 .. 4 loop
    if p_d between v_sat + 14 * k - 2 and v_sat + 14 * k then return true; end if;
  end loop;
  return false;
end;
$$;

create or replace function pg_temp.h_black_friday(p_d date)
returns date language sql immutable as $$
  select make_date(extract(year from p_d)::int, 11, 1)
         + ((5 - extract(dow from make_date(extract(year from p_d)::int, 11, 1))::int + 7) % 7) + 21;
$$;

-- Seasonality by customer segment.
create or replace function pg_temp.h_season(p_seg text, p_d date)
returns numeric language plpgsql immutable as $$
declare
  m int := extract(month from p_d);
  dd int := extract(day from p_d);
begin
  return case p_seg
    when 'student' then case
        when m in (6, 7) then 0.35
        when m = 5 then case when dd < 5 then 0.9 else 0.45 end
        when m = 8 and dd < 24 then 0.6
        when (m = 8 and dd >= 24) or m = 9 then 1.8      -- back to school
        when m = 10 then 1.15
        when m = 11 then 1.25
        when m = 12 then case when dd < 18 then 1.3 else 0.4 end
        else 1 end
    when 'gift_buyer' then case
        when m in (5, 6, 7, 8) then 0.6
        when m = 9 then 0.8
        when m = 10 then 1.0
        when m = 11 then 1.4 * (1 + dd / 30.0)          -- holiday ramp
        when m = 12 then 2.6
        else 1 end
    when 'hobbyist' then case when m in (6, 7, 8) then 1.15 when m in (11, 12) then 1.2 else 1 end
    when 'local_family' then case
        when m in (6, 7, 8) then 1.35                    -- summer
        when m in (9, 10) then 0.8
        when m in (11, 12) then 1.4
        else 1 end
    else 1 end;
end;
$$;

create or replace function pg_temp.h_event(p_seg text, p_d date)
returns numeric language plpgsql immutable as $$
declare
  v numeric := 1;
  v_bf date := pg_temp.h_black_friday(p_d);
begin
  if pg_temp.h_game_day(p_d) and p_seg in ('student', 'local_family') then v := v * 1.6; end if;
  if p_d = v_bf then v := v * case when p_seg = 'gift_buyer' then 3 else 2 end;
  elsif p_d between v_bf + 1 and v_bf + 3 then v := v * 1.6;
  end if;
  return v;
end;
$$;

-- Online orders peak Sunday/Monday evenings.
create or replace function pg_temp.h_dow(p_d date)
returns numeric language sql immutable as $$
  select (array[1.3, 1.25, 1.0, 0.95, 0.9, 0.85, 0.8])[extract(dow from p_d)::int + 1]::numeric;
$$;

create or replace function pg_temp.h_family(p_seg text, p_d date)
returns text language plpgsql volatile as $$
declare
  v_orn boolean := extract(month from p_d) in (11, 12);
  v_game boolean := pg_temp.h_game_day(p_d);
begin
  return case p_seg
    when 'student' then pg_temp.h_pick(array['KEY','BYU','SPN','DRG','ORN','MAG'],
           array[4, case when v_game then 7 else 3 end, 2.5, 2, case when v_orn then 2 else 0 end, 0.3]::numeric[])
    when 'gift_buyer' then pg_temp.h_pick(array['TMP','MAG','AIR','ORN','DRG','BYU'],
           array[3, 2, 0.8, case when v_orn then 3 else 0 end, 1, 0.5]::numeric[])
    when 'hobbyist' then pg_temp.h_pick(array['ARM','AIR','DRG','SPN'], array[3, 0.9, 2, 0.8]::numeric[])
    else pg_temp.h_pick(array['MAG','DRG','SPN','KEY','ORN','TMP','BYU'],
           array[2, 2, 2, 1.5, case when v_orn then 1.5 else 0 end, 0.5, case when v_game then 2 else 0.4 end]::numeric[])
  end;
end;
$$;

-- Color mix: blue leads BYU items, white leads temples, black leads soldiers.
create or replace function pg_temp.h_color(p_fam text, p_d date)
returns text language plpgsql volatile as $$
declare v_game boolean := pg_temp.h_game_day(p_d);
begin
  if p_fam = 'KEY' then return 'BW'; end if;
  if p_fam = 'AIR' then return 'MC'; end if;
  return pg_temp.h_pick(array['RED','WHITE','BLUE','BLACK'], case p_fam
    when 'BYU' then array[10, 20, case when v_game then 75 else 55 end, 15]
    when 'TMP' then array[15, 50, 20, 15]
    when 'ARM' then array[20, 15, 20, 45]
    when 'DRG' then array[30, 15, 30, 25]
    when 'SPN' then array[20, 15, 35, 30]
    when 'MAG' then array[30, 20, 30, 20]
    when 'ORN' then array[40, 30, 15, 15]
    else array[25, 25, 25, 25] end::numeric[]);
end;
$$;

create or replace function pg_temp.h_qty(p_seg text, p_fam text)
returns int language sql volatile as $$
  select case
    when p_fam = 'KEY' then 1 + (random() < 0.35)::int + (random() < 0.15)::int
    when p_seg = 'hobbyist' and p_fam = 'ARM' then 1 + (random() < 0.4)::int + (random() < 0.15)::int
    when p_seg in ('hobbyist', 'local_family') then 1 + (random() < 0.2)::int
    when p_seg = 'gift_buyer' then 1 + (random() < 0.12)::int
    else 1 end;
$$;

-- Stocked items: (fulfillment target, reorder trigger, campus target). Zero = make to order.
create or replace function pg_temp.h_rule(p_fam text, p_d date, out ff_target int, out ff_rop int, out cp_target int)
language plpgsql immutable as $$
begin
  ff_target := 0; ff_rop := 0; cp_target := 0;
  if p_fam = 'DRG' then ff_target := 14; ff_rop := 8;  cp_target := 6;
  elsif p_fam = 'SPN' then ff_target := 10; ff_rop := 6; cp_target := 5;
  elsif p_fam = 'KEY' then ff_target := 60; ff_rop := 30; cp_target := 20;
  elsif p_fam = 'ORN' and (to_char(p_d, 'MM-DD') between '10-12' and '12-20') then
    ff_target := 24; ff_rop := 10; cp_target := 8;
  end if;
end;
$$;

-- When a production order really finishes: plates run on 4 printers in parallel,
-- plus assembly. Prints that end after 8pm are completed at 8am next morning.
create or replace function pg_temp.h_finish(p_id uuid, p_start timestamptz, p_plates int, p_print numeric, p_asm numeric)
returns timestamptz language plpgsql immutable as $$
declare
  v_f timestamptz;
  v_l timestamp;
  v_wait numeric := pg_temp.h_hash(p_id::text, 'wait') % 40 / 60.0;
begin
  v_f := p_start + make_interval(mins => (ceil(p_plates / 4.0) * coalesce(p_print, 60) + p_plates * coalesce(p_asm, 0)
                                          + 10 + pg_temp.h_hash(p_id::text, 'fin') % 30)::int);
  v_l := v_f at time zone 'America/Denver';
  if extract(hour from v_l) >= 20 then return pg_temp.h_ts(v_l::date + 1, 8 + v_wait); end if;
  if extract(hour from v_l) < 8 then return pg_temp.h_ts(v_l::date, 8 + v_wait); end if;
  return v_f;
end;
$$;

-- Print failure rate per plate. The tall Airplane warps more; one printer was
-- due for maintenance mid-Sept to mid-Oct (clogs and layer shifts).
create or replace function pg_temp.h_fail_p(p_fam text, p_at timestamptz)
returns numeric language plpgsql immutable as $$
declare
  v numeric := case p_fam when 'Airplane' then 0.14 when 'Temple LED Tealight' then 0.06
                 when 'Magnet Alphabet Set' then 0.05 when 'Army Soldiers (lot of 10)' then 0.05
                 when 'Keychain' then 0.05 when 'BYU Logo' then 0.04 else 0.03 end;
  v_md text := to_char(p_at at time zone 'America/Denver', 'MM-DD');
begin
  if v_md between '09-15' and '10-20' then v := v * 1.8; end if;
  return v;
end;
$$;

create or replace function pg_temp.h_fail_reason(p_fam text, p_at timestamptz)
returns text language plpgsql volatile as $$
declare v_md text := to_char(p_at at time zone 'America/Denver', 'MM-DD');
begin
  if p_fam = 'Airplane' then
    return pg_temp.h_pick(array['SCRAP_WARPING','SCRAP_BED_ADHESION','SCRAP_SPAGHETTI','SCRAP_STRINGING'], array[50, 20, 15, 15]::numeric[]);
  end if;
  if v_md between '09-15' and '10-20' then
    return pg_temp.h_pick(array['SCRAP_NOZZLE_CLOG','SCRAP_LAYER_SHIFT','SCRAP_BED_ADHESION','SCRAP_SPAGHETTI','SCRAP_STRINGING','SCRAP_RUNOUT'],
                          array[35, 25, 15, 10, 10, 5]::numeric[]);
  end if;
  return pg_temp.h_pick(array['SCRAP_BED_ADHESION','SCRAP_SPAGHETTI','SCRAP_STRINGING','SCRAP_RUNOUT','SCRAP_LAYER_SHIFT',
                              'SCRAP_NOZZLE_CLOG','SCRAP_WARPING','SCRAP_POWER','SCRAP_ASSEMBLY'],
                        array[25, 20, 18, 12, 8, 7, 5, 3,
                              case when p_fam in ('Magnet Alphabet Set','Army Soldiers (lot of 10)','Temple LED Tealight') then 12 else 0 end]::numeric[]);
end;
$$;

-- Supplier delivery behavior (drives the scorecard): days late vs quoted lead time.
create or replace function pg_temp.h_delay(p_sup text, p_po uuid)
returns int language plpgsql immutable as $$
declare h int := pg_temp.h_hash(p_po::text, 'delay');
begin
  return case p_sup
    when 'Hobby Lobby'     then case when h < 880 then 0 else 1 end
    when 'Bambu Lab'       then case when h < 150 then -1 when h < 600 then 0 when h < 800 then 1 when h < 920 then 2 else 4 end
    when 'Uline'           then case when h < 900 then 0 else 1 end
    when 'Amazon Business' then case when h < 750 then 0 when h < 900 then 1 else 2 end
    when 'K&J Magnetics'   then case when h < 600 then 0 when h < 800 then 1 when h < 930 then 2 else 3 end
    when 'VXB Bearings'    then case when h < 250 then 0 when h < 450 then 2 when h < 700 then 3 when h < 900 then 5 else 7 end
    when 'Vistaprint'      then case when h < 650 then 0 when h < 850 then 1 else 3 end
    else 0 end;
end;
$$;

-- 'split' = part now, rest 3 days later; 'short' = some never shipped (PO closed short).
create or replace function pg_temp.h_ship_mode(p_sup text, p_po uuid)
returns text language plpgsql immutable as $$
declare h int := pg_temp.h_hash(p_po::text, 'mode');
begin
  if p_sup = 'Amazon Business' and h < 250 then return 'split'; end if;
  if p_sup = 'K&J Magnetics' and h < 300 then return 'short'; end if;
  if p_sup = 'VXB Bearings' and h < 150 then return 'short'; end if;
  return 'full';
end;
$$;

create temp table if not exists _h_err (what text, msg text);
create temp table if not exists _h_req (at timestamptz, cust uuid, seg text, method text, lines jsonb, biz boolean);

-- Place one order request; returns the sales order id (null if it could not be placed).
create or replace function pg_temp.h_place(p_at timestamptz, p_cust uuid, p_seg text, p_method text, p_lines jsonb, p_biz boolean)
returns uuid language plpgsql set search_path = public, pg_temp as $$
declare
  v_c customers%rowtype;
  v_units numeric := (select coalesce(sum((x->>'qty')::numeric), 0) from jsonb_array_elements(p_lines) x);
  v_mto boolean := exists (select 1 from jsonb_array_elements(p_lines) x join items i on i.id = (x->>'item_id')::uuid
                            where i.stocking_policy = 'make_to_order');
  v_d date := pg_temp.h_local(p_at);
  v_disc jsonb;
  v_id uuid;
  v_cp uuid := (select id from locations where code = 'CAMPUS');
begin
  select * into v_c from customers where id = p_cust;
  v_disc := case
    when v_c.is_byu then jsonb_build_object('discount_type', 'byu')
    when p_biz and v_units >= 25 then jsonb_build_object('discount_type', 'business')
    when random() < 0.012 then jsonb_build_object('discount_type', 'manual', 'discount_pct', 0.10, 'discount_reason',
                                pg_temp.h_pick(array['DISC_SERVICE','DISC_LOYALTY','DISC_PRICE_MATCH'], array[5, 3, 2]::numeric[]))
    else '{}'::jsonb end;

  -- Counter sale: only if every line is on the campus shelf now; otherwise a pickup order.
  if p_method = 'counter' then
    if not exists (select 1 from jsonb_array_elements(p_lines) x
                    where (x->>'qty')::numeric > coalesce((select sum(t.qty) from inventory_txn t
                                                           where t.item_id = (x->>'item_id')::uuid and t.location_id = v_cp), 0)) then
      begin
        return pos_sale(jsonb_build_object('customer_id', p_cust, 'lines', p_lines, 'order_date', p_at,
                          'payment_method', case when random() < 0.3 then 'cash' else 'card' end) || v_disc);
      exception when others then
        insert into _h_err values ('pos', sqlerrm);
        return null;
      end;
    end if;
    p_method := 'pickup';
  end if;

  begin
    v_id := create_sales_order(jsonb_build_object(
      'customer_id', p_cust,
      'channel', case when p_seg = 'gift_buyer' and random() < 0.08 then 'phone' else 'online' end,
      'fulfillment_method', p_method,
      'location_code', case when p_method = 'pickup' then 'CAMPUS' else 'FULFILLMENT' end,
      'need_date', v_d + case when p_biz then 7 when v_mto then 5 else 2 end + case when p_method = 'pickup' then 1 else 0 end,
      'order_date', p_at,
      'lines', p_lines) || v_disc);
  exception when others then
    insert into _h_err values ('order', sqlerrm);
    v_id := null;
  end;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- One simulated business day.
-- ---------------------------------------------------------------------------
create or replace function pg_temp.h_day(d date, v_start date, v_end date)
returns void language plpgsql set search_path = public, pg_temp as $$
declare
  v_pf uuid := (select id from locations where code = 'PRINT_FARM');
  v_ff uuid := (select id from locations where code = 'FULFILLMENT');
  v_cp uuid := (select id from locations where code = 'CAMPUS');
  v_qa uuid := (select id from locations where code = 'QA_HOLD');
  v_dow int := extract(dow from d)::int;
  v_weekday boolean := extract(dow from d)::int between 1 and 5;
  v_trend numeric := power(1.03::numeric, ((d - v_start) / 30.0)::numeric);
  v_orn boolean := extract(month from d) in (11, 12);
  r record;
  it record;
  v_id uuid;
  v_n int; v_k int; v_j int; v_q numeric; v_i int;
  v_seg text; v_fam text; v_sku text;
  v_custs uuid[]; v_cust uuid;
  v_map jsonb; v_lines jsonb; v_po jsonb;
  v_dem jsonb; v_demloc jsonb;
  v_oh numeric; v_wip numeric; v_pos numeric; v_need numeric; v_avail numeric;
  v_rate numeric; v_lead int; v_rop numeric; v_upto numeric; v_onorder numeric; v_alloc numeric;
  v_rule record;
  v_last date; v_arr date; v_mode text; v_fin timestamptz;
  v_failed int; v_scrap int; v_reason text;
  v_at timestamptz; v_days int; v_kind text; v_line record; v_other uuid;
  v_ret jsonb;
begin
  perform setseed(((d - date '2000-01-01') % 997) / 997.0);

  -- 1. Supplier deliveries (07:30-11:00) ------------------------------------
  for r in select po.id, po.status, po.order_date, po.lead_days, s.name as sup
             from purchase_orders po join suppliers s on s.id = po.supplier_id
            where po.status in ('sent', 'partial')
            order by po.order_date loop
    v_mode := pg_temp.h_ship_mode(r.sup, r.id);
    if r.status = 'sent' then
      v_arr := pg_temp.h_local(r.order_date) + r.lead_days + pg_temp.h_delay(r.sup, r.id);
      continue when v_arr > d;
      v_lines := null;
      if v_mode <> 'full' then
        select jsonb_agg(jsonb_build_object('po_line_id', l.id, 'qty',
                 greatest(1, floor(l.qty_ordered * case when v_mode = 'split' then 0.5 + random() * 0.3 else 0.85 + random() * 0.1 end))))
          into v_lines from purchase_order_lines l where l.po_id = r.id;
      end if;
      begin
        perform receive_purchase_order(r.id, v_lines, null, greatest(pg_temp.h_ts(d, 10 + random()), r.order_date + interval '1 hour'),
                                       false, case v_mode when 'split' then 'Partial shipment; rest to follow'
                                                          when 'short' then 'Short shipment' end);
      exception when others then insert into _h_err values ('receive', sqlerrm);
      end;
    elsif v_mode = 'split' then
      select pg_temp.h_local(max(received_at)) into v_last from po_receipts where po_id = r.id;
      if v_last + 3 <= d then
        begin
          perform receive_purchase_order(r.id, null, null, pg_temp.h_ts(d, 10.5), false, 'Rest of split shipment');
        exception when others then insert into _h_err values ('receive rest', sqlerrm);
        end;
      end if;
    end if;
  end loop;

  -- 2. Prints that finished overnight are completed at 8am -------------------
  perform pg_temp.h_complete(pg_temp.h_ts(d, 9));

  -- 3. Close delivered orders; on-account customers pay ~Net 30 -------------
  for r in select id, fulfilled_at, payment_method, fulfillment_method from sales_orders where status = 'fulfilled' loop
    v_days := case when r.payment_method = 'account' then 25 + pg_temp.h_hash(r.id::text, 'pay') % 10
                   when r.fulfillment_method = 'ship' then 3 + pg_temp.h_hash(r.id::text, 'dlv') % 3
                   else 1 end;
    if pg_temp.h_local(r.fulfilled_at) + v_days <= d then
      begin
        perform close_sales_order(r.id, greatest(pg_temp.h_ts(d, 8.25), r.fulfilled_at + interval '1 minute'));
      exception when others then insert into _h_err values ('close', sqlerrm);
      end;
    end if;
  end loop;

  -- 4. Production planning (08:15) and issue (08:30) -------------------------
  select coalesce(jsonb_object_agg(x.item_id, x.q), '{}'::jsonb) into v_dem
    from (select l.item_id, sum(l.qty - l.qty_fulfilled) as q
            from sales_orders so join sales_order_lines l on l.so_id = so.id
           where so.status = 'placed' group by l.item_id) x;
  for it in select i.id, i.product_family as fam, i.units_per_plate as upp, coalesce(i.lead_time_days, 1) as lead
              from items i
             where i.item_type = 'finished' and i.is_active
               and exists (select 1 from boms b where b.parent_item_id = i.id) loop
    v_oh := coalesce((select sum(qty) from inventory_txn where item_id = it.id and location_id in (v_ff, v_cp)), 0);
    v_wip := coalesce((select sum(case when status = 'in_progress' then qty_started else plates * it.upp end)
                         from production_orders where item_id = it.id and status in ('planned', 'in_progress')), 0);
    v_pos := v_oh + v_wip - coalesce((v_dem ->> it.id::text)::numeric, 0);
    select * into v_rule from pg_temp.h_rule(
      case it.fam when 'Dragon' then 'DRG' when 'Fidget Spinner' then 'SPN' when 'Keychain' then 'KEY'
                  when 'Christmas Ornament' then 'ORN' else 'MTO' end, d);
    v_q := 0;
    if v_rule.ff_rop > 0 then
      if v_pos < v_rule.ff_rop + v_rule.cp_target then v_q := v_rule.ff_target + v_rule.cp_target - v_pos; end if;
    elsif v_pos < 0 then
      v_q := -v_pos;
    end if;
    if v_q > 0 then
      begin
        perform create_production_order(it.id, v_q, d + it.lead, null, v_pf, v_ff,
                  case when v_rule.ff_rop > 0 then 'Restock' else 'Made to order' end, pg_temp.h_ts(d, 8.2));
      exception when others then insert into _h_err values ('plan MO', sqlerrm);
      end;
    end if;
  end loop;

  v_k := 0;
  for r in select mo.id from production_orders mo where mo.status = 'planned'
            order by coalesce(mo.due_date, pg_temp.h_local(mo.created_at)), mo.created_at loop
    continue when exists (
      select 1 from production_order_components c
       where c.mo_id = r.id
         and c.qty_required > coalesce((select sum(t.qty) from inventory_txn t
                                         where t.item_id = c.item_id and t.location_id = v_pf), 0));
    begin
      perform issue_production_order(r.id, pg_temp.h_ts(d, 8.5) + make_interval(mins => v_k * 4));
      v_k := v_k + 1;
    exception when others then insert into _h_err values ('issue MO', sqlerrm);
    end;
  end loop;

  -- 5. Tue/Fri delivery run Fulfillment -> Campus (10:30) --------------------
  if v_dow in (2, 5) then
    select coalesce(jsonb_object_agg(x.k, x.q), '{}'::jsonb) into v_demloc
      from (select l.item_id::text || '|' || so.location_id::text as k, sum(l.qty - l.qty_fulfilled) as q
              from sales_orders so join sales_order_lines l on l.so_id = so.id
             where so.status = 'placed' group by 1) x;
    v_lines := '[]'::jsonb;
    for it in select i.id, i.product_family as fam from items i
               where i.item_type = 'finished' and i.is_active loop
      select * into v_rule from pg_temp.h_rule(
        case it.fam when 'Dragon' then 'DRG' when 'Fidget Spinner' then 'SPN' when 'Keychain' then 'KEY'
                    when 'Christmas Ornament' then 'ORN' else 'MTO' end, d);
      v_need := v_rule.cp_target + coalesce((v_demloc ->> (it.id::text || '|' || v_cp::text))::numeric, 0)
              - coalesce((select sum(qty) from inventory_txn where item_id = it.id and location_id = v_cp), 0);
      v_avail := coalesce((select sum(qty) from inventory_txn where item_id = it.id and location_id = v_ff), 0)
               - coalesce((v_demloc ->> (it.id::text || '|' || v_ff::text))::numeric, 0);
      v_q := least(v_need, v_avail);
      if v_q > 0 then v_lines := v_lines || jsonb_build_array(jsonb_build_object('item_id', it.id, 'qty', v_q)); end if;
    end loop;
    if jsonb_array_length(v_lines) > 0 then
      begin
        perform transfer_inventory(v_ff, v_cp, v_lines, 'Delivery run to BYU campus', pg_temp.h_ts(d, 10.5));
      exception when others then insert into _h_err values ('transfer', sqlerrm);
      end;
    end if;
  end if;

  -- 6. Purchasing (weekdays 09:30): reorder components that run low --------
  if v_weekday then
    v_po := '{}'::jsonb;
    for it in select i.id, i.category, s.supplier_id, s.stock_per_purchase_unit as pack, sup.quoted_lead_days as lead, sup.name as sup
                from items i
                join item_suppliers s on s.item_id = i.id and s.is_preferred
                join suppliers sup on sup.id = s.supplier_id
               where i.item_type = 'purchased' and exists (select 1 from boms b where b.component_item_id = i.id) loop
      v_rate := coalesce(-(select sum(qty) from inventory_txn
                            where item_id = it.id and source_type = 'production_issue'
                              and txn_at >= pg_temp.h_ts(d - 28, 0) and txn_at < pg_temp.h_ts(d, 0)), 0)
                / least(28, greatest(d - v_start, 7));
      continue when v_rate <= 0;
      v_oh := coalesce((select sum(t.qty) from inventory_txn t join locations l on l.id = t.location_id
                         where t.item_id = it.id and l.is_sellable), 0);
      v_onorder := coalesce((select sum((pl.qty_ordered - pl.qty_received) * pl.stock_per_purchase_unit)
                               from purchase_order_lines pl join purchase_orders po on po.id = pl.po_id
                              where pl.item_id = it.id and po.status in ('sent', 'partial')), 0);
      v_alloc := coalesce((select sum(c.qty_required - c.qty_issued) from production_order_components c
                             join production_orders mo on mo.id = c.mo_id
                            where c.item_id = it.id and mo.status = 'planned'), 0);
      v_pos := v_oh + v_onorder - v_alloc;
      v_rop := v_rate * (it.lead + 5);
      v_upto := v_rate * (it.lead + 24);
      if v_pos < v_rop then
        v_q := greatest(1, ceil((v_upto - v_pos) / it.pack));
        v_po := jsonb_set(v_po, array[it.supplier_id::text],
                  coalesce(v_po -> it.supplier_id::text, '[]'::jsonb) || jsonb_build_array(
                    jsonb_build_object('item_id', it.id, 'qty', v_q) ||
                    case when it.sup = 'Hobby Lobby' and it.category = 'filament'
                         -- Hobby Lobby runs a 40%-off sale every third week.
                         then jsonb_build_object('unit_cost', case when extract(week from d)::int % 3 = 0 then 8.99 else 14.99 end)
                         else '{}'::jsonb end));
      end if;
    end loop;

    -- Packaging and the backup filament source are bought on a calendar.
    if v_dow = 1 then
      for r in select s.id, s.name from suppliers s where s.name in ('Uline', 'Vistaprint', 'Bambu Lab') loop
        select pg_temp.h_local(max(order_date)) into v_last from purchase_orders where supplier_id = r.id;
        v_last := coalesce(v_last, v_start - pg_temp.h_hash(r.name, 'first') % 20);
        continue when d - v_last < case r.name when 'Uline' then 28 when 'Vistaprint' then 35 else 42 end;
        v_lines := case r.name
          when 'Uline' then (select jsonb_agg(jsonb_build_object('item_id', i.id, 'qty', x.q))
                               from (values ('PKG-BOX-S', 40), ('PKG-BOX-M', 15), ('PKG-BOX-L', 5), ('PKG-TISSUE', 150)) as x(sku, q)
                               join items i on i.sku = x.sku)
          when 'Vistaprint' then (select jsonb_agg(jsonb_build_object('item_id', i.id, 'qty', 120)) from items i where i.sku = 'PKG-CARD')
          else (select jsonb_agg(jsonb_build_object('item_id', i.id, 'qty', 2)) from items i
                 where i.sku = 'FIL-PLA-' || (array['BLUE','WHITE','BLACK','RED'])[1 + pg_temp.h_hash(d::text, 'bambu') % 4])
        end;
        v_po := jsonb_set(v_po, array[r.id::text], coalesce(v_po -> r.id::text, '[]'::jsonb) || v_lines);
      end loop;
    end if;

    for r in select key, value from jsonb_each(v_po) loop
      begin
        perform create_purchase_order(jsonb_build_object('supplier_id', r.key, 'source', 'reorder',
                  'order_date', pg_temp.h_ts(d, 9.5), 'lines', r.value));
      exception when others then insert into _h_err values ('PO', sqlerrm);
      end;
    end loop;
  end if;

  -- 7. Customer orders through the day ---------------------------------------
  truncate _h_req;
  foreach v_seg in array array['student', 'gift_buyer', 'hobbyist', 'local_family'] loop
    select array_agg(id order by customer_no) into v_custs from customers where segment = v_seg and is_active;
    continue when v_custs is null;
    v_n := pg_temp.h_poisson(
             (case v_seg when 'student' then 2.2 when 'gift_buyer' then 1.0 when 'hobbyist' then 0.8 else 0.8 end)
             * pg_temp.h_season(v_seg, d) * v_trend * pg_temp.h_dow(d) * pg_temp.h_event(v_seg, d));
    for v_k in 1 .. v_n loop
      -- A few regulars order much more often than the rest.
      v_cust := v_custs[1 + floor(array_length(v_custs, 1) * power(random(), 1.6))::int];
      v_map := '{}'::jsonb;
      for v_j in 1 .. 1 + (random() < 0.3)::int + (random() < 0.08)::int loop
        v_fam := pg_temp.h_family(v_seg, d);
        v_sku := v_fam || '-' || pg_temp.h_color(v_fam, d);
        v_map := v_map || jsonb_build_object(v_sku, coalesce((v_map ->> v_sku)::int, 0) + pg_temp.h_qty(v_seg, v_fam));
      end loop;
      select jsonb_agg(jsonb_build_object('item_id', i.id, 'qty', e.value::int)) into v_lines
        from jsonb_each_text(v_map) e join items i on i.sku = e.key;
      insert into _h_req values (
        pg_temp.h_ts(d, 9 + random() * 12), v_cust, v_seg,
        case when v_seg = 'student' and random() < 0.65 then case when v_weekday then
                    case when random() < 0.5 then 'counter' else 'pickup' end else 'ship' end
             when v_seg in ('local_family', 'hobbyist') and random() < 0.1 then 'pickup'
             else 'ship' end,
        v_lines, false);
    end loop;
  end loop;

  -- Businesses: bulk orders every 3-5 weeks, Net 30.
  for r in select c.id, c.name from customers c where c.segment = 'business' and c.is_active loop
    select pg_temp.h_local(max(order_date)) into v_last from sales_orders where customer_id = r.id;
    v_last := coalesce(v_last, v_start - pg_temp.h_hash(r.id::text, 'b0') % 25);
    continue when not v_weekday or d - v_last < 22 + pg_temp.h_hash(r.id::text || v_last::text, 'int') % 16;
    v_map := jsonb_build_object('KEY-BW', 30 + 5 * floor(random() * 7)::int);
    if random() < 0.5 then
      v_map := v_map || jsonb_build_object('SPN-' || pg_temp.h_color('SPN', d), 10 + floor(random() * 11)::int);
    end if;
    if random() < 0.4 then
      v_map := v_map || jsonb_build_object('DRG-' || pg_temp.h_color('DRG', d), 8 + floor(random() * 9)::int);
    end if;
    if v_orn and to_char(d, 'MM-DD') <= '12-10' then
      v_map := v_map || jsonb_build_object('ORN-' || pg_temp.h_color('ORN', d), 12 + 6 * floor(random() * 4)::int);
    end if;
    if r.name = 'Wasatch Tinkerers Guild' then
      v_map := jsonb_build_object('ARM-BLACK', 4 + floor(random() * 6)::int, 'ARM-' || pg_temp.h_color('ARM', d), 3 + floor(random() * 4)::int,
                                  'KEY-BW', 25);
    end if;
    select jsonb_agg(jsonb_build_object('item_id', i.id, 'qty', e.value::int)) into v_lines
      from jsonb_each_text(v_map) e join items i on i.sku = e.key;
    insert into _h_req values (pg_temp.h_ts(d, 9 + random() * 7), r.id, 'business', 'ship', v_lines, true);
  end loop;

  -- Walk-up counter sales at campus (weekdays): stocked items, no customer record.
  if v_weekday then
    v_n := pg_temp.h_poisson(1.4 * pg_temp.h_season('student', d) * v_trend * pg_temp.h_event('student', d));
    for v_k in 1 .. v_n loop
      v_map := '{}'::jsonb;
      for v_j in 1 .. 1 + (random() < 0.25)::int loop
        v_fam := pg_temp.h_pick(array['KEY','DRG','SPN','ORN'], array[45, 25, 20, case when v_orn then 30 else 0 end]::numeric[]);
        v_sku := v_fam || '-' || pg_temp.h_color(v_fam, d);
        v_map := v_map || jsonb_build_object(v_sku, coalesce((v_map ->> v_sku)::int, 0) + 1 + (v_fam = 'KEY' and random() < 0.3)::int);
      end loop;
      -- Keep only what is on the campus shelf right now.
      select jsonb_agg(jsonb_build_object('item_id', i.id, 'qty', e.value::int)) into v_lines
        from jsonb_each_text(v_map) e join items i on i.sku = e.key;
      insert into _h_req values (pg_temp.h_ts(d, 10 + random() * 7), null, 'walk_in', 'counter', v_lines, false);
    end loop;
  end if;

  for r in select * from _h_req order by at loop
    if r.seg = 'walk_in' then
      select jsonb_agg(x) into v_lines from jsonb_array_elements(r.lines) x
       where (x->>'qty')::numeric <= coalesce((select sum(t.qty) from inventory_txn t
                                                where t.item_id = (x->>'item_id')::uuid and t.location_id = v_cp), 0);
      continue when v_lines is null;
      begin
        perform pos_sale(jsonb_build_object('lines', v_lines, 'order_date', r.at,
                  'payment_method', case when random() < 0.35 then 'cash' else 'card' end)
                  || case when random() < 0.4 then jsonb_build_object('discount_type', 'byu') else '{}'::jsonb end);
      exception when others then insert into _h_err values ('walk-in', sqlerrm);
      end;
    else
      perform pg_temp.h_place(r.at, r.cust, r.seg, r.method, r.lines, r.biz);
    end if;
  end loop;

  -- 8. Returns and exchanges (11:00): about 3% of orders, 2-19 days after delivery
  for r in select so.id, so.fulfillment_method, so.fulfilled_at from sales_orders so
            where so.status in ('fulfilled', 'closed') and so.customer_id is not null
              and so.fulfilled_at >= pg_temp.h_ts(d - 20, 0) and so.fulfilled_at < pg_temp.h_ts(d - 1, 0)
              and not exists (select 1 from returns rt where rt.so_id = so.id) loop
    continue when pg_temp.h_hash(r.id::text, 'ret') >= 30
               or pg_temp.h_local(r.fulfilled_at) + 2 + pg_temp.h_hash(r.id::text, 'rday') % 18 <> d;
    select l.id, l.item_id, i.product_family, i.sku into v_line
      from sales_order_lines l join items i on i.id = l.item_id
     where l.so_id = r.id and l.qty_fulfilled - l.qty_returned >= 1
     order by l.line_no limit 1;
    continue when v_line.id is null;
    v_kind := case when pg_temp.h_hash(r.id::text, 'kind') < 450 then 'quality'
                   when pg_temp.h_hash(r.id::text, 'kind') < 750 then 'refund' else 'exchange' end;
    v_other := null;
    if v_kind = 'exchange' then
      select i.id into v_other from items i
       where i.product_family = v_line.product_family and i.id <> v_line.item_id and i.is_active
       order by random() limit 1;
      if v_other is null then v_kind := 'refund'; end if;
    end if;
    v_ret := jsonb_build_object('so_id', r.id, 'returned_at', pg_temp.h_ts(d, 11 + random()),
      'lines', jsonb_build_array(jsonb_build_object('so_line_id', v_line.id, 'qty', 1, 'reason_code',
        case v_kind when 'quality' then case when r.fulfillment_method = 'ship' and random() < 0.4 then 'RET_DAMAGED_SHIP' else 'RET_QUALITY_DEFECT' end
                    when 'exchange' then 'RET_WRONG_COLOR' else 'RET_CHANGED_MIND' end)));
    if v_kind = 'exchange' then
      v_ret := v_ret || jsonb_build_object('exchange_lines', jsonb_build_array(jsonb_build_object('item_id', v_other, 'qty', 1)),
                                           'notes', 'Customer wanted a different color');
    end if;
    begin
      perform process_return(v_ret);
    exception when others then insert into _h_err values ('return', sqlerrm);
    end;
  end loop;

  -- 9. Pay supplier bills a couple of days before they are due (K&J late) --
  if v_weekday then
    for r in select ap.receipt_id, ap.due_date, ap.supplier_name from v_ap_open ap where ap.balance > 0 loop
      continue when d < r.due_date + case when r.supplier_name = 'K&J Magnetics' then 4 else -2 end;
      begin
        perform record_supplier_payment(r.receipt_id, null, pg_temp.h_ts(d, 15), 'ACH');
      exception when others then insert into _h_err values ('pay', sqlerrm);
      end;
    end loop;
  end if;

  -- 10. Close received POs a few days later; short shipments close short ---
  for r in select po.id, po.status, s.name as sup from purchase_orders po join suppliers s on s.id = po.supplier_id
            where po.status in ('received', 'partial') loop
    continue when r.status = 'partial' and pg_temp.h_ship_mode(r.sup, r.id) <> 'short';
    select pg_temp.h_local(max(received_at)) into v_last from po_receipts where po_id = r.id;
    continue when v_last + 1 + pg_temp.h_hash(r.id::text, 'cls') % 3 > d or d > v_end - 4;
    begin
      perform close_purchase_order(r.id, pg_temp.h_ts(d, 16));
    exception when others then insert into _h_err values ('close PO', sqlerrm);
    end;
  end loop;

  -- 11. Ship / hand over every order that stock now covers (16:30) ----------
  for r in select so.id, so.location_id, so.fulfillment_method from sales_orders so
            where so.status = 'placed' and so.order_date <= pg_temp.h_ts(d, 16.5)
            order by so.order_date loop
    continue when r.fulfillment_method = 'pickup' and not v_weekday;
    continue when exists (
      select 1 from sales_order_lines l
       where l.so_id = r.id
         and l.qty - l.qty_fulfilled > coalesce((select sum(t.qty) from inventory_txn t
                                                  where t.item_id = l.item_id and t.location_id = r.location_id), 0));
    begin
      perform fulfill_sales_order(r.id, pg_temp.h_ts(d, 16.5) + make_interval(secs => (random() * 3000)::int));
    exception when others then insert into _h_err values ('fulfill', sqlerrm);
    end;
  end loop;

  -- 12. Prints finishing before 8pm --------------------------------------------
  perform pg_temp.h_complete(pg_temp.h_ts(d, 20));

  -- 13. Cycle counts (1st and 15th), damage (20th), QA Hold inspection (Mondays)
  if extract(day from d) in (1, 15) then
    for r in select t.item_id, t.location_id, sum(t.qty) as oh, i.uom
               from inventory_txn t join items i on i.id = t.item_id
              where t.location_id in (v_pf, v_ff, v_cp)
              group by t.item_id, t.location_id, i.uom
             having sum(t.qty) > 2
              order by random() limit 5 loop
      v_q := case when random() < 0.7 then 0
                  when random() < 0.8 then -(case when r.uom = 'g' then 5 + floor(random() * 35) else 1 end)
                  else (case when r.uom = 'g' then 5 else 1 end) end;
      continue when v_q = 0;
      begin
        perform count_inventory(r.item_id, r.location_id, greatest(0, r.oh + v_q), 'ADJ_CYCLE_COUNT', null, pg_temp.h_ts(d, 18));
      exception when others then insert into _h_err values ('count', sqlerrm);
      end;
    end loop;
  end if;
  if extract(day from d) = 20 then
    for r in select t.item_id from inventory_txn t join items i on i.id = t.item_id
              where t.location_id = v_ff and i.category = 'product'
              group by t.item_id having sum(t.qty) >= 1 order by random() limit 1 loop
      begin
        perform adjust_inventory(r.item_id, v_ff, -1, 'ADJ_DAMAGED', 'Dropped while packing', pg_temp.h_ts(d, 17));
      exception when others then insert into _h_err values ('damage', sqlerrm);
      end;
    end loop;
  end if;
  if v_dow = 1 and d < v_end - 10 then
    for r in select t.item_id, sum(t.qty) as q from inventory_txn t
              where t.location_id = v_qa group by t.item_id having sum(t.qty) > 0 loop
      begin
        if random() < 0.6 then
          perform adjust_inventory(r.item_id, v_qa, -r.q, 'ADJ_QA_SCRAP', 'Failed QA inspection', pg_temp.h_ts(d, 17));
        else
          perform transfer_inventory(v_qa, v_ff, jsonb_build_array(jsonb_build_object('item_id', r.item_id, 'qty', r.q)),
                                     'Passed QA inspection', pg_temp.h_ts(d, 17));
        end if;
      exception when others then insert into _h_err values ('QA', sqlerrm);
      end;
    end loop;
  end if;
end;
$$;

-- Complete every in-progress production order that finishes by p_until.
create or replace function pg_temp.h_complete(p_until timestamptz)
returns void language plpgsql set search_path = public, pg_temp as $$
declare
  r record;
  v_fin timestamptz;
  v_failed int;
  v_scrap int;
begin
  for r in select mo.id, mo.started_at, mo.plates, mo.qty_started, i.units_per_plate as upp,
                  i.print_minutes as pm, i.assembly_minutes as am, i.product_family as fam
             from production_orders mo join items i on i.id = mo.item_id
            where mo.status = 'in_progress'
            order by mo.started_at loop
    v_fin := pg_temp.h_finish(r.id, r.started_at, r.plates, r.pm, r.am);
    continue when v_fin > p_until;
    v_failed := 0;
    for k in 1 .. r.plates loop
      if random() < pg_temp.h_fail_p(r.fam, v_fin) then v_failed := v_failed + 1; end if;
    end loop;
    if r.upp = 1 then
      v_scrap := v_failed;
    else
      v_scrap := 0;
      for k in 1 .. v_failed loop v_scrap := v_scrap + 1 + floor(random() * 3)::int; end loop;
    end if;
    v_scrap := least(v_scrap, r.qty_started::int);
    begin
      perform complete_production_order(r.id, r.qty_started - v_scrap, v_scrap,
                case when v_scrap > 0 then pg_temp.h_fail_reason(r.fam, v_fin) end, v_fin);
    exception when others then insert into _h_err values ('complete MO', sqlerrm);
    end;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------
do $$
declare
  v_budget interval := make_interval(secs => coalesce(nullif(current_setting('pp.history_budget_seconds', true), '')::double precision, 45));
  v_t0 timestamptz := clock_timestamp();
  v_today date := (now() at time zone 'America/Denver')::date;
  v_start date;
  v_end date := (now() at time zone 'America/Denver')::date - 1;
  v_last date;
  d date;
  v_days int := 0;
  r record;
  v_pipe timestamptz := now() - interval '30 minutes';
  v_biz jsonb;
begin
  if not exists (select 1 from items where sku = 'DRG-RED') then
    raise exception 'Load seed/001_starter_data.sql first.';
  end if;
  if exists (select 1 from settings where key = 'history_complete' and value = 'true') then
    raise notice 'History already complete; nothing changed.';
    return;
  end if;

  -- ----------------------------------------------------------- 60 customers
  -- (the 5 from the starter data are skipped by name). Portal logins are
  -- created in Supabase Auth with the same email; see HANDOFF.md.
  insert into customers (name, contact_name, email, phone, city, state, segment, is_byu, terms_days, notes)
  select x.name, x.contact, x.email, '801-555-' || lpad((1100 + x.n)::text, 4, '0'), x.city, x.state, x.seg,
         x.seg = 'student', case when x.seg = 'business' then 30 else 0 end,
         case when x.portal then 'Has a customer-portal login.' end
    from (values
      ( 2, 'Madison Reeves',          null,             'madison.reeves@example.com',      'Provo',            'UT', 'student',      false),
      ( 3, 'Tyler Okafor',            null,             'tyler.okafor@example.com',        'Orem',             'UT', 'student',      false),
      ( 4, 'Hannah Lindqvist',        null,             'hannah.lindqvist@example.com',    'Provo',            'UT', 'student',      true),
      ( 5, 'Jacob Tuilagi',           null,             'jacob.tuilagi@example.com',       'Provo',            'UT', 'student',      false),
      ( 6, 'Abigail Navarro',         null,             'abigail.navarro@example.com',     'Orem',             'UT', 'student',      false),
      ( 7, 'Caleb Whitfield',         null,             'caleb.whitfield@example.com',     'Provo',            'UT', 'student',      false),
      ( 8, 'Emma Kawamoto',           null,             'emma.kawamoto@example.com',       'Provo',            'UT', 'student',      true),
      ( 9, 'Samuel Brightwater',      null,             'samuel.brightwater@example.com',  'Springville',      'UT', 'student',      false),
      (10, 'Olivia Marchetti',        null,             'olivia.marchetti@example.com',    'Provo',            'UT', 'student',      false),
      (11, 'Noah Delacroix',          null,             'noah.delacroix@example.com',      'Orem',             'UT', 'student',      false),
      (12, 'Grace Sorensen',          null,             'grace.sorensen@example.com',      'Provo',            'UT', 'student',      true),
      (13, 'Isaac Fonoti',            null,             'isaac.fonoti@example.com',        'Provo',            'UT', 'student',      false),
      (14, 'Lily Ashcroft',           null,             'lily.ashcroft@example.com',       'Lehi',             'UT', 'student',      false),
      (15, 'Daniel Park',             null,             'daniel.park@example.com',         'Provo',            'UT', 'student',      false),
      (16, 'Chloe Vandermeer',        null,             'chloe.vandermeer@example.com',    'Provo',            'UT', 'student',      false),
      (17, 'Mason Ellsworth',         null,             'mason.ellsworth@example.com',     'Orem',             'UT', 'student',      false),
      (18, 'Ava Thibodeaux',          null,             'ava.thibodeaux@example.com',      'Provo',            'UT', 'student',      false),
      (20, 'Mark Jensen',             null,             'mark.jensen@example.com',         'Sandy',            'UT', 'gift_buyer',   false),
      (21, 'Linda Castellanos',       null,             'linda.castellanos@example.com',   'Mesa',             'AZ', 'gift_buyer',   true),
      (22, 'Karen Whitaker',          null,             'karen.whitaker@example.com',      'Boise',            'ID', 'gift_buyer',   false),
      (23, 'Steven Albright',         null,             'steven.albright@example.com',     'Las Vegas',        'NV', 'gift_buyer',   false),
      (24, 'Rachel Nakamura',         null,             'rachel.nakamura@example.com',     'St. George',       'UT', 'gift_buyer',   false),
      (25, 'Paul Esposito',           null,             'paul.esposito@example.com',       'Sacramento',       'CA', 'gift_buyer',   false),
      (26, 'Julie Pemberton',         null,             'julie.pemberton@example.com',     'Logan',            'UT', 'gift_buyer',   false),
      (27, 'Brian Oyelaran',          null,             'brian.oyelaran@example.com',      'Denver',           'CO', 'gift_buyer',   false),
      (28, 'Megan Halvorsen',         null,             'megan.halvorsen@example.com',     'Draper',           'UT', 'gift_buyer',   false),
      (29, 'Thomas Brennan',          null,             'thomas.brennan@example.com',      'Idaho Falls',      'ID', 'gift_buyer',   false),
      (30, 'Susan Mortensen',         null,             'susan.mortensen@example.com',     'Ogden',            'UT', 'gift_buyer',   false),
      (31, 'Gregory Lam',             null,             'gregory.lam@example.com',         'Seattle',          'WA', 'gift_buyer',   false),
      (32, 'Diane Fairbanks',         null,             'diane.fairbanks@example.com',     'Gilbert',          'AZ', 'gift_buyer',   false),
      (33, 'Kevin Andersen',          null,             'kevin.andersen@example.com',      'Dallas',           'TX', 'gift_buyer',   false),
      (34, 'Natalie Crowther',        null,             'natalie.crowther@example.com',    'Tooele',           'UT', 'gift_buyer',   false),
      (36, 'Derek Stroud',            null,             'derek.stroud@example.com',        'Tooele',           'UT', 'hobbyist',     false),
      (37, 'Aaron Velasquez',         null,             'aaron.velasquez@example.com',     'Phoenix',          'AZ', 'hobbyist',     false),
      (38, 'Brandon Kowalski',        null,             'brandon.kowalski@example.com',    'Chicago',          'IL', 'hobbyist',     false),
      (39, 'Jared Pettersen',         null,             'jared.pettersen@example.com',     'Grantsville',      'UT', 'hobbyist',     false),
      (40, 'Victor Ramos',            null,             'victor.ramos@example.com',        'Reno',             'NV', 'hobbyist',     false),
      (41, 'Colton Hayes',            null,             'colton.hayes@example.com',        'Stansbury Park',   'UT', 'hobbyist',     false),
      (42, 'Wesley Chandler',         null,             'wesley.chandler@example.com',     'Portland',         'OR', 'hobbyist',     false),
      (43, 'Trevor Lindgren',         null,             'trevor.lindgren@example.com',     'American Fork',    'UT', 'hobbyist',     false),
      (44, 'Dustin Moreau',           null,             'dustin.moreau@example.com',       'Austin',           'TX', 'hobbyist',     false),
      (45, 'Kyle Fujimoto',           null,             'kyle.fujimoto@example.com',       'Layton',           'UT', 'hobbyist',     false),
      (46, 'Russell Ngata',           null,             'russell.ngata@example.com',       'Kearns',           'UT', 'hobbyist',     false),
      (48, 'Amanda Christiansen',     null,             'amanda.christiansen@example.com', 'Erda',             'UT', 'local_family', false),
      (49, 'Heather Larsen',          null,             'heather.larsen@example.com',      'Tooele',           'UT', 'local_family', false),
      (50, 'Michelle Barlow',         null,             'michelle.barlow@example.com',     'Herriman',         'UT', 'local_family', false),
      (51, 'Stephanie Gutierrez',     null,             'stephanie.gutierrez@example.com', 'Spanish Fork',     'UT', 'local_family', false),
      (52, 'Laura McAllister',        null,             'laura.mcallister@example.com',    'Kaysville',        'UT', 'local_family', false),
      (53, 'Nicole Haddad',           null,             'nicole.haddad@example.com',       'Eagle Mountain',   'UT', 'local_family', false),
      (54, 'Crystal Pulsipher',       null,             'crystal.pulsipher@example.com',   'Cedar City',       'UT', 'local_family', false),
      (55, 'Angela Whitmore',         null,             'angela.whitmore@example.com',     'Saratoga Springs', 'UT', 'local_family', false),
      (57, 'Lakeview Toy Chest',      'Ryan Castillo',  'ryan.castillo@example.com',       'Bountiful',        'UT', 'business',     false),
      (58, 'Wasatch Tinkerers Guild', 'Jordan Ellis',   'jordan.ellis@example.com',        'Salt Lake City',   'UT', 'business',     true),
      (59, 'Canyon View Boutique',    'Priya Raman',    'priya.raman@example.com',         'Heber City',       'UT', 'business',     false),
      (60, 'Provo Peak Party Supply', 'Ben Hartley',    'ben.hartley@example.com',         'Provo',            'UT', 'business',     true),
      (61, 'Demo Customer',           null,             'demo.customer@example.com',       'Provo',            'UT', 'student',      true)
    ) as x(n, name, contact, email, city, state, seg, portal)
   where not exists (select 1 from customers c where c.name = x.name);
  -- Spec portal logins among the starter customers.
  update customers set notes = 'Has a customer-portal login.'
   where name in ('Ethan Caldwell', 'Rebecca Holloway', 'Marcus Bellweather', 'Jennifer Olsen', 'Summit Ridge Gifts')
     and notes is null;
  update customers set notes = 'Demo customer-portal login for the class demo.' where name = 'Demo Customer';

  -- ------------------------------------------------------------- the days
  select value::date into v_start from settings where key = 'history_start_date';
  if v_start is null then
    v_start := greatest(v_today - 180,
                        (select pg_temp.h_local(max(txn_at)) from inventory_txn where source_type = 'opening') + 1);
    insert into settings (key, value, type, category, label, description)
    values ('history_start_date', v_start::text, 'text', 'history', 'History starts',
            'First day of the generated sales history (seed/002).');
  end if;
  select value::date into v_last from settings where key = 'history_generated_through';
  d := coalesce(v_last + 1, v_start);

  while d <= v_end loop
    exit when clock_timestamp() - v_t0 > v_budget;
    perform pg_temp.h_day(d, v_start, v_end);
    d := d + 1;
    v_days := v_days + 1;
  end loop;

  insert into settings (key, value, type, category, label, description)
  values ('history_generated_through', (d - 1)::text, 'text', 'history', 'History generated through',
          'Last day generated by seed/002.')
  on conflict (key) do update set value = excluded.value, updated_at = now();

  -- --------------------------------------- open orders for the next 4 weeks
  -- Confirmed orders that are not built yet, so MRP has real demand to plan.
  if d > v_end then
    for r in select * from (values
        ('Summit Ridge Gifts',      12, '{"ORN-RED": 24, "ORN-WHITE": 18, "ORN-BLUE": 12, "KEY-BW": 40}'::jsonb),
        ('Provo Peak Party Supply', 18, '{"KEY-BW": 150, "SPN-BLUE": 20, "SPN-BLACK": 10}'::jsonb),
        ('Wasatch Tinkerers Guild',  9, '{"ARM-BLACK": 8, "ARM-BLUE": 4}'::jsonb),
        ('Lakeview Toy Chest',      21, '{"MAG-RED": 10, "MAG-BLUE": 10, "DRG-BLUE": 10}'::jsonb),
        ('Rebecca Holloway',         6, '{"TMP-WHITE": 2, "TMP-BLUE": 1}'::jsonb),
        ('Megan Halvorsen',         10, '{"TMP-WHITE": 3, "AIR-MC": 1}'::jsonb),
        ('Brandon Kowalski',        13, '{"AIR-MC": 2}'::jsonb),
        ('Linda Castellanos',       16, '{"MAG-WHITE": 2, "TMP-RED": 1}'::jsonb)
      ) as x(cust, days, lines) loop
      select jsonb_agg(jsonb_build_object('item_id', i.id, 'qty', e.value::int)) into v_biz
        from jsonb_each_text(r.lines) e join items i on i.sku = e.key;
      begin
        perform create_sales_order(jsonb_build_object(
          'customer_id', (select id from customers where name = r.cust),
          'fulfillment_method', 'ship', 'need_date', v_today + r.days, 'order_date', v_pipe,
          'notes', 'Confirmed order, ships by the need date',
          'lines', v_biz)
          || case when (select segment from customers where name = r.cust) = 'business'
                       and (select sum(e.value::int) from jsonb_each_text(r.lines) e) >= 25
                  then '{"discount_type": "business"}'::jsonb else '{}'::jsonb end);
      exception when others then insert into _h_err values ('pipeline', sqlerrm);
      end;
      v_pipe := v_pipe + interval '1 minute';
    end loop;

    insert into settings (key, value, type, category, label, description)
    values ('history_complete', 'true', 'boolean', 'history', 'History complete',
            'seed/002 finished generating the 6-month history.')
    on conflict (key) do update set value = 'true', updated_at = now();
    perform link_customer_logins();
  end if;

  raise notice 'History: % day(s) generated this run in % s, through %; % call(s) skipped.',
    v_days, round(extract(epoch from clock_timestamp() - v_t0)::numeric, 1), d - 1, (select count(*) from _h_err);
  for r in select what, msg, count(*) as n from _h_err group by what, msg order by count(*) desc limit 5 loop
    raise notice 'Skipped % x % : %', r.n, r.what, r.msg;
  end loop;
end $$;

select case when exists (select 1 from settings where key = 'history_complete' and value = 'true')
            then 'HISTORY COMPLETE: ' || (select count(*) from customers) || ' customers, '
                 || (select count(*) from sales_orders) || ' sales orders, '
                 || (select count(*) from purchase_orders) || ' purchase orders, '
                 || (select count(*) from production_orders) || ' production orders'
            else 'HISTORY PARTLY GENERATED through ' || (select value from settings where key = 'history_generated_through')
                 || '. Run this file again to continue.' end as result;
