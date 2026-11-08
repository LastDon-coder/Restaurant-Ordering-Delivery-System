import { supabase } from './supabase';

// Calls an Edge Function; failures become Error(message) using the function's own {message} when it sent one.
export async function callFunction(name, body) {
  const { data, error } = await supabase.functions.invoke(name, { body });
  if (error) {
    let message = 'The service is unavailable. Please try again.';
    try {
      const parsed = await error.context.json();
      if (parsed?.message) message = parsed.message;
    } catch { /* keep the default */ }
    throw new Error(message);
  }
  return data?.data;
}
