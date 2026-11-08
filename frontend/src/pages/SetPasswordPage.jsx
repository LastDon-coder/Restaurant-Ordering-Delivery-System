import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Loading } from '../components/StateMessage';
import { useAuth } from '../context/AuthContext';
import { supabase } from '../services/supabase';

const HOME = { staff: '/staff/orders', admin: '/staff/orders', rider: '/rider' };

// Landing page for the emailed invite link. Supabase signs the person in from the link,
// then they choose their own password here.
export default function SetPasswordPage() {
  const { user, role, loading } = useAuth();
  const navigate = useNavigate();
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  if (loading) return <Loading label="Checking your invitation…" />;
  if (!user) {
    return (
      <section className="form-page">
        <h1>Invitation link expired</h1>
        <p className="muted">This link is invalid or has expired. Ask an admin to send a new invitation, or <Link to="/login">log in</Link> if you already set a password.</p>
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
      setError(err.message?.toLowerCase().includes('same') ? 'Choose a different password.' : 'Could not save your password. Please try again.');
      setBusy(false);
      return;
    }
    navigate(HOME[role] ?? '/', { replace: true });
  }

  return (
    <section className="form-page">
      <h1>Welcome! Set your password</h1>
      <form onSubmit={onSubmit} className="form" noValidate>
        {error && <p className="form-error" role="alert">{error}</p>}
        <label>New password<input type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} /></label>
        <label>Confirm password<input type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} /></label>
        <button className="btn" type="submit" disabled={busy || !password}>{busy ? 'Saving…' : 'Save password and continue'}</button>
      </form>
    </section>
  );
}
