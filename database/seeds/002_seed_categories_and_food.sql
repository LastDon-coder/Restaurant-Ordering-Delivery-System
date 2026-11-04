-- Sample menu for development. Replace with your real menu later.
INSERT INTO categories (category_id, category_name, description) VALUES
  (1, 'Rice Dishes', 'Jollof, fried rice and more'),
  (2, 'Soups & Swallow', 'Traditional soups with your choice of swallow'),
  (3, 'Grills & Protein', 'Suya, grilled fish and chicken'),
  (4, 'Drinks', 'Soft drinks, juices and water');

INSERT INTO food_items (category_id, food_name, description, price) VALUES
  (1, 'Jollof Rice & Chicken', 'Smoky party jollof with grilled chicken', 3500.00),
  (1, 'Fried Rice & Plantain', 'Vegetable fried rice with dodo', 3200.00),
  (2, 'Egusi Soup & Pounded Yam', 'Egusi with assorted meat', 4000.00),
  (2, 'Pepper Soup (Catfish)', 'Hot and spicy catfish pepper soup', 4500.00),
  (3, 'Beef Suya', 'Spicy grilled beef with onions and yaji', 2500.00),
  (3, 'Grilled Tilapia', 'Whole tilapia, pepper sauce', 5500.00),
  (4, 'Chapman', 'Classic Nigerian Chapman', 1500.00),
  (4, 'Bottled Water', '75cl', 300.00);
