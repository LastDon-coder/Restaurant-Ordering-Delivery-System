import { supabase } from './supabase';

// The address is sent with the order; place_order validates it and re-prices the cart on the server.
// zoneId is optional: no zone = the standard fee. The server prices the order; the browser sends no amounts.
export async function placeOrder(address, paymentMethod, zoneId = null) {
  const { data, error } = await supabase.rpc('place_order', { p_address: address, p_payment_method: paymentMethod, p_zone_id: zoneId });
  if (error) throw error;
  return data; // new order id
}

// RLS limits this to the customer's own orders (staff/admin see all).
export async function getOrder(orderId) {
  const { data, error } = await supabase
    .from('orders')
    .select(
      'id, order_status, subtotal, delivery_fee, discount, total_amount, created_at, delivery_street_address, delivery_city, delivery_state, delivery_landmark, delivery_zone_name, ' +
        'order_items(id, food_name, quantity, price, subtotal), payments(payment_method, payment_status), order_status_history(to_status, reason, created_at)',
    )
    .eq('id', orderId)
    .maybeSingle();
  if (error) throw error;
  return data;
}

// ---- customer: my orders ----
export async function listMyOrders() {
  const { data, error } = await supabase
    .from('orders')
    .select('id, order_status, total_amount, created_at, order_items(food_name, quantity), payments(payment_method, payment_status)')
    .order('created_at', { ascending: false })
    .limit(100); // RLS already limits this to the signed-in customer's orders
  if (error) throw error;
  return data;
}

// A customer may cancel only their OWN order while it is still pending (enforced by change_order_status).
export async function cancelMyOrder(orderId) {
  const { error } = await supabase.rpc('change_order_status', { p_order_id: orderId, p_status: 'cancelled', p_reason: null });
  if (error) throw error;
}

// ---- staff / admin ----
export const ACTIVE = ['pending', 'confirmed', 'preparing', 'ready_for_delivery', 'out_for_delivery'];

export async function listStaffOrders(statuses) {
  let q = supabase
    .from('orders')
    .select(
      'id, order_status, total_amount, created_at, delivery_street_address, delivery_city, delivery_state, delivery_landmark, ' +
        'profiles(first_name, last_name, phone), order_items(id, food_name, quantity), ' +
        'payments(payment_method, payment_status), deliveries(rider_id, delivery_status)',
    )
    .order('created_at', { ascending: false })
    .limit(100);
  if (statuses) q = q.in('order_status', statuses);
  const { data, error } = await q;
  if (error) throw error;
  return data;
}

export async function listRiders() {
  const { data, error } = await supabase
    .from('profiles')
    .select('id, first_name, last_name')
    .eq('role', 'rider')
    .eq('is_active', true)
    .order('first_name');
  if (error) throw error;
  return data;
}

export async function setOrderStatus(orderId, status, reason = null) {
  const { error } = await supabase.rpc('change_order_status', { p_order_id: orderId, p_status: status, p_reason: reason });
  if (error) throw error;
}

export async function assignRider(orderId, riderId) {
  const { error } = await supabase.rpc('assign_rider', { p_order_id: orderId, p_rider_id: riderId });
  if (error) throw error;
}
