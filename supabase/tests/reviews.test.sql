-- Tests for reviews and ratings (migration 010). Same style as business_rules.test.sql: run the WHOLE file;
-- everything is rolled back and the error message at the bottom is the report ("FAILURES: 0" = all good).
do $$
declare
  r text[] := '{}';
  c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid(); st uuid := gen_random_uuid();
  rd uuid := gen_random_uuid(); ad uuid := gen_random_uuid();
  cat bigint; f1 bigint; f2 bigint; od bigint; op bigint; oi_d bigint; oi_d2 bigint; oi_p bigint; rv bigint; rv2 bigint; v jsonb; fails int;
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

  insert into auth.users (id, email, aud, role, raw_user_meta_data) values
    (c1, 'r-c1@example.com', 'authenticated', 'authenticated', '{"first_name":"Ada","last_name":"Obi"}'),
    (c2, 'r-c2@example.com', 'authenticated', 'authenticated', '{"first_name":"Bayo","last_name":"K"}'),
    (st, 'r-st@example.com', 'authenticated', 'authenticated', '{"first_name":"S","last_name":"T"}'),
    (rd, 'r-rd@example.com', 'authenticated', 'authenticated', '{"first_name":"R","last_name":"D"}'),
    (ad, 'r-ad@example.com', 'authenticated', 'authenticated', '{"first_name":"A","last_name":"D"}');
  update public.profiles set role = 'staff' where id = st;
  update public.profiles set role = 'rider' where id = rd;
  update public.profiles set role = 'admin' where id = ad;
  insert into public.categories (category_name) values ('R-Cat') returning id into cat;
  insert into public.food_items (category_id, food_name, price) values (cat, 'R-Food1', 1000) returning id into f1;
  insert into public.food_items (category_id, food_name, price) values (cat, 'R-Food2', 500) returning id into f2;

  -- two orders for c1: one delivered (od, two items), one still pending (op)
  perform pg_temp.as_user(c1);
  perform public.add_to_cart(f1, 1); perform public.add_to_cart(f2, 1);
  od := public.place_order('{"street_address":"1 Rd","city":"PH","state":"Rivers"}'::jsonb, 'cash_on_delivery');
  perform public.add_to_cart(f1, 1);
  op := public.place_order('{"street_address":"2 Rd","city":"PH","state":"Rivers"}'::jsonb, 'cash_on_delivery');
  perform pg_temp.as_su();
  update public.orders set order_status = 'delivered' where id = od;   -- shortcut for the test (the real flow is covered elsewhere)
  select id into oi_d  from public.order_items where order_id = od and food_id = f1;
  select id into oi_d2 from public.order_items where order_id = od and food_id = f2;
  select id into oi_p  from public.order_items where order_id = op;

  ---------- food reviews: who, when, how often ----------
  perform pg_temp.as_user(c1);
  r := r || pg_temp.expect('cannot review an item from an undelivered order', format('select public.submit_food_review(%s, 5)', oi_p), '55000');
  r := r || pg_temp.expect('rating 6 refused', format('select public.submit_food_review(%s, 6)', oi_d), '22023');
  r := r || pg_temp.expect('rating 0 refused', format('select public.submit_food_review(%s, 0)', oi_d), '22023');
  r := r || pg_temp.expect('comment over 500 characters refused', format('select public.submit_food_review(%s, 5, %L)', oi_d, repeat('a', 501)), '22023');
  rv := public.submit_food_review(oi_d, 5, '  Great jollof  ');
  r := r || pg_temp.m('delivered item can be reviewed (comment trimmed)', (select comment from public.food_reviews where id = rv) = 'Great jollof');
  r := r || pg_temp.m('new review starts as pending', (select status from public.food_reviews where id = rv) = 'pending');
  r := r || pg_temp.expect('same item cannot be reviewed twice', format('select public.submit_food_review(%s, 1)', oi_d), '55000');
  perform pg_temp.as_user(c2);
  r := r || pg_temp.expect('another customer cannot review my item', format('select public.submit_food_review(%s, 5)', oi_d2), 'P0002');
  perform pg_temp.as_user(st);
  r := r || pg_temp.expect('staff cannot write reviews', format('select public.submit_food_review(%s, 5)', oi_d2), '42501');
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('logged-out visitor cannot write reviews', format('select public.submit_food_review(%s, 5)', oi_d2), '42501');

  ---------- clients cannot write the tables directly ----------
  perform pg_temp.as_user(c1);
  r := r || pg_temp.expect('no direct insert into food_reviews', format('insert into public.food_reviews (order_item_id, food_id, user_id, rating) values (%s, %s, %L, 5)', oi_d2, f2, c1), '42501');
  r := r || pg_temp.expect('no direct approval of own review', format('update public.food_reviews set status = %L where id = %s', 'approved', rv), '42501');
  r := r || pg_temp.expect('no direct delete', format('delete from public.food_reviews where id = %s', rv), '42501');
  r := r || pg_temp.expect('the old open reviews table is gone', 'select * from public.reviews', '42P01');

  ---------- pending reviews are private ----------
  perform pg_temp.as_anon();
  r := r || pg_temp.m('pending review is not in the public list', public.list_food_reviews(f1) = '[]'::jsonb);
  r := r || pg_temp.m('pending review does not count in averages', not exists (select 1 from public.get_food_ratings() where food_id = f1));
  r := r || pg_temp.expect('anon cannot read the table directly', 'select * from public.food_reviews', '42501');
  perform pg_temp.as_user(c1);
  r := r || pg_temp.m('author can see own review row', (select count(*) from public.food_reviews) = 1);
  perform pg_temp.as_user(c2);
  r := r || pg_temp.m('other customer sees no review rows', (select count(*) from public.food_reviews) = 0);
  perform pg_temp.as_user(st);
  r := r || pg_temp.m('staff do not see food review rows (admin only)', (select count(*) from public.food_reviews) = 0);

  ---------- moderation ----------
  perform pg_temp.as_user(c1);
  r := r || pg_temp.expect('customer cannot approve', format('select public.moderate_food_review(%s, %L)', rv, 'approved'), '42501');
  perform pg_temp.as_user(st);
  r := r || pg_temp.expect('staff cannot approve', format('select public.moderate_food_review(%s, %L)', rv, 'approved'), '42501');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.m('admin sees the pending review', (select count(*) from public.food_reviews where status = 'pending') = 1);
  r := r || pg_temp.expect('cannot move a review back to pending', format('select public.moderate_food_review(%s, %L)', rv, 'pending'), '22023');
  r := r || pg_temp.expect('unknown review id', 'select public.moderate_food_review(999999999, ''approved'')', 'P0002');
  perform public.moderate_food_review(rv, 'approved');
  perform pg_temp.as_anon();
  v := public.list_food_reviews(f1);
  r := r || pg_temp.m('approved review is public with reviewer shown as "Ada O."', jsonb_array_length(v) = 1 and v->0->>'reviewer' = 'Ada O.' and v->0->>'comment' = 'Great jollof');
  r := r || pg_temp.m('public list never exposes email or ids', not (v->0 ? 'email') and not (v->0 ? 'user_id') and not (v->0 ? 'id'));
  r := r || pg_temp.m('average and count come from approved reviews', (select avg_rating = 5.0 and review_count = 1 from public.get_food_ratings() where food_id = f1));
  -- second review, on the other item of the same order (rated 2)
  perform pg_temp.as_user(c1);
  rv2 := public.submit_food_review(oi_d2, 2);
  perform pg_temp.as_user(ad);
  perform public.moderate_food_review(rv2, 'approved');
  perform pg_temp.as_anon();
  r := r || pg_temp.m('food ratings are per food', (select avg_rating = 2.0 from public.get_food_ratings() where food_id = f2));
  perform pg_temp.as_user(ad);
  perform public.moderate_food_review(rv, 'hidden');
  perform pg_temp.as_anon();
  r := r || pg_temp.m('hidden review disappears from the public list and average', public.list_food_reviews(f1) = '[]'::jsonb and not exists (select 1 from public.get_food_ratings() where food_id = f1));
  r := r || pg_temp.m('limit is capped (asking for 9999 is fine)', jsonb_typeof(public.list_food_reviews(f2, 9999, -5)) = 'array');

  ---------- order and delivery ratings (private) ----------
  perform pg_temp.as_user(c1);
  r := r || pg_temp.expect('cannot rate an undelivered order', format('select public.submit_order_rating(%s, 5)', op), '55000');
  r := r || pg_temp.expect('delivery rating 9 refused', format('select public.submit_order_rating(%s, 4, 9)', od), '22023');
  r := r || pg_temp.expect('overall rating is required', format('select public.submit_order_rating(%s, null)', od), '22023');
  r := r || pg_temp.expect('delivered order can be rated', format('select public.submit_order_rating(%s, 4, 5, %L)', od, 'Fast rider'), 'ok');
  r := r || pg_temp.expect('order cannot be rated twice', format('select public.submit_order_rating(%s, 1)', od), '55000');
  r := r || pg_temp.m('author sees own order rating', (select count(*) from public.order_ratings) = 1);
  r := r || pg_temp.expect('no direct insert into order_ratings', format('insert into public.order_ratings (order_id, user_id, rating) values (%s, %L, 5)', op, c1), '42501');
  perform pg_temp.as_user(c2);
  r := r || pg_temp.expect('another customer cannot rate my order', format('select public.submit_order_rating(%s, 5)', od), 'P0002');
  r := r || pg_temp.m('...and sees no ratings', (select count(*) from public.order_ratings) = 0);
  perform pg_temp.as_user(st);
  r := r || pg_temp.m('staff can read order ratings', (select count(*) from public.order_ratings) = 1 and (select delivery_rating from public.order_ratings) = 5);
  perform pg_temp.as_user(ad);
  r := r || pg_temp.m('admin can read order ratings', (select count(*) from public.order_ratings) = 1);
  perform pg_temp.as_user(rd);
  r := r || pg_temp.m('riders cannot read order ratings', (select count(*) from public.order_ratings) = 0);
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('anon cannot read order ratings', 'select * from public.order_ratings', '42501');
  r := r || pg_temp.expect('anon cannot read delivery zones', 'select * from public.delivery_zones', '42501');

  perform pg_temp.as_su();
  select count(*) into fails from unnest(r) x where x like 'FAIL%';
  raise exception E'TEST REPORT\nFAILURES: %\nTOTAL: %\n%', fails, array_length(r, 1), array_to_string(r, E'\n');
end $$;
