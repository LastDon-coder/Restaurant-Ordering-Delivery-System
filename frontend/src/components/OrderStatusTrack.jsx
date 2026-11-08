import { CLOSED, STEPS, statusLabel } from '../utils/orders';

// Progress bar for the happy path, or a single badge for cancelled / rejected / failed.
export default function OrderStatusTrack({ status }) {
  if (CLOSED.includes(status)) return <span className={`pill pill-${status}`}>{statusLabel(status)}</span>;
  const current = STEPS.indexOf(status);
  return (
    <ol className="track" aria-label={`Order status: ${statusLabel(status)}`}>
      {STEPS.map((s, i) => (
        <li key={s} className={i < current ? 'done' : i === current ? 'current' : ''} aria-current={i === current ? 'step' : undefined}>
          <span className="dot" aria-hidden="true" />
          <span className="step-name">{statusLabel(s)}</span>
        </li>
      ))}
    </ol>
  );
}
