-- Phase 5c: an owner/manager's own restaurant list also carries its two commission rates (read-only; only the admin can change them),
-- so the Sales tab can say what the platform keeps. Same function, same grants, two more keys.
create or replace function public.list_my_restaurants() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'slug', r.slug, 'status', r.status, 'status_reason', r.status_reason,
             'is_open', r.is_open, 'description', r.description, 'phone', r.phone, 'address', r.address, 'logo_url', r.logo_url,
             'base_delivery_fee', r.base_delivery_fee::text, 'member_role', m.member_role,
             'commission_percent', r.commission_percent, 'delivery_commission_percent', r.delivery_commission_percent) order by r.name)
    from public.restaurant_members m join public.restaurants r on r.id = m.restaurant_id
    where m.user_id = (select auth.uid())
  ), '[]'::jsonb);
end $$;
