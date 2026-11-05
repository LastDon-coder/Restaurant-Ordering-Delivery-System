const AppError = require('../utils/AppError');
const { sendSuccess } = require('../utils/response');
const { ROLES } = require('../utils/constants');
const foodModel = require('../models/foodModel');

// Visitors and customers see only foods that are on sale AND in an active category.
// Only an admin sees everything (sold-out foods, foods in hidden categories).
const isAdmin = (user) => Boolean(user) && user.role === ROLES.ADMIN;

const noSuchCategory = () =>
  new AppError('Validation failed', 400, [{ field: 'category_id', message: 'Category does not exist' }]);

// GET /api/v1/foods?q=rice&category_id=1&sort=price_asc&page=1&limit=20
// ?available=false or ?available=all is admin only.
async function list(req, res) {
  const { category_id, q, available, sort, page, limit } = req.validatedQuery;

  if (available !== 'true') {
    if (!req.user) throw new AppError('Authentication required', 401);
    if (!isAdmin(req.user)) throw new AppError('You do not have permission to view unavailable foods', 403);
  }

  const { foods, total } = await foodModel.search({
    categoryId: category_id,
    q,
    availability: available,
    publicOnly: !isAdmin(req.user),
    sort,
    page,
    limit,
  });

  sendSuccess(res, 200, 'Foods retrieved', {
    foods,
    pagination: { page, limit, total, total_pages: Math.ceil(total / limit) },
  });
}

// GET /api/v1/foods/:id
// A sold-out food, or one in an inactive category, looks like it doesn't exist (404) to non-admins.
async function getOne(req, res) {
  const food = await foodModel.findById(req.params.id);
  if (!food) throw new AppError('Food item not found', 404);

  const onSale = food.is_available && food.category_status === 'active';
  if (!onSale && !isAdmin(req.user)) throw new AppError('Food item not found', 404);

  sendSuccess(res, 200, 'Food item retrieved', { food });
}

// POST /api/v1/foods (admin)
async function create(req, res) {
  let foodId;
  try {
    foodId = await foodModel.create(req.body);
  } catch (err) {
    if (err.code === 'ER_NO_REFERENCED_ROW_2') throw noSuchCategory();
    throw err;
  }
  const food = await foodModel.findById(foodId);
  sendSuccess(res, 201, 'Food item created', { food });
}

// PUT /api/v1/foods/:id (admin): only the fields sent are changed.
// To take something off the menu without deleting it, send { "is_available": false }.
async function update(req, res) {
  const existing = await foodModel.findById(req.params.id);
  if (!existing) throw new AppError('Food item not found', 404);

  try {
    await foodModel.update(req.params.id, req.body);
  } catch (err) {
    if (err.code === 'ER_NO_REFERENCED_ROW_2') throw noSuchCategory();
    throw err;
  }
  const food = await foodModel.findById(req.params.id);
  sendSuccess(res, 200, 'Food item updated', { food });
}

// DELETE /api/v1/foods/:id (admin)
// A food that was ever ordered can't be deleted: past orders must keep showing what was bought.
// Mark it unavailable instead.
async function remove(req, res) {
  const existing = await foodModel.findById(req.params.id);
  if (!existing) throw new AppError('Food item not found', 404);

  try {
    await foodModel.remove(req.params.id);
  } catch (err) {
    if (err.code === 'ER_ROW_IS_REFERENCED_2') {
      throw new AppError(
        'This food item appears in past orders and cannot be deleted. Set is_available to false instead',
        409
      );
    }
    throw err;
  }
  sendSuccess(res, 200, 'Food item deleted');
}

module.exports = { list, getOne, create, update, remove };
