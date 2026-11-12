-- =============================================================================
-- 002_security.sql — roles, row-level security, grants
--
-- The repo is public and the browser holds the anon key, so the database itself
-- must enforce who can see and change what:
--   * anon (not signed in): nothing.
--   * staff: read everything; edit master data (items, suppliers, customers,
--     settings, BOMs, ...) directly; change transactions ONLY through the
--     business functions in 004_functions.sql.
--   * customer: read the product catalog, locations and their own orders.
--     Available stock comes from portal functions (Phase 9).
-- =============================================================================

-- Nobody but the owner creates objects in public.
revoke create on schema public from public;

-- ---------------------------------------------------------------------------
-- Who is calling?
-- ---------------------------------------------------------------------------

-- Role claim from the request's JWT: 'authenticated', 'anon', 'service_role',
-- or NULL for a direct database session (Supabase SQL Editor, migrations).
create or replace function public.jwt_role()
returns text
language sql stable
set search_path = ''
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
    nullif(current_setting('request.jwt.claim.role', true), '')
  );
$$;

create or replace function public.is_staff()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'staff'
  );
$$;

-- Staff via the app, or a trusted direct session (SQL Editor / service role).
create or replace function public.is_trusted()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select public.is_staff()
      or public.jwt_role() = 'service_role'
      or (public.jwt_role() is null and auth.uid() is null);
$$;

create or replace function public.my_customer_id()
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select p.customer_id from public.profiles p where p.id = auth.uid();
$$;

-- ---------------------------------------------------------------------------
-- Every new auth user gets a profile. New sign-ups are ALWAYS 'customer';
-- staff are promoted by SQL (see HANDOFF.md), never by sign-up metadata.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, role, full_name)
  values (new.id, 'customer', coalesce(new.raw_user_meta_data ->> 'full_name', new.email))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Users that exist right now (created in Phase 0) are staff.
insert into public.profiles (id, role, full_name)
select u.id, 'staff', u.email from auth.users u
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'settings','locations','reason_codes','accounts','suppliers','customers','profiles',
    'items','item_suppliers','boms','journals','ledger','inventory_txn',
    'sales_orders','sales_order_lines','returns','return_lines',
    'production_orders','production_order_components',
    'purchase_orders','purchase_order_lines','po_receipts','po_receipt_lines',
    'supplier_payments','activity_log'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    -- Staff can read every table.
    execute format(
      'create policy staff_read on public.%I for select to authenticated using (public.is_staff())', t);
  end loop;

  -- Master data: staff may insert/update/delete directly.
  foreach t in array array[
    'settings','locations','reason_codes','suppliers','customers',
    'items','item_suppliers','boms'
  ] loop
    execute format(
      'create policy staff_write on public.%I for all to authenticated using (public.is_staff()) with check (public.is_staff())', t);
  end loop;
  -- Transaction tables (ledger, inventory_txn, orders, ...) have NO write
  -- policies: they change only through SECURITY DEFINER business functions.
end $$;

-- Staff can change roles / link customers on profiles.
create policy staff_update on public.profiles
  for update to authenticated using (public.is_staff()) with check (public.is_staff());

-- Everyone signed in: own profile, reference lists, the sellable catalog.
create policy own_profile on public.profiles
  for select to authenticated using (id = auth.uid());
create policy signed_in_read on public.locations
  for select to authenticated using (is_active);
create policy signed_in_read on public.reason_codes
  for select to authenticated using (true);
create policy signed_in_read on public.settings
  for select to authenticated using (true);
create policy catalog_read on public.items
  for select to authenticated using (is_active and category = 'product');

-- Customers: their own record and orders.
create policy own_customer on public.customers
  for select to authenticated using (id = public.my_customer_id());
create policy own_orders on public.sales_orders
  for select to authenticated using (customer_id = public.my_customer_id());
create policy own_order_lines on public.sales_order_lines
  for select to authenticated using (
    exists (select 1 from public.sales_orders so
            where so.id = sales_order_lines.so_id and so.customer_id = public.my_customer_id()));
create policy own_returns on public.returns
  for select to authenticated using (customer_id = public.my_customer_id());

-- ---------------------------------------------------------------------------
-- Grants. Anonymous visitors get nothing. Signed-in users get table access
-- that RLS then narrows. Functions: execute is granted one by one in 004.
-- ---------------------------------------------------------------------------
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke execute on all functions in schema public from public, anon;
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.is_staff(), public.my_customer_id(), public.jwt_role(), public.is_trusted()
  to authenticated;

-- Objects created later by migrations: same defaults.
alter default privileges in schema public revoke all on tables    from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from public, anon;
