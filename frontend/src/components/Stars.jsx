import { useState } from 'react';

// Read-only stars: <Stars value={4.5} /> shows ★★★★★ with the first 4.5 filled.
export function Stars({ value, label }) {
  const v = Math.max(0, Math.min(5, Number(value) || 0));
  return (
    <span className="stars" role="img" aria-label={label ?? `${v} out of 5 stars`}>
      <span className="stars-back" aria-hidden="true">★★★★★</span>
      <span className="stars-front" aria-hidden="true" style={{ width: `${(v / 5) * 100}%` }}>★★★★★</span>
    </span>
  );
}

// Pick 1-5 stars with buttons (works with touch and keyboard).
export function StarInput({ value, onChange, name }) {
  const [hover, setHover] = useState(0);
  const shown = hover || value;
  return (
    <span className="star-input" role="radiogroup" aria-label={name} onMouseLeave={() => setHover(0)}>
      {[1, 2, 3, 4, 5].map((n) => (
        <button
          key={n}
          type="button"
          role="radio"
          aria-checked={value === n}
          aria-label={`${n} star${n > 1 ? 's' : ''}`}
          className={`star-btn ${n <= shown ? 'star-on' : ''}`}
          onClick={() => onChange(n)}
          onMouseEnter={() => setHover(n)}
        >
          ★
        </button>
      ))}
    </span>
  );
}
