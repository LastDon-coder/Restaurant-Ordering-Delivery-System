-- 013: version 2, Phase 2: security refactor. Every policy and function now asks "are you part of THIS restaurant?"
-- instead of "are you staff?". A platform admin keeps global access; owner/manager/staff get their own restaurant only.
--
-- WHY: after Phase 1 a v1 "staff" user could read and change orders of ANY restaurant. Row Level Security (RLS) is the
-- last line of defence, so the rule "same restaurant_id" lives in the database, not in the UI.
--
-- profiles.role = 'staff' is now only a label ("works at a restaurant"). Rights come from restaurant_members.
-- To keep v1 screens working, the public RPC signatures are unchanged; the new restaurant-aware variants (explicit
-- p_restaurant argument) arrive with the dashboards in Phase 4.

------------------------------------------------------------------------------------------------------------------
-- 1. Helpers
------------------------------------------------------------------------------------------------------------------
-- "Am I on the team of ANY active restaurant (or a platform admin)?" Used as a cheap early gate in RPCs.
create function private.is_any_member() returns boolean
language sql stable security definer set search_path = '' as $$
  select (select private.is_admin()) or exists (
    select 1
    from public.restaurant_members m
    join public.restaurants r on r.id = m.restaurant_id and r.status = 'active'
    join public.profiles p on p.id = m.user_id and p.is_active
    where m.user_id = (select auth.uid()))
$$;

-- Which restaurant does a manager mean? Explicit id = must be allowed to manage it. No id = the only one they manage
-- (v1 screens never pass one). Several choices = ask the caller to be explicit.
create function private.resolve_restaurant(p_restaurant bigint) returns bigint
language plpgsql stable security definer set search_path = '' as $$
declare v_ids bigint[];
begin
  if p_restaurant is not null then
    if not private.can_manage(p_restaurant) then
      raise exception 'You cannot manage this restaurant' using errcode = '42501';
    end if;
    return p_restaurant;
  end if;
  select array_agg(r.id order by r.id) into v_ids from public.restaurants r where private.can_manage(r.id);
  if coalesce(array_length(v_ids, 1), 0) = 0 then
    raise exception 'You do not manage a restaurant' using errcode = '42501';
  elsif array_length(v_ids, 1) > 1 then
    raise exception 'Choose which restaurant you mean' using errcode = '22023';
  end if;
  return v_ids[1];
end $$;

revoke execute on function private.is_any_member(), private.resolve_restaurant(bigint) from public, anon;
grant  execute on function private.is_any_member(), private.resolve_restaurant(bigint) to authenticated, service_role;

------------------------------------------------------------------------------------------------------------------
-- 2. restaurant_id: no more DEFAULT 1. A new row takes the manager's own restaurant (v1 forms send none); the
--    restaurant can never be changed afterwards.
------------------------------------------------------------------------------------------------------------------
alter table public.categories     alter column restaurant_id drop default;
alter table public.food_items     alter column restaurant_id drop default;
alter table public.delivery_zones alter column restaurant_id drop default;
alter table public.orders         alter column restaurant_id drop default;

create function private.fill_restaurant_id() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.restaurant_id is null then new.restaurant_id := private.resolve_restaurant(null); end if;
  return new;
end $$;
create function private.lock_restaurant_id() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.restaurant_id is distinct from old.restaurant_id then
    raise exception 'A row cannot be moved to another restaurant' using errcode = '55000';
  end if;
  return new;
end $$;
revoke execute on function private.fill_restaurant_id(), private.lock_restaurant_id() from public, anon;
grant  execute on function private.fill_restaurant_id(), private.lock_restaurant_id() to authenticated, service_role;

create trigger trg_categories_fill_restaurant     before insert on public.categories     for each row execute function private.fill_restaurant_id();
create trigger trg_food_items_fill_restaurant     before insert on public.food_items     for each row execute function private.fill_restaurant_id();
create trigger trg_delivery_zones_fill_restaurant before insert on public.delivery_zones for each row execute function private.fill_restaurant_id();
create trigger trg_categories_lock_restaurant     before update of restaurant_id on public.categories     for each row execute function private.lock_restaurant_id();
create trigger trg_food_items_lock_restaurant     before update of restaurant_id on public.food_items     for each row execute function private.lock_restaurant_id();
create trigger trg_delivery_zones_lock_restaurant before update of restaurant_id on public.delivery_zones for each row execute function private.lock_restaurant_id();
create trigger trg_orders_lock_restaurant         before update of restaurant_id on public.orders         for each row execute function private.lock_restaurant_id();

-- Names are unique per restaurant now (the per-restaurant indexes were added in Phase 1); drop the global ones.
alter table public.categories drop constraint categories_category_name_key;
drop index public.uq_delivery_zones_name;

------------------------------------------------------------------------------------------------------------------
-- 3. Cart keeps itself tidy: first item sets carts.restaurant_id, removing the last item clears it.
------------------------------------------------------------------------------------------------------------------
create function private.trg_cart_items_sync() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    update public.carts c set restaurant_id = (select f.restaurant_id from public.food_items f where f.id = new.food_id)
    where c.id = new.cart_id and c.restaurant_id is null;
  else
    update public.carts c set restaurant_id = null
    where c.id = old.cart_id and not exists (select 1 from public.cart_items i where i.cart_id = old.cart_id);
  end if;
  return null;
end $$;
revoke execute on function private.trg_cart_items_sync() from public, anon, authenticated;
create trigger trg_cart_items_sync after insert or delete on public.cart_items for each row execute function private.trg_cart_items_sync();

------------------------------------------------------------------------------------------------------------------
-- 4. Policies
------------------------------------------------------------------------------------------------------------------
-- categories
drop policy categories_admin_all   on public.categories;
drop policy categories_public_read on public.categories;
create policy categories_public_read on public.categories for select to anon, authenticated
  using (status = 'active' and exists (select 1 from public.restaurants r where r.id = categories.restaurant_id and r.status = 'active'));
create policy categories_member_read on public.categories for select to authenticated
  using (private.is_member(restaurant_id));
create policy categories_manage on public.categories for all to authenticated
  using (private.can_manage(restaurant_id)) with check (private.can_manage(restaurant_id));

-- food_items
drop policy food_admin_all   on public.food_items;
drop policy food_public_read on public.food_items;
drop policy food_staff_read  on public.food_items;
create policy food_public_read on public.food_items for select to anon, authenticated
  using (is_available
         and exists (select 1 from public.categories c where c.id = food_items.category_id and c.status = 'active')
         and exists (select 1 from public.restaurants r where r.id = food_items.restaurant_id and r.status = 'active'));
create policy food_member_read on public.food_items for select to authenticated
  using (private.is_member(restaurant_id));
create policy food_manage on public.food_items for all to authenticated
  using (private.can_manage(restaurant_id)) with check (private.can_manage(restaurant_id));

-- delivery_zones
drop policy zones_admin_all   on public.delivery_zones;
drop policy zones_read_active on public.delivery_zones;
create policy zones_read_active on public.delivery_zones for select to authenticated
  using (is_active and exists (select 1 from public.restaurants r where r.id = delivery_zones.restaurant_id and r.status = 'active'));
create policy zones_member_read on public.delivery_zones for select to authenticated
  using (private.is_member(restaurant_id));
create policy zones_manage on public.delivery_zones for all to authenticated
  using (private.can_manage(restaurant_id)) with check (private.can_manage(restaurant_id));

-- orders, deliveries
drop policy orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated
  using (user_id = (select auth.uid())
         or private.is_member(restaurant_id)
         or exists (select 1 from public.deliveries d where d.order_id = orders.id and d.rider_id = (select auth.uid())));
drop policy deliveries_select on public.deliveries;
create policy deliveries_select on public.deliveries for select to authenticated
  using (rider_id = (select auth.uid())
         or exists (select 1 from public.orders o where o.id = deliveries.order_id and private.is_member(o.restaurant_id)));

-- ratings, reviews, refunds: only the restaurant concerned (reviews and refunds: its managers)
drop policy order_ratings_staff on public.order_ratings;
create policy order_ratings_member on public.order_ratings for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_ratings.order_id and private.is_member(o.restaurant_id)));
drop policy food_reviews_admin on public.food_reviews;
create policy food_reviews_manager on public.food_reviews for select to authenticated
  using (exists (select 1 from public.food_items f where f.id = food_reviews.food_id and private.can_manage(f.restaurant_id)));
drop policy refunds_admin_select on public.payment_refunds;
create policy refunds_manager_select on public.payment_refunds for select to authenticated
  using (exists (select 1 from public.payments p join public.orders o on o.id = p.order_id
                 where p.id = payment_refunds.payment_id and private.can_manage(o.restaurant_id)));

-- profiles: yourself; admins; people who ordered from a restaurant you work for; riders (shared pool, needed to assign);
-- the team of a restaurant you manage.
drop policy profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid())
         or (select private.is_admin())
         or exists (select 1 from public.orders o where o.user_id = profiles.id and private.is_member(o.restaurant_id))
         or (profiles.role = 'rider' and (select private.is_any_member()))
         or exists (select 1 from public.restaurant_members m where m.user_id = profiles.id and private.can_manage(m.restaurant_id)));

-- cart_items: the food must belong to the cart's restaurant, and that restaurant must be active.
drop policy cart_items_insert on public.cart_items;
create policy cart_items_insert on public.cart_items for insert to authenticated
  with check ((select private.user_role()) = 'customer'
              and exists (select 1
                          from public.carts c
                          join public.food_items f on f.id = cart_items.food_id
                          join public.categories cat on cat.id = f.category_id
                          join public.restaurants r on r.id = f.restaurant_id
                          where c.id = cart_items.cart_id and c.user_id = (select auth.uid())
                            and f.is_available and cat.status = 'active' and r.status = 'active'
                            and (c.restaurant_id is null or c.restaurant_id = f.restaurant_id)));

------------------------------------------------------------------------------------------------------------------
-- 5. Cart and delivery pricing (per restaurant)
------------------------------------------------------------------------------------------------------------------
create or replace function public.add_to_cart(p_food_id bigint, p_quantity integer default 1)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_cart bigint; v_cart_rest bigint; v_rest bigint; v_existing integer;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if (select private.user_role()) is distinct from 'customer' then
    raise exception 'Only customers have a cart' using errcode = '42501';
  end if;
  if p_food_id is null or p_quantity is null or p_quantity < 1 or p_quantity > 50 then
    raise exception 'Quantity must be between 1 and 50' using errcode = '22023';
  end if;
  select f.restaurant_id into v_rest
  from public.food_items f
  join public.categories c on c.id = f.category_id
  join public.restaurants r on r.id = f.restaurant_id and r.status = 'active'
  where f.id = p_food_id and f.is_available and c.status = 'active';
  if v_rest is null then raise exception 'Food item not found or unavailable' using errcode = 'P0002'; end if;

  insert into public.carts (user_id) values (v_uid) on conflict (user_id) do nothing;
  select id, restaurant_id into v_cart, v_cart_rest from public.carts where user_id = v_uid;
  if v_cart_rest is not null and v_cart_rest <> v_rest then
    raise exception 'Your cart has items from another restaurant. Clear your cart before ordering from this one.' using errcode = '55000';
  end if;

  select quantity into v_existing from public.cart_items where cart_id = v_cart and food_id = p_food_id for update;
  if found and v_existing + p_quantity > 50 then
    raise exception 'You can order at most 50 of one item' using errcode = '22023';
  end if;

  insert into public.cart_items (cart_id, food_id, quantity) values (v_cart, p_food_id, p_quantity)
  on conflict (cart_id, food_id) do update set quantity = public.cart_items.quantity + excluded.quantity;

  return public.get_cart();
end $$;

create or replace function public.get_cart() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_items jsonb; v_sub numeric(12,2); v_count integer; v_fee numeric(10,2) := 0; v_rest bigint; v_rjson jsonb;
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

  select c.restaurant_id into v_rest from public.carts c where c.user_id = v_uid;
  if v_rest is not null then
    select jsonb_build_object('id', r.id, 'name', r.name, 'slug', r.slug, 'is_open', r.is_open, 'status', r.status),
           case when v_sub > 0 then r.base_delivery_fee else 0 end
      into v_rjson, v_fee
    from public.restaurants r where r.id = v_rest;
  end if;

  return jsonb_build_object('items', v_items, 'restaurant', v_rjson, 'summary', jsonb_build_object(
    'subtotal', v_sub::text, 'delivery_fee', v_fee::text, 'discount', '0.00',
    'total', (v_sub + v_fee)::numeric(12,2)::text, 'item_count', v_count));
end $$;

-- Fee for one restaurant (+ the area's extra fee). The area must belong to that same restaurant.
create function private.delivery_quote(p_restaurant bigint, p_zone_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_base numeric(10,2); z record;
begin
  select base_delivery_fee into v_base from public.restaurants where id = p_restaurant;
  if not found then raise exception 'Restaurant not found' using errcode = 'P0002'; end if;
  if p_zone_id is null then
    return jsonb_build_object('fee', v_base, 'zone_id', null, 'zone_name', null);
  end if;
  select id, zone_name, extra_fee into z from public.delivery_zones
   where id = p_zone_id and restaurant_id = p_restaurant and is_active for share;
  if not found then raise exception 'That delivery area is not available. Choose another area.' using errcode = '22023'; end if;
  return jsonb_build_object('fee', v_base + z.extra_fee, 'zone_id', z.id, 'zone_name', z.zone_name);
end $$;
revoke execute on function private.delivery_quote(bigint, bigint) from public, anon;
grant  execute on function private.delivery_quote(bigint, bigint) to authenticated, service_role;

create or replace function public.delivery_quote(p_zone_id bigint default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_cart jsonb; v_sub numeric(12,2); v_rest bigint; v_q jsonb; v_fee numeric(10,2) := 0; v_zone text;
begin
  v_cart := public.get_cart();
  v_sub  := (v_cart -> 'summary' ->> 'subtotal')::numeric;
  v_rest := (v_cart -> 'restaurant' ->> 'id')::bigint;
  if v_rest is not null and v_sub > 0 then
    v_q := private.delivery_quote(v_rest, p_zone_id);
    v_fee := (v_q ->> 'fee')::numeric;
    v_zone := v_q ->> 'zone_name';
  end if;
  return jsonb_build_object('subtotal', v_sub::text, 'delivery_fee', v_fee::text, 'zone_name', v_zone,
                            'total', (v_sub + v_fee)::numeric(12,2)::text, 'restaurant_id', v_rest);
end $$;

-- Same signatures as v1. They act on the restaurant the caller manages; explicit variants come in Phase 4.
create or replace function public.get_delivery_settings() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_r bigint;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  v_r := private.resolve_restaurant(null);
  return jsonb_build_object('base_fee', (select base_delivery_fee::text from public.restaurants where id = v_r), 'restaurant_id', v_r);
end $$;

create or replace function public.admin_set_delivery_fee(p_fee numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_r bigint;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  v_r := private.resolve_restaurant(null);
  if p_fee is null or p_fee < 0 or p_fee > 100000 or p_fee <> round(p_fee, 2) then
    raise exception 'Delivery fee must be between 0 and 100000, with at most 2 decimals' using errcode = '22023';
  end if;
  update public.restaurants set base_delivery_fee = p_fee where id = v_r;
  return jsonb_build_object('base_fee', p_fee::numeric(10,2)::text, 'restaurant_id', v_r);
end $$;

------------------------------------------------------------------------------------------------------------------
-- 6. place_order: the restaurant comes from the CART's food, never from the client.
------------------------------------------------------------------------------------------------------------------
create or replace function public.place_order(p_address jsonb, p_payment_method public.payment_method, p_zone_id bigint default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_street text; v_city text; v_state text; v_landmark text;
  v_cart bigint; v_lines jsonb := '[]'::jsonb; v_line record; v_rest bigint; v_rstat record;
  v_subtotal numeric(12,2) := 0; v_fee numeric(10,2); v_total numeric(12,2);
  v_address bigint; v_order bigint; v_quote jsonb;
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

  select id into v_cart from public.carts where user_id = v_uid for update;
  if not found then raise exception 'Your cart is empty' using errcode = '22023'; end if;

  for v_line in
    select ci.food_id, ci.quantity, f.food_name, f.price, f.restaurant_id, (f.is_available and cat.status = 'active') as ok
    from public.cart_items ci
    join public.food_items f on f.id = ci.food_id
    join public.categories cat on cat.id = f.category_id
    where ci.cart_id = v_cart
    order by f.id
    for share of f
  loop
    if v_rest is not null and v_line.restaurant_id <> v_rest then
      raise exception 'Your cart has items from more than one restaurant. Clear it and try again.' using errcode = '22023';
    end if;
    v_rest := v_line.restaurant_id;
    if not v_line.ok then
      raise exception '% is no longer available. Remove it from your cart.', v_line.food_name using errcode = '22023';
    end if;
    v_subtotal := v_subtotal + v_line.quantity * v_line.price;
    v_lines := v_lines || jsonb_build_object('food_id', v_line.food_id, 'food_name', v_line.food_name,
                                             'quantity', v_line.quantity, 'price', v_line.price);
  end loop;
  if jsonb_array_length(v_lines) = 0 then raise exception 'Your cart is empty' using errcode = '22023'; end if;

  select status, is_open into v_rstat from public.restaurants where id = v_rest for share;
  if not found or v_rstat.status <> 'active' then
    raise exception 'This restaurant is not taking orders' using errcode = '22023';
  end if;
  if not v_rstat.is_open then
    raise exception 'This restaurant is closed right now' using errcode = '22023';
  end if;

  v_quote := private.delivery_quote(v_rest, p_zone_id);
  v_fee := (v_quote ->> 'fee')::numeric;
  v_total := v_subtotal + v_fee;

  insert into public.addresses (user_id, street_address, city, state, landmark)
  values (v_uid, v_street, v_city, v_state, v_landmark) returning id into v_address;

  insert into public.orders (user_id, restaurant_id, address_id, subtotal, delivery_fee, discount, total_amount,
                             delivery_street_address, delivery_city, delivery_state, delivery_landmark,
                             delivery_zone_id, delivery_zone_name)
  values (v_uid, v_rest, v_address, v_subtotal, v_fee, 0, v_total, v_street, v_city, v_state, v_landmark,
          (v_quote ->> 'zone_id')::bigint, v_quote ->> 'zone_name')
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

------------------------------------------------------------------------------------------------------------------
-- 7. Order status, riders, reviews
------------------------------------------------------------------------------------------------------------------
create or replace function public.change_order_status(p_order_id bigint, p_status public.order_status, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_role public.app_role := (select private.user_role());
  v_reason text := nullif(trim(p_reason), '');
  v_team boolean; o record;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if v_role is null or v_role = 'rider' then
    raise exception 'You are not allowed to change order status' using errcode = '42501';
  end if;
  if length(coalesce(v_reason, '')) > 255 then
    raise exception 'Reason must be at most 255 characters' using errcode = '22023';
  end if;

  select ord.id, ord.user_id, ord.restaurant_id, ord.order_status, p.payment_method, p.payment_status into o
  from public.orders ord left join public.payments p on p.order_id = ord.id
  where ord.id = p_order_id for update of ord;
  v_team := found and private.is_member(o.restaurant_id);
  -- Not the customer and not on this restaurant's team: the order does not exist as far as you are concerned.
  if not found or not (v_team or o.user_id = v_uid) then
    raise exception 'Order not found' using errcode = 'P0002';
  end if;

  if not (p_status = any (private.allowed_next(o.order_status))) then
    raise exception 'Cannot change an order from % to %. Allowed next: %', o.order_status, p_status,
      coalesce(nullif(array_to_string(private.allowed_next(o.order_status), ', '), ''), 'none (this order is final)')
      using errcode = '55000';
  end if;
  if not v_team and not (o.order_status = 'pending' and p_status = 'cancelled') then
    raise exception 'You are not allowed to make this status change' using errcode = '42501';
  end if;
  if v_team and not (select private.is_admin()) and p_status in ('out_for_delivery', 'delivered', 'failed') then
    raise exception 'The assigned rider (or an admin) makes this change' using errcode = '42501';
  end if;
  if v_team and p_status in ('rejected', 'cancelled', 'failed') and v_reason is null then
    raise exception 'A reason is required when the status is %', p_status using errcode = '22023';
  end if;
  if p_status = 'confirmed' and o.payment_method = 'online' and o.payment_status <> 'paid' then
    raise exception 'This is an online-payment order and it has not been paid yet' using errcode = '55000';
  end if;

  perform private.apply_order_status(p_order_id, p_status, v_reason, v_uid);

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

create or replace function public.assign_rider(p_order_id bigint, p_rider_id uuid)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  o record; d record; v_delivery bigint;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_any_member()) then
    raise exception 'Only restaurant staff or an admin can assign riders' using errcode = '42501';
  end if;
  if p_order_id is null or p_rider_id is null then
    raise exception 'order and rider are required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = p_rider_id and role = 'rider' and is_active) then
    raise exception 'That user is not an active rider' using errcode = '22023';
  end if;

  select id, restaurant_id, order_status into o from public.orders where id = p_order_id for update;
  if not found or not private.is_member(o.restaurant_id) then
    raise exception 'Order not found' using errcode = 'P0002';
  end if;
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

create or replace function public.moderate_food_review(p_review_id bigint, p_status public.review_status)
returns void language plpgsql security definer set search_path = '' as $$
declare v_rest bigint;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_any_member()) then raise exception 'Only a restaurant manager or an admin can moderate reviews' using errcode = '42501'; end if;
  if p_status is null or p_status = 'pending' then
    raise exception 'Choose approved or hidden' using errcode = '22023';
  end if;
  select f.restaurant_id into v_rest from public.food_reviews fr join public.food_items f on f.id = fr.food_id where fr.id = p_review_id;
  if not found or not private.is_member(v_rest) then raise exception 'Review not found' using errcode = 'P0002'; end if;
  if not private.can_manage(v_rest) then raise exception 'Only a restaurant manager or an admin can moderate reviews' using errcode = '42501'; end if;
  update public.food_reviews set status = p_status, moderated_by = (select auth.uid()), moderated_at = now() where id = p_review_id;
end $$;

------------------------------------------------------------------------------------------------------------------
-- 8. Emails: the "new order" mail goes to THIS restaurant's team only.
------------------------------------------------------------------------------------------------------------------
create or replace function private.notify_order_received(p_order bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare v_email text; v_name text; r record;
begin
  select u.email, c.first_name into v_email, v_name
  from public.orders o join auth.users u on u.id = o.user_id join public.profiles c on c.id = o.user_id
  where o.id = p_order;
  if not private.mail_ok(v_email) then return; end if;

  perform private.enqueue_notification('received:' || p_order || ':customer', 'order_received', p_order, v_email, v_name);
  for r in
    select p.id, p.first_name, u.email
    from public.orders o
    join public.restaurant_members m on m.restaurant_id = o.restaurant_id
    join public.profiles p on p.id = m.user_id and p.is_active
    join auth.users u on u.id = p.id
    where o.id = p_order
  loop
    if private.mail_ok(r.email) then
      perform private.enqueue_notification('new:' || p_order || ':' || r.id, 'new_order', p_order, r.email, r.first_name);
    end if;
  end loop;
end $$;

------------------------------------------------------------------------------------------------------------------
-- 9. Fix (applied as 20261112_tenancy_fix_policy_recursion): orders_select looks at deliveries, so deliveries_select
--    must NOT look back at orders under RLS (infinite recursion, 42P17). A security-definer helper reads orders directly.
------------------------------------------------------------------------------------------------------------------
create function private.is_member_of_order(p_order bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.orders o where o.id = p_order and private.is_member(o.restaurant_id))
$$;
revoke execute on function private.is_member_of_order(bigint) from public, anon;
grant  execute on function private.is_member_of_order(bigint) to authenticated, service_role;
drop policy deliveries_select on public.deliveries;
create policy deliveries_select on public.deliveries for select to authenticated
  using (rider_id = (select auth.uid()) or private.is_member_of_order(order_id));
