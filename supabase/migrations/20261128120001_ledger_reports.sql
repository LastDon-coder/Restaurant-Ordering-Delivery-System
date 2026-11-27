-- Phase 5b: money reports. Read-only, built on order_ledger (rows with status 'earned' only; refunded rows are left out).
-- WHY SECURITY DEFINER + explicit checks (not just RLS): the functions aggregate, and we want a clear 42501 for a
-- non-manager instead of a silently empty report. The rules:
--   * platform admin: any restaurant, or ALL restaurants (p_restaurant = null)
--   * owner / manager: only their own restaurant (p_restaurant is required)
--   * everyone else (staff, riders, customers, anonymous): refused
-- Days are Nigerian days (Africa/Lagos), so an order paid at 00:30 local time lands on the right day.
--
-- "balance" answers "who owes whom?" without a payouts table:
--   online orders: the platform's Paystack account received the money, so the platform owes the restaurant its share
--   cash orders:   the restaurant/rider holds the cash, so the restaurant owes the platform its commission
--   balance = online restaurant_share - cash platform_income   (positive = platform pays restaurant, negative = restaurant pays platform)
-- Recording actual payouts (so a balance can be settled to zero) is not built yet.

create function private.report_check(p_restaurant bigint, p_from date, p_to date) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'Choose a valid date range (from must not be after to)' using errcode = '22023';
  end if;
  if p_to - p_from > 366 then raise exception 'A report can cover at most 366 days' using errcode = '22023'; end if;
  if (select private.is_admin()) then
    if p_restaurant is not null and not exists (select 1 from public.restaurants where id = p_restaurant) then
      raise exception 'Restaurant not found' using errcode = 'P0002';
    end if;
  else
    if p_restaurant is null then raise exception 'Choose a restaurant' using errcode = '22023'; end if;
    if not (select private.can_manage(p_restaurant)) then
      raise exception 'Only the restaurant''s owner or manager can see its sales' using errcode = '42501';
    end if;
  end if;
end $$;
revoke execute on function private.report_check(bigint, date, date) from public, anon, authenticated;

-- Totals for a period (one restaurant, or all for the admin).
create function public.report_summary(p_restaurant bigint, p_from date, p_to date) returns jsonb
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
    'balance',             coalesce(sum(restaurant_share) filter (where payment_method = 'online'), 0)
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

-- Sales by day (days with at least one order, oldest first).
create function public.report_sales_by_day(p_restaurant bigint, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.report_check(p_restaurant, p_from, p_to);
  return coalesce((
    select jsonb_agg(d order by d ->> 'day')
    from (
      select jsonb_build_object(
        'day', ((earned_at at time zone 'Africa/Lagos')::date)::text,
        'orders', count(*), 'gross', sum(gross), 'food_amount', sum(food_amount), 'delivery_fee', sum(delivery_fee),
        'commission', sum(commission), 'delivery_commission', sum(delivery_commission),
        'platform_income', sum(platform_income), 'restaurant_share', sum(restaurant_share)) as d
      from public.order_ledger
      where status = 'earned' and (p_restaurant is null or restaurant_id = p_restaurant)
        and (earned_at at time zone 'Africa/Lagos')::date between p_from and p_to
      group by (earned_at at time zone 'Africa/Lagos')::date
    ) x), '[]'::jsonb);
end $$;

-- Sales and balance per restaurant. Admin only (an owner has one restaurant: use report_summary).
create function public.report_by_restaurant(p_from date, p_to date) returns jsonb
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
             coalesce(sum(restaurant_share) filter (where payment_method = 'online'), 0)
               - coalesce(sum(platform_income) filter (where payment_method = 'cash_on_delivery'), 0) as balance
      from public.order_ledger
      where status = 'earned' and (earned_at at time zone 'Africa/Lagos')::date between p_from and p_to
      group by restaurant_id
    ) s on s.restaurant_id = r.id
    where r.status in ('active', 'suspended')), '[]'::jsonb);
end $$;

revoke execute on function public.report_summary(bigint, date, date), public.report_sales_by_day(bigint, date, date),
  public.report_by_restaurant(date, date) from public, anon;
grant execute on function public.report_summary(bigint, date, date), public.report_sales_by_day(bigint, date, date),
  public.report_by_restaurant(date, date) to authenticated, service_role;
