-- 012: version 2, Phase 1: tenancy foundation (multiple restaurants). DATABASE ONLY: nothing visible changes.
-- v1 keeps working untouched. Every v1 row becomes "Restaurant #1". Phase 2 rewrites the policies and functions to be
-- restaurant-aware and then removes the temporary DEFAULT 1 added below.
--
-- WHY restaurant_id on rows (not a database per restaurant): one set of tables, one set of functions, and the database
-- itself (foreign keys + RLS) keeps restaurants apart. A composite foreign key such as (category_id, restaurant_id)
-- makes it IMPOSSIBLE to attach a restaurant's food to another restaurant's category, even with a bug in our code.

create type public.restaurant_status as enum ('pending', 'active', 'rejected', 'suspended');
create type public.restaurant_member_role as enum ('owner', 'manager', 'staff');

create table public.restaurants (
  id                 bigint generated always as identity primary key,
  name               text not null check (length(btrim(name)) between 2 and 100),
  slug               text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(slug) between 3 and 60),
  description        text check (length(description) <= 1000),
  logo_url           text check (length(logo_url) <= 500),
  phone              text check (length(phone) <= 30),
  address            text check (length(address) <= 255),
  is_open            boolean not null default true,         -- owner's "open / closed" switch
  status             public.restaurant_status not null default 'pending',
  status_reason      text check (length(status_reason) <= 500),  -- why it was rejected or suspended
  base_delivery_fee  numeric(10,2) not null default 0 check (base_delivery_fee >= 0 and base_delivery_fee <= 100000),
  commission_percent numeric(5,2) not null default 0 check (commission_percent >= 0 and commission_percent <= 100),
  created_by         uuid references public.profiles (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index idx_restaurants_status on public.restaurants (status);
create index idx_restaurants_created_by on public.restaurants (created_by);
create trigger trg_restaurants_touch before update on public.restaurants
  for each row execute function private.touch_updated_at();

-- Who works for which restaurant. Composite primary key = a person can hold only ONE role per restaurant.
create table public.restaurant_members (
  restaurant_id bigint not null references public.restaurants (id) on delete cascade,
  user_id       uuid   not null references public.profiles (id) on delete cascade,
  member_role   public.restaurant_member_role not null,
  created_at    timestamptz not null default now(),
  primary key (restaurant_id, user_id)
);
create index idx_restaurant_members_user on public.restaurant_members (user_id);   -- "which restaurants am I in?"

-- Restaurant #1 = everything that exists today. Its fee starts from the current v1 setting.
insert into public.restaurants (name, slug, status, base_delivery_fee, created_by)
values ('Restaurant', 'restaurant', 'active', private.delivery_fee(),
        (select id from public.profiles where role = 'admin' order by created_at limit 1));
do $$ begin
  if (select id from public.restaurants where slug = 'restaurant') <> 1 then
    raise exception 'Restaurant #1 must have id 1 (the temporary column defaults rely on it)';
  end if;
end $$;

-- Staff of v1 become members of Restaurant #1 (profiles.role = 'staff' still works until Phase 2).
insert into public.restaurant_members (restaurant_id, user_id, member_role)
select 1, id, 'staff' from public.profiles where role = 'staff';
-- The first admin also owns Restaurant #1 (later, owners manage a restaurant without being platform admins).
insert into public.restaurant_members (restaurant_id, user_id, member_role)
select 1, created_by, 'owner' from public.restaurants where id = 1 and created_by is not null
on conflict do nothing;

-- Helpers used by the Phase 2 policies. All three ignore deactivated people and restaurants that are not active.
-- is_member = may work inside this restaurant (any member, or a platform admin).
-- can_manage = may change its menu, fees, team (owner/manager, or a platform admin).
create function private.member_role(p_restaurant bigint) returns public.restaurant_member_role
language sql stable security definer set search_path = '' as $$
  select m.member_role
  from public.restaurant_members m
  join public.restaurants r on r.id = m.restaurant_id and r.status = 'active'
  join public.profiles p on p.id = m.user_id and p.is_active
  where m.restaurant_id = p_restaurant and m.user_id = (select auth.uid())
$$;
create function private.is_member(p_restaurant bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select (select private.is_admin()) or (select private.member_role(p_restaurant)) is not null
$$;
create function private.can_manage(p_restaurant bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select (select private.is_admin()) or coalesce((select private.member_role(p_restaurant)) in ('owner', 'manager'), false)
$$;
revoke execute on function private.member_role(bigint), private.is_member(bigint), private.can_manage(bigint) from public, anon;
grant  execute on function private.member_role(bigint), private.is_member(bigint), private.can_manage(bigint) to authenticated, service_role;

-- Tag the existing data. ADD COLUMN ... DEFAULT 1 fills every existing row with 1 in one step (no table rewrite).
-- The DEFAULT is TEMPORARY: it keeps v1's functions and forms (which do not know about restaurants yet) working.
alter table public.categories     add column restaurant_id bigint not null default 1 references public.restaurants (id) on delete restrict;
alter table public.food_items     add column restaurant_id bigint not null default 1 references public.restaurants (id) on delete restrict;
alter table public.delivery_zones add column restaurant_id bigint not null default 1 references public.restaurants (id) on delete restrict;
alter table public.orders         add column restaurant_id bigint not null default 1 references public.restaurants (id) on delete restrict;
-- A cart belongs to one restaurant once it has items; an empty cart has none (Phase 3 sets and clears it).
alter table public.carts          add column restaurant_id bigint references public.restaurants (id) on delete set null;
update public.carts set restaurant_id = 1 where exists (select 1 from public.cart_items ci where ci.cart_id = carts.id);

create index idx_categories_restaurant     on public.categories (restaurant_id);
create index idx_food_items_restaurant     on public.food_items (restaurant_id);
create index idx_delivery_zones_restaurant on public.delivery_zones (restaurant_id);
create index idx_orders_restaurant_status  on public.orders (restaurant_id, order_status, created_at desc);  -- the staff board query
create index idx_carts_restaurant          on public.carts (restaurant_id);

-- Names only need to be unique INSIDE a restaurant. (The old global unique indexes are dropped in Phase 2, together
-- with the functions that rely on them, so v1 keeps behaving exactly the same until then.)
create unique index uq_categories_restaurant_name on public.categories (restaurant_id, lower(btrim(category_name)));
create unique index uq_delivery_zones_restaurant_name on public.delivery_zones (restaurant_id, lower(btrim(zone_name)));

-- Cross-restaurant guards. A foreign key can only point at a UNIQUE target, so each parent exposes (id, restaurant_id).
alter table public.categories     add constraint uq_categories_id_restaurant     unique (id, restaurant_id);
alter table public.delivery_zones add constraint uq_delivery_zones_id_restaurant unique (id, restaurant_id);
-- Food must be in a category of ITS OWN restaurant.
alter table public.food_items add constraint fk_food_items_category_same_restaurant
  foreign key (category_id, restaurant_id) references public.categories (id, restaurant_id) on update cascade;
-- An order may only use a delivery area of ITS OWN restaurant. When a zone is deleted only delivery_zone_id is nulled
-- (the column list after SET NULL is PostgreSQL 15+), never restaurant_id.
alter table public.orders add constraint fk_orders_zone_same_restaurant
  foreign key (delivery_zone_id, restaurant_id) references public.delivery_zones (id, restaurant_id) on delete set null (delivery_zone_id);

-- Row Level Security. New tables get no automatic access: revoke first, then grant only what is needed.
alter table public.restaurants enable row level security;
alter table public.restaurant_members enable row level security;
revoke all on public.restaurants, public.restaurant_members from public, anon, authenticated;
grant select on public.restaurants to anon, authenticated;                       -- the public restaurant list
grant insert, update, delete on public.restaurants to authenticated;             -- admin only, enforced by the policy below
grant select, insert, update, delete on public.restaurant_members to authenticated;

-- Everyone (even logged out) sees ACTIVE restaurants. Pending, rejected and suspended ones are visible only to
-- the person who applied, its members, and platform admins.
create policy restaurants_public_read on public.restaurants for select to anon, authenticated using (status = 'active');
create policy restaurants_own_read on public.restaurants for select to authenticated
  using (created_by = (select auth.uid())
         or exists (select 1 from public.restaurant_members m where m.restaurant_id = restaurants.id and m.user_id = (select auth.uid())));
create policy restaurants_admin_all on public.restaurants for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

create policy members_own_read on public.restaurant_members for select to authenticated using (user_id = (select auth.uid()));
create policy members_manager_read on public.restaurant_members for select to authenticated using ((select private.can_manage(restaurant_id)));
create policy members_admin_all on public.restaurant_members for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
