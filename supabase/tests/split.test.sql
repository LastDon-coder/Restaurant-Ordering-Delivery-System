-- Tests for version 2, Phase 5e: Paystack split payments (connection, split terms, frozen rates, settlement on the ledger,
-- balances, fallbacks, access). Run the WHOLE file; everything is rolled back and the error at the bottom is the report
-- ("FAILURES: 0" = all good). The Paystack calls themselves are not tested here (that needs Paystack TEST mode).
do $$
declare
  r text[] := '{}';
  ad uuid := gen_random_uuid(); oa uuid := gen_random_uuid(); ob uuid := gen_random_uuid(); cu uuid := gen_random_uuid(); sa uuid := gen_random_uuid();
  ra bigint; rb bigint; o1 bigint; o2 bigint; o3 bigint; o4 bigint; o5 bigint; o6 bigint; o7 bigint;
  s jsonb; res jsonb; l record; n int; ref text;
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
  create function pg_temp.rates(p_rest bigint, p_food numeric, p_delivery numeric) returns void language plpgsql as
    $f$ begin update public.restaurants set commission_percent = p_food, delivery_commission_percent = p_delivery where id = p_rest; end $f$;

  insert into auth.users (id, email, aud, role, raw_user_meta_data)
  select t.u, 'x-' || left(t.u::text, 8) || '@notify-check.dev', 'authenticated', 'authenticated', json_build_object('first_name', t.nm, 'last_name', 'T')::jsonb
  from (values (ad,'Ann'),(oa,'OwnA'),(ob,'OwnB'),(cu,'Cy'),(sa,'StaffA')) t(u, nm);
  update public.profiles set role = 'admin' where id = ad;
  update public.profiles set role = 'staff' where id in (oa, ob, sa);
  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by) values ('Alpha Grill', 'sp-alpha', 'active', 200, oa) returning id into ra;
  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by) values ('Beta Kitchen', 'sp-beta', 'active', 500, ob) returning id into rb;
  insert into public.restaurant_members values (ra, oa, 'owner'), (ra, sa, 'staff'), (rb, ob, 'owner');

  ---------- connecting a bank account (server only) ----------
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('even an admin browser cannot save a settlement directly', format('select public.pay_save_settlement(%L, %s, ''ACCT_test12345'', ''Test Bank'', ''Alpha Ltd'', ''1234'')', ad, ra), '42501');
  perform pg_temp.as_su();
  r := r || pg_temp.expect('a non-admin id is refused', format('select public.pay_save_settlement(%L, %s, ''ACCT_test12345'', ''Test Bank'', ''Alpha Ltd'', ''1234'')', cu, ra), '42501');
  r := r || pg_temp.expect('an unknown restaurant', format('select public.pay_save_settlement(%L, 999999999, ''ACCT_test12345'', ''Test Bank'', ''Alpha Ltd'', ''1234'')', ad), 'P0002');
  r := r || pg_temp.expect('a malformed subaccount code is refused', format('select public.pay_save_settlement(%L, %s, ''not-a-code'', ''Test Bank'', ''Alpha Ltd'', ''1234'')', ad, ra), '23514');
  r := r || pg_temp.expect('the last-4 must be 4 digits (a full number is refused)', format('select public.pay_save_settlement(%L, %s, ''ACCT_test12345'', ''Test Bank'', ''Alpha Ltd'', ''0123456789'')', ad, ra), '23514');
  r := r || pg_temp.expect('admin connects Alpha', format('select public.pay_save_settlement(%L, %s, ''ACCT_test12345'', ''Test Bank'', ''Alpha Ltd'', ''1234'')', ad, ra), 'ok');

  ---------- who can see the connection ----------
  perform pg_temp.as_user(oa);
  s := public.get_settlement(ra);
  r := r || pg_temp.m('owner A sees bank, name and last 4 only', s ->> 'bank_name' = 'Test Bank' and s ->> 'account_last4' = '1234' and (s ? 'account_number') = false and (s ->> 'active')::boolean);
  r := r || pg_temp.expect('owner A cannot see B''s connection', format('select public.get_settlement(%s)', rb), '42501');
  r := r || pg_temp.expect('an owner cannot list all settlements', 'select public.admin_list_settlements()', '42501');
  r := r || pg_temp.expect('an owner cannot read the settlement table directly (only get_settlement)', 'select * from public.restaurant_settlement', '42501');
  r := r || pg_temp.expect('an owner cannot write the table', format('update public.restaurant_settlement set active = false where restaurant_id = %s', ra), '42501');
  perform pg_temp.as_user(sa);
  r := r || pg_temp.expect('plain staff cannot see the connection', format('select public.get_settlement(%s)', ra), '42501');
  perform pg_temp.as_user(ob);
  r := r || pg_temp.expect('owner B cannot read the settlement table either', 'select * from public.restaurant_settlement', '42501');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.m('admin: B has no connection (null)', public.get_settlement(rb) is null or public.get_settlement(rb) = 'null'::jsonb);
  r := r || pg_temp.m('admin list: Alpha connected, Beta not', (select bool_and(case when (e ->> 'restaurant_id')::bigint = ra then (e ->> 'connected')::boolean
                                                                                     when (e ->> 'restaurant_id')::bigint = rb then not (e ->> 'connected')::boolean else true end)
                                                               from jsonb_array_elements(public.admin_list_settlements()) e));
  perform pg_temp.as_su();

  ---------- the server-only payment functions are closed to browsers ----------
  perform pg_temp.as_user(cu);
  r := r || pg_temp.expect('a customer cannot call pay_start', 'select public.pay_start(gen_random_uuid(), 1)', '42501');
  r := r || pg_temp.expect('a customer cannot call pay_apply_charge', 'select public.pay_apply_charge(''ORD-1-aaaaaaaaaaaaaaaa'', 1, ''NGN'', true)', '42501');
  r := r || pg_temp.expect('a customer cannot call pay_clear_split', 'select public.pay_clear_split(''ORD-1-aaaaaaaaaaaaaaaa'')', '42501');
  perform pg_temp.as_su();

  ---------- a split payment: terms from the database ----------
  o1 := pg_temp.mk(cu, ra, 1000, 200, 'online');
  s := public.pay_start(cu, o1);
  r := r || pg_temp.m('Alpha order: split terms returned', s ->> 'subaccount' = 'ACCT_test12345');
  r := r || pg_temp.m('the platform keeps 120.00 = 12000 kobo of 120000', (s ->> 'platform_kobo')::bigint = 12000 and (s ->> 'amount_kobo')::bigint = 120000);

  -- the admin changes the rates AFTER the customer started paying: this payment must keep the rates it started with
  perform pg_temp.rates(ra, 50, 50);
  ref := s ->> 'reference';
  res := public.pay_apply_charge(ref, 120000, 'NGN', true);
  r := r || pg_temp.m('payment confirmed', res ->> 'result' = 'paid');
  r := r || pg_temp.m('the payment is marked split', (select settlement = 'split' from public.payments where order_id = o1));
  select * into l from public.order_ledger where order_id = o1;
  r := r || pg_temp.m('ledger: settlement split', l.settlement = 'split');
  r := r || pg_temp.m('ledger keeps the FROZEN 10% / 10% (100 + 20), not the new 50%', l.commission = 100 and l.delivery_commission = 20 and l.commission_rate = 10 and l.restaurant_share = 1080);
  perform pg_temp.rates(ra, 10, 10);
  r := r || pg_temp.m('a split order adds nothing to what the platform owes (outstanding 0)', pg_temp.outstanding(ra) = 0);
  perform pg_temp.as_user(ad);
  s := public.report_summary(ra, (now() at time zone 'Africa/Lagos')::date, (now() at time zone 'Africa/Lagos')::date);
  r := r || pg_temp.m('report: 1 split order, 1080 went straight to the restaurant, balance 0', (s ->> 'split_orders')::int = 1 and (s ->> 'split_share')::numeric = 1080 and (s ->> 'balance')::numeric = 0);
  perform pg_temp.as_su();
  res := public.pay_apply_charge(ref, 120000, 'NGN', true);
  r := r || pg_temp.m('confirming again is harmless', res ->> 'result' = 'already_paid' and (select count(*) = 1 from public.order_ledger where order_id = o1));

  ---------- a restaurant without a connection is unchanged ----------
  o2 := pg_temp.mk(cu, rb, 1000, 200, 'online');
  s := public.pay_start(cu, o2);
  r := r || pg_temp.m('Beta (not connected): no split terms', s ->> 'subaccount' is null and s ->> 'platform_kobo' is null);
  perform public.pay_apply_charge(s ->> 'reference', 120000, 'NGN', true);
  r := r || pg_temp.m('Beta ledger row is platform-settled', (select settlement = 'platform' from public.order_ledger where order_id = o2));
  r := r || pg_temp.m('...so the platform owes Beta its 1080', pg_temp.outstanding(rb) = 1080);

  ---------- switching it off ----------
  perform pg_temp.as_user(oa);
  r := r || pg_temp.expect('an owner cannot switch splitting off', format('select public.admin_set_split_active(%s, false)', ra), '42501');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('admin: Beta has nothing to switch', format('select public.admin_set_split_active(%s, false)', rb), 'P0002');
  r := r || pg_temp.expect('admin switches Alpha off', format('select public.admin_set_split_active(%s, false)', ra), 'ok');
  perform pg_temp.as_su();
  o3 := pg_temp.mk(cu, ra, 1000, 200, 'online');
  s := public.pay_start(cu, o3);
  r := r || pg_temp.m('splitting off: a new Alpha payment has no split terms', s ->> 'subaccount' is null);
  perform pg_temp.as_user(ad);
  perform public.admin_set_split_active(ra, true);
  perform pg_temp.as_su();

  ---------- Paystack refuses the split: fall back to a normal payment ----------
  o4 := pg_temp.mk(cu, ra, 1000, 200, 'online');
  s := public.pay_start(cu, o4);
  r := r || pg_temp.m('terms were created for the attempt', s ->> 'subaccount' is not null);
  perform public.pay_clear_split(s ->> 'reference');
  perform public.pay_apply_charge(s ->> 'reference', 120000, 'NGN', true);
  r := r || pg_temp.m('after the fallback the order is booked as platform-settled', (select settlement = 'platform' from public.order_ledger where order_id = o4));
  r := r || pg_temp.m('...and the platform owes Alpha its 1080', pg_temp.outstanding(ra) = 1080);

  ---------- edge cases: no split when the cut is 0 or the whole order ----------
  perform pg_temp.rates(ra, 0, 0);
  o5 := pg_temp.mk(cu, ra, 1000, 200, 'online');
  r := r || pg_temp.m('0% / 0%: no split (Paystack would ignore a 0 charge)', public.pay_start(cu, o5) ->> 'subaccount' is null);
  perform pg_temp.rates(ra, 100, 100);
  o6 := pg_temp.mk(cu, ra, 1000, 200, 'online');
  r := r || pg_temp.m('100% / 100%: no split (the restaurant would get nothing)', public.pay_start(cu, o6) ->> 'subaccount' is null);
  perform pg_temp.rates(ra, 10, 10);

  ---------- cash orders are never split ----------
  o7 := pg_temp.mk(cu, ra, 500, 100, 'cash_on_delivery');
  update public.orders set order_status = 'confirmed' where id = o7;
  update public.orders set order_status = 'out_for_delivery' where id = o7;
  update public.orders set order_status = 'delivered' where id = o7;
  r := r || pg_temp.m('a delivered cash order is platform-settled', (select settlement = 'platform' from public.order_ledger where order_id = o7));
  r := r || pg_temp.m('...Alpha owes the platform 60, so outstanding = 1080 - 60 = 1020', pg_temp.outstanding(ra) = 1020);

  ---------- refunding a split order ----------
  perform public.pay_reserve_refund(ad, o1, 'customer changed mind');
  perform public.pay_apply_refund((select transaction_reference from public.payments where order_id = o1), 'processed');
  r := r || pg_temp.m('refunded split order: the ledger row is reversed', (select status = 'reversed' from public.order_ledger where order_id = o1));
  r := r || pg_temp.m('...and Alpha''s balance is unchanged (1020)', pg_temp.outstanding(ra) = 1020);

  perform pg_temp.as_su();
  select count(*) into n from unnest(r) x where x like 'FAIL%';
  raise exception E'TEST REPORT\nFAILURES: %\nTOTAL: %\n%', n, array_length(r, 1), array_to_string(r, E'\n');
end $$;
