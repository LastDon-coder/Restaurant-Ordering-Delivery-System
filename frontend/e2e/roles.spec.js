import { expect, test } from '@playwright/test';
import { login } from './helpers.js';

// Each role can reach its own pages and is stopped at everyone else's. (The database enforces this too; here we
// check what a person actually sees.)

const blocked = async (page, path) => {
  await page.goto(path);
  await expect(page.getByRole('heading', { name: 'Not allowed' })).toBeVisible();
};

test('customer', async ({ page }) => {
  await login(page, 'customer');
  await expect(page.getByRole('link', { name: 'My orders' })).toBeVisible();
  await page.goto('/orders');
  await expect(page.getByRole('heading', { name: /orders/i }).first()).toBeVisible();
  await page.goto('/apply');
  await expect(page.getByRole('heading', { name: 'Open a restaurant' })).toBeVisible();
  await blocked(page, '/admin/restaurants');
  await blocked(page, '/restaurant');
  await blocked(page, '/staff/orders');
  await blocked(page, '/admin/delivery');
  await blocked(page, '/rider');
});

test('staff', async ({ page }) => {
  await login(page, 'staff');
  await page.goto('/staff/orders');
  await expect(page.getByRole('heading', { name: 'Orders', exact: true })).toBeVisible();
  await page.goto('/staff/reviews');
  await expect(page.getByRole('heading', { name: 'Reviews', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Approve' })).toHaveCount(0); // staff cannot moderate
  await page.goto('/restaurant');
  await expect(page.getByRole('link', { name: 'Settings', exact: true })).toBeVisible();
  await blocked(page, '/admin/menu');
  await blocked(page, '/admin/restaurants');
  await blocked(page, '/apply');
  await blocked(page, '/cart');
});

test('rider', async ({ page }) => {
  await login(page, 'rider');
  await expect(page.getByRole('link', { name: 'Deliveries' })).toBeVisible();
  await page.goto('/rider');
  await expect(page.getByRole('link', { name: 'Deliveries' })).toBeVisible();
  await blocked(page, '/staff/orders');
  await blocked(page, '/admin/users');
});

test('admin', async ({ page }) => {
  await login(page, 'admin');
  for (const [path, heading] of [['/admin/menu', 'Menu'], ['/admin/delivery', 'Delivery'], ['/staff/reviews', 'Reviews'], ['/admin/users', 'Users & roles'], ['/admin/restaurants', 'Restaurants']]) {
    await page.goto(path);
    await expect(page.getByRole('heading', { name: heading, exact: true })).toBeVisible();
  }
  await blocked(page, '/cart');
});

test('the apply form checks its fields before sending anything', async ({ page }) => {
  await login(page, 'customer');
  await page.goto('/apply');
  await expect(page.getByRole('heading', { name: 'Open a restaurant' })).toBeVisible();
  await page.getByRole('button', { name: 'Send application' }).click(); // empty form: nothing is sent, so no test data is created
  await expect(page.getByText('At least 2 characters')).toBeVisible();
  await expect(page.getByText('Required').first()).toBeVisible();
});
