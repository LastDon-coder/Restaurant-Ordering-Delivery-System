const AppError = require('../utils/AppError');
const { sendSuccess } = require('../utils/response');
const { ROLES } = require('../utils/constants');
const categoryModel = require('../models/categoryModel');

// Visitors and customers only ever see ACTIVE categories. Only an admin can see inactive ones.
const isAdmin = (user) => Boolean(user) && user.role === ROLES.ADMIN;

// GET /api/v1/categories            -> active categories (public)
// GET /api/v1/categories?status=all -> admin only; also accepts "inactive"
async function list(req, res) {
  const status = req.query.status || 'active';
  if (!['active', 'inactive', 'all'].includes(status)) {
    throw new AppError('status must be active, inactive or all', 400);
  }
  if (status !== 'active') {
    if (!req.user) throw new AppError('Authentication required', 401);
    if (!isAdmin(req.user)) throw new AppError('You do not have permission to view inactive categories', 403);
  }

  const categories = await categoryModel.findAll(status);
  sendSuccess(res, 200, 'Categories retrieved', { categories });
}

// GET /api/v1/categories/:id
// An inactive category looks like it doesn't exist (404) to everyone except an admin.
async function getOne(req, res) {
  const category = await categoryModel.findById(req.params.id);
  if (!category || (category.status !== 'active' && !isAdmin(req.user))) {
    throw new AppError('Category not found', 404);
  }
  sendSuccess(res, 200, 'Category retrieved', { category });
}

// POST /api/v1/categories (admin)
async function create(req, res) {
  let categoryId;
  try {
    categoryId = await categoryModel.create(req.body);
  } catch (err) {
    if (err.code === 'ER_DUP_ENTRY') throw new AppError('A category with this name already exists', 409);
    throw err;
  }
  const category = await categoryModel.findById(categoryId);
  sendSuccess(res, 201, 'Category created', { category });
}

// PUT /api/v1/categories/:id (admin): only the fields sent are changed.
async function update(req, res) {
  const existing = await categoryModel.findById(req.params.id);
  if (!existing) throw new AppError('Category not found', 404);

  try {
    await categoryModel.update(req.params.id, req.body);
  } catch (err) {
    if (err.code === 'ER_DUP_ENTRY') throw new AppError('A category with this name already exists', 409);
    throw err;
  }
  const category = await categoryModel.findById(req.params.id);
  sendSuccess(res, 200, 'Category updated', { category });
}

// DELETE /api/v1/categories/:id (admin)
// A category that still has food can't be deleted (the database refuses). The alternative is
// setting its status to inactive, which hides it from customers without losing anything.
async function remove(req, res) {
  const existing = await categoryModel.findById(req.params.id);
  if (!existing) throw new AppError('Category not found', 404);

  try {
    await categoryModel.remove(req.params.id);
  } catch (err) {
    if (err.code === 'ER_ROW_IS_REFERENCED_2') {
      throw new AppError(
        'This category still has food items. Move or delete them first, or set the category to inactive instead',
        409
      );
    }
    throw err;
  }
  sendSuccess(res, 200, 'Category deleted');
}

module.exports = { list, getOne, create, update, remove };
