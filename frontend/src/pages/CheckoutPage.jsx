import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { EmptyState, ErrorMessage, Loading } from '../components/StateMessage';
import { useCart } from '../context/CartContext';
import { initializePayment } from '../services/paymentService';
import { getDeliveryQuote, listZones } from '../services/cartService';
import { placeOrder } from '../services/orderService';
import { friendlyDbError } from '../utils/errors';
import { formatMoney } from '../utils/format';

const LIMITS = { street_address: 255, city: 100, state: 100, landmark: 255 };

export default function CheckoutPage() {
  const { cart, loading, loadError, refresh } = useCart();
  const navigate = useNavigate();
  const [form, setForm] = useState({ street_address: '', city: '', state: '', landmark: '' });
  const [method, setMethod] = useState('online');
  const [errors, setErrors] = useState({});
  const [formError, setFormError] = useState('');
  const [busy, setBusy] = useState(false);
  const [zones, setZones] = useState([]);
  const [zonesState, setZonesState] = useState('loading'); // loading | ready | error
  const [zoneId, setZoneId] = useState('');                // '' = other area (standard fee)
  const [quote, setQuote] = useState(null);                // the server's price for the chosen area
  const [quoteError, setQuoteError] = useState('');

  useEffect(() => {
    let cancelled = false;
    listZones()
      .then((z) => { if (!cancelled) { setZones(z); setZonesState('ready'); } })
      .catch((e) => { console.error(e); if (!cancelled) setZonesState('error'); });
    return () => { cancelled = true; };
  }, []);

  // Ask the server what the delivery will cost for this area (also re-runs if the cart changes).
  const cartTotal = cart.summary.total;
  useEffect(() => {
    if (cart.items.length === 0) return undefined;
    let cancelled = false;
    setQuoteError('');
    getDeliveryQuote(zoneId ? Number(zoneId) : null)
      .then((q) => { if (!cancelled) setQuote(q); })
      .catch((e) => { console.error(e); if (!cancelled) { setQuote(null); setQuoteError(friendlyDbError(e)); } });
    return () => { cancelled = true; };
  }, [zoneId, cartTotal, cart.items.length]);

  if (loading && cart.items.length === 0) return <Loading label="Loading your cart…" />;
  if (loadError) return <ErrorMessage message={loadError} onRetry={refresh} />;
  if (cart.items.length === 0 && !busy) {
    return (
      <EmptyState title="Your cart is empty">
        <Link to="/">Browse the menu</Link>
      </EmptyState>
    );
  }

  const blocked = cart.items.some((i) => !i.is_available);
  const set = (key) => (e) => setForm((f) => ({ ...f, [key]: e.target.value }));

  function validate() {
    const next = {};
    for (const key of ['street_address', 'city', 'state']) if (!form[key].trim()) next[key] = 'Required';
    for (const [key, max] of Object.entries(LIMITS)) if (form[key].length > max) next[key] = `Max ${max} characters`;
    setErrors(next);
    return Object.keys(next).length === 0;
  }

  async function onSubmit(e) {
    e.preventDefault();
    setFormError('');
    if (busy || blocked || !validate()) return;
    setBusy(true);
    let orderId;
    try {
      orderId = await placeOrder(form, method, zoneId ? Number(zoneId) : null);
    } catch (err) {
      console.error(err);
      setFormError(friendlyDbError(err));
      setBusy(false);
      refresh();
      return;
    }
    // The order exists and the cart is empty now. For card payments, go on to Paystack.
    if (method === 'online') {
      try {
        const { authorization_url: url } = await initializePayment(orderId);
        window.location.assign(url);
        return; // leaving the page
      } catch (err) {
        console.error(err);
        // Not lost: the order page has a "Pay now" button.
        navigate(`/orders/${orderId}`, { replace: true, state: { payError: err.message } });
        return;
      }
    }
    navigate(`/orders/${orderId}`, { replace: true });
  }

  // Show the server's quote for the chosen area; until it arrives, fall back to the cart's standard-fee summary.
  const summary = quote?.delivery_fee != null ? { ...cart.summary, delivery_fee: quote.delivery_fee, total: quote.total } : cart.summary;
  return (
    <section>
      <h1>Checkout</h1>
      <form onSubmit={onSubmit} className="form" noValidate>
        {formError && <p className="form-error" role="alert">{formError}</p>}
        {blocked && <p className="form-error" role="alert">Some items are unavailable. <Link to="/cart">Fix your cart</Link></p>}

        <h2>Delivery address</h2>
        {[
          ['street_address', 'Street address', 'street-address'],
          ['city', 'City', 'address-level2'],
          ['state', 'State', 'address-level1'],
          ['landmark', 'Landmark (optional)', 'off'],
        ].map(([key, label, ac]) => (
          <label key={key}>
            {label}
            <input value={form[key]} onChange={set(key)} autoComplete={ac} maxLength={LIMITS[key] + 1} aria-invalid={!!errors[key]} />
            {errors[key] && <span className="field-error">{errors[key]}</span>}
          </label>
        ))}

        <h2>Delivery area</h2>
        {zonesState === 'error' && <p className="form-error" role="alert">Could not load delivery areas. You can still order and pay the standard delivery fee.</p>}
        <label>
          Area
          <select value={zoneId} onChange={(e) => setZoneId(e.target.value)} disabled={zonesState === 'loading'}>
            <option value="">{zonesState === 'loading' ? 'Loading areas…' : 'Other area (standard fee)'}</option>
            {zones.map((z) => (
              <option key={z.id} value={z.id}>{z.zone_name}{Number(z.extra_fee) > 0 ? ` (+${formatMoney(z.extra_fee)})` : ''}</option>
            ))}
          </select>
        </label>

        <h2>Payment</h2>
        <label className="radio"><input type="radio" name="method" checked={method === 'online'} onChange={() => setMethod('online')} /> Pay online (card, bank, USSD)</label>
        <label className="radio"><input type="radio" name="method" checked={method === 'cash_on_delivery'} onChange={() => setMethod('cash_on_delivery')} /> Cash on delivery</label>

        <dl className="summary">
          <div><dt>Subtotal</dt><dd>{formatMoney(summary.subtotal)}</dd></div>
          <div><dt>Delivery fee</dt><dd>{formatMoney(summary.delivery_fee)}</dd></div>
          <div className="summary-total"><dt>Total</dt><dd>{formatMoney(summary.total)}</dd></div>
        </dl>
        {quoteError && <p className="form-error" role="alert">{quoteError}</p>}
        <p className="muted small">The final amount is calculated again by the server when you place the order.</p>
        <button className="btn" type="submit" disabled={busy || blocked || !!quoteError}>
          {busy ? 'Placing order…' : method === 'online' ? 'Place order & pay' : 'Place order'}
        </button>
      </form>
    </section>
  );
}
