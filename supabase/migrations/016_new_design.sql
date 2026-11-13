-- =============================================================================
-- 016_new_design.sql — New Design wizard (wow #8)
--
-- Turn print data for a new product into real items in one step: one item per
-- color (SKU CODE-COLOR, barcode PP-CODE-COLOR), each with a bill of material
-- (that color's filament + any components, per plate), production data,
-- size / packing data and a price. Costs use the same formula as
-- item_standard_cost, so the preview equals the rolled-up cost afterwards:
--   unit cost = (grams x filament cost/g + sum(component qty x cost)
--               + print hours x machine rate + (setup + cleanup + assembly)/60 x labor rate)
--               / units per plate
--   suggested price = ceil(unit cost x design markup) - 0.01
-- p = {name, code, colors[], grams_per_plate, print_minutes, units_per_plate?,
--      assembly_minutes?, components?: [{item_id, qty_per_plate}], length_in?, width_in?,
--      height_in?, packing_class?, box_size?, stocking_policy?, season_start?, season_end?,
--      lead_time_days?, price?, description?}
-- =============================================================================

insert into public.settings (key, value, type, category, label, description) values
  ('new_design_markup', '3', 'number', 'products', 'New design price markup (x cost)',
   'Suggested price = cost x markup, rounded up to .99.')
on conflict (key) do nothing;

create or replace function public._design_plan(p jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_name   text := left(trim(coalesce(p->>'name', '')), 40);
  v_code   text := upper(trim(coalesce(p->>'code', '')));
  v_grams  numeric;
  v_print  numeric;
  v_upp    int;
  v_asm    numeric := 0;
  v_policy text := coalesce(nullif(p->>'stocking_policy', ''), 'make_to_order');
  v_price  numeric;
  v_markup numeric := public.setting_num('new_design_markup');
  v_rm     numeric := public.machine_rate_per_hour();
  v_rl     numeric := public.setting_num('labor_rate');
  v_setup  numeric := public.setting_num('setup_minutes_per_plate') + public.setting_num('cleanup_minutes_per_plate');
  v_comp_cost numeric := 0;
  v_comps  jsonb := '[]'::jsonb;
  v_vars   jsonb := '[]'::jsonb;
  v_max    numeric := 0;
  v_color  text;
  v_fil    items%rowtype;
  c        jsonb;
  ci       items%rowtype;
  v_q      numeric;
  m_fil numeric; m_mach numeric; m_lab numeric; v_unit numeric;
  v_dim    text;
begin
  if v_name = '' then raise exception 'Give the product a name.'; end if;
  if exists (select 1 from items where product_family = v_name) then
    raise exception 'A product called "%" already exists.', v_name;
  end if;
  if v_code !~ '^[A-Z]{2,4}$' then raise exception 'The code must be 2 to 4 letters (it starts every SKU, e.g. RKT).'; end if;
  if exists (select 1 from items where sku like v_code || '-%') then
    raise exception 'Code % is already used by other items. Pick another.', v_code;
  end if;
  if jsonb_typeof(p->'colors') is distinct from 'array' or jsonb_array_length(p->'colors') = 0 then
    raise exception 'Choose at least one color.';
  end if;
  if coalesce(p->>'grams_per_plate', '') !~ '^\s*\d+(\.\d+)?\s*$' then raise exception 'Enter the filament grams per plate.'; end if;
  v_grams := (p->>'grams_per_plate')::numeric;
  if v_grams <= 0 or v_grams > 2000 then raise exception 'Filament must be more than 0 and at most 2,000 g per plate.'; end if;
  if coalesce(p->>'print_minutes', '') !~ '^\s*\d+(\.\d+)?\s*$' then raise exception 'Enter the print time per plate in minutes.'; end if;
  v_print := (p->>'print_minutes')::numeric;
  if v_print <= 0 or v_print > 2880 then raise exception 'Print time must be more than 0 and at most 2,880 minutes (48 h).'; end if;
  if coalesce(nullif(p->>'units_per_plate', ''), '1') !~ '^\s*\d+\s*$' then raise exception 'Units per plate must be a whole number.'; end if;
  v_upp := coalesce(nullif(p->>'units_per_plate', ''), '1')::int;
  if v_upp < 1 or v_upp > 100 then raise exception 'Units per plate must be from 1 to 100.'; end if;
  if coalesce(p->>'assembly_minutes', '') <> '' then
    if p->>'assembly_minutes' !~ '^\s*\d+(\.\d+)?\s*$' then raise exception 'Assembly time must be a number of minutes.'; end if;
    v_asm := (p->>'assembly_minutes')::numeric;
    if v_asm > 240 then raise exception 'Assembly must be at most 240 minutes per plate.'; end if;
  end if;
  if v_policy not in ('stock', 'make_to_order', 'seasonal') then raise exception 'Choose stocked, made to order or seasonal.'; end if;
  if v_policy = 'seasonal' and (coalesce(p->>'season_start', '') !~ '^\d{2}-\d{2}$' or coalesce(p->>'season_end', '') !~ '^\d{2}-\d{2}$') then
    raise exception 'A seasonal product needs a season start and end (MM-DD).';
  end if;
  foreach v_dim in array array['length_in', 'width_in', 'height_in'] loop
    if coalesce(p->>v_dim, '') <> '' and (p->>v_dim !~ '^\s*\d+(\.\d+)?\s*$' or (p->>v_dim)::numeric <= 0 or (p->>v_dim)::numeric > 48) then
      raise exception 'Sizes must be inches between 0 and 48.';
    end if;
  end loop;
  if coalesce(p->>'lead_time_days', '') <> '' and (p->>'lead_time_days' !~ '^\s*\d+\s*$' or (p->>'lead_time_days')::int > 60) then
    raise exception 'Lead time must be a whole number of days from 0 to 60.';
  end if;
  if coalesce(p->>'packing_class', '') <> '' and p->>'packing_class' not in ('small', 'standard', 'multi_piece', 'fragile') then
    raise exception 'Unknown packing class.';
  end if;
  if coalesce(p->>'box_size', '') <> '' and p->>'box_size' not in ('small', 'medium', 'large') then
    raise exception 'Unknown box size.';
  end if;

  -- Components (per plate), same for every color.
  if jsonb_typeof(p->'components') = 'array' then
    for c in select * from jsonb_array_elements(p->'components') loop
      if coalesce(c->>'item_id', '') !~ '^[0-9a-fA-F-]{36}$' then raise exception 'Choose each component from the list.'; end if;
      select * into ci from items where id = (c->>'item_id')::uuid and category = 'component' and is_active;
      if not found then raise exception 'Components must be active component items.'; end if;
      if coalesce(c->>'qty_per_plate', '') !~ '^\s*\d+(\.\d+)?\s*$' or (c->>'qty_per_plate')::numeric <= 0 then
        raise exception 'Enter a quantity per plate above zero for %.', ci.name;
      end if;
      if v_comps @> jsonb_build_array(jsonb_build_object('item_id', ci.id)) then
        raise exception '% is listed twice.', ci.name;
      end if;
      v_q := (c->>'qty_per_plate')::numeric;
      v_comp_cost := v_comp_cost + v_q * public.item_unit_cost(ci.id);
      v_comps := v_comps || jsonb_build_object('item_id', ci.id, 'name', ci.name, 'uom', ci.uom, 'qty_per_plate', v_q,
                                               'unit_cost', public.item_unit_cost(ci.id));
    end loop;
  end if;

  -- One variant per color, each with its own filament.
  for v_color in select distinct initcap(trim(x)) from jsonb_array_elements_text(p->'colors') x loop
    select * into v_fil from items where sku = 'FIL-PLA-' || upper(v_color) and category = 'filament' and is_active;
    if not found then raise exception 'Unknown filament color %. Use Red, White, Blue or Black.', v_color; end if;
    m_fil  := v_grams * public.item_unit_cost(v_fil.id);
    m_mach := v_print / 60.0 * v_rm;
    m_lab  := (v_setup + v_asm) / 60.0 * v_rl;
    v_unit := round((m_fil + v_comp_cost) / v_upp, 6) + round(m_mach / v_upp, 6) + round(m_lab / v_upp, 6);
    v_max  := greatest(v_max, v_unit);
    v_vars := v_vars || jsonb_build_object(
      'color', v_color, 'sku', v_code || '-' || upper(v_color), 'barcode', 'PP-' || v_code || '-' || upper(v_color),
      'name', v_name || ' - ' || v_color, 'filament_item_id', v_fil.id, 'filament_cost_per_g', public.item_unit_cost(v_fil.id),
      'material_cost', round((m_fil + v_comp_cost) / v_upp, 6), 'machine_cost', round(m_mach / v_upp, 6),
      'labor_cost', round(m_lab / v_upp, 6), 'unit_cost', v_unit);
  end loop;

  if coalesce(p->>'price', '') <> '' then
    if p->>'price' !~ '^\s*\d+(\.\d{1,2})?\s*$' or (p->>'price')::numeric <= 0 or (p->>'price')::numeric > 1000 then
      raise exception 'Price must be between $0.01 and $1,000.';
    end if;
    v_price := (p->>'price')::numeric;
  end if;

  return jsonb_build_object(
    'name', v_name, 'code', v_code, 'description', left(nullif(trim(p->>'description'), ''), 300),
    'grams_per_plate', v_grams, 'print_minutes', v_print, 'units_per_plate', v_upp, 'assembly_minutes', v_asm,
    'stocking_policy', v_policy, 'season_start', nullif(p->>'season_start', ''), 'season_end', nullif(p->>'season_end', ''),
    'lead_time_days', coalesce(nullif(p->>'lead_time_days', '')::int, case when v_policy = 'make_to_order' then 2 else 1 end),
    'length_in', nullif(p->>'length_in', '')::numeric, 'width_in', nullif(p->>'width_in', '')::numeric,
    'height_in', nullif(p->>'height_in', '')::numeric,
    'packing_class', coalesce(nullif(p->>'packing_class', ''), 'standard'), 'box_size', nullif(p->>'box_size', ''),
    'components', v_comps, 'component_cost_per_plate', round(v_comp_cost, 4), 'variants', v_vars,
    'inputs', jsonb_build_object('machine_rate_per_hour', round(v_rm, 4), 'labor_rate', v_rl,
              'setup_cleanup_minutes', v_setup, 'markup', v_markup),
    'suggested_price', ceil(v_max * v_markup) - 0.01,
    'price', coalesce(v_price, ceil(v_max * v_markup) - 0.01),
    'margin_pct', round((coalesce(v_price, ceil(v_max * v_markup) - 0.01) - v_max)
                        / nullif(coalesce(v_price, ceil(v_max * v_markup) - 0.01), 0), 4));
end;
$$;

create or replace function public.preview_product_design(p jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform public._require_staff();
  return public._design_plan(p);
end;
$$;

-- Creates the items + BOMs. Returns the new item ids (one per color).
create or replace function public.create_product_design(p jsonb)
returns uuid[]
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  d     jsonb;
  v     jsonb;
  c     jsonb;
  v_id  uuid;
  v_ids uuid[] := '{}';
begin
  perform public._require_staff();
  d := public._design_plan(p);
  for v in select * from jsonb_array_elements(d->'variants') loop
    insert into items (sku, barcode, name, description, item_type, category, product_family, color, uom, price,
                       stocking_policy, season_start, season_end, units_per_plate, print_minutes, assembly_minutes,
                       lead_time_days, packing_class, box_size, length_in, width_in, height_in)
    values (v->>'sku', v->>'barcode', v->>'name', d->>'description', 'finished', 'product', d->>'name', v->>'color', 'ea',
            (d->>'price')::numeric, d->>'stocking_policy', d->>'season_start', d->>'season_end',
            (d->>'units_per_plate')::int, (d->>'print_minutes')::numeric, (d->>'assembly_minutes')::numeric,
            (d->>'lead_time_days')::int, d->>'packing_class', d->>'box_size',
            (d->>'length_in')::numeric, (d->>'width_in')::numeric, (d->>'height_in')::numeric)
    returning id into v_id;
    insert into boms (parent_item_id, component_item_id, qty_per_plate)
    values (v_id, (v->>'filament_item_id')::uuid, (d->>'grams_per_plate')::numeric);
    for c in select * from jsonb_array_elements(d->'components') loop
      insert into boms (parent_item_id, component_item_id, qty_per_plate)
      values (v_id, (c->>'item_id')::uuid, (c->>'qty_per_plate')::numeric);
    end loop;
    v_ids := v_ids || v_id;
  end loop;
  perform public._log('item.design_created', 'item', v_ids[1],
    format('New product %s: %s color(s) at $%s', d->>'name', jsonb_array_length(d->'variants'),
           to_char((d->>'price')::numeric, 'FM999,990.00')),
    '/inventory/item/' || v_ids[1], now());
  return v_ids;
end;
$$;

revoke execute on function public._design_plan(jsonb) from public, anon, authenticated;
revoke execute on function public.preview_product_design(jsonb), public.create_product_design(jsonb) from public, anon;
grant execute on function public.preview_product_design(jsonb), public.create_product_design(jsonb) to authenticated;
