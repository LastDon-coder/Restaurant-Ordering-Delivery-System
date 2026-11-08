// Turn Supabase / Postgres errors into short messages a customer can act on.
export function friendlyAuthError(error) {
  const msg = (error?.message || '').toLowerCase();
  if (msg.includes('invalid login credentials')) return 'Incorrect email or password.';
  if (msg.includes('email not confirmed')) return 'Please confirm your email first. Check your inbox.';
  if (msg.includes('already registered') || msg.includes('already been registered')) return 'An account with this email already exists.';
  if (msg.includes('phone') && msg.includes('unique')) return 'That phone number is already in use.';
  if (msg.includes('database error saving new user')) return 'Could not create the account. The phone number may already be in use.';
  if (msg.includes('rate limit') || msg.includes('too many')) return 'Too many attempts. Please wait a minute and try again.';
  if (msg.includes('password')) return error.message;
  if (msg.includes('failed to fetch') || msg.includes('network')) return 'Cannot reach the server. Check your connection.';
  return 'Something went wrong. Please try again.';
}

// Errors from our SQL functions (add_to_cart, place_order, ...). Their messages are written for customers.
export function friendlyDbError(error) {
  const code = error?.code;
  if (code === '22023' || code === '55000') return error.message;
  if (code === '23514') return 'You can order at most 50 of one item.';
  if (code === 'P0002') return 'That item is no longer available.';
  if (code === '28000' || code === 'PGRST301' || (error?.message || '').toLowerCase().includes('jwt')) return 'Please log in again.';
  if (code === '42501') return 'Your account cannot do that.';
  if ((error?.message || '').toLowerCase().includes('fetch')) return 'Cannot reach the server. Check your connection.';
  return 'Something went wrong. Please try again.';
}
