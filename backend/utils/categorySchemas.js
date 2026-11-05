const { z } = require('zod');

// Input rules for category requests. Unknown fields (like a client-sent category_id) are dropped.

const categoryName = z
  .string({ error: 'Category name is required' })
  .trim()
  .min(1, 'Category name is required')
  .max(100, 'Category name must be at most 100 characters');

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

const status = z.enum(['active', 'inactive'], { error: 'Status must be active or inactive' }).optional();

const createCategorySchema = z.object({
  category_name: categoryName,
  description: optionalText('Description', 255),
  image_url: imageUrl,
  status, // left out = 'active' (the database default)
});

// PUT: send only the fields you want to change.
const updateCategorySchema = z
  .object({
    category_name: categoryName.optional(),
    description: optionalText('Description', 255),
    image_url: imageUrl,
    status,
  })
  .refine((body) => Object.values(body).some((value) => value !== undefined), {
    error: 'Send at least one field to update',
  });

module.exports = { createCategorySchema, updateCategorySchema };
