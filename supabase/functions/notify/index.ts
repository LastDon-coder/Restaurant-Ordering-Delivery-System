// Sends the queued order emails. POST /notify (no input). Called by the database right after an order event
// (pg_net) and every minute by pg_cron if anything is still waiting.
// WHY it takes no input and needs no login: it only works through the outbox table. All a caller can do is make it
// send mail that was already due, so spamming the URL costs nothing but a database query. (No secret to leak.)
// Needs these Edge Function secrets: RESEND_API_KEY, MAIL_FROM (e.g. Restaurant <orders@yourdomain.com>).
// Optional: SITE_URL (links inside emails), RESTAURANT_NAME.
import { createClient } from 'npm:@supabase/supabase-js@2'

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')
const MAIL_FROM = Deno.env.get('MAIL_FROM')
const SITE = (Deno.env.get('SITE_URL') ?? 'https://restaurant-ordering-delivery.vercel.app').replace(/\/+$/, '')
const NAME = Deno.env.get('RESTAURANT_NAME') ?? 'Restaurant'

const secretKeys = Deno.env.get('SUPABASE_SECRET_KEYS')
const serviceKey = secretKeys ? JSON.parse(secretKeys)['default'] : Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const db = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

// Customer names and addresses are typed by users: escape everything before it goes into HTML.
const esc = (v: unknown) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!))
const naira = (v: unknown) => '₦' + Number(v ?? 0).toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
const payLabel = (m: string) => (m === 'online' ? 'Paid online' : m === 'cash_on_delivery' ? 'Cash on delivery' : String(m ?? ''))

type Item = { name: string; quantity: number; price: number }
type Row = { id: number; kind: string; to_email: string; to_name: string | null; payload: Record<string, any>; attempts: number }

function itemsText(items: Item[]) {
  return items.map((i) => `${i.quantity} x ${i.name}  ${naira(i.quantity * i.price)}`).join('\n')
}
function itemsHtml(items: Item[]) {
  return `<table style="width:100%;border-collapse:collapse">${items
    .map((i) => `<tr><td style="padding:4px 0">${esc(i.quantity)} × ${esc(i.name)}</td><td style="padding:4px 0;text-align:right">${naira(i.quantity * i.price)}</td></tr>`)
    .join('')}</table>`
}

// Each template returns { subject, intro, lines (plain facts), link, linkLabel, showItems }
function compose(row: Row) {
  const p = row.payload
  const id = p.order_id
  const hi = row.to_name ? `Hi ${row.to_name},` : 'Hi,'
  const total = naira(p.total)
  switch (row.kind) {
    case 'order_received':
      return { subject: `We received your order #${id}`, intro: `${hi} thank you for your order. We have received it and will confirm it shortly.`,
        facts: [`Order #${id}`, `Total: ${total} (${payLabel(p.payment_method)})`, `Delivering to: ${p.address}`], items: p.items,
        link: `${SITE}/orders/${id}`, linkLabel: 'Track your order' }
    case 'order_status': {
      const s = p.status
      const msg = s === 'confirmed' ? 'The restaurant has confirmed your order.'
        : s === 'preparing' ? 'Your food is being prepared.' : 'Your order is on its way to you.'
      const subj = s === 'confirmed' ? `Order #${id} is confirmed` : s === 'preparing' ? `Order #${id} is being prepared` : `Order #${id} is on its way`
      return { subject: subj, intro: `${hi} ${msg}`, facts: [`Order #${id}`, `Total: ${total} (${payLabel(p.payment_method)})`], items: [],
        link: `${SITE}/orders/${id}`, linkLabel: 'Track your order' }
    }
    case 'new_order':
      return { subject: `New order #${id}: ${total} (${payLabel(p.payment_method)})`, intro: `${hi} a new order is waiting for you.`,
        facts: [`Order #${id}`, `Customer: ${p.customer_first_name ?? ''}`, `Total: ${total} (${payLabel(p.payment_method)})`,
          `Area: ${p.zone ?? 'Other area'}`, `Address: ${p.address}`], items: p.items,
        link: `${SITE}/staff/orders`, linkLabel: 'Open the orders page' }
    case 'rider_assigned':
      return { subject: `Delivery assigned: order #${id}`, intro: `${hi} you have a new delivery.`,
        facts: [`Order #${id}`, `Deliver to: ${p.address}`, `Area: ${p.zone ?? 'Other area'}`,
          `Customer: ${p.customer_first_name ?? ''}${p.customer_phone ? ' · ' + p.customer_phone : ''}`,
          p.payment_method === 'cash_on_delivery' ? `Collect cash: ${total}` : 'Already paid online: collect nothing'], items: [],
        link: `${SITE}/rider`, linkLabel: 'Open your deliveries' }
    default:
      throw new Error(`unknown kind ${row.kind}`)
  }
}

function render(row: Row) {
  const c = compose(row)
  const text = [c.intro, '', ...c.facts, ...(c.items.length ? ['', itemsText(c.items)] : []), '', `${c.linkLabel}: ${c.link}`, '', NAME].join('\n')
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;color:#222;line-height:1.5">
<h2 style="margin:0 0 12px">${esc(NAME)}</h2>
<p>${esc(c.intro)}</p>
<ul style="padding-left:18px">${c.facts.map((f) => `<li>${esc(f)}</li>`).join('')}</ul>
${c.items.length ? itemsHtml(c.items) : ''}
<p style="margin:20px 0"><a href="${esc(c.link)}" style="background:#c0392b;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">${esc(c.linkLabel)}</a></p>
<p style="color:#888;font-size:12px">You get this email because of an order on ${esc(NAME)}.</p></div>`
  return { subject: c.subject, text, html }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

async function send(row: Row): Promise<{ ok: boolean; error?: string; permanent?: boolean }> {
  const { subject, text, html } = render(row)
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      'Content-Type': 'application/json',
      // If we crash after Resend accepts the mail but before we record it, the retry carries the same key,
      // so Resend will not send a second copy.
      'Idempotency-Key': `outbox-${row.id}`,
    },
    body: JSON.stringify({ from: MAIL_FROM, to: [row.to_email], subject, text, html }),
  })
  if (res.ok) return { ok: true }
  const body = (await res.text()).slice(0, 300)
  // 422 = Resend says the message itself is invalid (e.g. a bad address): retrying cannot help.
  return { ok: false, error: `Resend ${res.status}: ${body}`, permanent: res.status === 422 }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ success: false, message: 'Use POST' }, 405)
  if (!RESEND_API_KEY || !MAIL_FROM) {
    // Nothing is claimed, so queued emails simply wait until the secrets are set.
    return json({ success: false, message: 'Email is not configured (set RESEND_API_KEY and MAIL_FROM)' }, 503)
  }

  const { data, error } = await db.rpc('claim_notifications', { p_limit: 20 })
  if (error) {
    console.error('claim failed', error)
    return json({ success: false, message: 'Could not read the queue' }, 500)
  }
  const rows = (data ?? []) as Row[]
  let sent = 0
  let failed = 0
  for (const row of rows) {
    let result: { ok: boolean; error?: string; permanent?: boolean }
    try {
      result = await send(row)
      // Resend allows about 2 requests a second on the free plan; a 429 just means "try again later".
    } catch (e) {
      result = { ok: false, error: `send threw: ${(e as Error).message}` }
    }
    const { error: fe } = await db.rpc('finish_notification', {
      p_id: row.id, p_ok: result.ok, p_error: result.error ?? null, p_permanent: result.permanent ?? false,
    })
    if (fe) console.error('finish failed', row.id, fe)
    if (result.ok) sent++
    else { failed++; console.error('email failed', row.id, row.kind, result.error) }
    await sleep(600)
  }
  return json({ success: true, message: 'Done', data: { claimed: rows.length, sent, failed } })
})
