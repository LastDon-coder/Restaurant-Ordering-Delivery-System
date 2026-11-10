# Restaurant Ordering & Delivery System

A full-stack web app that lets a restaurant take food orders online, collect payment, and run deliveries.
Customers browse the menu, order and track their order. Staff run the kitchen, admins manage the menu, delivery
fees, reviews, refunds and people, and riders deliver. Version 1 is a single restaurant.

**Live:** https://restaurant-ordering-delivery.vercel.app

## What it does

| Role | Can do |
|---|---|
| Customer | Browse the menu (with ratings), cart, checkout (cash on delivery or Paystack), choose a delivery area, track the order, rate the order and review food |
| Staff | See all orders, confirm / prepare / mark ready / reject / cancel (with a reason), assign riders, see order ratings |
| Rider | See assigned deliveries, mark picked up and delivered |
| Admin | Everything staff can do, plus menu and categories, delivery fee and areas, review moderation, refunds, invite staff and riders, change roles |

Also: forgot-password, order notification emails (customer, staff, rider), server-side prices and fees, enforced order
status transitions, and server-verified payments.

## Stack

- **Frontend:** React 19, Vite, React Router (`frontend/`), deployed on Vercel from `main`
- **Backend:** Supabase: PostgreSQL with Row Level Security, SQL functions for every sensitive action, Supabase Auth, Edge Functions (`supabase/`)
- **Payments:** Paystack (test mode until live keys are added); **Email:** Resend
- **Tests:** SQL rule tests and Playwright browser tests

## How it is kept safe

- The browser only holds the public publishable key. Secrets (Paystack, Resend, service key) live in Edge Function secrets.
- Roles come from the `profiles` table, never the token. Every sensitive write goes through a `SECURITY DEFINER` function that checks the role.
- Prices, delivery fees and totals are calculated in the database; order items snapshot the price at order time.
- Cart-to-order, payment and status changes are transactional; payments are confirmed server-side (Paystack webhook / verify) before an order counts as paid.
- Emails go through an outbox table, so a mail outage can never break an order.

## Folder map

```
frontend/            React app (src/pages, components, services, context, hooks, utils) + e2e/ browser tests
supabase/migrations/ the database, in order (tables, RLS, functions, zones, reviews, notifications...)
supabase/functions/  Edge Functions: payments, paystack-webhook, invite-user, notify
supabase/tests/      SQL rule tests (run in the SQL editor; each rolls itself back)
docs/                ER diagram
```

The first version of this project used Express + MySQL. That code is kept on the `legacy-express-mysql` branch.

## Run it locally

1. `cd frontend`, then `npm install`.
2. Copy `.env.example` to `.env` and fill in `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`
   (Supabase dashboard -> Project Settings -> API).
3. `npm run dev` and open http://localhost:5173.

The database is the hosted Supabase project; the migrations in `supabase/migrations/` recreate it in a new project
(run them in order in the SQL editor, or with the Supabase CLI).

## Tests

- **Database rules:** paste a file from `supabase/tests/` into the Supabase SQL editor and run it. The "error" it ends with
  is the report (`FAILURES: 0` = pass). Details: `supabase/tests/README.md`.
- **Browser tests:** copy `frontend/.env.e2e.example` to `frontend/.env.e2e`, fill in the four e2e account passwords, then
  `cd frontend`, `npx playwright install chromium` (once) and `npm run e2e`. They run against the live project and place a
  clearly marked test order (`E2E TEST`).

## Deploy and configure

- **Frontend:** push to `main`; Vercel builds `frontend/` and deploys.
- **Database:** apply new files from `supabase/migrations/`.
- **Edge Functions:** see `supabase/functions/README.md` for each function and its secrets
  (`PAYSTACK_SECRET_KEY`, `ALLOWED_ORIGIN`, `RESEND_API_KEY`, `MAIL_FROM`...).
- **Supabase Auth:** list the site address under Authentication -> URL Configuration -> Redirect URLs
  (needed for invite and password-reset links).

## Still to do before real customers

Paystack live keys and webhook, a custom SMTP sender for Supabase Auth emails, a verified Resend sending domain,
a custom domain, and leaked-password protection (Supabase Auth settings).
