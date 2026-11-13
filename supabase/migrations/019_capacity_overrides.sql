-- =============================================================================
-- 019_capacity_overrides.sql — rest of the capacity model (wow #7)
--
--   * capacity_check(location, lines): space a move would use at a location
--     (finished goods: L x W x H x qty / 1728 cu ft) -> projected utilization,
--     warning level, and a suggested fix (the sellable location with the most room)
--   * log_capacity_override(...): going over 100% is allowed (warn, never block)
--     but needs a manager reason code; who / when / why is recorded
--   * filament_rack_room(): spools the Print Farm rack can still take
--     (rack size - spools on hand - spools on open POs), used to cap EOQ
--     ("EOQ says 18 spools, the rack has room for 11")
-- =============================================================================

insert into public.reason_codes (code, category, description, is_quality, charges_restocking_fee, sort_order) values
  ('OVR_PEAK', 'override', 'Holiday / peak stock build-up', false, false, 20),
  ('OVR_TEMP', 'override', 'Temporary: moves out on the next delivery run', false, false, 30)
on conflict (code) do nothing;

create table if not exists public.capacity_overrides (
  id                     bigint generated always as identity primary key,
  location_id            uuid not null references public.locations(id),
  reason_code            text not null references public.reason_codes(code),
  note                   text,
  context                text,
  projected_utilization  numeric(8,4),
  user_id                uuid,
  actor                  text,
  at                     timestamptz not null default now()
);
alter table public.capacity_overrides enable row level security;
drop policy if exists staff_read on public.capacity_overrides;
create policy staff_read on public.capacity_overrides for select to authenticated using (public.is_staff());
revoke all on public.capacity_overrides from anon;

-- p_lines = [{item_id, qty}] being added at p_location.
create or replace function public.capacity_check(p_location uuid, p_lines jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  u       record;
  v_add   numeric := 0;
  v_proj  numeric;
  v_best  record;
begin
  perform public._require_staff();
  select * into u from v_location_utilization where location_id = p_location;
  if not found then raise exception 'Unknown location.'; end if;
  if jsonb_typeof(p_lines) = 'array' then
    select coalesce(sum(coalesce((x->>'qty')::numeric, 0) * coalesce(i.length_in * i.width_in * i.height_in, 0)), 0) / 1728.0
      into v_add
      from jsonb_array_elements(p_lines) x
      join items i on i.id = case when coalesce(x->>'item_id', '') ~ '^[0-9a-fA-F-]{36}$' then (x->>'item_id')::uuid end
     where i.category = 'product';
  end if;
  v_proj := case when u.capacity_cuft > 0 then (u.used_cuft + v_add) / u.capacity_cuft end;
  select l.name, l.capacity_cuft - l.used_cuft as free_cuft into v_best
    from v_location_utilization l join locations x on x.id = l.location_id
   where l.location_id <> p_location and x.is_sellable and l.capacity_cuft is not null
   order by l.capacity_cuft - l.used_cuft desc limit 1;
  return jsonb_build_object(
    'location', u.name, 'capacity_cuft', u.capacity_cuft, 'used_cuft', u.used_cuft,
    'adding_cuft', round(v_add, 2), 'projected_cuft', round(u.used_cuft + v_add, 2),
    'projected_utilization', round(v_proj, 4), 'warn_pct', u.warn_pct,
    'level', case when v_proj > 1 then 'over' when v_proj > u.warn_pct then 'warn' else 'ok' end,
    'suggestion', case when v_proj > u.warn_pct and v_best.name is not null
                       then format('%s has %s cu ft free: move some stock there, split the delivery, or pull production forward.',
                                   v_best.name, round(v_best.free_cuft, 1)) end);
end;
$$;

create or replace function public.log_capacity_override(p_location uuid, p_reason text, p_note text default null,
                                                       p_context text default null, p_projected numeric default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_name text;
begin
  perform public._require_staff();
  select name into v_name from locations where id = p_location;
  if not found then raise exception 'Unknown location.'; end if;
  if not exists (select 1 from reason_codes where code = p_reason and category = 'override' and is_active) then
    raise exception 'Going over capacity needs a manager reason code.';
  end if;
  insert into capacity_overrides (location_id, reason_code, note, context, projected_utilization, user_id, actor)
  values (p_location, p_reason, left(nullif(trim(p_note), ''), 300), left(p_context, 300), p_projected, auth.uid(), public._actor());
  perform public._log('capacity.override', 'location', p_location,
    format('Over capacity at %s (%s%%) approved: %s%s', v_name, round(coalesce(p_projected, 0) * 100),
           (select description from reason_codes where code = p_reason), coalesce(' — ' || nullif(trim(p_note), ''), '')),
    '/', now());
end;
$$;

-- Spools the filament rack can still take.
create or replace function public.filament_rack_room()
returns table (rack_spools numeric, spools_on_hand numeric, spools_on_order numeric, room numeric)
language sql stable security definer
set search_path = public, pg_temp
as $$
  with h as (
    select coalesce(sum(t.qty), 0) / public.setting_num('spool_grams') as n
      from inventory_txn t join items i on i.id = t.item_id where i.category = 'filament'
  ), o as (
    select coalesce(sum((l.qty_ordered - l.qty_received) * l.stock_per_purchase_unit), 0) / public.setting_num('spool_grams') as n
      from purchase_order_lines l join purchase_orders po on po.id = l.po_id join items i on i.id = l.item_id
     where i.category = 'filament' and po.status in ('sent', 'partial') and l.qty_received < l.qty_ordered
  )
  select public.setting_num('filament_rack_spools'), round(h.n, 1), round(o.n, 1),
         greatest(0, floor(public.setting_num('filament_rack_spools') - h.n - o.n))
    from h cross join o;
$$;

revoke execute on function public.capacity_check(uuid, jsonb), public.log_capacity_override(uuid, text, text, text, numeric),
  public.filament_rack_room() from public, anon;
grant execute on function public.capacity_check(uuid, jsonb), public.log_capacity_override(uuid, text, text, text, numeric),
  public.filament_rack_room() to authenticated;
