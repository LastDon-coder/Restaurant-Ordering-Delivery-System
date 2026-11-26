-- Version 2, Phase 4b (step 2): what an owner / manager / staff member can do for THEIR restaurant.
-- Every function takes the restaurant explicitly and checks membership in the database (not in the UI).

-- The restaurants I work for (drives the dashboard's restaurant switcher).
create function public.list_my_restaurants() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'slug', r.slug, 'status', r.status, 'status_reason', r.status_reason,
             'is_open', r.is_open, 'description', r.description, 'phone', r.phone, 'address', r.address, 'logo_url', r.logo_url,
             'base_delivery_fee', r.base_delivery_fee::text, 'member_role', m.member_role) order by r.name)
    from public.restaurant_members m join public.restaurants r on r.id = m.restaurant_id
    where m.user_id = (select auth.uid())
  ), '[]'::jsonb);
end $$;

-- Name, description, contact details, logo. The slug (the public address) never changes here.
create function public.update_restaurant_profile(p_restaurant bigint, p_name text, p_description text, p_phone text, p_address text, p_logo_url text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_name text := btrim(p_name); v_desc text := nullif(btrim(p_description), ''); v_phone text := nullif(btrim(p_phone), '');
  v_addr text := nullif(btrim(p_address), ''); v_logo text := nullif(btrim(p_logo_url), '');
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_restaurant is null or not private.can_manage(p_restaurant) then raise exception 'You cannot manage this restaurant' using errcode = '42501'; end if;
  if v_name is null or length(v_name) not between 2 and 100 then raise exception 'Name must be 2 to 100 characters' using errcode = '22023'; end if;
  if v_phone is null or length(v_phone) > 30 or v_addr is null or length(v_addr) > 255 or length(coalesce(v_desc, '')) > 1000 then
    raise exception 'A phone number and an address are required (address max 255, about max 1000)' using errcode = '22023';
  end if;
  if v_logo is not null and (length(v_logo) > 500 or v_logo !~* '^https://') then
    raise exception 'The logo must be a link starting with https://' using errcode = '22023';
  end if;
  update public.restaurants set name = v_name, description = v_desc, phone = v_phone, address = v_addr, logo_url = v_logo where id = p_restaurant;
end $$;

-- The open / closed switch. Any team member may flip it (a shift lead closing the kitchen should not need a manager).
create function public.set_restaurant_open(p_restaurant bigint, p_open boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_open is null then raise exception 'open must be true or false' using errcode = '22023'; end if;
  if p_restaurant is null or not private.is_member(p_restaurant) then raise exception 'You are not on this restaurant''s team' using errcode = '42501'; end if;
  update public.restaurants set is_open = p_open where id = p_restaurant and status = 'active';
  if not found then raise exception 'Only a live restaurant can open or close' using errcode = '55000'; end if;
end $$;

-- Delivery fee for an explicit restaurant (the old no-restaurant versions only work for people who manage exactly one).
create function public.get_delivery_settings(p_restaurant bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_r bigint;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  v_r := private.resolve_restaurant(p_restaurant);
  return jsonb_build_object('base_fee', (select base_delivery_fee::text from public.restaurants where id = v_r), 'restaurant_id', v_r);
end $$;

create function public.admin_set_delivery_fee(p_restaurant bigint, p_fee numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_r bigint;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  v_r := private.resolve_restaurant(p_restaurant);
  if p_fee is null or p_fee < 0 or p_fee > 100000 or p_fee <> round(p_fee, 2) then
    raise exception 'Delivery fee must be between 0 and 100000, with at most 2 decimals' using errcode = '22023';
  end if;
  update public.restaurants set base_delivery_fee = p_fee where id = v_r;
  return jsonb_build_object('base_fee', p_fee::numeric(10,2)::text, 'restaurant_id', v_r);
end $$;

-- Team: list (owner / manager / admin), add by email, remove.
create function public.list_restaurant_team(p_restaurant bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_restaurant is null or not private.can_manage(p_restaurant) then raise exception 'You cannot manage this restaurant' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'member_role', m.member_role, 'name', btrim(concat_ws(' ', p.first_name, p.last_name)),
             'email', u.email, 'is_active', p.is_active, 'joined', m.created_at)
             order by case m.member_role when 'owner' then 0 when 'manager' then 1 else 2 end, m.created_at)
    from public.restaurant_members m join public.profiles p on p.id = m.user_id join auth.users u on u.id = m.user_id
    where m.restaurant_id = p_restaurant
  ), '[]'::jsonb);
end $$;

-- Same answer for "no such email" and "wrong kind of account": nobody can use this to find out who has an account.
create function public.add_restaurant_member_by_email(p_restaurant bigint, p_email text, p_role public.restaurant_member_role)
returns void language plpgsql security definer set search_path = '' as $$
declare v_user uuid;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_restaurant is null or not private.can_manage(p_restaurant) then raise exception 'You cannot manage this restaurant' using errcode = '42501'; end if;
  select u.id into v_user from auth.users u join public.profiles p on p.id = u.id
  where lower(u.email) = lower(btrim(p_email)) and p.is_active and p.role in ('customer', 'staff');
  if v_user is null then
    raise exception 'No customer or staff account with that email. Ask them to sign up first.' using errcode = '22023';
  end if;
  perform public.add_restaurant_member(p_restaurant, v_user, p_role);   -- applies the role rules (who may appoint whom)
end $$;

-- Removing: staff by any manager/owner, managers by an owner, owners only by the platform admin. Never yourself.
-- A person left with no team goes back to being a customer.
create function public.remove_restaurant_member(p_restaurant bigint, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_target public.restaurant_member_role; v_me public.restaurant_member_role; v_admin boolean := (select private.is_admin());
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_restaurant is null or not private.can_manage(p_restaurant) then raise exception 'You cannot manage this restaurant' using errcode = '42501'; end if;
  if p_user = (select auth.uid()) then raise exception 'You cannot remove yourself' using errcode = '55000'; end if;
  select member_role into v_target from public.restaurant_members where restaurant_id = p_restaurant and user_id = p_user for update;
  if not found then raise exception 'That person is not on this team' using errcode = 'P0002'; end if;
  v_me := private.member_role(p_restaurant);
  if v_target = 'owner' and not v_admin then raise exception 'Only the platform admin can remove an owner' using errcode = '42501'; end if;
  if v_target = 'manager' and not (v_admin or v_me = 'owner') then raise exception 'Only an owner can remove a manager' using errcode = '42501'; end if;
  delete from public.restaurant_members where restaurant_id = p_restaurant and user_id = p_user;
  if not exists (select 1 from public.restaurant_members where user_id = p_user) then
    update public.profiles set role = 'customer' where id = p_user and role = 'staff';
  end if;
end $$;

revoke execute on function public.list_my_restaurants(), public.update_restaurant_profile(bigint, text, text, text, text, text),
  public.set_restaurant_open(bigint, boolean), public.get_delivery_settings(bigint), public.admin_set_delivery_fee(bigint, numeric),
  public.list_restaurant_team(bigint), public.add_restaurant_member_by_email(bigint, text, public.restaurant_member_role),
  public.remove_restaurant_member(bigint, uuid) from public, anon;
grant execute on function public.list_my_restaurants(), public.update_restaurant_profile(bigint, text, text, text, text, text),
  public.set_restaurant_open(bigint, boolean), public.get_delivery_settings(bigint), public.admin_set_delivery_fee(bigint, numeric),
  public.list_restaurant_team(bigint), public.add_restaurant_member_by_email(bigint, text, public.restaurant_member_role),
  public.remove_restaurant_member(bigint, uuid) to authenticated, service_role;
