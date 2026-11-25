-- =============================================================================
-- 025_grants_for_new_projects.sql — signed-in users can reach the app's tables,
-- views and functions on a NEW Supabase project too.
--
-- Database 1 was created when Supabase still gave the API roles default
-- privileges on everything later created in schema public. Newer Supabase
-- projects no longer do, so on database 2 every table, view and function made
-- after 002_security.sql was unreachable ("permission denied for view
-- v_availability"). This restores exactly what database 1 has:
--   * signed-in users: table/view access (row-level security still narrows it),
--     sequences, and execute on functions;
--   * the internal helpers that migrations deliberately locked stay locked;
--   * anonymous visitors still get nothing except track_order (013).
-- Safe to run on any database, any number of times.
-- =============================================================================

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

-- Objects created later get the same (what database 1 had by default).
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public grant usage, select on sequences to authenticated;
alter default privileges in schema public grant execute on functions to authenticated;

-- Re-lock the internal helpers (the same revokes as the migrations that made them).
do $$
declare
  f text;
begin
  foreach f in array array[
    'public._require_staff()', 'public._actor()', 'public._log(text, text, uuid, text, text, timestamptz)',
    'public._location_id(text)', 'public._local_date(timestamptz)',
    'public._post_journal(text, uuid, timestamptz, text, jsonb)',
    'public._inv_move(uuid, uuid, numeric, numeric, text, uuid, uuid, text, timestamptz, text)',
    'public._price_sales_order(jsonb)',
    'public._insert_sales_order(jsonb)', 'public._portal_order_payload(jsonb)',
    'public._signal_stock_change()', 'public._in_season(text, text, text, date)',
    'public._order_tracking(uuid)',
    'public._assign_printer()', 'public._custom_quote(jsonb)', 'public._create_custom_order(jsonb, uuid, text)',
    'public._design_plan(jsonb)',
    'public._spool_create(uuid, numeric, timestamptz)', 'public._spool_take(uuid, numeric, bigint, uuid, text, timestamptz)',
    'public._spool_load(uuid, uuid, int, timestamptz)', 'public._spool_draw(uuid, numeric, uuid, bigint, uuid, text, timestamptz)',
    'public._spool_follow_txn()',
    'public._poisson(numeric)',
    'public._item_ship_weight_g(uuid)', 'public._zone_postage(text, numeric)',
    'public._link_or_create_customer(uuid, text, text, text)',
    'public._promo_pct(text)',
    'public._require_reseed_allowed()'
  ] loop
    if to_regprocedure(f) is not null then
      execute format('revoke execute on function %s from public, anon, authenticated', f);
    end if;
  end loop;
end $$;
