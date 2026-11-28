-- Audit fix: the platform's commission rates were readable by anyone.
-- WHY: row-level security only decides WHICH rows you see, not which COLUMNS. The restaurants table had a table-wide SELECT
-- for the public (anon) and for every signed-in user, so anyone with the public API key could request
-- /rest/v1/restaurants?select=commission_percent,delivery_commission_percent (and created_by, status_reason).
-- Fix: column-level grants. The public gets only what the menu pages show. Owners/managers read their rates through
-- list_my_restaurants() and the admin through the report functions (both SECURITY DEFINER), so nothing in the app changes.
revoke select on public.restaurants from anon, authenticated;
grant select (id, name, slug, description, logo_url, phone, address, is_open, status, base_delivery_fee, created_at, updated_at)
  on public.restaurants to anon;
-- Signed-in users additionally see status_reason (RLS limits it to their own restaurants and the admin).
grant select (id, name, slug, description, logo_url, phone, address, is_open, status, status_reason, base_delivery_fee, created_at, updated_at)
  on public.restaurants to authenticated;

-- The Paystack subaccount code is only ever needed by the server; owners read the bank name and last 4 through get_settlement().
revoke select on public.restaurant_settlement from authenticated;
