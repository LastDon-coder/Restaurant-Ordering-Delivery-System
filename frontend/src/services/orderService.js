import { supabase } from './supabase';

// The address is sent with the order; place_order validates it and re-prices the cart on the server.
export async function placeOrder(address, paymentMethod) {
  const { data, error } = await supabase.rpc('place_order', { p_address: address, p_payment_method: paymentMethod });
  if (error) throw error;
  return data; // new order id
}

// RLS limits this to the customer's own orders (staff/admin see all).
export async function getOrder(orderId) {
  const { data, error } = await supabase
    .from('orders')
    .select(
      'id, order_status, subtotal, delivery_fee, discount, total_amount, created_at, delivery_street_address, delivery_city, delivery_state, delivery_landmark, ' +
        'order_items(id, food_name, quantity, price, subtotal), payments(payment_method, payment_status)',
    )
    .eq('id', orderId)
    .maybeSingle();
  if (error) throw error;
  return data;
}
