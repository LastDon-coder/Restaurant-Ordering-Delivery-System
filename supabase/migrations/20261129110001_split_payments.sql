-- Phase 5e: Paystack split payments.
-- A restaurant with a connected Paystack SUBACCOUNT is paid its share directly by Paystack at settlement; the platform keeps
-- only its commission (a flat transaction_charge, in kobo, that stays in the main account). Restaurants without one are
-- unchanged: the platform collects everything and owes the restaurant its share (settled through payouts, phase 5d).
-- WHY the terms are frozen per payment attempt: the commission rates could change between "start paying" and "paid". The
-- amount we told Paystack to keep and the ledger row must match, so the rates used are copied onto the attempt and onto
-- the payment when it is confirmed.
-- WHY settlement is recorded on the ledger row: a split order's share was already paid to the restaurant, so it must NOT
-- count as money the platform owes. Balance = share of PLATFORM-settled online orders - commission on cash orders - payouts.
-- Bank details: only the Paystack subaccount code, bank name, account NAME and the last 4 digits are stored. The full
-- account number goes to Paystack from the Edge Function and is never saved or logged by us.

create table public.restaurant_settlement (
  restaurant_id   bigint primary key references public.restaurants (id) on delete restrict,
  subaccount_code text        not null unique check (subaccount_code ~ '^ACCT_[A-Za-z0-9]{5,40}$'),
  bank_name       text        not null check (length(bank_name) between 1 and 100),
  account_name    text        not null check (length(account_name) between 1 and 150),
  account_last4   text        not null check (account_last4 ~ '^[0-9]{4}$'),
  active          boolean     not null default true,
  created_by      uuid        references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index idx_restaurant_settlement_created_by on public.restaurant_settlement (created_by);
create trigger trg_restaurant_settlement_touch before update on public.restaurant_settlement
  for each row execute function private.touch_updated_at();
alter table public.restaurant_settlement enable row level security;
create policy restaurant_settlement_select on public.restaurant_settlement for select to authenticated
  using ((select private.is_admin()) or (select private.can_manage(restaurant_id)));
revoke all on public.restaurant_settlement from public, anon, authenticated;
grant select on public.restaurant_settlement to authenticated;
grant all on public.restaurant_settlement to service_role;

alter table public.payment_attempts
  add column split_subaccount text, add column split_food_rate numeric(5,2), add column split_delivery_rate numeric(5,2);
alter table public.payments
  add column settlement text not null default 'platform' check (settlement in ('platform', 'split')),
  add column split_food_rate numeric(5,2), add column split_delivery_rate numeric(5,2);
alter table public.order_ledger
  add column settlement text not null default 'platform' check (settlement in ('platform', 'split'));

-- pay_start: same job as before, plus the split terms when the restaurant has an active subaccount.
create or replace function public.pay_start(p_user uuid, p_order_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  o record; v_ref text; v_email text;
  v_sub text; v_fr numeric(5,2); v_dr numeric(5,2); v_platform numeric(12,2);
begin
  select ord.id, ord.order_status, ord.restaurant_id, ord.delivery_fee, ord.total_amount,
         p.id as payment_id, p.payment_method, p.payment_status, p.amount into o
  from public.orders ord join public.payments p on p.order_id = ord.id
  where ord.id = p_order_id and ord.user_id = p_user
  for update of p;
  if not found then raise exception 'Order not found' using errcode = 'P0002'; end if;
  if o.payment_method <> 'online' then
    raise exception 'This order is not an online-payment order' using errcode = '22023';
  end if;
  if o.payment_status not in ('pending', 'failed') then
    raise exception 'This order has already been paid' using errcode = '55000';
  end if;
  if o.order_status <> 'pending' then
    raise exception 'This order can no longer be paid (it is %)', o.order_status using errcode = '55000';
  end if;
  select u.email into v_email from auth.users u where u.id = p_user;
  if v_email is null then raise exception 'Your account has no email address' using errcode = '22023'; end if;

  -- Split terms: only with an active subaccount, and only if the platform's cut is more than 0 and less than the whole order
  -- (Paystack ignores a 0 charge and falls back to the subaccount's default percentage, which we never want).
  select s.subaccount_code, r.commission_percent, r.delivery_commission_percent
    into v_sub, v_fr, v_dr
  from public.restaurant_settlement s join public.restaurants r on r.id = s.restaurant_id
  where s.restaurant_id = o.restaurant_id and s.active;
  if v_sub is not null then
    v_platform := round((o.total_amount - o.delivery_fee) * v_fr / 100, 2) + round(o.delivery_fee * v_dr / 100, 2);
    if not (v_platform > 0 and v_platform < o.total_amount) then v_sub := null; end if;
  end if;

  v_ref := 'ORD-' || o.id || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 16);
  insert into public.payment_attempts (reference, payment_id, split_subaccount, split_food_rate, split_delivery_rate)
  values (v_ref, o.payment_id, v_sub, case when v_sub is not null then v_fr end, case when v_sub is not null then v_dr end);
  return jsonb_build_object('reference', v_ref, 'amount_kobo', (o.amount * 100)::bigint, 'email', v_email, 'order_id', o.id,
                            'subaccount', v_sub, 'platform_kobo', case when v_sub is not null then (v_platform * 100)::bigint end);
end $$;

-- If Paystack refuses the split (for example the fee is bigger than the restaurant's share on a tiny order), the Edge Function
-- starts an ordinary payment instead and clears the split terms, so the books follow what really happened.
create function public.pay_clear_split(p_reference text) returns void
language sql security definer set search_path = '' as $$
  update public.payment_attempts set split_subaccount = null, split_food_rate = null, split_delivery_rate = null
   where reference = p_reference $$;

-- pay_apply_charge: unchanged rules; when it marks the order paid it also freezes how the money was settled.
create or replace function public.pay_apply_charge(p_reference text, p_amount_kobo bigint, p_currency text, p_success boolean)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p record; v_expected bigint;
begin
  select pay.id, pay.order_id, pay.amount, pay.payment_status, pay.transaction_reference, ord.order_status,
         a.split_subaccount, a.split_food_rate, a.split_delivery_rate into p
  from public.payment_attempts a
  join public.payments pay on pay.id = a.payment_id
  join public.orders ord on ord.id = pay.order_id
  where a.reference = p_reference
  for update of pay;
  if not found then return jsonb_build_object('result', 'unknown_reference'); end if;

  if not p_success then
    return jsonb_build_object('result', 'not_successful', 'order_id', p.order_id, 'payment_status', p.payment_status);
  end if;

  v_expected := (p.amount * 100)::bigint;
  if p_amount_kobo is distinct from v_expected or upper(coalesce(p_currency, '')) <> 'NGN' then
    return jsonb_build_object('result', 'amount_mismatch', 'order_id', p.order_id, 'expected_kobo', v_expected);
  end if;

  if p.payment_status in ('paid', 'refunded') then
    return jsonb_build_object('result',
      case when p.transaction_reference = p_reference then 'already_paid' else 'duplicate_payment' end,
      'order_id', p.order_id, 'payment_status', p.payment_status);
  end if;

  update public.payments set payment_status = 'paid', paid_at = now(), transaction_reference = p_reference,
         settlement = case when p.split_subaccount is not null then 'split' else 'platform' end,
         split_food_rate = p.split_food_rate, split_delivery_rate = p.split_delivery_rate
   where id = p.id;
  return jsonb_build_object(
    'result', case when p.order_status in ('cancelled', 'rejected', 'failed') then 'paid_order_closed' else 'paid' end,
    'order_id', p.order_id, 'payment_status', 'paid');
end $$;

-- The ledger uses the frozen split rates when there are any, and records how the order was settled.
create or replace function private.ledger_record(p_order bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare o record; v_food numeric(12,2); v_fr numeric(5,2); v_dr numeric(5,2); v_fc numeric(12,2); v_dc numeric(12,2);
begin
  select ord.id, ord.restaurant_id, ord.delivery_fee, ord.total_amount, pay.payment_method, pay.settlement,
         coalesce(pay.split_food_rate, r.commission_percent) as food_rate,
         coalesce(pay.split_delivery_rate, r.delivery_commission_percent) as delivery_rate
    into o
  from public.orders ord
  join public.payments pay on pay.order_id = ord.id
  join public.restaurants r on r.id = ord.restaurant_id
  where ord.id = p_order;
  if not found then return; end if;

  v_food := o.total_amount - o.delivery_fee;
  v_fc := round(v_food * o.food_rate / 100, 2);
  v_dc := round(o.delivery_fee * o.delivery_rate / 100, 2);

  insert into public.order_ledger (order_id, restaurant_id, payment_method, settlement, gross, food_amount, delivery_fee,
                                   commission_rate, delivery_commission_rate, commission, delivery_commission, restaurant_share)
  values (o.id, o.restaurant_id, o.payment_method, o.settlement, o.total_amount, v_food, o.delivery_fee,
          o.food_rate, o.delivery_rate, v_fc, v_dc, o.total_amount - v_fc - v_dc)
  on conflict (order_id) do nothing;
end $$;

-- Balance now counts only the online orders the PLATFORM collected.
create or replace function private.restaurant_balance(p_restaurant bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  with l as (
    select coalesce(sum(restaurant_share) filter (where payment_method = 'online' and settlement = 'platform'), 0)
         - coalesce(sum(platform_income) filter (where payment_method = 'cash_on_delivery'), 0) as bal
    from public.order_ledger where restaurant_id = p_restaurant and status = 'earned'
  ), p as (
    select coalesce(sum(amount) filter (where direction = 'to_restaurant'), 0) as to_r,
           coalesce(sum(amount) filter (where direction = 'to_platform'), 0) as to_p
    from public.payouts where restaurant_id = p_restaurant and voided_at is null
  )
  select jsonb_build_object('restaurant_id', p_restaurant, 'ledger_balance', l.bal,
    'paid_to_restaurant', p.to_r, 'paid_to_platform', p.to_p, 'outstanding', l.bal - p.to_r + p.to_p)
  from l, p $$;

-- Reports (same as phase 5b, with the settlement-aware balance and a split count).
create or replace function public.report_summary(p_restaurant bigint, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_refunds jsonb;
begin
  perform private.report_check(p_restaurant, p_from, p_to);
  select jsonb_build_object(
    'orders',              count(*),
    'online_orders',       count(*) filter (where payment_method = 'online'),
    'cash_orders',         count(*) filter (where payment_method = 'cash_on_delivery'),
    'gross',               coalesce(sum(gross), 0),
    'food_amount',         coalesce(sum(food_amount), 0),
    'delivery_fee',        coalesce(sum(delivery_fee), 0),
    'commission',          coalesce(sum(commission), 0),
    'delivery_commission', coalesce(sum(delivery_commission), 0),
    'platform_income',     coalesce(sum(platform_income), 0),
    'restaurant_share',    coalesce(sum(restaurant_share), 0),
    'split_orders',        count(*) filter (where settlement = 'split'),
    'split_share',         coalesce(sum(restaurant_share) filter (where settlement = 'split'), 0),
    'balance',             coalesce(sum(restaurant_share) filter (where payment_method = 'online' and settlement = 'platform'), 0)
                         - coalesce(sum(platform_income) filter (where payment_method = 'cash_on_delivery'), 0))
    into v
  from public.order_ledger
  where status = 'earned' and (p_restaurant is null or restaurant_id = p_restaurant)
    and (earned_at at time zone 'Africa/Lagos')::date between p_from and p_to;

  select jsonb_build_object('refunded_orders', count(*), 'refunded_gross', coalesce(sum(gross), 0)) into v_refunds
  from public.order_ledger
  where status = 'reversed' and (p_restaurant is null or restaurant_id = p_restaurant)
    and (earned_at at time zone 'Africa/Lagos')::date between p_from and p_to;
  return v || v_refunds;
end $$;

create or replace function public.report_by_restaurant(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.report_check(null, p_from, p_to);
  if not (select private.is_admin()) then
    raise exception 'Only a platform admin can compare restaurants' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'restaurant_id', r.id, 'name', r.name, 'status', r.status,
        'commission_percent', r.commission_percent, 'delivery_commission_percent', r.delivery_commission_percent,
        'orders', coalesce(s.orders, 0), 'gross', coalesce(s.gross, 0),
        'commission', coalesce(s.commission, 0), 'delivery_commission', coalesce(s.delivery_commission, 0),
        'platform_income', coalesce(s.platform_income, 0), 'restaurant_share', coalesce(s.restaurant_share, 0),
        'balance', coalesce(s.balance, 0)) order by coalesce(s.gross, 0) desc, r.id)
    from public.restaurants r
    left join (
      select restaurant_id, count(*) as orders, sum(gross) as gross, sum(commission) as commission,
             sum(delivery_commission) as delivery_commission, sum(platform_income) as platform_income,
             sum(restaurant_share) as restaurant_share,
             coalesce(sum(restaurant_share) filter (where payment_method = 'online' and settlement = 'platform'), 0)
               - coalesce(sum(platform_income) filter (where payment_method = 'cash_on_delivery'), 0) as balance
      from public.order_ledger
      where status = 'earned' and (earned_at at time zone 'Africa/Lagos')::date between p_from and p_to
      group by restaurant_id
    ) s on s.restaurant_id = r.id
    where r.status in ('active', 'suspended')), '[]'::jsonb);
end $$;

-- Connect: called ONLY by the Edge Function (service role) after it created the Paystack subaccount.
create function public.pay_save_settlement(p_admin uuid, p_restaurant bigint, p_code text, p_bank_name text, p_account_name text, p_last4 text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.profiles where id = p_admin and role = 'admin' and is_active) then
    raise exception 'Only an admin can connect a bank account' using errcode = '42501';
  end if;
  if not exists (select 1 from public.restaurants where id = p_restaurant) then raise exception 'Restaurant not found' using errcode = 'P0002'; end if;
  insert into public.restaurant_settlement (restaurant_id, subaccount_code, bank_name, account_name, account_last4, created_by)
  values (p_restaurant, p_code, p_bank_name, p_account_name, p_last4, p_admin)
  on conflict (restaurant_id) do update
    set subaccount_code = excluded.subaccount_code, bank_name = excluded.bank_name, account_name = excluded.account_name,
        account_last4 = excluded.account_last4, active = true;
end $$;

-- Admin: switch splitting on or off for a restaurant (off = the platform collects again and owes the share).
create function public.admin_set_split_active(p_restaurant bigint, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only a platform admin can change split payments' using errcode = '42501'; end if;
  if p_active is null then raise exception 'Choose on or off' using errcode = '22023'; end if;
  update public.restaurant_settlement set active = p_active where restaurant_id = p_restaurant;
  if not found then raise exception 'This restaurant has no connected bank account' using errcode = 'P0002'; end if;
end $$;

-- A restaurant's connection (never the full account number): admin, owner or manager.
create function public.get_settlement(p_restaurant bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_restaurant is null or not (select private.is_admin() or private.can_manage(p_restaurant)) then
    raise exception 'Only the restaurant''s owner or manager can see this' using errcode = '42501';
  end if;
  return (select jsonb_build_object('bank_name', bank_name, 'account_name', account_name, 'account_last4', account_last4, 'active', active)
          from public.restaurant_settlement where restaurant_id = p_restaurant);
end $$;

-- Admin: every live restaurant with its connection status.
create function public.admin_list_settlements() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only a platform admin can see this' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('restaurant_id', r.id, 'name', r.name, 'status', r.status,
             'connected', s.restaurant_id is not null, 'bank_name', s.bank_name, 'account_name', s.account_name,
             'account_last4', s.account_last4, 'active', s.active) order by r.name)
    from public.restaurants r left join public.restaurant_settlement s on s.restaurant_id = r.id
    where r.status in ('active', 'suspended')), '[]'::jsonb);
end $$;

revoke execute on function public.pay_start(uuid, bigint), public.pay_apply_charge(text, bigint, text, boolean),
  public.pay_clear_split(text), public.pay_save_settlement(uuid, bigint, text, text, text, text) from public, anon, authenticated;
grant execute on function public.pay_start(uuid, bigint), public.pay_apply_charge(text, bigint, text, boolean),
  public.pay_clear_split(text), public.pay_save_settlement(uuid, bigint, text, text, text, text) to service_role;
revoke execute on function public.admin_set_split_active(bigint, boolean), public.get_settlement(bigint), public.admin_list_settlements() from public, anon;
grant execute on function public.admin_set_split_active(bigint, boolean), public.get_settlement(bigint), public.admin_list_settlements() to authenticated, service_role;
