-- Phase 5a: the money ledger.
-- WHY a separate table: orders/payments say what the customer did; the ledger says who is owed what. One row per
-- order, written ONCE when the money counts, with the commission rate COPIED in (a snapshot, like order_items.price),
-- so changing a restaurant's rate later never rewrites history.
--
-- When an order counts:
--   * online order      -> the moment the payment becomes 'paid' (pay_apply_charge already verified it server-side)
--   * cash on delivery  -> the moment the order becomes 'delivered' (the rider has collected the cash)
-- Reversal: an online payment that is refunded marks its ledger row 'reversed' (kept for the audit trail, left out of totals).
--
-- Money rules (agreed for v2):
--   gross            = order total (food + delivery fee - discount)
--   commission       = commission_rate % of the WHOLE total, but never more than the food amount
--   delivery_fee     = kept by the platform
--   restaurant_share = food amount - commission
--   platform_income  = commission + delivery_fee
--   so restaurant_share + platform_income = gross, always (enforced by a CHECK).

create table public.order_ledger (
  id               bigint generated always as identity primary key,
  order_id         bigint        not null unique references public.orders (id) on delete restrict,   -- unique = one row per order
  restaurant_id    bigint        not null references public.restaurants (id) on delete restrict,
  payment_method   public.payment_method not null,
  status           text          not null default 'earned' check (status in ('earned', 'reversed')),
  gross            numeric(12,2) not null check (gross >= 0),
  food_amount      numeric(12,2) not null check (food_amount >= 0),
  delivery_fee     numeric(12,2) not null check (delivery_fee >= 0),
  commission_rate  numeric(5,2)  not null check (commission_rate >= 0 and commission_rate <= 100),
  commission       numeric(12,2) not null check (commission >= 0),
  restaurant_share numeric(12,2) not null check (restaurant_share >= 0),
  platform_income  numeric(12,2) generated always as (commission + delivery_fee) stored,
  earned_at        timestamptz   not null default now(),
  reversed_at      timestamptz,
  constraint chk_ledger_split   check (gross = restaurant_share + commission + delivery_fee),
  constraint chk_ledger_reverse check ((status = 'reversed') = (reversed_at is not null))
);
-- Reports filter by restaurant and a date range, so this one index serves "sales by day" and "by restaurant".
create index idx_order_ledger_restaurant_earned on public.order_ledger (restaurant_id, earned_at);
create index idx_order_ledger_earned on public.order_ledger (earned_at);

alter table public.order_ledger enable row level security;
-- Read only: platform admin sees everything; an owner/manager sees their own restaurant. Staff and riders see nothing.
-- There is NO insert/update/delete policy and no grant: only the triggers below (SECURITY DEFINER) can write.
create policy order_ledger_select on public.order_ledger for select to authenticated
  using ((select private.is_admin()) or (select private.can_manage(restaurant_id)));
revoke all on public.order_ledger from public, anon, authenticated;
grant select on public.order_ledger to authenticated;
grant all on public.order_ledger to service_role;

-- Write the ledger row for one order (idempotent: the unique order_id + ON CONFLICT mean a second call does nothing).
create function private.ledger_record(p_order bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare o record; v_food numeric(12,2); v_comm numeric(12,2);
begin
  select ord.id, ord.restaurant_id, ord.subtotal, ord.delivery_fee, ord.discount, ord.total_amount,
         pay.payment_method, r.commission_percent
    into o
  from public.orders ord
  join public.payments pay on pay.order_id = ord.id
  join public.restaurants r on r.id = ord.restaurant_id
  where ord.id = p_order;
  if not found then return; end if;

  v_food := o.subtotal - o.discount;
  if v_food < 0 then v_food := 0; end if;
  v_comm := least(round(o.total_amount * o.commission_percent / 100, 2), v_food);

  insert into public.order_ledger (order_id, restaurant_id, payment_method, gross, food_amount, delivery_fee,
                                   commission_rate, commission, restaurant_share)
  values (o.id, o.restaurant_id, o.payment_method, o.total_amount, o.total_amount - o.delivery_fee, o.delivery_fee,
          o.commission_percent, v_comm, (o.total_amount - o.delivery_fee) - v_comm)
  on conflict (order_id) do nothing;
end $$;

-- Online: payment became 'paid' -> record. Payment became 'refunded' -> reverse.
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

-- Cash on delivery: order became 'delivered' -> record.
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

-- Admin only: set a restaurant's commission rate. Affects FUTURE ledger rows only (old rows keep their snapshot).
create function public.admin_set_commission(p_restaurant bigint, p_percent numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_old numeric;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only a platform admin can set commission' using errcode = '42501'; end if;
  if p_restaurant is null or p_percent is null or p_percent < 0 or p_percent > 100 then
    raise exception 'Commission must be a number from 0 to 100' using errcode = '22023';
  end if;
  select commission_percent into v_old from public.restaurants where id = p_restaurant for update;
  if not found then raise exception 'Restaurant not found' using errcode = 'P0002'; end if;
  update public.restaurants set commission_percent = round(p_percent, 2) where id = p_restaurant;
  return jsonb_build_object('restaurant_id', p_restaurant, 'old_percent', v_old, 'commission_percent', round(p_percent, 2));
end $$;
revoke execute on function public.admin_set_commission(bigint, numeric) from public, anon;
grant execute on function public.admin_set_commission(bigint, numeric) to authenticated, service_role;

-- Backfill: orders that already counted before this migration (rate is whatever each restaurant has now, default 0).
insert into public.order_ledger (order_id, restaurant_id, payment_method, gross, food_amount, delivery_fee,
                                 commission_rate, commission, restaurant_share, earned_at)
select o.id, o.restaurant_id, p.payment_method, o.total_amount, o.total_amount - o.delivery_fee, o.delivery_fee,
       r.commission_percent,
       least(round(o.total_amount * r.commission_percent / 100, 2), o.total_amount - o.delivery_fee),
       (o.total_amount - o.delivery_fee) - least(round(o.total_amount * r.commission_percent / 100, 2), o.total_amount - o.delivery_fee),
       coalesce(p.paid_at, o.updated_at)
from public.orders o
join public.payments p on p.order_id = o.id
join public.restaurants r on r.id = o.restaurant_id
where (p.payment_method = 'online' and p.payment_status = 'paid')
   or (p.payment_method = 'cash_on_delivery' and o.order_status = 'delivered')
on conflict (order_id) do nothing;
