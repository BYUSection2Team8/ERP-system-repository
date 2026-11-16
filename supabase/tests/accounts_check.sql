-- =============================================================================
-- accounts_check.sql — create-account flows (022). ROLLED BACK.
-- Success = "ACCOUNTS CHECKS PASSED".
--   * a new login always starts as a customer
--   * register_customer: no matching customer -> new customer record, linked;
--     an existing customer with the same email -> linked to that one; calling again
--     returns the same customer
--   * customers cannot list users, change roles or set up other accounts
--   * staff can list users, promote / demote others, but not change their own role
-- =============================================================================
begin;

insert into customers (name, email, state) values ('Accounts Existing Customer', 'acct.existing@example.com', 'ID');
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'acct.new@example.com', '{"full_name": "New Person"}'),
  ('00000000-0000-0000-0000-0000000000a2', 'acct.existing@example.com', '{}'),
  ('00000000-0000-0000-0000-0000000000a3', 'acct.staff@example.com', '{}');

do $$
begin
  assert (select count(*) from profiles where id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2',
          '00000000-0000-0000-0000-0000000000a3') and role = 'customer') = 3, 'new logins start as customers';
  update profiles set role = 'staff' where id = '00000000-0000-0000-0000-0000000000a3';
end $$;

-- ------------------------------------------------- new customer signs up
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
do $$
declare c1 uuid; c2 uuid; v_ok boolean := false;
begin
  begin perform register_customer('', 'UT'); exception when others then v_ok := sqlerrm like '%name%'; end;
  assert v_ok, 'a name is required for a new customer';
  v_ok := false;
  begin perform register_customer('New Person', 'Utah'); exception when others then v_ok := sqlerrm like '%2-letter%'; end;
  assert v_ok, 'state must be 2 letters';
  c1 := register_customer('New Person', 'ut', '801-555-0100');
  assert (select name || '/' || state || '/' || email from customers where id = c1) = 'New Person/UT/acct.new@example.com', 'new customer record';
  assert (select customer_id from profiles where id = auth.uid()) = c1, 'login linked';
  c2 := register_customer('Someone Else', 'AZ');
  assert c2 = c1, 'calling again keeps the same customer';
  v_ok := false;
  begin perform list_users(); exception when insufficient_privilege then v_ok := true; end;
  assert v_ok, 'customers cannot list users';
  v_ok := false;
  begin perform set_user_role(auth.uid(), 'staff'); exception when insufficient_privilege then v_ok := true; end;
  assert v_ok, 'customers cannot make themselves staff';
  assert not is_staff(), 'still a customer';
end $$;

-- ------------------------------------------------- existing customer's email
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
do $$
declare c uuid;
begin
  c := register_customer(null, null);
  assert (select name from customers where id = c) = 'Accounts Existing Customer', 'linked to the existing customer with that email';
end $$;

-- ------------------------------------------------- staff
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
do $$
declare v_ok boolean := false; c uuid;
begin
  assert exists (select 1 from list_users() where email = 'acct.new@example.com' and role = 'customer' and customer_name = 'New Person'),
    'staff see logins with their customers';
  perform set_user_role('00000000-0000-0000-0000-0000000000a1', 'staff');
  assert (select role from profiles where id = '00000000-0000-0000-0000-0000000000a1') = 'staff', 'promoted';
  perform set_user_role('00000000-0000-0000-0000-0000000000a1', 'customer');
  assert (select role from profiles where id = '00000000-0000-0000-0000-0000000000a1') = 'customer', 'demoted';
  begin perform set_user_role(auth.uid(), 'customer'); exception when others then v_ok := sqlerrm like '%own role%'; end;
  assert v_ok, 'staff cannot change their own role';
  v_ok := false;
  begin perform set_user_role('00000000-0000-0000-0000-0000000000a1', 'admin'); exception when others then v_ok := sqlerrm like '%staff or customer%'; end;
  assert v_ok, 'only staff / customer roles';
end $$;
reset role;

do $$ begin raise notice 'ACCOUNTS CHECKS PASSED'; end $$;
rollback;
