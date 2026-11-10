-- 005: starter menu (ported from the original MySQL seed; see the legacy-express-mysql branch).
insert into public.categories (category_name, description) values
  ('Rice Dishes', 'Jollof, fried rice and more'),
  ('Soups & Swallow', 'Traditional soups with your choice of swallow'),
  ('Grills & Protein', 'Suya, grilled fish and chicken'),
  ('Drinks', 'Soft drinks, juices and water');

insert into public.food_items (category_id, food_name, description, price)
select c.id, v.food_name, v.description, v.price
from (values
  ('Rice Dishes', 'Jollof Rice & Chicken', 'Smoky party jollof with grilled chicken', 3500.00),
  ('Rice Dishes', 'Fried Rice & Plantain', 'Vegetable fried rice with dodo', 3200.00),
  ('Soups & Swallow', 'Egusi Soup & Pounded Yam', 'Egusi with assorted meat', 4000.00),
  ('Soups & Swallow', 'Pepper Soup (Catfish)', 'Hot and spicy catfish pepper soup', 4500.00),
  ('Grills & Protein', 'Beef Suya', 'Spicy grilled beef with onions and yaji', 2500.00),
  ('Grills & Protein', 'Grilled Tilapia', 'Whole tilapia, pepper sauce', 5500.00),
  ('Drinks', 'Chapman', 'Classic Nigerian Chapman', 1500.00),
  ('Drinks', 'Bottled Water', '75cl', 300.00)
) as v(category_name, food_name, description, price)
join public.categories c on c.category_name = v.category_name;
