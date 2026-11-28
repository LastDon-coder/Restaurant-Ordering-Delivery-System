import { supabase } from './supabase';

// Owner/manager: ask the platform admin to refund a paid online order. Never moves money by itself.
export async function requestRefund(orderId, reason) {
  const { data, error } = await supabase.rpc('request_refund', { p_order: orderId, p_reason: reason });
  if (error) throw error;
  return data;
}
export async function listRefundRequests(restaurantId) {
  const { data, error } = await supabase.rpc('list_refund_requests', { p_restaurant: restaurantId });
  if (error) throw error;
  return data ?? [];
}
// Admin
export async function adminListRefundRequests(status = 'open') {
  const { data, error } = await supabase.rpc('admin_list_refund_requests', { p_status: status });
  if (error) throw error;
  return data ?? [];
}
export async function adminDismissRefundRequest(id, note) {
  const { error } = await supabase.rpc('admin_dismiss_refund_request', { p_id: id, p_note: note });
  if (error) throw error;
}
