-- 011: order notification emails (outbox pattern).
-- WHY an outbox: sending an email is a call to another company's server. If we did it inside the order transaction,
-- a slow or failing mail provider would make orders fail. Instead the database only WRITES A ROW ("send this email")
-- in the same transaction as the order change (so the row exists if and only if the change committed), and a separate
-- Edge Function (notify) sends the rows through Resend and marks them sent. Failed sends are retried with a back-off.
-- Who gets what: customer = order received, confirmed, preparing, out for delivery. Staff/admins = new order.
-- Rider = a delivery was assigned. Orders from reserved test addresses (@example.com etc.) send nothing.

create extension if not exists pg_net;
create extension if not exists pg_cron;

create table private.notification_outbox (
  id           bigint generated always as identity primary key,
  -- One row per (event, recipient). The UNIQUE key makes every enqueue safe to repeat: no duplicate emails.
  dedupe_key   text not null unique,
  kind         text not null check (kind in ('order_received', 'order_status', 'new_order', 'rider_assigned')),
  order_id     bigint not null references public.orders (id) on delete cascade,
  to_email     text not null,
  to_name      text,
  payload      jsonb not null,
  status       text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed')),
  attempts     integer not null default 0,
  last_error   text,
  send_after   timestamptz not null default now(),
  locked_until timestamptz,
  created_at   timestamptz not null default now(),
  sent_at      timestamptz
);
-- Partial index: the sender only ever looks at unfinished rows, so the index stays tiny however many are sent.
create index idx_outbox_due on private.notification_outbox (send_after) where status in ('pending', 'sending');
create index idx_outbox_order on private.notification_outbox (order_id);
revoke all on private.notification_outbox from public, anon, authenticated;

-- Reserved or fake addresses never get mail (keeps the e2e tests quiet and protects the sender's reputation).
create function private.mail_ok(p_email text) returns boolean
language sql immutable set search_path = '' as $$
  select p_email is not null
     and p_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$'
     and p_email !~* '@(example\.(com|org|net)|[^@]*\.(test|invalid|localhost|example))$'
$$;

-- Everything an email needs, read at enqueue time so the email shows what the customer actually ordered.
create function private.notif_payload(p_order bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'order_id', o.id, 'subtotal', o.subtotal, 'delivery_fee', o.delivery_fee, 'total', o.total_amount,
    'zone', o.delivery_zone_name,
    'address', concat_ws(', ', o.delivery_street_address, o.delivery_city, o.delivery_state, nullif(o.delivery_landmark, '')),
    'payment_method', p.payment_method, 'customer_first_name', c.first_name, 'customer_phone', c.phone,
    'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.food_name, 'quantity', i.quantity, 'price', i.price) order by i.food_name)
                       from public.order_items i where i.order_id = o.id), '[]'::jsonb))
  from public.orders o
  left join public.payments p on p.order_id = o.id
  left join public.profiles c on c.id = o.user_id
  where o.id = p_order
$$;

create function private.enqueue_notification(p_key text, p_kind text, p_order bigint, p_email text, p_name text, p_extra jsonb default '{}')
returns void language sql security definer set search_path = '' as $$
  insert into private.notification_outbox (dedupe_key, kind, order_id, to_email, to_name, payload)
  values (p_key, p_kind, p_order, p_email, p_name, private.notif_payload(p_order) || p_extra)
  on conflict (dedupe_key) do nothing
$$;

-- Wakes the sender straight away. pg_net queues the HTTP call and sends it AFTER the transaction commits
-- (a rolled-back order never triggers it). The endpoint takes no input: it only works through the outbox.
create function private.kick_notifier() returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform net.http_post(
    url := 'https://lnlilnouigqkbddiljzb.supabase.co/functions/v1/notify',
    body := '{}'::jsonb,
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 5000);
end $$;

-- "The order is real and ready for staff": cash orders at creation, online orders once the payment is confirmed.
create function private.notify_order_received(p_order bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare v_email text; v_name text; r record;
begin
  select u.email, c.first_name into v_email, v_name
  from public.orders o join auth.users u on u.id = o.user_id join public.profiles c on c.id = o.user_id
  where o.id = p_order;
  if not private.mail_ok(v_email) then return; end if;   -- test or fake customer: send nothing for this order

  perform private.enqueue_notification('received:' || p_order || ':customer', 'order_received', p_order, v_email, v_name);
  for r in
    select p.id, p.first_name, u.email
    from public.profiles p join auth.users u on u.id = p.id
    where p.role in ('staff', 'admin') and p.is_active
  loop
    if private.mail_ok(r.email) then
      perform private.enqueue_notification('new:' || p_order || ':' || r.id, 'new_order', p_order, r.email, r.first_name);
    end if;
  end loop;
end $$;

-- Triggers must NEVER break the order flow: any error here becomes a warning and the order carries on.
create function private.trg_payments_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  begin
    if (tg_op = 'INSERT' and new.payment_method = 'cash_on_delivery')
       or (tg_op = 'UPDATE' and new.payment_method = 'online' and new.payment_status = 'paid'
           and old.payment_status is distinct from 'paid') then
      perform private.notify_order_received(new.order_id);
      perform private.kick_notifier();
    end if;
  exception when others then
    raise warning 'notification not queued (payments): %', sqlerrm;
  end;
  return null;
end $$;
create trigger trg_payments_notify after insert or update of payment_status on public.payments
  for each row execute function private.trg_payments_notify();

create function private.trg_status_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_email text; v_name text;
begin
  begin
    if new.to_status in ('confirmed', 'preparing', 'out_for_delivery') then
      select u.email, c.first_name into v_email, v_name
      from public.orders o join auth.users u on u.id = o.user_id join public.profiles c on c.id = o.user_id
      where o.id = new.order_id;
      if private.mail_ok(v_email) then
        perform private.enqueue_notification('status:' || new.order_id || ':' || new.to_status, 'order_status', new.order_id,
                                             v_email, v_name, jsonb_build_object('status', new.to_status));
        perform private.kick_notifier();
      end if;
    end if;
  exception when others then
    raise warning 'notification not queued (status): %', sqlerrm;
  end;
  return null;
end $$;
create trigger trg_status_notify after insert on public.order_status_history
  for each row execute function private.trg_status_notify();

create function private.trg_delivery_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_cust text; v_email text; v_name text;
begin
  begin
    if new.rider_id is not null and (tg_op = 'INSERT' or old.rider_id is distinct from new.rider_id) then
      select u.email into v_cust from public.orders o join auth.users u on u.id = o.user_id where o.id = new.order_id;
      select u.email, p.first_name into v_email, v_name from public.profiles p join auth.users u on u.id = p.id where p.id = new.rider_id;
      if private.mail_ok(v_cust) and private.mail_ok(v_email) then
        perform private.enqueue_notification('rider:' || new.order_id || ':' || new.rider_id, 'rider_assigned', new.order_id, v_email, v_name);
        perform private.kick_notifier();
      end if;
    end if;
  exception when others then
    raise warning 'notification not queued (delivery): %', sqlerrm;
  end;
  return null;
end $$;
create trigger trg_delivery_notify after insert or update of rider_id on public.deliveries
  for each row execute function private.trg_delivery_notify();

-- The sender's two calls. Only the service role (the Edge Function) may run them.
-- claim: hands out due rows and LEASES them for 5 minutes. FOR UPDATE SKIP LOCKED means two senders running at the
-- same moment never pick the same row. A sender that crashes simply lets the lease expire and the row is retried.
create function public.claim_notifications(p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  update private.notification_outbox set status = 'failed', last_error = coalesce(last_error, 'gave up after repeated attempts')
  where status = 'sending' and locked_until < now() and attempts >= 5;

  with c as (
    select id from private.notification_outbox
    where attempts < 5 and ((status = 'pending' and send_after <= now()) or (status = 'sending' and locked_until < now()))
    order by id limit least(greatest(coalesce(p_limit, 20), 1), 50)
    for update skip locked),
  u as (
    update private.notification_outbox o
    set status = 'sending', attempts = o.attempts + 1, locked_until = now() + interval '5 minutes'
    from c where o.id = c.id
    returning o.id, o.kind, o.to_email, o.to_name, o.payload, o.attempts)
  select coalesce(jsonb_agg(to_jsonb(u) order by u.id), '[]'::jsonb) into v from u;
  return v;
end $$;

-- finish: success -> sent. Failure -> back to pending with a growing delay (2, 4, 6, 8 minutes), failed after 5 tries.
-- p_permanent = the provider said "this will never work" (bad address): stop at once.
create function public.finish_notification(p_id bigint, p_ok boolean, p_error text default null, p_permanent boolean default false)
returns void language sql security definer set search_path = '' as $$
  update private.notification_outbox
  set status = case when p_ok then 'sent' when p_permanent or attempts >= 5 then 'failed' else 'pending' end,
      sent_at = case when p_ok then now() end,
      last_error = left(p_error, 500),
      send_after = now() + attempts * interval '2 minutes',
      locked_until = null
  where id = p_id and status = 'sending'
$$;

revoke execute on function public.claim_notifications(integer), public.finish_notification(bigint, boolean, text, boolean)
  from public, anon, authenticated;
grant execute on function public.claim_notifications(integer), public.finish_notification(bigint, boolean, text, boolean)
  to service_role;
revoke execute on function private.kick_notifier(), private.enqueue_notification(text, text, bigint, text, text, jsonb),
  private.notify_order_received(bigint), private.notif_payload(bigint) from public, anon, authenticated;

-- Safety net: every minute, if anything is due (a failed send waiting to retry, or a missed wake-up), wake the sender.
select cron.schedule('notify-retry', '* * * * *', $cron$
  select private.kick_notifier() where exists (
    select 1 from private.notification_outbox
    where (status = 'pending' and send_after <= now()) or (status = 'sending' and locked_until < now()))
$cron$);
