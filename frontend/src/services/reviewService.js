import { supabase } from './supabase';

// Reviews are written ONLY through database functions: they check that the order is yours, delivered, and not
// reviewed yet. The browser just sends the ids, the stars and the text.

// ---- public (the menu) ----
export async function getFoodRatings() {
  const { data, error } = await supabase.rpc('get_food_ratings');
  if (error) throw error;
  return Object.fromEntries((data ?? []).map((r) => [r.food_id, { avg: Number(r.avg_rating), count: Number(r.review_count) }]));
}

export async function listFoodReviews(foodId, limit = 10, offset = 0) {
  const { data, error } = await supabase.rpc('list_food_reviews', { p_food_id: foodId, p_limit: limit, p_offset: offset });
  if (error) throw error;
  return data ?? []; // [{ rating, comment, reviewer, created_at }]
}

// ---- customer ----
export async function submitFoodReview(orderItemId, rating, comment) {
  const { error } = await supabase.rpc('submit_food_review', { p_order_item_id: orderItemId, p_rating: rating, p_comment: comment || null });
  if (error) throw error;
}

export async function submitOrderRating(orderId, rating, deliveryRating, comment) {
  const { error } = await supabase.rpc('submit_order_rating', {
    p_order_id: orderId, p_rating: rating, p_delivery_rating: deliveryRating || null, p_comment: comment || null,
  });
  if (error) throw error;
}

// What this customer already wrote for one order (RLS only returns their own rows).
export async function getMyReviewsForOrder(orderId, orderItemIds) {
  const [foods, rating] = await Promise.all([
    orderItemIds.length
      ? supabase.from('food_reviews').select('order_item_id, rating, comment, status').in('order_item_id', orderItemIds)
      : Promise.resolve({ data: [], error: null }),
    supabase.from('order_ratings').select('rating, delivery_rating, comment').eq('order_id', orderId).maybeSingle(),
  ]);
  if (foods.error) throw foods.error;
  if (rating.error) throw rating.error;
  return { foods: Object.fromEntries(foods.data.map((r) => [r.order_item_id, r])), order: rating.data };
}

// ---- restaurant: order ratings (staff + admin) and food review moderation (admin) ----
export async function listOrderRatings() {
  const { data, error } = await supabase
    .from('order_ratings')
    .select('id, order_id, rating, delivery_rating, comment, created_at, author:profiles!user_id(first_name, last_name)')
    .order('created_at', { ascending: false })
    .limit(100);
  if (error) throw error;
  return data;
}

export async function adminListFoodReviews(status) {
  const { data, error } = await supabase
    .from('food_reviews')
    .select('id, rating, comment, status, created_at, food:food_items(food_name), author:profiles!user_id(first_name, last_name)')
    .eq('status', status)
    .order('created_at', { ascending: false })
    .limit(100);
  if (error) throw error;
  return data;
}

export async function moderateReview(reviewId, status) {
  const { error } = await supabase.rpc('moderate_food_review', { p_review_id: reviewId, p_status: status });
  if (error) throw error;
}
