const pool = require('../config/db');

// All SQL for the categories table. Values always go through ? placeholders.
const COLUMNS = 'category_id, category_name, description, image_url, status';

// status: 'active' | 'inactive' | 'all'
async function findAll(status) {
  if (status === 'all') {
    const [rows] = await pool.execute(`SELECT ${COLUMNS} FROM categories ORDER BY category_name`);
    return rows;
  }
  const [rows] = await pool.execute(
    `SELECT ${COLUMNS} FROM categories WHERE status = ? ORDER BY category_name`,
    [status]
  );
  return rows;
}

async function findById(categoryId) {
  const [rows] = await pool.execute(`SELECT ${COLUMNS} FROM categories WHERE category_id = ?`, [categoryId]);
  return rows[0] || null;
}

// A duplicate name throws ER_DUP_ENTRY (UNIQUE key uq_categories_category_name).
async function create({ category_name, description, image_url, status }) {
  const [result] = await pool.execute(
    'INSERT INTO categories (category_name, description, image_url, status) VALUES (?, ?, ?, ?)',
    [category_name, description ?? null, image_url ?? null, status ?? 'active']
  );
  return result.insertId;
}

// Column names come from this fixed list, never from the request, so building the SET clause
// from them is safe. The values still go through placeholders.
const UPDATABLE = ['category_name', 'description', 'image_url', 'status'];

async function update(categoryId, fields) {
  const entries = Object.entries(fields).filter(([key, value]) => UPDATABLE.includes(key) && value !== undefined);
  if (entries.length === 0) return;
  const setClause = entries.map(([key]) => `${key} = ?`).join(', ');
  await pool.execute(`UPDATE categories SET ${setClause} WHERE category_id = ?`, [
    ...entries.map(([, value]) => value),
    categoryId,
  ]);
}

// Throws ER_ROW_IS_REFERENCED_2 if food items still belong to the category (ON DELETE RESTRICT).
async function remove(categoryId) {
  await pool.execute('DELETE FROM categories WHERE category_id = ?', [categoryId]);
}

module.exports = { findAll, findById, create, update, remove };
