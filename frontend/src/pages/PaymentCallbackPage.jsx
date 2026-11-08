import { useEffect, useRef, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { ErrorMessage, Loading } from '../components/StateMessage';
import { verifyPayment } from '../services/paymentService';

// Paystack sends the customer back here with ?reference=... The browser's word is NOT trusted:
// we ask our server to verify the reference with Paystack, and only the server marks the order paid.
export default function PaymentCallbackPage() {
  const [params] = useSearchParams();
  const reference = params.get('reference') || params.get('trxref');
  const navigate = useNavigate();
  const [state, setState] = useState(reference ? 'checking' : 'missing');
  const [message, setMessage] = useState('');
  const [orderId, setOrderId] = useState(null);
  const started = useRef(false);

  async function check() {
    setState('checking');
    try {
      const data = await verifyPayment(reference);
      setOrderId(data.order_id);
      if (['paid', 'already_paid', 'paid_order_closed'].includes(data.result)) {
        navigate(`/orders/${data.order_id}`, { replace: true });
      } else {
        setState('failed');
      }
    } catch (e) {
      setMessage(e.message);
      setState('error');
    }
  }
  useEffect(() => {
    if (reference && !started.current) { started.current = true; check(); }
  }, [reference]); // eslint-disable-line react-hooks/exhaustive-deps

  if (state === 'missing') return <ErrorMessage message="No payment reference found." />;
  if (state === 'checking') return <Loading label="Confirming your payment…" />;
  if (state === 'error') return <ErrorMessage message={message} onRetry={check} />;
  return (
    <div className="state state-error" role="alert">
      <p>Your payment was not completed.</p>
      {orderId && <Link className="btn" to={`/orders/${orderId}`}>View order and try again</Link>}
    </div>
  );
}
