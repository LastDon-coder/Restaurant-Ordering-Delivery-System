import { expect, test } from '@playwright/test';
import { amounts, openAs, orderCard } from './helpers.js';

// One whole journey on the LIVE project, with the four e2e accounts:
//   admin adds a delivery area -> customer orders (cash on delivery) into it -> staff confirm, prepare, mark ready,
//   assign the rider -> rider picks up and delivers -> customer rates the order and reviews the food ->
//   admin approves the review (visible on the menu) and then HIDES it again -> admin deletes the area.
// The test order itself stays in the database (marked "E2E TEST"). Everything public is undone at the end.

test.describe.configure({ mode: 'serial' });

const stamp = Date.now();
const ZONE = `E2E Zone ${stamp}`;
const EXTRA = 123;
const MARKER = `E2E review ${stamp}`;
const s = { orderId: null, food: null, base: null, zoneCreated: false, approved: false };
const people = {};

test.beforeAll(async ({ browser }) => {
  for (const role of ['admin', 'customer', 'staff', 'rider']) people[role] = await openAs(browser, role);
  people.visitor = await openAs(browser, null); // not logged in
});

test.afterAll(async () => {
  // Undo anything public, even if a step failed half way. Never throws.
  const admin = people.admin?.page;
  try {
    if (admin && s.approved) {
      await admin.goto('/staff/reviews');
      await admin.getByRole('tab', { name: 'Published' }).click();
      const card = admin.locator('li.order-card', { hasText: MARKER }).filter({ has: admin.getByRole('button', { name: 'Hide' }) });
      if (await card.count()) await card.first().getByRole('button', { name: 'Hide' }).click();
    }
    if (admin && s.zoneCreated) {
      await admin.goto('/admin/delivery');
      const zone = admin.locator('li.order-card', { hasText: ZONE });
      if (await zone.count()) {
        await zone.getByRole('button', { name: 'Delete' }).click();
        await admin.getByRole('button', { name: 'Yes, delete' }).click();
        await expect(zone).toHaveCount(0);
      }
    }
  } catch (e) {
    console.warn(`E2E cleanup problem (check Admin > Delivery and Reviews by hand): ${e.message}`);
  }
  if (s.orderId) console.log(`E2E test order #${s.orderId} (${s.food}) stays in the database, marked "E2E TEST".`);
  for (const p of Object.values(people)) await p.context.close();
});

test('admin adds a delivery area', async () => {
  const { page } = people.admin;
  await page.goto('/admin/delivery');
  await expect(page.getByRole('heading', { name: 'Delivery', exact: true })).toBeVisible();
  s.base = Number(await page.getByLabel('Standard fee (₦)').inputValue());
  await page.getByRole('button', { name: '+ Add area' }).click();
  await page.getByLabel('Area name').fill(ZONE);
  await page.getByLabel('Extra charge (₦)').fill(String(EXTRA));
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  const card = page.locator('li.order-card', { hasText: ZONE });
  await expect(card).toBeVisible();
  s.zoneCreated = true;
  const pays = amounts(await card.innerText()).at(-1);
  expect(pays).toBe(s.base + EXTRA); // "Customer pays" = standard fee + extra
});

test('customer orders into that area (cash on delivery)', async () => {
  const { page } = people.customer;
  await page.goto('/');
  const card = page.locator('article').first();
  await expect(card).toBeVisible();
  s.food = (await card.locator('h3').innerText()).trim();
  await card.getByRole('button', { name: 'Add to cart' }).click();
  await expect(card.getByRole('button', { name: 'Added ✓' })).toBeVisible();

  await page.goto('/checkout');
  await page.getByLabel('Street address').fill('E2E TEST - do not prepare or deliver');
  await page.getByLabel('City').fill('Port Harcourt');
  await page.getByLabel('State').fill('Rivers');

  const fee = page.locator('.summary div', { hasText: 'Delivery fee' }).locator('dd');
  await expect.poll(async () => amounts(await fee.innerText())[0]).toBe(s.base); // standard fee for "Other area"

  const area = page.getByLabel('Area');
  const value = await area.locator('option', { hasText: ZONE }).getAttribute('value');
  await area.selectOption(value);
  await expect.poll(async () => amounts(await fee.innerText())[0]).toBe(s.base + EXTRA); // the server's price for the area

  await page.getByLabel('Cash on delivery').check();
  await page.getByRole('button', { name: 'Place order', exact: true }).click();
  await page.waitForURL(/\/orders\/\d+/);
  s.orderId = Number(/\/orders\/(\d+)/.exec(page.url())[1]);
  await expect(page.getByText(`Delivery fee (${ZONE})`)).toBeVisible();
});

test('staff confirm, prepare, mark ready and assign the rider', async () => {
  const { page } = people.staff;
  await page.goto('/staff/orders');
  const card = orderCard(page, s.orderId);
  await expect(card).toBeVisible();
  await expect(card).toContainText(ZONE); // the area is shown on the staff card
  // Each click re-renders the card with the new status, so wait for the status bar before the next step.
  const at = (label) => expect(card.getByRole('list', { name: `Order status: ${label}` })).toBeVisible();
  await card.getByRole('button', { name: 'Confirm', exact: true }).click();
  await at('Confirmed');
  await card.getByRole('button', { name: 'Start preparing' }).click();
  await at('Preparing');
  await card.getByRole('button', { name: 'Mark ready' }).click();
  await at('Ready for delivery');
  await expect(card.getByLabel('Choose rider')).toBeVisible();
  await card.getByLabel('Choose rider').selectOption({ label: 'E2E Rider' });
  await card.getByRole('button', { name: 'Assign rider' }).click();
  await expect(card).toContainText('Rider: E2E Rider');
});

test('rider picks up and delivers', async () => {
  const { page } = people.rider;
  await page.goto('/rider');
  const job = orderCard(page, s.orderId);
  await expect(job).toBeVisible();
  await expect(job).toContainText(ZONE); // the area is shown on the rider card
  await job.getByRole('button', { name: 'Picked up' }).click();
  await job.getByRole('button', { name: /^Delivered/ }).click();
  await expect(job).toHaveCount(0); // delivered jobs leave the list
});

test('customer rates the order and reviews the food', async () => {
  const { page } = people.customer;
  await page.goto(`/orders/${s.orderId}`);
  await expect(page.getByRole('heading', { name: 'Rate your order' })).toBeVisible();

  await page.getByRole('radiogroup', { name: 'Overall rating' }).getByRole('radio', { name: '4 stars' }).click();
  await page.getByRole('radiogroup', { name: 'Delivery rating' }).getByRole('radio', { name: '5 stars' }).click();
  await page.getByLabel('Comment (optional)').first().fill(MARKER);
  await page.getByRole('button', { name: 'Send rating' }).click();
  await expect(page.getByText('Thank you for your feedback')).toBeVisible();

  const item = page.locator('li.order-card', { hasText: s.food });
  await item.getByRole('button', { name: 'Review this item' }).click();
  await item.getByRole('radiogroup').getByRole('radio', { name: '5 stars' }).click();
  await item.getByLabel('Comment (optional)').fill(MARKER);
  await item.getByRole('button', { name: 'Post review' }).click();
  await expect(item.getByText('Waiting for approval')).toBeVisible();
});

test('an unapproved review is not public; the order rating stays private', async () => {
  const { page } = people.visitor;
  await page.goto('/');
  const card = page.locator('article', { hasText: s.food });
  await expect(card).toBeVisible();
  const reviews = card.getByRole('button', { name: /\d+ reviews?/ });
  if (await reviews.count()) {
    await reviews.click();
    await expect(card.getByText('Loading reviews…')).toHaveCount(0);
  }
  await expect(card).not.toContainText(MARKER);
});

test('admin approves the review and it appears on the menu; staff see the order rating', async () => {
  const admin = people.admin.page;
  await admin.goto('/staff/reviews');
  const pending = admin.locator('li.order-card', { hasText: MARKER }).filter({ has: admin.getByRole('button', { name: 'Approve' }) });
  await expect(pending).toHaveCount(1);
  await expect(pending).toContainText(s.food);
  await pending.getByRole('button', { name: 'Approve' }).click();
  await expect(pending).toHaveCount(0);
  s.approved = true;
  await expect(admin.getByText(MARKER).first()).toBeVisible(); // the private order rating shows lower on the page

  const visitor = people.visitor.page;
  await visitor.goto('/');
  const card = visitor.locator('article', { hasText: s.food });
  await card.getByRole('button', { name: /\d+ reviews?/ }).click();
  await expect(card.getByText(MARKER)).toBeVisible();

  const staff = people.staff.page;
  await staff.goto('/staff/reviews');
  await expect(staff.getByText(MARKER)).toBeVisible();
  await expect(staff.getByRole('button', { name: 'Approve' })).toHaveCount(0);
});

test('admin hides the review again so it is not left on the live menu', async () => {
  const admin = people.admin.page;
  await admin.goto('/staff/reviews');
  await admin.getByRole('tab', { name: 'Published' }).click();
  const card = admin.locator('li.order-card', { hasText: MARKER }).filter({ has: admin.getByRole('button', { name: 'Hide' }) });
  await expect(card).toHaveCount(1);
  await card.getByRole('button', { name: 'Hide' }).click();
  await expect(card).toHaveCount(0);
  s.approved = false;

  const visitor = people.visitor.page;
  await visitor.goto('/');
  const menuCard = visitor.locator('article', { hasText: s.food });
  await expect(menuCard).toBeVisible();
  const reviews = menuCard.getByRole('button', { name: /\d+ reviews?/ });
  if (await reviews.count()) {
    await reviews.click();
    await expect(menuCard.getByText('Loading reviews…')).toHaveCount(0);
  }
  await expect(menuCard).not.toContainText(MARKER);
});
