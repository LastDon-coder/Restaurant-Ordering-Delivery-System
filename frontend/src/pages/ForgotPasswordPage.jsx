import { useState } from 'react';
import { Link } from 'react-router-dom';
import { supabase } from '../services/supabase';
import { friendlyAuthError } from '../utils/errors';

// Step 1 of a password reset: ask for the email and have Supabase send a reset link.
// The same message is shown whether or not the email has an account, so this page can't be used to find out
// who is registered.
export default function ForgotPasswordPage() {
  const [email, setEmail] = useState('');
  const [error, setError] = useState('');
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);

  async function onSubmit(e) {
    e.preventDefault();
    setError('');
    const clean = email.trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(clean)) return setError('Enter a valid email address.');
    setBusy(true);
    const { error: err } = await supabase.auth.resetPasswordForEmail(clean, {
      redirectTo: `${window.location.origin}/reset-password`,
    });
    setBusy(false);
    // Only report problems that say nothing about the account (rate limit, network). Anything else looks like success.
    const msg = (err?.message || '').toLowerCase();
    if (err && (msg.includes('rate limit') || msg.includes('too many') || msg.includes('fetch') || msg.includes('network'))) {
      return setError(friendlyAuthError(err));
    }
    if (err) console.error(err);
    setSent(true);
  }

  if (sent) {
    return (
      <section className="form-page">
        <h1>Check your email</h1>
        <p>
          If an account exists for <strong>{email.trim()}</strong>, we have sent a link to reset your password. The link expires after a
          short time, so use it soon.
        </p>
        <p className="muted">
          Nothing arrived? Check your spam folder, wait a minute, then <button type="button" className="text-link" onClick={() => setSent(false)}>try again</button>.
        </p>
        <p className="muted"><Link to="/login">Back to log in</Link></p>
      </section>
    );
  }

  return (
    <section className="form-page">
      <h1>Reset your password</h1>
      <p className="muted">Enter the email you signed up with and we will send you a reset link.</p>
      <form onSubmit={onSubmit} className="form" noValidate>
        {error && <p className="form-error" role="alert">{error}</p>}
        <label>
          Email
          <input type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </label>
        <button className="btn" type="submit" disabled={busy || !email}>{busy ? 'Sending…' : 'Send reset link'}</button>
      </form>
      <p className="muted"><Link to="/login">Back to log in</Link></p>
    </section>
  );
}
