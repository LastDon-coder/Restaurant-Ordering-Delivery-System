import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Loading } from '../components/StateMessage';
import { useAuth } from '../context/AuthContext';
import { supabase } from '../services/supabase';

// Step 2 of a password reset: the emailed link signs the person in (Supabase "recovery" session),
// and they choose a new password here.
export default function ResetPasswordPage() {
  const { user, loading } = useAuth();
  const navigate = useNavigate();
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  if (loading) return <Loading label="Checking your reset link…" />;
  if (!user) {
    return (
      <section className="form-page">
        <h1>Reset link expired</h1>
        <p className="muted">This link is invalid or has expired. <Link to="/forgot-password">Request a new reset link</Link>.</p>
      </section>
    );
  }

  async function onSubmit(e) {
    e.preventDefault();
    setError('');
    if (password.length < 8) return setError('Use at least 8 characters.');
    if (password !== confirm) return setError('Passwords do not match.');
    setBusy(true);
    const { error: err } = await supabase.auth.updateUser({ password });
    if (err) {
      console.error(err);
      setError(err.message?.toLowerCase().includes('same') ? 'Choose a different password from your old one.' : 'Could not save your password. Please try again.');
      setBusy(false);
      return;
    }
    // Sign out every other device that was logged in with the old password, then go to the home page.
    await supabase.auth.signOut({ scope: 'others' });
    navigate('/', { replace: true, state: { passwordChanged: true } });
  }

  return (
    <section className="form-page">
      <h1>Choose a new password</h1>
      <form onSubmit={onSubmit} className="form" noValidate>
        {error && <p className="form-error" role="alert">{error}</p>}
        <label>New password<input type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} /></label>
        <label>Confirm password<input type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} /></label>
        <button className="btn" type="submit" disabled={busy || !password}>{busy ? 'Saving…' : 'Save new password'}</button>
      </form>
    </section>
  );
}
