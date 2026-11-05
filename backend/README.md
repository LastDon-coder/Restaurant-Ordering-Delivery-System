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
| POST | `/api/auth/register` | Anyone | Creates a **customer** account, returns `{ user, token }` |
| POST | `/api/auth/login` | Anyone | Returns `{ user, token }` |
| GET | `/api/auth/me` | Logged in | Returns the current user |
| POST | `/api/auth/forgot-password` | Anyone | Creates a reset link (printed in the server terminal for now, no real email yet) |
| POST | `/api/auth/reset-password` | Anyone with a link | Sets a new password with `{ token, password }` |
| POST | `/api/users` | **Admin only** | Creates a `staff` or `rider` account |

Sample register request and reply:

```
POST /api/auth/register
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

## Layout

| Path | Purpose |
|---|---|
| `server.js` | Starts the server: checks the database, listens, shuts down cleanly |
| `app.js` | Builds the Express app: security headers, CORS, JSON parsing, routes, error handling |
| `config/env.js` | Loads and validates `.env` |
| `config/db.js` | Shared MySQL connection pool. Use `pool.execute(sql, [values])` |
| `middleware/errorHandler.js` | 404 handler and the one central error handler |
| `utils/AppError.js` | `throw new AppError(message, status)` for expected errors |
| `routes/` | One file per resource: `health.js`, `auth.js`, `users.js` |
| `controllers/` | Request handlers: `authController.js`, `userController.js` |
| `models/` | All SQL lives here: `userModel.js`, `passwordResetModel.js` |
| `middleware/` | `auth.js` (authenticate, authorize), `validate.js`, `rateLimiter.js`, `errorHandler.js` |
| `services/` | `emailService.js` (prints reset links for now) |
| `scripts/seedAdmin.js` | Creates the first admin from `.env` |

All responses use `{ success, message, data }`.
