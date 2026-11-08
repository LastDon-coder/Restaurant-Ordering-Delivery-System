import { useCallback, useEffect, useState } from 'react';
import AdminNav from '../components/AdminNav';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { adminCategories, adminFoods, deleteCategory, deleteFood, saveCategory, saveFood } from '../services/adminService';
import { friendlyDbError } from '../utils/errors';
import { formatMoney } from '../utils/format';

const isUrl = (v) => { try { return ['http:', 'https:'].includes(new URL(v).protocol); } catch { return false; } };
const dbMessage = (e) => (e?.code === '23505' ? 'That name is already used.' : e?.code === '23503' ? 'It is used by existing orders or foods, so it cannot be deleted. Mark it unavailable / inactive instead.' : friendlyDbError(e));

function CategoryForm({ initial, onSaved, onCancel }) {
  const [v, setV] = useState({ category_name: initial?.category_name ?? '', description: initial?.description ?? '', image_url: initial?.image_url ?? '', status: initial?.status ?? 'active' });
  const [err, setErr] = useState({}); const [busy, setBusy] = useState(false); const [formErr, setFormErr] = useState('');
  async function submit(e) {
    e.preventDefault(); setFormErr('');
    const next = {};
    if (!v.category_name.trim() || v.category_name.length > 100) next.category_name = '1–100 characters';
    if (v.description.length > 255) next.description = 'Max 255 characters';
    if (v.image_url && (!isUrl(v.image_url) || v.image_url.length > 500)) next.image_url = 'Enter a full http(s) link (max 500)';
    setErr(next); if (Object.keys(next).length) return;
    setBusy(true);
    try { await saveCategory(initial?.id, { category_name: v.category_name.trim(), description: v.description.trim() || null, image_url: v.image_url.trim() || null, status: v.status }); await onSaved(); }
    catch (e2) { console.error(e2); setFormErr(dbMessage(e2)); setBusy(false); }
  }
  return (
    <form className="form order-card" onSubmit={submit} noValidate>
      <h3>{initial ? 'Edit category' : 'New category'}</h3>
      {formErr && <p className="form-error" role="alert">{formErr}</p>}
      <label>Name<input value={v.category_name} onChange={(e) => setV({ ...v, category_name: e.target.value })} />{err.category_name && <span className="field-error">{err.category_name}</span>}</label>
      <label>Description<input value={v.description} onChange={(e) => setV({ ...v, description: e.target.value })} />{err.description && <span className="field-error">{err.description}</span>}</label>
      <label>Image link (optional)<input value={v.image_url} onChange={(e) => setV({ ...v, image_url: e.target.value })} />{err.image_url && <span className="field-error">{err.image_url}</span>}</label>
      <label>Status<select value={v.status} onChange={(e) => setV({ ...v, status: e.target.value })}><option value="active">Active (visible)</option><option value="inactive">Inactive (hidden)</option></select></label>
      <div className="inline-actions"><button className="btn btn-small" disabled={busy}>{busy ? 'Saving…' : 'Save'}</button><button type="button" className="btn btn-ghost btn-small" onClick={onCancel} disabled={busy}>Cancel</button></div>
    </form>
  );
}

function FoodForm({ initial, categories, onSaved, onCancel }) {
  const [v, setV] = useState({ category_id: initial?.category_id ?? categories[0]?.id ?? '', food_name: initial?.food_name ?? '', description: initial?.description ?? '', price: initial?.price ?? '', image_url: initial?.image_url ?? '', is_available: initial?.is_available ?? true });
  const [err, setErr] = useState({}); const [busy, setBusy] = useState(false); const [formErr, setFormErr] = useState('');
  async function submit(e) {
    e.preventDefault(); setFormErr('');
    const next = {}; const price = Number(v.price);
    if (!v.category_id) next.category_id = 'Choose a category';
    if (!v.food_name.trim() || v.food_name.length > 150) next.food_name = '1–150 characters';
    if (v.price === '' || !Number.isFinite(price) || price < 0 || price > 99999999 || !/^\d+(\.\d{1,2})?$/.test(String(v.price))) next.price = 'A number like 2500 or 2500.50';
    if (v.image_url && (!isUrl(v.image_url) || v.image_url.length > 500)) next.image_url = 'Enter a full http(s) link (max 500)';
    setErr(next); if (Object.keys(next).length) return;
    setBusy(true);
    try { await saveFood(initial?.id, { category_id: Number(v.category_id), food_name: v.food_name.trim(), description: v.description.trim() || null, price: price.toFixed(2), image_url: v.image_url.trim() || null, is_available: v.is_available }); await onSaved(); }
    catch (e2) { console.error(e2); setFormErr(dbMessage(e2)); setBusy(false); }
  }
  return (
    <form className="form order-card" onSubmit={submit} noValidate>
      <h3>{initial ? 'Edit food' : 'New food'}</h3>
      {formErr && <p className="form-error" role="alert">{formErr}</p>}
      <label>Category<select value={v.category_id} onChange={(e) => setV({ ...v, category_id: e.target.value })}>{categories.map((c) => <option key={c.id} value={c.id}>{c.category_name}</option>)}</select>{err.category_id && <span className="field-error">{err.category_id}</span>}</label>
      <label>Name<input value={v.food_name} onChange={(e) => setV({ ...v, food_name: e.target.value })} />{err.food_name && <span className="field-error">{err.food_name}</span>}</label>
      <label>Description<textarea rows={2} value={v.description} onChange={(e) => setV({ ...v, description: e.target.value })} /></label>
      <label>Price (₦)<input inputMode="decimal" value={v.price} onChange={(e) => setV({ ...v, price: e.target.value })} />{err.price && <span className="field-error">{err.price}</span>}</label>
      <label>Image link (optional)<input value={v.image_url} onChange={(e) => setV({ ...v, image_url: e.target.value })} />{err.image_url && <span className="field-error">{err.image_url}</span>}</label>
      <label className="radio"><input type="checkbox" checked={v.is_available} onChange={(e) => setV({ ...v, is_available: e.target.checked })} /> Available to order</label>
      <div className="inline-actions"><button className="btn btn-small" disabled={busy}>{busy ? 'Saving…' : 'Save'}</button><button type="button" className="btn btn-ghost btn-small" onClick={onCancel} disabled={busy}>Cancel</button></div>
    </form>
  );
}

export default function AdminMenuPage() {
  const [cats, setCats] = useState([]); const [foods, setFoods] = useState([]);
  const [state, setState] = useState('loading'); const [error, setError] = useState('');
  const [editing, setEditing] = useState(null); // {type:'cat'|'food', item|null}
  const [notice, setNotice] = useState('');
  const [confirmDel, setConfirmDel] = useState(null); // {type, id}

  const load = useCallback(async () => {
    try { const [c, f] = await Promise.all([adminCategories(), adminFoods()]); setCats(c); setFoods(f); setState('ready'); }
    catch (e) { console.error(e); setError(friendlyDbError(e)); setState('error'); }
  }, []);
  useEffect(() => { load(); }, [load]);

  async function run(fn) { setNotice(''); try { await fn(); await load(); } catch (e) { console.error(e); setNotice(dbMessage(e)); } }
  const afterSave = async () => { setEditing(null); await load(); };
  const catName = (id) => cats.find((c) => c.id === id)?.category_name ?? '—';

  if (state === 'loading') return <Loading label="Loading menu…" />;
  if (state === 'error') return <ErrorMessage message={error} onRetry={load} />;

  return (
    <section>
      <AdminNav />
      <h1>Menu</h1>
      {notice && <p className="form-error" role="alert">{notice}</p>}

      <div className="order-head"><h2>Categories</h2>{!editing && <button type="button" className="btn btn-small" onClick={() => setEditing({ type: 'cat', item: null })}>+ Add category</button>}</div>
      {editing?.type === 'cat' && <CategoryForm initial={editing.item} onSaved={afterSave} onCancel={() => setEditing(null)} />}
      {cats.length === 0 ? <EmptyState title="No categories yet" /> : (
        <ul className="cart-list">
          {cats.map((c) => (
            <li key={c.id} className="order-card">
              <div className="order-head"><strong>{c.category_name}</strong><span className={`pill ${c.status === 'active' ? 'pill-ok' : 'pill-wait'}`}>{c.status}</span></div>
              {c.description && <p className="muted small">{c.description}</p>}
              <div className="inline-actions">
                <button type="button" className="btn btn-ghost btn-small" onClick={() => setEditing({ type: 'cat', item: c })}>Edit</button>
                <button type="button" className="btn btn-ghost btn-small" onClick={() => run(() => saveCategory(c.id, { status: c.status === 'active' ? 'inactive' : 'active' }))}>{c.status === 'active' ? 'Hide' : 'Show'}</button>
                {confirmDel?.type === 'cat' && confirmDel.id === c.id
                  ? <><span className="small">Delete?</span><button type="button" className="btn btn-small btn-danger" onClick={() => { setConfirmDel(null); run(() => deleteCategory(c.id)); }}>Yes, delete</button><button type="button" className="btn btn-ghost btn-small" onClick={() => setConfirmDel(null)}>No</button></>
                  : <button type="button" className="btn btn-ghost btn-small" onClick={() => setConfirmDel({ type: 'cat', id: c.id })}>Delete</button>}
              </div>
            </li>
          ))}
        </ul>
      )}

      <div className="order-head"><h2>Foods</h2>{!editing && cats.length > 0 && <button type="button" className="btn btn-small" onClick={() => setEditing({ type: 'food', item: null })}>+ Add food</button>}</div>
      {editing?.type === 'food' && <FoodForm initial={editing.item} categories={cats} onSaved={afterSave} onCancel={() => setEditing(null)} />}
      {foods.length === 0 ? <EmptyState title="No foods yet" /> : (
        <ul className="cart-list">
          {foods.map((f) => (
            <li key={f.id} className="order-card">
              <div className="order-head"><strong>{f.food_name}</strong><span>{formatMoney(f.price)}</span></div>
              <p className="muted small">{catName(f.category_id)} · <span className={`pill ${f.is_available ? 'pill-ok' : 'pill-wait'}`}>{f.is_available ? 'Available' : 'Sold out'}</span></p>
              <div className="inline-actions">
                <button type="button" className="btn btn-ghost btn-small" onClick={() => setEditing({ type: 'food', item: f })}>Edit</button>
                <button type="button" className="btn btn-ghost btn-small" onClick={() => run(() => saveFood(f.id, { is_available: !f.is_available }))}>{f.is_available ? 'Mark sold out' : 'Mark available'}</button>
                {confirmDel?.type === 'food' && confirmDel.id === f.id
                  ? <><span className="small">Delete?</span><button type="button" className="btn btn-small btn-danger" onClick={() => { setConfirmDel(null); run(() => deleteFood(f.id)); }}>Yes, delete</button><button type="button" className="btn btn-ghost btn-small" onClick={() => setConfirmDel(null)}>No</button></>
                  : <button type="button" className="btn btn-ghost btn-small" onClick={() => setConfirmDel({ type: 'food', id: f.id })}>Delete</button>}
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
