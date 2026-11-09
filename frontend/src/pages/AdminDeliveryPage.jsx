import { useCallback, useEffect, useState } from 'react';
import AdminNav from '../components/AdminNav';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { adminZones, deleteZone, getBaseFee, saveZone, setBaseFee } from '../services/adminService';
import { friendlyDbError } from '../utils/errors';
import { formatMoney } from '../utils/format';

const MONEY_RE = /^\d{1,6}(\.\d{1,2})?$/;
const dbMessage = (e) => (e?.code === '23505' ? 'A zone with that name already exists.' : friendlyDbError(e));

function BaseFeeForm({ fee, onSaved }) {
  const [value, setValue] = useState(String(Number(fee)));
  const [error, setError] = useState('');
  const [ok, setOk] = useState(false);
  const [busy, setBusy] = useState(false);

  async function submit(e) {
    e.preventDefault();
    setError(''); setOk(false);
    if (!MONEY_RE.test(value.trim()) || Number(value) > 100000) return setError('Enter an amount like 2000 or 2000.50 (max 100000).');
    setBusy(true);
    try { await setBaseFee(Number(value)); setOk(true); await onSaved(); }
    catch (err) { console.error(err); setError(err?.code === '22023' ? err.message : friendlyDbError(err)); }
    finally { setBusy(false); }
  }

  return (
    <form className="form order-card" onSubmit={submit} noValidate>
      <h2>Standard delivery fee</h2>
      <p className="muted small">Every order pays this. A delivery area can add an extra charge on top.</p>
      {error && <p className="form-error" role="alert">{error}</p>}
      {ok && <p className="muted" role="status">Saved. New orders use {formatMoney(Number(value))}.</p>}
      <label>Standard fee (₦)<input inputMode="decimal" value={value} onChange={(e) => { setValue(e.target.value); setOk(false); }} /></label>
      <div className="inline-actions"><button className="btn btn-small" disabled={busy}>{busy ? 'Saving…' : 'Save fee'}</button></div>
    </form>
  );
}

function ZoneForm({ initial, onSaved, onCancel }) {
  const [v, setV] = useState({ zone_name: initial?.zone_name ?? '', extra_fee: initial ? String(Number(initial.extra_fee)) : '0', is_active: initial?.is_active ?? true });
  const [err, setErr] = useState({});
  const [formErr, setFormErr] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(e) {
    e.preventDefault(); setFormErr('');
    const next = {};
    if (!v.zone_name.trim() || v.zone_name.trim().length > 100) next.zone_name = '1–100 characters';
    if (!MONEY_RE.test(v.extra_fee.trim()) || Number(v.extra_fee) > 100000) next.extra_fee = 'A number like 0, 500 or 1500.50 (max 100000)';
    setErr(next); if (Object.keys(next).length) return;
    setBusy(true);
    try { await saveZone(initial?.id, { zone_name: v.zone_name.trim(), extra_fee: Number(v.extra_fee).toFixed(2), is_active: v.is_active }); await onSaved(); }
    catch (e2) { console.error(e2); setFormErr(dbMessage(e2)); setBusy(false); }
  }

  return (
    <form className="form order-card" onSubmit={submit} noValidate>
      <h3>{initial ? 'Edit area' : 'New delivery area'}</h3>
      {formErr && <p className="form-error" role="alert">{formErr}</p>}
      <label>Area name<input value={v.zone_name} onChange={(e) => setV({ ...v, zone_name: e.target.value })} placeholder="e.g. Rumuokoro" />{err.zone_name && <span className="field-error">{err.zone_name}</span>}</label>
      <label>Extra charge (₦)<input inputMode="decimal" value={v.extra_fee} onChange={(e) => setV({ ...v, extra_fee: e.target.value })} />{err.extra_fee && <span className="field-error">{err.extra_fee}</span>}</label>
      <label className="radio"><input type="checkbox" checked={v.is_active} onChange={(e) => setV({ ...v, is_active: e.target.checked })} /> Customers can choose this area</label>
      <div className="inline-actions"><button className="btn btn-small" disabled={busy}>{busy ? 'Saving…' : 'Save'}</button><button type="button" className="btn btn-ghost btn-small" onClick={onCancel} disabled={busy}>Cancel</button></div>
    </form>
  );
}

export default function AdminDeliveryPage() {
  const [base, setBase] = useState('0');
  const [zones, setZones] = useState([]);
  const [state, setState] = useState('loading');
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [editing, setEditing] = useState(null); // null | { item: zone | null }
  const [confirmDel, setConfirmDel] = useState(null);

  const load = useCallback(async () => {
    try {
      const [b, z] = await Promise.all([getBaseFee(), adminZones()]);
      setBase(b); setZones(z); setState('ready');
    } catch (e) { console.error(e); setError(friendlyDbError(e)); setState('error'); }
  }, []);
  useEffect(() => { load(); }, [load]);

  async function run(fn) { setNotice(''); try { await fn(); await load(); } catch (e) { console.error(e); setNotice(dbMessage(e)); } }
  const afterSave = async () => { setEditing(null); await load(); };

  if (state === 'loading') return <Loading label="Loading delivery settings…" />;
  if (state === 'error') return <ErrorMessage message={error} onRetry={load} />;

  return (
    <section>
      <AdminNav />
      <h1>Delivery</h1>
      {notice && <p className="form-error" role="alert">{notice}</p>}

      <BaseFeeForm fee={base} onSaved={load} />

      <div className="order-head">
        <h2>Delivery areas</h2>
        {!editing && <button type="button" className="btn btn-small" onClick={() => setEditing({ item: null })}>+ Add area</button>}
      </div>
      <p className="muted small">Customers pick their area at checkout. Anyone who picks "Other area" pays the standard fee only.</p>
      {editing && <ZoneForm key={editing.item?.id ?? 'new'} initial={editing.item} onSaved={afterSave} onCancel={() => setEditing(null)} />}

      {zones.length === 0 ? (
        <EmptyState title="No delivery areas yet">Every order pays the standard fee until you add areas.</EmptyState>
      ) : (
        <ul className="cart-list">
          {zones.map((z) => (
            <li key={z.id} className="order-card">
              <div className="order-head">
                <strong>{z.zone_name}</strong>
                <span className={`pill ${z.is_active ? 'pill-ok' : 'pill-wait'}`}>{z.is_active ? 'Active' : 'Hidden'}</span>
              </div>
              <p className="muted small">Extra {formatMoney(z.extra_fee)} · Customer pays {formatMoney(Number(base) + Number(z.extra_fee))} delivery</p>
              <div className="inline-actions">
                <button type="button" className="btn btn-ghost btn-small" onClick={() => setEditing({ item: z })}>Edit</button>
                <button type="button" className="btn btn-ghost btn-small" onClick={() => run(() => saveZone(z.id, { is_active: !z.is_active }))}>{z.is_active ? 'Hide' : 'Show'}</button>
                {confirmDel === z.id
                  ? <><span className="small">Delete?</span><button type="button" className="btn btn-small btn-danger" onClick={() => { setConfirmDel(null); run(() => deleteZone(z.id)); }}>Yes, delete</button><button type="button" className="btn btn-ghost btn-small" onClick={() => setConfirmDel(null)}>No</button></>
                  : <button type="button" className="btn btn-ghost btn-small" onClick={() => setConfirmDel(z.id)}>Delete</button>}
              </div>
            </li>
          ))}
        </ul>
      )}
      <p className="muted small">Deleting an area never changes past orders; they keep the area name and fee they were charged.</p>
    </section>
  );
}
