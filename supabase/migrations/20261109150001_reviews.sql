-- 010: reviews and ratings.
--  * food_reviews  : one review per ORDERED ITEM, only after the order is delivered. Starts 'pending'; an admin
--                    approves or hides it. Only approved reviews are public (through the functions below).
--  * order_ratings : one rating per ORDER (overall + optional delivery), only after delivery. Private: the
--                    customer who wrote it, staff and admins can read it.
-- WHY functions for writing: clients get NO insert/update/delete on these tables, so the "delivered only",
-- "owner only", "once only" and "pending first" rules cannot be skipped by calling the API directly.
-- Error codes: 28000=401, 42501=403, P0002=404, 22023=400, 55000=409.

create type public.review_status as enum ('pending', 'approved', 'hidden');

create table public.food_reviews (
  id            bigint generated always as identity primary key,
  order_item_id bigint not null unique references public.order_items (id) on delete cascade, -- UNIQUE = once per ordered item
  food_id       bigint not null references public.food_items (id) on delete cascade,
  user_id       uuid   not null references public.profiles (id) on delete cascade,
  rating        smallint not null check (rating between 1 and 5),
  comment       text check (comment is null or length(comment) between 1 and 500),
  status        public.review_status not null default 'pending',
  moderated_by  uuid references public.profiles (id) on delete set null,
  moderated_at  timestamptz,
  created_at    timestamptz not null default now()
);
create index idx_food_reviews_food_status on public.food_reviews (food_id, status);   -- public lists and averages
create index idx_food_reviews_status_created on public.food_reviews (status, created_at); -- admin queue
create index idx_food_reviews_user on public.food_reviews (user_id);
create index idx_food_reviews_moderated_by on public.food_reviews (moderated_by);

create table public.order_ratings (
  id              bigint generated always as identity primary key,
  order_id        bigint not null unique references public.orders (id) on delete cascade, -- once per order
  user_id         uuid   not null references public.profiles (id) on delete cascade,
  rating          smallint not null check (rating between 1 and 5),
  delivery_rating smallint check (delivery_rating is null or delivery_rating between 1 and 5),
  comment         text check (comment is null or length(comment) between 1 and 500),
  created_at      timestamptz not null default now()
);
create index idx_order_ratings_user on public.order_ratings (user_id);
create index idx_order_ratings_created on public.order_ratings (created_at desc);

alter table public.food_reviews  enable row level security;
alter table public.order_ratings enable row level security;
grant select on public.food_reviews, public.order_ratings to authenticated;   -- read only; writes go through functions
create policy food_reviews_own   on public.food_reviews  for select to authenticated using (user_id = (select auth.uid()));
create policy food_reviews_admin on public.food_reviews  for select to authenticated using ((select private.is_admin()));
create policy order_ratings_own   on public.order_ratings for select to authenticated using (user_id = (select auth.uid()));
create policy order_ratings_staff on public.order_ratings for select to authenticated using ((select private.is_staff_or_admin()));

-- ---------- customer: write a review / rating (delivered orders only, once) ----------
create function public.submit_food_review(p_order_item_id bigint, p_rating integer, p_comment text default null)
returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_comment text := nullif(trim(p_comment), '');
  r record; v_id bigint;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if (select private.user_role()) is distinct from 'customer' then
    raise exception 'Only customers can write reviews' using errcode = '42501';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception 'Choose a rating from 1 to 5 stars' using errcode = '22023';
  end if;
  if length(coalesce(v_comment, '')) > 500 then
    raise exception 'A review can be at most 500 characters' using errcode = '22023';
  end if;
  select oi.food_id, o.user_id, o.order_status into r
  from public.order_items oi join public.orders o on o.id = oi.order_id
  where oi.id = p_order_item_id;
  if not found or r.user_id <> v_uid then raise exception 'Order item not found' using errcode = 'P0002'; end if;
  if r.order_status <> 'delivered' then
    raise exception 'You can review an item after your order has been delivered' using errcode = '55000';
  end if;
  insert into public.food_reviews (order_item_id, food_id, user_id, rating, comment)
  values (p_order_item_id, r.food_id, v_uid, p_rating, v_comment)
  on conflict (order_item_id) do nothing returning id into v_id;
  if v_id is null then raise exception 'You have already reviewed this item' using errcode = '55000'; end if;
  return v_id;
end $$;

create function public.submit_order_rating(p_order_id bigint, p_rating integer, p_delivery_rating integer default null, p_comment text default null)
returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_comment text := nullif(trim(p_comment), '');
  r record; v_id bigint;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if (select private.user_role()) is distinct from 'customer' then
    raise exception 'Only customers can rate orders' using errcode = '42501';
  end if;
  if p_rating is null or p_rating not between 1 and 5 or (p_delivery_rating is not null and p_delivery_rating not between 1 and 5) then
    raise exception 'Choose a rating from 1 to 5 stars' using errcode = '22023';
  end if;
  if length(coalesce(v_comment, '')) > 500 then
    raise exception 'A comment can be at most 500 characters' using errcode = '22023';
  end if;
  select o.user_id, o.order_status into r from public.orders o where o.id = p_order_id;
  if not found or r.user_id <> v_uid then raise exception 'Order not found' using errcode = 'P0002'; end if;
  if r.order_status <> 'delivered' then
    raise exception 'You can rate an order after it has been delivered' using errcode = '55000';
  end if;
  insert into public.order_ratings (order_id, user_id, rating, delivery_rating, comment)
  values (p_order_id, v_uid, p_rating, p_delivery_rating, v_comment)
  on conflict (order_id) do nothing returning id into v_id;
  if v_id is null then raise exception 'You have already rated this order' using errcode = '55000'; end if;
  return v_id;
end $$;

-- ---------- admin: approve or hide a food review ----------
create function public.moderate_food_review(p_review_id bigint, p_status public.review_status) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not (select private.is_admin()) then raise exception 'Only an admin can moderate reviews' using errcode = '42501'; end if;
  if p_status is null or p_status = 'pending' then
    raise exception 'Choose approved or hidden' using errcode = '22023';
  end if;
  update public.food_reviews set status = p_status, moderated_by = (select auth.uid()), moderated_at = now()
  where id = p_review_id;
  if not found then raise exception 'Review not found' using errcode = 'P0002'; end if;
end $$;

-- ---------- public reads: APPROVED reviews only, no email, reviewer shown as "Ada O." ----------
create function public.get_food_ratings() returns table (food_id bigint, avg_rating numeric, review_count bigint)
language sql stable security definer set search_path = '' as $$
  select r.food_id, round(avg(r.rating)::numeric, 1), count(*)
  from public.food_reviews r where r.status = 'approved' group by r.food_id $$;

create function public.list_food_reviews(p_food_id bigint, p_limit integer default 10, p_offset integer default 0)
returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) from (
    select r.rating, r.comment, r.created_at,
           p.first_name || ' ' || left(p.last_name, 1) || '.' as reviewer
    from public.food_reviews r join public.profiles p on p.id = r.user_id
    where r.food_id = p_food_id and r.status = 'approved'
    order by r.created_at desc
    limit least(greatest(coalesce(p_limit, 10), 1), 50) offset greatest(coalesce(p_offset, 0), 0)
  ) x $$;

revoke execute on function public.submit_food_review(bigint, integer, text), public.submit_order_rating(bigint, integer, integer, text),
  public.moderate_food_review(bigint, public.review_status), public.get_food_ratings(), public.list_food_reviews(bigint, integer, integer)
  from public, anon;
grant execute on function public.submit_food_review(bigint, integer, text), public.submit_order_rating(bigint, integer, integer, text),
  public.moderate_food_review(bigint, public.review_status) to authenticated;
grant execute on function public.get_food_ratings(), public.list_food_reviews(bigint, integer, integer) to anon, authenticated;
