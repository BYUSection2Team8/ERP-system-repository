-- =============================================================================
-- 009_customer_logins.sql — link customer-portal logins to customer records (Phase 6)
--
-- A portal login is a Supabase Auth user whose email matches a customer's email.
-- New sign-ups are still always role 'customer' (002_security.sql); this only
-- fills profiles.customer_id so the portal (Phase 9) knows whose orders to show.
-- Staff create portal logins in Supabase -> Authentication -> Users (see HANDOFF.md).
-- =============================================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, role, full_name, customer_id)
  values (new.id, 'customer',
          coalesce(new.raw_user_meta_data ->> 'full_name', new.email),
          (select c.id from public.customers c
            where new.email is not null and lower(c.email) = lower(new.email)
            order by c.created_at limit 1))
  on conflict (id) do nothing;
  return new;
end;
$$;

-- Link any customer logins that exist already (safe to run again).
-- Returns how many logins were linked.
create or replace function public.link_customer_logins()
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_n int;
begin
  perform public._require_staff();
  with m as (
    select p.id as profile_id,
           (select c.id from customers c where lower(c.email) = lower(u.email) order by c.created_at limit 1) as customer_id
      from profiles p
      join auth.users u on u.id = p.id
     where p.role = 'customer' and p.customer_id is null and u.email is not null
  )
  update profiles p set customer_id = m.customer_id
    from m where m.profile_id = p.id and m.customer_id is not null;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke execute on function public.link_customer_logins() from public, anon;
grant execute on function public.link_customer_logins() to authenticated;
