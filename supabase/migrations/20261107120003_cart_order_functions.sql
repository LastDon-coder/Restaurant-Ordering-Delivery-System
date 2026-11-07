-- 003: server-side business logic as SQL functions (the Supabase equivalent of the Express services).
-- WHY: clients can't write orders/payments directly, so every price, total and status rule is enforced here,
-- inside ONE transaction per call (a function body is atomic).
-- Error codes map to HTTP in the frontend: 28000=401, 42501=403, P0002=404, 22023=400, 55000=409.

create function private.delivery_fee() returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce((select s.value::numeric from private.settings s where s.key = 'delivery_fee'), 0)::numeric(10,2) $$;

create function private.allowed_next(s public.order_status) returns public.order_status[]
language sql immutable set search_path = '' as $$
  select case s
    when 'pending'            then array['confirmed','rejected','cancelled']::public.order_status[]
    when 'confirmed'          then array['preparing','cancelled']::public.order_status[]
    when 'preparing'          then array['ready_for_delivery','cancelled']::public.order_status[]
    when 'ready_for_delivery' then array['out_for_delivery','cancelled']::public.order_status[]
    when 'out_for_delivery'   then array['delivered','failed']::public.order_status[]
    else array[]::public.order_status[] end $$;

-- The cart with LIVE prices. Sold-out lines are shown (is_available=false) but excluded from totals.
create function public.get_cart() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid   uuid := (select auth.uid());
  v_items jsonb; v_sub numeric(12,2); v_count integer; v_fee numeric(10,2);
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if (select private.user_role()) is distinct from 'customer' then
    raise exception 'Only customers have a cart' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', ci.id, 'food_id', f.id, 'food_name', f.food_name, 'image_url', f.image_url,
           'price', f.price::text, 'quantity', ci.quantity,
           'line_total', (ci.quantity * f.price)::numeric(12,2)::text,
           'is_available', (f.is_available and cat.status = 'active')) order by ci.id), '[]'::jsonb),
         coalesce(sum(ci.quantity * f.price) filter (where f.is_available and cat.status = 'active'), 0),
         coalesce(sum(ci.quantity) filter (where f.is_available and cat.status = 'active'), 0)
    into v_items, v_sub, v_count
  from public.carts c
  join public.cart_items ci on ci.cart_id = c.id
  join public.food_items f on f.id = ci.food_id
  join public.categories cat on cat.id = f.category_id
  where c.user_id = v_uid;

  v_fee := case when v_sub > 0 then private.delivery_fee() else 0 end;
  return jsonb_build_object('items', v_items, 'summary', jsonb_build_object(
    'subtotal', v_sub::text, 'delivery_fee', v_fee::text, 'discount', '0.00',
    'total', (v_sub + v_fee)::numeric(12,2)::text, 'item_count', v_count));
end $$;

-- Adds quantity (merging into an existing line). SECURITY INVOKER: RLS still applies, so a customer can
-- only ever touch their own cart and only foods they can see (available, active category).
create function public.add_to_cart(p_food_id bigint, p_quantity integer default 1) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_cart bigint; v_existing integer;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if (select private.user_role()) is distinct from 'customer' then
    raise exception 'Only customers have a cart' using errcode = '42501';
  end if;
  if p_food_id is null or p_quantity is null or p_quantity < 1 or p_quantity > 50 then
    raise exception 'Quantity must be between 1 and 50' using errcode = '22023';
  end if;
  if not exists (select 1 from public.food_items f join public.categories c on c.id = f.category_id
                 where f.id = p_food_id and f.is_available and c.status = 'active') then
    raise exception 'Food item not found or unavailable' using errcode = 'P0002';
  end if;

  insert into public.carts (user_id) values (v_uid) on conflict (user_id) do nothing;
  select id into v_cart from public.carts where user_id = v_uid;

  select quantity into v_existing from public.cart_items
   where cart_id = v_cart and food_id = p_food_id for update;       -- serialises double-clicks
  if found and v_existing + p_quantity > 50 then
    raise exception 'You can order at most 50 of one item' using errcode = '22023';
  end if;

  insert into public.cart_items (cart_id, food_id, quantity) values (v_cart, p_food_id, p_quantity)
  on conflict (cart_id, food_id) do update set quantity = public.cart_items.quantity + excluded.quantity;

  return public.get_cart();
end $$;

-- Cart -> order in ONE transaction: re-prices from food_items, locks the foods, snapshots name+price,
-- creates address + order + items + payment + history, then empties the cart. Returns the new order id.
create function public.place_order(p_address jsonb, p_payment_method public.payment_method) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_street text; v_city text; v_state text; v_landmark text;
  v_cart bigint; v_lines jsonb := '[]'::jsonb; v_line record;
  v_subtotal numeric(12,2) := 0; v_fee numeric(10,2); v_total numeric(12,2);
  v_address bigint; v_order bigint;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if (select private.user_role()) is distinct from 'customer' then
    raise exception 'Only customers can place orders' using errcode = '42501';
  end if;
  if p_payment_method is null or p_payment_method not in ('online', 'cash_on_delivery') then
    raise exception 'Choose online payment or cash on delivery' using errcode = '22023';
  end if;
  if p_address is null or jsonb_typeof(p_address) <> 'object' then
    raise exception 'A delivery address is required' using errcode = '22023';
  end if;

  v_street   := nullif(trim(p_address ->> 'street_address'), '');
  v_city     := nullif(trim(p_address ->> 'city'), '');
  v_state    := nullif(trim(p_address ->> 'state'), '');
  v_landmark := nullif(trim(p_address ->> 'landmark'), '');
  if v_street is null or v_city is null or v_state is null
     or length(v_street) > 255 or length(v_city) > 100 or length(v_state) > 100 or length(coalesce(v_landmark, '')) > 255 then
    raise exception 'Street address, city and state are required (street max 255, city/state max 100)' using errcode = '22023';
  end if;

  select id into v_cart from public.carts where user_id = v_uid for update;   -- blocks a parallel checkout
  if not found then raise exception 'Your cart is empty' using errcode = '22023'; end if;

  for v_line in
    select ci.food_id, ci.quantity, f.food_name, f.price, (f.is_available and cat.status = 'active') as ok
    from public.cart_items ci
    join public.food_items f on f.id = ci.food_id
    join public.categories cat on cat.id = f.category_id
    where ci.cart_id = v_cart
    order by f.id
    for share of f                                   -- price/availability can't change under us
  loop
    if not v_line.ok then
      raise exception '% is no longer available. Remove it from your cart.', v_line.food_name using errcode = '22023';
    end if;
    v_subtotal := v_subtotal + v_line.quantity * v_line.price;
    v_lines := v_lines || jsonb_build_object('food_id', v_line.food_id, 'food_name', v_line.food_name,
                                             'quantity', v_line.quantity, 'price', v_line.price);
  end loop;
  if jsonb_array_length(v_lines) = 0 then raise exception 'Your cart is empty' using errcode = '22023'; end if;

  v_fee := private.delivery_fee();
  v_total := v_subtotal + v_fee;

  insert into public.addresses (user_id, street_address, city, state, landmark)
  values (v_uid, v_street, v_city, v_state, v_landmark) returning id into v_address;

  insert into public.orders (user_id, address_id, subtotal, delivery_fee, discount, total_amount,
                             delivery_street_address, delivery_city, delivery_state, delivery_landmark)
  values (v_uid, v_address, v_subtotal, v_fee, 0, v_total, v_street, v_city, v_state, v_landmark)
  returning id into v_order;

  insert into public.order_items (order_id, food_id, food_name, quantity, price)
  select v_order, (l.value ->> 'food_id')::bigint, l.value ->> 'food_name',
         (l.value ->> 'quantity')::integer, (l.value ->> 'price')::numeric
  from jsonb_array_elements(v_lines) with ordinality as l(value, ord) order by l.ord;

  insert into public.payments (order_id, payment_method, amount) values (v_order, p_payment_method, v_total);
  insert into public.order_status_history (order_id, from_status, to_status, changed_by)
  values (v_order, null, 'pending', v_uid);

  delete from public.cart_items where cart_id = v_cart;
  return v_order;
end $$;

-- The ONLY way an order's status changes. Enforces the transition table, who may do what, required reasons,
-- the "online orders must be paid before confirming" rule, and marks COD paid on delivery.
create function public.change_order_status(p_order_id bigint, p_status public.order_status, p_reason text default null)
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
  if v_role <> 'customer' and p_status in ('rejected', 'cancelled', 'failed') and v_reason is null then
    raise exception 'A reason is required when the status is %', p_status using errcode = '22023';
  end if;
  if p_status = 'confirmed' and o.payment_method = 'online' and o.payment_status <> 'paid' then
    raise exception 'This is an online-payment order and it has not been paid yet' using errcode = '55000';
  end if;

  update public.orders set order_status = p_status where id = p_order_id;
  if p_status = 'delivered' and o.payment_method = 'cash_on_delivery' and o.payment_status = 'pending' then
    update public.payments set payment_status = 'paid', paid_at = now() where order_id = p_order_id;
  end if;
  insert into public.order_status_history (order_id, from_status, to_status, changed_by, reason)
  values (p_order_id, o.order_status, p_status, v_uid, v_reason);
end $$;
