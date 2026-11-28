-- Audit fix: the roadmap's permission matrix says a restaurant owner/manager can REQUEST a refund and the platform admin
-- APPROVES it (only the admin can move money back through Paystack). That request step was never built.
-- A request is only a note to the admin; it never moves money. When the admin refunds the order the request closes itself.
create table public.refund_requests (
  id              bigint generated always as identity primary key,
  order_id        bigint      not null references public.orders (id) on delete restrict,
  restaurant_id   bigint      not null references public.restaurants (id) on delete restrict,
  requested_by    uuid        references public.profiles (id) on delete set null,
  reason          text        not null check (length(reason) between 1 and 255),
  status          text        not null default 'open' check (status in ('open', 'done', 'dismissed')),
  resolution_note text        check (resolution_note is null or length(resolution_note) <= 255),
  created_at      timestamptz not null default now(),
  resolved_at     timestamptz,
  resolved_by     uuid        references public.profiles (id) on delete set null,
  constraint chk_refund_request_resolved check ((status = 'open') = (resolved_at is null))
);
create unique index uq_refund_requests_open on public.refund_requests (order_id) where status = 'open';   -- one open request per order
create index idx_refund_requests_restaurant_status on public.refund_requests (restaurant_id, status);
create index idx_refund_requests_order on public.refund_requests (order_id);
create index idx_refund_requests_requested_by on public.refund_requests (requested_by);
create index idx_refund_requests_resolved_by on public.refund_requests (resolved_by);

alter table public.refund_requests enable row level security;
create policy refund_requests_select on public.refund_requests for select to authenticated
  using ((select private.is_admin()) or (select private.can_manage(restaurant_id)));
revoke all on public.refund_requests from public, anon, authenticated;
grant select on public.refund_requests to authenticated;
grant all on public.refund_requests to service_role;

-- Owner or manager of the order's restaurant asks the admin to refund a PAID ONLINE order.
create function public.request_refund(p_order bigint, p_reason text) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid()); v_reason text := nullif(btrim(p_reason), ''); o record; v_id bigint;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if v_reason is null or length(v_reason) > 255 then
    raise exception 'A reason (at most 255 characters) is required' using errcode = '22023';
  end if;
  select ord.id, ord.restaurant_id, p.payment_method, p.payment_status into o
  from public.orders ord join public.payments p on p.order_id = ord.id where ord.id = p_order;
  -- Not on this restaurant's team (or no such order): the order does not exist as far as you are concerned.
  if not found or not (select private.is_member(o.restaurant_id)) then
    raise exception 'Order not found' using errcode = 'P0002';
  end if;
  if not (select private.can_manage(o.restaurant_id)) then
    raise exception 'Only the restaurant''s owner or manager can ask for a refund' using errcode = '42501';
  end if;
  if o.payment_method <> 'online' or o.payment_status <> 'paid' then
    raise exception 'Only a paid online order can be refunded (payment status: %)', o.payment_status using errcode = '55000';
  end if;
  if exists (select 1 from public.refund_requests where order_id = p_order and status = 'open') then
    raise exception 'A refund request for this order is already open' using errcode = '55000';
  end if;
  insert into public.refund_requests (order_id, restaurant_id, requested_by, reason)
  values (p_order, o.restaurant_id, v_uid, v_reason) returning id into v_id;
  return v_id;
end $$;

-- Admin: the queue (p_status = 'open' | 'done' | 'dismissed', or null for all), newest first.
create function public.admin_list_refund_requests(p_status text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only a platform admin can see refund requests' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', q.id, 'order_id', q.order_id, 'restaurant_id', q.restaurant_id, 'restaurant', r.name, 'amount', p.amount,
      'reason', q.reason, 'status', q.status, 'resolution_note', q.resolution_note, 'created_at', q.created_at,
      'requested_by', nullif(btrim(coalesce(u.first_name, '') || ' ' || coalesce(u.last_name, '')), '')) order by q.id desc)
    from public.refund_requests q
    join public.restaurants r on r.id = q.restaurant_id
    join public.payments p on p.order_id = q.order_id
    left join public.profiles u on u.id = q.requested_by
    where p_status is null or q.status = p_status), '[]'::jsonb);
end $$;

-- Admin: turn a request down (with a note). Approving = doing the refund on the Refunds page, which closes the request itself.
create function public.admin_dismiss_refund_request(p_id bigint, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_note text := nullif(btrim(p_note), ''); v_status text;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only a platform admin can dismiss refund requests' using errcode = '42501'; end if;
  if v_note is null or length(v_note) > 255 then raise exception 'A note (at most 255 characters) is required' using errcode = '22023'; end if;
  select status into v_status from public.refund_requests where id = p_id for update;
  if not found then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if v_status <> 'open' then raise exception 'This request is already closed' using errcode = '55000'; end if;
  update public.refund_requests set status = 'dismissed', resolution_note = v_note, resolved_at = now(), resolved_by = (select auth.uid()) where id = p_id;
end $$;

-- The restaurant's own requests with their outcome (owner/manager, or admin).
create function public.list_refund_requests(p_restaurant bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_restaurant is null or not (select private.is_admin() or private.can_manage(p_restaurant)) then
    raise exception 'Only the restaurant''s owner or manager can see its refund requests' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'order_id', order_id, 'reason', reason, 'status', status,
             'resolution_note', resolution_note, 'created_at', created_at) order by id desc)
    from public.refund_requests where restaurant_id = p_restaurant), '[]'::jsonb);
end $$;

-- When the payment is refunded (by the admin, through Paystack) every open request for that order is closed as done.
create function private.trg_refund_request_done() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.payment_status = 'refunded' and old.payment_status is distinct from 'refunded' then
    update public.refund_requests set status = 'done', resolved_at = now()
     where order_id = new.order_id and status = 'open';
  end if;
  return null;
end $$;
create trigger trg_payments_refund_request after update of payment_status on public.payments
  for each row execute function private.trg_refund_request_done();
revoke execute on function private.trg_refund_request_done() from public, anon, authenticated;

revoke execute on function public.request_refund(bigint, text), public.admin_list_refund_requests(text),
  public.admin_dismiss_refund_request(bigint, text), public.list_refund_requests(bigint) from public, anon;
grant execute on function public.request_refund(bigint, text), public.admin_list_refund_requests(text),
  public.admin_dismiss_refund_request(bigint, text), public.list_refund_requests(bigint) to authenticated, service_role;
