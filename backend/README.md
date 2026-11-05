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

## Layout

| Path | Purpose |
|---|---|
| `server.js` | Starts the server: checks the database, listens, shuts down cleanly |
| `app.js` | Builds the Express app: security headers, CORS, JSON parsing, routes, error handling |
| `config/env.js` | Loads and validates `.env` |
| `config/db.js` | Shared MySQL connection pool. Use `pool.execute(sql, [values])` |
| `middleware/errorHandler.js` | 404 handler and the one central error handler |
| `utils/AppError.js` | `throw new AppError(message, status)` for expected errors |
| `routes/` | One file per resource: `health.js`, `auth.js`, `users.js`, `categories.js`, `foods.js` |
| `controllers/` | Request handlers: `authController.js`, `userController.js`, `categoryController.js`, `foodController.js` |
| `models/` | All SQL lives here: `userModel.js`, `passwordResetModel.js`, `categoryModel.js`, `foodModel.js` |
| `middleware/` | `auth.js` (authenticate, authorize), `validate.js`, `rateLimiter.js`, `errorHandler.js` |
| `services/` | `emailService.js` (prints reset links for now) |
| `scripts/seedAdmin.js` | Creates the first admin from `.env` |

All responses use `{ success, message, data }`.
