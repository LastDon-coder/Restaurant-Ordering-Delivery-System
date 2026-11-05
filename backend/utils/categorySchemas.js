const { z } = require('zod');
const { optionalText, imageUrl } = require('./schemaHelpers');

// Input rules for category requests. Unknown fields (like a client-sent category_id) are dropped.

const categoryName = z
  .string({ error: 'Category name is required' })
  .trim()
  .min(1, 'Category name is required')
  .max(100, 'Category name must be at most 100 characters');

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
