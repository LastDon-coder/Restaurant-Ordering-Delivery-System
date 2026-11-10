# Database tests

`business_rules.test.sql` checks the rules that protect money and permissions, using the real database functions,
RLS policies and constraints (82 checks, including delivery zones): role safety, server-side cart totals, price snapshots, status transitions,
who may do what, delivery flow, Paystack payment and refund handling, and admin safeguards.

`reviews.test.sql` (45 checks) covers reviews and ratings: delivered orders only, one review per item, admin approval before
anything is public, privacy of order ratings, and that nobody can write the tables directly. It builds its own test data.

`notifications.test.sql` (38 checks) covers the order emails: who is queued for which event, no duplicates, nothing for
test addresses, locked-down queue access, and the sender's lease and retry rules. No real email is sent (it is rolled back).

**Run any file:** paste the whole file into the Supabase SQL editor and run it. Everything happens inside one transaction that
is rolled back at the end, so no data is kept. The SQL editor shows an "error" that starts with `TEST REPORT`: that
message is the report. `FAILURES: 0` means everything passed; any line starting with `FAIL` tells you what broke.

Run it again after every migration or change to a function, policy or grant.
