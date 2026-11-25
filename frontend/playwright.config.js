import { defineConfig } from '@playwright/test';
import { loadE2EEnv } from './e2e/env.js';

loadE2EEnv();

// By default the tests start the app on http://localhost:5173 (using your normal frontend/.env, i.e. the LIVE
// Supabase project). Set E2E_BASE_URL in .env.e2e to test a deployed site instead (e.g. the Vercel address).
// E2E_PORT picks the port the tests start the app on (default 5173), e.g. E2E_PORT=5180.
const port = Number(process.env.E2E_PORT) || 5173;
const baseURL = process.env.E2E_BASE_URL || `http://localhost:${port}`;

export default defineConfig({
  testDir: './e2e',
  timeout: 120_000,
  expect: { timeout: 20_000 },
  fullyParallel: false,
  workers: 1, // the tests share one live database and one order journey, so they run one at a time
  retries: 0,
  reporter: [['list'], ['html', { open: 'never', outputFolder: 'e2e-report' }]],
  outputDir: 'e2e-results',
  use: { baseURL, trace: 'retain-on-failure', screenshot: 'only-on-failure' },
  webServer: process.env.E2E_BASE_URL
    ? undefined
    : { command: `npm run dev -- --port ${port} --strictPort`, url: `http://localhost:${port}`, reuseExistingServer: true, timeout: 60_000 },
});
