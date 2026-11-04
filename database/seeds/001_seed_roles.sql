-- Seed roles. Run once, right after the migrations.
-- IDs are fixed so backend constants can rely on them (1 = admin ... 4 = rider).
INSERT INTO roles (role_id, role_name) VALUES
  (1, 'admin'),
  (2, 'staff'),
  (3, 'customer'),
  (4, 'rider');
