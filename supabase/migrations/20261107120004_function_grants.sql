-- 004: who may call the functions. Postgres gives EXECUTE to PUBLIC by default and Supabase also grants it to
-- anon/authenticated, so we revoke first and then grant only to signed-in users.
revoke execute on function public.get_cart(), public.add_to_cart(bigint, integer),
  public.place_order(jsonb, public.payment_method),
  public.change_order_status(bigint, public.order_status, text) from public, anon;
grant execute on function public.get_cart(), public.add_to_cart(bigint, integer),
  public.place_order(jsonb, public.payment_method),
  public.change_order_status(bigint, public.order_status, text) to authenticated;

revoke execute on function private.delivery_fee(), private.allowed_next(public.order_status) from public, anon;
grant  execute on function private.delivery_fee(), private.allowed_next(public.order_status) to authenticated, service_role;
