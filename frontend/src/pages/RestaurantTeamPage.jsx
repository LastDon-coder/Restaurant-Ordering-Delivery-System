import { useCallback, useEffect, useState } from 'react';
import { Navigate, useOutletContext } from 'react-router-dom';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { useAuth } from '../context/AuthContext';
import { addTeamMember, listTeam, removeTeamMember } from '../services/restaurantTeamService';
import { friendlyDbError } from '../utils/errors';

export default function RestaurantTeamPage() {
  const { restaurant: r, canManage } = useOutletContext();
  const { user } = useAuth();
  const [team, setTeam] = useState([]);
  const [state, setState] = useState('loading');
  const [email, setEmail] = useState('');
  const [role, setRole] = useState('staff');
  const [msg, setMsg] = useState({ type: '', text: '' });
  const [busy, setBusy] = useState(false);
  const [confirm, setConfirm] = useState(null); // user_id awaiting "Yes, remove"

  const isOwner = r.member_role === 'owner';
  const load = useCallback(async () => {
    setState('loading');
    try { setTeam(await listTeam(r.id)); setState('ready'); }
    catch (e) { console.error(e); setState('error'); }
  }, [r.id]);
  useEffect(() => { if (canManage) load(); }, [canManage, load]);
  useEffect(() => { setRole('staff'); setMsg({ type: '', text: '' }); setConfirm(null); }, [r.id]);

  if (!canManage) return <Navigate to="/restaurant" replace />;

  async function act(fn, ok) {
    setBusy(true); setMsg({ type: '', text: '' });
    try { await fn(); setMsg({ type: 'ok', text: ok }); await load(); }
    catch (e) { console.error(e); setMsg({ type: 'error', text: friendlyDbError(e) }); }
    finally { setBusy(false); setConfirm(null); }
  }

  const canRemove = (m) => m.user_id !== user?.id && (m.member_role === 'staff' || (m.member_role === 'manager' && isOwner));

  return (
    <div>
      <h2>Team</h2>
      {state === 'loading' && <Loading label="Loading the team…" />}
      {state === 'error' && <ErrorMessage message="Could not load the team." onRetry={load} />}
      {state === 'ready' && team.length === 0 && <EmptyState title="No team members yet" />}
      {state === 'ready' && team.length > 0 && (
        <ul className="cart-list">
          {team.map((m) => (
            <li key={m.user_id} className="order-card">
              <div className="order-head">
                <span><strong>{m.name || 'Unnamed'}</strong> <span className="pill pill-ok">{m.member_role}</span>{!m.is_active && <span className="pill pill-cancelled">deactivated</span>}</span>
                {canRemove(m) && confirm !== m.user_id && (
                  <button type="button" className="btn btn-small btn-ghost" disabled={busy} onClick={() => setConfirm(m.user_id)}>Remove</button>
                )}
              </div>
              <p className="muted small">{m.email}</p>
              {confirm === m.user_id && (
                <div className="inline-actions">
                  <span className="small">Remove {m.name || m.email} from the team?</span>
                  <button type="button" className="btn btn-small btn-danger" disabled={busy} onClick={() => act(() => removeTeamMember(r.id, m.user_id), 'Removed.')}>Yes, remove</button>
                  <button type="button" className="btn btn-small btn-ghost" disabled={busy} onClick={() => setConfirm(null)}>Back</button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}

      <form className="form" noValidate onSubmit={(e) => { e.preventDefault(); if (email.trim()) act(async () => { await addTeamMember(r.id, email.trim(), role); setEmail(''); }, 'Added.'); }}>
        <h2>Add someone</h2>
        <p className="muted small">They need an account already (a customer or staff account). Ask them to sign up first, then add their email here.</p>
        <label>Email<input type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="off" maxLength={254} /></label>
        <label>
          Role
          <select value={role} onChange={(e) => setRole(e.target.value)}>
            <option value="staff">Staff: handles orders</option>
            {isOwner && <option value="manager">Manager: also menu, fee, areas and team</option>}
          </select>
        </label>
        <button className="btn" type="submit" disabled={busy || !email.trim()}>{busy ? 'Saving…' : 'Add to team'}</button>
      </form>
      {msg.text && <p role={msg.type === 'error' ? 'alert' : 'status'} className={msg.type === 'error' ? 'form-error' : 'small'}>{msg.text}</p>}
    </div>
  );
}
