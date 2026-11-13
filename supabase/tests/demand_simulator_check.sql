-- =============================================================================
-- demand_simulator_check.sql — demand simulator (wow #8). ROLLED BACK.
-- Success = "DEMAND SIMULATOR CHECKS PASSED".
--   * one normal day: orders created, all "Order placed", marked [Simulated demand];
--     reported units / value = the saved order lines / totals
--   * expected units scale with the event: Black Friday = 2.5 x normal, slow = 0.5 x
--   * bad input refused; customers cannot run it
-- =============================================================================
begin;

do $$
declare a jsonb; b jsonb; c jsonb; ids uuid[]; v_ok boolean;
begin
  a := simulate_demand(1, null, 0.42);
  select array_agg(x::uuid) into ids from jsonb_array_elements_text(a->'order_ids') x;
  assert (a->>'orders')::int > 0 and (a->>'expected_units')::numeric > 0, format('a normal day brings orders: %s', a - 'order_ids');
  assert (select bool_and(status = 'placed' and notes like '[Simulated demand]%') from sales_orders where id = any(ids)), 'placed and marked';
  assert (select sum(l.qty) from sales_order_lines l where l.so_id = any(ids)) = (a->>'units')::int, 'units = saved lines';
  assert (select sum(total) from sales_orders where id = any(ids)) = (a->>'value')::numeric, 'value = saved totals';
  assert (select count(*) from sales_orders where id = any(ids) and fulfillment_method = 'ship' and ship_state is null) = 0, 'shipped orders have a state';

  b := simulate_demand(1, 'black_friday', 0.42);
  c := simulate_demand(1, 'slow', 0.42);
  assert abs((b->>'expected_units')::numeric - 2.5 * (a->>'expected_units')::numeric) < 0.05,
    format('Black Friday expected %s vs normal %s', b->>'expected_units', a->>'expected_units');
  assert abs((c->>'expected_units')::numeric - 0.5 * (a->>'expected_units')::numeric) < 0.05, 'slow week = half';

  v_ok := false; begin perform simulate_demand(0); exception when others then v_ok := sqlerrm like '%1 to 7%'; end; assert v_ok, '0 days refused';
  v_ok := false; begin perform simulate_demand(8); exception when others then v_ok := sqlerrm like '%1 to 7%'; end; assert v_ok, '8 days refused';
  v_ok := false; begin perform simulate_demand(1, 'parade'); exception when others then v_ok := sqlerrm like '%Unknown event%'; end; assert v_ok, 'unknown event refused';
end $$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000b7', 'sim.customer@example.com');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b7","role":"authenticated"}', true);
do $$
declare v_ok boolean := false;
begin
  begin perform simulate_demand(1); exception when insufficient_privilege then v_ok := true; end;
  assert v_ok, 'customers cannot simulate demand';
end $$;
reset role;

do $$ begin raise notice 'DEMAND SIMULATOR CHECKS PASSED'; end $$;
rollback;
