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
  await blocked(page, '/admin/menu');
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
  for (const [path, heading] of [['/admin/menu', 'Menu'], ['/admin/delivery', 'Delivery'], ['/staff/reviews', 'Reviews'], ['/admin/users', 'Users']]) {
    await page.goto(path);
    await expect(page.getByRole('heading', { name: heading, exact: true })).toBeVisible();
  }
  await blocked(page, '/cart');
});
