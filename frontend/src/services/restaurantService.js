import { supabase } from './supabase';

// Public: active restaurants only (closed ones included so the page can grey them out). Search is by name, done by the database.
export async function listRestaurants(search = '') {
  const { data, error } = await supabase.rpc('list_restaurants', { p_search: search.trim() || null });
  if (error) throw error;
  return (data ?? []).map((r) => ({ ...r, rating_avg: r.rating_avg == null ? null : Number(r.rating_avg), rating_count: Number(r.rating_count) }));
}

export async function getRestaurant(slug) {
  const { data, error } = await supabase.rpc('get_restaurant', { p_slug: slug });
  if (error) throw error;
  return data;
}

// RLS hides inactive categories, sold-out food and non-active restaurants; we only narrow to one restaurant.
export async function fetchRestaurantMenu(restaurantId) {
  const [categories, foods] = await Promise.all([
    supabase.from('categories').select('id, category_name, description').eq('restaurant_id', restaurantId).order('id'),
    supabase.from('food_items').select('id, category_id, food_name, description, price, image_url').eq('restaurant_id', restaurantId).order('id'),
  ]);
  if (categories.error) throw categories.error;
  if (foods.error) throw foods.error;
  return { categories: categories.data, foods: foods.data };
}
