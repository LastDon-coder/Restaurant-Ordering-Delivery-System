const { z } = require('zod');
const { optionalText, imageUrl } = require('./schemaHelpers');

// Input rules for food requests. Unknown fields (food_id, created_at, ...) are dropped.

const categoryId = z
  .number({ error: 'Category is required' })
  .int('Category id must be a whole number')
  .positive('Category id must be a positive number');

const foodName = z
  .string({ error: 'Food name is required' })
  .trim()
  .min(1, 'Food name is required')
  .max(150, 'Food name must be at most 150 characters');

// Price arrives as a number (3500, 1200.5) or a numeric string ("1200.50") and leaves as an exact
// string with 2 decimals ("1200.50"), which MySQL stores in the DECIMAL column without float rounding.
// Rejects: 0, negatives, more than 2 decimals, "1e3", "abc", anything above 99999999.99.
const price = z
  .union([z.number({ error: 'Price must be a number' }), z.string({ error: 'Price must be a number' })], {
    error: 'Price is required',
  })
  .transform((value, ctx) => {
    const text = typeof value === 'number' ? String(value) : value.trim();
    const amount = Number(text);
    if (!/^\d{1,8}(\.\d{1,2})?$/.test(text) || amount <= 0) {
      ctx.issues.push({
        code: 'custom',
        message: 'Price must be greater than 0, have at most 2 decimal places, and be at most 99999999.99',
        input: value,
      });
      return z.NEVER;
    }
    return amount.toFixed(2);
  });

const isAvailable = z.boolean({ error: 'is_available must be true or false' });

const createFoodSchema = z.object({
  category_id: categoryId,
  food_name: foodName,
  description: optionalText('Description', 1000),
  price,
  image_url: imageUrl,
  is_available: isAvailable.optional(), // left out = true (the database default)
});

// PUT: send only the fields you want to change.
const updateFoodSchema = z
  .object({
    category_id: categoryId.optional(),
    food_name: foodName.optional(),
    description: optionalText('Description', 1000),
    price: price.optional(),
    image_url: imageUrl,
    is_available: isAvailable.optional(),
  })
  .refine((body) => Object.values(body).some((value) => value !== undefined), {
    error: 'Send at least one field to update',
  });

// Query string for GET /foods. Everything is optional; "" counts as "not sent".
const blankToUndefined = (value) => (value === '' ? undefined : value);

const listFoodsQuerySchema = z.object({
  category_id: z.preprocess(blankToUndefined, z.coerce.number().int().positive().optional()),
  q: z.preprocess(blankToUndefined, z.string().trim().min(1).max(100, 'Search text is too long').optional()),
  // true = only foods on sale (the default). false / all are for admins.
  available: z.preprocess(blankToUndefined, z.enum(['true', 'false', 'all']).default('true')),
  sort: z.preprocess(blankToUndefined, z.enum(['name', 'price_asc', 'price_desc', 'newest']).default('name')),
  page: z.preprocess(blankToUndefined, z.coerce.number().int().min(1).max(100000).default(1)),
  limit: z.preprocess(blankToUndefined, z.coerce.number().int().min(1).max(100).default(20)),
});

module.exports = { createFoodSchema, updateFoodSchema, listFoodsQuerySchema };
