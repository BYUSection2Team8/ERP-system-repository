-- =============================================================================
-- 017_spools.sql — filament spool tracking (rest of wow #5)
--
-- Every physical spool has its own barcode (PP-SP-1001...) and grams left.
-- Spools follow the filament stock movements automatically (a trigger on
-- inventory_txn), so spool grams always add up to the filament on hand and
-- nothing is typed in:
--   * opening stock / PO receipts  -> new spools (whole 985 g spools + one partial)
--   * production issue             -> grams come off the spool of that color loaded on
--                                     the print's printer; when it runs out the next
--                                     spool in stock is loaded into that AMS slot
--   * other decreases / increases  -> taken from / added to spools in stock
--   * weigh_spool()                -> a cycle count aimed at one spool
-- Transfers between locations do not change spools (filament lives at the Print Farm).
-- load_spool / unload_spool move spools in and out of a printer's 4 AMS slots.
-- =============================================================================

insert into public.settings (key, value, type, category, label, description) values
  ('spool_low_grams', '100', 'number', 'filament', 'Near-empty spool warning (g)', 'Spools with less than this are flagged.')
on conflict (key) do nothing;

create sequence if not exists public.spool_no_seq start 1001;

create table if not exists public.spools (
  id            uuid primary key default gen_random_uuid(),
  spool_no      text not null unique,
  barcode       text not null unique,
  item_id       uuid not null references public.items(id),
  grams_initial numeric(10,2) not null check (grams_initial > 0),
  grams_left    numeric(10,2) not null check (grams_left >= 0),
  status        text not null default 'in_stock' check (status in ('in_stock', 'loaded', 'empty')),
  printer_id    uuid references public.printers(id),
  ams_slot      int check (ams_slot between 1 and 4),
  created_at    timestamptz not null default now(),
  loaded_at     timestamptz,
  emptied_at    timestamptz,
  check ((status = 'loaded') = (printer_id is not null and ams_slot is not null))
);
create unique index if not exists spools_slot_uq on public.spools (printer_id, ams_slot) where status = 'loaded';
create index if not exists spools_item_idx on public.spools (item_id, status);

create table if not exists public.spool_usage (
  id        bigint generated always as identity primary key,
  spool_id  uuid not null references public.spools(id),
  txn_id    bigint references public.inventory_txn(id),
  mo_id     uuid references public.production_orders(id),
  grams     numeric(10,2) not null,          -- + used, - added back
  kind      text not null check (kind in ('print', 'adjust', 'weigh')),
  at        timestamptz not null default now()
);
create index if not exists spool_usage_spool_idx on public.spool_usage (spool_id);

alter table public.spools enable row level security;
alter table public.spool_usage enable row level security;
drop policy if exists staff_read on public.spools;
drop policy if exists staff_read on public.spool_usage;
create policy staff_read on public.spools for select to authenticated using (public.is_staff());
create policy staff_read on public.spool_usage for select to authenticated using (public.is_staff());
revoke all on public.spools, public.spool_usage from anon;

-- New spool(s) for grams received: whole spools plus one partial.
create or replace function public._spool_create(p_item uuid, p_grams numeric, p_at timestamptz)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_size numeric := public.setting_num('spool_grams');
  v_left numeric := p_grams;
  v_g    numeric;
  v_no   bigint;
begin
  while v_left > 0.005 loop
    v_g := least(v_size, v_left);
    v_no := nextval('public.spool_no_seq');
    insert into spools (spool_no, barcode, item_id, grams_initial, grams_left, created_at)
    values ('SP-' || v_no, 'PP-SP-' || v_no, p_item, round(v_g, 2), round(v_g, 2), coalesce(p_at, now()));
    v_left := v_left - v_g;
  end loop;
end;
$$;

-- Take grams from one spool (empties it at zero, freeing its AMS slot).
create or replace function public._spool_take(p_spool uuid, p_grams numeric, p_txn bigint, p_mo uuid, p_kind text, p_at timestamptz)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  update spools
     set grams_left = greatest(grams_left - p_grams, 0),
         status     = case when grams_left - p_grams <= 0.005 then 'empty' else status end,
         printer_id = case when grams_left - p_grams <= 0.005 then null else printer_id end,
         ams_slot   = case when grams_left - p_grams <= 0.005 then null else ams_slot end,
         emptied_at = case when grams_left - p_grams <= 0.005 then coalesce(p_at, now()) else emptied_at end
   where id = p_spool;
  insert into spool_usage (spool_id, txn_id, mo_id, grams, kind, at)
  values (p_spool, p_txn, p_mo, round(p_grams, 2), p_kind, coalesce(p_at, now()));
end;
$$;

-- Put a spool into a printer's AMS slot (slot null = first free; if all 4 are
-- full, slot 4's spool goes back to stock).
create or replace function public._spool_load(p_spool uuid, p_printer uuid, p_slot int, p_at timestamptz)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_slot int := p_slot;
begin
  if v_slot is null then
    select s into v_slot from generate_series(1, 4) s
     where not exists (select 1 from spools x where x.printer_id = p_printer and x.ams_slot = s and x.status = 'loaded')
     order by s limit 1;
    v_slot := coalesce(v_slot, 4);
  end if;
  update spools set status = 'in_stock', printer_id = null, ams_slot = null
   where printer_id = p_printer and ams_slot = v_slot and status = 'loaded' and id <> p_spool;
  update spools set status = 'loaded', printer_id = p_printer, ams_slot = v_slot, loaded_at = coalesce(p_at, now())
   where id = p_spool;
  return v_slot;
end;
$$;

-- Draw grams of a filament for a print on a printer, or (printer null) from stock.
create or replace function public._spool_draw(p_item uuid, p_grams numeric, p_printer uuid, p_txn bigint, p_mo uuid,
                                              p_kind text, p_at timestamptz)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_need numeric := p_grams;
  v_sid  uuid;
  v_left numeric;
begin
  while v_need > 0.005 loop
    v_sid := null;
    if p_printer is not null then
      select id, grams_left into v_sid, v_left from spools
       where item_id = p_item and status = 'loaded' and printer_id = p_printer and grams_left > 0
       order by ams_slot limit 1 for update;
      if v_sid is null then
        -- Runs out / nothing loaded: load the next spool (partials first).
        select id, grams_left into v_sid, v_left from spools
         where item_id = p_item and status = 'in_stock' and grams_left > 0
         order by grams_left, spool_no limit 1 for update;
        if v_sid is not null then
          perform public._spool_load(v_sid, p_printer, null, p_at);
        end if;
      end if;
    end if;
    if v_sid is null then
      select id, grams_left into v_sid, v_left from spools
       where item_id = p_item and status <> 'empty' and grams_left > 0
       order by (status = 'in_stock') desc, grams_left, spool_no limit 1 for update;
    end if;
    exit when v_sid is null;   -- spools not set up for this filament: nothing to track
    perform public._spool_take(v_sid, least(v_need, v_left), p_txn, p_mo, p_kind, p_at);
    v_need := v_need - least(v_need, v_left);
  end loop;
end;
$$;

-- The trigger: keep spools in step with filament stock movements.
create or replace function public._spool_follow_txn()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_target  uuid := nullif(current_setting('pp.spool_target', true), '')::uuid;
  v_printer uuid;
  v_sid     uuid;
begin
  if not exists (select 1 from items where id = new.item_id and category = 'filament') then return null; end if;
  if new.source_type in ('transfer_out', 'transfer_in') then return null; end if;

  if v_target is not null then                       -- weigh_spool: aim at one spool
    if new.qty < 0 then
      perform public._spool_take(v_target, -new.qty, new.id, null, 'weigh', new.txn_at);
    else
      update spools set grams_left = grams_left + new.qty,
                        status = case when status = 'empty' then 'in_stock' else status end, emptied_at = null
       where id = v_target;
      insert into spool_usage (spool_id, txn_id, grams, kind, at) values (v_target, new.id, -new.qty, 'weigh', new.txn_at);
    end if;
  elsif new.qty > 0 then
    if new.source_type in ('opening', 'po_receipt') or new.qty >= 50 then
      perform public._spool_create(new.item_id, new.qty, new.txn_at);
    else                                             -- small gain: back onto the emptiest spool in stock
      select id into v_sid from spools where item_id = new.item_id and status = 'in_stock'
       order by grams_left limit 1;
      if v_sid is null then
        perform public._spool_create(new.item_id, new.qty, new.txn_at);
      else
        update spools set grams_left = grams_left + new.qty where id = v_sid;
        insert into spool_usage (spool_id, txn_id, grams, kind, at) values (v_sid, new.id, -new.qty, 'adjust', new.txn_at);
      end if;
    end if;
  elsif new.source_type = 'production_issue' then
    select printer_id into v_printer from production_orders where id = new.source_id;
    if v_printer is null and new.source_id is not null then
      -- Put the print on a printer now (same rule as at issue: least busy).
      select p.id into v_printer from printers p where p.is_active
       order by (select count(*) from production_orders mo where mo.printer_id = p.id and mo.status = 'in_progress'), p.sort_order
       limit 1;
      update production_orders set printer_id = v_printer where id = new.source_id;
    end if;
    perform public._spool_draw(new.item_id, -new.qty, v_printer, new.id, new.source_id, 'print', new.txn_at);
  else
    perform public._spool_draw(new.item_id, -new.qty, null, new.id, null, 'adjust', new.txn_at);
  end if;
  return null;
end;
$$;

drop trigger if exists inventory_txn_spools on public.inventory_txn;
create trigger inventory_txn_spools
  after insert on public.inventory_txn
  for each row execute function public._spool_follow_txn();

-- ---------------------------------------------------------------------------
-- Staff actions
-- ---------------------------------------------------------------------------
create or replace function public.load_spool(p_barcode text, p_printer uuid, p_slot int)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare s spools%rowtype; v_pname text;
begin
  perform public._require_staff();
  select * into s from spools where barcode = upper(trim(p_barcode)) or spool_no = upper(trim(p_barcode)) for update;
  if not found then raise exception 'No spool with barcode %.', p_barcode; end if;
  if s.status = 'empty' or s.grams_left <= 0 then raise exception '% is empty.', s.spool_no; end if;
  if p_slot is null or p_slot not between 1 and 4 then raise exception 'Choose AMS slot 1 to 4.'; end if;
  select name into v_pname from printers where id = p_printer and is_active;
  if not found then raise exception 'Choose an active printer.'; end if;
  update spools set status = 'in_stock', printer_id = null, ams_slot = null where id = s.id;
  perform public._spool_load(s.id, p_printer, p_slot, now());
  perform public._log('spool.loaded', 'spool', s.id,
    format('%s (%s, %s g) loaded into %s slot %s', s.spool_no, (select name from items where id = s.item_id),
           trim_scale(s.grams_left), v_pname, p_slot), '/production/spools', now());
end;
$$;

create or replace function public.unload_spool(p_barcode text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare s spools%rowtype;
begin
  perform public._require_staff();
  select * into s from spools where barcode = upper(trim(p_barcode)) or spool_no = upper(trim(p_barcode)) for update;
  if not found then raise exception 'No spool with barcode %.', p_barcode; end if;
  if s.status <> 'loaded' then raise exception '% is not loaded in a printer.', s.spool_no; end if;
  update spools set status = 'in_stock', printer_id = null, ams_slot = null where id = s.id;
  perform public._log('spool.unloaded', 'spool', s.id, s.spool_no || ' taken off the printer', '/production/spools', now());
end;
$$;

-- Weigh a spool: a cycle count of that filament aimed at this spool, so the
-- ledger, the item's stock and the spool all change together.
create or replace function public.weigh_spool(p_barcode text, p_grams numeric)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare s spools%rowtype;
begin
  perform public._require_staff();
  select * into s from spools where barcode = upper(trim(p_barcode)) or spool_no = upper(trim(p_barcode)) for update;
  if not found then raise exception 'No spool with barcode %.', p_barcode; end if;
  if p_grams is null or p_grams < 0 or p_grams > s.grams_initial + 50 then
    raise exception 'Enter the filament left on the spool, 0 to % g.', trim_scale(s.grams_initial);
  end if;
  if round(p_grams, 2) = s.grams_left then return; end if;
  perform set_config('pp.spool_target', s.id::text, true);
  perform public.adjust_inventory(s.item_id, public._location_id('PRINT_FARM'), round(p_grams, 2) - s.grams_left, 'ADJ_CYCLE_COUNT',
    format('Spool %s weighed: %s g (system %s g)', s.spool_no, trim_scale(round(p_grams, 2)), trim_scale(s.grams_left)), now());
  perform set_config('pp.spool_target', '', true);
end;
$$;

-- Spool grams vs filament on hand, per filament (should always agree).
create or replace view public.v_spool_reconciliation with (security_invoker = true) as
select i.id as item_id, i.sku, i.name,
       coalesce((select sum(t.qty) from public.inventory_txn t where t.item_id = i.id), 0) as grams_on_hand,
       coalesce((select sum(s.grams_left) from public.spools s where s.item_id = i.id), 0) as grams_on_spools,
       (select count(*) from public.spools s where s.item_id = i.id and s.status <> 'empty') as spools,
       (select count(*) from public.spools s where s.item_id = i.id and s.status <> 'empty'
          and s.grams_left < public.setting_num('spool_low_grams')) as near_empty
  from public.items i
 where i.category = 'filament' and i.is_active;

-- ---------------------------------------------------------------------------
-- Existing databases: create spools for the filament already on hand and load
-- one spool of each color into each printer. (A fresh database gets its spools
-- from the receipts in the seed instead.)
-- ---------------------------------------------------------------------------
do $$
declare r record; p record; v_slot int; v_sid uuid;
begin
  for r in select i.id, coalesce(sum(t.qty), 0) as grams from items i left join inventory_txn t on t.item_id = i.id
            where i.category = 'filament' group by i.id
           having not exists (select 1 from spools s where s.item_id = i.id) loop
    if r.grams > 0 then perform public._spool_create(r.id, r.grams, now()); end if;
  end loop;
  for p in select id from printers where is_active order by sort_order loop
    v_slot := 0;
    for r in select id from items where category = 'filament' and is_active and sku like 'FIL-PLA-%'
              order by case sku when 'FIL-PLA-RED' then 1 when 'FIL-PLA-WHITE' then 2 when 'FIL-PLA-BLUE' then 3 else 4 end limit 4 loop
      v_slot := v_slot + 1;
      continue when exists (select 1 from spools where printer_id = p.id and status = 'loaded' and item_id = r.id);
      select id into v_sid from spools where item_id = r.id and status = 'in_stock' and grams_left > 0
       order by grams_left, spool_no limit 1;
      if v_sid is not null and not exists (select 1 from spools where printer_id = p.id and ams_slot = v_slot and status = 'loaded') then
        perform public._spool_load(v_sid, p.id, v_slot, now());
      end if;
    end loop;
  end loop;
end $$;

revoke execute on function public._spool_create(uuid, numeric, timestamptz), public._spool_take(uuid, numeric, bigint, uuid, text, timestamptz),
  public._spool_load(uuid, uuid, int, timestamptz), public._spool_draw(uuid, numeric, uuid, bigint, uuid, text, timestamptz),
  public._spool_follow_txn() from public, anon, authenticated;
revoke execute on function public.load_spool(text, uuid, int), public.unload_spool(text), public.weigh_spool(text, numeric) from public, anon;
grant execute on function public.load_spool(text, uuid, int), public.unload_spool(text), public.weigh_spool(text, numeric) to authenticated;
grant select on public.v_spool_reconciliation to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'spools') then
    alter publication supabase_realtime add table public.spools;
  end if;
end $$;
