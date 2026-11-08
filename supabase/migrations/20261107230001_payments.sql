-- 007 (Step 14 on Supabase): payment + refund state changes for the Paystack Edge Functions.
-- WHY: only the SERVER may decide "this order is paid". These functions are callable ONLY by service_role
-- (the Edge Functions); anon/authenticated (every browser) are revoked, so a customer can never mark
-- their own order paid. Amount, currency and ownership are always re-checked here, in one locked transaction.

-- One row per Paystack attempt. A customer can start payment more than once (closed tab, failed card), and
-- each attempt needs its own unique reference, but a late success on an OLD reference must still be matched.
create table public.payment_attempts (
  reference  text primary key check (reference ~ '^ORD-[0-9]{1,10}-[a-f0-9]{16}$'),
  payment_id bigint not null references public.payments (id) on delete restrict,
  created_at timestamptz not null default now()
);
create index idx_payment_attempts_payment_id on public.payment_attempts (payment_id);
alter table public.payment_attempts enable row level security;     -- no policies, no grants: server only
revoke all on public.payment_attempts from public, anon, authenticated;
grant  all on public.payment_attempts to service_role;

-- Start an online payment for MY order. Returns the new reference and the amount in kobo (from the DB row,
-- never from the client).
create function public.pay_start(p_user uuid, p_order_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare o record; v_ref text; v_email text;
begin
  select ord.id, ord.order_status, p.id as payment_id, p.payment_method, p.payment_status, p.amount into o
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

  v_ref := 'ORD-' || o.id || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 16);
  insert into public.payment_attempts (reference, payment_id) values (v_ref, o.payment_id);
  return jsonb_build_object('reference', v_ref, 'amount_kobo', (o.amount * 100)::bigint, 'email', v_email, 'order_id', o.id);
end $$;

-- Who owns this reference? (lets the verify endpoint refuse other people's references)
create function public.pay_lookup(p_reference text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('order_id', o.id, 'user_id', o.user_id, 'payment_status', p.payment_status)
  from public.payment_attempts a
  join public.payments p on p.id = a.payment_id
  join public.orders o on o.id = p.order_id
  where a.reference = p_reference $$;

-- Record the outcome Paystack reported. Idempotent: webhook retries and the verify endpoint can both call it.
create function public.pay_apply_charge(p_reference text, p_amount_kobo bigint, p_currency text, p_success boolean)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p record; v_expected bigint;
begin
  select pay.id, pay.order_id, pay.amount, pay.payment_status, pay.transaction_reference, ord.order_status into p
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

  update public.payments set payment_status = 'paid', paid_at = now(), transaction_reference = p_reference
   where id = p.id;
  return jsonb_build_object(
    'result', case when p.order_status in ('cancelled', 'rejected', 'failed') then 'paid_order_closed' else 'paid' end,
    'order_id', p.order_id, 'payment_status', 'paid');
end $$;

-- Admin refund, step 1: reserve the refund row BEFORE calling Paystack. The unique transaction_reference on
-- payment_refunds means two admins clicking at once can't both refund the same payment.
create function public.pay_reserve_refund(p_admin uuid, p_order_id bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p record; r record; v_reason text := nullif(trim(p_reason), '');
begin
  if not exists (select 1 from public.profiles where id = p_admin and role = 'admin' and is_active) then
    raise exception 'Only an admin can refund payments' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) > 255 then
    raise exception 'A refund reason (max 255 characters) is required' using errcode = '22023';
  end if;

  select pay.id, pay.amount, pay.payment_method, pay.payment_status, pay.transaction_reference into p
  from public.payments pay where pay.order_id = p_order_id for update;
  if not found then raise exception 'Order not found' using errcode = 'P0002'; end if;
  if p.payment_method <> 'online' or p.payment_status <> 'paid' or p.transaction_reference is null then
    raise exception 'Only a paid online payment can be refunded (status: %)', p.payment_status using errcode = '55000';
  end if;

  select rf.id, rf.refund_status into r from public.payment_refunds rf where rf.transaction_reference = p.transaction_reference for update;
  if found then
    if r.refund_status <> 'failed' then
      raise exception 'A refund for this payment is already %', r.refund_status using errcode = '55000';
    end if;
    update public.payment_refunds set refund_status = 'pending', reason = v_reason, requested_by = p_admin, paystack_refund_id = null
     where id = r.id;
  else
    insert into public.payment_refunds (payment_id, transaction_reference, amount, reason, requested_by)
    values (p.id, p.transaction_reference, p.amount, v_reason, p_admin);
  end if;
  return jsonb_build_object('transaction_reference', p.transaction_reference, 'amount_kobo', (p.amount * 100)::bigint);
end $$;

-- Admin refund, step 2 / refund webhooks: record what Paystack said. Idempotent.
create function public.pay_apply_refund(p_transaction_reference text, p_status text, p_paystack_refund_id text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if p_status not in ('pending', 'processed', 'failed') then
    raise exception 'Unknown refund status' using errcode = '22023';
  end if;
  select rf.id, rf.payment_id, rf.refund_status into r
  from public.payment_refunds rf where rf.transaction_reference = p_transaction_reference for update;
  if not found then return jsonb_build_object('result', 'unknown_refund'); end if;
  if r.refund_status = 'processed' then return jsonb_build_object('result', 'already_processed'); end if;

  update public.payment_refunds set refund_status = p_status::public.refund_status,
         paystack_refund_id = coalesce(p_paystack_refund_id, paystack_refund_id)
   where id = r.id;
  if p_status = 'processed' then
    update public.payments set payment_status = 'refunded' where id = r.payment_id;
  end if;
  return jsonb_build_object('result', p_status);
end $$;

revoke execute on function public.pay_start(uuid, bigint), public.pay_lookup(text),
  public.pay_apply_charge(text, bigint, text, boolean), public.pay_reserve_refund(uuid, bigint, text),
  public.pay_apply_refund(text, text, text) from public, anon, authenticated;
grant execute on function public.pay_start(uuid, bigint), public.pay_lookup(text),
  public.pay_apply_charge(text, bigint, text, boolean), public.pay_reserve_refund(uuid, bigint, text),
  public.pay_apply_refund(text, text, text) to service_role;
