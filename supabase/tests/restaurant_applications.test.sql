-- Tests for version 2, Phase 4a: restaurant applications and the admin decision. Run the WHOLE file; everything is rolled back
-- and the error at the bottom is the report ("FAILURES: 0" = all good).
do $$
declare
  r text[] := '{}';
  ad uuid := gen_random_uuid(); c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid(); st uuid := gen_random_uuid(); rd uuid := gen_random_uuid();
  r1 bigint; r2 bigint; r3 bigint; n int; v jsonb; cat bigint;
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

  insert into auth.users (id, email, aud, role, raw_user_meta_data)
  select t.u, 'x-' || left(t.u::text, 8) || '@notify-check.dev', 'authenticated', 'authenticated', json_build_object('first_name', t.nm, 'last_name', 'T')::jsonb
  from (values (ad,'Ann'),(c1,'Cy'),(c2,'Dee'),(st,'Stan'),(rd,'Rita')) t(u, nm);
  update public.profiles set role = 'admin' where id = ad;
  update public.profiles set role = 'staff' where id = st;
  update public.profiles set role = 'rider' where id = rd;
  -- other real admins may exist in the live database: silence their mail so counts below only see the test admin
  update public.profiles set is_active = false where role = 'admin' and id <> ad;

  ---------- applying ----------
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('anonymous cannot apply', $q$select public.submit_restaurant_application('Anon Cafe','d','080','1 Rd')$q$, '42501');
  perform pg_temp.as_user(st);
  r := r || pg_temp.expect('a staff account cannot apply', $q$select public.submit_restaurant_application('Staff Cafe','d','080','1 Rd')$q$, '42501');
  perform pg_temp.as_user(rd);
  r := r || pg_temp.expect('a rider cannot apply', $q$select public.submit_restaurant_application('Rider Cafe','d','080','1 Rd')$q$, '42501');
  perform pg_temp.as_user(c1);
  r := r || pg_temp.expect('a one-letter name is refused', $q$select public.submit_restaurant_application('A','d','080','1 Rd')$q$, '22023');
  r := r || pg_temp.expect('a phone number is required', $q$select public.submit_restaurant_application('Nice Place','d','','1 Rd')$q$, '22023');
  r := r || pg_temp.expect('an address is required', $q$select public.submit_restaurant_application('Nice Place','d','080','')$q$, '22023');
  r1 := public.submit_restaurant_application('  Mama Put & Co!  ', 'Home cooking', '08012345678', '5 Aba Road, Port Harcourt');
  perform pg_temp.as_su();
  r := r || pg_temp.m('application creates a PENDING restaurant with a clean slug',
    (select status = 'pending' and slug = 'mama-put-co' and name = 'Mama Put & Co!' and created_by = c1 from public.restaurants where id = r1));
  r := r || pg_temp.m('the applicant is its owner', (select member_role = 'owner' from public.restaurant_members where restaurant_id = r1 and user_id = c1));
  perform pg_temp.as_user(c1);
  r := r || pg_temp.m('...so they cannot manage it', not private.can_manage(r1));
  r := r || pg_temp.expect('a second open application is refused', $q$select public.submit_restaurant_application('Another','d','080','1 Rd')$q$, '55000');
  r := r || pg_temp.expect('the applicant cannot add a category while pending', format('insert into public.categories (category_name, restaurant_id) values (%L, %s)', 'Early', r1), '42501');
  perform pg_temp.as_su();
  r := r || pg_temp.m('every active admin got exactly one "pending" email', (select count(*) from private.notification_outbox where kind = 'restaurant_pending' and payload ->> 'restaurant_id' = r1::text) = 1);
  r := r || pg_temp.m('...and it has no order attached', (select bool_and(order_id is null) from private.notification_outbox where kind = 'restaurant_pending' and payload ->> 'restaurant_id' = r1::text));
  perform pg_temp.as_anon();
  r := r || pg_temp.m('the public cannot see the pending restaurant', not exists (select 1 from public.restaurants where id = r1)
    and not exists (select 1 from jsonb_array_elements(public.list_restaurants()) e where (e ->> 'id')::bigint = r1));
  perform pg_temp.as_user(c1);
  r := r || pg_temp.m('the applicant can see their own application', exists (select 1 from public.restaurants where id = r1));

  ---------- who may decide ----------
  r := r || pg_temp.expect('the applicant cannot approve themselves', format('select public.admin_decide_restaurant(%s, %L)', r1, 'approve'), '42501');
  perform pg_temp.as_user(c2);
  r := r || pg_temp.expect('another customer cannot approve', format('select public.admin_decide_restaurant(%s, %L)', r1, 'approve'), '42501');
  r := r || pg_temp.expect('another customer cannot list applications', 'select public.admin_list_restaurants()', '42501');
  perform pg_temp.as_user(st);
  r := r || pg_temp.expect('staff cannot approve', format('select public.admin_decide_restaurant(%s, %L)', r1, 'approve'), '42501');
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('anonymous cannot approve', format('select public.admin_decide_restaurant(%s, %L)', r1, 'approve'), '42501');

  ---------- approve / reject / suspend / reinstate ----------
  perform pg_temp.as_user(ad);
  v := public.admin_list_restaurants('pending');
  r := r || pg_temp.m('admin sees the application with the applicant''s details',
    exists (select 1 from jsonb_array_elements(v) e where (e ->> 'id')::bigint = r1 and e ->> 'applicant' like 'Cy T <%@notify-check.dev>'));
  r := r || pg_temp.expect('an unknown decision is refused', format('select public.admin_decide_restaurant(%s, %L)', r1, 'delete'), '22023');
  r := r || pg_temp.expect('rejecting needs a reason', format('select public.admin_decide_restaurant(%s, %L)', r1, 'reject'), '22023');
  r := r || pg_temp.expect('unknown restaurant', format('select public.admin_decide_restaurant(%s, %L)', -1, 'approve'), 'P0002');
  r := r || pg_temp.expect('a pending restaurant cannot be suspended', format('select public.admin_decide_restaurant(%s, %L, %L)', r1, 'suspend', 'x'), '55000');
  r := r || pg_temp.expect('a pending restaurant cannot be "reinstated"', format('select public.admin_decide_restaurant(%s, %L)', r1, 'reinstate'), '55000');
  r := r || pg_temp.expect('admin approves', format('select public.admin_decide_restaurant(%s, %L)', r1, 'approve'), 'ok');
  perform pg_temp.as_su();
  r := r || pg_temp.m('approved: restaurant is active, no reason kept', (select status = 'active' and status_reason is null from public.restaurants where id = r1));
  r := r || pg_temp.m('approved: the owner''s account became a staff account', (select role = 'staff' from public.profiles where id = c1));
  r := r || pg_temp.m('approved: the owner is emailed', (select count(*) from private.notification_outbox where kind = 'restaurant_decision' and payload ->> 'restaurant_id' = r1::text and payload ->> 'decision' = 'approve') = 1);
  perform pg_temp.as_anon();
  r := r || pg_temp.m('approved: the public can now see it in the list', exists (select 1 from jsonb_array_elements(public.list_restaurants('mama')) e where (e ->> 'id')::bigint = r1));
  perform pg_temp.as_user(c1);
  r := r || pg_temp.m('approved: the owner now manages it', private.can_manage(r1));
  r := r || pg_temp.expect('approved: the owner can add a category', format('insert into public.categories (category_name, restaurant_id) values (%L, %s)', 'Soups', r1), 'ok');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('approving twice is refused', format('select public.admin_decide_restaurant(%s, %L)', r1, 'approve'), '55000');
  r := r || pg_temp.expect('rejecting an active restaurant is refused', format('select public.admin_decide_restaurant(%s, %L, %L)', r1, 'reject', 'x'), '55000');
  r := r || pg_temp.expect('suspending needs a reason', format('select public.admin_decide_restaurant(%s, %L)', r1, 'suspend'), '22023');
  r := r || pg_temp.expect('suspending with a reason', format('select public.admin_decide_restaurant(%s, %L, %L)', r1, 'suspend', 'Hygiene complaint'), 'ok');
  perform pg_temp.as_user(c1);
  r := r || pg_temp.m('suspended: the owner loses control at once', not private.can_manage(r1));
  perform pg_temp.as_anon();
  r := r || pg_temp.m('suspended: it disappears from the public list', not exists (select 1 from jsonb_array_elements(public.list_restaurants()) e where (e ->> 'id')::bigint = r1));
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('admin reinstates', format('select public.admin_decide_restaurant(%s, %L)', r1, 'reinstate'), 'ok');
  perform pg_temp.as_su();
  r := r || pg_temp.m('reinstated: active again and the reason is cleared', (select status = 'active' and status_reason is null from public.restaurants where id = r1));

  ---------- rejection, re-applying, name clashes ----------
  perform pg_temp.as_user(c2);
  r2 := public.submit_restaurant_application('Mama Put & Co!', null, '08099999999', '9 Other Street');
  perform pg_temp.as_su();
  r := r || pg_temp.m('the same name gets a different slug', (select slug <> 'mama-put-co' and slug like 'mama-put-co-%' from public.restaurants where id = r2));
  perform pg_temp.as_user(ad);
  perform public.admin_decide_restaurant(r2, 'reject', '  Address could not be verified  ');
  perform pg_temp.as_su();
  r := r || pg_temp.m('rejected: status and trimmed reason stored', (select status = 'rejected' and status_reason = 'Address could not be verified' from public.restaurants where id = r2));
  r := r || pg_temp.m('rejected: the applicant stays a customer', (select role = 'customer' from public.profiles where id = c2));
  r := r || pg_temp.m('rejected: the applicant is emailed with the reason', (select count(*) from private.notification_outbox where kind = 'restaurant_decision'
    and payload ->> 'restaurant_id' = r2::text and payload ->> 'reason' = 'Address could not be verified') = 1);
  perform pg_temp.as_user(c2);
  r := r || pg_temp.m('rejected: they can still see their application and reason', exists (select 1 from public.restaurants where id = r2 and status = 'rejected'));
  r := r || pg_temp.expect('rejected: they can apply again', $q$select public.submit_restaurant_application('Better Kitchen','Fresh','08011111111','1 New Road')$q$, 'ok');
  perform pg_temp.as_su();
  perform pg_temp.as_user(c2);
  r := r || pg_temp.m('a rejected restaurant gives its owner no rights', not private.can_manage(r2));

  perform pg_temp.as_su();
  select count(*) into n from unnest(r) x where x like 'FAIL%';
  raise exception E'TEST REPORT\nFAILURES: %\nTOTAL: %\n%', n, array_length(r, 1), array_to_string(r, E'\n');
end $$;
