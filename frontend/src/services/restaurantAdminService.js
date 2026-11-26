import { supabase } from './supabase';

// ---- applicant (a signed-in customer) ----
export async function submitApplication({ name, description, phone, address }) {
  const { data, error } = await supabase.rpc('submit_restaurant_application', {
    p_name: name, p_description: description, p_phone: phone, p_address: address,
  });
  if (error) throw error;
  return data; // new restaurant id
}

// RLS lets a person read the restaurants they created (pending, rejected or live), nobody else's.
export async function listMyApplications() {
  const { data, error } = await supabase
    .from('restaurants')
    .select('id, name, slug, status, status_reason, created_at')
    .order('created_at', { ascending: false });
  if (error) throw error;
  return data;
}

// ---- platform admin ----
export async function adminListRestaurants(status = null) {
  const { data, error } = await supabase.rpc('admin_list_restaurants', { p_status: status });
  if (error) throw error;
  return data ?? [];
}

// decision: approve | reject | suspend | reinstate (reject and suspend need a reason)
export async function decideRestaurant(id, decision, reason = null) {
  const { error } = await supabase.rpc('admin_decide_restaurant', { p_restaurant: id, p_decision: decision, p_reason: reason });
  if (error) throw error;
}
