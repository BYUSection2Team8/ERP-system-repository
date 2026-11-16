-- =============================================================================
-- 022_accounts.sql — create accounts from the app
--
--   * register_customer(name, state, phone): a signed-in customer login without a
--     customer record links to the customer with the same email (if no other login
--     has it) or gets a new customer record, so it can order in the portal.
--   * list_users(): staff see every login with its role and linked customer.
--   * set_user_role(user, role): staff promote / demote logins (never themselves).
--   * setup_customer_account(user, name, state, phone): staff link / create the
--     customer record for a login they just created.
-- New logins are still ALWAYS created as customers (002 / 009 trigger); only
-- staff can make someone staff. Logins themselves are created by Supabase Auth
-- (sign-up from the browser), never by these functions.
-- =============================================================================

-- Link a login to the customer with its email, or create one. Returns the customer id.
create or replace function public._link_or_create_customer(p_user uuid, p_name text, p_state text, p_phone text)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_email text;
  v_name  text := left(nullif(trim(p_name), ''), 80);
  v_state text := upper(nullif(trim(p_state), ''));
  v_cust  uuid;
begin
  select customer_id into v_cust from profiles where id = p_user;
  if v_cust is not null then return v_cust; end if;
  select email into v_email from auth.users where id = p_user;
  if v_email is null then raise exception 'Unknown login.'; end if;
  if v_state is not null and v_state !~ '^[A-Z]{2}$' then raise exception 'Enter the 2-letter state (e.g. UT).'; end if;

  select c.id into v_cust from customers c
   where lower(c.email) = lower(v_email) and c.is_active
     and not exists (select 1 from profiles p where p.customer_id = c.id)
   order by c.created_at limit 1;
  if v_cust is null then
    if v_name is null then raise exception 'Enter your name.'; end if;
    insert into customers (name, email, phone, state, notes)
    values (v_name, lower(v_email), left(nullif(trim(p_phone), ''), 30), coalesce(v_state, 'UT'), 'Created at sign-up')
    returning id into v_cust;
  end if;
  update profiles set customer_id = v_cust, full_name = coalesce(v_name, full_name) where id = p_user;
  perform public._log('account.customer_linked', 'customer', v_cust,
    format('Login %s linked to customer %s', v_email, (select name from customers where id = v_cust)), null, now());
  return v_cust;
end;
$$;

create or replace function public.register_customer(p_name text, p_state text default null, p_phone text default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.' using errcode = '42501'; end if;
  if (select role from profiles where id = auth.uid()) <> 'customer' then
    raise exception 'Staff logins do not need a customer account.';
  end if;
  return public._link_or_create_customer(auth.uid(), p_name, p_state, p_phone);
end;
$$;

create or replace function public.list_users()
returns table (user_id uuid, email text, role text, full_name text, customer_id uuid, customer_name text, created_at timestamptz)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform public._require_staff();
  return query
  select u.id, u.email::text, p.role, p.full_name, p.customer_id, c.name, p.created_at
    from auth.users u
    join profiles p on p.id = u.id
    left join customers c on c.id = p.customer_id
   order by (p.role = 'staff') desc, u.email;
end;
$$;

create or replace function public.set_user_role(p_user uuid, p_role text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_email text;
begin
  perform public._require_staff();
  if p_role not in ('staff', 'customer') then raise exception 'Role must be staff or customer.'; end if;
  if p_user = auth.uid() then raise exception 'You cannot change your own role.'; end if;
  select email into v_email from auth.users where id = p_user;
  if v_email is null then raise exception 'Unknown login.'; end if;
  update profiles set role = p_role where id = p_user;
  perform public._log('account.role', 'profile', p_user, format('%s is now %s', v_email, p_role), null, now());
end;
$$;

create or replace function public.setup_customer_account(p_user uuid, p_name text, p_state text default null, p_phone text default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform public._require_staff();
  return public._link_or_create_customer(p_user, p_name, p_state, p_phone);
end;
$$;

revoke execute on function public._link_or_create_customer(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.register_customer(text, text, text), public.list_users(), public.set_user_role(uuid, text),
  public.setup_customer_account(uuid, text, text, text) from public, anon;
grant execute on function public.register_customer(text, text, text), public.list_users(), public.set_user_role(uuid, text),
  public.setup_customer_account(uuid, text, text, text) to authenticated;
