-- =============================================================================
-- promo_check.sql — promo codes + white-only Temples (023). ROLLED BACK.
-- Success = "PROMO CHECKS PASSED".
--   * only the white Temple is sellable
--   * a BYU student (10%) types "password" (11%) -> promo applies (best discount wins);
--     any capitalization / spaces; discount = round(subtotal x 0.11, 2); saved = quote
--   * a business order of 30 units (15%) with the code keeps the business discount
--   * an unknown or switched-off code is refused with a plain message
-- =============================================================================
begin;

do $$
begin
  assert (select count(*) from items where product_family = 'Temple LED Tealight' and is_active) = 1
     and (select color from items where product_family = 'Temple LED Tealight' and is_active) = 'White', 'Temples: white only';
  insert into customers (name, state, email, is_byu, segment) values ('Promo Student', 'UT', 'promo.student@example.com', true, 'student');
  insert into customers (name, state, email, segment, terms_days) values ('Promo Business', 'UT', 'promo.biz@example.com', 'business', 30);
end $$;
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000e7', 'promo.student@example.com'),
  ('00000000-0000-0000-0000-0000000000e8', 'promo.biz@example.com');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000e7","role":"authenticated"}', true);
do $$
declare
  drg uuid := (select item_id from portal_catalog() where product_family = 'Dragon' order by sku limit 1);
  cp uuid := (select location_id from portal_catalog() where location_code = 'CAMPUS' limit 1);
  p jsonb; q jsonb; so uuid; v_ok boolean := false;
begin
  p := jsonb_build_object('location_id', cp, 'lines', jsonb_build_array(jsonb_build_object('item_id', drg, 'qty', 2)));
  q := portal_quote_order(p);
  assert q->>'discount_type' = 'byu', 'BYU discount without a code';
  q := portal_quote_order(p || '{"promo_code": "  PassWord "}');
  assert q->>'discount_type' = 'promo' and (q->>'discount_pct')::numeric = 0.11 and q->>'promo_code' = 'PASSWORD'
     and (q->>'discount_amount')::numeric = round((q->>'subtotal')::numeric * 0.11, 2), format('promo applies: %s', q);
  begin perform portal_quote_order(p || '{"promo_code": "nope"}'); exception when others then v_ok := sqlerrm like '%not valid%'; end;
  assert v_ok, 'unknown code refused';
  so := portal_place_order(p || '{"promo_code": "password"}');
  assert (select discount_type || '/' || promo_code from sales_orders where id = so) = 'promo/PASSWORD', 'saved with the code';
  assert (select total from sales_orders where id = so) = (q->>'total')::numeric, 'saved total = quote';
end $$;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000e8","role":"authenticated"}', true);
do $$
declare
  key uuid := (select item_id from portal_catalog() where sku = 'KEY-BW' limit 1);
  cp uuid := (select location_id from portal_catalog() where location_code = 'CAMPUS' limit 1);
  q jsonb;
begin
  q := portal_quote_order(jsonb_build_object('location_id', cp, 'promo_code', 'password',
         'lines', jsonb_build_array(jsonb_build_object('item_id', key, 'qty', 30))));
  assert q->>'discount_type' = 'business' and q->>'promo_code' is null, format('business 15%% beats the 11%% code: %s', q->>'discount_type');
end $$;
reset role;

do $$
declare v_ok boolean := false;
begin
  update promo_codes set is_active = false where code = 'PASSWORD';
  begin perform _promo_pct('password'); exception when others then v_ok := sqlerrm like '%not valid%'; end;
  assert v_ok, 'switched-off code refused';
end $$;

do $$ begin raise notice 'PROMO CHECKS PASSED'; end $$;
rollback;
