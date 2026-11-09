-- 012: remove the original public.reviews table (from migration 001). It let any signed-in customer post a public,
-- unmoderated review for ANY food (no purchase check) and let anonymous visitors read them all. It was empty (0 rows)
-- and is replaced by food_reviews + order_ratings (migration 010), which enforce "delivered orders only, once,
-- approved by an admin before it is public".
drop table public.reviews;
