-- =============================================================================
-- reseed_check.sql — CI ONLY (it WIPES the business data, so it is never part
-- of Paste 2). Runs the website's "Reseed data through yesterday" the way the
-- Settings screen does: reseed_begin(), then reseed_step() until done.
-- Afterwards CI re-runs the seed, history and pattern checks on the new data.
-- Success = "RESEED CHECK PASSED".
-- =============================================================================
do $$
declare
  r jsonb;
  n int := 0;
  v_cust int;
begin
  -- Something made in the app that the reseed must remove.
  insert into items (sku, barcode, name, item_type, category, product_family, uom, price, is_custom)
  values ('CUST-9999', 'PP-CUST-9999', 'Custom: reseed test', 'finished', 'product', 'Custom', 'ea', 10, true);

  r := public.reseed_begin();
  assert (r->>'removed_items')::int >= 1, 'app-made items removed';
  assert not exists (select 1 from items where sku = 'CUST-9999'), 'custom item gone';
  assert (select count(*) from sales_orders) = 0, 'orders wiped';
  assert (select count(*) from ledger) > 0, 'opening stock posted again';
  assert (select count(*) from inventory_txn where source_type <> 'opening') = 0, 'only opening stock before the history runs';
  v_cust := (select count(*) from customers);
  assert v_cust = 61, format('60 customers + Demo Customer after reseed_begin (have %s)', v_cust);

  loop
    r := public.reseed_step();
    n := n + 1;
    exit when (r->>'done')::boolean;
    if n > 400 then raise exception 'reseed_step never finished: %', r; end if;
  end loop;

  assert (select value from settings where key = 'history_complete') = 'true', 'history complete after reseed';
  assert (select value::date from settings where key = 'history_generated_through')
         = (now() at time zone 'America/Denver')::date - 1, 'history runs through yesterday';
  assert (select min(substr(order_no, 4)::int) from sales_orders) = 10001, 'order numbers restart';
  raise notice 'Reseed: % step call(s), % orders, % production orders, % POs.',
    n, (select count(*) from sales_orders), (select count(*) from production_orders), (select count(*) from purchase_orders);
end $$;

select 'RESEED CHECK PASSED' as result;
