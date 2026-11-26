import { supabase } from './supabase';

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data;
}

export const listMyRestaurants = async () => (await rpc('list_my_restaurants')) ?? [];
export const setRestaurantOpen = (id, open) => rpc('set_restaurant_open', { p_restaurant: id, p_open: open });
export const updateRestaurantProfile = (id, f) =>
  rpc('update_restaurant_profile', {
    p_restaurant: id, p_name: f.name, p_description: f.description, p_phone: f.phone, p_address: f.address, p_logo_url: f.logo_url,
  });
export const setDeliveryFee = (id, fee) => rpc('admin_set_delivery_fee', { p_restaurant: id, p_fee: fee });
export const listTeam = async (id) => (await rpc('list_restaurant_team', { p_restaurant: id })) ?? [];
export const addTeamMember = (id, email, role) => rpc('add_restaurant_member_by_email', { p_restaurant: id, p_email: email, p_role: role });
export const removeTeamMember = (id, userId) => rpc('remove_restaurant_member', { p_restaurant: id, p_user: userId });
