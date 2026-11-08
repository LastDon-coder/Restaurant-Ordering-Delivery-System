import { supabase } from './supabase';

// ---------- menu (admin only; Row Level Security enforces it, the UI just hides what you can't use) ----------
export async function adminCategories() {
  const { data, error } = await supabase.from('categories').select('id, category_name, description, image_url, status').order('id');
  if (error) throw error;
  return data;
}
export async function saveCategory(id, values) {
  const q = id ? supabase.from('categories').update(values).eq('id', id) : supabase.from('categories').insert(values);
  const { error } = await q;
  if (error) throw error;
}
export async function adminFoods() {
  const { data, error } = await supabase
    .from('food_items')
    .select('id, category_id, food_name, description, price, image_url, is_available')
    .order('id');
  if (error) throw error;
  return data;
}
export async function saveFood(id, values) {
  const q = id ? supabase.from('food_items').update(values).eq('id', id) : supabase.from('food_items').insert(values);
  const { error } = await q;
  if (error) throw error;
}
export async function deleteFood(id) {
  const { error } = await supabase.from('food_items').delete().eq('id', id);
  if (error) throw error;
}
export async function deleteCategory(id) {
  const { error } = await supabase.from('categories').delete().eq('id', id);
  if (error) throw error;
}

// ---------- refunds ----------
export async function listOnlinePayments() {
  const [pay, ref] = await Promise.all([
    supabase
      .from('payments')
      .select('id, order_id, amount, payment_status, paid_at, orders(order_status, profiles(first_name, last_name))')
      .eq('payment_method', 'online')
      .in('payment_status', ['paid', 'refunded'])
      .order('paid_at', { ascending: false })
      .limit(100),
    supabase.from('payment_refunds').select('payment_id, refund_status, reason, created_at').order('created_at', { ascending: false }),
  ]);
  if (pay.error) throw pay.error;
  if (ref.error) throw ref.error;
  const latest = new Map();
  for (const r of ref.data) if (!latest.has(r.payment_id)) latest.set(r.payment_id, r); // newest first
  return pay.data.map((p) => ({ ...p, refund: latest.get(p.payment_id ?? p.id) ?? latest.get(p.id) ?? null }));
}

// ---------- users & roles ----------
export async function listUsers(search) {
  const { data, error } = await supabase.rpc('admin_list_users', { p_search: search || null });
  if (error) throw error;
  return data;
}
export async function setRole(userId, role) {
  const { error } = await supabase.rpc('admin_set_role', { p_user: userId, p_role: role });
  if (error) throw error;
}
export async function setActive(userId, active) {
  const { error } = await supabase.rpc('admin_set_active', { p_user: userId, p_active: active });
  if (error) throw error;
}
