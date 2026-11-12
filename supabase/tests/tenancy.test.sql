-- Tests for version 2, Phase 2: cross-restaurant isolation. Two restaurants (A and B) with their own people, menu, zones and
-- orders. Every check tries to make someone from A touch something of B (and the reverse). Run the WHOLE file: everything
-- is rolled back, and the error at the bottom is the report ("FAILURES: 0" = all good).
do $$
declare
  r text[] := '{}';
  ad uuid := gen_random_uuid(); oa uuid := gen_random_uuid(); ma uuid := gen_random_uuid(); sa uuid := gen_random_uuid();
  ob uuid := gen_random_uuid(); mb uuid := gen_random_uuid(); sb uuid := gen_random_uuid();
  cu uuid := gen_random_uuid(); c2 uuid := gen_random_uuid(); rd uuid := gen_random_uuid(); rd2 uuid := gen_random_uuid();
  ls uuid := gen_random_uuid(); sp uuid := gen_random_uuid(); ap uuid := gen_random_uuid();
  ra bigint; rb bigint; rp bigint; ca bigint; cb bigint; fa bigint; fb bigint; fp bigint; cp bigint; za bigint; zb bigint;
  o_a bigint; o_b bigint; oi_a bigint; rv bigint; n int; fails int; v jsonb;
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
  create function pg_temp.cnt(p_order bigint, p_kind text) returns int language sql as
    $f$ select count(*)::int from private.notification_outbox where order_id = p_order and kind = p_kind and to_email like '%@notify-check.dev' $f$;

  ---------- people ----------
  insert into auth.users (id, email, aud, role, raw_user_meta_data)
  select t.u, 'x-' || left(t.u::text, 8) || '@notify-check.dev', 'authenticated', 'authenticated',
         json_build_object('first_name', t.nm, 'last_name', 'T')::jsonb
  from (values (ad,'Ann'),(oa,'OwnA'),(ma,'MgrA'),(sa,'StaffA'),(ob,'OwnB'),(mb,'MgrB'),(sb,'StaffB'),
               (cu,'Cy'),(c2,'Dee'),(rd,'Rita'),(rd2,'Remi'),(ls,'Lone'),(sp,'Sus'),(ap,'Abe')) t(u, nm);
  update public.profiles set role = 'admin' where id = ad;
  update public.profiles set role = 'staff' where id in (oa, ma, sa, ob, mb, sb, ls);   -- ls = "staff" label but on NO team
  update public.profiles set role = 'rider' where id in (rd, rd2);

  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by) values ('Alpha Grill', 't-alpha', 'active', 200, oa) returning id into ra;
  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by) values ('Beta Kitchen', 't-beta', 'active', 500, ob) returning id into rb;
  insert into public.restaurants (name, slug, status, created_by) values ('Pending Place', 't-pending', 'pending', ap) returning id into rp;
  insert into public.restaurant_members values (ra, oa, 'owner'), (ra, ma, 'manager'), (ra, sa, 'staff'),
                                               (rb, ob, 'owner'), (rb, mb, 'manager'), (rb, sb, 'staff'), (rp, ap, 'owner');

  insert into public.categories (category_name, restaurant_id) values ('Mains', ra) returning id into ca;
  insert into public.categories (category_name, restaurant_id) values ('Mains', rb) returning id into cb;   -- same name, other restaurant
  insert into public.categories (category_name, restaurant_id) values ('Soon', rp) returning id into cp;
  insert into public.food_items (category_id, food_name, price, restaurant_id) values (ca, 'A-Jollof', 1000, ra) returning id into fa;
  insert into public.food_items (category_id, food_name, price, restaurant_id) values (cb, 'B-Suya', 700, rb) returning id into fb;
  insert into public.food_items (category_id, food_name, price, restaurant_id) values (cp, 'P-Dish', 300, rp) returning id into fp;
  insert into public.delivery_zones (zone_name, extra_fee, restaurant_id) values ('Zone', 100, ra) returning id into za;
  insert into public.delivery_zones (zone_name, extra_fee, restaurant_id) values ('Zone', 300, rb) returning id into zb;

  ---------- customer: one restaurant per cart, fees per restaurant ----------
  perform pg_temp.as_user(cu);
  perform public.add_to_cart(fa, 2);
  r := r || pg_temp.m('get_cart reports the cart''s restaurant and ITS fee (200)',
    (public.get_cart() -> 'restaurant' ->> 'id')::bigint = ra and (public.get_cart() -> 'summary' ->> 'delivery_fee')::numeric = 200);
  r := r || pg_temp.expect('adding food from another restaurant is refused', format('select public.add_to_cart(%s, 1)', fb), '55000');
  r := r || pg_temp.expect('direct cart_items insert of another restaurant''s food is blocked by RLS',
    format('insert into public.cart_items (cart_id, food_id, quantity) select id, %s, 1 from public.carts where user_id = %L', fb, cu), '42501');
  r := r || pg_temp.expect('cannot add food of a pending restaurant', format('select public.add_to_cart(%s, 1)', fp), 'P0002');
  r := r || pg_temp.expect('another restaurant''s delivery area is refused at checkout',
    format('select public.place_order(%L::jsonb, %L, %s)', '{"street_address":"1 Rd","city":"PH","state":"Rivers"}', 'cash_on_delivery', zb), '22023');
  r := r || pg_temp.m('quote uses the cart''s restaurant (200 + zone 100)', (public.delivery_quote(za) ->> 'delivery_fee')::numeric = 300);
  perform pg_temp.as_su();
  update public.restaurants set is_open = false where id = ra;
  perform pg_temp.as_user(cu);
  r := r || pg_temp.expect('a closed restaurant takes no orders',
    format('select public.place_order(%L::jsonb, %L, %s)', '{"street_address":"1 Rd","city":"PH","state":"Rivers"}', 'cash_on_delivery', za), '22023');
  perform pg_temp.as_su();
  update public.restaurants set is_open = true where id = ra;
  perform pg_temp.as_user(cu);
  o_a := public.place_order('{"street_address":"1 Rd","city":"PH","state":"Rivers"}'::jsonb, 'cash_on_delivery', za);
  r := r || pg_temp.m('after ordering the cart has no restaurant, so another one can be used',
    (select restaurant_id is null from public.carts where user_id = cu));
  perform public.add_to_cart(fb, 1);
  o_b := public.place_order('{"street_address":"2 Rd","city":"PH","state":"Rivers"}'::jsonb, 'cash_on_delivery', zb);
  perform pg_temp.as_su();
  r := r || pg_temp.m('orders are stamped with the right restaurant', (select restaurant_id from public.orders where id = o_a) = ra and (select restaurant_id from public.orders where id = o_b) = rb);
  r := r || pg_temp.m('fees: A = 200 + 100, B = 500 + 300',
    (select delivery_fee from public.orders where id = o_a) = 300 and (select delivery_fee from public.orders where id = o_b) = 800);
  r := r || pg_temp.expect('an order cannot be moved to another restaurant', format('update public.orders set restaurant_id = %s where id = %s', rb, o_a), '55000');
  r := r || pg_temp.m('"new order" emails go to restaurant A''s team only',
    pg_temp.cnt(o_a, 'new_order') = 3 and not exists (select 1 from private.notification_outbox n join auth.users u on u.email = n.to_email
                                                      where n.order_id = o_a and n.kind = 'new_order' and u.id in (ob, mb, sb, ad)));
  r := r || pg_temp.m('...and B''s emails to B''s team', pg_temp.cnt(o_b, 'new_order') = 3
    and not exists (select 1 from private.notification_outbox n join auth.users u on u.email = n.to_email where n.order_id = o_b and n.kind = 'new_order' and u.id in (oa, ma, sa)));

  ---------- staff of A: sees and changes only A ----------
  perform pg_temp.as_user(sa);
  r := r || pg_temp.m('staff A sees order A and not order B', exists (select 1 from public.orders where id = o_a) and not exists (select 1 from public.orders where id = o_b));
  r := r || pg_temp.m('staff A cannot read the items, payment or history of B',
    not exists (select 1 from public.order_items where order_id = o_b) and not exists (select 1 from public.payments where order_id = o_b)
    and not exists (select 1 from public.order_status_history where order_id = o_b));
  r := r || pg_temp.m('staff A can read the items of A', exists (select 1 from public.order_items where order_id = o_a));
  r := r || pg_temp.m('staff A sees the customer of A, not people who never ordered there',
    exists (select 1 from public.profiles where id = cu) and not exists (select 1 from public.profiles where id = c2));
  r := r || pg_temp.m('staff A does not see the team of B', not exists (select 1 from public.profiles where id = sb or id = mb));
  r := r || pg_temp.m('staff A sees the shared rider pool', exists (select 1 from public.profiles where id = rd));
  r := r || pg_temp.expect('staff A cannot confirm order B', format('select public.change_order_status(%s, %L)', o_b, 'confirmed'), 'P0002');
  r := r || pg_temp.expect('staff A cannot reject order B', format('select public.change_order_status(%s, %L, %L)', o_b, 'rejected', 'x'), 'P0002');
  r := r || pg_temp.expect('staff A cannot assign a rider to order B', format('select public.assign_rider(%s, %L)', o_b, rd), 'P0002');
  r := r || pg_temp.expect('staff A can confirm order A', format('select public.change_order_status(%s, %L)', o_a, 'confirmed'), 'ok');

  -- menu and money: staff read, managers write, only their own restaurant
  r := r || pg_temp.expect('staff A cannot create a category (not a manager)', format('insert into public.categories (category_name, restaurant_id) values (%L, %s)', 'Nope', ra), '42501');
  r := r || pg_temp.expect('staff A cannot set the fee', 'select public.admin_set_delivery_fee(1)', '42501');
  perform pg_temp.as_user(ma);
  r := r || pg_temp.expect('manager A can add a category to A', format('insert into public.categories (category_name, restaurant_id) values (%L, %s)', 'Drinks', ra), 'ok');
  r := r || pg_temp.expect('manager A cannot add a category to B', format('insert into public.categories (category_name, restaurant_id) values (%L, %s)', 'Evil', rb), '42501');
  r := r || pg_temp.expect('a category without a restaurant lands in the manager''s own restaurant', 'insert into public.categories (category_name) values (''Auto'')', 'ok');
  r := r || pg_temp.m('...and it is restaurant A', (select restaurant_id from public.categories where category_name = 'Auto') = ra);
  r := r || pg_temp.expect('manager A cannot add food to B', format('insert into public.food_items (category_id, food_name, price, restaurant_id) values (%s, %L, 1, %s)', cb, 'Evil', rb), '42501');
  r := r || pg_temp.expect('manager A cannot put A''s food in B''s category (composite FK)', format('insert into public.food_items (category_id, food_name, price, restaurant_id) values (%s, %L, 1, %s)', cb, 'Evil', ra), '23503');
  update public.food_items set price = 1 where id = fb;
  get diagnostics n = row_count;
  r := r || pg_temp.m('manager A cannot change the price of B''s food (0 rows)', n = 0);
  delete from public.categories where id = cb;
  get diagnostics n = row_count;
  r := r || pg_temp.m('manager A cannot delete B''s category (0 rows)', n = 0);
  r := r || pg_temp.expect('manager A cannot move food to another restaurant', format('update public.food_items set restaurant_id = %s where id = %s', rb, fa), '55000');
  r := r || pg_temp.expect('manager A cannot create a zone for B', format('insert into public.delivery_zones (zone_name, restaurant_id) values (%L, %s)', 'Evil', rb), '42501');
  r := r || pg_temp.m('manager A sets the fee of A (admin_set_delivery_fee)', (public.admin_set_delivery_fee(250) ->> 'restaurant_id')::bigint = ra);
  r := r || pg_temp.m('get_delivery_settings shows A''s fee', (public.get_delivery_settings() ->> 'base_fee')::numeric = 250);
  r := r || pg_temp.m('manager A sees the team of A, not of B',
    exists (select 1 from public.restaurant_members where restaurant_id = ra) and not exists (select 1 from public.restaurant_members where restaurant_id = rb));
  r := r || pg_temp.m('manager A sees the profiles of A''s team, not B''s', exists (select 1 from public.profiles where id = sa) and not exists (select 1 from public.profiles where id = sb));
  r := r || pg_temp.expect('manager A cannot edit the restaurant row of B', format('update public.restaurants set name = %L where id = %s', 'Hacked', rb), 'ok');
  r := r || pg_temp.m('...it changed nothing', (select name from public.restaurants where id = rb) = 'Beta Kitchen');
  r := r || pg_temp.expect('manager A cannot add themselves to B', format('insert into public.restaurant_members values (%s, %L, %L)', rb, ma, 'manager'), '42501');
  perform pg_temp.as_su();
  r := r || pg_temp.m('the fee of B is untouched', (select base_delivery_fee from public.restaurants where id = rb) = 500);

  ---------- B is symmetric ----------
  perform pg_temp.as_user(mb);
  r := r || pg_temp.m('manager B sees order B and not order A', exists (select 1 from public.orders where id = o_b) and not exists (select 1 from public.orders where id = o_a));
  r := r || pg_temp.expect('manager B cannot cancel order A', format('select public.change_order_status(%s, %L, %L)', o_a, 'cancelled', 'x'), 'P0002');
  r := r || pg_temp.expect('manager B cannot assign a rider to order A', format('select public.assign_rider(%s, %L)', o_a, rd), 'P0002');

  ---------- delivery, reviews, ratings, refunds ----------
  perform pg_temp.as_user(sa);
  perform public.change_order_status(o_a, 'preparing');
  perform public.change_order_status(o_a, 'ready_for_delivery');
  perform public.assign_rider(o_a, rd);
  perform pg_temp.as_user(sb);
  r := r || pg_temp.m('staff B cannot see the delivery of A', not exists (select 1 from public.deliveries where order_id = o_a));
  perform pg_temp.as_user(sa);
  r := r || pg_temp.m('staff A sees the delivery of A', exists (select 1 from public.deliveries where order_id = o_a));
  perform pg_temp.as_user(rd2);
  r := r || pg_temp.expect('a rider who is not assigned cannot update the delivery', format('select public.update_delivery_status(%s, %L)', o_a, 'picked_up'), 'P0002');
  r := r || pg_temp.m('an unassigned rider sees no deliveries', jsonb_array_length(public.get_my_deliveries()) = 0);
  perform pg_temp.as_user(rd);
  perform public.update_delivery_status(o_a, 'picked_up');
  perform public.update_delivery_status(o_a, 'delivered');
  r := r || pg_temp.m('the assigned rider sees only their own delivery... (none active after delivery)', jsonb_array_length(public.get_my_deliveries()) = 0);
  perform pg_temp.as_user(cu);
  select id into oi_a from public.order_items where order_id = o_a limit 1;
  rv := public.submit_food_review(oi_a, 4, 'good');
  perform public.submit_order_rating(o_a, 5, 4, 'nice');
  perform pg_temp.as_su();
  insert into public.payment_refunds (payment_id, transaction_reference, amount, reason, requested_by)
  select p.id, 'T-REF-' || o_a, p.amount, 'test', ad from public.payments p where p.order_id = o_a;

  perform pg_temp.as_user(mb);
  r := r || pg_temp.m('manager B sees no review, rating or refund of A',
    not exists (select 1 from public.food_reviews where id = rv) and not exists (select 1 from public.order_ratings where order_id = o_a)
    and not exists (select 1 from public.payment_refunds));
  r := r || pg_temp.expect('manager B cannot moderate the review of A', format('select public.moderate_food_review(%s, %L)', rv, 'hidden'), 'P0002');
  perform pg_temp.as_user(sa);
  r := r || pg_temp.m('staff A sees the rating of A but not the review queue or refunds',
    exists (select 1 from public.order_ratings where order_id = o_a) and not exists (select 1 from public.food_reviews where id = rv)
    and not exists (select 1 from public.payment_refunds));
  r := r || pg_temp.expect('staff A cannot moderate (not a manager)', format('select public.moderate_food_review(%s, %L)', rv, 'hidden'), '42501');
  perform pg_temp.as_user(ma);
  r := r || pg_temp.m('manager A sees the review and the refund of A',
    exists (select 1 from public.food_reviews where id = rv) and exists (select 1 from public.payment_refunds));
  r := r || pg_temp.expect('manager A can moderate the review of A', format('select public.moderate_food_review(%s, %L)', rv, 'hidden'), 'ok');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('platform admin can moderate any review', format('select public.moderate_food_review(%s, %L)', rv, 'approved'), 'ok');
  r := r || pg_temp.m('platform admin sees every order and refund', exists (select 1 from public.orders where id = o_a) and exists (select 1 from public.orders where id = o_b) and exists (select 1 from public.payment_refunds));
  r := r || pg_temp.expect('with several restaurants an admin must say which one the fee is for', 'select public.admin_set_delivery_fee(100)', '22023');
  r := r || pg_temp.expect('refunds still need an admin (manager cannot reserve one)', format('select public.pay_reserve_refund(%L, %s, %L)', ma, o_a, 'x'), '42501');

  ---------- people without a team ----------
  perform pg_temp.as_user(ls);
  r := r || pg_temp.m('a user labelled "staff" but on no team sees no orders', not exists (select 1 from public.orders));
  r := r || pg_temp.expect('...cannot change an order', format('select public.change_order_status(%s, %L)', o_b, 'confirmed'), 'P0002');
  r := r || pg_temp.expect('...cannot assign a rider', format('select public.assign_rider(%s, %L)', o_b, rd), '42501');
  r := r || pg_temp.expect('...cannot add a category', 'insert into public.categories (category_name) values (''Nope'')', '42501');
  perform pg_temp.as_user(c2);
  r := r || pg_temp.expect('another customer cannot cancel someone else''s order', format('select public.change_order_status(%s, %L)', o_b, 'cancelled'), 'P0002');
  r := r || pg_temp.m('another customer sees no orders, items or deliveries', not exists (select 1 from public.orders) and not exists (select 1 from public.order_items));
  perform pg_temp.as_user(rd);
  r := r || pg_temp.expect('a rider cannot change order status', format('select public.change_order_status(%s, %L)', o_a, 'cancelled'), '42501');
  r := r || pg_temp.expect('a rider cannot assign riders', format('select public.assign_rider(%s, %L)', o_a, rd), '42501');

  ---------- pending and suspended restaurants ----------
  perform pg_temp.as_anon();
  r := r || pg_temp.m('anonymous sees food of active restaurants, not of the pending one',
    exists (select 1 from public.food_items where id = fa) and not exists (select 1 from public.food_items where id = fp)
    and not exists (select 1 from public.categories where id = cp));
  r := r || pg_temp.m('anonymous sees no orders', not exists (select 1 from public.orders));
  perform pg_temp.as_user(ap);
  r := r || pg_temp.expect('...really cannot add a category', format('insert into public.categories (category_name, restaurant_id) values (%L, %s)', 'Early', rp), '42501');
  perform pg_temp.as_su();
  update public.restaurants set status = 'suspended' where id = ra;
  perform pg_temp.as_user(sa);
  r := r || pg_temp.m('suspending restaurant A locks its team out of its orders', not exists (select 1 from public.orders where id = o_a));
  perform pg_temp.as_anon();
  r := r || pg_temp.m('...and hides its menu from the public', not exists (select 1 from public.food_items where id = fa));
  perform pg_temp.as_user(c2);
  r := r || pg_temp.expect('...and nobody can add its food to a cart', format('select public.add_to_cart(%s, 1)', fa), 'P0002');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.m('...but the platform admin still sees it', exists (select 1 from public.orders where id = o_a));

  ---------- report ----------
  perform pg_temp.as_su();
  select count(*) into fails from unnest(r) x where x like 'FAIL%';
  raise exception E'TEST REPORT FAILURES: %\n%', fails, array_to_string(r, E'\n');
end $$;
