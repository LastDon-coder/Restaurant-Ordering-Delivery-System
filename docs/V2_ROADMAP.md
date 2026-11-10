# Version 2 roadmap: multiple restaurants + live tracking

Status: DRAFT for approval. Nothing here is built yet. Build order matters: each phase depends on the one before it.
We build one phase at a time, with a way to test it at the end of each (same as version 1).

## Goal

Turn the single-restaurant app into a platform where several restaurants each run their own menu, staff, orders and
delivery pricing, and where customers can watch an order and its rider move in real time.

Out of scope for v2 (decide later): mobile app, loyalty/promo codes, orders that mix several restaurants, restaurant
self-signup with identity checks, automated bank payouts.

## Design decisions (proposed defaults, change any of them before Phase 1)

1. **Tenancy model:** a new `restaurants` table; every restaurant-owned row carries `restaurant_id`. People are linked to
   restaurants through `restaurant_members (user_id, restaurant_id, member_role: owner | manager | staff)`.
2. **Roles:** `profiles.role` stays platform-level (`customer`, `rider`, `admin` = platform admin). The v1 `staff` role moves
   into `restaurant_members`, because one person's staff rights belong to one restaurant, not the whole platform.
3. **One restaurant per cart and per order.** Adding food from another restaurant asks to clear the cart first. A
   multi-restaurant checkout (split orders, split payments) is a separate, later feature.
4. **Delivery pricing is per restaurant:** base fee and delivery areas move from `private.settings` and `delivery_zones` to
   each restaurant.
5. **Riders are a platform-wide pool** that restaurants assign from (simple, and riders can serve several restaurants).
   The alternative is riders per restaurant: say so before Phase 1 if you prefer it.
6. **Money:** record each order's platform commission in a ledger first and pay restaurants out manually. Paystack split
   payments (subaccounts) need business verification for every restaurant, so they come last and only if wanted.
7. **URLs:** `/r/<slug>` for each restaurant (works with the current Vercel setup; subdomains can come later).
8. **Existing data:** v1 data becomes "Restaurant #1" in a backfill migration, so nothing is lost and old orders keep working.

## Biggest risks (and how the plan deals with them)

- **Cross-restaurant data leaks** (staff of A reading orders of B). Every RLS policy and SQL function changes from "is staff"
  to "is a member of THIS restaurant". Phase 2 ends with a dedicated isolation test file that tries to break this.
- **Breaking live v1 orders during the migration.** Migrations are additive first (nullable `restaurant_id`, backfill, then
  `NOT NULL`), and the v1 SQL and e2e tests must stay green after every phase.
- **Web location limits.** A website can only share the rider's position while the rider's page is open and the screen is
  on; phones pause browsers in the background. Phase 7 is built for that (rider keeps the delivery screen open) and tells the
  rider when sharing stops. Reliable background tracking needs a native app (a later version).
- **Geocoding Nigerian street addresses is unreliable.** The customer can drop a pin on the map at checkout (optional)
  instead of relying on text-to-coordinates lookups.
- **Cost:** Supabase Realtime and map tiles have free limits. Phase 7 uses OpenStreetMap + Leaflet (no key) and throttles
  location updates.

## Phases

### Phase 1: Tenancy foundation (database only, no visible change)
- `restaurants` (name, slug, description, logo, phone, address, is_open, status active/suspended, base_delivery_fee, commission_percent).
- `restaurant_members`, helper functions `private.is_member(restaurant_id)` and `private.can_manage(restaurant_id)`.
- Add `restaurant_id` to `categories`, `food_items`, `delivery_zones`, `orders`, `carts`; create "Restaurant #1"; backfill; set `NOT NULL`.
- Move the v1 staff users into `restaurant_members` for Restaurant #1.
- Test: v1 SQL tests still pass; new tests for the helpers and the backfill.

### Phase 2: Security refactor + isolation tests
- Rewrite every policy and function (cart, `place_order`, status changes, rider assignment, reviews, refunds, zones, fees) to be restaurant-aware.
- Platform admin keeps global access; owner/manager/staff get their restaurant only.
- New `tenancy.test.sql`: staff of A cannot read, change, approve, refund or assign anything of B (expect 42501 / P0002 everywhere).

### Phase 3: Customer side
- Home page lists restaurants (open/closed, rating); `/r/<slug>` shows one menu; search by name.
- Cart rule: one restaurant per cart; clear-cart prompt when switching.
- Checkout and order pages show the restaurant; order emails and ratings carry it.

### Phase 4: Restaurant dashboards and onboarding
- Staff/manager pages scope to their restaurant; owners manage menu, hours/open switch, delivery fee and areas, team.
- Platform admin: create a restaurant, invite its owner by email, suspend a restaurant (hidden from customers, no new orders).
- Per-restaurant reviews moderation (restaurant manager) with platform admin override.

### Phase 5: Money
- `order_ledger` rows (gross, commission, restaurant share) created when an order is paid.
- Admin and owner reports: sales by day, by restaurant, commission owed; export to CSV.
- Optional later: Paystack split payments.

### Phase 6: Realtime status
- Customer order page, staff board and rider screen update instantly through Supabase Realtime (replaces the 30-second refresh).
- RLS decides who receives which event; tested.

### Phase 7: Live rider tracking
- Rider screen shares position while an order is out for delivery (throttled, with a clear "sharing location" indicator and a stop at delivered).
- `delivery_locations` (latest point per delivery, purged after 24 hours); function `update_rider_location(order_id, lat, lng)` checks
  the caller is the assigned rider and the order is out for delivery.
- Customer sees a map (Leaflet + OpenStreetMap) with the rider moving; staff and admins of that restaurant see all their riders.
- Optional: customer drops a drop-off pin at checkout (`orders.delivery_lat/lng`); simple distance-based ETA.

### Phase 8: Notifications, SEO, polish
- Emails per restaurant (staff emails go only to that restaurant's team; restaurant name in the sender and subject).
- Sitemap lists each restaurant page; canonical tags and page titles per restaurant.

### Phase 9: Tests and release
- Extend the browser tests (two restaurants, cross-restaurant isolation, tracking with a faked location).
- Update README, ER diagram, and deploy checklist; backfill rehearsal on a copy before the real migration.

## Permission matrix (target)

| Action | Customer | Rider | Restaurant staff | Manager/Owner | Platform admin |
|---|---|---|---|---|---|
| Browse restaurants and menus | yes | yes | yes | yes | yes |
| Place an order | yes | no | no | no | no |
| See own orders | yes | assigned only | own restaurant | own restaurant | all |
| Confirm, prepare, reject, cancel orders | no | no | own restaurant | own restaurant | all |
| Assign a rider | no | no | own restaurant | own restaurant | all |
| Update delivery status and share location | no | assigned only | no | no | no |
| Edit menu, fees, areas | no | no | no | own restaurant | all |
| Moderate reviews | no | no | no | own restaurant | all |
| Refunds | no | no | no | request | approve |
| Create or suspend restaurants, manage platform users | no | no | no | no | yes |

## Questions to settle before Phase 1

1. Who creates restaurants: only you as platform admin (recommended for v2), or restaurant self-signup?
2. Riders: shared platform pool (proposed) or per restaurant?
3. Money: manual payouts with a commission ledger (proposed), or Paystack split payments from the start?
4. Is the drop-off pin on a map at checkout wanted, or text addresses only?
