import { supabase } from './supabase';

export async function getMyDeliveries() {
  const { data, error } = await supabase.rpc('get_my_deliveries');
  if (error) throw error;
  return data; // active jobs only (assigned / picked_up)
}

// picked_up -> delivered | failed (failed needs a reason). The database checks it is MY delivery and the order is ready.
export async function updateDelivery(orderId, status, reason = null) {
  const { error } = await supabase.rpc('update_delivery_status', { p_order_id: orderId, p_status: status, p_reason: reason });
  if (error) throw error;
}
