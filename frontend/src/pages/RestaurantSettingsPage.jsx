import { useEffect, useState } from 'react';
import { Link, useOutletContext } from 'react-router-dom';
import { setDeliveryFee, setRestaurantOpen, updateRestaurantProfile } from '../services/restaurantTeamService';
import { friendlyDbError } from '../utils/errors';

export default function RestaurantSettingsPage() {
  const { restaurant: r, canManage, live, reload } = useOutletContext();
  const [open, setOpen] = useState(r.is_open);
  const [switchBusy, setSwitchBusy] = useState(false);
  const [switchError, setSwitchError] = useState('');

  const [form, setForm] = useState({});
  const [fee, setFee] = useState('');
  const [saved, setSaved] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  // Reset the forms whenever another restaurant is selected.
  useEffect(() => {
    setOpen(r.is_open);
    setForm({ name: r.name, description: r.description ?? '', phone: r.phone ?? '', address: r.address ?? '', logo_url: r.logo_url ?? '' });
    setFee(String(Number(r.base_delivery_fee)));
    setSaved(''); setError(''); setSwitchError('');
  }, [r]);

  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }));

  async function toggle() {
    setSwitchBusy(true); setSwitchError('');
    try { await setRestaurantOpen(r.id, !open); setOpen(!open); await reload(); }
    catch (e) { console.error(e); setSwitchError(friendlyDbError(e)); }
    finally { setSwitchBusy(false); }
  }

  async function save(action, message) {
    setBusy(true); setSaved(''); setError('');
    try { await action(); await reload(); setSaved(message); }
    catch (e) { console.error(e); setError(friendlyDbError(e)); }
    finally { setBusy(false); }
  }

  const feeNumber = Number(fee);
  const feeOk = fee.trim() !== '' && Number.isFinite(feeNumber) && feeNumber >= 0 && feeNumber <= 100000;

  return (
    <div>
      {live && (
        <div className="order-card">
          <div className="order-head">
            <strong>{open ? 'Open for orders' : 'Closed'}</strong>
            <button type="button" className={`btn btn-small ${open ? 'btn-ghost' : ''}`} onClick={toggle} disabled={switchBusy}>
              {switchBusy ? 'Saving…' : open ? 'Close the restaurant' : 'Open the restaurant'}
            </button>
          </div>
          <p className="muted small">Closed restaurants stay visible but customers cannot order. Anyone on your team can use this switch.</p>
          {switchError && <p className="field-error" role="alert">{switchError}</p>}
        </div>
      )}

      {live && <p className="small">Public page: <Link to={`/r/${r.slug}`}>/r/{r.slug}</Link></p>}

      {canManage ? (
        <>
          <form className="form" noValidate onSubmit={(e) => { e.preventDefault(); save(() => updateRestaurantProfile(r.id, form), 'Details saved.'); }}>
            <h2>Details</h2>
            <label>Name<input value={form.name ?? ''} onChange={set('name')} maxLength={100} /></label>
            <label>About<textarea rows={3} value={form.description ?? ''} onChange={set('description')} maxLength={1000} /></label>
            <label>Phone<input type="tel" value={form.phone ?? ''} onChange={set('phone')} maxLength={30} /></label>
            <label>Address<input value={form.address ?? ''} onChange={set('address')} maxLength={255} /></label>
            <label>Logo link (https://…, optional)<input value={form.logo_url ?? ''} onChange={set('logo_url')} maxLength={500} /></label>
            <button className="btn" type="submit" disabled={busy || !(form.name ?? '').trim()}>Save details</button>
          </form>

          {live && (
            <form className="form" noValidate onSubmit={(e) => { e.preventDefault(); if (feeOk) save(() => setDeliveryFee(r.id, feeNumber), 'Delivery fee saved.'); }}>
              <h2>Delivery fee</h2>
              <label>Standard fee (₦)<input type="number" inputMode="decimal" min="0" max="100000" step="0.01" value={fee} onChange={(e) => setFee(e.target.value)} aria-invalid={!feeOk} /></label>
              <p className="muted small">Areas that cost extra are set up on the Delivery page.</p>
              <button className="btn" type="submit" disabled={busy || !feeOk}>Save fee</button>
            </form>
          )}
          {saved && <p role="status" className="small">{saved}</p>}
          {error && <p className="form-error" role="alert">{error}</p>}
        </>
      ) : (
        <p className="muted">Only owners and managers can change restaurant details, the fee and the team.</p>
      )}
    </div>
  );
}
