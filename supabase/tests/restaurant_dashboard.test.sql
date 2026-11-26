-- Tests for version 2, Phase 4b: what a restaurant's own team can do (profile, open switch, fee, team). Run the WHOLE file;
-- everything is rolled back and the error at the bottom is the report ("FAILURES: 0" = all good).
do $$
declare
  r text[] := '{}';
  ad uuid := gen_random_uuid(); oa uuid := gen_random_uuid(); ma uuid := gen_random_uuid(); sa uuid := gen_random_uuid();
  ob uuid := gen_random_uuid(); mb uuid := gen_random_uuid(); cu uuid := gen_random_uuid(); nw uuid := gen_random_uuid(); rd uuid := gen_random_uuid();
  ra bigint; rb bigint; n int; v jsonb; e_nw text; e_rd text; e_cu text;
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
  from (values (ad,'Ann'),(oa,'OwnA'),(ma,'MgrA'),(sa,'StaffA'),(ob,'OwnB'),(mb,'MgrB'),(cu,'Cy'),(nw,'New'),(rd,'Rita')) t(u, nm);
  update public.profiles set role = 'admin' where id = ad;
  update public.profiles set role = 'staff' where id in (oa, ma, sa, ob, mb);
  update public.profiles set role = 'rider' where id = rd;
  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by) values ('Alpha Grill', 'd-alpha', 'active', 200, oa) returning id into ra;
  insert into public.restaurants (name, slug, status, base_delivery_fee, created_by) values ('Beta Kitchen', 'd-beta', 'active', 500, ob) returning id into rb;
  insert into public.restaurant_members values (ra, oa, 'owner'), (ra, ma, 'manager'), (ra, sa, 'staff'), (rb, ob, 'owner'), (rb, mb, 'manager');

  -- emails are read here, as the superuser: the test users themselves may not read auth.users
  select email into e_nw from auth.users where id = nw;
  select email into e_rd from auth.users where id = rd;
  select email into e_cu from auth.users where id = cu;

  ---------- my restaurants ----------
  perform pg_temp.as_user(oa);
  v := public.list_my_restaurants();
  r := r || pg_temp.m('owner A sees only restaurant A, with the role', jsonb_array_length(v) = 1 and v -> 0 ->> 'id' = ra::text and v -> 0 ->> 'member_role' = 'owner');
  perform pg_temp.as_user(cu);
  r := r || pg_temp.m('a customer works for nobody', jsonb_array_length(public.list_my_restaurants()) = 0);
  perform pg_temp.as_anon();
  r := r || pg_temp.expect('anonymous cannot list', 'select public.list_my_restaurants()', '42501');

  ---------- profile ----------
  perform pg_temp.as_user(ma);
  r := r || pg_temp.expect('manager A edits A', format('select public.update_restaurant_profile(%s, %L, %L, %L, %L, %L)', ra, ' Alpha Grill 2 ', 'Best grill', '0801', '1 Main St', 'https://img.example/x.png'), 'ok');
  r := r || pg_temp.m('...saved and trimmed, slug unchanged', (select name = 'Alpha Grill 2' and slug = 'd-alpha' and logo_url = 'https://img.example/x.png' from public.restaurants where id = ra));
  r := r || pg_temp.expect('manager A cannot edit B', format('select public.update_restaurant_profile(%s, %L, %L, %L, %L, %L)', rb, 'Hacked', null, '1', '1', null), '42501');
  r := r || pg_temp.expect('a one-letter name is refused', format('select public.update_restaurant_profile(%s, %L, %L, %L, %L, %L)', ra, 'A', null, '1', '1', null), '22023');
  r := r || pg_temp.expect('an http logo link is refused', format('select public.update_restaurant_profile(%s, %L, %L, %L, %L, %L)', ra, 'Alpha', null, '1', '1', 'http://x.png'), '22023');
  r := r || pg_temp.expect('a javascript: logo link is refused', format('select public.update_restaurant_profile(%s, %L, %L, %L, %L, %L)', ra, 'Alpha', null, '1', '1', 'javascript:alert(1)'), '22023');
  perform pg_temp.as_user(sa);
  r := r || pg_temp.expect('staff A cannot edit the profile', format('select public.update_restaurant_profile(%s, %L, %L, %L, %L, %L)', ra, 'Alpha', null, '1', '1', null), '42501');

  ---------- open / closed ----------
  r := r || pg_temp.expect('staff A can close A', format('select public.set_restaurant_open(%s, false)', ra), 'ok');
  r := r || pg_temp.m('...and the public list shows it closed', exists (select 1 from jsonb_array_elements(public.list_restaurants()) e where (e ->> 'id')::bigint = ra and (e ->> 'is_open')::boolean = false));
  r := r || pg_temp.expect('staff A cannot touch B''s switch', format('select public.set_restaurant_open(%s, false)', rb), '42501');
  perform pg_temp.as_user(cu);
  r := r || pg_temp.expect('a customer cannot close a restaurant', format('select public.set_restaurant_open(%s, false)', ra), '42501');
  perform pg_temp.as_su();
  update public.restaurants set status = 'suspended' where id = rb;
  perform pg_temp.as_user(ob);
  r := r || pg_temp.expect('a suspended restaurant''s owner cannot flip the switch', format('select public.set_restaurant_open(%s, true)', rb), '42501');
  perform pg_temp.as_su();
  update public.restaurants set status = 'active' where id = rb;

  ---------- delivery fee ----------
  perform pg_temp.as_user(ma);
  r := r || pg_temp.expect('manager A sets the fee of A', format('select public.admin_set_delivery_fee(%s, 350)', ra), 'ok');
  r := r || pg_temp.m('...read back', (public.get_delivery_settings(ra) ->> 'base_fee')::numeric = 350);
  r := r || pg_temp.expect('manager A cannot set the fee of B', format('select public.admin_set_delivery_fee(%s, 1)', rb), '42501');
  r := r || pg_temp.expect('manager A cannot read B''s settings', format('select public.get_delivery_settings(%s)', rb), '42501');
  r := r || pg_temp.expect('a negative fee is refused', format('select public.admin_set_delivery_fee(%s, -5)', ra), '22023');
  perform pg_temp.as_user(sa);
  r := r || pg_temp.expect('staff A cannot set the fee', format('select public.admin_set_delivery_fee(%s, 1)', ra), '42501');

  ---------- team ----------
  perform pg_temp.as_user(ma);
  v := public.list_restaurant_team(ra);
  r := r || pg_temp.m('manager A sees the 3 members of A, owner first', jsonb_array_length(v) = 3 and v -> 0 ->> 'member_role' = 'owner');
  r := r || pg_temp.expect('manager A cannot see the team of B', format('select public.list_restaurant_team(%s)', rb), '42501');
  perform pg_temp.as_user(sa);
  r := r || pg_temp.expect('staff A cannot see the team list', format('select public.list_restaurant_team(%s)', ra), '42501');
  perform pg_temp.as_user(ma);
  r := r || pg_temp.expect('add a staff member by email', format('select public.add_restaurant_member_by_email(%s, %L, %L)', ra, e_nw, 'staff'), 'ok');
  r := r || pg_temp.m('...they are on team A', exists (select 1 from public.restaurant_members where restaurant_id = ra and user_id = nw));
  r := r || pg_temp.expect('adding the same email again is refused', format('select public.add_restaurant_member_by_email(%s, %L, %L)', ra, e_nw, 'staff'), '55000');
  r := r || pg_temp.expect('an unknown email gets the generic answer', format('select public.add_restaurant_member_by_email(%s, %L, %L)', ra, 'nobody@notify-check.dev', 'staff'), '22023');
  r := r || pg_temp.expect('a rider email gets the SAME answer (no account probing)', format('select public.add_restaurant_member_by_email(%s, %L, %L)', ra, e_rd, 'staff'), '22023');
  r := r || pg_temp.expect('a manager cannot appoint a manager', format('select public.add_restaurant_member_by_email(%s, %L, %L)', ra, e_cu, 'manager'), '42501');
  r := r || pg_temp.expect('a manager cannot add people to B', format('select public.add_restaurant_member_by_email(%s, %L, %L)', rb, e_cu, 'staff'), '42501');

  ---------- removing ----------
  r := r || pg_temp.expect('manager A cannot remove themselves', format('select public.remove_restaurant_member(%s, %L)', ra, ma), '55000');
  r := r || pg_temp.expect('manager A cannot remove the owner', format('select public.remove_restaurant_member(%s, %L)', ra, oa), '42501');
  r := r || pg_temp.expect('manager A cannot remove someone from B', format('select public.remove_restaurant_member(%s, %L)', rb, mb), '42501');
  r := r || pg_temp.expect('removing a non-member', format('select public.remove_restaurant_member(%s, %L)', ra, cu), 'P0002');
  r := r || pg_temp.expect('manager A removes the new staff member', format('select public.remove_restaurant_member(%s, %L)', ra, nw), 'ok');
  perform pg_temp.as_su();
  r := r || pg_temp.m('...they are off the team and back to a customer account', not exists (select 1 from public.restaurant_members where user_id = nw) and (select role = 'customer' from public.profiles where id = nw));
  perform pg_temp.as_user(sa);
  r := r || pg_temp.expect('staff cannot remove anyone', format('select public.remove_restaurant_member(%s, %L)', ra, ma), '42501');
  perform pg_temp.as_user(oa);
  r := r || pg_temp.expect('the owner removes a manager', format('select public.remove_restaurant_member(%s, %L)', ra, ma), 'ok');
  r := r || pg_temp.expect('the owner cannot remove an owner (even themselves)', format('select public.remove_restaurant_member(%s, %L)', ra, oa), '55000');
  perform pg_temp.as_user(ad);
  r := r || pg_temp.expect('the platform admin can remove an owner', format('select public.remove_restaurant_member(%s, %L)', ra, oa), 'ok');

  perform pg_temp.as_su();
  select count(*) into n from unnest(r) x where x like 'FAIL%';
  raise exception E'TEST REPORT\nFAILURES: %\nTOTAL: %\n%', n, array_length(r, 1), array_to_string(r, E'\n');
end $$;
