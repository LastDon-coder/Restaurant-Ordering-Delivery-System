-- The composite foreign keys that keep food inside its own restaurant's categories (and orders inside their restaurant's zones)
-- need a covering index, so deleting a category or zone does not scan the whole child table.
create index if not exists idx_food_items_category_restaurant on public.food_items (category_id, restaurant_id);
create index if not exists idx_orders_zone_restaurant on public.orders (delivery_zone_id, restaurant_id);
