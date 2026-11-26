import { expect, test } from '@playwright/test';

// No login needed. Safe checks of the public site.

test('the restaurant list loads and opens a menu', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Order from a restaurant' })).toBeVisible();
  await page.locator('a.restaurant-card').first().click();
  await expect(page).toHaveURL(/\/r\//);
  await expect(page.locator('article').first()).toBeVisible();
});

test('searching restaurants with no match shows an empty state', async ({ page }) => {
  await page.goto('/');
  await page.getByPlaceholder('Search restaurants by name').fill('zzzz-no-such-place');
  await expect(page.getByText('No restaurant matches your search')).toBeVisible();
});

test('an unknown restaurant shows not found', async ({ page }) => {
  await page.goto('/r/does-not-exist');
  await expect(page.getByText('Restaurant not found')).toBeVisible();
});

test('logged-out visitors are sent to the login page', async ({ page }) => {
  await page.goto('/cart');
  await expect(page).toHaveURL(/\/login/);
  await expect(page.getByRole('heading', { name: 'Log in' })).toBeVisible();
});

test('a wrong password shows a friendly message', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Email').fill('nobody-e2e@example.com');
  await page.getByLabel('Password').fill('definitely-wrong-password');
  await page.getByRole('button', { name: 'Log in' }).click();
  await expect(page.getByRole('alert')).toContainText('Incorrect email or password');
});

test('forgot-password rejects an invalid email without sending anything', async ({ page }) => {
  await page.goto('/login');
  await page.getByRole('link', { name: 'Forgot your password?' }).click();
  await expect(page).toHaveURL(/\/forgot-password/);
  await page.getByLabel('Email').fill('not-an-email');
  await page.getByRole('button', { name: 'Send reset link' }).click();
  await expect(page.getByRole('alert')).toContainText('valid email');
});

test('an expired reset link says so and offers a new one', async ({ page }) => {
  await page.goto('/reset-password');
  await expect(page.getByRole('heading', { name: 'Reset link expired' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Request a new reset link' })).toBeVisible();
});
