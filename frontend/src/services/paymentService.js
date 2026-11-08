import { supabase } from './supabase';

// Calls the `payments` Edge Function, which talks to Paystack with the secret key (never in the browser).
async function call(path, body) {
  const { data, error } = await supabase.functions.invoke(`payments/${path}`, { body });
  if (error) {
    let message = 'Payment service is unavailable. Please try again.';
    try {
      const parsed = await error.context.json();
      if (parsed?.message) message = parsed.message;
    } catch { /* keep the default */ }
    throw new Error(message);
  }
  return data?.data;
}

export const initializePayment = (orderId) => call('initialize', { order_id: orderId }); // -> { authorization_url, reference }
export const verifyPayment = (reference) => call('verify', { reference }); // -> { result, order_id }
