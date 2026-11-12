-- 014: v2 Phase 2 addendum: team management through a function (not direct inserts), scoped to ONE restaurant.
-- Staff cannot add anyone. A manager adds staff; an owner also adds managers; only a platform admin appoints owners.
-- (Direct inserts into restaurant_members stay admin-only, so nobody can skip these rules.)
create function public.add_restaurant_member(p_restaurant bigint, p_user uuid, p_role public.restaurant_member_role)
returns void language plpgsql security definer set search_path = '' as $$
declare v_admin boolean := (select private.is_admin()); v_my public.restaurant_member_role; v_target public.app_role;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_restaurant is null or p_user is null or p_role is null then
    raise exception 'restaurant, user and role are required' using errcode = '22023';
  end if;
  if not private.can_manage(p_restaurant) then
    raise exception 'Only an owner or manager of this restaurant can add team members' using errcode = '42501';
  end if;
  v_my := private.member_role(p_restaurant);
  if p_role = 'owner' and not v_admin then
    raise exception 'Only a platform admin can appoint an owner' using errcode = '42501';
  end if;
  if p_role = 'manager' and not v_admin and v_my is distinct from 'owner' then
    raise exception 'Only an owner can appoint a manager' using errcode = '42501';
  end if;
  select role into v_target from public.profiles where id = p_user and is_active;
  if not found or v_target not in ('customer', 'staff') then
    raise exception 'That user cannot join a restaurant team' using errcode = '22023';
  end if;
  insert into public.restaurant_members (restaurant_id, user_id, member_role) values (p_restaurant, p_user, p_role)
  on conflict do nothing;
  if not found then raise exception 'That user is already on this team' using errcode = '55000'; end if;
end $$;
revoke execute on function public.add_restaurant_member(bigint, uuid, public.restaurant_member_role) from public, anon;
grant  execute on function public.add_restaurant_member(bigint, uuid, public.restaurant_member_role) to authenticated, service_role;
