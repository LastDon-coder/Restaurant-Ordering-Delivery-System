// One shared Supabase client for the whole app. Uses ONLY the publishable key:
// what a signed-in user can do is decided by Row Level Security and the SQL functions in the database.
import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

if (!url || !key) {
  throw new Error('Missing VITE_SUPABASE_URL or VITE_SUPABASE_PUBLISHABLE_KEY. Copy .env.example to .env.');
}

export const supabase = createClient(url, key);
