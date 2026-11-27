-- Phase 5a (revised): TWO commission rates per restaurant, both set by the admin:
--   commission_percent          = % of the FOOD amount the platform keeps (default 10)
--   delivery_commission_percent = % of the DELIVERY FEE the platform keeps (default 10)
-- The restaurant keeps the rest of each. restaurant_share + platform_income = gross, always.
-- The ledger was created a moment ago and holds only rebuilt test-era rows, so it is simply recreated.

drop trigger if exists trg_payments_ledger on public.payments;
drop trigger if exists trg_orders_ledger on public.orders;
drop function if exists private.trg_ledger_from_payment();
drop function if exists private.trg_ledger_from_order();
drop function if exists private.ledger_record(bigint);
drop function if exists public.admin_set_commission(bigint, numeric);
drop table if exists public.order_ledger;

alter table public.restaurants
  add column delivery_commission_percent numeric(5,2) not null default 10
    check (delivery_commission_percent >= 0 and delivery_commission_percent <= 100);
alter table public.restaurants alter column commission_percent set default 10;
-- Every existing restaurant gets the agreed 10% / 10% (the admin can change each one).
update public.restaurants set commission_percent = 10, delivery_commission_percent = 10;

create table public.order_ledger (
  id                         bigint generated always as identity primary key,
  order_id                   bigint        not null unique references public.orders (id) on delete restrict,
  restaurant_id              bigint        not null references public.restaurants (id) on delete restrict,
  payment_method             public.payment_method not null,
  status                     text          not null default 'earned' check (status in ('earned', 'reversed')),
  gross                      numeric(12,2) not null check (gross >= 0),
  food_amount                numeric(12,2) not null check (food_amount >= 0),
  delivery_fee               numeric(12,2) not null check (delivery_fee >= 0),
  commission_rate            numeric(5,2)  not null check (commission_rate between 0 and 100),
  delivery_commission_rate   numeric(5,2)  not null check (delivery_commission_rate between 0 and 100),
  commission                 numeric(12,2) not null check (commission >= 0),            -- platform's cut of the food
  delivery_commission        numeric(12,2) not null check (delivery_commission >= 0),   -- platform's cut of the delivery fee
  restaurant_share           numeric(12,2) not null check (restaurant_share >= 0),
  platform_income            numeric(12,2) generated always as (commission + delivery_commission) stored,
  earned_at                  timestamptz   not null default now(),
  reversed_at                timestamptz,
  constraint chk_ledger_gross   check (gross = food_amount + delivery_fee),
  constraint chk_ledger_split   check (gross = restaurant_share + commission + delivery_commission),
  constraint chk_ledger_reverse check ((status = 'reversed') = (reversed_at is not null))
);
create index idx_order_ledger_restaurant_earned on public.order_ledger (restaurant_id, earned_at);
create index idx_order_ledger_earned on public.order_ledger (earned_at);

alter table public.order_ledger enable row level security;
create policy order_ledger_select on public.order_ledger for select to authenticated
  using ((select private.is_admin()) or (select private.can_manage(restaurant_id)));
revoke all on public.order_ledger from public, anon, authenticated;
grant select on public.order_ledger to authenticated;
grant all on public.order_ledger to service_role;

create function private.ledger_record(p_order bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare o record; v_food numeric(12,2); v_fc numeric(12,2); v_dc numeric(12,2);
begin
  select ord.id, ord.restaurant_id, ord.delivery_fee, ord.total_amount, pay.payment_method,
         r.commission_percent, r.delivery_commission_percent
    into o
  from public.orders ord
  join public.payments pay on pay.order_id = ord.id
  join public.restaurants r on r.id = ord.restaurant_id
  where ord.id = p_order;
  if not found then return; end if;

  v_food := o.total_amount - o.delivery_fee;           -- food after any discount
  v_fc := round(v_food * o.commission_percent / 100, 2);
  v_dc := round(o.delivery_fee * o.delivery_commission_percent / 100, 2);

  insert into public.order_ledger (order_id, restaurant_id, payment_method, gross, food_amount, delivery_fee,
                                   commission_rate, delivery_commission_rate, commission, delivery_commission, restaurant_share)
  values (o.id, o.restaurant_id, o.payment_method, o.total_amount, v_food, o.delivery_fee,
          o.commission_percent, o.delivery_commission_percent, v_fc, v_dc, o.total_amount - v_fc - v_dc)
  on conflict (order_id) do nothing;
end $$;

create function private.trg_ledger_from_payment() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.payment_status = 'paid' and old.payment_status is distinct from 'paid' and new.payment_method = 'online' then
    perform private.ledger_record(new.order_id);
  elsif new.payment_status = 'refunded' and old.payment_status is distinct from 'refunded' then
    update public.order_ledger set status = 'reversed', reversed_at = now()
     where order_id = new.order_id and status = 'earned';
  end if;
  return null;
end $$;
create trigger trg_payments_ledger after update of payment_status on public.payments
  for each row execute function private.trg_ledger_from_payment();

create function private.trg_ledger_from_order() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.order_status = 'delivered' and old.order_status is distinct from 'delivered'
     and exists (select 1 from public.payments p where p.order_id = new.id and p.payment_method = 'cash_on_delivery') then
    perform private.ledger_record(new.id);
  end if;
  return null;
end $$;
create trigger trg_orders_ledger after update of order_status on public.orders
  for each row execute function private.trg_ledger_from_order();

revoke execute on function private.ledger_record(bigint), private.trg_ledger_from_payment(), private.trg_ledger_from_order()
  from public, anon, authenticated;

-- Admin only. Both rates are required so a screen can never half-update. Affects FUTURE ledger rows only.
create function public.admin_set_commission(p_restaurant bigint, p_food_percent numeric, p_delivery_percent numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_old_f numeric; v_old_d numeric;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only a platform admin can set commission' using errcode = '42501'; end if;
  if p_restaurant is null or p_food_percent is null or p_delivery_percent is null
     or p_food_percent < 0 or p_food_percent > 100 or p_delivery_percent < 0 or p_delivery_percent > 100 then
    raise exception 'Both commission rates must be numbers from 0 to 100' using errcode = '22023';
  end if;
  select commission_percent, delivery_commission_percent into v_old_f, v_old_d
    from public.restaurants where id = p_restaurant for update;
  if not found then raise exception 'Restaurant not found' using errcode = 'P0002'; end if;
  update public.restaurants
     set commission_percent = round(p_food_percent, 2), delivery_commission_percent = round(p_delivery_percent, 2)
   where id = p_restaurant;
  return jsonb_build_object('restaurant_id', p_restaurant,
    'old_food_percent', v_old_f, 'old_delivery_percent', v_old_d,
    'food_percent', round(p_food_percent, 2), 'delivery_percent', round(p_delivery_percent, 2));
end $$;
revoke execute on function public.admin_set_commission(bigint, numeric, numeric) from public, anon;
grant execute on function public.admin_set_commission(bigint, numeric, numeric) to authenticated, service_role;

-- Backfill orders that already counted (paid online / delivered cash) at the current 10% / 10%.
insert into public.order_ledger (order_id, restaurant_id, payment_method, gross, food_amount, delivery_fee,
                                 commission_rate, delivery_commission_rate, commission, delivery_commission, restaurant_share, earned_at)
select o.id, o.restaurant_id, p.payment_method, o.total_amount, o.total_amount - o.delivery_fee, o.delivery_fee,
       r.commission_percent, r.delivery_commission_percent,
       round((o.total_amount - o.delivery_fee) * r.commission_percent / 100, 2),
       round(o.delivery_fee * r.delivery_commission_percent / 100, 2),
       o.total_amount - round((o.total_amount - o.delivery_fee) * r.commission_percent / 100, 2)
                      - round(o.delivery_fee * r.delivery_commission_percent / 100, 2),
       coalesce(p.paid_at, o.updated_at)
from public.orders o
join public.payments p on p.order_id = o.id
join public.restaurants r on r.id = o.restaurant_id
where (p.payment_method = 'online' and p.payment_status = 'paid')
   or (p.payment_method = 'cash_on_delivery' and o.order_status = 'delivered')
on conflict (order_id) do nothing;
