-- 008: delivery zones. Fee = base fee (settings, now 2000) + the extra charge of the zone the customer picks.
-- No zone chosen ("other area") = base fee only. The fee is always computed here, never sent by the browser.
-- WHY a table (not a column on orders): zones are reference data an admin edits. Orders keep a SNAPSHOT of the
-- zone name and the final fee, so renaming, repricing or deleting a zone never rewrites history.

update private.settings set value = '2000.00' where key = 'delivery_fee';

create table public.delivery_zones (
  id         bigint generated always as identity primary key,
  zone_name  text not null check (length(btrim(zone_name)) between 1 and 100),
  extra_fee  numeric(10,2) not null default 0 check (extra_fee >= 0 and extra_fee <= 100000),
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- Case-insensitive unique name: "GRA" and "gra" would confuse customers.
create unique index uq_delivery_zones_name on public.delivery_zones (lower(btrim(zone_name)));
create trigger trg_delivery_zones_touch before update on public.delivery_zones
  for each row execute function private.touch_updated_at();

alter table public.delivery_zones enable row level security;
grant select, insert, update, delete on public.delivery_zones to authenticated;
-- Signed-in users see active zones (the checkout dropdown); admins see and edit all of them.
create policy zones_read_active on public.delivery_zones for select to authenticated using (is_active);
create policy zones_admin_all on public.delivery_zones for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

-- Orders remember where they were delivered-priced. The FK is SET NULL so a zone can be deleted; the name stays.
alter table public.orders
  add column delivery_zone_id bigint references public.delivery_zones (id) on delete set null,
  add column delivery_zone_name text;
create index idx_orders_delivery_zone_id on public.orders (delivery_zone_id);

-- The one place the fee is calculated. Locks the zone row (FOR SHARE) so its price can't change mid-order.
-- (Not marked STABLE: a function that takes row locks must be VOLATILE.)
create function private.delivery_quote(p_zone_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_base numeric(10,2) := private.delivery_fee(); z record;
begin
  if p_zone_id is null then
    return jsonb_build_object('fee', v_base, 'zone_id', null, 'zone_name', null);
  end if;
  select id, zone_name, extra_fee into z from public.delivery_zones where id = p_zone_id and is_active for share;
  if not found then raise exception 'That delivery area is not available. Choose another area.' using errcode = '22023'; end if;
  return jsonb_build_object('fee', v_base + z.extra_fee, 'zone_id', z.id, 'zone_name', z.zone_name);
end $$;
revoke execute on function private.delivery_quote(bigint) from public, anon;
grant  execute on function private.delivery_quote(bigint) to authenticated, service_role;

-- What the checkout shows for the chosen area. Same maths as place_order (it calls the same helper).
create function public.delivery_quote(p_zone_id bigint default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_cart jsonb; v_sub numeric(12,2); v_q jsonb; v_fee numeric(10,2);
begin
  v_cart := public.get_cart();            -- also checks the caller is a signed-in customer
  v_sub := (v_cart -> 'summary' ->> 'subtotal')::numeric;
  v_q := private.delivery_quote(p_zone_id);
  v_fee := case when v_sub > 0 then (v_q ->> 'fee')::numeric else 0 end;
  return jsonb_build_object('subtotal', v_sub::text, 'delivery_fee', v_fee::text, 'zone_name', v_q ->> 'zone_name',
                            'total', (v_sub + v_fee)::numeric(12,2)::text);
end $$;
revoke execute on function public.delivery_quote(bigint) from public, anon;
grant  execute on function public.delivery_quote(bigint) to authenticated;

-- Base fee: readable by any signed-in user, changeable only by an active admin.
create function public.get_delivery_settings() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  return jsonb_build_object('base_fee', private.delivery_fee()::text);
end $$;
create function public.admin_set_delivery_fee(p_fee numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only an admin can change the delivery fee' using errcode = '42501'; end if;
  if p_fee is null or p_fee < 0 or p_fee > 100000 or p_fee <> round(p_fee, 2) then
    raise exception 'Delivery fee must be between 0 and 100000, with at most 2 decimals' using errcode = '22023';
  end if;
  update private.settings set value = to_char(p_fee, 'FM999999990.00') where key = 'delivery_fee';
  return jsonb_build_object('base_fee', private.delivery_fee()::text);
end $$;
revoke execute on function public.get_delivery_settings(), public.admin_set_delivery_fee(numeric) from public, anon;
grant  execute on function public.get_delivery_settings(), public.admin_set_delivery_fee(numeric) to authenticated;

-- place_order gains an optional zone. Dropping the old signature avoids two overloads confusing the API.
drop function public.place_order(jsonb, public.payment_method);
create function public.place_order(p_address jsonb, p_payment_method public.payment_method, p_zone_id bigint default null) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_street text; v_city text; v_state text; v_landmark text;
  v_cart bigint; v_lines jsonb := '[]'::jsonb; v_line record;
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

  v_quote := private.delivery_quote(p_zone_id);   -- base fee + the chosen zone's extra (server-side)
  v_fee := (v_quote ->> 'fee')::numeric;
  v_total := v_subtotal + v_fee;

  insert into public.addresses (user_id, street_address, city, state, landmark)
  values (v_uid, v_street, v_city, v_state, v_landmark) returning id into v_address;

  insert into public.orders (user_id, address_id, subtotal, delivery_fee, discount, total_amount,
                             delivery_street_address, delivery_city, delivery_state, delivery_landmark,
                             delivery_zone_id, delivery_zone_name)
  values (v_uid, v_address, v_subtotal, v_fee, 0, v_total, v_street, v_city, v_state, v_landmark,
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

revoke execute on function public.place_order(jsonb, public.payment_method, bigint) from public, anon;
grant  execute on function public.place_order(jsonb, public.payment_method, bigint) to authenticated;
