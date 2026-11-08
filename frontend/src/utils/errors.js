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
