// Loads .env once and exports validated settings.
// Failing here, at startup, is better than failing later in the middle of a request.
require('dotenv').config({ quiet: true });

const required = ['DB_HOST', 'DB_USER', 'DB_NAME'];
const missing = required.filter((name) => !process.env[name]);
if (missing.length > 0) {
  console.error(`Missing required environment variables: ${missing.join(', ')}`);
  console.error('Copy .env.example to .env and fill them in.');
  process.exit(1);
}

// The JWT secret signs every login token. If it is short or guessable, anyone can forge a token
// (including an admin one), so refuse to start without a long random value.
const jwtSecret = process.env.JWT_SECRET || '';
if (jwtSecret.length < 32) {
  console.error('JWT_SECRET is missing or shorter than 32 characters.');
  console.error('Generate one with: node -e "console.log(require(\'crypto\').randomBytes(48).toString(\'hex\'))"');
  process.exit(1);
}

// Flat delivery fee added to every order, e.g. 500 or 500.00. Defaults to free delivery.
const rawDeliveryFee = (process.env.DELIVERY_FEE || '0').trim();
if (!/^\d{1,6}(\.\d{1,2})?$/.test(rawDeliveryFee)) {
  console.error('DELIVERY_FEE must be an amount such as 500 or 500.00');
  process.exit(1);
}

const corsOrigin = process.env.CORS_ORIGIN || 'http://localhost:5173';
const nodeEnv = process.env.NODE_ENV || 'development';
const frontendUrl = process.env.FRONTEND_URL || corsOrigin;

// Paystack secret key (sk_test_... while testing, sk_live_... in production). It lives only here on the
// server: never in the frontend, never in git. Without it the app still runs, but online payments answer 503.
const paystackSecretKey = (process.env.PAYSTACK_SECRET_KEY || '').trim();
if (paystackSecretKey && !/^sk_(test|live)_\S+$/.test(paystackSecretKey)) {
  console.error('PAYSTACK_SECRET_KEY must be a Paystack SECRET key (starts with sk_test_ or sk_live_), not the public key.');
  process.exit(1);
}
if (nodeEnv === 'production') {
  if (!paystackSecretKey) {
    console.error('PAYSTACK_SECRET_KEY is required when NODE_ENV=production.');
    process.exit(1);
  }
  if (paystackSecretKey.startsWith('sk_test_')) {
    console.warn('WARNING: production is running with a Paystack TEST key. No real money will move.');
  }
} else if (paystackSecretKey.startsWith('sk_live_')) {
  console.warn('WARNING: a LIVE Paystack key is set outside production. Real cards will be charged.');
}

module.exports = {
  nodeEnv,
  port: Number(process.env.PORT) || 5000,
  corsOrigin,
  deliveryFee: Number(rawDeliveryFee).toFixed(2), // string with 2 decimals, e.g. "500.00"
  // Where the React app lives; used to build the password reset link.
  frontendUrl,
  paystack: {
    secretKey: paystackSecretKey,
    // Overridable so tests can point at a fake Paystack. Leave unset to use the real one.
    baseUrl: (process.env.PAYSTACK_BASE_URL || 'https://api.paystack.co').replace(/\/+$/, ''),
    // Where Paystack sends the customer's browser after paying (the React app adds ?reference=...).
    callbackUrl: process.env.PAYSTACK_CALLBACK_URL || `${frontendUrl}/payment/callback`,
  },
  jwt: {
    secret: jwtSecret,
    expiresIn: process.env.JWT_EXPIRES_IN || '1d',
  },
  db: {
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT) || 3306,
    user: process.env.DB_USER,
    // Empty is allowed: a local MySQL root user often has no password.
    password: process.env.DB_PASSWORD || '',
    database: process.env.DB_NAME,
  },
};
