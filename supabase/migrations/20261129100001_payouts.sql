-- Phase 5d: payouts, so a restaurant's balance can be settled to zero.
-- WHY append-only: money history must be auditable. A payout is never edited or deleted; a mistake is VOIDED (with a reason)
-- and the balance goes back up. Only the platform admin records or voids payouts.
--
-- outstanding = ledger balance (all-time) - paid to the restaurant + paid to the platform
--   > 0  the platform still owes the restaurant      (record a 'to_restaurant' payout)
--   < 0  the restaurant still owes the platform      (record a 'to_platform' payout)
-- A payout may never be bigger than what is outstanding in its direction (no accidental overpaying).

create table public.payouts (
  id            bigint generated always as identity primary key,
  restaurant_id bigint        not null references public.restaurants (id) on delete restrict,
  direction     text          not null check (direction in ('to_restaurant', 'to_platform')),
  amount        numeric(12,2) not null check (amount > 0 and amount <= 1000000000),
  method        text          not null check (method in ('bank_transfer', 'cash', 'other')),
  reference     text          check (reference is null or length(reference) between 1 and 100),
  note          text          check (note is null or length(note) <= 255),
  recorded_by   uuid          references public.profiles (id) on delete set null,
  created_at    timestamptz   not null default now(),
  voided_at     timestamptz,
  void_reason   text          check (void_reason is null or length(void_reason) between 1 and 255),
  constraint chk_payout_void check ((voided_at is null) = (void_reason is null)),
  constraint chk_payout_ref  check (method <> 'bank_transfer' or reference is not null)
);
create index idx_payouts_restaurant_created on public.payouts (restaurant_id, created_at);
create index idx_payouts_recorded_by on public.payouts (recorded_by);
-- The same bank reference cannot be recorded twice for one restaurant (stops a double-click or a repeated entry).
create unique index uq_payouts_reference on public.payouts (restaurant_id, reference) where reference is not null and voided_at is null;

alter table public.payouts enable row level security;
create policy payouts_select on public.payouts for select to authenticated
  using ((select private.is_admin()) or (select private.can_manage(restaurant_id)));
revoke all on public.payouts from public, anon, authenticated;
grant select on public.payouts to authenticated;
grant all on public.payouts to service_role;

-- One restaurant's running balance (all time, not tied to a report period).
create function private.restaurant_balance(p_restaurant bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  with l as (
    select coalesce(sum(restaurant_share) filter (where payment_method = 'online'), 0)
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
revoke execute on function private.restaurant_balance(bigint) from public, anon, authenticated;

create function public.admin_record_payout(p_restaurant bigint, p_direction text, p_amount numeric, p_method text,
                                           p_reference text, p_note text) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_ref text := nullif(btrim(p_reference), ''); v_note text := nullif(btrim(p_note), '');
  v_out numeric; v_id bigint;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only a platform admin can record payouts' using errcode = '42501'; end if;
  if p_direction is null or p_direction not in ('to_restaurant', 'to_platform') then
    raise exception 'Choose who was paid: the restaurant or the platform' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 or p_amount <> round(p_amount, 2) then
    raise exception 'The amount must be more than 0, with at most 2 decimals' using errcode = '22023';
  end if;
  if p_method is null or p_method not in ('bank_transfer', 'cash', 'other') then
    raise exception 'Choose bank transfer, cash or other' using errcode = '22023';
  end if;
  if p_method = 'bank_transfer' and v_ref is null then
    raise exception 'A bank transfer needs its reference' using errcode = '22023';
  end if;
  if length(coalesce(v_ref, '')) > 100 or length(coalesce(v_note, '')) > 255 then
    raise exception 'Reference is at most 100 characters and the note at most 255' using errcode = '22023';
  end if;

  -- Lock the restaurant so two payouts recorded at the same moment cannot both fit inside the same balance.
  perform 1 from public.restaurants where id = p_restaurant for update;
  if not found then raise exception 'Restaurant not found' using errcode = 'P0002'; end if;
  v_out := (private.restaurant_balance(p_restaurant) ->> 'outstanding')::numeric;

  if p_direction = 'to_restaurant' then
    if v_out <= 0 then raise exception 'The platform does not owe this restaurant anything right now' using errcode = '55000'; end if;
    if p_amount > v_out then raise exception 'That is more than the platform owes (%)', v_out using errcode = '55000'; end if;
  else
    if v_out >= 0 then raise exception 'This restaurant does not owe the platform anything right now' using errcode = '55000'; end if;
    if p_amount > -v_out then raise exception 'That is more than the restaurant owes (%)', -v_out using errcode = '55000'; end if;
  end if;

  insert into public.payouts (restaurant_id, direction, amount, method, reference, note, recorded_by)
  values (p_restaurant, p_direction, p_amount, p_method, v_ref, v_note, v_uid) returning id into v_id;
  return v_id;
end $$;

create function public.admin_void_payout(p_payout bigint, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_reason text := nullif(btrim(p_reason), ''); v_rest bigint; v_voided timestamptz;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only a platform admin can void payouts' using errcode = '42501'; end if;
  if v_reason is null or length(v_reason) > 255 then
    raise exception 'A reason (at most 255 characters) is required to void a payout' using errcode = '22023';
  end if;
  select restaurant_id, voided_at into v_rest, v_voided from public.payouts where id = p_payout for update;
  if not found then raise exception 'Payout not found' using errcode = 'P0002'; end if;
  if v_voided is not null then raise exception 'This payout is already voided' using errcode = '55000'; end if;
  update public.payouts set voided_at = now(), void_reason = v_reason where id = p_payout;
end $$;

-- Balances of every live restaurant (admin) ...
create function public.report_balances() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only a platform admin can see all balances' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg((private.restaurant_balance(r.id) || jsonb_build_object('name', r.name, 'status', r.status)) order by r.name)
    from public.restaurants r where r.status in ('active', 'suspended')), '[]'::jsonb);
end $$;

-- ... or one restaurant's own (admin, owner or manager).
create function public.report_my_balance(p_restaurant bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_restaurant is null or not (select private.is_admin() or private.can_manage(p_restaurant)) then
    raise exception 'Only the restaurant''s owner or manager can see its balance' using errcode = '42501';
  end if;
  if not exists (select 1 from public.restaurants where id = p_restaurant) then raise exception 'Restaurant not found' using errcode = 'P0002'; end if;
  return private.restaurant_balance(p_restaurant);
end $$;

-- Payout history, newest first, including voided ones (they stay visible with their reason).
create function public.list_payouts(p_restaurant bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_restaurant is null or not (select private.is_admin() or private.can_manage(p_restaurant)) then
    raise exception 'Only the restaurant''s owner or manager can see its payouts' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'direction', direction, 'amount', amount, 'method', method, 'reference', reference,
             'note', note, 'created_at', created_at, 'voided_at', voided_at, 'void_reason', void_reason) order by id desc)
    from public.payouts where restaurant_id = p_restaurant), '[]'::jsonb);
end $$;

revoke execute on function public.admin_record_payout(bigint, text, numeric, text, text, text), public.admin_void_payout(bigint, text),
  public.report_balances(), public.report_my_balance(bigint), public.list_payouts(bigint) from public, anon;
grant execute on function public.admin_record_payout(bigint, text, numeric, text, text, text), public.admin_void_payout(bigint, text),
  public.report_balances(), public.report_my_balance(bigint), public.list_payouts(bigint) to authenticated, service_role;
