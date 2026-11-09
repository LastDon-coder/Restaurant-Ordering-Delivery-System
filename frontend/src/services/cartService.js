import { supabase } from './supabase';

// Every price and total in the cart is calculated by the database (get_cart / add_to_cart).
// The browser only ever sends food ids and quantities.
export async function getCart() {
  const { data, error } = await supabase.rpc('get_cart');
  if (error) throw error;
  return data;
}

export async function addToCart(foodId, quantity = 1) {
  const { data, error } = await supabase.rpc('add_to_cart', { p_food_id: foodId, p_quantity: quantity });
  if (error) throw error;
  return data; // the updated cart
}

// Absolute quantity (1-50). Row Level Security guarantees a customer can only touch their own cart lines.
export async function setItemQuantity(itemId, quantity) {
  const { data, error } = await supabase.from('cart_items').update({ quantity }).eq('id', itemId).select('id');
  if (error) throw error;
  if (!data || data.length === 0) throw Object.assign(new Error('Cart item not found'), { code: 'P0002' });
}

export async function removeItem(itemId) {
  const { error } = await supabase.from('cart_items').delete().eq('id', itemId);
  if (error) throw error;
}

// Delivery areas the customer can pick (RLS only returns active ones) and the server's price for the chosen one.
export async function listZones() {
  const { data, error } = await supabase.from('delivery_zones').select('id, zone_name, extra_fee').eq('is_active', true).order('zone_name');
  if (error) throw error;
  return data;
}

export async function getDeliveryQuote(zoneId) {
  const { data, error } = await supabase.rpc('delivery_quote', { p_zone_id: zoneId ?? null });
  if (error) throw error;
  return data; // { subtotal, delivery_fee, total, zone_name }
}
