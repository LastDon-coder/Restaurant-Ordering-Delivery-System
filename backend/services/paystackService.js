const crypto = require('node:crypto');
const { paystack } = require('../config/env');
const AppError = require('../utils/AppError');

// The only file that talks to Paystack. Docs: https://paystack.com/docs/api/
// Amounts are in kobo (whole numbers): NGN 4000.00 is 400000.

function assertConfigured() {
  if (!paystack.secretKey) throw new AppError('Online payments are not configured on this server', 503);
}

async function request(method, path, body) {
  assertConfigured();
  try {
    const res = await fetch(`${paystack.baseUrl}${path}`, {
      method,
      headers: { Authorization: `Bearer ${paystack.secretKey}`, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(10000), // never hang a customer's request on Paystack
    });
    let json = null;
    try {
      json = await res.json();
    } catch {
      /* non-JSON answer: handled by the callers */
    }
    return { status: res.status, json };
  } catch (err) {
    console.error('Paystack request failed:', err.name, err.message); // never log the key or headers
    throw new AppError('The payment provider is unavailable. Please try again shortly.', 502);
  }
}

// Starts a payment. Returns { authorization_url, access_code, reference }: send the customer's browser to authorization_url.
async function initializeTransaction({ email, amountKobo, reference, callbackUrl, metadata }) {
  const { status, json } = await request('POST', '/transaction/initialize', {
    email,
    amount: amountKobo,
    currency: 'NGN',
    reference,
    callback_url: callbackUrl,
    metadata,
  });
  if (status !== 200 || !json || json.status !== true || !json.data || !json.data.authorization_url) {
    console.error('Paystack rejected initialize:', status, json && json.message);
    throw new AppError('Could not start the payment. Please try again shortly.', 502);
  }
  return json.data;
}

// Asks Paystack what really happened to a reference. Returns its data ({ status, amount, currency, reference, ... }),
// or null if Paystack has never heard of the reference (the customer never opened the payment page).
async function verifyTransaction(reference) {
  const { status, json } = await request('GET', `/transaction/verify/${encodeURIComponent(reference)}`);
  if (json && json.status === false && /not found/i.test(json.message || '') && (status === 404 || status === 400)) return null;
  if (status !== 200 || !json || json.status !== true || !json.data) {
    console.error('Paystack rejected verify:', status, json && json.message);
    throw new AppError('Could not check the payment. Please try again shortly.', 502);
  }
  return json.data;
}

// Webhook check: Paystack signs the RAW request body with HMAC-SHA512 using our secret key and sends it in
// the x-paystack-signature header. Anyone can POST to our URL, so without this, anyone could fake "paid".
function verifyWebhookSignature(rawBody, signature) {
  if (!paystack.secretKey || !Buffer.isBuffer(rawBody) || typeof signature !== 'string') return false;
  const expected = crypto.createHmac('sha512', paystack.secretKey).update(rawBody).digest();
  const given = Buffer.from(signature, 'hex');
  return given.length === expected.length && crypto.timingSafeEqual(given, expected); // constant-time compare
}

module.exports = { initializeTransaction, verifyTransaction, verifyWebhookSignature };
