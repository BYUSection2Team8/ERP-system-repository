-- =============================================================================
-- 006_realtime.sql — push changes to every open screen (multi-user, cap. 12)
-- Supabase Realtime only sends rows the signed-in user may read (RLS applies).
-- Screens subscribe to these tables and refetch when something changes.
-- =============================================================================
do $$
declare t text;
begin
  foreach t in array array[
    'inventory_txn','ledger','sales_orders','sales_order_lines','returns',
    'production_orders','purchase_orders','purchase_order_lines','po_receipts',
    'activity_log','items','settings'
  ] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
