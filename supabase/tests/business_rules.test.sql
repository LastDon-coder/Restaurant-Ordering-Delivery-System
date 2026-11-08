-- Business-rule tests for the Supabase database. Run the WHOLE file in the Supabase SQL editor (or via the MCP
-- execute_sql tool). Everything runs inside one transaction that is ROLLED BACK at the end, so no data is kept:
-- the "error" you see at the bottom is the test report. Look for lines starting FAIL; "FAILURES: 0" means all good.
-- Re-run after every migration. Needs the seed menu or any one available food (the test creates its own foods).
do $$
declare
  r text[] := '{}';
  c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid(); st uuid := gen_random_uuid();
  rd uuid := gen_random_uuid(); rd2 uuid := gen_random_uuid(); ad uuid := gen_random_uuid(); evil uuid := gen_random_uuid();
  cat bigint; f1 bigint; f2 bigint; fx bigint; oc bigint; oo bigint; ref text; kobo bigint; v jsonb; n int; txt text;
  fails int;
begin
  -- helpers (pg_temp = private to this session). m(): record a result. as_*(): switch identity like the API does.
  create function pg_temp.m(p_name text, p_ok boolean) returns text language sql as
    $f$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name $f$;
  create function pg_temp.as_user(u uuid) returns void language plpgsql as
    $f$ begin perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
         execute 'reset role'; execute 'set local role authenticated'; end $f$;
  create function pg_temp.as_service() returns void language plpgsql as
    $f$ begin execute 'reset role'; execute 'set local role service_role'; end $f$;
  create function pg_temp.as_su() returns void language plpgsql as $f$ begin execute 'reset role'; end $f$;
  -- expect(): run SQL, return PASS if it fails with the given SQLSTATE (or succeeds when expected = 'ok')
  create function pg_temp.expect(p_name text, p_sql text, p_state text) returns text language plpgsql as
    $f$ begin execute p_sql; return pg_temp.m(p_name || ' [expected ' || p_state || ', got ok]', p_state = 'ok');
        exception when others then return pg_temp.m(p_name || ' [expected ' || p_state || ', got ' || sqlstate || ']', sqlstate = p_state); end $f$;

  ---------- setup (as superuser) ----------
  insert into auth.users (id, email, aud, role, raw_user_meta_data) values
    (c1, 't-c1@example.com', 'authenticated', 'authenticated', '{"first_name":"C","last_name":"One"}'),
    (c2, 't-c2@example.com', 'authenticated', 'authenticated', '{"first_name":"C","last_name":"Two"}'),
    (st, 't-st@example.com', 'authenticated', 'authenticated', '{"first_name":"S","last_name":"Taff"}'),
    (rd, 't-rd@example.com', 'authenticated', 'authenticated', '{"first_name":"R","last_name":"One"}'),
    (rd2,'t-rd2@example.com','authenticated', 'authenticated', '{"first_name":"R","last_name":"Two"}'),
    (ad, 't-ad@example.com', 'authenticated', 'authenticated', '{"first_name":"A","last_name":"Dmin"}'),
    (evil,'t-evil@example.com','authenticated','authenticated','{"first_name":"E","last_name":"Vil","role":"admin"}');
  update public.profiles set role = 'staff' where id = st;
  update public.profiles set role = 'rider' where id in (rd, rd2);
  update public.profiles set role = 'admin' where id = ad;
  insert into public.categories (category_name) values ('T-Cat') returning id into cat;
  insert into public.food_items (category_id, food_name, price) values (cat, 'T-Food1', 1000.00) returning id into f1;
  insert into public.food_items (category_id, food_name, price) values (cat, 'T-Food2', 250.50) returning id into f2;
  insert into public.food_items (category_id, food_name, price, is_available) values (cat, 'T-SoldOut', 10, false) returning id into fx;

  ---------- sign-up and role safety ----------
  r := r || pg_temp.m('sign-up claiming role=admin still becomes customer', (select role from public.profiles where id = evil) = 'customer');
  perform pg_temp.as_user(c1);
  r := r || pg_temp.expect('customer cannot promote self (column grant)', format('update public.profiles set role = %L where id = %L', 'admin', c1), '42501');
  r := r || pg_temp.expect('customer cannot insert orders directly', format('insert into public.orders (user_id,address_id,subtotal,total_amount,delivery_street_address,delivery_city,delivery_state) values (%L,1,1,1,%L,%L,%L)', c1, 'x', 'y', 'z'), '42501');
  r := r || pg_temp.expect('customer cannot mark a payment paid directly', 'update public.payments set payment_status = ''paid''', '42501');
  r := r || pg_temp.expect('customer cannot call pay_apply_charge', 'select public.pay_apply_charge(''ORD-1-0000000000000000'',1,''NGN'',true)', '42501');

  ---------- cart: server-side totals and limits ----------
  perform public.add_to_cart(f1, 2); perform public.add_to_cart(f2, 1);
  v := public.get_cart();
  r := r || pg_temp.m('cart subtotal computed by server (2x1000 + 250.50)', (v->'summary'->>'subtotal')::numeric = 2250.50);
  r := r || pg_temp.m('delivery fee 500 added, total 2750.50', (v->'summary'->>'total')::numeric = 2750.50);
  r := r || pg_temp.expect('cannot exceed 50 of one item', format('select public.add_to_cart(%s, 49)', f1), '22023');
  r := r || pg_temp.expect('quantity 0 rejected', format('select public.add_to_cart(%s, 0)', f1), '22023');
  r := r || pg_temp.expect('sold-out food cannot be added', format('select public.add_to_cart(%s, 1)', fx), 'P0002');
  perform pg_temp.as_user(st);
  r := r || pg_temp.expect('staff has no cart', format('select public.add_to_cart(%s, 1)', f1), '42501');

  ---------- place order: snapshot + atomic cart clear ----------
  perform pg_temp.as_user(c1);
  r := r || pg_temp.expect('address is required', 'select public.place_order(''{}''::jsonb, ''cash_on_delivery'')', '22023');
  oc := public.place_order('{"street_address":"1 Aba Rd","city":"PH","state":"Rivers"}'::jsonb, 'cash_on_delivery');
  r := r || pg_temp.m('order total = 2750.50', (select total_amount from public.orders where id = oc) = 2750.50);
  r := r || pg_temp.m('cart emptied by place_order', not exists (select 1 from public.cart_items ci join public.carts c on c.id = ci.cart_id where c.user_id = c1));
  r := r || pg_temp.expect('empty cart cannot be ordered', 'select public.place_order(''{"street_address":"a","city":"b","state":"c"}''::jsonb, ''cash_on_delivery'')', '22023');
  perform pg_temp.as_su();
  update public.food_items set price = 9999 where id = f1;
  r := r || pg_temp.m('price change later does not alter the order snapshot', (select price from public.order_items where order_id = oc and food_id = f1) = 1000.00
                      and (select total_amount from public.orders where id = oc) = 2750.50);
  update public.food_items set price = 1000 where id = f1;

  ---------- isolation between customers ----------
  perform pg_temp.as_user(c2);
  r := r || pg_temp.m('customer 2 cannot see customer 1 orders', (select count(*) from public.orders where id = oc) = 0);
  r := r || pg_temp.expect('customer 2 cannot change customer 1 order', format('select public.change_order_status(%s, %L)', oc, 'cancelled'), 'P0002');

  ---------- status rules ----------
  perform pg_temp.as_user(st);
  r := r || pg_temp.expect('cannot skip pending -> preparing', format('select public.change_order_status(%s, %L)', oc, 'preparing'), '55000');
  r := r || pg_temp.expect('rejecting needs a reason', format('select public.change_order_status(%s, %L)', oc, 'rejected'), '22023');
  perform public.change_order_status(oc, 'confirmed'); perform public.change_order_status(oc, 'preparing'); perform public.change_order_status(oc, 'ready_for_delivery');
  r := r || pg_temp.m('staff moved COD order to ready_for_delivery', (select order_status from public.orders where id = oc) = 'ready_for_delivery');
  r := r || pg_temp.expect('staff cannot set out_for_delivery (rider only)', format('select public.change_order_status(%s, %L)', oc, 'out_for_delivery'), '42501');
  perform pg_temp.as_user(c1);
  r := r || pg_temp.expect('customer cannot cancel once confirmed', format('select public.change_order_status(%s, %L)', oc, 'cancelled'), '42501');

  ---------- delivery flow ----------
  perform pg_temp.as_user(c2);
  r := r || pg_temp.expect('customer cannot assign riders', format('select public.assign_rider(%s, %L)', oc, rd), '42501');
  perform pg_temp.as_user(st);
  r := r || pg_temp.expect('cannot assign a non-rider', format('select public.assign_rider(%s, %L)', oc, c2), '22023');
  perform public.assign_rider(oc, rd);
  perform pg_temp.as_user(rd);
  r := r || pg_temp.m('rider sees their job', jsonb_array_length(public.get_my_deliveries()) = 1);
  perform pg_temp.as_user(rd2);
  r := r || pg_temp.m('other rider sees nothing', jsonb_array_length(public.get_my_deliveries()) = 0);
  r := r || pg_temp.expect('other rider cannot update this delivery', format('select public.update_delivery_status(%s, %L)', oc, 'picked_up'), 'P0002');
  perform pg_temp.as_user(rd);
  r := r || pg_temp.expect('cannot deliver before pickup', format('select public.update_delivery_status(%s, %L)', oc, 'delivered'), '55000');
  perform public.update_delivery_status(oc, 'picked_up');
  r := r || pg_temp.m('pickup sets order out_for_delivery', (select order_status from public.orders where id = oc) = 'out_for_delivery');
  perform public.update_delivery_status(oc, 'delivered');
  perform pg_temp.as_su();
  r := r || pg_temp.m('delivered order is final', (select order_status from public.orders where id = oc) = 'delivered');
  r := r || pg_temp.m('COD payment marked paid on delivery', (select payment_status from public.payments where order_id = oc) = 'paid');
  r := r || pg_temp.m('status history recorded (6+ entries)', (select count(*) from public.order_status_history where order_id = oc) >= 6);

  ---------- online payment ----------
  perform pg_temp.as_user(c1);
  perform public.add_to_cart(f2, 2);
  oo := public.place_order('{"street_address":"2 Aba Rd","city":"PH","state":"Rivers"}'::jsonb, 'online');
  perform pg_temp.as_user(st);
  r := r || pg_temp.expect('online order cannot be confirmed before payment', format('select public.change_order_status(%s, %L)', oo, 'confirmed'), '55000');
  perform pg_temp.as_service();
  v := public.pay_start(c1, oo); ref := v->>'reference'; kobo := (v->>'amount_kobo')::bigint;
  r := r || pg_temp.m('payment amount comes from DB (2x250.50 + 500 = 1001.00 -> 100100 kobo)', kobo = 100100);
  r := r || pg_temp.m('wrong amount refused', public.pay_apply_charge(ref, kobo - 1, 'NGN', true)->>'result' = 'amount_mismatch');
  r := r || pg_temp.m('wrong currency refused', public.pay_apply_charge(ref, kobo, 'USD', true)->>'result' = 'amount_mismatch');
  r := r || pg_temp.m('unknown reference refused', public.pay_apply_charge('ORD-1-0000000000000000', kobo, 'NGN', true)->>'result' = 'unknown_reference');
  r := r || pg_temp.expect('another user cannot start payment on this order', format('select public.pay_start(%L, %s)', c2, oo), 'P0002');
  r := r || pg_temp.m('correct payment accepted', public.pay_apply_charge(ref, kobo, 'NGN', true)->>'result' = 'paid');
  r := r || pg_temp.m('webhook replay is idempotent', public.pay_apply_charge(ref, kobo, 'NGN', true)->>'result' = 'already_paid');
  perform pg_temp.as_user(st);
  perform public.change_order_status(oo, 'confirmed');
  r := r || pg_temp.m('paid online order can now be confirmed', (select order_status from public.orders where id = oo) = 'confirmed');

  ---------- refunds ----------
  perform pg_temp.as_service();
  r := r || pg_temp.expect('non-admin cannot reserve a refund', format('select public.pay_reserve_refund(%L, %s, %L)', st, oo, 'x'), '42501');
  r := r || pg_temp.m('admin reserves refund for the DB amount', (public.pay_reserve_refund(ad, oo, 'Customer asked')->>'amount_kobo')::bigint = 100100);
  r := r || pg_temp.expect('second refund on same payment refused', format('select public.pay_reserve_refund(%L, %s, %L)', ad, oo, 'again'), '55000');
  r := r || pg_temp.m('refund webhook reports processed', (public.pay_apply_refund(ref, 'processed', 'rf_1')->>'result') = 'processed');
  -- (separate statement: a read in the same statement as the write would see the old snapshot)
  r := r || pg_temp.m('...and the payment is now marked refunded', (select payment_status from public.payments where order_id = oo) = 'refunded');
  perform pg_temp.as_user(c1);
  r := r || pg_temp.m('customer cannot see refunds table rows', (select count(*) from public.payment_refunds) = 0);

  ---------- admin tools ----------
  perform pg_temp.as_user(c1);
  r := r || pg_temp.expect('customer cannot list users', 'select * from public.admin_list_users()', '42501');
  r := r || pg_temp.expect('customer cannot change roles', format('select public.admin_set_role(%L, %L)', c1, 'admin'), '42501');
  r := r || pg_temp.expect('customer cannot write the menu', format('update public.food_items set price = 1 where id = %s', f1), 'ok');
  r := r || pg_temp.m('...and nothing changed (RLS filtered the update)', (select price from public.food_items where id = f1) = 1000.00);
  perform pg_temp.as_user(st);
  r := r || pg_temp.expect('staff cannot create categories', 'insert into public.categories (category_name) values (''Nope'')', '42501');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('admin cannot change own role', format('select public.admin_set_role(%L, %L)', ad, 'staff'), '55000');
  r := r || pg_temp.expect('admin cannot deactivate self', format('select public.admin_set_active(%L, false)', ad), '55000');
  r := r || pg_temp.expect('admin can promote a customer to staff', format('select public.admin_set_role(%L, %L)', c2, 'staff'), 'ok');
  r := r || pg_temp.expect('negative price rejected by constraint', format('insert into public.food_items (category_id, food_name, price) values (%s, %L, -1)', cat, 'Bad'), '23514');
  r := r || pg_temp.expect('duplicate category name rejected', 'insert into public.categories (category_name) values (''T-Cat'')', '23505');
  r := r || pg_temp.expect('ordered food cannot be deleted', format('delete from public.food_items where id = %s', f1), '23503');
  -- a rider with an unfinished delivery is protected
  perform pg_temp.as_user(c1);
  perform public.add_to_cart(f1, 1);
  oo := public.place_order('{"street_address":"3 Aba Rd","city":"PH","state":"Rivers"}'::jsonb, 'cash_on_delivery');
  perform pg_temp.as_user(st);
  perform public.change_order_status(oo, 'confirmed'); perform public.assign_rider(oo, rd2);
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('rider with unfinished delivery cannot be demoted', format('select public.admin_set_role(%L, %L)', rd2, 'customer'), '55000');
  r := r || pg_temp.expect('...or deactivated', format('select public.admin_set_active(%L, false)', rd2), '55000');
  perform pg_temp.as_user(c1);
  r := r || pg_temp.expect('customer cannot cancel a confirmed order', format('select public.change_order_status(%s, %L)', oo, 'cancelled'), '42501');

  perform pg_temp.as_su();
  select count(*) into fails from unnest(r) x where x like 'FAIL%';
  -- Raising an error is what rolls everything back; the message IS the report.
  raise exception E'TEST REPORT\nFAILURES: %\nTOTAL: %\n%', fails, array_length(r, 1), array_to_string(r, E'\n');
end $$;
