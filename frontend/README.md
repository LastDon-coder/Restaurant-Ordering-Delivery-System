# Frontend (React + Vite + Supabase)

```bash
cd frontend
cp .env.example .env        # fill in VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY (Dashboard > Settings > API Keys)
npm install
npm run dev                 # http://localhost:5173
```

- The app talks to Supabase directly with the **publishable** key. What each user may do is enforced by Row Level
  Security and the SQL functions in `../supabase/migrations`. Never put a secret / service_role key here.
- Supabase Dashboard > Authentication > URL Configuration: add `http://localhost:5173` as a Site URL / redirect URL.
- If "Confirm email" is on (default), new users must click the emailed link before logging in.
- Structure: `components/ context/ hooks/ pages/ services/ utils/`. Role-based routes use `<ProtectedRoute roles={[...]} />`.

## Done
Menu (categories, foods; loading / error / empty states), sign up, log in, log out, session handling, 404.
## Next
Cart, checkout (address + payment method), Paystack payment page, my orders, then staff/admin and rider dashboards.
