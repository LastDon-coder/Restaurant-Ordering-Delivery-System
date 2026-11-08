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
