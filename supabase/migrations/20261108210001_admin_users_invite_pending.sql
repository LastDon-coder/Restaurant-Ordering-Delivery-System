-- 009: show which users were invited but have not accepted yet (so an admin can resend the invite).
-- The return type changes, so the function is dropped and recreated (grants repeated below).
drop function public.admin_list_users(text);

create function public.admin_list_users(p_search text default null)
returns table (id uuid, email text, first_name text, last_name text, phone text,
               role public.app_role, is_active boolean, created_at timestamptz, invite_pending boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only an admin can manage users' using errcode = '42501'; end if;
  return query
    select p.id, u.email::text, p.first_name, p.last_name, p.phone, p.role, p.is_active, p.created_at,
           (u.invited_at is not null and u.last_sign_in_at is null) as invite_pending
    from public.profiles p join auth.users u on u.id = p.id
    where p_search is null or trim(p_search) = ''
       or u.email ilike '%' || replace(replace(trim(p_search), '%', ''), '_', '') || '%'
       or (p.first_name || ' ' || p.last_name) ilike '%' || replace(replace(trim(p_search), '%', ''), '_', '') || '%'
    order by p.created_at desc
    limit 100;
end $$;

revoke execute on function public.admin_list_users(text) from public, anon;
grant execute on function public.admin_list_users(text) to authenticated;
