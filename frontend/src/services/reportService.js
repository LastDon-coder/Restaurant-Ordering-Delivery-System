import { supabase } from './supabase';

// restaurantId = null means "all restaurants" and only works for the platform admin. The server checks who is asking.
export async function getSummary(restaurantId, from, to) {
  const { data, error } = await supabase.rpc('report_summary', { p_restaurant: restaurantId, p_from: from, p_to: to });
  if (error) throw error;
  return data;
}

export async function getSalesByDay(restaurantId, from, to) {
  const { data, error } = await supabase.rpc('report_sales_by_day', { p_restaurant: restaurantId, p_from: from, p_to: to });
  if (error) throw error;
  return data ?? [];
}

export async function getByRestaurant(from, to) {
  const { data, error } = await supabase.rpc('report_by_restaurant', { p_from: from, p_to: to });
  if (error) throw error;
  return data ?? [];
}

// Admin only. Both rates are sent together so a screen can never half-update.
export async function setCommission(restaurantId, foodPercent, deliveryPercent) {
  const { data, error } = await supabase.rpc('admin_set_commission', {
    p_restaurant: restaurantId, p_food_percent: foodPercent, p_delivery_percent: deliveryPercent,
  });
  if (error) throw error;
  return data;
}
