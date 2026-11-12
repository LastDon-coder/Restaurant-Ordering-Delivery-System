-- Tests for order notifications (migration 011). Same style as the other tests: run the WHOLE file; everything is
-- rolled back (pg_net only sends after a COMMIT, so no real HTTP call or email happens) and the error message at the
-- bottom is the report ("FAILURES: 0" = all good).
do $$
declare
  r text[] := '{}';
  c1 uuid := gen_random_uuid(); ct uuid := gen_random_uuid(); st uuid := gen_random_uuid();
  rd uuid := gen_random_uuid(); rd2 uuid := gen_random_uuid(); ad uuid := gen_random_uuid();
  cat bigint; f1 bigint; oc bigint; oo bigint; ot bigint; v jsonb; fails int; ref text; kobo bigint; n int; id1 bigint;
begin
  create function pg_temp.m(p_name text, p_ok boolean) returns text language sql as
    $f$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name $f$;
  create function pg_temp.as_user(u uuid) returns void language plpgsql as
    $f$ begin perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
         execute 'reset role'; execute 'set local role authenticated'; end $f$;
  create function pg_temp.as_anon() returns void language plpgsql as
    $f$ begin perform set_config('request.jwt.claims', '', true); execute 'reset role'; execute 'set local role anon'; end $f$;
  create function pg_temp.as_service() returns void language plpgsql as
    $f$ begin execute 'reset role'; execute 'set local role service_role'; end $f$;
  create function pg_temp.as_su() returns void language plpgsql as $f$ begin execute 'reset role'; end $f$;
  create function pg_temp.expect(p_name text, p_sql text, p_state text) returns text language plpgsql as
    $f$ begin execute p_sql; return pg_temp.m(p_name || ' [expected ' || p_state || ', got ok]', p_state = 'ok');
        exception when others then return pg_temp.m(p_name || ' [expected ' || p_state || ', got ' || sqlstate || ']', sqlstate = p_state); end $f$;
  -- Only look at THIS test's recipients (the live project has real staff whose rows would also be queued).
  create function pg_temp.cnt(p_order bigint, p_kind text, p_like text default '%@notify-check.dev') returns int language sql as
    $f$ select count(*)::int from private.notification_outbox where order_id = p_order and kind = p_kind and to_email like p_like $f$;

  insert into auth.users (id, email, aud, role, raw_user_meta_data) values
    (c1, 'n-c1@notify-check.dev', 'authenticated', 'authenticated', '{"first_name":"Ada","last_name":"Obi"}'),
    (ct, 'n-test@example.com', 'authenticated', 'authenticated', '{"first_name":"Tess","last_name":"T"}'),
    (st, 'n-st@notify-check.dev', 'authenticated', 'authenticated', '{"first_name":"Sam","last_name":"Staff"}'),
    (rd, 'n-rd@notify-check.dev', 'authenticated', 'authenticated', '{"first_name":"Rita","last_name":"Rider"}'),
    (rd2, 'n-rd2@notify-check.dev', 'authenticated', 'authenticated', '{"first_name":"Remi","last_name":"Rider"}'),
    (ad, 'n-ad@notify-check.dev', 'authenticated', 'authenticated', '{"first_name":"Ann","last_name":"Admin"}');
  update public.profiles set role = 'staff' where id = st;
  insert into public.restaurant_members (restaurant_id, user_id, member_role) values (1, st, 'staff');
  insert into public.restaurant_members (restaurant_id, user_id, member_role) values (1, ad, 'manager');
  update public.profiles set role = 'rider' where id in (rd, rd2);
  update public.profiles set role = 'admin' where id = ad;
  insert into public.categories (category_name, restaurant_id) values ('N-Cat', 1) returning id into cat;
  insert into public.food_items (category_id, food_name, price, restaurant_id) values (cat, 'N-Food <b>', 1000, 1) returning id into f1;

  ---------- the address filter ----------
  r := r || pg_temp.m('real address is deliverable', private.mail_ok('ada@gmail.com'));
  r := r || pg_temp.m('example.com is not', not private.mail_ok('a@example.com'));
  r := r || pg_temp.m('.invalid is not', not private.mail_ok('a@mail.invalid'));
  r := r || pg_temp.m('junk is not', not private.mail_ok('not-an-email') and not private.mail_ok(null));

  ---------- cash order: customer + staff + admin are queued, rider is not ----------
  perform pg_temp.as_user(c1);
  perform public.add_to_cart(f1, 2);
  oc := public.place_order('{"street_address":"1 Rd <script>","city":"PH","state":"Rivers"}'::jsonb, 'cash_on_delivery');
  perform pg_temp.as_su();
  r := r || pg_temp.m('cash order: customer gets "order received"', pg_temp.cnt(oc, 'order_received') = 1);
  r := r || pg_temp.m('cash order: the restaurant team (staff + manager) gets "new order"', pg_temp.cnt(oc, 'new_order') = 2);
  r := r || pg_temp.m('cash order: no rider email yet', pg_temp.cnt(oc, 'rider_assigned') = 0);
  r := r || pg_temp.m('payload carries the items, total and address',
    (select payload->>'total' = '4000.00' and payload->'items'->0->>'quantity' = '2' and payload->>'address' like '1 Rd%'
       from private.notification_outbox where order_id = oc and kind = 'order_received'));
  r := r || pg_temp.m('payload keeps raw text (escaping happens when the email is built)',
    (select payload->'items'->0->>'name' = 'N-Food <b>' from private.notification_outbox where order_id = oc and kind = 'order_received'));
  r := r || pg_temp.m('every new row starts pending with 0 attempts',
    not exists (select 1 from private.notification_outbox where order_id = oc and (status <> 'pending' or attempts <> 0)));

  ---------- an order from a test address sends nothing at all ----------
  perform pg_temp.as_user(ct);
  perform public.add_to_cart(f1, 1);
  ot := public.place_order('{"street_address":"9 Rd","city":"PH","state":"Rivers"}'::jsonb, 'cash_on_delivery');
  perform pg_temp.as_su();
  r := r || pg_temp.m('test-address customer: nothing queued for anyone',
    (select count(*) from private.notification_outbox where order_id = ot) = 0);
  perform pg_temp.as_user(st);
  perform public.change_order_status(ot, 'confirmed');
  perform pg_temp.as_su();
  r := r || pg_temp.m('test-address customer: status changes queue nothing either',
    (select count(*) from private.notification_outbox where order_id = ot) = 0);

  ---------- status emails: confirmed, preparing, out for delivery only ----------
  perform pg_temp.as_user(st);
  perform public.change_order_status(oc, 'confirmed');
  perform pg_temp.as_su();
  r := r || pg_temp.m('confirmed -> customer email', pg_temp.cnt(oc, 'order_status') = 1);
  perform pg_temp.as_user(st);
  perform public.change_order_status(oc, 'preparing');
  perform pg_temp.as_su();
  r := r || pg_temp.m('preparing -> customer email', pg_temp.cnt(oc, 'order_status') = 2);
  perform pg_temp.as_user(st);
  perform public.change_order_status(oc, 'ready_for_delivery');
  perform pg_temp.as_su();
  r := r || pg_temp.m('ready for delivery -> no email (not in the chosen list)', pg_temp.cnt(oc, 'order_status') = 2);

  ---------- rider assignment ----------
  perform pg_temp.as_user(st);
  perform public.assign_rider(oc, rd);
  perform pg_temp.as_su();
  r := r || pg_temp.m('assigning a rider emails that rider', pg_temp.cnt(oc, 'rider_assigned', 'n-rd@%') = 1);
  perform pg_temp.as_user(st);
  perform public.assign_rider(oc, rd);
  perform pg_temp.as_su();
  r := r || pg_temp.m('assigning the same rider again does not email twice', pg_temp.cnt(oc, 'rider_assigned') = 1);
  perform pg_temp.as_user(st);
  perform public.assign_rider(oc, rd2);
  perform pg_temp.as_su();
  r := r || pg_temp.m('reassigning to another rider emails the new rider', pg_temp.cnt(oc, 'rider_assigned', 'n-rd2@%') = 1);
  perform pg_temp.as_user(rd2);
  perform public.update_delivery_status(oc, 'picked_up');
  perform pg_temp.as_su();
  r := r || pg_temp.m('picked up -> customer "on its way" email (3 status emails now)', pg_temp.cnt(oc, 'order_status') = 3);
  r := r || pg_temp.m('the on-its-way row is tagged out_for_delivery',
    exists (select 1 from private.notification_outbox where order_id = oc and kind = 'order_status' and payload->>'status' = 'out_for_delivery'));

  ---------- online order: nothing until the payment is confirmed ----------
  perform pg_temp.as_user(c1);
  perform public.add_to_cart(f1, 1);
  oo := public.place_order('{"street_address":"2 Rd","city":"PH","state":"Rivers"}'::jsonb, 'online');
  perform pg_temp.as_su();
  r := r || pg_temp.m('unpaid online order: nothing queued yet', (select count(*) from private.notification_outbox where order_id = oo) = 0);
  perform pg_temp.as_service();
  v := public.pay_start(c1, oo); ref := v->>'reference'; kobo := (v->>'amount_kobo')::bigint;
  r := r || pg_temp.m('payment accepted', public.pay_apply_charge(ref, kobo, 'NGN', true)->>'result' = 'paid');
  perform pg_temp.as_su();
  r := r || pg_temp.m('paid online order: customer + staff + admin queued',
    pg_temp.cnt(oo, 'order_received') = 1 and pg_temp.cnt(oo, 'new_order') = 2);
  perform pg_temp.as_service();
  perform public.pay_apply_charge(ref, kobo, 'NGN', true);   -- the payment webhook is delivered twice
  perform pg_temp.as_su();
  r := r || pg_temp.m('webhook replay does not queue duplicates', pg_temp.cnt(oo, 'order_received') = 1 and pg_temp.cnt(oo, 'new_order') = 2);

  ---------- who can touch the queue ----------
  perform pg_temp.as_user(c1);
  r := r || pg_temp.expect('customer cannot read the outbox', 'select count(*) from private.notification_outbox', '42501');
  r := r || pg_temp.expect('customer cannot claim', 'select public.claim_notifications(5)', '42501');
  r := r || pg_temp.expect('customer cannot finish', 'select public.finish_notification(1, true)', '42501');
  perform pg_temp.as_user(st);
  r := r || pg_temp.expect('staff cannot claim', 'select public.claim_notifications(5)', '42501');
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('anonymous cannot claim', 'select public.claim_notifications(5)', '42501');
  r := r || pg_temp.expect('anonymous cannot read the outbox', 'select count(*) from private.notification_outbox', '42501');

  ---------- the sender's lease / retry rules ----------
  perform pg_temp.as_su();
  -- Keep only this test's rows visible to the sender: park every other pending row far in the future.
  update private.notification_outbox set send_after = now() + interval '1 day' where to_email not like '%@notify-check.dev';
  perform pg_temp.as_service();
  v := public.claim_notifications(100);
  r := r || pg_temp.m('claim hands out the due rows', jsonb_array_length(v) >= 10);
  r := r || pg_temp.m('claimed rows show attempt 1', (v->0->>'attempts') = '1');
  id1 := (v->0->>'id')::bigint;
  r := r || pg_temp.m('a second claim finds nothing (rows are leased)', jsonb_array_length(public.claim_notifications(100)) = 0);
  perform public.finish_notification(id1, true);
  perform pg_temp.as_su();
  r := r || pg_temp.m('finish ok -> sent with a timestamp', (select status = 'sent' and sent_at is not null from private.notification_outbox where id = id1));

  id1 := (v->1->>'id')::bigint;
  perform pg_temp.as_service();
  perform public.finish_notification(id1, false, 'Resend 500: boom');
  perform pg_temp.as_su();
  r := r || pg_temp.m('a failed send goes back to pending with a delay and the error',
    (select status = 'pending' and send_after > now() and last_error like 'Resend 500%' from private.notification_outbox where id = id1));

  id1 := (v->2->>'id')::bigint;
  perform pg_temp.as_service();
  perform public.finish_notification(id1, false, 'Resend 422: bad address', true);
  perform pg_temp.as_su();
  r := r || pg_temp.m('a permanent failure is final at once', (select status = 'failed' from private.notification_outbox where id = id1));

  id1 := (v->3->>'id')::bigint;
  update private.notification_outbox set attempts = 5 where id = id1;
  perform pg_temp.as_service();
  perform public.finish_notification(id1, false, 'still failing');
  perform pg_temp.as_su();
  r := r || pg_temp.m('after 5 attempts it stops retrying', (select status = 'failed' from private.notification_outbox where id = id1));

  -- an expired lease (sender crashed) makes the row claimable again
  id1 := (v->4->>'id')::bigint;
  update private.notification_outbox set locked_until = now() - interval '1 minute' where id = id1;
  perform pg_temp.as_service();
  r := r || pg_temp.m('an expired lease is picked up again (attempt 2)',
    exists (select 1 from jsonb_array_elements(public.claim_notifications(100)) e where (e->>'id')::bigint = id1 and (e->>'attempts') = '2'));

  perform pg_temp.as_su();
  select count(*) into fails from unnest(r) x where x like 'FAIL%';
  raise exception E'TEST REPORT\nFAILURES: %\nTOTAL: %\n%', fails, array_length(r, 1), array_to_string(r, E'\n');
end $$;
