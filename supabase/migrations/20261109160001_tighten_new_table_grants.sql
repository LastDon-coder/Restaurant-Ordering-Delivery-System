-- 011: Supabase gives every new table in `public` broad default grants (anon + authenticated: all privileges).
-- Row Level Security already kept the data safe, but we also start each new table from NOTHING and grant only what
-- each role needs (defence in depth, and clear 403s instead of silent "0 rows"). Applies to the tables added in
-- migrations 008 (delivery_zones) and 010 (food_reviews, order_ratings).
revoke all on public.food_reviews, public.order_ratings from anon, authenticated;
grant select on public.food_reviews, public.order_ratings to authenticated;
revoke all on public.delivery_zones from anon;
revoke all on public.delivery_zones from authenticated;
grant select, insert, update, delete on public.delivery_zones to authenticated;
