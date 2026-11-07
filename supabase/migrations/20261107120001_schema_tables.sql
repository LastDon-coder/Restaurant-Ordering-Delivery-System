-- 001: schemas, enums, tables, role helpers, sign-up trigger.
-- WHY: Supabase Auth owns identity (auth.users). public.profiles holds the app data + role.
-- The role is ALWAYS read from profiles (never from the JWT / user_metadata, which users can edit).

create schema if not exists private;                       -- not exposed through the API
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

create table private.settings (key text primary key, value text not null);
revoke all on private.settings from public, anon, authenticated;
insert into private.settings (key, value) values ('delivery_fee', '500.00');

create type public.app_role        as enum ('customer', 'admin', 'staff', 'rider');
create type public.category_status as enum ('active', 'inactive');
create type public.order_status    as enum ('pending', 'confirmed', 'preparing', 'ready_for_delivery',
                                            'out_for_delivery', 'delivered', 'cancelled', 'rejected', 'failed');
create type public.payment_method  as enum ('online', 'cash_on_delivery', 'bank_transfer');
create type public.payment_status  as enum ('pending', 'paid', 'failed', 'refunded');
create type public.refund_status   as enum ('pending', 'processed', 'failed');
create type public.delivery_status as enum ('assigned', 'picked_up', 'out_for_delivery', 'delivered', 'failed');

create function private.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

create table public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  first_name text not null check (length(first_name) between 1 and 100),
  last_name  text not null check (length(last_name) between 1 and 100),
  phone      text unique check (phone is null or length(phone) between 7 and 20),
  role       public.app_role not null default 'customer',
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_profiles_touch before update on public.profiles
  for each row execute function private.touch_updated_at();

create table public.categories (
  id            bigint generated always as identity primary key,
  category_name text not null unique check (length(category_name) between 1 and 100),
  description   text check (length(description) <= 255),
  image_url     text check (length(image_url) <= 500),
  status        public.category_status not null default 'active'
);

create table public.food_items (
  id           bigint generated always as identity primary key,
  category_id  bigint not null references public.categories (id) on update cascade on delete restrict,
  food_name    text not null check (length(food_name) between 1 and 150),
  description  text,
  price        numeric(10,2) not null check (price >= 0),
  image_url    text check (length(image_url) <= 500),
  is_available boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index idx_food_items_category_available on public.food_items (category_id, is_available);
create trigger trg_food_items_touch before update on public.food_items
  for each row execute function private.touch_updated_at();

create table public.addresses (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references public.profiles (id) on delete cascade,
  street_address text not null check (length(street_address) between 1 and 255),
  city           text not null check (length(city) between 1 and 100),
  state          text not null check (length(state) between 1 and 100),
  landmark       text check (length(landmark) <= 255),
  created_at     timestamptz not null default now()
);
create index idx_addresses_user_id on public.addresses (user_id);

create table public.carts (
  id         bigint generated always as identity primary key,
  user_id    uuid not null unique references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_carts_touch before update on public.carts
  for each row execute function private.touch_updated_at();

-- No price column: cart prices are always read live from food_items (never trust a stored/client price).
create table public.cart_items (
  id       bigint generated always as identity primary key,
  cart_id  bigint not null references public.carts (id) on delete cascade,
  food_id  bigint not null references public.food_items (id) on update cascade on delete cascade,
  quantity integer not null default 1 check (quantity between 1 and 50),
  unique (cart_id, food_id)
);
create index idx_cart_items_food_id on public.cart_items (food_id);

create table public.orders (
  id                      bigint generated always as identity primary key,
  user_id                 uuid not null references public.profiles (id) on delete restrict,
  address_id              bigint not null references public.addresses (id) on delete restrict,
  order_status            public.order_status not null default 'pending',
  subtotal                numeric(10,2) not null,
  delivery_fee            numeric(10,2) not null default 0,
  discount                numeric(10,2) not null default 0,
  total_amount            numeric(10,2) not null,
  delivery_street_address text not null,
  delivery_city           text not null,
  delivery_state          text not null,
  delivery_landmark       text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint chk_orders_amounts check (subtotal >= 0 and delivery_fee >= 0 and discount >= 0),
  constraint chk_orders_total   check (total_amount = subtotal + delivery_fee - discount)
);
create index idx_orders_user_created on public.orders (user_id, created_at);
create index idx_orders_status       on public.orders (order_status);
create index idx_orders_address_id   on public.orders (address_id);
create trigger trg_orders_touch before update on public.orders
  for each row execute function private.touch_updated_at();

-- Snapshot of name + price at order time; subtotal is computed by the database.
create table public.order_items (
  id        bigint generated always as identity primary key,
  order_id  bigint not null references public.orders (id) on delete cascade,
  food_id   bigint not null references public.food_items (id) on update cascade on delete restrict,
  food_name text not null,
  quantity  integer not null check (quantity > 0),
  price     numeric(10,2) not null check (price >= 0),
  subtotal  numeric(12,2) generated always as (quantity * price) stored
);
create index idx_order_items_order_id on public.order_items (order_id);
create index idx_order_items_food_id  on public.order_items (food_id);

create table public.payments (
  id                    bigint generated always as identity primary key,
  order_id              bigint not null unique references public.orders (id) on delete restrict,
  payment_method        public.payment_method not null,
  transaction_reference text unique check (length(transaction_reference) <= 100),
  amount                numeric(10,2) not null check (amount >= 0),
  payment_status        public.payment_status not null default 'pending',
  paid_at               timestamptz,
  created_at            timestamptz not null default now()
);
create index idx_payments_status on public.payments (payment_status);

create table public.payment_refunds (
  id                    bigint generated always as identity primary key,
  payment_id            bigint not null references public.payments (id) on delete restrict,
  transaction_reference text not null unique check (length(transaction_reference) <= 100),
  amount                numeric(10,2) not null check (amount > 0),
  refund_status         public.refund_status not null default 'pending',
  paystack_refund_id    text,
  reason                text not null check (length(reason) <= 255),
  requested_by          uuid references public.profiles (id) on delete set null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create index idx_payment_refunds_payment_id   on public.payment_refunds (payment_id);
create index idx_payment_refunds_requested_by on public.payment_refunds (requested_by);
create trigger trg_payment_refunds_touch before update on public.payment_refunds
  for each row execute function private.touch_updated_at();

create table public.order_status_history (
  id          bigint generated always as identity primary key,
  order_id    bigint not null references public.orders (id) on delete cascade,
  from_status public.order_status,
  to_status   public.order_status not null,
  changed_by  uuid references public.profiles (id) on delete set null,
  reason      text check (length(reason) <= 255),
  created_at  timestamptz not null default now()
);
create index idx_status_history_order_created on public.order_status_history (order_id, created_at);
create index idx_status_history_changed_by    on public.order_status_history (changed_by);

create table public.deliveries (
  id              bigint generated always as identity primary key,
  order_id        bigint not null unique references public.orders (id) on delete restrict,
  rider_id        uuid not null references public.profiles (id) on delete restrict,
  delivery_status public.delivery_status not null default 'assigned',
  assigned_at     timestamptz not null default now(),
  picked_up_at    timestamptz,
  delivered_at    timestamptz
);
create index idx_deliveries_rider_status on public.deliveries (rider_id, delivery_status);

create table public.reviews (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  food_id    bigint not null references public.food_items (id) on delete cascade,
  rating     smallint not null check (rating between 1 and 5),
  comment    text check (length(comment) <= 1000),
  created_at timestamptz not null default now(),
  unique (user_id, food_id)
);
create index idx_reviews_food_id on public.reviews (food_id);

-- Role helpers. SECURITY DEFINER so they can read profiles regardless of RLS (no recursion).
-- A deactivated user has no role at all -> locked out immediately.
create function private.user_role() returns public.app_role
language sql stable security definer set search_path = '' as $$
  select p.role from public.profiles p where p.id = (select auth.uid()) and p.is_active $$;

create function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select private.user_role()) = 'admin', false) $$;

create function private.is_staff_or_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select private.user_role()) in ('admin', 'staff'), false) $$;

revoke execute on function private.user_role(), private.is_admin(), private.is_staff_or_admin() from public, anon;
grant  execute on function private.user_role(), private.is_admin(), private.is_staff_or_admin() to authenticated, service_role;

-- Every sign-up becomes a CUSTOMER, whatever the client sends. Staff/riders/admins are promoted by an admin later.
create function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, first_name, last_name, phone)
  values (
    new.id,
    coalesce(nullif(left(trim(new.raw_user_meta_data ->> 'first_name'), 100), ''), 'Customer'),
    coalesce(nullif(left(trim(new.raw_user_meta_data ->> 'last_name'), 100), ''), 'User'),
    nullif(trim(new.raw_user_meta_data ->> 'phone'), '')
  );
  return new;
end $$;
revoke execute on function private.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();
