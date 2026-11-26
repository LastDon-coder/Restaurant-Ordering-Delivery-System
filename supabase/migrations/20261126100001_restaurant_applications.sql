-- Version 2, Phase 4a: restaurants apply themselves, the platform admin approves / rejects / suspends.
--
-- Flow: a signed-in customer applies -> a PENDING restaurant is created with that person as OWNER (the membership grants
-- nothing while pending) -> every active admin is emailed -> admin approves (the owner's account becomes a "staff" account
-- and the restaurant goes live) or rejects with a reason. The applicant is emailed the decision.

------------------------------------------------------------------------------------------------------------------
-- 1. The email outbox can now carry mail that is not about an order
------------------------------------------------------------------------------------------------------------------
alter table private.notification_outbox alter column order_id drop not null;
alter table private.notification_outbox drop constraint if exists notification_outbox_kind_check;
alter table private.notification_outbox add constraint notification_outbox_kind_check
  check (kind in ('order_received', 'order_status', 'new_order', 'rider_assigned', 'restaurant_pending', 'restaurant_decision'));

create function private.enqueue_plain(p_key text, p_kind text, p_email text, p_name text, p_payload jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into private.notification_outbox (dedupe_key, kind, order_id, to_email, to_name, payload)
  values (p_key, p_kind, null, p_email, p_name, p_payload)
  on conflict (dedupe_key) do nothing
$$;
revoke execute on function private.enqueue_plain(text, text, text, text, jsonb) from public, anon, authenticated;

------------------------------------------------------------------------------------------------------------------
-- 2. Applying
------------------------------------------------------------------------------------------------------------------
create function public.submit_restaurant_application(p_name text, p_description text, p_phone text, p_address text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_name text := btrim(p_name); v_desc text := nullif(btrim(p_description), ''); v_phone text := nullif(btrim(p_phone), '');
  v_addr text := nullif(btrim(p_address), '');
  v_base text; v_slug text; v_id bigint; v_applicant text; v_admin record;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and is_active and role = 'customer') then
    raise exception 'Only a customer account can apply. Use a separate account for your restaurant.' using errcode = '42501';
  end if;
  if v_name is null or length(v_name) not between 2 and 100 then
    raise exception 'Restaurant name must be 2 to 100 characters' using errcode = '22023';
  end if;
  if v_phone is null or length(v_phone) > 30 or v_addr is null or length(v_addr) > 255 or length(coalesce(v_desc, '')) > 1000 then
    raise exception 'A phone number and an address are required (address max 255, description max 1000)' using errcode = '22023';
  end if;
  -- One open application per person: stops someone flooding the admin queue.
  if exists (select 1 from public.restaurants where created_by = v_uid and status = 'pending') then
    raise exception 'You already have an application waiting for review' using errcode = '55000';
  end if;

  v_base := trim(both '-' from regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g'));
  if length(v_base) < 3 then v_base := 'restaurant'; end if;
  v_base := left(v_base, 50);
  v_slug := v_base;
  while exists (select 1 from public.restaurants where slug = v_slug) loop
    v_slug := v_base || '-' || substr(md5(random()::text), 1, 4);
  end loop;

  insert into public.restaurants (name, slug, description, phone, address, status, created_by)
  values (v_name, v_slug, v_desc, v_phone, v_addr, 'pending', v_uid) returning id into v_id;
  insert into public.restaurant_members (restaurant_id, user_id, member_role) values (v_id, v_uid, 'owner');

  select btrim(concat_ws(' ', first_name, last_name)) into v_applicant from public.profiles where id = v_uid;
  for v_admin in
    select u.email, p.first_name, p.id from public.profiles p join auth.users u on u.id = p.id
    where p.role = 'admin' and p.is_active and private.mail_ok(u.email)
  loop
    perform private.enqueue_plain('rest-pending:' || v_id || ':' || v_admin.id, 'restaurant_pending', v_admin.email, v_admin.first_name,
      jsonb_build_object('restaurant_id', v_id, 'restaurant_name', v_name, 'applicant', v_applicant, 'phone', v_phone, 'address', v_addr));
  end loop;
  perform private.kick_notifier();
  return v_id;
end $$;

------------------------------------------------------------------------------------------------------------------
-- 3. Deciding (platform admin only)
------------------------------------------------------------------------------------------------------------------
-- decision: approve (pending -> active), reject (pending -> rejected, reason required),
--           suspend (active -> suspended, reason required), reinstate (suspended -> active).
create function public.admin_decide_restaurant(p_restaurant bigint, p_decision text, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_r record; v_reason text := nullif(btrim(p_reason), ''); v_to public.restaurant_status; v_owner record;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only an admin can decide on restaurants' using errcode = '42501'; end if;
  if length(coalesce(v_reason, '')) > 500 then raise exception 'Reason is too long (max 500)' using errcode = '22023'; end if;

  select id, name, status into v_r from public.restaurants where id = p_restaurant for update;
  if not found then raise exception 'Restaurant not found' using errcode = 'P0002'; end if;

  if p_decision = 'approve' and v_r.status = 'pending' then v_to := 'active';
  elsif p_decision = 'reject' and v_r.status = 'pending' then v_to := 'rejected';
  elsif p_decision = 'suspend' and v_r.status = 'active' then v_to := 'suspended';
  elsif p_decision = 'reinstate' and v_r.status = 'suspended' then v_to := 'active';
  elsif p_decision in ('approve', 'reject', 'suspend', 'reinstate') then
    raise exception 'A % restaurant cannot be "%"', v_r.status, p_decision using errcode = '55000';
  else
    raise exception 'Decision must be approve, reject, suspend or reinstate' using errcode = '22023';
  end if;
  if v_to in ('rejected', 'suspended') and v_reason is null then
    raise exception 'Please give a reason' using errcode = '22023';
  end if;

  update public.restaurants set status = v_to, status_reason = case when v_to in ('rejected', 'suspended') then v_reason else null end
  where id = p_restaurant;

  -- Approval: the owner's customer account becomes a restaurant (staff) account. Only owners of this restaurant, only if still a customer.
  if p_decision = 'approve' then
    update public.profiles set role = 'staff'
    where role = 'customer' and id in (select user_id from public.restaurant_members where restaurant_id = p_restaurant and member_role = 'owner');
  end if;

  for v_owner in
      select u.email, p.first_name, p.id from public.restaurant_members m
      join public.profiles p on p.id = m.user_id join auth.users u on u.id = m.user_id
      where m.restaurant_id = p_restaurant and m.member_role = 'owner' and private.mail_ok(u.email)
    loop
      perform private.enqueue_plain('rest-decision:' || p_restaurant || ':' || p_decision || ':' || extract(epoch from now())::bigint || ':' || v_owner.id,
        'restaurant_decision', v_owner.email, v_owner.first_name,
        jsonb_build_object('restaurant_id', p_restaurant, 'restaurant_name', v_r.name, 'decision', p_decision, 'reason', v_reason));
    end loop;
  perform private.kick_notifier();
end $$;

-- The admin's queue: applications with the applicant's details (email only for admins).
create function public.admin_list_restaurants(p_status public.restaurant_status default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only an admin can list restaurants' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'slug', r.slug, 'description', r.description, 'phone', r.phone,
             'address', r.address, 'status', r.status, 'status_reason', r.status_reason, 'is_open', r.is_open, 'created_at', r.created_at,
             'applicant', (select btrim(concat_ws(' ', p.first_name, p.last_name)) || ' <' || u.email || '>'
                           from public.restaurant_members m join public.profiles p on p.id = m.user_id join auth.users u on u.id = m.user_id
                           where m.restaurant_id = r.id and m.member_role = 'owner' order by m.created_at limit 1))
             order by (r.status = 'pending') desc, r.created_at desc)
    from public.restaurants r where p_status is null or r.status = p_status
  ), '[]'::jsonb);
end $$;

revoke execute on function public.submit_restaurant_application(text, text, text, text),
  public.admin_decide_restaurant(bigint, text, text), public.admin_list_restaurants(public.restaurant_status) from public, anon;
grant execute on function public.submit_restaurant_application(text, text, text, text),
  public.admin_decide_restaurant(bigint, text, text), public.admin_list_restaurants(public.restaurant_status) to authenticated, service_role;
