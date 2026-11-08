import { useState } from 'react';
import { Link, Navigate } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { friendlyAuthError } from '../utils/errors';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PHONE_RE = /^\+?[0-9]{7,15}$/;

// Client-side checks are only for quick feedback. The database enforces its own rules too.
function validate(f) {
  const errors = {};
  if (!f.firstName.trim()) errors.firstName = 'Enter your first name.';
  if (!f.lastName.trim()) errors.lastName = 'Enter your last name.';
  if (!EMAIL_RE.test(f.email.trim())) errors.email = 'Enter a valid email address.';
  if (f.phone.trim() && !PHONE_RE.test(f.phone.replace(/[\s-]/g, ''))) errors.phone = 'Enter a valid phone number, e.g. 08012345678.';
  if (f.password.length < 8) errors.password = 'Use at least 8 characters.';
  if (f.password !== f.confirm) errors.confirm = 'Passwords do not match.';
  return errors;
}

export default function RegisterPage() {
  const { user, signUp } = useAuth();
  const [form, setForm] = useState({ firstName: '', lastName: '', email: '', phone: '', password: '', confirm: '' });
  const [errors, setErrors] = useState({});
  const [formError, setFormError] = useState('');
  const [busy, setBusy] = useState(false);
  const [checkEmail, setCheckEmail] = useState(false);

  if (user) return <Navigate to="/" replace />;

  const set = (field) => (e) => setForm((f) => ({ ...f, [field]: e.target.value }));

  async function onSubmit(e) {
    e.preventDefault();
    setFormError('');
    const found = validate(form);
    setErrors(found);
    if (Object.keys(found).length > 0) return;

    setBusy(true);
    try {
      const { needsEmailConfirmation } = await signUp({
        email: form.email.trim(),
        password: form.password,
        firstName: form.firstName.trim(),
        lastName: form.lastName.trim(),
        phone: form.phone.replace(/[\s-]/g, ''),
      });
      if (needsEmailConfirmation) setCheckEmail(true); // otherwise onAuthStateChange signs them in
    } catch (err) {
      setFormError(friendlyAuthError(err));
    } finally {
      setBusy(false);
    }
  }

  if (checkEmail) {
    return (
      <section className="form-page">
        <h1>Check your email</h1>
        <p>
          We sent a confirmation link to <strong>{form.email}</strong>. Open it, then <Link to="/login">log in</Link>.
        </p>
      </section>
    );
  }

  const field = (name, label, props = {}) => (
    <label>
      {label}
      <input value={form[name]} onChange={set(name)} aria-invalid={Boolean(errors[name])} {...props} />
      {errors[name] && <span className="field-error">{errors[name]}</span>}
    </label>
  );

  return (
    <section className="form-page">
      <h1>Create an account</h1>
      <form onSubmit={onSubmit} className="form" noValidate>
        {formError && (
          <p className="form-error" role="alert">
            {formError}
          </p>
        )}
        <div className="row">
          {field('firstName', 'First name', { autoComplete: 'given-name' })}
          {field('lastName', 'Last name', { autoComplete: 'family-name' })}
        </div>
        {field('email', 'Email', { type: 'email', autoComplete: 'email' })}
        {field('phone', 'Phone (optional)', { type: 'tel', autoComplete: 'tel', placeholder: '08012345678' })}
        {field('password', 'Password', { type: 'password', autoComplete: 'new-password' })}
        {field('confirm', 'Confirm password', { type: 'password', autoComplete: 'new-password' })}
        <button className="btn" type="submit" disabled={busy}>
          {busy ? 'Creating account…' : 'Sign up'}
        </button>
      </form>
      <p className="muted">
        Already have an account? <Link to="/login">Log in</Link>
      </p>
    </section>
  );
}
