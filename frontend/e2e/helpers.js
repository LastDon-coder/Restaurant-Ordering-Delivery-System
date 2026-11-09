import { expect } from '@playwright/test';
import { account } from './env.js';

// Log in through the real login form and wait until the header shows the greeting.
export async function login(page, role) {
  const { email, password } = account(role);
  await page.goto('/login');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Log in' }).click();
  await expect(page.getByText('Hi, E2E')).toBeVisible();
}

// A separate browser window (context) per person, so several roles can be logged in at once.
export async function openAs(browser, role) {
  const context = await browser.newContext();
  const page = await context.newPage();
  if (role) await login(page, role);
  return { context, page };
}

// "Customer pays ₦2,123.00 delivery" -> [2123]. Handles every money amount in a piece of text.
export function amounts(text) {
  return [...String(text).matchAll(/\d[\d,]*\.\d{2}/g)].map((m) => Number(m[0].replace(/,/g, '')));
}
