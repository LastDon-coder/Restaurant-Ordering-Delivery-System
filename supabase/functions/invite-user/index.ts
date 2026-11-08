// Admin-only: invite a new STAFF or RIDER by email. POST /invite-user { email, first_name, last_name, role }
// WHY an Edge Function: creating a login account needs the service key, which must never reach a browser.
// Flow: verify the caller is an active admin -> Supabase emails the invite link -> the sign-up trigger makes a
// customer profile -> we set the role -> the person opens the link and chooses their own password
// (the admin never sees or sets a password).
import { createClient } from 'npm:@supabase/supabase-js@2'

const ORIGIN = Deno.env.get('ALLOWED_ORIGIN') ?? 'http://localhost:5173'
const cors = {
  'Access-Control-Allow-Origin': ORIGIN,
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  Vary: 'Origin',
}
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@]{1,255}\.[^\s@]{2,}$/
const ROLES = ['staff', 'rider'] // admins are promoted deliberately from the Users tab, not by invite

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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return respond(405, 'Method not allowed')

  try {
    // 1. Who is calling? Must be a signed-in, ACTIVE admin (checked in the database, not from the token).
    const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
    if (!token) return respond(401, 'Authentication required')
    const { data: caller, error: callerError } = await admin.auth.getUser(token)
    if (callerError || !caller.user) return respond(401, 'Authentication required')
    const { data: profile } = await admin.from('profiles').select('role, is_active').eq('id', caller.user.id).maybeSingle()
    if (!profile || profile.role !== 'admin' || !profile.is_active) return respond(403, 'Only an admin can invite people')

    // 2. Validate input.
    const body = await req.json().catch(() => null)
    if (!body || typeof body !== 'object') return respond(400, 'Send a JSON body')
    const email = String(body.email ?? '').trim().toLowerCase()
    const first = String(body.first_name ?? '').trim()
    const last = String(body.last_name ?? '').trim()
    const role = String(body.role ?? '')
    if (!EMAIL_RE.test(email) || email.length > 254) return respond(400, 'Enter a valid email address')
    if (!first || first.length > 100 || !last || last.length > 100) return respond(400, 'First and last name are required (max 100 characters each)')
    if (!ROLES.includes(role)) return respond(400, 'Role must be staff or rider')

    // 3. Send the invite (Supabase emails the link; the new user is created unconfirmed).
    const { data: invited, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
      data: { first_name: first, last_name: last },
      redirectTo: `${ORIGIN}/set-password`,
    })
    if (inviteError || !invited?.user) {
      const msg = (inviteError?.message ?? '').toLowerCase()
      if (msg.includes('already') || msg.includes('registered') || inviteError?.status === 422) {
        return respond(409, 'An account with this email already exists. Find them under Users and change their role instead.')
      }
      if (inviteError?.status === 429 || msg.includes('rate limit')) {
        return respond(429, 'Too many emails sent recently. Please wait a few minutes and try again.')
      }
      console.error('invite failed', inviteError?.status, inviteError?.message)
      return respond(502, 'Could not send the invitation email. Please try again.')
    }

    // 4. The sign-up trigger created a customer profile; give it the invited role.
    const { data: updated, error: roleError } = await admin
      .from('profiles').update({ role }).eq('id', invited.user.id).select('id')
    if (roleError || !updated?.length) {
      console.error('role update failed', roleError?.message)
      return respond(500, 'The invitation was sent but the role could not be set. Open Users and set it there.')
    }
    return respond(200, `Invitation sent to ${email}`, { user_id: invited.user.id, role })
  } catch (e) {
    console.error('unhandled', e)
    return respond(500, 'Something went wrong. Please try again.')
  }
})
