const { z } = require('zod');

// Input rules for the auth endpoints. Unknown fields (for example a "role" sent by a hacker
// at sign-up) are silently dropped, so they can never reach the database.

const requiredString = (label) => z.string({ error: `${label} is required` });

const name = (label) =>
  requiredString(label).trim().min(1, `${label} is required`).max(100, `${label} is too long`);

const email = requiredString('Email')
  .trim()
  .toLowerCase()
  .max(255, 'Email is too long')
  .pipe(z.email('Enter a valid email address'));

const phone = requiredString('Phone')
  .trim()
  .regex(/^[0-9+\-\s()]{7,20}$/, 'Enter a valid phone number');

// bcrypt only uses the first 72 BYTES of a password, so longer ones are rejected rather than
// silently cut. (Counting bytes, not characters, because some characters take several bytes.)
const password = requiredString('Password')
  .min(8, 'Password must be at least 8 characters')
  .refine((value) => Buffer.byteLength(value, 'utf8') <= 72, 'Password must be at most 72 bytes');

const registerSchema = z.object({
  first_name: name('First name'),
  last_name: name('Last name'),
  email,
  phone,
  password,
});

// Admin creating a staff or rider account.
const createUserSchema = registerSchema.extend({
  role: z.enum(['staff', 'rider'], { error: 'Role must be staff or rider' }),
});

// Login doesn't re-apply the strength rules; it only needs something to compare.
const loginSchema = z.object({
  email,
  password: requiredString('Password').min(1, 'Password is required').max(128, 'Password is too long'),
});

const forgotPasswordSchema = z.object({ email });

const resetPasswordSchema = z.object({
  token: requiredString('Token').regex(/^[a-f0-9]{64}$/, 'Invalid reset token'),
  password,
});

module.exports = {
  registerSchema,
  createUserSchema,
  loginSchema,
  forgotPasswordSchema,
  resetPasswordSchema,
};
