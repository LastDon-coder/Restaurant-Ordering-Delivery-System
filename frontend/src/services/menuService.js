import { supabase } from './supabase';

// RLS already hides inactive categories and sold-out foods from the public, so no extra filtering is needed here.
export async function fetchMenu() {
  const [categories, foods] = await Promise.all([
    supabase.from('categories').select('id, category_name, description').order('id'),
    supabase
      .from('food_items')
      .select('id, category_id, food_name, description, price, image_url')
      .order('id'),
  ]);
  if (categories.error) throw categories.error;
  if (foods.error) throw foods.error;
  return { categories: categories.data, foods: foods.data };
}
