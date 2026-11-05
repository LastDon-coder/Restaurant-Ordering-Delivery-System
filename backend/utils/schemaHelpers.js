const { z } = require('zod');

// Validation pieces shared by the category and food schemas.

// Optional text that can be cleared by sending null or "".
const optionalText = (label, max) =>
  z
    .string({ error: `${label} must be text` })
    .trim()
    .max(max, `${label} must be at most ${max} characters`)
    .transform((value) => (value === '' ? null : value))
    .nullable()
    .optional();

// Only http(s) addresses: stops values like "javascript:..." ending up in an <img src>.
const imageUrl = z
  .string({ error: 'Image URL must be text' })
  .trim()
  .max(500, 'Image URL must be at most 500 characters')
  .refine((value) => {
    if (value === '') return true;
    try {
      const { protocol } = new URL(value);
      return protocol === 'http:' || protocol === 'https:';
    } catch {
      return false;
    }
  }, 'Image URL must be a valid http:// or https:// address')
  .transform((value) => (value === '' ? null : value))
  .nullable()
  .optional();

module.exports = { optionalText, imageUrl };
