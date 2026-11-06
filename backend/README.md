# Backend (Express + MySQL)

## Setup

1. Create the database: run `database/setup_all.sql` in one go (in MySQL Workbench: File > Open
   SQL Script, then the lightning bolt). It is the files in `database/migrations/` and
   `database/seeds/` joined in order. To run them one by one instead, do `000`, then `001` to
   `013` against `restaurant_db`, then the seeds.
2. `cd backend && npm install`
3. `cp .env.example .env` and fill in your MySQL details, plus `ADMIN_EMAIL`, `ADMIN_PASSWORD`
   (10+ characters) and `ADMIN_PHONE`. Also set `JWT_SECRET` (the server will not start without
   it). Generate one with:
   `node -e "console.log(require('crypto').randomBytes(48).toString('hex'))"`
4. `npm run seed:admin` creates the first admin account (safe to run twice).
   Development only, optional: set `TEST_USER_PASSWORD` in `.env`, then `npm run seed:test-users`
   creates `customer@example.com`, `staff@example.com` and `rider@example.com` with that password
   (safe to run twice; refuses to run when `NODE_ENV=production`).
5. `npm run dev` starts the API with auto-restart, or `npm start` for plain Node.

## Check it works

```
GET http://localhost:5000/api/health
-> 200 { "success": true, "message": "API and database are healthy", "data": null }
```

## Authentication (Step 5)

Tokens travel in the header `Authorization: Bearer <token>` and last 1 day (`JWT_EXPIRES_IN`).
Import `postman/restaurant-api.postman_collection.json` into Postman to try everything: the
Register and Login requests save the token for you.

| Method | Path | Who | What it does |
|---|---|---|---|
| POST | `/api/v1/auth/register` | Anyone | Creates a **customer** account, returns `{ user, token }` |
| POST | `/api/v1/auth/login` | Anyone | Returns `{ user, token }` |
| GET | `/api/v1/auth/me` | Logged in | Returns the current user |
| POST | `/api/v1/auth/forgot-password` | Anyone | Creates a reset link (printed in the server terminal for now, no real email yet) |
| POST | `/api/v1/auth/reset-password` | Anyone with a link | Sets a new password with `{ token, password }` |
| POST | `/api/v1/users` | **Admin only** | Creates a `staff` or `rider` account |

Sample register request and reply:

```
POST /api/v1/auth/register
{ "first_name": "Ada", "last_name": "Obi", "email": "ada@example.com",
  "phone": "08012345678", "password": "CorrectHorse9" }

201 { "success": true, "message": "Account created",
      "data": { "user": { "user_id": 2, "first_name": "Ada", "last_name": "Obi",
                          "email": "ada@example.com", "phone": "08012345678", "role": "customer" },
                "token": "eyJ..." } }
```

Protect any future route with the middleware in `middleware/auth.js`:
`router.get('/x', authenticate, authorize('admin', 'staff'), handler)`.

Rules worth knowing: passwords are 8 to 72 bytes; login is limited to 10 failed tries per 15 minutes
per IP; there is no logout endpoint (the React app just deletes its token); a token cannot be
revoked before it expires, but a deactivated account or changed role takes effect immediately.

## Categories

| Method | Path | Who | What it does |
|---|---|---|---|
| GET | `/api/v1/categories` | Anyone | Lists **active** categories, sorted by name. Admin only: `?status=all` or `?status=inactive` |
| GET | `/api/v1/categories/:id` | Anyone | One category. Inactive ones look like 404 to everyone except an admin |
| POST | `/api/v1/categories` | **Admin** | Creates a category |
| PUT | `/api/v1/categories/:id` | **Admin** | Updates the fields you send (at least one). `null` or `""` clears `description` / `image_url` |
| DELETE | `/api/v1/categories/:id` | **Admin** | Deletes an empty category. If it still has food: `409`, and you should set it to `inactive` instead |

Fields: `category_name` (required, 1 to 100 characters, unique ignoring case), `description` (up to 255),
`image_url` (must start with `http://` or `https://`), `status` (`active` or `inactive`, default `active`).

```
POST /api/v1/categories        (Authorization: Bearer <admin token>)
{ "category_name": "Desserts", "description": "Cakes and ice cream" }

201 { "success": true, "message": "Category created",
      "data": { "category": { "category_id": 5, "category_name": "Desserts",
                              "description": "Cakes and ice cream", "image_url": null, "status": "active" } } }
```

Errors: `400` bad input (with an `errors` list of `{ field, message }`), `401` not logged in,
`403` not an admin, `404` not found, `409` duplicate name or category still in use.

## Food items

| Method | Path | Who | What it does |
|---|---|---|---|
| GET | `/api/v1/foods` | Anyone | The menu: foods that are on sale, in active categories. Supports search, filters, sorting, paging |
| GET | `/api/v1/foods/:id` | Anyone | One food. Sold-out foods and foods in inactive categories look like 404 to everyone except an admin |
| POST | `/api/v1/foods` | **Admin** | Creates a food item |
| PUT | `/api/v1/foods/:id` | **Admin** | Updates the fields you send (at least one) |
| DELETE | `/api/v1/foods/:id` | **Admin** | Deletes a food that was never ordered. Otherwise `409`: set `is_available` to `false` instead |

Query string for `GET /api/v1/foods` (all optional):

| Parameter | Meaning |
|---|---|
| `q` | Search text, matched against name and description, ignoring case (max 100 characters) |
| `category_id` | Only foods in this category |
| `sort` | `name` (default), `price_asc`, `price_desc`, `newest` |
| `page`, `limit` | Paging. Defaults 1 and 20; `limit` is at most 100 |
| `available` | `true` (default). Admin only: `false` (sold out only) or `all` |

Fields: `category_id` (required, must exist), `food_name` (required, up to 150 characters),
`price` (required, greater than 0, at most 2 decimal places; send `1200.5` or `"1200.50"`),
`description` (up to 1000), `image_url` (`http://` or `https://` address; file upload comes later),
`is_available` (`true` or `false`, default `true`).

**Prices are strings** such as `"3500.00"`: money is stored as an exact decimal, and a JavaScript
number can drift (0.1 + 0.2). Show it as it is; the server does all money maths.

```
GET /api/v1/foods?q=rice&sort=price_asc&page=1&limit=10

200 { "success": true, "message": "Foods retrieved",
      "data": { "foods": [ { "food_id": 2, "category_id": 1, "category_name": "Rice Dishes",
                             "category_status": "active", "food_name": "Fried Rice & Plantain",
                             "description": "Vegetable fried rice with dodo", "price": "3200.00",
                             "image_url": null, "is_available": true,
                             "created_at": "...", "updated_at": "..." } ],
                "pagination": { "page": 1, "limit": 10, "total": 2, "total_pages": 1 } } }
```

Errors: `400` bad input (with an `errors` list of `{ field, message }`), `401` not logged in,
`403` not an admin, `404` not found, `409` food appears in past orders. Deleting a food that is
only sitting in carts works, and it is removed from those carts.

## Cart (Step 11)

Customers only (admin, staff and rider get `403`). Every route needs `Authorization: Bearer <token>`.
Every response returns the **whole cart**, so the React app can just replace what it shows.

| Method | Path | Body | Does |
|---|---|---|---|
| GET | `/api/v1/cart` | none | Show the cart (an empty cart if none yet) |
| POST | `/api/v1/cart/items` | `{ "food_id": 1, "quantity": 2 }` | Add a food. Already in the cart: quantity goes up. `quantity` defaults to 1 |
| PUT | `/api/v1/cart/items/:id` | `{ "quantity": 3 }` | Set the quantity to exactly this |
| DELETE | `/api/v1/cart/items/:id` | none | Remove a line |

```
POST /api/v1/cart/items   { "food_id": 1, "quantity": 2 }

201 { "success": true, "message": "Item added to cart",
      "data": { "cart": {
        "items": [ { "cart_item_id": 1, "food_id": 1, "food_name": "Jollof Rice & Chicken",
                     "image_url": null, "unit_price": "3500.00", "quantity": 2,
                     "line_total": "7000.00", "is_available": true } ],
        "summary": { "item_count": 2, "subtotal": "7000.00", "delivery_fee": "500.00",
                     "discount": "0.00", "total": "7500.00" } } } }
```

Rules the server enforces:
- **The client never sends money.** Prices come from the live menu; a price, total or `user_id` in the body is ignored.
- Totals are added up in whole kobo (`utils/money.js`), so `19.99 x 3` is exactly `59.97`.
- Delivery fee is the flat `DELIVERY_FEE` from `.env` (default `0`), charged only when there is something to deliver. `discount` is always `"0.00"` in version 1.
- Only foods that are available and in an active category can be added (`404` otherwise). If a food later sells out, it stays in the cart with `is_available: false` and is left out of the totals.
- At most 50 of one food (`400`). Another customer's item id gives `404`.

## Orders (Step 12)

Place an order from the cart, then read orders back. Order status changes (confirm, cancel, ...) come in Step 13 and payment verification in Step 14, so every order is `pending` for now.

| Method | Path | Who | Does |
|---|---|---|---|
| POST | `/api/v1/orders` | customer | Turn the cart into an order |
| GET | `/api/v1/orders?status=&page=&limit=` | customer (own), admin, staff (all) | List orders, newest first |
| GET | `/api/v1/orders/:id` | customer (own), admin, staff | One order with items and payment |

Riders get order access in Step 15, once deliveries exist.

```
POST /api/v1/orders
{ "delivery_address": { "street_address": "12 Aba Road", "city": "Port Harcourt",
                        "state": "Rivers", "landmark": "Near the roundabout" },
  "payment_method": "cash_on_delivery" }          // or "online"

201 { "success": true, "message": "Order placed",
      "data": { "order": { "order_id": 1, "order_status": "pending",
        "subtotal": "7300.00", "delivery_fee": "500.00", "discount": "0.00", "total_amount": "7800.00",
        "delivery_address": { ... }, "customer": { ... },
        "payment": { "payment_method": "cash_on_delivery", "payment_status": "pending",
                     "amount": "7800.00", "paid_at": null },
        "items": [ { "food_id": 1, "food_name": "Jollof Rice & Chicken", "quantity": 2,
                     "unit_price": "3500.00", "line_total": "7000.00" } ] } } }
```

How it is kept safe:
- **One transaction** saves the address, order, items, payment and empties the cart. If any step fails, nothing is saved.
- **The server reads the cart**, so the body only says where and how to pay. Prices, fees, totals and status in the body are ignored.
- **Snapshot:** item names and prices are copied into `order_items`; later menu changes never alter old orders.
- **Double-click safe:** the cart row is locked, so a second simultaneous submit finds an empty cart (`400`).
- A sold-out food (or one in an inactive category) in the cart gives `400` listing it; nothing is created.
- The typed address is saved as an `addresses` row (the table requires one) and copied onto the order.
- Someone else's order id gives `404`. `payment_status` stays `pending` until Step 14 (online) or delivery (cash).

## Order status workflow (Step 13)

**Run the new migration first** (a new table): in MySQL Workbench open `database/migrations/014_create_order_status_history.sql` and run it. (A fresh `setup_all.sql` already includes it.)

`PATCH /api/v1/orders/:id/status` with `{ "status": "confirmed", "reason": "optional text" }`.
Staff and admin can make any allowed move; a customer can only cancel their own order while it is `pending`. Riders get the two delivery moves in Step 15.

```
pending --> confirmed --> preparing --> ready_for_delivery --> out_for_delivery --> delivered
   |  \__> rejected          |                 |                    \__> failed
   |                          \_________________\__> cancelled (also from confirmed)
   \__> cancelled
```

| From | Can move to |
|---|---|
| pending | confirmed, rejected, cancelled |
| confirmed | preparing, cancelled |
| preparing | ready_for_delivery, cancelled |
| ready_for_delivery | out_for_delivery, cancelled |
| out_for_delivery | delivered, failed |
| delivered, cancelled, rejected, failed | nothing (final) |

- **Reason required** (`400` without one) for `rejected`, `cancelled` and `failed`, except when a customer cancels their own order.
- Invalid move (skipping, going back, leaving a final status): `409` listing the allowed next statuses. Not allowed for your role: `403`. Someone else's order: `404`.
- An **online-payment order cannot be confirmed until it is paid** (`409`); payment verification arrives in Step 14.
- Every change is saved with its history line in one transaction, and the order row is locked, so two people acting at once can't both win. `GET /orders/:id` now includes `status_history` (from, to, reason, time) so customers can see what happened and why.
- The rules live in `utils/orderWorkflow.js`.

## Payments with Paystack (Step 14)

Online payments use [Paystack](https://paystack.com/docs/api/) (NGN). The same code runs in test and production: only the key changes.

**Setup**
1. Paystack Dashboard > Settings > API Keys & Webhooks. Copy the **Secret** key (`sk_test_...`) into `backend/.env` as `PAYSTACK_SECRET_KEY=`. Never use the public key here, never commit the key, never put it in React.
2. Webhook URL (same page): `https://YOUR-PUBLIC-URL/api/v1/payments/webhook`. Paystack can't reach `localhost`, so for local testing run a tunnel such as `ngrok http 5000` and use its https address. Without it, the verify endpoint below still works.
3. In production set `NODE_ENV=production` and the `sk_live_...` key. The server refuses to start in production without a key and warns if it is a test key.
4. Without a key the app runs, but payment endpoints answer `503`.

| Method | Path | Who | Does |
|---|---|---|---|
| POST | `/api/v1/payments/initialize` | customer | `{ "order_id": 1 }` starts a payment; returns `authorization_url` to send the browser to |
| GET | `/api/v1/payments/verify/:reference` | owner customer, admin, staff | Asks Paystack what happened and updates the payment |
| POST | `/api/v1/payments/webhook` | Paystack only | Signed server-to-server notification |

**Flow:** customer places an order with `payment_method: "online"` (Step 12) -> `initialize` -> browser goes to Paystack -> Paystack redirects to `PAYSTACK_CALLBACK_URL?reference=...` (default `FRONTEND_URL/payment/callback`) -> the React page calls `verify/:reference`. The webhook confirms the same thing even if the customer closes the tab. Staff can confirm the order once it is `paid`.

```
POST /api/v1/payments/initialize   { "order_id": 1 }
200 { "data": { "payment": { "authorization_url": "https://checkout.paystack.com/...",
      "access_code": "...", "reference": "ORD-1-9f86d081884c7d65", "amount": "4000.00", "currency": "NGN" } } }

GET /api/v1/payments/verify/ORD-1-9f86d081884c7d65
200 { "data": { "payment": { "order_id": 1, "order_status": "pending", "payment_method": "online",
      "payment_status": "paid", "amount": "4000.00", "paid_at": "...", "reference": "ORD-1-9f86d081884c7d65" } } }
```

How it is kept safe:
- **The client never sends money.** The amount sent to Paystack (in kobo) comes from the order's own total saved at checkout.
- **"Paid" is decided by the server, from Paystack's answer**, never from the browser or the redirect. The amount and currency must match exactly, otherwise the payment stays unpaid and the problem is logged (`mismatch`).
- **Webhook signature:** Paystack signs the raw body with HMAC-SHA512 using your secret key (`x-paystack-signature`). Wrong or missing signature gives `401`. The route is mounted before the JSON parser so the raw bytes are intact.
- **Idempotent:** webhook retries, double verifies and a verify racing a webhook all give one paid payment (the payment row is locked in a transaction).
- **References** look like `ORD-<orderId>-<random>` and are created by the server. If a customer pays an older attempt, the money still lands on the right order.
- Paystack down or slow: `502`, nothing changes, 10 second timeout, no internals leaked.
- Cash on delivery: the payment becomes `paid` when staff mark the order `delivered`.

**Things that need a human (logged as `DUPLICATE PAYMENT` or "was paid" in the server log):** a customer who pays twice, or pays an order that was cancelled in the meantime. Refund these in the Paystack dashboard for now; an automated admin refund endpoint is a good next addition.

## Layout

| Path | Purpose |
|---|---|
| `server.js` | Starts the server: checks the database, listens, shuts down cleanly |
| `app.js` | Builds the Express app: security headers, CORS, JSON parsing, routes, error handling |
| `config/env.js` | Loads and validates `.env` |
| `config/db.js` | Shared MySQL connection pool. Use `pool.execute(sql, [values])` |
| `middleware/errorHandler.js` | 404 handler and the one central error handler |
| `utils/AppError.js` | `throw new AppError(message, status)` for expected errors |
| `routes/` | One file per resource: `health.js`, `auth.js`, `users.js`, `categories.js`, `foods.js`, `cart.js`, `orders.js`, `payments.js`, `paymentWebhook.js` |
| `controllers/` | Request handlers: `authController.js`, `userController.js`, `categoryController.js`, `foodController.js`, `cartController.js`, `orderController.js`, `paymentController.js` |
| `models/` | All SQL lives here: `userModel.js`, `passwordResetModel.js`, `categoryModel.js`, `foodModel.js`, `cartModel.js`, `orderModel.js`, `paymentModel.js` |
| `middleware/` | `auth.js` (authenticate, authorize), `validate.js`, `rateLimiter.js`, `errorHandler.js` |
| `services/` | `emailService.js` (prints reset links for now), `cartService.js` (cart totals), `orderService.js` (place order, change status), `paymentService.js` and `paystackService.js` (payments), `utils/orderWorkflow.js` (status rules) |
| `scripts/seedAdmin.js` | Creates the first admin from `.env` |

All responses use `{ success, message, data }`.
