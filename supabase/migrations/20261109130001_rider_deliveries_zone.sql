-- 009: riders also see the delivery area and fee on each job. Only two keys are added to the JSON that
-- get_my_deliveries() returns, so the signature and grants stay exactly as they were (CREATE OR REPLACE keeps them).
create or replace function public.get_my_deliveries() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if (select private.user_role()) is distinct from 'rider' then
    raise exception 'Only riders have deliveries' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'order_id', o.id, 'delivery_status', d.delivery_status, 'order_status', o.order_status,
      'assigned_at', d.assigned_at, 'total_amount', o.total_amount::text,
      'delivery_fee', o.delivery_fee::text, 'zone_name', o.delivery_zone_name,
      'payment_method', p.payment_method, 'payment_status', p.payment_status,
      'address', jsonb_build_object('street_address', o.delivery_street_address, 'city', o.delivery_city,
                                    'state', o.delivery_state, 'landmark', o.delivery_landmark),
      'customer', jsonb_build_object('name', cu.first_name || ' ' || cu.last_name, 'phone', cu.phone),
      'items', (select coalesce(jsonb_agg(jsonb_build_object('food_name', oi.food_name, 'quantity', oi.quantity) order by oi.id), '[]'::jsonb)
                from public.order_items oi where oi.order_id = o.id)
    ) order by d.assigned_at desc)
    from public.deliveries d
    join public.orders o on o.id = d.order_id
    join public.payments p on p.order_id = o.id
    join public.profiles cu on cu.id = o.user_id
    where d.rider_id = v_uid and d.delivery_status in ('assigned', 'picked_up')
  ), '[]'::jsonb);
end $$;
