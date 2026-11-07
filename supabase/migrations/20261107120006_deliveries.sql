-- 006 (Step 15): delivery management.
--  * admin/staff assign a rider (and may swap riders until pickup)
--  * the assigned rider marks picked_up (order -> out_for_delivery), then delivered or failed
--  * riders read their own jobs (with customer name/phone) through get_my_deliveries()
-- Error codes: 42501=403, P0002=404, 22023=400, 55000=409.

-- One place that changes an order's status + keeps payments/history consistent. NOT callable by clients:
-- it is only called from the SECURITY DEFINER functions below, which do their own permission checks.
create function private.apply_order_status(p_order_id bigint, p_to public.order_status, p_reason text, p_actor uuid)
returns void
language plpgsql set search_path = '' as $$
declare o record;
begin
  select ord.order_status, p.payment_method, p.payment_status into o
  from public.orders ord left join public.payments p on p.order_id = ord.id
  where ord.id = p_order_id for update of ord;
  if not found then raise exception 'Order not found' using errcode = 'P0002'; end if;

  update public.orders set order_status = p_to where id = p_order_id;
  if p_to = 'delivered' and o.payment_method = 'cash_on_delivery' and o.payment_status = 'pending' then
    update public.payments set payment_status = 'paid', paid_at = now() where order_id = p_order_id;   -- cash collected
  end if;
  insert into public.order_status_history (order_id, from_status, to_status, changed_by, reason)
  values (p_order_id, o.order_status, p_to, p_actor, p_reason);
end $$;
revoke execute on function private.apply_order_status(bigint, public.order_status, text, uuid) from public, anon, authenticated;

-- change_order_status, now delegating to apply_order_status. The three delivery moves belong to the rider;
-- only an admin may force them (e.g. a rider's phone died), and then the delivery row is kept in sync.
create or replace function public.change_order_status(p_order_id bigint, p_status public.order_status, p_reason text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_role public.app_role := (select private.user_role());
  v_reason text := nullif(trim(p_reason), '');
  o record;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if v_role is null or v_role not in ('admin', 'staff', 'customer') then
    raise exception 'You are not allowed to change order status' using errcode = '42501';
  end if;
  if length(coalesce(v_reason, '')) > 255 then
    raise exception 'Reason must be at most 255 characters' using errcode = '22023';
  end if;

  select ord.id, ord.user_id, ord.order_status, p.payment_method, p.payment_status into o
  from public.orders ord left join public.payments p on p.order_id = ord.id
  where ord.id = p_order_id for update of ord;
  if not found or (v_role = 'customer' and o.user_id <> v_uid) then
    raise exception 'Order not found' using errcode = 'P0002';
  end if;

  if not (p_status = any (private.allowed_next(o.order_status))) then
    raise exception 'Cannot change an order from % to %. Allowed next: %', o.order_status, p_status,
      coalesce(nullif(array_to_string(private.allowed_next(o.order_status), ', '), ''), 'none (this order is final)')
      using errcode = '55000';
  end if;
  if v_role = 'customer' and not (o.order_status = 'pending' and p_status = 'cancelled') then
    raise exception 'You are not allowed to make this status change' using errcode = '42501';
  end if;
  if v_role = 'staff' and p_status in ('out_for_delivery', 'delivered', 'failed') then
    raise exception 'The assigned rider (or an admin) makes this change' using errcode = '42501';
  end if;
  if v_role <> 'customer' and p_status in ('rejected', 'cancelled', 'failed') and v_reason is null then
    raise exception 'A reason is required when the status is %', p_status using errcode = '22023';
  end if;
  if p_status = 'confirmed' and o.payment_method = 'online' and o.payment_status <> 'paid' then
    raise exception 'This is an online-payment order and it has not been paid yet' using errcode = '55000';
  end if;

  perform private.apply_order_status(p_order_id, p_status, v_reason, v_uid);

  -- Admin override on a delivery: keep the delivery record in step with the order.
  if p_status in ('out_for_delivery', 'delivered', 'failed') then
    update public.deliveries set
      delivery_status = case p_status when 'out_for_delivery' then 'picked_up'::public.delivery_status
                                      when 'delivered' then 'delivered'::public.delivery_status
                                      else 'failed'::public.delivery_status end,
      picked_up_at = coalesce(picked_up_at, now()),
      delivered_at = case when p_status = 'delivered' then now() else delivered_at end
    where order_id = p_order_id;
  end if;
end $$;

-- Admin or staff assign a rider; allowed from "confirmed" until the rider picks up.
create function public.assign_rider(p_order_id bigint, p_rider_id uuid) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  o record; d record; v_delivery bigint;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_staff_or_admin()) then
    raise exception 'Only admin or staff can assign riders' using errcode = '42501';
  end if;
  if p_order_id is null or p_rider_id is null then
    raise exception 'order and rider are required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = p_rider_id and role = 'rider' and is_active) then
    raise exception 'That user is not an active rider' using errcode = '22023';
  end if;

  select id, order_status into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'Order not found' using errcode = 'P0002'; end if;
  if o.order_status not in ('confirmed', 'preparing', 'ready_for_delivery') then
    raise exception 'A rider can be assigned only while the order is confirmed, preparing or ready for delivery (now: %)', o.order_status
      using errcode = '55000';
  end if;

  select id, delivery_status into d from public.deliveries where order_id = p_order_id for update;
  if found then
    if d.delivery_status <> 'assigned' then
      raise exception 'The rider has already picked this order up' using errcode = '55000';
    end if;
    update public.deliveries set rider_id = p_rider_id, assigned_at = now() where id = d.id returning id into v_delivery;
  else
    insert into public.deliveries (order_id, rider_id) values (p_order_id, p_rider_id) returning id into v_delivery;
  end if;
  return v_delivery;
end $$;

-- The assigned rider (only) moves the delivery: assigned -> picked_up -> delivered | failed.
-- picked_up also sets the order to out_for_delivery; delivered/failed finish the order (COD becomes paid).
create function public.update_delivery_status(p_order_id bigint, p_status public.delivery_status, p_reason text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_reason text := nullif(trim(p_reason), '');
  d record;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if (select private.user_role()) is distinct from 'rider' then
    raise exception 'Only riders update deliveries' using errcode = '42501';
  end if;
  if length(coalesce(v_reason, '')) > 255 then
    raise exception 'Reason must be at most 255 characters' using errcode = '22023';
  end if;

  select dl.id, dl.delivery_status, o.order_status into d
  from public.deliveries dl join public.orders o on o.id = dl.order_id
  where dl.order_id = p_order_id and dl.rider_id = v_uid
  for update of dl, o;
  if not found then raise exception 'Delivery not found' using errcode = 'P0002'; end if;   -- also hides other riders' jobs

  if not ((d.delivery_status = 'assigned' and p_status = 'picked_up')
       or (d.delivery_status = 'picked_up' and p_status in ('delivered', 'failed'))) then
    raise exception 'Cannot change a delivery from % to %', d.delivery_status, p_status using errcode = '55000';
  end if;
  if p_status = 'failed' and v_reason is null then
    raise exception 'A reason is required when a delivery fails' using errcode = '22023';
  end if;
  if p_status = 'picked_up' and d.order_status <> 'ready_for_delivery' then
    raise exception 'The order is not ready for pickup yet (now: %)', d.order_status using errcode = '55000';
  end if;

  update public.deliveries set
    delivery_status = p_status,
    picked_up_at = case when p_status = 'picked_up' then now() else picked_up_at end,
    delivered_at = case when p_status = 'delivered' then now() else delivered_at end
  where id = d.id;

  perform private.apply_order_status(p_order_id,
    case p_status when 'picked_up' then 'out_for_delivery'::public.order_status
                  when 'delivered' then 'delivered'::public.order_status
                  else 'failed'::public.order_status end,
    v_reason, v_uid);
end $$;

-- A rider's open jobs with what they need on the road (customer name/phone, address, items, cash to collect).
create function public.get_my_deliveries() returns jsonb
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

revoke execute on function public.assign_rider(bigint, uuid), public.update_delivery_status(bigint, public.delivery_status, text),
  public.get_my_deliveries() from public, anon;
grant execute on function public.assign_rider(bigint, uuid), public.update_delivery_status(bigint, public.delivery_status, text),
  public.get_my_deliveries() to authenticated;
