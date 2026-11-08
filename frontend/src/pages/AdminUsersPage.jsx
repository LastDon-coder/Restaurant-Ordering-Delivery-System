import { useCallback, useEffect, useState } from 'react';
import AdminNav from '../components/AdminNav';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { useAuth } from '../context/AuthContext';
import { inviteUser, listUsers, setActive, setRole } from '../services/adminService';
import { friendlyDbError } from '../utils/errors';
import { statusLabel } from '../utils/orders';

const ROLES = ['customer', 'staff', 'rider', 'admin'];
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

function InviteForm({ onInvited }) {
  const [open, setOpen] = useState(false);
  const [v, setV] = useState({ first_name: '', last_name: '', email: '', role: 'staff' });
  const [errors, setErrors] = useState({});
  const [busy, setBusy] = useState(false);
  const [formError, setFormError] = useState('');
  const [sent, setSent] = useState('');

  async function submit(e) {
    e.preventDefault();
    setFormError('');
    setSent('');
    const next = {};
    if (!v.first_name.trim()) next.first_name = 'Required';
    if (!v.last_name.trim()) next.last_name = 'Required';
    if (!EMAIL_RE.test(v.email.trim())) next.email = 'Enter a valid email';
    setErrors(next);
    if (Object.keys(next).length) return;
    setBusy(true);
    try {
      await inviteUser({ ...v, email: v.email.trim(), first_name: v.first_name.trim(), last_name: v.last_name.trim() });
      setSent(`Invitation sent to ${v.email.trim()}. They will get an email to set a password.`);
      setV({ first_name: '', last_name: '', email: '', role: 'staff' });
      setOpen(false);
      onInvited();
    } catch (err) {
      console.error(err);
      setFormError(err.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div>
      {sent && <p className="notice" role="status">{sent}</p>}
      {!open ? (
        <button type="button" className="btn btn-small" onClick={() => { setOpen(true); setSent(''); }}>+ Invite staff or rider</button>
      ) : (
        <form className="form order-card" onSubmit={submit} noValidate>
          <h3>Invite by email</h3>
          {formError && <p className="form-error" role="alert">{formError}</p>}
          <div className="row">
            <label>First name<input value={v.first_name} onChange={(e) => setV({ ...v, first_name: e.target.value })} maxLength={100} />{errors.first_name && <span className="field-error">{errors.first_name}</span>}</label>
            <label>Last name<input value={v.last_name} onChange={(e) => setV({ ...v, last_name: e.target.value })} maxLength={100} />{errors.last_name && <span className="field-error">{errors.last_name}</span>}</label>
          </div>
          <label>Email<input type="email" value={v.email} onChange={(e) => setV({ ...v, email: e.target.value })} />{errors.email && <span className="field-error">{errors.email}</span>}</label>
          <label>Role<select value={v.role} onChange={(e) => setV({ ...v, role: e.target.value })}><option value="staff">Staff (manages orders)</option><option value="rider">Rider (delivers orders)</option></select></label>
          <div className="inline-actions">
            <button className="btn btn-small" disabled={busy}>{busy ? 'Sending…' : 'Send invitation'}</button>
            <button type="button" className="btn btn-ghost btn-small" onClick={() => setOpen(false)} disabled={busy}>Cancel</button>
          </div>
        </form>
      )}
    </div>
  );
}

function UserRow({ u, isMe, onChanged }) {
  const [role, setRoleValue] = useState(u.role); const [busy, setBusy] = useState(false); const [error, setError] = useState('');
  const [confirm, setConfirm] = useState(null); // 'role' | 'active'
  async function run(fn) {
    setBusy(true); setError('');
    try { await fn(); setConfirm(null); await onChanged(); }
    catch (e) { console.error(e); setError(friendlyDbError(e)); setRoleValue(u.role); setConfirm(null); }
    finally { setBusy(false); }
  }
  return (
    <li className="order-card">
      <div className="order-head"><strong>{u.first_name} {u.last_name}{isMe && ' (you)'}</strong><span className={`pill ${u.is_active ? 'pill-ok' : 'pill-cancelled'}`}>{u.is_active ? 'Active' : 'Deactivated'}</span></div>
      <p className="small">{u.email}{u.phone ? ` · ${u.phone}` : ''}</p>
      {isMe ? <p className="muted small">Role: {statusLabel(u.role)} (you cannot change your own account)</p> : (
        <div className="inline-actions">
          <select value={role} onChange={(e) => setRoleValue(e.target.value)} aria-label={`Role for ${u.email}`} disabled={busy}>{ROLES.map((r) => <option key={r} value={r}>{statusLabel(r)}</option>)}</select>
          {role !== u.role && (confirm === 'role'
            ? <><span className="small">Make {statusLabel(role)}?</span><button type="button" className="btn btn-small" disabled={busy} onClick={() => run(() => setRole(u.id, role))}>Yes</button><button type="button" className="btn btn-ghost btn-small" onClick={() => { setConfirm(null); setRoleValue(u.role); }}>No</button></>
            : <button type="button" className="btn btn-small" onClick={() => setConfirm('role')}>Change role</button>)}
          {confirm === 'active'
            ? <><span className="small">{u.is_active ? 'Deactivate' : 'Reactivate'}?</span><button type="button" className="btn btn-small btn-danger" disabled={busy} onClick={() => run(() => setActive(u.id, !u.is_active))}>Yes</button><button type="button" className="btn btn-ghost btn-small" onClick={() => setConfirm(null)}>No</button></>
            : <button type="button" className="btn btn-ghost btn-small" onClick={() => setConfirm('active')}>{u.is_active ? 'Deactivate' : 'Reactivate'}</button>}
        </div>
      )}
      {error && <p className="field-error" role="alert">{error}</p>}
    </li>
  );
}

export default function AdminUsersPage() {
  const { user } = useAuth();
  const [search, setSearch] = useState(''); const [q, setQ] = useState('');
  const [users, setUsers] = useState([]); const [state, setState] = useState('loading'); const [error, setError] = useState('');
  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading');
    try { setUsers(await listUsers(q)); setState('ready'); }
    catch (e) { console.error(e); setError(friendlyDbError(e)); setState('error'); }
  }, [q]);
  useEffect(() => { load(); }, [load]);
  return (
    <section>
      <AdminNav />
      <h1>Users & roles</h1>
      <p className="muted small">Invite new staff or riders by email, or change the role of an existing account. Deactivated people are locked out immediately.</p>
      <InviteForm onInvited={() => load(true)} />
      <form className="inline-actions" onSubmit={(e) => { e.preventDefault(); setQ(search.trim()); }}>
        <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search by name or email" aria-label="Search users" />
        <button className="btn btn-small">Search</button>
        {q && <button type="button" className="btn btn-ghost btn-small" onClick={() => { setSearch(''); setQ(''); }}>Clear</button>}
      </form>
      {state === 'loading' && <Loading label="Loading users…" />}
      {state === 'error' && <ErrorMessage message={error} onRetry={load} />}
      {state === 'ready' && users.length === 0 && <EmptyState title="No users found" />}
      {state === 'ready' && users.length > 0 && <ul className="cart-list">{users.map((u) => <UserRow key={`${u.id}-${u.role}-${u.is_active}`} u={u} isMe={u.id === user?.id} onChanged={() => load(true)} />)}</ul>}
    </section>
  );
}
