-- 008: admin user management (list users, change role, activate/deactivate).
-- WHY: profiles.role / is_active are not writable by clients (column grants), so promoting someone to staff or
-- rider must go through admin-only SECURITY DEFINER functions. Safety rules live HERE, not in the UI:
--   * only an active admin may call them
--   * an admin cannot change or deactivate THEIR OWN account (prevents locking everyone out)
--   * a rider with unfinished deliveries cannot be demoted or deactivated (their jobs would be orphaned)
-- Error codes: 28000=401, 42501=403, P0002=404, 22023=400, 55000=409.

create function public.admin_list_users(p_search text default null)
returns table (id uuid, email text, first_name text, last_name text, phone text,
               role public.app_role, is_active boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only an admin can manage users' using errcode = '42501'; end if;
  return query
    select p.id, u.email::text, p.first_name, p.last_name, p.phone, p.role, p.is_active, p.created_at
    from public.profiles p join auth.users u on u.id = p.id
    where p_search is null or trim(p_search) = ''
       or u.email ilike '%' || replace(replace(trim(p_search), '%', ''), '_', '') || '%'
       or (p.first_name || ' ' || p.last_name) ilike '%' || replace(replace(trim(p_search), '%', ''), '_', '') || '%'
    order by p.created_at desc
    limit 100;
end $$;

create function public.admin_set_role(p_user uuid, p_role public.app_role) returns void
language plpgsql security definer set search_path = '' as $$
declare v_target record;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only an admin can change roles' using errcode = '42501'; end if;
  if p_user = (select auth.uid()) then
    raise exception 'You cannot change your own role' using errcode = '55000';
  end if;
  select id, role into v_target from public.profiles where id = p_user for update;
  if not found then raise exception 'User not found' using errcode = 'P0002'; end if;
  if v_target.role = 'rider' and p_role <> 'rider' and exists (
       select 1 from public.deliveries d where d.rider_id = p_user and d.delivery_status in ('assigned', 'picked_up')) then
    raise exception 'This rider still has unfinished deliveries. Reassign them first.' using errcode = '55000';
  end if;
  update public.profiles set role = p_role where id = p_user;
end $$;

create function public.admin_set_active(p_user uuid, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_target record;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only an admin can change accounts' using errcode = '42501'; end if;
  if p_active is null then raise exception 'active must be true or false' using errcode = '22023'; end if;
  if p_user = (select auth.uid()) then
    raise exception 'You cannot deactivate your own account' using errcode = '55000';
  end if;
  select id, role into v_target from public.profiles where id = p_user for update;
  if not found then raise exception 'User not found' using errcode = 'P0002'; end if;
  if not p_active and v_target.role = 'rider' and exists (
       select 1 from public.deliveries d where d.rider_id = p_user and d.delivery_status in ('assigned', 'picked_up')) then
    raise exception 'This rider still has unfinished deliveries. Reassign them first.' using errcode = '55000';
  end if;
  update public.profiles set is_active = p_active where id = p_user;
end $$;

revoke execute on function public.admin_list_users(text), public.admin_set_role(uuid, public.app_role),
  public.admin_set_active(uuid, boolean) from public, anon;
grant execute on function public.admin_list_users(text), public.admin_set_role(uuid, public.app_role),
  public.admin_set_active(uuid, boolean) to authenticated;
