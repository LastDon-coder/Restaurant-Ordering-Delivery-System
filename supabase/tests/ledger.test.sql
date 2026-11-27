-- Tests for version 2, Phase 5a: the money ledger (when rows are written, the split, snapshots, reversal, who can read,
-- who can set commission). Run the WHOLE file; everything is rolled back and the error at the bottom is the report
-- ("FAILURES: 0" = all good).
do $$
declare
  r text[] := '{}';
  ad uuid := gen_random_uuid(); oa uuid := gen_random_uuid(); ma uuid := gen_random_uuid(); sa uuid := gen_random_uuid();
  ob uuid := gen_random_uuid(); cu uuid := gen_random_uuid();
  ra bigint; rb bigint; o1 bigint; o2 bigint; o3 bigint; o4 bigint; o5 bigint; n int; l record;
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
  -- an order + its payment, created directly (as the superuser) so we can test the ledger on its own
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
  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by) values ('Alpha Grill', 'l-alpha', 'active', 200, oa) returning id into ra;
  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by) values ('Beta Kitchen', 'l-beta', 'active', 500, ob) returning id into rb;
  insert into public.restaurant_members values (ra, oa, 'owner'), (ra, ma, 'manager'), (ra, sa, 'staff'), (rb, ob, 'owner');

  ---------- commission setting: admin only ----------
  perform pg_temp.as_user(ma);
  r := r || pg_temp.expect('a manager cannot set commission', format('select public.admin_set_commission(%s, 10)', ra), '42501');
  perform pg_temp.as_user(oa);
  r := r || pg_temp.expect('an owner cannot set commission either', format('select public.admin_set_commission(%s, 10)', ra), '42501');
  perform pg_temp.as_user(cu);
  r := r || pg_temp.expect('a customer cannot set commission', format('select public.admin_set_commission(%s, 10)', ra), '42501');
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('anonymous cannot set commission', format('select public.admin_set_commission(%s, 10)', ra), '42501');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('admin: 101 is refused', format('select public.admin_set_commission(%s, 101)', ra), '22023');
  r := r || pg_temp.expect('admin: -1 is refused', format('select public.admin_set_commission(%s, -1)', ra), '22023');
  r := r || pg_temp.expect('admin: unknown restaurant', 'select public.admin_set_commission(999999999, 5)', 'P0002');
  r := r || pg_temp.expect('admin sets A to 10%', format('select public.admin_set_commission(%s, 10)', ra), 'ok');
  perform pg_temp.as_su();
  r := r || pg_temp.m('...saved on the restaurant', (select commission_percent = 10 from public.restaurants where id = ra));
  r := r || pg_temp.m('B still has the default 0%', (select commission_percent = 0 from public.restaurants where id = rb));

  ---------- online order: counts when paid ----------
  o1 := pg_temp.mk(cu, ra, 1000, 200, 'online');
  r := r || pg_temp.m('a pending online order is NOT in the ledger', not exists (select 1 from public.order_ledger where order_id = o1));
  update public.payments set payment_status = 'paid', paid_at = now(), transaction_reference = 'ORD-' || o1 || '-aaaaaaaaaaaaaaaa' where order_id = o1;
  select * into l from public.order_ledger where order_id = o1;
  r := r || pg_temp.m('paid online order is in the ledger', l.id is not null and l.status = 'earned');
  r := r || pg_temp.m('gross 1200 = food 1000 + fee 200', l.gross = 1200 and l.food_amount = 1000 and l.delivery_fee = 200);
  r := r || pg_temp.m('commission is 10% of the WHOLE total (120)', l.commission = 120 and l.commission_rate = 10);
  r := r || pg_temp.m('restaurant share = food - commission (880)', l.restaurant_share = 880);
  r := r || pg_temp.m('platform income = commission + delivery fee (320)', l.platform_income = 320);
  perform private.ledger_record(o1);
  r := r || pg_temp.m('recording again changes nothing (idempotent)', (select count(*) = 1 from public.order_ledger where order_id = o1));

  ---------- rate changes never rewrite history ----------
  perform pg_temp.as_user(ad);
  perform public.admin_set_commission(ra, 50);
  perform pg_temp.as_su();
  r := r || pg_temp.m('old row keeps its 10% snapshot after the rate changed to 50%', (select commission_rate = 10 and commission = 120 from public.order_ledger where order_id = o1));

  ---------- cash on delivery: counts when delivered ----------
  o2 := pg_temp.mk(cu, ra, 500, 100, 'cash_on_delivery');
  r := r || pg_temp.m('a cash order is not in the ledger when placed', not exists (select 1 from public.order_ledger where order_id = o2));
  update public.orders set order_status = 'confirmed' where id = o2;
  update public.orders set order_status = 'out_for_delivery' where id = o2;
  r := r || pg_temp.m('...nor while out for delivery', not exists (select 1 from public.order_ledger where order_id = o2));
  update public.orders set order_status = 'delivered' where id = o2;
  select * into l from public.order_ledger where order_id = o2;
  r := r || pg_temp.m('delivered cash order is in the ledger at the NEW rate (50%)', l.id is not null and l.commission_rate = 50 and l.commission = 300);
  r := r || pg_temp.m('...share 200 + commission 300 + fee 100 = gross 600', l.restaurant_share = 200 and l.gross = 600);

  o3 := pg_temp.mk(cu, ra, 400, 100, 'cash_on_delivery');
  update public.orders set order_status = 'cancelled' where id = o3;
  r := r || pg_temp.m('a cancelled cash order never enters the ledger', not exists (select 1 from public.order_ledger where order_id = o3));

  ---------- an online order that is delivered does not create a second row ----------
  update public.orders set order_status = 'confirmed' where id = o1;
  update public.orders set order_status = 'delivered' where id = o1;
  r := r || pg_temp.m('delivering a paid online order does not duplicate it', (select count(*) = 1 from public.order_ledger where order_id = o1));

  ---------- commission can never exceed the food amount ----------
  perform pg_temp.as_user(ad);
  perform public.admin_set_commission(rb, 100);
  perform pg_temp.as_su();
  o4 := pg_temp.mk(cu, rb, 100, 50, 'online');
  update public.payments set payment_status = 'paid', paid_at = now(), transaction_reference = 'ORD-' || o4 || '-bbbbbbbbbbbbbbbb' where order_id = o4;
  select * into l from public.order_ledger where order_id = o4;
  r := r || pg_temp.m('100% rate: commission capped at the food amount (100), restaurant gets 0', l.commission = 100 and l.restaurant_share = 0);
  r := r || pg_temp.m('...platform keeps 150 and the split still adds up', l.platform_income = 150 and l.gross = 150);

  ---------- refunds reverse ----------
  update public.payments set payment_status = 'refunded' where order_id = o1;
  select * into l from public.order_ledger where order_id = o1;
  r := r || pg_temp.m('a refunded online order is marked reversed with a time', l.status = 'reversed' and l.reversed_at is not null);

  ---------- who can read ----------
  perform pg_temp.as_user(oa);
  r := r || pg_temp.m('owner A sees only restaurant A rows (2)', (select count(*) = 2 and bool_and(restaurant_id = ra) from public.order_ledger));
  perform pg_temp.as_user(ma);
  r := r || pg_temp.m('manager A sees A rows too', (select count(*) = 2 from public.order_ledger));
  perform pg_temp.as_user(sa);
  r := r || pg_temp.m('plain staff sees no money', (select count(*) = 0 from public.order_ledger));
  perform pg_temp.as_user(ob);
  r := r || pg_temp.m('owner B sees only B (1 row)', (select count(*) = 1 and bool_and(restaurant_id = rb) from public.order_ledger));
  perform pg_temp.as_user(cu);
  r := r || pg_temp.m('a customer sees nothing', (select count(*) = 0 from public.order_ledger));
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('anonymous cannot read the ledger', 'select count(*) from public.order_ledger', '42501');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.m('admin sees all 3 test rows', (select count(*) >= 3 from public.order_ledger where order_id in (o1, o2, o4)));

  ---------- nobody can write it directly ----------
  perform pg_temp.as_user(oa);
  r := r || pg_temp.expect('an owner cannot insert a ledger row', format('insert into public.order_ledger (order_id, restaurant_id, payment_method, gross, food_amount, delivery_fee, commission_rate, commission, restaurant_share) values (%s, %s, ''online'', 1, 1, 0, 0, 0, 1)', o3, ra), '42501');
  r := r || pg_temp.expect('an owner cannot edit a ledger row', format('update public.order_ledger set restaurant_share = 999999 where order_id = %s', o1), '42501');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('not even the admin can delete a ledger row', format('delete from public.order_ledger where order_id = %s', o1), '42501');

  perform pg_temp.as_su();
  select count(*) into n from unnest(r) x where x like 'FAIL%';
  raise exception E'TEST REPORT\nFAILURES: %\nTOTAL: %\n%', n, array_length(r, 1), array_to_string(r, E'\n');
end $$;
