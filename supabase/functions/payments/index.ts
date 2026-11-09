// Paystack payments for signed-in users: POST /payments/initialize, /payments/verify, /payments/refund (admin).
// WHY an Edge Function: the Paystack SECRET key must never reach a browser, and only the server may decide an
// order is paid. All state changes go through service-role-only SQL functions (migration 007), which re-check
// ownership, amount and currency. Prices are never read from the request.
import { createClient } from 'npm:@supabase/supabase-js@2'

const PAYSTACK = 'https://api.paystack.co'
// ALLOWED_ORIGIN may list several site addresses, comma-separated (e.g. the live site and http://localhost:5173).
// The first one is the default. Links we create (payment return page, invite page) point back to the site that
// made the request, but only if it is in the list. CORS itself is not the security boundary here: every call
// needs a signed-in user's bearer token (no cookies are used), so any origin may read the response.
const ORIGINS = (Deno.env.get('ALLOWED_ORIGIN') ?? 'http://localhost:5173').split(',').map((s) => s.trim().replace(/\/+$/, '')).filter(Boolean)
const ORIGIN = ORIGINS[0]
const pickOrigin = (req: Request) => {
  const o = req.headers.get('Origin')
  return o && ORIGINS.includes(o) ? o : ORIGIN
}
const REF_RE = /^ORD-\d{1,10}-[a-f0-9]{16}$/
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const secretKeys = Deno.env.get('SUPABASE_SECRET_KEYS')
const serviceKey = secretKeys ? JSON.parse(secretKeys)['default'] : Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const admin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
})

function respond(status: number, message: string, data: unknown = null) {
  return new Response(JSON.stringify({ success: status < 400, message, data }), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  })
}

// Postgres error codes raised by our SQL functions -> HTTP status.
const PG_STATUS: Record<string, number> = { '28000': 401, '42501': 403, P0002: 404, '22023': 400, '55000': 409 }
function dbError(e: { code?: string; message?: string }) {
  const status = PG_STATUS[e.code ?? '']
  if (status) return respond(status, e.message ?? 'Request failed')
  console.error('database error', e.code, e.message)
  return respond(500, 'Something went wrong. Please try again.')
}

async function paystack(path: string, init: RequestInit = {}) {
  const key = Deno.env.get('PAYSTACK_SECRET_KEY')
  if (!key) throw new Error('PAYSTACK_SECRET_KEY is not set')
  return await fetch(PAYSTACK + path, {
    ...init,
    signal: AbortSignal.timeout(15000),
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
  })
}

async function currentUser(req: Request) {
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return null
  const { data, error } = await admin.auth.getUser(token)
  return error ? null : data.user
}

async function readJson(req: Request) {
  try {
    const body = await req.json()
    return body && typeof body === 'object' ? (body as Record<string, unknown>) : null
  } catch {
    return null
  }
}

async function initialize(userId: string, body: Record<string, unknown>, frontend: string) {
  const orderId = Number(body.order_id)
  if (!Number.isInteger(orderId) || orderId < 1) return respond(400, 'order_id must be a positive integer')

  // The amount, email and reference come from OUR database, not from the client.
  const { data: start, error } = await admin.rpc('pay_start', { p_user: userId, p_order_id: orderId })
  if (error) return dbError(error)

  let res: Response
  try {
    res = await paystack('/transaction/initialize', {
      method: 'POST',
      body: JSON.stringify({
        email: start.email,
        amount: start.amount_kobo,
        currency: 'NGN',
        reference: start.reference,
        callback_url: Deno.env.get('PAYSTACK_CALLBACK_URL') ?? `${frontend}/payment/callback`,
        metadata: { order_id: start.order_id },
      }),
    })
  } catch (e) {
    console.error('paystack initialize failed', e)
    return respond(502, 'Could not reach the payment provider. Please try again.')
  }
  const json = await res.json().catch(() => null)
  if (!res.ok || !json?.status) {
    console.error('paystack initialize rejected', res.status, json?.message)
    return respond(502, 'The payment provider rejected the request.')
  }
  return respond(200, 'Payment started', {
    authorization_url: json.data.authorization_url,
    reference: start.reference,
  })
}

async function verify(userId: string, body: Record<string, unknown>) {
  const reference = String(body.reference ?? '')
  if (!REF_RE.test(reference)) return respond(400, 'Invalid payment reference')

  // Only the owner of the order may verify its reference (others get a 404, so references can't be probed).
  const { data: info, error: lookupError } = await admin.rpc('pay_lookup', { p_reference: reference })
  if (lookupError) return dbError(lookupError)
  if (!info || info.user_id !== userId) return respond(404, 'Payment not found')

  let res: Response
  try {
    res = await paystack(`/transaction/verify/${encodeURIComponent(reference)}`)
  } catch (e) {
    console.error('paystack verify failed', e)
    return respond(502, 'Could not reach the payment provider. Please try again.')
  }
  const json = await res.json().catch(() => null)
  if (!res.ok || !json?.status || !json.data) {
    // Paystack answers 400 for a reference it has never seen (customer never reached the payment page).
    return respond(200, 'Payment not completed', { result: 'not_successful', order_id: info.order_id })
  }

  const { data, error } = await admin.rpc('pay_apply_charge', {
    p_reference: reference,
    p_amount_kobo: Number(json.data.amount),
    p_currency: String(json.data.currency ?? ''),
    p_success: json.data.status === 'success',
  })
  if (error) return dbError(error)
  if (data.result === 'amount_mismatch') {
    console.error('AMOUNT MISMATCH', reference, json.data.amount, json.data.currency)
    return respond(409, 'The amount paid does not match the order. Please contact the restaurant.', data)
  }
  return respond(200, 'Payment checked', data)
}

async function refund(userId: string, body: Record<string, unknown>) {
  const orderId = Number(body.order_id)
  const reason = String(body.reason ?? '')
  if (!Number.isInteger(orderId) || orderId < 1) return respond(400, 'order_id must be a positive integer')

  // Step 1: reserve the refund row (also checks the caller is an active admin and the payment is refundable).
  const { data: reserved, error } = await admin.rpc('pay_reserve_refund', {
    p_admin: userId, p_order_id: orderId, p_reason: reason,
  })
  if (error) return dbError(error)

  // Step 2: ask Paystack. A clear rejection frees the row for a retry; a network error leaves it pending
  // (the outcome is unknown, and the refund webhook will settle it).
  let res: Response
  try {
    res = await paystack('/refund', {
      method: 'POST',
      body: JSON.stringify({
        transaction: reserved.transaction_reference,
        amount: reserved.amount_kobo,
        currency: 'NGN',
        customer_note: reason.trim().slice(0, 255),
        merchant_note: reason.trim().slice(0, 255),
      }),
    })
  } catch (e) {
    console.error('paystack refund: unknown outcome', e)
    return respond(502, 'The refund was sent but the result is unknown. Check the Paystack dashboard; it will update automatically.')
  }
  const json = await res.json().catch(() => null)
  if (!res.ok || !json?.status) {
    console.error('paystack refund rejected', res.status, json?.message)
    await admin.rpc('pay_apply_refund', { p_transaction_reference: reserved.transaction_reference, p_status: 'failed' })
    return respond(502, `Paystack rejected the refund: ${json?.message ?? 'unknown error'}`)
  }
  const s = String(json.data?.status ?? 'pending')
  const status = s === 'processed' ? 'processed' : s === 'failed' ? 'failed' : 'pending'
  const { data, error: applyError } = await admin.rpc('pay_apply_refund', {
    p_transaction_reference: reserved.transaction_reference,
    p_status: status,
    p_paystack_refund_id: json.data?.id != null ? String(json.data.id) : null,
  })
  if (applyError) return dbError(applyError)
  return respond(200, status === 'processed' ? 'Refund processed' : 'Refund started', data)
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return respond(405, 'Method not allowed')

  const user = await currentUser(req)
  if (!user) return respond(401, 'Authentication required')
  const body = await readJson(req)
  if (!body) return respond(400, 'Send a JSON body')

  try {
    const path = new URL(req.url).pathname.replace(/\/+$/, '')
    if (path.endsWith('/initialize')) return await initialize(user.id, body, pickOrigin(req))
    if (path.endsWith('/verify')) return await verify(user.id, body)
    if (path.endsWith('/refund')) return await refund(user.id, body)
    return respond(404, 'Not found')
  } catch (e) {
    console.error('unhandled', e)
    return respond(500, 'Something went wrong. Please try again.')
  }
})
