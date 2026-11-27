-- Tests for version 2, Phase 5b: the money reports (totals, by day, by restaurant, balance, who may ask, date checks).
-- Run the WHOLE file; everything is rolled back and the error at the bottom is the report ("FAILURES: 0" = all good).
do $$
declare
  r text[] := '{}';
  ad uuid := gen_random_uuid(); oa uuid := gen_random_uuid(); ma uuid := gen_random_uuid(); sa uuid := gen_random_uuid();
  ob uuid := gen_random_uuid(); cu uuid := gen_random_uuid();
  ra bigint; rb bigint; o1 bigint; o2 bigint; o3 bigint; o4 bigint; v jsonb; rw jsonb; n int;
  today date := (now() at time zone 'Africa/Lagos')::date;
begin
  create function pg_temp.m(p_name text, p_ok boolean) returns text language sql as
    $f$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name $f$;
  create function pg_temp.as_user(u uuid) returns void language plpgsql as
    $f$ begin perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
         execute 'reset role'; execute 'set local role authenticated'; end $f$;
  create function pg_temp.as_anon() returns void language plpgsql as
    $f$ begin perform set_config('request.jwt.claims', '', true); execute 'reset role'; execute 'set local role anon'; end $f$;
  create function pg_temp.as_su() returns void language plpgsql as $f$ begin execute 'reset role'; end $f$;
  create function pg_temp.expect(p_name text, p_sql text, p_state text) returns text language plpgsql as
    $f$ begin execute p_sql; return pg_temp.m(p_name || ' [expected ' || p_state || ', got ok]', p_state = 'ok');
        exception when others then return pg_temp.m(p_name || ' [expected ' || p_state || ', got ' || sqlstate || ']', sqlstate = p_state); end $f$;
  create function pg_temp.mk(p_user uuid, p_rest bigint, p_sub numeric, p_fee numeric, p_method public.payment_method) returns bigint
  language plpgsql as $f$
  declare a bigint; o bigint;
  begin
    insert into public.addresses (user_id, street_address, city, state) values (p_user, '1 Test St', 'Lagos', 'Lagos') returning id into a;
    insert into public.orders (user_id, restaurant_id, address_id, subtotal, delivery_fee, discount, total_amount,
                               delivery_street_address, delivery_city, delivery_state)
    values (p_user, p_rest, a, p_sub, p_fee, 0, p_sub + p_fee, '1 Test St', 'Lagos', 'Lagos') returning id into o;
    insert into public.payments (order_id, payment_method, amount) values (o, p_method, p_sub + p_fee);
    return o;
  end $f$;

  insert into auth.users (id, email, aud, role, raw_user_meta_data)
  select t.u, 'x-' || left(t.u::text, 8) || '@notify-check.dev', 'authenticated', 'authenticated', json_build_object('first_name', t.nm, 'last_name', 'T')::jsonb
  from (values (ad,'Ann'),(oa,'OwnA'),(ma,'MgrA'),(sa,'StaffA'),(ob,'OwnB'),(cu,'Cy')) t(u, nm);
  update public.profiles set role = 'admin' where id = ad;
  update public.profiles set role = 'staff' where id in (oa, ma, sa, ob);
  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by) values ('Alpha Grill', 'rp-alpha', 'active', 200, oa) returning id into ra;
  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by) values ('Beta Kitchen', 'rp-beta', 'active', 500, ob) returning id into rb;
  insert into public.restaurant_members values (ra, oa, 'owner'), (ra, ma, 'manager'), (ra, sa, 'staff'), (rb, ob, 'owner');

  -- A (10% / 10%): o1 online 1000+200 paid, o2 cash 500+100 delivered, o4 online 700+100 paid then refunded.  B: o3 online 300+100 paid.
  o1 := pg_temp.mk(cu, ra, 1000, 200, 'online');
  update public.payments set payment_status = 'paid', paid_at = now(), transaction_reference = 'ORD-' || o1 || '-aaaaaaaaaaaaaaaa' where order_id = o1;
  o2 := pg_temp.mk(cu, ra, 500, 100, 'cash_on_delivery');
  update public.orders set order_status = 'confirmed' where id = o2;
  update public.orders set order_status = 'out_for_delivery' where id = o2;
  update public.orders set order_status = 'delivered' where id = o2;
  o4 := pg_temp.mk(cu, ra, 700, 100, 'online');
  update public.payments set payment_status = 'paid', paid_at = now(), transaction_reference = 'ORD-' || o4 || '-cccccccccccccccc' where order_id = o4;
  update public.payments set payment_status = 'refunded' where order_id = o4;
  o3 := pg_temp.mk(cu, rb, 300, 100, 'online');
  update public.payments set payment_status = 'paid', paid_at = now(), transaction_reference = 'ORD-' || o3 || '-bbbbbbbbbbbbbbbb' where order_id = o3;

  ---------- summary for restaurant A ----------
  perform pg_temp.as_user(oa);
  v := public.report_summary(ra, today, today);
  r := r || pg_temp.m('owner A: 2 orders (the refunded one is left out)', (v ->> 'orders')::int = 2 and (v ->> 'online_orders')::int = 1 and (v ->> 'cash_orders')::int = 1);
  r := r || pg_temp.m('gross 1800 = food 1500 + delivery 300', (v ->> 'gross')::numeric = 1800 and (v ->> 'food_amount')::numeric = 1500 and (v ->> 'delivery_fee')::numeric = 300);
  r := r || pg_temp.m('commission 150 + delivery commission 30 = platform income 180', (v ->> 'commission')::numeric = 150 and (v ->> 'delivery_commission')::numeric = 30 and (v ->> 'platform_income')::numeric = 180);
  r := r || pg_temp.m('restaurant share 1620', (v ->> 'restaurant_share')::numeric = 1620);
  r := r || pg_temp.m('balance = online share 1080 - cash commission 60 = 1020 (platform owes restaurant)', (v ->> 'balance')::numeric = 1020);
  r := r || pg_temp.m('the refund is reported separately (1 order, 800)', (v ->> 'refunded_orders')::int = 1 and (v ->> 'refunded_gross')::numeric = 800);
  v := public.report_summary(ra, today + 1, today + 5);
  r := r || pg_temp.m('a period with no sales is zeros, not an error', (v ->> 'orders')::int = 0 and (v ->> 'gross')::numeric = 0 and (v ->> 'balance')::numeric = 0);

  ---------- by day ----------
  v := public.report_sales_by_day(ra, today - 3, today);
  r := r || pg_temp.m('by day: one row (today) with 2 orders and gross 1800', jsonb_array_length(v) = 1 and v -> 0 ->> 'day' = today::text and (v -> 0 ->> 'orders')::int = 2 and (v -> 0 ->> 'gross')::numeric = 1800);
  r := r || pg_temp.m('by day: an empty period is an empty list', jsonb_array_length(public.report_sales_by_day(ra, today + 1, today + 2)) = 0);

  ---------- who may ask ----------
  perform pg_temp.as_user(ma);
  r := r || pg_temp.expect('manager A can report on A', format('select public.report_summary(%s, %L, %L)', ra, today, today), 'ok');
  r := r || pg_temp.expect('manager A cannot report on B', format('select public.report_summary(%s, %L, %L)', rb, today, today), '42501');
  r := r || pg_temp.expect('a manager cannot ask for ALL restaurants (needs a restaurant)', format('select public.report_summary(null, %L, %L)', today, today), '22023');
  r := r || pg_temp.expect('a manager cannot compare restaurants', format('select public.report_by_restaurant(%L, %L)', today, today), '42501');
  perform pg_temp.as_user(sa);
  r := r || pg_temp.expect('plain staff cannot see sales', format('select public.report_summary(%s, %L, %L)', ra, today, today), '42501');
  r := r || pg_temp.expect('plain staff cannot see sales by day', format('select public.report_sales_by_day(%s, %L, %L)', ra, today, today), '42501');
  perform pg_temp.as_user(ob);
  r := r || pg_temp.expect('owner B cannot report on A', format('select public.report_sales_by_day(%s, %L, %L)', ra, today, today), '42501');
  perform pg_temp.as_user(cu);
  r := r || pg_temp.expect('a customer cannot see sales', format('select public.report_summary(%s, %L, %L)', ra, today, today), '42501');
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('anonymous cannot see sales', format('select public.report_summary(%s, %L, %L)', ra, today, today), '42501');

  ---------- admin ----------
  perform pg_temp.as_user(ad);
  v := public.report_summary(ra, today, today);
  r := r || pg_temp.m('admin sees A the same as its owner', (v ->> 'gross')::numeric = 1800);
  v := public.report_summary(null, today, today);
  r := r || pg_temp.m('admin: ALL restaurants includes at least the 3 test orders', (v ->> 'orders')::int >= 3);
  r := r || pg_temp.expect('admin: unknown restaurant', format('select public.report_summary(999999999, %L, %L)', today, today), 'P0002');
  v := public.report_by_restaurant(today, today);
  select e into rw from jsonb_array_elements(v) e where (e ->> 'restaurant_id')::bigint = ra;
  r := r || pg_temp.m('by restaurant: A has 2 orders, gross 1800, balance 1020', (rw ->> 'orders')::int = 2 and (rw ->> 'gross')::numeric = 1800 and (rw ->> 'balance')::numeric = 1020);
  r := r || pg_temp.m('by restaurant: A shows its rates (10 / 10)', (rw ->> 'commission_percent')::numeric = 10 and (rw ->> 'delivery_commission_percent')::numeric = 10);
  select e into rw from jsonb_array_elements(v) e where (e ->> 'restaurant_id')::bigint = rb;
  r := r || pg_temp.m('by restaurant: B has 1 order, gross 400, platform income 40, share 360', (rw ->> 'orders')::int = 1 and (rw ->> 'gross')::numeric = 400 and (rw ->> 'platform_income')::numeric = 40 and (rw ->> 'restaurant_share')::numeric = 360);
  r := r || pg_temp.m('by restaurant: B balance 360 (online, platform owes B)', (rw ->> 'balance')::numeric = 360);
  r := r || pg_temp.m('by restaurant: richest first', (select (v -> 0 ->> 'gross')::numeric >= (v -> 1 ->> 'gross')::numeric));

  ---------- date checks ----------
  r := r || pg_temp.expect('from after to is refused', format('select public.report_summary(%s, %L, %L)', ra, today, today - 1), '22023');
  r := r || pg_temp.expect('a missing date is refused', format('select public.report_summary(%s, null, %L)', ra, today), '22023');
  r := r || pg_temp.expect('more than 366 days is refused', format('select public.report_sales_by_day(%s, %L, %L)', ra, today - 400, today), '22023');
  r := r || pg_temp.expect('exactly 366 days is allowed', format('select public.report_sales_by_day(%s, %L, %L)', ra, today - 366, today), 'ok');

  perform pg_temp.as_su();
  select count(*) into n from unnest(r) x where x like 'FAIL%';
  raise exception E'TEST REPORT\nFAILURES: %\nTOTAL: %\n%', n, array_length(r, 1), array_to_string(r, E'\n');
end $$;
