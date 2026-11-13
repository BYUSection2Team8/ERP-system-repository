-- =============================================================================
-- 015_box_selection.sql — automatic box selection + packing slip (wow #6)
--
-- pack_order(so): packs the order's units, largest first, into the fewest and
-- smallest shipping boxes: an item fits a box when its sorted dimensions fit
-- the box's sorted inside dimensions (longest side vs longest side, ...) and the
-- box stays under the fill limit (80% of its volume by default). Returns the
-- boxes with their contents and the reason, packaging cost (boxes + tissue +
-- thank-you card at weighted-average cost) next to the flat packaging setting,
-- and packing minutes from the packing-time settings.
-- Read-only: it explains the packing; prices and postings are unchanged.
-- =============================================================================

insert into public.settings (key, value, type, category, label, description) values
  ('box_fill_limit',             '0.8', 'number', 'fulfillment', 'Box fill limit', 'Share of a box''s volume we fill before opening another box.'),
  ('tissue_sheets_per_box',      '2',   'number', 'fulfillment', 'Tissue sheets per box', null),
  ('packing_min_per_box',        '3',   'number', 'fulfillment', 'Packing time per box (min)', null),
  ('packing_min_small',          '0.5', 'number', 'fulfillment', 'Packing time per item: small (min)', null),
  ('packing_min_standard',       '1',   'number', 'fulfillment', 'Packing time per item: standard (min)', null),
  ('packing_min_multi_piece',    '1.5', 'number', 'fulfillment', 'Packing time per item: multi-piece (min)', null),
  ('packing_min_fragile',        '2',   'number', 'fulfillment', 'Packing time per item: fragile (min)', null),
  ('packing_pickup_saving_min',  '1',   'number', 'fulfillment', 'Pickup saving per box (min)', 'No shipping label for pickups.')
on conflict (key) do nothing;

create or replace function public.pack_order(p_so_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  so      sales_orders%rowtype;
  bt      record;
  u       record;
  t_sku   text[] := '{}';
  t_name  text[] := '{}';
  t_d1    numeric[] := '{}';
  t_d2    numeric[] := '{}';
  t_d3    numeric[] := '{}';
  t_vol   numeric[] := '{}';
  t_cost  numeric[] := '{}';
  b_type  int[] := '{}';
  b_used  numeric[] := '{}';
  b_items jsonb[] := '{}';
  k int; j int;
  placed  boolean;
  v_fill  numeric := public.setting_num('box_fill_limit');
  v_units int := 0;
  v_over  int := 0;
  v_item_min numeric := 0;
  v_boxes jsonb := '[]'::jsonb;
  v_box_cost numeric := 0;
  v_tissue numeric;
  v_card numeric;
  v_minutes numeric;
  v_left  numeric;
begin
  perform public._require_staff();
  select * into so from sales_orders where id = p_so_id;
  if not found then raise exception 'Unknown sales order.'; end if;
  if so.fulfillment_method = 'counter' then
    return jsonb_build_object('order_no', so.order_no, 'counter', true, 'boxes', '[]'::jsonb);
  end if;
  if (select coalesce(sum(qty), 0) from sales_order_lines where so_id = so.id) > 500 then
    raise exception 'Too many units to plan boxes automatically (over 500).';
  end if;

  -- Box types, smallest first, with inside dimensions sorted longest first.
  for bt in
    select i.sku, i.name,
           (select array_agg(x order by x desc) from unnest(array[i.length_in, i.width_in, i.height_in]) x) as d,
           i.length_in * i.width_in * i.height_in as vol, public.item_unit_cost(i.id) as cost
      from items i
     where i.category = 'packaging' and i.sku like 'PKG-BOX-%' and i.is_active
       and i.length_in is not null and i.width_in is not null and i.height_in is not null
     order by i.length_in * i.width_in * i.height_in
  loop
    t_sku := t_sku || bt.sku; t_name := t_name || bt.name;
    t_d1 := t_d1 || bt.d[1]; t_d2 := t_d2 || bt.d[2]; t_d3 := t_d3 || bt.d[3];
    t_vol := t_vol || bt.vol; t_cost := t_cost || bt.cost;
  end loop;
  if coalesce(array_length(t_sku, 1), 0) = 0 then raise exception 'No shipping boxes are set up (packaging items PKG-BOX-...).'; end if;

  select coalesce(sum(l.qty * coalesce(i.length_in, 1) * coalesce(i.width_in, 1) * coalesce(i.height_in, 1)), 0) into v_left
    from sales_order_lines l join items i on i.id = l.item_id where l.so_id = so.id;

  -- Units, largest volume first. Items without a size count as 1 x 1 x 1 in.
  for u in
    select i.name, coalesce(i.packing_class, 'standard') as pc,
           (select array_agg(x order by x desc)
              from unnest(array[coalesce(i.length_in, 1), coalesce(i.width_in, 1), coalesce(i.height_in, 1)]) x) as d,
           coalesce(i.length_in, 1) * coalesce(i.width_in, 1) * coalesce(i.height_in, 1) as vol
      from sales_order_lines l
      join items i on i.id = l.item_id
      cross join generate_series(1, ceil(l.qty)::int) g
     where l.so_id = so.id
     order by 4 desc, 1
  loop
    placed := false;
    for k in 1 .. coalesce(array_length(b_type, 1), 0) loop
      j := b_type[k];
      if u.d[1] <= t_d1[j] and u.d[2] <= t_d2[j] and u.d[3] <= t_d3[j] and b_used[k] + u.vol <= v_fill * t_vol[j] then
        b_used[k] := b_used[k] + u.vol;
        b_items[k] := b_items[k] || to_jsonb(u.name);
        placed := true;
        exit;
      end if;
    end loop;
    if not placed then
      -- Open the smallest box that fits this unit AND everything still to pack;
      -- if no box holds everything, the largest box that fits this unit.
      j := null;
      for k in 1 .. array_length(t_sku, 1) loop
        if u.d[1] <= t_d1[k] and u.d[2] <= t_d2[k] and u.d[3] <= t_d3[k] and v_left <= v_fill * t_vol[k] then
          j := k;
          exit;
        end if;
      end loop;
      if j is null then
        for k in reverse array_length(t_sku, 1) .. 1 loop
          if u.d[1] <= t_d1[k] and u.d[2] <= t_d2[k] and u.d[3] <= t_d3[k] and u.vol <= v_fill * t_vol[k] then
            j := k;
            exit;
          end if;
        end loop;
      end if;
      if j is null then
        j := array_length(t_sku, 1);   -- bigger than every box: largest box, flagged
        v_over := v_over + 1;
      end if;
      b_type := b_type || j;
      b_used := b_used || u.vol;
      b_items := b_items || jsonb_build_array(u.name);
    end if;
    v_left := v_left - u.vol;
    v_units := v_units + 1;
    v_item_min := v_item_min + case u.pc when 'small' then public.setting_num('packing_min_small')
                                         when 'multi_piece' then public.setting_num('packing_min_multi_piece')
                                         when 'fragile' then public.setting_num('packing_min_fragile')
                                         else public.setting_num('packing_min_standard') end;
  end loop;

  for k in 1 .. coalesce(array_length(b_type, 1), 0) loop
    j := b_type[k];
    v_box_cost := v_box_cost + t_cost[j];
    v_boxes := v_boxes || jsonb_build_object(
      'box', t_name[j], 'sku', t_sku[j],
      'inside', trim_scale(t_d1[j]) || ' x ' || trim_scale(t_d2[j]) || ' x ' || trim_scale(t_d3[j]) || ' in',
      'fill', round(b_used[k] / t_vol[j], 3), 'units', jsonb_array_length(b_items[k]), 'cost', round(t_cost[j], 4),
      'contents', (select jsonb_agg(jsonb_build_object('name', x.n, 'qty', x.c) order by x.c desc, x.n)
                     from (select e as n, count(*) as c from jsonb_array_elements_text(b_items[k]) e group by e) x));
  end loop;

  v_tissue := coalesce(array_length(b_type, 1), 0) * public.setting_num('tissue_sheets_per_box')
              * coalesce((select public.item_unit_cost(id) from items where sku = 'PKG-TISSUE'), 0);
  v_card := coalesce((select public.item_unit_cost(id) from items where sku = 'PKG-CARD'), 0);
  v_minutes := coalesce(array_length(b_type, 1), 0) * public.setting_num('packing_min_per_box') + v_item_min
               - case when so.fulfillment_method = 'pickup'
                      then coalesce(array_length(b_type, 1), 0) * public.setting_num('packing_pickup_saving_min') else 0 end;

  return jsonb_build_object(
    'order_no', so.order_no, 'counter', false, 'fulfillment_method', so.fulfillment_method,
    'units', v_units, 'boxes', v_boxes, 'box_count', coalesce(array_length(b_type, 1), 0), 'oversize_units', v_over,
    'fill_limit', v_fill,
    'box_cost', round(v_box_cost, 2), 'tissue_cost', round(v_tissue, 2), 'card_cost', round(v_card, 2),
    'packaging_cost', round(v_box_cost + v_tissue + v_card, 2),
    'flat_packaging_setting', public.setting_num('packaging_cost_per_order'),
    'packing_minutes', greatest(round(v_minutes, 1), 0),
    'packing_labor_cost', round(greatest(v_minutes, 0) / 60.0 * public.setting_num('labor_rate'), 2));
end;
$$;

revoke execute on function public.pack_order(uuid) from public, anon;
grant execute on function public.pack_order(uuid) to authenticated;
