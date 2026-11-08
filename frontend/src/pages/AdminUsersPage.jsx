import { useCallback, useEffect, useState } from 'react';
import AdminNav from '../components/AdminNav';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { useAuth } from '../context/AuthContext';
import { listUsers, setActive, setRole } from '../services/adminService';
import { friendlyDbError } from '../utils/errors';
import { statusLabel } from '../utils/orders';

const ROLES = ['customer', 'staff', 'rider', 'admin'];

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
      <p className="muted small">New staff and riders first create an account with Sign up (they start as customers). Find them here and change their role. Deactivated people are locked out immediately.</p>
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
