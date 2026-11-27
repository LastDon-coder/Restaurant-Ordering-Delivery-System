-- Tests for version 2, Phase 5d: payouts (who may record, direction and size limits, void, balances, history, no direct writes).
-- Run the WHOLE file; everything is rolled back and the error at the bottom is the report ("FAILURES: 0" = all good).
do $$
declare
  r text[] := '{}';
  ad uuid := gen_random_uuid(); oa uuid := gen_random_uuid(); ma uuid := gen_random_uuid(); sa uuid := gen_random_uuid();
  ob uuid := gen_random_uuid(); cu uuid := gen_random_uuid();
  ra bigint; rb bigint; o1 bigint; o2 bigint; o3 bigint; p1 bigint; p2 bigint; v jsonb; rw jsonb; n int;
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
  create function pg_temp.outstanding(p_rest bigint) returns numeric language sql as
    $f$ select (private.restaurant_balance(p_rest) ->> 'outstanding')::numeric $f$;

  insert into auth.users (id, email, aud, role, raw_user_meta_data)
  select t.u, 'x-' || left(t.u::text, 8) || '@notify-check.dev', 'authenticated', 'authenticated', json_build_object('first_name', t.nm, 'last_name', 'T')::jsonb
  from (values (ad,'Ann'),(oa,'OwnA'),(ma,'MgrA'),(sa,'StaffA'),(ob,'OwnB'),(cu,'Cy')) t(u, nm);
  update public.profiles set role = 'admin' where id = ad;
  update public.profiles set role = 'staff' where id in (oa, ma, sa, ob);
  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by) values ('Alpha Grill', 'po-alpha', 'active', 200, oa) returning id into ra;
  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by) values ('Beta Kitchen', 'po-beta', 'active', 500, ob) returning id into rb;
  insert into public.restaurant_members values (ra, oa, 'owner'), (ra, ma, 'manager'), (ra, sa, 'staff'), (rb, ob, 'owner');

  -- A (10%/10%): online 1000+200 paid -> platform owes 1080;  cash 500+100 delivered -> restaurant owes 60.  Balance 1020.
  o1 := pg_temp.mk(cu, ra, 1000, 200, 'online');
  update public.payments set payment_status = 'paid', paid_at = now(), transaction_reference = 'ORD-' || o1 || '-aaaaaaaaaaaaaaaa' where order_id = o1;
  o2 := pg_temp.mk(cu, ra, 500, 100, 'cash_on_delivery');
  update public.orders set order_status = 'confirmed' where id = o2;
  update public.orders set order_status = 'out_for_delivery' where id = o2;
  update public.orders set order_status = 'delivered' where id = o2;
  -- B: only a delivered cash order -> the restaurant owes the platform 60.
  o3 := pg_temp.mk(cu, rb, 500, 100, 'cash_on_delivery');
  update public.orders set order_status = 'confirmed' where id = o3;
  update public.orders set order_status = 'out_for_delivery' where id = o3;
  update public.orders set order_status = 'delivered' where id = o3;

  ---------- balances ----------
  perform pg_temp.as_user(ad);
  v := public.report_balances();
  select e into rw from jsonb_array_elements(v) e where (e ->> 'restaurant_id')::bigint = ra;
  r := r || pg_temp.m('admin sees A: balance 1020, nothing paid, outstanding 1020', (rw ->> 'ledger_balance')::numeric = 1020 and (rw ->> 'outstanding')::numeric = 1020 and (rw ->> 'paid_to_restaurant')::numeric = 0);
  select e into rw from jsonb_array_elements(v) e where (e ->> 'restaurant_id')::bigint = rb;
  r := r || pg_temp.m('admin sees B: the restaurant owes 60 (outstanding -60)', (rw ->> 'outstanding')::numeric = -60);
  perform pg_temp.as_user(oa);
  r := r || pg_temp.expect('an owner cannot see all balances', 'select public.report_balances()', '42501');
  r := r || pg_temp.m('owner A sees their own balance', (public.report_my_balance(ra) ->> 'outstanding')::numeric = 1020);
  r := r || pg_temp.expect('owner A cannot see B''s balance', format('select public.report_my_balance(%s)', rb), '42501');
  perform pg_temp.as_user(sa);
  r := r || pg_temp.expect('plain staff cannot see the balance', format('select public.report_my_balance(%s)', ra), '42501');

  ---------- only the admin records ----------
  perform pg_temp.as_user(oa);
  r := r || pg_temp.expect('an owner cannot record a payout', format('select public.admin_record_payout(%s, ''to_restaurant'', 100, ''bank_transfer'', ''X1'', null)', ra), '42501');
  perform pg_temp.as_user(ma);
  r := r || pg_temp.expect('a manager cannot record a payout', format('select public.admin_record_payout(%s, ''to_restaurant'', 100, ''bank_transfer'', ''X1'', null)', ra), '42501');
  perform pg_temp.as_user(cu);
  r := r || pg_temp.expect('a customer cannot record a payout', format('select public.admin_record_payout(%s, ''to_restaurant'', 100, ''bank_transfer'', ''X1'', null)', ra), '42501');
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('anonymous cannot record a payout', format('select public.admin_record_payout(%s, ''to_restaurant'', 100, ''bank_transfer'', ''X1'', null)', ra), '42501');

  ---------- admin: input checks ----------
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('bad direction', format('select public.admin_record_payout(%s, ''sideways'', 100, ''cash'', null, null)', ra), '22023');
  r := r || pg_temp.expect('zero amount', format('select public.admin_record_payout(%s, ''to_restaurant'', 0, ''cash'', null, null)', ra), '22023');
  r := r || pg_temp.expect('negative amount', format('select public.admin_record_payout(%s, ''to_restaurant'', -5, ''cash'', null, null)', ra), '22023');
  r := r || pg_temp.expect('three decimals', format('select public.admin_record_payout(%s, ''to_restaurant'', 10.005, ''cash'', null, null)', ra), '22023');
  r := r || pg_temp.expect('unknown method', format('select public.admin_record_payout(%s, ''to_restaurant'', 10, ''bitcoin'', null, null)', ra), '22023');
  r := r || pg_temp.expect('a bank transfer needs a reference', format('select public.admin_record_payout(%s, ''to_restaurant'', 10, ''bank_transfer'', ''  '', null)', ra), '22023');
  r := r || pg_temp.expect('unknown restaurant', 'select public.admin_record_payout(999999999, ''to_restaurant'', 10, ''cash'', null, null)', 'P0002');

  ---------- direction and size limits ----------
  r := r || pg_temp.expect('cannot pay the platform when the platform is the one owing', format('select public.admin_record_payout(%s, ''to_platform'', 10, ''cash'', null, null)', ra), '55000');
  r := r || pg_temp.expect('cannot pay the restaurant when the restaurant owes', format('select public.admin_record_payout(%s, ''to_restaurant'', 10, ''cash'', null, null)', rb), '55000');
  r := r || pg_temp.expect('cannot pay more than is owed (1020)', format('select public.admin_record_payout(%s, ''to_restaurant'', 1020.01, ''cash'', null, null)', ra), '55000');
  p1 := public.admin_record_payout(ra, 'to_restaurant', 400, 'bank_transfer', ' TRF-1 ', 'part payment');
  r := r || pg_temp.m('a part payment of 400 is recorded', p1 is not null);
  r := r || pg_temp.m('...outstanding falls to 620', pg_temp.outstanding(ra) = 620);
  r := r || pg_temp.expect('the same bank reference cannot be recorded twice', format('select public.admin_record_payout(%s, ''to_restaurant'', 10, ''bank_transfer'', ''TRF-1'', null)', ra), '23505');
  r := r || pg_temp.expect('now 700 is too much (620 left)', format('select public.admin_record_payout(%s, ''to_restaurant'', 700, ''cash'', null, null)', ra), '55000');
  p2 := public.admin_record_payout(ra, 'to_restaurant', 620, 'cash', null, null);
  r := r || pg_temp.m('paying the rest settles A to exactly 0', pg_temp.outstanding(ra) = 0);
  r := r || pg_temp.expect('nothing more can be paid to A', format('select public.admin_record_payout(%s, ''to_restaurant'', 1, ''cash'', null, null)', ra), '55000');

  ---------- restaurant owes the platform ----------
  r := r || pg_temp.expect('B pays more than it owes (60)', format('select public.admin_record_payout(%s, ''to_platform'', 61, ''cash'', null, null)', rb), '55000');
  r := r || pg_temp.expect('B pays the 60 it owes', format('select public.admin_record_payout(%s, ''to_platform'', 60, ''bank_transfer'', ''TRF-B1'', null)', rb), 'ok');
  r := r || pg_temp.m('...B is settled to 0', pg_temp.outstanding(rb) = 0);

  ---------- void ----------
  perform pg_temp.as_user(oa);
  r := r || pg_temp.expect('an owner cannot void a payout', format('select public.admin_void_payout(%s, ''oops'')', p2), '42501');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('voiding needs a reason', format('select public.admin_void_payout(%s, ''  '')', p2), '22023');
  r := r || pg_temp.expect('unknown payout', 'select public.admin_void_payout(999999999, ''x'')', 'P0002');
  r := r || pg_temp.expect('void the 620 payout', format('select public.admin_void_payout(%s, ''entered twice'')', p2), 'ok');
  r := r || pg_temp.m('...the balance goes back up to 620', pg_temp.outstanding(ra) = 620);
  r := r || pg_temp.expect('voiding twice is refused', format('select public.admin_void_payout(%s, ''again'')', p2), '55000');
  r := r || pg_temp.expect('a bank reference still in use by a live payout cannot be reused', format('select public.admin_record_payout(%s, ''to_restaurant'', 620, ''bank_transfer'', ''TRF-1'', ''redo'')', ra), '23505');

  ---------- history ----------
  perform pg_temp.as_user(oa);
  v := public.list_payouts(ra);
  r := r || pg_temp.m('owner A sees A''s payouts (2), newest first, the voided one marked', jsonb_array_length(v) = 2 and (v -> 0 ->> 'id')::bigint = p2 and v -> 0 ->> 'void_reason' = 'entered twice');
  r := r || pg_temp.expect('owner A cannot read B''s payouts', format('select public.list_payouts(%s)', rb), '42501');
  perform pg_temp.as_user(sa);
  r := r || pg_temp.expect('plain staff cannot read payouts', format('select public.list_payouts(%s)', ra), '42501');
  perform pg_temp.as_user(oa);
  r := r || pg_temp.m('owner A sees only A''s payout rows when reading the table', (select count(*) = 2 and bool_and(restaurant_id = ra) from public.payouts));

  ---------- nobody writes the table directly ----------
  r := r || pg_temp.expect('an owner cannot insert a payout row', format('insert into public.payouts (restaurant_id, direction, amount, method) values (%s, ''to_restaurant'', 1, ''cash'')', ra), '42501');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('even the admin cannot edit a payout row', format('update public.payouts set amount = 1 where id = %s', p1), '42501');
  r := r || pg_temp.expect('even the admin cannot delete a payout row', format('delete from public.payouts where id = %s', p1), '42501');

  perform pg_temp.as_su();
  select count(*) into n from unnest(r) x where x like 'FAIL%';
  raise exception E'TEST REPORT\nFAILURES: %\nTOTAL: %\n%', n, array_length(r, 1), array_to_string(r, E'\n');
end $$;
