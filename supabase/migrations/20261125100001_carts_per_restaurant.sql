-- 015: version 2, Phase 3a (database): ONE CART PER RESTAURANT + public restaurant list.
-- A customer may have a basket open at several restaurants and checks each one out separately, so every order still has
-- exactly one restaurant, one fee, one payment and one team (no payment redesign needed).
--
-- WHY a cart per (user, restaurant): the unique key moves from (user_id) to (user_id, restaurant_id). The database itself
-- then guarantees "one basket per restaurant per person", and cart_items can only hold food of the cart's restaurant.
--
-- Old function signatures (get_cart(), delivery_quote(zone), place_order(address, method, zone)) keep working for a
-- customer who has ONE basket, so v1 screens and tests are untouched. New overloads take the restaurant explicitly and
-- deliberately have NO default values, so a call can never be ambiguous between the old and the new version.

------------------------------------------------------------------------------------------------------------------
-- 1. Carts belong to one restaurant, always
------------------------------------------------------------------------------------------------------------------
drop trigger trg_cart_items_sync on public.cart_items;          -- the restaurant is now set when the cart is created
drop function private.trg_cart_items_sync();

update public.carts set restaurant_id = 1 where restaurant_id is null;   -- v1 had a single restaurant
alter table public.carts drop constraint carts_restaurant_id_fkey;
alter table public.carts add constraint carts_restaurant_id_fkey
  foreign key (restaurant_id) references public.restaurants (id) on delete cascade;
alter table public.carts alter column restaurant_id set not null;
alter table public.carts drop constraint carts_user_id_key;
alter table public.carts add constraint carts_user_restaurant_key unique (user_id, restaurant_id);

-- Food can only be put into the cart of ITS OWN restaurant, and that restaurant must be active.
drop policy cart_items_insert on public.cart_items;
create policy cart_items_insert on public.cart_items for insert to authenticated
  with check ((select private.user_role()) = 'customer'
              and exists (select 1
                          from public.carts c
                          join public.food_items f on f.id = cart_items.food_id and f.restaurant_id = c.restaurant_id
                          join public.categories cat on cat.id = f.category_id
                          join public.restaurants r on r.id = f.restaurant_id
                          where c.id = cart_items.cart_id and c.user_id = (select auth.uid())
                            and f.is_available and cat.status = 'active' and r.status = 'active'));

------------------------------------------------------------------------------------------------------------------
-- 2. Reading carts
------------------------------------------------------------------------------------------------------------------
-- One restaurant's basket (same JSON shape as before; an empty basket is fine).
create function public.get_cart(p_restaurant bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_items jsonb; v_sub numeric(12,2); v_count integer; v_fee numeric(10,2) := 0; v_rjson jsonb;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if (select private.user_role()) is distinct from 'customer' then
    raise exception 'Only customers have a cart' using errcode = '42501';
  end if;
  select jsonb_build_object('id', r.id, 'name', r.name, 'slug', r.slug, 'is_open', r.is_open, 'status', r.status), r.base_delivery_fee
    into v_rjson, v_fee
  from public.restaurants r where r.id = p_restaurant and r.status = 'active';
  if not found then raise exception 'Restaurant not found' using errcode = 'P0002'; end if;

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
  where c.user_id = v_uid and c.restaurant_id = p_restaurant;

  if v_sub = 0 then v_fee := 0; end if;
  return jsonb_build_object('items', v_items, 'restaurant', v_rjson, 'summary', jsonb_build_object(
    'subtotal', v_sub::text, 'delivery_fee', v_fee::text, 'discount', '0.00',
    'total', (v_sub + v_fee)::numeric(12,2)::text, 'item_count', v_count));
end $$;

-- Every basket that has something in it (navbar badge, cart page).
create function public.get_carts() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if (select private.user_role()) is distinct from 'customer' then
    raise exception 'Only customers have a cart' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(public.get_cart(c.restaurant_id) order by c.updated_at desc)
    from public.carts c
    join public.restaurants r on r.id = c.restaurant_id and r.status = 'active'
    where c.user_id = v_uid and exists (select 1 from public.cart_items i where i.cart_id = c.id)
  ), '[]'::jsonb);
end $$;

-- v1 behaviour: "the" basket. Fine with one basket, asks to choose when there are several.
create or replace function public.get_cart() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid()); v_ids bigint[];
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if (select private.user_role()) is distinct from 'customer' then
    raise exception 'Only customers have a cart' using errcode = '42501';
  end if;
  select array_agg(c.restaurant_id order by c.updated_at desc) into v_ids
  from public.carts c where c.user_id = v_uid and exists (select 1 from public.cart_items i where i.cart_id = c.id);
  if coalesce(array_length(v_ids, 1), 0) = 0 then
    return jsonb_build_object('items', '[]'::jsonb, 'restaurant', null, 'summary', jsonb_build_object(
      'subtotal', '0.00', 'delivery_fee', '0.00', 'discount', '0.00', 'total', '0.00', 'item_count', 0));
  elsif array_length(v_ids, 1) > 1 then
    raise exception 'You have baskets at several restaurants. Choose one.' using errcode = '22023';
  end if;
  return public.get_cart(v_ids[1]);
end $$;

------------------------------------------------------------------------------------------------------------------
-- 3. Adding to a cart: the basket is found (or created) for the food's own restaurant
------------------------------------------------------------------------------------------------------------------
create or replace function public.add_to_cart(p_food_id bigint, p_quantity integer default 1)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_cart bigint; v_rest bigint; v_existing integer;
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

  insert into public.carts (user_id, restaurant_id) values (v_uid, v_rest) on conflict (user_id, restaurant_id) do nothing;
  select id into v_cart from public.carts where user_id = v_uid and restaurant_id = v_rest;

  select quantity into v_existing from public.cart_items where cart_id = v_cart and food_id = p_food_id for update;
  if found and v_existing + p_quantity > 50 then
    raise exception 'You can order at most 50 of one item' using errcode = '22023';
  end if;

  insert into public.cart_items (cart_id, food_id, quantity) values (v_cart, p_food_id, p_quantity)
  on conflict (cart_id, food_id) do update set quantity = public.cart_items.quantity + excluded.quantity;

  return public.get_cart(v_rest);
end $$;

------------------------------------------------------------------------------------------------------------------
-- 4. Delivery quote and checkout, per restaurant
------------------------------------------------------------------------------------------------------------------
create function public.delivery_quote(p_restaurant bigint, p_zone_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_cart jsonb; v_sub numeric(12,2); v_q jsonb; v_fee numeric(10,2) := 0; v_zone text;
begin
  v_cart := public.get_cart(p_restaurant);
  v_sub  := (v_cart -> 'summary' ->> 'subtotal')::numeric;
  if v_sub > 0 then
    v_q := private.delivery_quote(p_restaurant, p_zone_id);
    v_fee := (v_q ->> 'fee')::numeric;
    v_zone := v_q ->> 'zone_name';
  end if;
  return jsonb_build_object('subtotal', v_sub::text, 'delivery_fee', v_fee::text, 'zone_name', v_zone,
                            'total', (v_sub + v_fee)::numeric(12,2)::text, 'restaurant_id', p_restaurant);
end $$;

create function public.place_order(p_restaurant bigint, p_address jsonb, p_payment_method public.payment_method, p_zone_id bigint)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_street text; v_city text; v_state text; v_landmark text;
  v_cart bigint; v_lines jsonb := '[]'::jsonb; v_line record; v_rstat record;
  v_subtotal numeric(12,2) := 0; v_fee numeric(10,2); v_total numeric(12,2);
  v_address bigint; v_order bigint; v_quote jsonb;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if (select private.user_role()) is distinct from 'customer' then
    raise exception 'Only customers can place orders' using errcode = '42501';
  end if;
  if p_restaurant is null then raise exception 'Choose a restaurant' using errcode = '22023'; end if;
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

  select id into v_cart from public.carts where user_id = v_uid and restaurant_id = p_restaurant for update;
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
    if v_line.restaurant_id <> p_restaurant then
      raise exception 'This basket has food from another restaurant. Remove it and try again.' using errcode = '22023';
    end if;
    if not v_line.ok then
      raise exception '% is no longer available. Remove it from your cart.', v_line.food_name using errcode = '22023';
    end if;
    v_subtotal := v_subtotal + v_line.quantity * v_line.price;
    v_lines := v_lines || jsonb_build_object('food_id', v_line.food_id, 'food_name', v_line.food_name,
                                             'quantity', v_line.quantity, 'price', v_line.price);
  end loop;
  if jsonb_array_length(v_lines) = 0 then raise exception 'Your cart is empty' using errcode = '22023'; end if;

  select status, is_open into v_rstat from public.restaurants where id = p_restaurant for share;
  if not found or v_rstat.status <> 'active' then
    raise exception 'This restaurant is not taking orders' using errcode = '22023';
  end if;
  if not v_rstat.is_open then
    raise exception 'This restaurant is closed right now' using errcode = '22023';
  end if;

  v_quote := private.delivery_quote(p_restaurant, p_zone_id);
  v_fee := (v_quote ->> 'fee')::numeric;
  v_total := v_subtotal + v_fee;

  insert into public.addresses (user_id, street_address, city, state, landmark)
  values (v_uid, v_street, v_city, v_state, v_landmark) returning id into v_address;

  insert into public.orders (user_id, restaurant_id, address_id, subtotal, delivery_fee, discount, total_amount,
                             delivery_street_address, delivery_city, delivery_state, delivery_landmark,
                             delivery_zone_id, delivery_zone_name)
  values (v_uid, p_restaurant, v_address, v_subtotal, v_fee, 0, v_total, v_street, v_city, v_state, v_landmark,
          (v_quote ->> 'zone_id')::bigint, v_quote ->> 'zone_name')
  returning id into v_order;

  insert into public.order_items (order_id, food_id, food_name, quantity, price)
  select v_order, (l.value ->> 'food_id')::bigint, l.value ->> 'food_name',
         (l.value ->> 'quantity')::integer, (l.value ->> 'price')::numeric
  from jsonb_array_elements(v_lines) with ordinality as l(value, ord) order by l.ord;

  insert into public.payments (order_id, payment_method, amount) values (v_order, p_payment_method, v_total);
  insert into public.order_status_history (order_id, from_status, to_status, changed_by)
  values (v_order, null, 'pending', v_uid);

  delete from public.cart_items where cart_id = v_cart;     -- only THIS restaurant's basket is emptied
  return v_order;
end $$;

-- v1 signatures: act on "the" basket when there is exactly one.
create or replace function public.delivery_quote(p_zone_id bigint default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_cart jsonb; v_rest bigint;
begin
  v_cart := public.get_cart();
  v_rest := (v_cart -> 'restaurant' ->> 'id')::bigint;
  if v_rest is null then
    return jsonb_build_object('subtotal', '0.00', 'delivery_fee', '0.00', 'zone_name', null, 'total', '0.00', 'restaurant_id', null);
  end if;
  return public.delivery_quote(v_rest, p_zone_id);
end $$;

create or replace function public.place_order(p_address jsonb, p_payment_method public.payment_method, p_zone_id bigint default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_rest bigint;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  v_rest := ((public.get_cart()) -> 'restaurant' ->> 'id')::bigint;   -- 22023 if several baskets
  if v_rest is null then raise exception 'Your cart is empty' using errcode = '22023'; end if;
  return public.place_order(v_rest, p_address, p_payment_method, p_zone_id);
end $$;

------------------------------------------------------------------------------------------------------------------
-- 5. Public restaurant list (home page) and one restaurant (/r/<slug>)
------------------------------------------------------------------------------------------------------------------
-- Active restaurants only; closed ones are listed (is_open = false) so the page can grey them out.
-- Rating = average of APPROVED food reviews across the restaurant's menu.
create function public.list_restaurants(p_search text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_q text := nullif(btrim(p_search), '');
begin
  if v_q is not null and length(v_q) > 60 then raise exception 'Search is too long' using errcode = '22023'; end if;
  return coalesce((
    select jsonb_agg(x order by (x ->> 'is_open') desc, x ->> 'name')
    from (
      select jsonb_build_object('id', r.id, 'name', r.name, 'slug', r.slug, 'description', r.description,
               'logo_url', r.logo_url, 'is_open', r.is_open, 'base_delivery_fee', r.base_delivery_fee::text,
               'rating_avg', (select round(avg(fr.rating)::numeric, 1) from public.food_reviews fr
                              join public.food_items f on f.id = fr.food_id where f.restaurant_id = r.id and fr.status = 'approved'),
               'rating_count', (select count(*) from public.food_reviews fr
                                join public.food_items f on f.id = fr.food_id where f.restaurant_id = r.id and fr.status = 'approved')) as x
      from public.restaurants r
      where r.status = 'active'
        and (v_q is null or r.name ilike '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%')
      limit 100
    ) t
  ), '[]'::jsonb);
end $$;

create function public.get_restaurant(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  select jsonb_build_object('id', r.id, 'name', r.name, 'slug', r.slug, 'description', r.description, 'logo_url', r.logo_url,
           'phone', r.phone, 'address', r.address, 'is_open', r.is_open, 'base_delivery_fee', r.base_delivery_fee::text)
    into v from public.restaurants r where r.slug = p_slug and r.status = 'active';
  if v is null then raise exception 'Restaurant not found' using errcode = 'P0002'; end if;
  return v;
end $$;

-- Grants: new functions start open to everyone in Supabase, so close them, then open only what is needed.
revoke execute on function public.get_cart(bigint), public.get_carts(), public.delivery_quote(bigint, bigint),
  public.place_order(bigint, jsonb, public.payment_method, bigint), public.list_restaurants(text), public.get_restaurant(text)
  from public, anon;
grant execute on function public.get_cart(bigint), public.get_carts(), public.delivery_quote(bigint, bigint),
  public.place_order(bigint, jsonb, public.payment_method, bigint) to authenticated, service_role;
grant execute on function public.list_restaurants(text), public.get_restaurant(text) to anon, authenticated, service_role;
