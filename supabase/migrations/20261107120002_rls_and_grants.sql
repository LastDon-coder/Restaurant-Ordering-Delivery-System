-- 002: Row Level Security + least-privilege grants.
-- WHY: Supabase grants ALL on new public tables to anon/authenticated by default. We revoke that first,
-- then grant only what each role needs; RLS then decides WHICH ROWS. Money-moving tables (orders, order_items,
-- payments, history, refunds) get NO client write access at all: they change only through the SQL functions
-- in migration 003 (or the service role in Edge Functions).

alter table public.profiles              enable row level security;
alter table public.categories            enable row level security;
alter table public.food_items            enable row level security;
alter table public.addresses             enable row level security;
alter table public.carts                 enable row level security;
alter table public.cart_items            enable row level security;
alter table public.orders                enable row level security;
alter table public.order_items           enable row level security;
alter table public.payments              enable row level security;
alter table public.payment_refunds       enable row level security;
alter table public.order_status_history  enable row level security;
alter table public.deliveries            enable row level security;
alter table public.reviews               enable row level security;

revoke all on all tables in schema public from anon, authenticated;

-- profiles: read own (staff/admin read all); users may edit ONLY name/phone (never role / is_active).
grant select on public.profiles to authenticated;
grant update (first_name, last_name, phone) on public.profiles to authenticated;
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select private.is_staff_or_admin()));
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- categories / food_items: the public menu, admin-managed.
grant select on public.categories, public.food_items to anon;
grant select, insert, update, delete on public.categories, public.food_items to authenticated;

create policy categories_public_read on public.categories for select to anon, authenticated
  using (status = 'active');
create policy categories_admin_all on public.categories for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

create policy food_public_read on public.food_items for select to anon, authenticated
  using (is_available and exists (select 1 from public.categories c where c.id = category_id and c.status = 'active'));
create policy food_staff_read on public.food_items for select to authenticated
  using ((select private.is_staff_or_admin()));
create policy food_admin_all on public.food_items for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

-- addresses: own rows, read-only (created by place_order).
grant select on public.addresses to authenticated;
create policy addresses_select_own on public.addresses for select to authenticated
  using (user_id = (select auth.uid()));

-- carts / cart_items: customers manage their own cart directly; add_to_cart() is the main path.
grant select, insert on public.carts to authenticated;
grant select, insert, update, delete on public.cart_items to authenticated;
create policy carts_select_own on public.carts for select to authenticated
  using (user_id = (select auth.uid()));
create policy carts_insert_own on public.carts for insert to authenticated
  with check (user_id = (select auth.uid()) and (select private.user_role()) = 'customer');

create policy cart_items_select on public.cart_items for select to authenticated
  using (exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid())));
create policy cart_items_insert on public.cart_items for insert to authenticated
  with check (
    (select private.user_role()) = 'customer'
    and exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid()))
    and exists (select 1 from public.food_items f join public.categories cat on cat.id = f.category_id
                where f.id = food_id and f.is_available and cat.status = 'active'));
create policy cart_items_update on public.cart_items for update to authenticated
  using (exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid())))
  with check (exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid())));
create policy cart_items_delete on public.cart_items for delete to authenticated
  using (exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid())));

-- deliveries: a rider sees only their own; staff/admin see all. (Writes come with Step 15.)
grant select on public.deliveries to authenticated;
create policy deliveries_select on public.deliveries for select to authenticated
  using (rider_id = (select auth.uid()) or (select private.is_staff_or_admin()));

-- orders: owner, staff/admin, or the assigned rider. READ ONLY for clients.
grant select on public.orders to authenticated;
create policy orders_select on public.orders for select to authenticated
  using (user_id = (select auth.uid())
         or (select private.is_staff_or_admin())
         or exists (select 1 from public.deliveries d where d.order_id = orders.id and d.rider_id = (select auth.uid())));

-- order_items / payments / history: visible whenever the parent order is visible (orders RLS applies inside).
grant select on public.order_items to authenticated;
create policy order_items_select on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id));

-- Column-level grants hide the Paystack reference (payments) and who made a change (history) from customers.
grant select (id, order_id, payment_method, amount, payment_status, paid_at, created_at) on public.payments to authenticated;
create policy payments_select on public.payments for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id));

grant select (id, order_id, from_status, to_status, reason, created_at) on public.order_status_history to authenticated;
create policy status_history_select on public.order_status_history for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id));

-- refunds: admin only.
grant select on public.payment_refunds to authenticated;
create policy refunds_admin_select on public.payment_refunds for select to authenticated
  using ((select private.is_admin()));

-- reviews: public to read, customers write their own.
grant select on public.reviews to anon, authenticated;
grant insert, update, delete on public.reviews to authenticated;
create policy reviews_read on public.reviews for select to anon, authenticated using (true);
create policy reviews_insert_own on public.reviews for insert to authenticated
  with check (user_id = (select auth.uid()) and (select private.user_role()) = 'customer');
create policy reviews_update_own on public.reviews for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy reviews_delete_own on public.reviews for delete to authenticated
  using (user_id = (select auth.uid()));
