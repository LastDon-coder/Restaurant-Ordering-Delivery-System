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
