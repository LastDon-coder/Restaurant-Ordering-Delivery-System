// Admin-only: connect a restaurant's bank account to Paystack so online orders can be split.
//   POST /restaurant-bank/banks    {}                                   -> list of Nigerian banks [{name, code}]
//   POST /restaurant-bank/resolve  { bank_code, account_number }        -> { account_name }   (lets the admin check the name first)
//   POST /restaurant-bank/connect  { restaurant_id, bank_code, account_number } -> creates (or updates) the Paystack subaccount
// WHY an Edge Function: the Paystack SECRET key must never reach a browser. The full account number is sent to Paystack and
// then forgotten: we store only the subaccount code, the bank name, the account NAME and the last 4 digits, and we never log it.
import { createClient } from 'npm:@supabase/supabase-js@2'

const PAYSTACK = 'https://api.paystack.co'
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const secretKeys = Deno.env.get('SUPABASE_SECRET_KEYS')
const serviceKey = secretKeys ? JSON.parse(secretKeys)['default'] : Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const admin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })

function respond(status: number, message: string, data: unknown = null) {
  return new Response(JSON.stringify({ success: status < 400, message, data }), {
    status, headers: { ...cors, 'Content-Type': 'application/json' },
  })
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

const BANK_CODE_RE = /^[0-9]{2,6}$/
const ACCOUNT_RE = /^[0-9]{10}$/ // Nigerian NUBAN account numbers

async function resolveAccount(bankCode: string, accountNumber: string) {
  const res = await paystack(`/bank/resolve?account_number=${accountNumber}&bank_code=${bankCode}`)
  const json = await res.json().catch(() => null)
  if (!res.ok || !json?.status || !json.data?.account_name) return null
  return String(json.data.account_name)
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return respond(405, 'Method not allowed')
  try {
    // Only a signed-in, ACTIVE admin (checked in the database, not from the token).
    const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
    if (!token) return respond(401, 'Authentication required')
    const { data: caller, error: callerError } = await admin.auth.getUser(token)
    if (callerError || !caller.user) return respond(401, 'Authentication required')
    const { data: profile } = await admin.from('profiles').select('role, is_active').eq('id', caller.user.id).maybeSingle()
    if (!profile || profile.role !== 'admin' || !profile.is_active) return respond(403, 'Only an admin can manage bank accounts')

    const body = (await req.json().catch(() => null)) as Record<string, unknown> | null
    if (!body || typeof body !== 'object') return respond(400, 'Send a JSON body')
    const path = new URL(req.url).pathname.replace(/\/+$/, '')

    if (path.endsWith('/banks')) {
      const res = await paystack('/bank?country=nigeria&perPage=200&use_cursor=false')
      const json = await res.json().catch(() => null)
      if (!res.ok || !json?.status || !Array.isArray(json.data)) return respond(502, 'Could not load the bank list. Please try again.')
      const banks = json.data.filter((b: any) => b?.active !== false && b?.code && b?.name)
        .map((b: any) => ({ name: String(b.name), code: String(b.code) }))
        .sort((a: any, b: any) => a.name.localeCompare(b.name))
      return respond(200, 'Banks', banks)
    }

    const bankCode = String(body.bank_code ?? '')
    const accountNumber = String(body.account_number ?? '').replace(/\s+/g, '')
    if (!BANK_CODE_RE.test(bankCode)) return respond(400, 'Choose a bank')
    if (!ACCOUNT_RE.test(accountNumber)) return respond(400, 'The account number must be 10 digits')

    if (path.endsWith('/resolve')) {
      const name = await resolveAccount(bankCode, accountNumber)
      if (!name) return respond(422, 'Paystack could not verify that account. Check the bank and number.')
      return respond(200, 'Account found', { account_name: name })
    }

    if (path.endsWith('/connect')) {
      const restaurantId = Number(body.restaurant_id)
      if (!Number.isInteger(restaurantId) || restaurantId < 1) return respond(400, 'restaurant_id must be a positive integer')
      const { data: rest } = await admin.from('restaurants').select('id, name, commission_percent').eq('id', restaurantId).maybeSingle()
      if (!rest) return respond(404, 'Restaurant not found')

      // Verify again on the server: never trust a name the browser says it saw.
      const accountName = await resolveAccount(bankCode, accountNumber)
      if (!accountName) return respond(422, 'Paystack could not verify that account. Check the bank and number.')

      // Bank name for display (from Paystack's own list, not from the request).
      const listRes = await paystack('/bank?country=nigeria&perPage=200&use_cursor=false')
      const list = await listRes.json().catch(() => null)
      const bankName = Array.isArray(list?.data) ? String(list.data.find((b: any) => String(b.code) === bankCode)?.name ?? '') : ''
      if (!bankName) return respond(422, 'That bank is not in Paystack\'s list')

      const { data: existing } = await admin.from('restaurant_settlement').select('subaccount_code').eq('restaurant_id', restaurantId).maybeSingle()
      // percentage_charge is required by Paystack but is only the DEFAULT; every payment sends its own flat transaction_charge.
      const payload = {
        business_name: String(rest.name).slice(0, 100), settlement_bank: bankCode, account_number: accountNumber,
        percentage_charge: Number(rest.commission_percent),
      }
      const res = existing
        ? await paystack(`/subaccount/${encodeURIComponent(existing.subaccount_code)}`, { method: 'PUT', body: JSON.stringify(payload) })
        : await paystack('/subaccount', { method: 'POST', body: JSON.stringify(payload) })
      const json = await res.json().catch(() => null)
      const code = existing ? existing.subaccount_code : json?.data?.subaccount_code
      if (!res.ok || !json?.status || !code) {
        console.error('paystack subaccount rejected', res.status, json?.message) // never log the account number
        return respond(502, `Paystack rejected the bank account: ${json?.message ?? 'unknown error'}`)
      }

      const { error } = await admin.rpc('pay_save_settlement', {
        p_admin: caller.user.id, p_restaurant: restaurantId, p_code: String(code),
        p_bank_name: bankName, p_account_name: accountName, p_last4: accountNumber.slice(-4),
      })
      if (error) {
        console.error('save settlement failed', error.code, error.message)
        return respond(500, 'The bank account was created at Paystack but could not be saved. Try again.')
      }
      return respond(200, 'Bank account connected', { bank_name: bankName, account_name: accountName, account_last4: accountNumber.slice(-4) })
    }
    return respond(404, 'Not found')
  } catch (e) {
    console.error('unhandled', (e as Error).message)
    return respond(500, 'Something went wrong. Please try again.')
  }
})
