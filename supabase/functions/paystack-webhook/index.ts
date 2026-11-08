// Paystack webhook. Public URL (verify_jwt = false) because Paystack has no Supabase JWT; instead we verify the
// HMAC-SHA512 signature (x-paystack-signature) computed over the RAW body with our secret key.
// Handles charge.success, refund.processed / refund.failed / refund.pending. Safe to receive repeatedly.
import { createClient } from 'npm:@supabase/supabase-js@2'

const REF_RE = /^ORD-\d{1,10}-[a-f0-9]{16}$/
const secretKeys = Deno.env.get('SUPABASE_SECRET_KEYS')
const serviceKey = secretKeys ? JSON.parse(secretKeys)['default'] : Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const admin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
})

const toHex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('')

async function sign(secret: string, body: Uint8Array) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-512' }, false, ['sign'])
  return toHex(await crypto.subtle.sign('HMAC', key, body))
}

// Constant-time comparison so response timing can't leak the signature.
function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method !== 'POST') return reply(405, { received: false })
  const secret = Deno.env.get('PAYSTACK_SECRET_KEY')
  if (!secret) return reply(503, { received: false })

  const raw = new Uint8Array(await req.arrayBuffer())
  const given = (req.headers.get('x-paystack-signature') ?? '').toLowerCase()
  if (!given || !safeEqual(given, await sign(secret, raw))) return reply(401, { received: false })

  let event: { event?: string; data?: Record<string, any> }
  try {
    event = JSON.parse(new TextDecoder().decode(raw))
  } catch {
    return reply(400, { received: false })
  }
  const data = event.data ?? {}

  try {
    if (event.event === 'charge.success') {
      const reference = String(data.reference ?? '')
      if (REF_RE.test(reference)) {
        const { data: out, error } = await admin.rpc('pay_apply_charge', {
          p_reference: reference,
          p_amount_kobo: Number(data.amount),
          p_currency: String(data.currency ?? ''),
          p_success: data.status === 'success',
        })
        if (error) throw error
        if (out?.result === 'amount_mismatch' || out?.result === 'duplicate_payment' || out?.result === 'paid_order_closed') {
          console.error('PAYMENT NEEDS ATTENTION', reference, JSON.stringify(out)) // admin should review / refund
        }
      }
    } else if (event.event === 'refund.processed' || event.event === 'refund.failed' || event.event === 'refund.pending') {
      // Paystack's docs show the original transaction's reference in two different places; accept both.
      const txRef = String(data.transaction_reference ?? data.transaction?.reference ?? '')
      if (REF_RE.test(txRef)) {
        const status = event.event === 'refund.processed' ? 'processed' : event.event === 'refund.failed' ? 'failed' : 'pending'
        const { error } = await admin.rpc('pay_apply_refund', {
          p_transaction_reference: txRef,
          p_status: status,
          p_paystack_refund_id: data.id != null ? String(data.id) : null,
        })
        if (error) throw error
      }
    }
  } catch (e) {
    console.error('webhook processing failed', e)
    return reply(500, { received: false }) // non-2xx makes Paystack retry later
  }
  return reply(200, { received: true })
})
