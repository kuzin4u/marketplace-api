-- ============================================================
-- СПРИНТ 0 · Задача 0.1 · Seed: Масса Матере
-- Миграция пилота в БД (был: Google Sheets)
-- ============================================================

-- ============ Организатор ============
INSERT INTO participants (id, inn, name, legal_type, role, region, status)
VALUES ('ORG-001', '7700000001', 'Организатор Системы', 'OOO', 'ORGANIZER', 'MSK', 'ACTIVE');

-- ============ Масса Матере (селлер) ============
INSERT INTO participants (id, inn, name, legal_type, role, seller_group, region, status, rating, contact_phone)
VALUES ('PTR-12345', '770712345678', 'Масса Матере', 'IP', 'SELLER', 1, 'MSK', 'ACTIVE', 4.80, '+79001234567');

-- ============ Инфраструктура (тестовые, Волна 0: сам селлер = фулфилмент+логистика) ============
INSERT INTO participants (id, inn, name, legal_type, role, region, status)
VALUES
  ('PTR-67891', '770700001111', '3PL-Сервис (тестовый)', 'OOO', 'FULFILLMENT', 'MSK', 'ACTIVE'),
  ('PTR-88901', '770700002222', 'Курьер-Экспресс (тестовый)', 'OOO', 'LOGISTICS', 'MSK', 'ACTIVE');

-- ============ Тарифы операторов (ст. 3.2) ============
INSERT INTO participant_tariffs (id, participant_id, service_type, unit, rate) VALUES
  ('TRF-001', 'PTR-67891', 'ASSEMBLY',        'PER_ITEM',       200.00),
  ('TRF-002', 'PTR-67891', 'ASSEMBLY_BULK',    'PER_ITEM',       150.00),
  ('TRF-003', 'PTR-67891', 'STORAGE',          'PER_PALLET_DAY',  50.00),
  ('TRF-004', 'PTR-67891', 'RETURN_HANDLING',   'PER_ITEM',       300.00),
  ('TRF-005', 'PTR-88901', 'DELIVERY_ZONE_1',  'PER_ORDER',      350.00),
  ('TRF-006', 'PTR-88901', 'DELIVERY_ZONE_2',  'PER_ORDER',      500.00),
  ('TRF-007', 'PTR-88901', 'DELIVERY_ZONE_3',  'PER_ORDER',      800.00),
  ('TRF-008', 'ORG-001',   'ORGANIZER_FEE',    'PERCENT',          0.20);

-- ============ Привязка: Масса Матере → операторы (ст. 3.3.1) ============
INSERT INTO infra_bindings (id, seller_id, fulfillment_id, logistics_id)
VALUES ('BND-001', 'PTR-12345', 'PTR-67891', 'PTR-88901');

-- ============ Магазин (ст. 9.2) ============
INSERT INTO shops (id, seller_id, slug, brand_name, brand_tagline, brand_accent, brand_description, channels, custom_domain)
VALUES (
  'SHOP-massamadre',
  'PTR-12345',
  'massamadre',
  'Масса Матере',
  'Хлеб на настоящей закваске · SeMaVi',
  '#8B4513',
  'Семейная пекарня. Тартин, ржаной, бородинский — ручная работа, 24-часовая ферментация. Доставка по Москве.',
  '{"telegram":true,"website":true,"vk":true,"max":false,"instagram":true}',
  'massamadre.ru'
);

-- ============ Категории ============
INSERT INTO categories (id, parent_id, name, slug, icon, sort_order) VALUES
  ('CAT-FOOD',   NULL,       'Продукты питания',    'food',        '🍽',  1),
  ('CAT-BREAD',  'CAT-FOOD', 'Хлеб и выпечка',      'bread',       '🍞',  1),
  ('CAT-PASTRY', 'CAT-FOOD', 'Кондитерские изделия', 'pastry',      '🥐',  2),
  ('CAT-DAIRY',  'CAT-FOOD', 'Молочные продукты',    'dairy',       '🥛',  3),
  ('CAT-FARM',   'CAT-FOOD', 'Фермерские продукты',  'farm',        '🌾',  4),
  ('CAT-CRAFT',  NULL,       'Крафт и handmade',     'craft',       '🎨',  2),
  ('CAT-HOME',   NULL,       'Товары для дома',       'home',        '🏠',  3);

-- ============ SKU Масса Матере (ст. 9.4 — SKU-атом) ============
INSERT INTO skus (id, seller_id, shop_id, title, description, category_id, tags, price, stock, unit, weight_g, shipping_zones, visible_shop, visible_catalog, status, moderation_status, moderation_confidence, rating, reviews_count, orders_count) VALUES
  ('SKU-001', 'PTR-12345', 'SHOP-massamadre',
   'Тартин на закваске',
   'Пшеничный хлеб с открытым мякишем, 24ч ферментация. Хрустящая корочка, нежный мякиш. Натуральная закваска, без дрожжей.',
   'CAT-BREAD', '{закваска,крафт,тартин,пшеничный}',
   450.00, 12, 'шт', 800, '{MSK,MSK-OBL}',
   TRUE, TRUE, 'ACTIVE', 'MANUAL_APPROVED', 0.97, 4.90, 34, 156),

  ('SKU-002', 'PTR-12345', 'SHOP-massamadre',
   'Заварной ржаной',
   '100% рожь, заварка на кориандре и тмине. Плотный, ароматный, без дрожжей. Идеален для бутербродов.',
   'CAT-BREAD', '{ржаной,без дрожжей,заварной,кориандр}',
   380.00, 8, 'шт', 700, '{MSK,MSK-OBL}',
   TRUE, TRUE, 'ACTIVE', 'MANUAL_APPROVED', 0.95, 4.70, 28, 98),

  ('SKU-003', 'PTR-12345', 'SHOP-massamadre',
   'Тартин сырный',
   'Тартин с тёртым пармезаном и розмарином. Закваска 24ч + сырная корочка. Ароматный, с насыщенным вкусом.',
   'CAT-BREAD', '{закваска,сыр,пармезан,розмарин}',
   520.00, 6, 'шт', 850, '{MSK,MSK-OBL}',
   TRUE, TRUE, 'ACTIVE', 'MANUAL_APPROVED', 0.96, 4.80, 19, 67),

  ('SKU-004', 'PTR-12345', 'SHOP-massamadre',
   'Бородинский классический',
   'Ржано-пшеничный, кориандр, солод. Рецепт 1933 года на живой закваске. Классика русского хлеба.',
   'CAT-BREAD', '{классический,бородинский,солод,кориандр}',
   350.00, 15, 'шт', 600, '{MSK,MSK-OBL}',
   TRUE, TRUE, 'ACTIVE', 'MANUAL_APPROVED', 0.94, 4.60, 8, 42);

-- ============ Тестовые покупатели (ст. 10) ============
INSERT INTO customers (id, phone, name) VALUES
  ('CUST-001', '+79101111111', 'Анна'),
  ('CUST-002', '+79102222222', 'Дмитрий'),
  ('CUST-003', '+79103333333', 'Мария');

-- Привязка: все мигрировавшие с Масса Матере (ст. 10.2)
INSERT INTO customer_bindings (id, customer_id, seller_id, source_type, orders_count, total_gmv) VALUES
  ('CB-001', 'CUST-001', 'PTR-12345', 'MIGRATED', 12, 8400.00),
  ('CB-002', 'CUST-002', 'PTR-12345', 'MIGRATED',  5, 3200.00),
  ('CB-003', 'CUST-003', 'PTR-12345', 'MIGRATED',  3, 1950.00);

-- ============ Тестовый заказ (ст. 6) ============
INSERT INTO orders (id, customer_id, seller_id, shop_id, entry_point, source_type, total_goods, total_delivery, total_amount, payment_method, status)
VALUES ('ORD-00001', 'CUST-001', 'PTR-12345', 'SHOP-massamadre', 'SHOP', 'MIGRATED', 1420.00, 350.00, 1770.00, 'DIRECT', 'COMPLETED');

INSERT INTO order_items (id, order_id, sku_id, qty, price_at_order, total) VALUES
  ('OI-001', 'ORD-00001', 'SKU-001', 2, 450.00, 900.00),
  ('OI-002', 'ORD-00001', 'SKU-003', 1, 520.00, 520.00);

-- Клиринг тестового заказа (ст. 6.7)
INSERT INTO clearing_splits (id, order_id, participant_id, role, amount, tariff_ref, calculation, status, released_at) VALUES
  ('CLR-001', 'ORD-00001', 'PTR-12345', 'SELLER',      817.16, NULL,      '1420 − 600 − 2.84',   'RELEASED', datetime('now')),
  ('CLR-002', 'ORD-00001', 'PTR-67891', 'FULFILLMENT',  600.00, 'TRF-001', '3 ед × 200₽',         'RELEASED', datetime('now')),
  ('CLR-003', 'ORD-00001', 'PTR-88901', 'LOGISTICS',    350.00, 'TRF-005', 'зона 1 = 350₽',       'RELEASED', datetime('now')),
  ('CLR-004', 'ORD-00001', 'ORG-001',   'ORGANIZER',      2.84, 'TRF-008', '1420 × 0.2%',         'RELEASED', datetime('now'));
