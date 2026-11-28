import { supabase } from './supabase';
import { callFunction } from './edge';

// ---- reads (database functions; owners/managers can read their own restaurant's connection, never the account number) ----
export async function getSettlement(restaurantId) {
  const { data, error } = await supabase.rpc('get_settlement', { p_restaurant: restaurantId });
  if (error) throw error;
  return data; // null when no bank account is connected
}

export async function adminListSettlements() {
  const { data, error } = await supabase.rpc('admin_list_settlements');
  if (error) throw error;
  return data ?? [];
}

export async function setSplitActive(restaurantId, active) {
  const { error } = await supabase.rpc('admin_set_split_active', { p_restaurant: restaurantId, p_active: active });
  if (error) throw error;
}

// ---- admin only: the Edge Function talks to Paystack with the secret key. The account number goes there and is not kept. ----
export const listBanks = () => callFunction('restaurant-bank/banks', {}); // -> [{ name, code }]
export const resolveAccount = (bankCode, accountNumber) => callFunction('restaurant-bank/resolve', { bank_code: bankCode, account_number: accountNumber }); // -> { account_name }
export const connectBank = (restaurantId, bankCode, accountNumber) =>
  callFunction('restaurant-bank/connect', { restaurant_id: restaurantId, bank_code: bankCode, account_number: accountNumber });
