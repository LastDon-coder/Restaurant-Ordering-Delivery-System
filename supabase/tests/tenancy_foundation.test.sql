-- Tests for version 2, Phase 1: tenancy foundation (migration 012). Same style as the other tests: run the WHOLE file;
-- everything is rolled back and the error message at the bottom is the report ("FAILURES: 0" = all good).
-- Phase 2 will add tenancy.test.sql (cross-restaurant isolation of every policy and function).
do $$
declare
  r text[] := '{}';
  ow uuid := gen_random_uuid(); mg uuid := gen_random_uuid(); sf uuid := gen_random_uuid(); si uuid := gen_random_uuid();
  cu uuid := gen_random_uuid(); ad uuid := gen_random_uuid(); ap uuid := gen_random_uuid(); cm uuid := gen_random_uuid();
  rb bigint; rc bigint; cat1 bigint; catb bigint; fb bigint; f1 bigint; zb bigint; z1 bigint; od bigint; oz bigint; n int; fails int;
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

  ---------- the backfill (checked BEFORE the test creates anything) ----------
  r := r || pg_temp.m('Restaurant #1 exists, is active, slug "restaurant"',
    exists (select 1 from public.restaurants where id = 1 and slug = 'restaurant' and status = 'active'));
  r := r || pg_temp.m('every existing category, food, zone and order belongs to Restaurant #1',
    not exists (select 1 from public.categories where restaurant_id <> 1) and not exists (select 1 from public.food_items where restaurant_id <> 1)
    and not exists (select 1 from public.delivery_zones where restaurant_id <> 1) and not exists (select 1 from public.orders where restaurant_id <> 1));
  r := r || pg_temp.m('every v1 staff user is a member of Restaurant #1',
    not exists (select 1 from public.profiles p where p.role = 'staff'
                and not exists (select 1 from public.restaurant_members m where m.restaurant_id = 1 and m.user_id = p.id)));
  r := r || pg_temp.m('Restaurant #1 has an owner', exists (select 1 from public.restaurant_members where restaurant_id = 1 and member_role = 'owner'));
  r := r || pg_temp.m('Restaurant #1 starts with the v1 delivery fee', (select base_delivery_fee from public.restaurants where id = 1) = private.delivery_fee());

  ---------- test people ----------
  insert into auth.users (id, email, aud, role, raw_user_meta_data) values
    (ow, 't-ow@example.com', 'authenticated', 'authenticated', '{"first_name":"Owen","last_name":"Owner"}'),
    (mg, 't-mg@example.com', 'authenticated', 'authenticated', '{"first_name":"Mona","last_name":"Manager"}'),
    (sf, 't-sf@example.com', 'authenticated', 'authenticated', '{"first_name":"Sam","last_name":"Staff"}'),
    (si, 't-si@example.com', 'authenticated', 'authenticated', '{"first_name":"Ina","last_name":"Inactive"}'),
    (cu, 't-cu@example.com', 'authenticated', 'authenticated', '{"first_name":"Cy","last_name":"Customer"}'),
    (ad, 't-ad@example.com', 'authenticated', 'authenticated', '{"first_name":"Ann","last_name":"Admin"}'),
    (ap, 't-ap@example.com', 'authenticated', 'authenticated', '{"first_name":"Abe","last_name":"Applicant"}'),
    (cm, 't-cm@example.com', 'authenticated', 'authenticated', '{"first_name":"Cleo","last_name":"Pending-member"}');
  update public.profiles set role = 'admin' where id = ad;
  update public.profiles set role = 'staff' where id = sf;     -- v1 staff role still drives the v1 policies
  update public.profiles set is_active = false where id = si;

  ---------- constraints ----------
  r := r || pg_temp.expect('slug must be lowercase letters, digits and dashes', $q$insert into public.restaurants (name, slug) values ('Bad One', 'Bad Slug!')$q$, '23514');
  r := r || pg_temp.expect('slug cannot be a duplicate', $q$insert into public.restaurants (name, slug) values ('Dup', 'restaurant')$q$, '23505');
  r := r || pg_temp.expect('name needs at least 2 characters', $q$insert into public.restaurants (name, slug) values ('X', 'x-restaurant')$q$, '23514');
  r := r || pg_temp.expect('commission cannot exceed 100', $q$insert into public.restaurants (name, slug, commission_percent) values ('Greedy', 'greedy', 101)$q$, '23514');
  r := r || pg_temp.expect('a restaurant with orders cannot be deleted', 'delete from public.restaurants where id = 1', '23503');

  insert into public.restaurants (name, slug, status, created_by) values ('Beta Kitchen', 'beta-kitchen', 'active', ow) returning id into rb;
  insert into public.restaurants (name, slug, status, created_by) values ('Pending Place', 'pending-place', 'pending', ap) returning id into rc;
  insert into public.restaurant_members values (rb, ow, 'owner'), (rb, mg, 'manager'), (rb, sf, 'staff'), (rb, si, 'staff'), (rc, cm, 'owner');
  r := r || pg_temp.m('default status of a new restaurant is pending', (select status from public.restaurants where slug = 'pending-place') = 'pending');
  r := r || pg_temp.expect('one role per person per restaurant', format('insert into public.restaurant_members values (%s, %L, %L)', rb, mg, 'staff'), '23505');

  insert into public.categories (category_name, restaurant_id) values ('T-Cat Beta', rb) returning id into catb;
  insert into public.categories (category_name, restaurant_id) values ('T-Cat One', 1) returning id into cat1;
  r := r || pg_temp.m('a category stored in Restaurant #1 reads back with restaurant_id 1', (select restaurant_id from public.categories where id = cat1) = 1);
  insert into public.food_items (category_id, food_name, price, restaurant_id) values (catb, 'T-Food Beta', 700, rb) returning id into fb;
  insert into public.food_items (category_id, food_name, price, restaurant_id) values (cat1, 'T-Food One', 1000, 1) returning id into f1;
  r := r || pg_temp.expect('food cannot use another restaurant''s category (composite FK)',
    format('insert into public.food_items (category_id, food_name, price, restaurant_id) values (%s, %L, 1, %s)', cat1, 'T-Bad', rb), '23503');
  r := r || pg_temp.expect('food cannot be moved to another restaurant while in its category',
    format('update public.food_items set restaurant_id = %s where id = %s', rb, f1), '23503');
  r := r || pg_temp.expect('a category name is unique inside a restaurant', format('insert into public.categories (category_name, restaurant_id) values (%L, %s)', 't-cat beta ', rb), '23505');

  insert into public.delivery_zones (zone_name, extra_fee, restaurant_id) values ('T-Zone Beta', 100, rb) returning id into zb;
  insert into public.delivery_zones (zone_name, extra_fee, restaurant_id) values ('T-Zone One', 300, 1) returning id into z1;

  ---------- the v1 flow still works, and orders are stamped with Restaurant #1 ----------
  perform pg_temp.as_user(cu);
  perform public.add_to_cart(f1, 1);
  od := public.place_order('{"street_address":"1 Rd","city":"PH","state":"Rivers"}'::jsonb, 'cash_on_delivery', z1);
  perform pg_temp.as_su();
  r := r || pg_temp.m('v1 place_order still works and stamps Restaurant #1', (select restaurant_id from public.orders where id = od) = 1);
  perform pg_temp.as_user(sf);
  perform public.change_order_status(od, 'confirmed');
  perform pg_temp.as_su();
  r := r || pg_temp.m('v1 staff can still confirm the order', (select order_status from public.orders where id = od) = 'confirmed');
  r := r || pg_temp.expect('an order cannot point at another restaurant''s delivery area',
    format('update public.orders set delivery_zone_id = %s where id = %s', zb, od), '23503');
  delete from public.delivery_zones where id = z1;
  r := r || pg_temp.m('deleting a zone clears only the zone link; the order keeps its restaurant and zone name',
    (select delivery_zone_id is null and restaurant_id = 1 and delivery_zone_name = 'T-Zone One' from public.orders where id = od));

  ---------- helper functions ----------
  perform pg_temp.as_user(ow);
  r := r || pg_temp.m('owner: member and can manage their restaurant', private.is_member(rb) and private.can_manage(rb) and private.member_role(rb) = 'owner');
  r := r || pg_temp.m('owner: no access to another restaurant', not private.is_member(1) and not private.can_manage(rc));
  perform pg_temp.as_user(mg);
  r := r || pg_temp.m('manager: member and can manage', private.is_member(rb) and private.can_manage(rb));
  perform pg_temp.as_user(sf);
  r := r || pg_temp.m('staff: member but cannot manage', private.is_member(rb) and not private.can_manage(rb));
  perform pg_temp.as_user(cu);
  r := r || pg_temp.m('customer: neither', not private.is_member(rb) and not private.can_manage(rb) and private.member_role(rb) is null);
  perform pg_temp.as_user(si);
  r := r || pg_temp.m('deactivated member: neither', not private.is_member(rb) and not private.can_manage(rb));
  perform pg_temp.as_user(cm);
  r := r || pg_temp.m('member of a PENDING restaurant has no rights yet', not private.is_member(rc) and not private.can_manage(rc));
  perform pg_temp.as_user(ad);
  r := r || pg_temp.m('platform admin: member and manager of every restaurant, even pending ones',
    private.is_member(rb) and private.can_manage(rb) and private.is_member(rc) and private.can_manage(1));
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('anonymous cannot call the helpers', 'select private.is_member(1)', '42501');

  ---------- who can see which restaurants ----------
  perform pg_temp.as_anon();
  r := r || pg_temp.m('anonymous sees active restaurants only (not the pending one)',
    exists (select 1 from public.restaurants where id = 1) and exists (select 1 from public.restaurants where id = rb)
    and not exists (select 1 from public.restaurants where id = rc));
  perform pg_temp.as_user(cu);
  r := r || pg_temp.m('an unrelated customer cannot see the pending restaurant', not exists (select 1 from public.restaurants where id = rc));
  perform pg_temp.as_user(ap);
  r := r || pg_temp.m('the applicant can see their own pending restaurant', exists (select 1 from public.restaurants where id = rc));
  perform pg_temp.as_user(cm);
  r := r || pg_temp.m('its member can see it too', exists (select 1 from public.restaurants where id = rc));
  perform pg_temp.as_user(ad);
  r := r || pg_temp.m('platform admin sees everything', (select count(*) from public.restaurants) >= 3);

  ---------- who can change restaurants and teams ----------
  perform pg_temp.as_user(cu);
  r := r || pg_temp.expect('customer cannot create a restaurant directly', $q$insert into public.restaurants (name, slug) values ('Sneaky', 'sneaky')$q$, '42501');
  perform pg_temp.as_user(ow);
  r := r || pg_temp.expect('owner cannot approve or edit the restaurant row directly (functions come in Phase 4)',
    format('update public.restaurants set commission_percent = 50 where id = %s', rb), 'ok');
  r := r || pg_temp.m('...and nothing changed (the policy hid the row from the update)',
    (select commission_percent from public.restaurants where id = rb) = 0);
  r := r || pg_temp.expect('owner cannot add team members directly', format('insert into public.restaurant_members values (%s, %L, %L)', rb, cu, 'staff'), '42501');
  perform pg_temp.as_user(sf);
  r := r || pg_temp.expect('staff cannot add team members', format('insert into public.restaurant_members values (%s, %L, %L)', rb, cu, 'staff'), '42501');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('platform admin can add team members', format('insert into public.restaurant_members values (%s, %L, %L)', rb, cu, 'staff'), 'ok');
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('anonymous cannot read team lists', 'select count(*) from public.restaurant_members', '42501');

  ---------- who can read teams ----------
  perform pg_temp.as_user(mg);
  r := r || pg_temp.m('a manager sees the whole team of their restaurant', (select count(*) from public.restaurant_members where restaurant_id = rb) >= 5);
  r := r || pg_temp.m('...but not the team of another restaurant', (select count(*) from public.restaurant_members where restaurant_id = rc) = 0);
  perform pg_temp.as_user(sf);
  r := r || pg_temp.m('staff see only their own membership row', (select count(*) from public.restaurant_members) = 1);

  perform pg_temp.as_su();
  select count(*) into fails from unnest(r) x where x like 'FAIL%';
  raise exception E'TEST REPORT\nFAILURES: %\nTOTAL: %\n%', fails, array_length(r, 1), array_to_string(r, E'\n');
end $$;
