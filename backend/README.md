# Backend (Express + MySQL)

## Setup

1. Create the database: run `database/migrations/000_create_database.sql`, then `001` to `013`
   (in order, against `restaurant_db`), then the two files in `database/seeds/`.
2. `cd backend && npm install`
3. `cp .env.example .env` and fill in your MySQL details, plus `ADMIN_EMAIL`, `ADMIN_PASSWORD`
   (10+ characters) and `ADMIN_PHONE`.
4. `npm run seed:admin` creates the first admin account (safe to run twice).
5. `npm run dev` starts the API with auto-restart, or `npm start` for plain Node.

## Check it works

```
GET http://localhost:5000/api/health
-> 200 { "success": true, "message": "API and database are healthy", "data": null }
```

## Layout

| Path | Purpose |
|---|---|
| `server.js` | Starts the server: checks the database, listens, shuts down cleanly |
| `app.js` | Builds the Express app: security headers, CORS, JSON parsing, routes, error handling |
| `config/env.js` | Loads and validates `.env` |
| `config/db.js` | Shared MySQL connection pool. Use `pool.execute(sql, [values])` |
| `middleware/errorHandler.js` | 404 handler and the one central error handler |
| `utils/AppError.js` | `throw new AppError(message, status)` for expected errors |
| `routes/` | One file per resource (so far only `health.js`) |
| `scripts/seedAdmin.js` | Creates the first admin from `.env` |

All responses use `{ success, message, data }`.
