import fs from 'node:fs';

// Reads frontend/.env.e2e (gitignored) into process.env without needing an extra package.
export function loadE2EEnv() {
  let text;
  try { text = fs.readFileSync(new URL('../.env.e2e', import.meta.url), 'utf8'); } catch { return; }
  for (const line of text.split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
    if (!m || line.trim().startsWith('#')) continue;
    if (process.env[m[1]] === undefined) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
}

// The test accounts: E2E_<ROLE>_EMAIL (defaults to e2e-<role>@example.com) and E2E_<ROLE>_PASSWORD (required).
export function account(role) {
  const key = role.toUpperCase();
  const password = process.env[`E2E_${key}_PASSWORD`];
  if (!password) {
    throw new Error(`Missing E2E_${key}_PASSWORD. Copy .env.e2e.example to .env.e2e (in the frontend folder) and fill in the passwords.`);
  }
  return { email: process.env[`E2E_${key}_EMAIL`] || `e2e-${role}@example.com`, password };
}
