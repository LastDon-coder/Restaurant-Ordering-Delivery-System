# Edge Functions

| Function | Auth | Purpose |
|---|---|---|
| `payments` | user JWT (`verify_jwt = true`) | `POST /payments/initialize` `{order_id}` · `POST /payments/verify` `{reference}` · `POST /payments/refund` `{order_id, reason}` (admin) |
| `paystack-webhook` | Paystack HMAC signature (`verify_jwt = false`) | `charge.success`, `refund.processed`, `refund.failed`, `refund.pending` |

## Secrets (Supabase Dashboard > Edge Functions > Secrets, never in git)
- `PAYSTACK_SECRET_KEY` (required) - `sk_test_...` while testing, `sk_live_...` only for production.
- `ALLOWED_ORIGIN` (optional, default `http://localhost:5173`) - the React app's origin (CORS).
- `FRONTEND_URL` / `PAYSTACK_CALLBACK_URL` (optional) - where Paystack sends the customer after paying (default `<origin>/payment/callback`).

## Paystack dashboard
Set the webhook URL (Settings > API Keys & Webhooks) to
`https://<project-ref>.supabase.co/functions/v1/paystack-webhook`.

## Try it
```bash
# 1. sign in as a customer (publishable key from Settings > API Keys) and copy access_token
# 2. place an ONLINE order (place_order RPC) and note its id
curl -X POST https://<ref>.supabase.co/functions/v1/payments/initialize \
  -H "Authorization: Bearer <access_token>" -H "apikey: <publishable key>" \
  -H "Content-Type: application/json" -d '{"order_id": 1}'
# -> { success, message, data: { authorization_url, reference } }  open authorization_url, pay with a Paystack test card
curl -X POST https://<ref>.supabase.co/functions/v1/payments/verify \
  -H "Authorization: Bearer <access_token>" -H "apikey: <publishable key>" \
  -H "Content-Type: application/json" -d '{"reference": "ORD-1-xxxxxxxxxxxxxxxx"}'
```

## invite-user (admin invites staff / riders by email)

`POST /functions/v1/invite-user` with `{ "email", "first_name", "last_name", "role": "staff" | "rider" }` and the admin's login token.
The function checks the caller is an active admin, asks Supabase Auth to email an invite, sets the role, and the invited
person chooses their own password on `/set-password`. Needs the same `ALLOWED_ORIGIN` secret as `payments`
(its value is also used for the link in the email), and **`<ALLOWED_ORIGIN>/set-password` must be listed under
Authentication -> URL Configuration -> Redirect URLs**. Supabase's built-in email sender is rate limited
(a few emails per hour); for production add your own SMTP server under Authentication -> SMTP.

`POST /functions/v1/invite-user` with `{ "action": "resend", "user_id": "<uuid>" }` re-sends the invite. It only works for
someone who was invited and has never signed in (the Users list marks them "Invite pending"); anyone else gets a 409.

## notify (order emails through Resend)

The database writes a row to `private.notification_outbox` in the same transaction as the order change (so an email exists
only if the change committed). `notify` sends the waiting rows through Resend. Who gets what: the customer (order received,
confirmed, preparing, out for delivery), staff and admins (new order, once a cash order is placed or an online payment is
confirmed) and the rider (a delivery was assigned). Orders from test addresses (`@example.com` etc.) send nothing.

`POST /functions/v1/notify` takes no input and no login (`verify_jwt` is off): it only sends mail that is already due.
It is woken by the database right after an order event (pg_net) and every minute by pg_cron while anything waits, so a
failed send is retried (2, 4, 6, 8 minutes, then marked `failed`). Resend gets an `Idempotency-Key` so a retry never double-sends.

Secrets (Supabase dashboard -> Edge Functions -> Secrets): `RESEND_API_KEY`, `MAIL_FROM` (for example
`Restaurant <orders@yourdomain.com>`; the domain must be verified in Resend). Optional: `SITE_URL`, `RESTAURANT_NAME`.
Until the secrets exist the function answers 503 and emails simply wait in the queue.

Look at the queue (SQL editor): `select id, kind, to_email, status, attempts, last_error from private.notification_outbox order by id desc limit 20;`
Re-queue failed ones after fixing a problem: `update private.notification_outbox set status='pending', attempts=0, send_after=now() where status='failed';`

## Production addresses (after deploying the frontend)

`ALLOWED_ORIGIN` accepts several site addresses separated by commas, for example
`https://restaurant-ordering-delivery.vercel.app,http://localhost:5173`. The first is the default. The payment return
link and the invite link point back to whichever listed site made the request, so live and local both work.
Do **not** set `PAYSTACK_CALLBACK_URL` unless you want to force one fixed return address (it overrides the above).
