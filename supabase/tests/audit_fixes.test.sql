-- Tests for the Phase 1-5 audit fixes: restaurant column privacy, rider pickup info, refund requests.
-- Run the WHOLE file; everything is rolled back and the error at the bottom is the report ("FAILURES: 0" = all good).
do $$
declare
  r text[] := '{}';
  ad uuid := gen_random_uuid(); oa uuid := gen_random_uuid(); ma uuid := gen_random_uuid(); sa uuid := gen_random_uuid();
  ob uuid := gen_random_uuid(); cu uuid := gen_random_uuid(); rd uuid := gen_random_uuid();
  ra bigint; rb bigint; o1 bigint; o2 bigint; o3 bigint; q bigint; v jsonb; n int;
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
  create function pg_temp.mk(p_user uuid, p_rest bigint, p_method public.payment_method) returns bigint
  language plpgsql as $f$
  declare a bigint; o bigint;
  begin
    insert into public.addresses (user_id, street_address, city, state) values (p_user, '1 Test St', 'Lagos', 'Lagos') returning id into a;
    insert into public.orders (user_id, restaurant_id, address_id, subtotal, delivery_fee, discount, total_amount,
                               delivery_street_address, delivery_city, delivery_state)
    values (p_user, p_rest, a, 1000, 200, 0, 1200, '1 Test St', 'Lagos', 'Lagos') returning id into o;
    insert into public.payments (order_id, payment_method, amount) values (o, p_method, 1200);
    return o;
  end $f$;

  insert into auth.users (id, email, aud, role, raw_user_meta_data)
  select t.u, 'x-' || left(t.u::text, 8) || '@notify-check.dev', 'authenticated', 'authenticated', json_build_object('first_name', t.nm, 'last_name', 'T')::jsonb
  from (values (ad,'Ann'),(oa,'OwnA'),(ma,'MgrA'),(sa,'StaffA'),(ob,'OwnB'),(cu,'Cy'),(rd,'Rider')) t(u, nm);
  update public.profiles set role = 'admin' where id = ad;
  update public.profiles set role = 'staff' where id in (oa, ma, sa, ob);
  update public.profiles set role = 'rider' where id = rd;
  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by, address, phone) values ('Alpha Grill', 'af-alpha', 'active', 200, oa, '5 Kitchen Rd', '08011112222') returning id into ra;
  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by) values ('Beta Kitchen', 'af-beta', 'active', 500, ob) returning id into rb;
  insert into public.restaurant_members values (ra, oa, 'owner'), (ra, ma, 'manager'), (ra, sa, 'staff'), (rb, ob, 'owner');

  o1 := pg_temp.mk(cu, ra, 'online');
  update public.payments set payment_status = 'paid', paid_at = now(), transaction_reference = 'ORD-' || o1 || '-aaaaaaaaaaaaaaaa' where order_id = o1;
  o2 := pg_temp.mk(cu, ra, 'cash_on_delivery');
  o3 := pg_temp.mk(cu, ra, 'online');   -- still unpaid

  ---------- restaurant column privacy ----------
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('anonymous can still read the public columns', 'select id, name, slug, is_open, base_delivery_fee from public.restaurants', 'ok');
  r := r || pg_temp.expect('anonymous cannot read commission_percent', 'select commission_percent from public.restaurants', '42501');
  r := r || pg_temp.expect('anonymous cannot read delivery_commission_percent', 'select delivery_commission_percent from public.restaurants', '42501');
  r := r || pg_temp.expect('anonymous cannot read created_by', 'select created_by from public.restaurants', '42501');
  r := r || pg_temp.expect('anonymous cannot select *', 'select * from public.restaurants', '42501');
  perform pg_temp.as_user(oa);
  r := r || pg_temp.expect('owner cannot read the commission rate directly', 'select commission_percent from public.restaurants', '42501');
  r := r || pg_temp.expect('owner can read status_reason', 'select status_reason from public.restaurants', 'ok');
  v := public.list_my_restaurants();
  r := r || pg_temp.m('owner still gets their rates through list_my_restaurants()', (v -> 0 ->> 'commission_percent')::numeric = 10);
  r := r || pg_temp.expect('owner cannot read the settlement table', 'select * from public.restaurant_settlement', '42501');

  ---------- rider pickup ----------
  perform pg_temp.as_su();
  insert into public.deliveries (order_id, rider_id, delivery_status) values (o1, rd, 'assigned');
  perform pg_temp.as_user(rd);
  v := public.get_my_deliveries();
  r := r || pg_temp.m('rider sees the pickup restaurant name, address and phone',
    v -> 0 -> 'restaurant' ->> 'name' = 'Alpha Grill' and v -> 0 -> 'restaurant' ->> 'address' = '5 Kitchen Rd' and v -> 0 -> 'restaurant' ->> 'phone' = '08011112222');
  r := r || pg_temp.m('rider still sees the customer and items', v -> 0 -> 'customer' ->> 'name' is not null and jsonb_typeof(v -> 0 -> 'items') = 'array');

  ---------- refund requests ----------
  perform pg_temp.as_user(ma);
  r := r || pg_temp.expect('manager can request a refund for a paid online order', format('select public.request_refund(%s, %L)', o1, 'Customer received the wrong meal'), 'ok');
  r := r || pg_temp.expect('a second open request for the same order is refused', format('select public.request_refund(%s, %L)', o1, 'again'), '55000');
  r := r || pg_temp.expect('a blank reason is refused', format('select public.request_refund(%s, %L)', o1, '   '), '22023');
  r := r || pg_temp.expect('an unpaid online order cannot be refunded', format('select public.request_refund(%s, %L)', o3, 'x'), '55000');
  r := r || pg_temp.expect('a cash order cannot be refunded', format('select public.request_refund(%s, %L)', o2, 'x'), '55000');
  v := public.list_refund_requests(ra);
  r := r || pg_temp.m('manager sees the request, open', jsonb_array_length(v) = 1 and v -> 0 ->> 'status' = 'open');
  r := r || pg_temp.expect('manager cannot list another restaurant''s requests', format('select public.list_refund_requests(%s)', rb), '42501');
  r := r || pg_temp.expect('manager cannot see the admin queue', 'select public.admin_list_refund_requests(null)', '42501');
  r := r || pg_temp.expect('manager cannot dismiss', format('select public.admin_dismiss_refund_request(1, %L)', 'no'), '42501');
  perform pg_temp.as_user(sa);
  r := r || pg_temp.expect('plain staff cannot request a refund', format('select public.request_refund(%s, %L)', o1, 'x'), '42501');
  r := r || pg_temp.m('plain staff cannot read the requests table', (select count(*) = 0 from public.refund_requests));
  perform pg_temp.as_user(ob);
  r := r || pg_temp.expect('another restaurant''s owner gets "not found"', format('select public.request_refund(%s, %L)', o1, 'x'), 'P0002');
  r := r || pg_temp.m('another restaurant''s owner sees no requests', (select count(*) = 0 from public.refund_requests));
  perform pg_temp.as_user(cu);
  r := r || pg_temp.expect('a customer cannot request a refund', format('select public.request_refund(%s, %L)', o1, 'x'), 'P0002');
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('anonymous cannot request a refund', format('select public.request_refund(%s, %L)', o1, 'x'), '42501');

  perform pg_temp.as_user(ad);
  v := public.admin_list_refund_requests('open');
  r := r || pg_temp.m('admin sees the open request with restaurant name and amount', jsonb_array_length(v) >= 1 and exists (
    select 1 from jsonb_array_elements(v) e where (e ->> 'order_id')::bigint = o1 and e ->> 'restaurant' = 'Alpha Grill' and (e ->> 'amount')::numeric = 1200));
  select id into q from public.refund_requests where order_id = o1;
  r := r || pg_temp.expect('dismiss needs a note', format('select public.admin_dismiss_refund_request(%s, %L)', q, ''), '22023');
  r := r || pg_temp.expect('admin can dismiss with a note', format('select public.admin_dismiss_refund_request(%s, %L)', q, 'Meal was fine'), 'ok');
  r := r || pg_temp.expect('a closed request cannot be dismissed again', format('select public.admin_dismiss_refund_request(%s, %L)', q, 'x'), '55000');
  r := r || pg_temp.expect('a request that does not exist', format('select public.admin_dismiss_refund_request(999999999, %L)', 'x'), 'P0002');
  r := r || pg_temp.m('a dismissed request records its note', (select resolution_note = 'Meal was fine' and status = 'dismissed' from public.refund_requests where id = q));

  -- a new request is allowed after the earlier one closed; refunding the payment closes it as done
  perform pg_temp.as_user(oa);
  r := r || pg_temp.expect('owner can ask again after a dismissal', format('select public.request_refund(%s, %L)', o1, 'Second try'), 'ok');
  perform pg_temp.as_su();
  update public.payments set payment_status = 'refunded' where order_id = o1;
  r := r || pg_temp.m('refunding the payment closes the open request as done',
    (select count(*) from public.refund_requests where order_id = o1 and status = 'done' and resolved_at is not null) = 1
    and (select count(*) from public.refund_requests where order_id = o1 and status = 'open') = 0);

  select count(*) into n from unnest(r) x where x like 'FAIL%';
  raise exception E'TEST REPORT\nFAILURES: %\nTOTAL: %\n%', n, array_length(r, 1), array_to_string(r, E'\n');
end $$;
