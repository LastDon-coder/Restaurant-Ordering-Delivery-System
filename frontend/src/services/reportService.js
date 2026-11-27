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

// ---- payouts (recorded by the platform admin only; owners and managers can read) ----
export async function getBalances() {
  const { data, error } = await supabase.rpc('report_balances');
  if (error) throw error;
  return data ?? [];
}

export async function getMyBalance(restaurantId) {
  const { data, error } = await supabase.rpc('report_my_balance', { p_restaurant: restaurantId });
  if (error) throw error;
  return data;
}

export async function listPayouts(restaurantId) {
  const { data, error } = await supabase.rpc('list_payouts', { p_restaurant: restaurantId });
  if (error) throw error;
  return data ?? [];
}

// direction: 'to_restaurant' | 'to_platform'; method: 'bank_transfer' | 'cash' | 'other'
export async function recordPayout({ restaurantId, direction, amount, method, reference, note }) {
  const { data, error } = await supabase.rpc('admin_record_payout', {
    p_restaurant: restaurantId, p_direction: direction, p_amount: amount, p_method: method,
    p_reference: reference || null, p_note: note || null,
  });
  if (error) throw error;
  return data;
}

export async function voidPayout(payoutId, reason) {
  const { error } = await supabase.rpc('admin_void_payout', { p_payout: payoutId, p_reason: reason });
  if (error) throw error;
}
