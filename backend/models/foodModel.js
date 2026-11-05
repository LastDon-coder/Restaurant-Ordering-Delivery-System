const pool = require('../config/db');

// All SQL for food_items. Values always go through ? placeholders.
// The category name comes along via a JOIN so the menu can show it without a second request.
const SELECT = `SELECT f.food_id, f.category_id, c.category_name, c.status AS category_status, f.food_name, f.description,
  f.price, f.image_url, f.is_available, f.created_at, f.updated_at
  FROM food_items f JOIN categories c ON c.category_id = f.category_id`;

// price stays a string ("3500.00"): DECIMAL is exact, a JS number is not. is_available becomes a real boolean.
const toFood = (row) => ({ ...row, is_available: Boolean(row.is_available) });

// ORDER BY comes from this fixed list, never from the request. food_id is the tie-breaker so
// pages never repeat or skip an item when two foods share a name or price.
const SORTS = {
  name: 'f.food_name ASC, f.food_id ASC',
  price_asc: 'f.price ASC, f.food_id ASC',
  price_desc: 'f.price DESC, f.food_id ASC',
  newest: 'f.created_at DESC, f.food_id DESC',
};

// Treat % _ and \ in the search text as ordinary characters, not LIKE wildcards.
const escapeLike = (text) => text.replace(/[\\%_]/g, '\\$&');

// availability: 'true' | 'false' | 'all'. publicOnly hides foods whose category is inactive.
async function search({ categoryId, q, availability, publicOnly, sort, page, limit }) {
  const where = [];
  const params = [];
  if (publicOnly) where.push("c.status = 'active'");
  if (availability === 'true') where.push('f.is_available = 1');
  if (availability === 'false') where.push('f.is_available = 0');
  if (categoryId) {
    where.push('f.category_id = ?');
    params.push(categoryId);
  }
  if (q) {
    where.push('(f.food_name LIKE ? OR f.description LIKE ?)');
    const pattern = `%${escapeLike(q)}%`;
    params.push(pattern, pattern);
  }
  const whereSql = where.length > 0 ? `WHERE ${where.join(' AND ')}` : '';

  const [[{ total }]] = await pool.execute(
    `SELECT COUNT(*) AS total FROM food_items f JOIN categories c ON c.category_id = f.category_id ${whereSql}`,
    params
  );
  // query() rather than execute() here: LIMIT/OFFSET placeholders are fussy in prepared statements.
  // page and limit were already validated as whole numbers, and the driver escapes them.
  const [rows] = await pool.query(`${SELECT} ${whereSql} ORDER BY ${SORTS[sort]} LIMIT ? OFFSET ?`, [
    ...params,
    limit,
    (page - 1) * limit,
  ]);
  return { foods: rows.map(toFood), total };
}

async function findById(foodId) {
  const [rows] = await pool.execute(`${SELECT} WHERE f.food_id = ?`, [foodId]);
  return rows[0] ? toFood(rows[0]) : null;
}

// A category_id that doesn't exist throws ER_NO_REFERENCED_ROW_2 (the foreign key decides).
async function create({ category_id, food_name, description, price, image_url, is_available }) {
  const [result] = await pool.execute(
    `INSERT INTO food_items (category_id, food_name, description, price, image_url, is_available)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [category_id, food_name, description ?? null, price, image_url ?? null, is_available === false ? 0 : 1]
  );
  return result.insertId;
}

// Column names come from this fixed list, never from the request.
const UPDATABLE = ['category_id', 'food_name', 'description', 'price', 'image_url', 'is_available'];

async function update(foodId, fields) {
  const entries = Object.entries(fields)
    .filter(([key, value]) => UPDATABLE.includes(key) && value !== undefined)
    .map(([key, value]) => [key, key === 'is_available' ? (value ? 1 : 0) : value]);
  if (entries.length === 0) return;
  const setClause = entries.map(([key]) => `${key} = ?`).join(', ');
  await pool.execute(`UPDATE food_items SET ${setClause} WHERE food_id = ?`, [
    ...entries.map(([, value]) => value),
    foodId,
  ]);
}

// Throws ER_ROW_IS_REFERENCED_2 if the food appears in any past order (order_items uses ON DELETE RESTRICT).
// Cart rows for this food are removed automatically (cart_items uses ON DELETE CASCADE).
async function remove(foodId) {
  await pool.execute('DELETE FROM food_items WHERE food_id = ?', [foodId]);
}

module.exports = { search, findById, create, update, remove };
