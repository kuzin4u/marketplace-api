// ============================================================
// СПРИНТ 0 · Задача 0.2 · REST API
// Marketplace API поверх PostgreSQL
// ============================================================
// Замена Google Sheets webhook на нормальный API
// massamadre.ru будет читать из этого сервера
// ============================================================

const express = require('express');
const { Pool } = require('pg');
const crypto = require('crypto');
const cors = require('cors');

const app = express();
app.use(cors());
app.use(express.json());

// ============ DATABASE ============

const pool = new Pool({
  connectionString: process.env.DATABASE_URL || 'postgresql://localhost:5432/marketplace',
  ssl: process.env.DATABASE_URL ? { rejectUnauthorized: false } : false
});

// Helper: query with error handling
async function db(sql, params = []) {
  const client = await pool.connect();
  try {
    const result = await client.query(sql, params);
    return result.rows;
  } finally {
    client.release();
  }
}

async function dbOne(sql, params = []) {
  const rows = await db(sql, params);
  return rows[0] || null;
}

// Helper: generate ID
function genId(prefix) {
  return `${prefix}-${crypto.randomBytes(4).toString('hex')}`;
}
const { requireSeller } = require('./auth-seller')(app, { db, dbOne, genId });
require('./channels-api')(app, { db, dbOne, requireSeller });
require('./customers-api')(app, { db, dbOne, genId });   // ← новая строка
// ============================================================
// PUBLIC API (покупатель, без auth для browsing)
// ============================================================

// ──── Магазин по slug (ст. 9.2) ────

app.get('/api/v1/shop/:slug', async (req, res) => {
  try {
    const shop = await dbOne(`
      SELECT s.*, p.name as seller_name, p.rating as seller_rating,
             p.seller_group, p.joined_at as seller_joined
      FROM shops s
      JOIN participants p ON s.seller_id = p.id
      WHERE s.slug = $1 AND s.status = 'ACTIVE'
    `, [req.params.slug]);

    if (!shop) return res.status(404).json({ error: 'Shop not found' });

    // Count SKUs and stats
    const stats = await dbOne(`
      SELECT COUNT(*) as sku_count,
             COALESCE(SUM(orders_count), 0) as total_orders,
             COALESCE(AVG(rating) FILTER (WHERE reviews_count > 0), 0) as avg_rating,
             COALESCE(SUM(reviews_count), 0) as total_reviews
      FROM skus WHERE shop_id = $1 AND status = 'ACTIVE'
    `, [shop.id]);

    res.json({
      ...shop,
      stats: {
        sku_count: parseInt(stats.sku_count),
        total_orders: parseInt(stats.total_orders),
        avg_rating: parseFloat(stats.avg_rating).toFixed(1),
        total_reviews: parseInt(stats.total_reviews)
      }
    });
  } catch (err) {
    console.error('GET /shop/:slug', err);
    res.status(500).json({ error: 'Internal error' });
  }
});

// ──── Товары магазина (ст. 9.2) ────

app.get('/api/v1/shop/:slug/products', async (req, res) => {
  try {
    const { cat, sort, page = 1, limit = 20 } = req.query;
    const offset = (parseInt(page) - 1) * parseInt(limit);

    let where = `sh.slug = $1 AND sk.visible_shop = TRUE AND sk.status = 'ACTIVE'`;
    const params = [req.params.slug];
    let paramIdx = 2;

    if (cat) {
      where += ` AND sk.category_id = $${paramIdx}`;
      params.push(cat);
      paramIdx++;
    }

    let orderBy = 'sk.orders_count DESC'; // default: популярное
    if (sort === 'cheap') orderBy = 'sk.price ASC';
    else if (sort === 'expensive') orderBy = 'sk.price DESC';
    else if (sort === 'rating') orderBy = 'sk.rating DESC';
    else if (sort === 'new') orderBy = 'sk.created_at DESC';

    const rows = await db(`
      SELECT sk.*, c.name as category_name, c.slug as category_slug
      FROM skus sk
      JOIN shops sh ON sk.shop_id = sh.id
      LEFT JOIN categories c ON sk.category_id = c.id
      WHERE ${where}
      ORDER BY ${orderBy}
      LIMIT $${paramIdx} OFFSET $${paramIdx + 1}
    `, [...params, parseInt(limit), offset]);

    const total = await dbOne(`
      SELECT COUNT(*) as cnt FROM skus sk
      JOIN shops sh ON sk.shop_id = sh.id
      WHERE ${where}
    `, params);

    res.json({
      products: rows,
      total: parseInt(total.cnt),
      page: parseInt(page),
      pages: Math.ceil(parseInt(total.cnt) / parseInt(limit))
    });
  } catch (err) {
    console.error('GET /shop/:slug/products', err);
    res.status(500).json({ error: 'Internal error' });
  }
});

// ──── Карточка SKU (ст. 9.4 — source of truth = PostgreSQL) ────

app.get('/api/v1/sku/:id', async (req, res) => {
  try {
    const sku = await dbOne(`
      SELECT sk.*, 
             sh.slug as shop_slug, sh.brand_name, sh.brand_accent, sh.brand_logo_url,
             c.name as category_name,
             p.seller_group, p.joined_at as seller_joined
      FROM skus sk
      JOIN shops sh ON sk.shop_id = sh.id
      JOIN participants p ON sk.seller_id = p.id
      LEFT JOIN categories c ON sk.category_id = c.id
      WHERE sk.id = $1
    `, [req.params.id]);

    if (!sku) return res.status(404).json({ error: 'SKU not found' });

    // Available stock
    sku.available = sku.stock - sku.stock_reserved;

    res.json(sku);
  } catch (err) {
    console.error('GET /sku/:id', err);
    res.status(500).json({ error: 'Internal error' });
  }
});

// ──── Каталог Системы: поиск (ст. 9.3 + ст. 11 маршрутизация) ────

app.get('/api/v1/catalog/search', async (req, res) => {
  try {
    const { q, cat, price_min, price_max, rating_min, zone, sort, page = 1, limit = 20 } = req.query;
    const offset = (parseInt(page) - 1) * parseInt(limit);

    let where = `sk.visible_catalog = TRUE AND sk.status = 'ACTIVE' AND sk.stock > 0`;
    const params = [];
    let paramIdx = 1;

    // Full-text search (PostgreSQL tsvector)
    if (q) {
      where += ` AND to_tsvector('russian', sk.title || ' ' || COALESCE(sk.description,'')) @@ plainto_tsquery('russian', $${paramIdx})`;
      params.push(q);
      paramIdx++;
    }

    if (cat) {
      where += ` AND sk.category_id = $${paramIdx}`;
      params.push(cat);
      paramIdx++;
    }

    if (price_min) {
      where += ` AND sk.price >= $${paramIdx}`;
      params.push(parseFloat(price_min));
      paramIdx++;
    }

    if (price_max) {
      where += ` AND sk.price <= $${paramIdx}`;
      params.push(parseFloat(price_max));
      paramIdx++;
    }

    if (rating_min) {
      where += ` AND sk.rating >= $${paramIdx}`;
      params.push(parseFloat(rating_min));
      paramIdx++;
    }

    // Ранжирование (ст. 11.3) — формула:
    // score = text_relevance × quality × commercial × policy_boost
    // policy_boost: гр.2 первые 90 дней = 1.3, гр.3 первые 30 дней = 1.1
    let orderBy;
    if (sort === 'cheap') {
      orderBy = 'sk.price ASC';
    } else if (sort === 'expensive') {
      orderBy = 'sk.price DESC';
    } else if (sort === 'rating') {
      orderBy = 'sk.rating DESC';
    } else if (sort === 'new') {
      orderBy = 'sk.created_at DESC';
    } else {
      // Default: ранжирование по формуле (ст. 11.3)
      orderBy = `(
        (1 + 0.15 * ln(1 + sk.rating)) *
        (1 + 0.08 * ln(1 + sk.reviews_count)) *
        (1 + 0.10 * ln(1 + sk.orders_count)) *
        CASE
          WHEN p.seller_group = 2 AND p.joined_at > NOW() - INTERVAL '90 days' THEN 1.3
          WHEN p.seller_group = 3 AND p.joined_at > NOW() - INTERVAL '30 days' THEN 1.1
          ELSE 1.0
        END
      ) DESC`;
    }

    const rows = await db(`
      SELECT sk.*,
             sh.slug as shop_slug, sh.brand_name, sh.brand_accent, sh.brand_logo_url,
             c.name as category_name,
             p.seller_group, p.joined_at as seller_joined,
             CASE
               WHEN p.seller_group = 2 AND p.joined_at > NOW() - INTERVAL '90 days' THEN TRUE
               WHEN p.seller_group = 3 AND p.joined_at > NOW() - INTERVAL '30 days' THEN TRUE
               ELSE FALSE
             END as has_boost
      FROM skus sk
      JOIN shops sh ON sk.shop_id = sh.id
      JOIN participants p ON sk.seller_id = p.id
      LEFT JOIN categories c ON sk.category_id = c.id
      WHERE ${where}
      ORDER BY ${orderBy}
      LIMIT $${paramIdx} OFFSET $${paramIdx + 1}
    `, [...params, parseInt(limit), offset]);

    const total = await dbOne(`
      SELECT COUNT(*) as cnt FROM skus sk
      JOIN participants p ON sk.seller_id = p.id
      WHERE ${where}
    `, params);

    res.json({
      products: rows,
      total: parseInt(total.cnt),
      page: parseInt(page),
      pages: Math.ceil(parseInt(total.cnt) / parseInt(limit)),
      source_type: 'NETWORK'  // каталог = сетевой приток (ст. 10.4)
    });
  } catch (err) {
    console.error('GET /catalog/search', err);
    res.status(500).json({ error: 'Internal error' });
  }
});

// ──── Каталог магазинов (ст. 11.4) ────

app.get('/api/v1/catalog/shops', async (req, res) => {
  try {
    const { q, cat, sort, page = 1, limit = 20 } = req.query;
    const offset = (parseInt(page) - 1) * parseInt(limit);

    let where = `sh.status = 'ACTIVE'`;
    const params = [];
    let paramIdx = 1;

    if (q) {
      where += ` AND (sh.brand_name ILIKE $${paramIdx} OR sh.brand_description ILIKE $${paramIdx})`;
      params.push(`%${q}%`);
      paramIdx++;
    }

    const rows = await db(`
      SELECT sh.*,
             p.seller_group, p.rating as seller_rating, p.joined_at as seller_joined,
             COUNT(sk.id) as sku_count,
             COALESCE(SUM(sk.orders_count), 0) as total_orders,
             COALESCE(SUM(sk.reviews_count), 0) as total_reviews,
             CASE
               WHEN p.seller_group = 2 AND p.joined_at > NOW() - INTERVAL '90 days' THEN TRUE
               ELSE FALSE
             END as has_boost
      FROM shops sh
      JOIN participants p ON sh.seller_id = p.id
      LEFT JOIN skus sk ON sk.shop_id = sh.id AND sk.status = 'ACTIVE'
      WHERE ${where}
      GROUP BY sh.id, p.id
      ORDER BY (
        (1 + 0.20 * ln(1 + p.rating * COALESCE(SUM(sk.reviews_count), 1))) *
        CASE WHEN p.seller_group = 2 AND p.joined_at > NOW() - INTERVAL '90 days' THEN 1.25 ELSE 1.0 END
      ) DESC
      LIMIT $${paramIdx} OFFSET $${paramIdx + 1}
    `, [...params, parseInt(limit), offset]);

    res.json({ shops: rows, page: parseInt(page) });
  } catch (err) {
    console.error('GET /catalog/shops', err);
    res.status(500).json({ error: 'Internal error' });
  }
});

// ──── Категории ────

app.get('/api/v1/catalog/categories', async (req, res) => {
  try {
    const rows = await db(`
      SELECT c.*,
             COUNT(sk.id) FILTER (WHERE sk.status = 'ACTIVE' AND sk.visible_catalog = TRUE) as sku_count
      FROM categories c
      LEFT JOIN skus sk ON sk.category_id = c.id
      WHERE c.is_active = TRUE
      GROUP BY c.id
      ORDER BY c.sort_order
    `);
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: 'Internal error' });
  }
});

// ============================================================
// CART + ORDERS (auth required in production, simplified here)
// ============================================================

// ──── Добавить в корзину (единый сток, ст. 9.4) ────

app.post('/api/v1/cart/add', async (req, res) => {
  const client = await pool.connect();
  try {
    const { sku_id, qty = 1, entry_point = 'SHOP' } = req.body;

    await client.query('BEGIN');

    // Atomic stock reservation: SELECT FOR UPDATE (ст. 9.4 единый сток)
    const sku = (await client.query(
      'SELECT stock, stock_reserved, price, seller_id, shop_id FROM skus WHERE id = $1 FOR UPDATE',
      [sku_id]
    )).rows[0];

    if (!sku) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'SKU not found' });
    }

    const available = sku.stock - sku.stock_reserved;
    if (available < qty) {
      await client.query('ROLLBACK');
      return res.status(409).json({ error: 'NOT_ENOUGH_STOCK', available });
    }

    // Reserve stock
    await client.query(
      'UPDATE skus SET stock_reserved = stock_reserved + $1 WHERE id = $2',
      [qty, sku_id]
    );

    await client.query('COMMIT');

    res.json({
      sku_id,
      qty,
      price: sku.price,
      entry_point,
      source_type: entry_point === 'CATALOG' ? 'NETWORK' : 'MIGRATED',
      reserved: true
    });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('POST /cart/add', err);
    res.status(500).json({ error: 'Internal error' });
  } finally {
    client.release();
  }
});

// ──── Создать заказ (ст. 6.6 анатомия заказа) ────

app.post('/api/v1/orders', async (req, res) => {
  const client = await pool.connect();
  try {
    const { customer_id, items, entry_point = 'SHOP', shipping_address } = req.body;
    // items: [{sku_id, qty}]

    await client.query('BEGIN');

    // Determine source_type (ст. 10.4)
    const source_type = (entry_point === 'CATALOG' || entry_point === 'REFERRAL_SYSTEM')
      ? 'NETWORK' : 'MIGRATED';

    // Validate items and calculate totals
    let total_goods = 0;
    const orderItems = [];

    for (const item of items) {
      const sku = (await client.query(
        'SELECT id, price, seller_id, shop_id FROM skus WHERE id = $1 AND status = $2',
        [item.sku_id, 'ACTIVE']
      )).rows[0];

      if (!sku) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: `SKU ${item.sku_id} not found or inactive` });
      }

      const itemTotal = parseFloat(sku.price) * item.qty;
      total_goods += itemTotal;

      orderItems.push({
        sku_id: sku.id,
        qty: item.qty,
        price: sku.price,
        total: itemTotal,
        seller_id: sku.seller_id,
        shop_id: sku.shop_id
      });
    }

    // All items must be from same seller (shop order) or multiple (catalog)
    const seller_id = orderItems[0].seller_id;
    const shop_id = orderItems[0].shop_id;

    // Get delivery tariff from binding (ст. 3.3.1)
    const binding = (await client.query(
      'SELECT logistics_id, fulfillment_id FROM infra_bindings WHERE seller_id = $1 AND active = TRUE',
      [seller_id]
    )).rows[0];

    let total_delivery = 0;
    if (binding && binding.logistics_id) {
      const tariff = (await client.query(
        `SELECT rate FROM participant_tariffs 
         WHERE participant_id = $1 AND service_type = 'DELIVERY_ZONE_1'
         AND (valid_to IS NULL OR valid_to >= CURRENT_DATE)
         ORDER BY valid_from DESC LIMIT 1`,
        [binding.logistics_id]
      )).rows[0];
      if (tariff) total_delivery = parseFloat(tariff.rate);
    }

    const total_amount = total_goods + total_delivery;

    // Create order
    const order_id = genId('ORD');
    await client.query(`
      INSERT INTO orders (id, customer_id, seller_id, shop_id, entry_point, source_type,
                         total_goods, total_delivery, total_amount, shipping_address, status)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'PENDING')
    `, [order_id, customer_id, seller_id, shop_id, entry_point, source_type,
        total_goods, total_delivery, total_amount,
        shipping_address ? JSON.stringify(shipping_address) : null]);

    // Create order items
    for (const item of orderItems) {
      await client.query(`
        INSERT INTO order_items (id, order_id, sku_id, qty, price_at_order, total)
        VALUES ($1, $2, $3, $4, $5, $6)
      `, [genId('OI'), order_id, item.sku_id, item.qty, item.price, item.total]);

      // Deduct stock (from reserved)
      await client.query(
        'UPDATE skus SET stock = stock - $1, stock_reserved = stock_reserved - $1 WHERE id = $2',
        [item.qty, item.sku_id]
      );

      // Increment orders_count
      await client.query(
        'UPDATE skus SET orders_count = orders_count + 1 WHERE id = $1',
        [item.sku_id]
      );
    }

    // Update or create customer binding (ст. 10.5 — фиксация)
    await client.query(`
      INSERT INTO customer_bindings (id, customer_id, seller_id, source_type, orders_count, total_gmv)
      VALUES ($1, $2, $3, $4, 1, $5)
      ON CONFLICT (customer_id, seller_id) DO UPDATE
      SET orders_count = customer_bindings.orders_count + 1,
          total_gmv = customer_bindings.total_gmv + $5
    `, [genId('CB'), customer_id, seller_id, source_type, total_goods]);

    // Pre-calculate clearing splits (ст. 6.7 — flow денег)
    const splits = await calculateClearing(client, order_id, seller_id, total_goods, orderItems, binding);

    // Audit log
    await client.query(`
      INSERT INTO audit_log (entity_type, entity_id, action, actor_id, new_value)
      VALUES ('ORDER', $1, 'CREATED', $2, $3)
    `, [order_id, customer_id, JSON.stringify({ total_amount, source_type, items: items.length })]);

    await client.query('COMMIT');

    res.status(201).json({
      order_id,
      total_goods,
      total_delivery,
      total_amount,
      source_type,
      entry_point,
      items: orderItems.length,
      clearing: splits,
      status: 'PENDING'
    });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('POST /orders', err);
    res.status(500).json({ error: 'Internal error' });
  } finally {
    client.release();
  }
});

// ──── Расчёт клиринга (ст. 6.7 + ст. 3.5: объём × тариф = сумма) ────

async function calculateClearing(client, order_id, seller_id, total_goods, items, binding) {
  const splits = [];
  let total_ops = 0;

  // 1. Fulfillment: тариф × количество единиц
  if (binding && binding.fulfillment_id) {
    const tariff = (await client.query(
      `SELECT id, rate FROM participant_tariffs 
       WHERE participant_id = $1 AND service_type = 'ASSEMBLY'
       AND (valid_to IS NULL OR valid_to >= CURRENT_DATE)
       ORDER BY valid_from DESC LIMIT 1`,
      [binding.fulfillment_id]
    )).rows[0];

    if (tariff) {
      const totalQty = items.reduce((s, i) => s + i.qty, 0);
      const amount = parseFloat(tariff.rate) * totalQty;
      total_ops += amount;

      const split_id = genId('CLR');
      await client.query(`
        INSERT INTO clearing_splits (id, order_id, participant_id, role, amount, tariff_ref, calculation, status)
        VALUES ($1, $2, $3, 'FULFILLMENT', $4, $5, $6, 'PENDING')
      `, [split_id, order_id, binding.fulfillment_id, amount, tariff.id,
          `${totalQty} ед × ${tariff.rate}₽`]);

      splits.push({ role: 'FULFILLMENT', participant: binding.fulfillment_id, amount });
    }
  }

  // 2. Logistics: тариф зоны (уже включён в total_delivery, получен из order)
  if (binding && binding.logistics_id) {
    const tariff = (await client.query(
      `SELECT id, rate FROM participant_tariffs 
       WHERE participant_id = $1 AND service_type = 'DELIVERY_ZONE_1'
       AND (valid_to IS NULL OR valid_to >= CURRENT_DATE)
       ORDER BY valid_from DESC LIMIT 1`,
      [binding.logistics_id]
    )).rows[0];

    if (tariff) {
      const amount = parseFloat(tariff.rate);
      // Logistics paid from delivery fee, not from goods

      const split_id = genId('CLR');
      await client.query(`
        INSERT INTO clearing_splits (id, order_id, participant_id, role, amount, tariff_ref, calculation, status)
        VALUES ($1, $2, $3, 'LOGISTICS', $4, $5, $6, 'PENDING')
      `, [split_id, order_id, binding.logistics_id, amount, tariff.id,
          `зона 1 = ${tariff.rate}₽`]);

      splits.push({ role: 'LOGISTICS', participant: binding.logistics_id, amount });
    }
  }

  // 3. Organizer: 0.2% от суммы товаров (ст. 6.3)
  const orgTariff = (await client.query(
    `SELECT id, rate FROM participant_tariffs 
     WHERE service_type = 'ORGANIZER_FEE'
     AND (valid_to IS NULL OR valid_to >= CURRENT_DATE)
     ORDER BY valid_from DESC LIMIT 1`
  )).rows[0];

  if (orgTariff) {
    const amount = parseFloat((total_goods * parseFloat(orgTariff.rate) / 100).toFixed(2));
    total_ops += amount;

    const split_id = genId('CLR');
    await client.query(`
      INSERT INTO clearing_splits (id, order_id, participant_id, role, amount, tariff_ref, calculation, status)
      VALUES ($1, $2, 'ORG-001', 'ORGANIZER', $3, $4, $5, 'PENDING')
    `, [split_id, order_id, amount, orgTariff.id,
        `${total_goods}₽ × ${orgTariff.rate}%`]);

    splits.push({ role: 'ORGANIZER', participant: 'ORG-001', amount });
  }

  // 4. Seller: остаток (ст. 7 — 100% выручки минус операторы)
  const sellerAmount = parseFloat((total_goods - total_ops).toFixed(2));
  const split_id = genId('CLR');
  await client.query(`
    INSERT INTO clearing_splits (id, order_id, participant_id, role, amount, calculation, status)
    VALUES ($1, $2, $3, 'SELLER', $4, $5, 'PENDING')
  `, [split_id, order_id, seller_id, sellerAmount,
      `${total_goods}₽ − ${total_ops.toFixed(2)}₽ (операторы)`]);

  splits.push({ role: 'SELLER', participant: seller_id, amount: sellerAmount });

  return splits;
}

// ──── Получить заказ ────

app.get('/api/v1/orders/:id', async (req, res) => {
  try {
    const order = await dbOne('SELECT * FROM orders WHERE id = $1', [req.params.id]);
    if (!order) return res.status(404).json({ error: 'Order not found' });

    const items = await db('SELECT oi.*, sk.title FROM order_items oi JOIN skus sk ON oi.sku_id = sk.id WHERE oi.order_id = $1', [req.params.id]);
    const splits = await db(`
      SELECT cs.*, p.name as participant_name 
      FROM clearing_splits cs JOIN participants p ON cs.participant_id = p.id 
      WHERE cs.order_id = $1 ORDER BY cs.amount DESC
    `, [req.params.id]);

    res.json({ ...order, items, clearing: splits });
  } catch (err) {
    res.status(500).json({ error: 'Internal error' });
  }
});

// ============================================================
// SELLER API (auth: seller role — simplified, no JWT yet)
// ============================================================

// ──── CRUD товаров (ст. 9.4) ────

app.get('/api/v1/seller/:seller_id/products', async (req, res) => {
  try {
    const rows = await db(
      'SELECT * FROM skus WHERE seller_id = $1 ORDER BY created_at DESC',
      [req.params.seller_id]
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: 'Internal error' });
  }
});

app.post('/api/v1/seller/:seller_id/products', async (req, res) => {
  try {
    const { title, description, price, stock, category_id, tags, images,
            weight_g, shipping_zones, visible_catalog = true } = req.body;
    const seller_id = req.params.seller_id;

    // Get shop for this seller
    const shop = await dbOne('SELECT id FROM shops WHERE seller_id = $1', [seller_id]);
    if (!shop) return res.status(400).json({ error: 'No shop for this seller' });

    const sku_id = genId('SKU');

    await db(`
      INSERT INTO skus (id, seller_id, shop_id, title, description, price, stock,
                       category_id, tags, images, weight_g, shipping_zones,
                       visible_shop, visible_catalog, status, moderation_status)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, TRUE, $13, 'ACTIVE', 'PENDING')
    `, [sku_id, seller_id, shop.id, title, description, price, stock || 0,
        category_id, tags || [], images || [], weight_g,
        shipping_zones || ['MSK'], visible_catalog]);

    res.status(201).json({ id: sku_id, status: 'ACTIVE' });
  } catch (err) {
    console.error('POST /seller/products', err);
    res.status(500).json({ error: 'Internal error' });
  }
});

app.patch('/api/v1/seller/:seller_id/products/:sku_id', async (req, res) => {
  try {
    const { price, stock, title, description, visible_catalog } = req.body;
    const updates = [];
    const params = [];
    let idx = 1;

    if (price !== undefined) { updates.push(`price = $${idx}`); params.push(price); idx++; }
    if (stock !== undefined) { updates.push(`stock = $${idx}`); params.push(stock); idx++; }
    if (title !== undefined) { updates.push(`title = $${idx}`); params.push(title); idx++; }
    if (description !== undefined) { updates.push(`description = $${idx}`); params.push(description); idx++; }
    if (visible_catalog !== undefined) { updates.push(`visible_catalog = $${idx}`); params.push(visible_catalog); idx++; }

    if (updates.length === 0) return res.status(400).json({ error: 'No fields to update' });

    // Verify ownership
    params.push(req.params.sku_id);
    params.push(req.params.seller_id);

    await db(`UPDATE skus SET ${updates.join(', ')} WHERE id = $${idx} AND seller_id = $${idx + 1}`, params);

    res.json({ updated: true });
  } catch (err) {
    res.status(500).json({ error: 'Internal error' });
  }
});

// ──── Статистика селлера ────

app.get('/api/v1/seller/:seller_id/stats', async (req, res) => {
  try {
    const seller_id = req.params.seller_id;

    const products = await dbOne('SELECT COUNT(*) as cnt FROM skus WHERE seller_id = $1 AND status = $2', [seller_id, 'ACTIVE']);
    const orders = await dbOne(`SELECT COUNT(*) as cnt, COALESCE(SUM(total_goods),0) as gmv FROM orders WHERE seller_id = $1`, [seller_id]);
    const customers = await dbOne(`
      SELECT COUNT(*) as total,
             COUNT(*) FILTER (WHERE source_type = 'MIGRATED') as migrated,
             COUNT(*) FILTER (WHERE source_type = 'NETWORK') as network
      FROM customer_bindings WHERE seller_id = $1
    `, [seller_id]);

    res.json({
      active_skus: parseInt(products.cnt),
      total_orders: parseInt(orders.cnt),
      total_gmv: parseFloat(orders.gmv),
      customers: {
        total: parseInt(customers.total),
        migrated: parseInt(customers.migrated),
        network: parseInt(customers.network)
      }
    });
  } catch (err) {
    res.status(500).json({ error: 'Internal error' });
  }
});

// ============================================================
// SHOP + PARTICIPANT CREATION (Спринт 1-2 endpoints)
// ============================================================

// ──── Создать участника (форма /join, задача 2.1) ────

app.post('/api/v1/participants', async (req, res) => {
  try {
    const { inn, name, legal_type, role = 'SELLER', seller_group, region = 'MSK', contact_phone } = req.body;
    if (!inn || !name) return res.status(400).json({ error: 'inn and name required' });

    const id = genId('PTR');
    await db(`
      INSERT INTO participants (id, inn, name, legal_type, role, seller_group, region, status, contact_phone)
      VALUES ($1, $2, $3, $4, $5, $6, $7, 'ACTIVE', $8)
    `, [id, inn, name, legal_type || 'IP', role, seller_group, region, contact_phone]);

    console.log(`[Participant] Created ${id}: ${name} (${role}, group ${seller_group})`);
    res.status(201).json({ id, name, role, seller_group, status: 'ACTIVE' });
  } catch (err) {
    console.error('POST /participants', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ──── Создать магазин (wizard, задача 1.1) ────

app.post('/api/v1/shops', requireSeller, async (req, res) => {
  try {
    const seller_id = req.seller_id;   // из токена (requireSeller), НЕ из тела
    const { slug, brand_name, brand_tagline, brand_accent,
            brand_description, channels, category, region } = req.body;

    if (!slug || !brand_name) {
      return res.status(400).json({ error: 'slug, brand_name required' });
    }

    // Check seller exists
    const seller = await dbOne('SELECT id, name FROM participants WHERE id = $1', [seller_id]);
    if (!seller) return res.status(400).json({ error: 'Seller not found' });

    // Check slug unique
    const existing = await dbOne('SELECT id FROM shops WHERE slug = $1', [slug]);
    if (existing) return res.status(409).json({ error: 'Slug already taken' });

    const shop_id = 'SHOP-' + slug;
    await db(`
      INSERT INTO shops (id, seller_id, slug, brand_name, brand_tagline, brand_accent,
                        brand_description, channels, status)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'ACTIVE')
    `, [shop_id, seller_id, slug, brand_name, brand_tagline || '',
        brand_accent || '#1e40af', brand_description || '',
        JSON.stringify(channels || {telegram:true, website:true, vk:false, max:false, instagram:false})]);

    // Auto-assign default binding if operators exist
    const fulfillment = await dbOne("SELECT id FROM participants WHERE role = 'FULFILLMENT' AND status = 'ACTIVE' LIMIT 1");
    const logistics = await dbOne("SELECT id FROM participants WHERE role = 'LOGISTICS' AND status = 'ACTIVE' LIMIT 1");
    if (fulfillment || logistics) {
      await db(`
        INSERT INTO infra_bindings (id, seller_id, fulfillment_id, logistics_id, active)
        VALUES ($1, $2, $3, $4, TRUE)
      `, [genId('BND'), seller_id, fulfillment ? fulfillment.id : null, logistics ? logistics.id : null]);
    }

    console.log(`[Shop] Created ${shop_id}: ${brand_name} (seller: ${seller_id})`);

    res.status(201).json({
      shop_id,
      slug,
      brand_name,
      url: `/s/${slug}`,
      bot: `@${slug}_shop_bot`,
      status: 'ACTIVE'
    });
  } catch (err) {
    console.error('POST /shops', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// AGENT: прокси к Claude API (агент покупателя)
// Браузер → server.js → Claude API → ответ
// API-ключ хранится в ANTHROPIC_API_KEY (Render env var)
// ============================================================

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || '';

// Системный промпт собирается из ОБОИХ каталогов (Система + рынок)
async function buildAgentSystemPrompt() {
  // Каталог Системы (🟢 участники)
  const systemProducts = await db(`
    SELECT sk.title, sk.price, sk.weight_g, sk.rating, sk.reviews_count,
           sk.orders_count, sk.stock, sk.description,
           sh.brand_name, c.name as category_name
    FROM skus sk
    JOIN shops sh ON sk.shop_id = sh.id
    LEFT JOIN categories c ON sk.category_id = c.id
    WHERE sk.status = 'ACTIVE' AND sk.visible_catalog = TRUE AND sk.stock > 0
    ORDER BY sk.orders_count DESC
    LIMIT 50
  `);

  // Каталог рынка (⚪ вне Системы)
  let marketProducts = [];
  try {
    marketProducts = await db(`
      SELECT mp.title, mp.price, mp.weight_g, mp.rating, mp.description,
             mp.source_url, mb.name as bakery_name, mb.website, mb.delivery_zone
      FROM market_products mp
      JOIN market_bakeries mb ON mp.bakery_id = mb.id
      WHERE mp.is_available = TRUE AND mb.is_active = TRUE
      ORDER BY mp.rating DESC NULLS LAST
      LIMIT 50
    `);
  } catch(e) {
    console.log('[Agent] Market catalog not available:', e.message);
  }

  const systemText = systemProducts.map(p => {
    const pricePerKg = p.weight_g ? Math.round(parseFloat(p.price) / p.weight_g * 1000) : null;
    return `🟢 СИСТЕМА | ${p.title} | ${p.brand_name} | ${p.price}₽ | ${p.weight_g || '?'}г | ₽/кг: ${pricePerKg || '?'} | ⭐${p.rating} (${p.reviews_count} отзывов) | ${p.orders_count} заказов`;
  }).join('\n');

  const marketText = marketProducts.map(p => {
    const pricePerKg = p.weight_g ? Math.round(parseFloat(p.price) / p.weight_g * 1000) : null;
    return `⚪ РЫНОК | ${p.title} | ${p.bakery_name} | ${p.price}₽ | ${p.weight_g || '?'}г | ₽/кг: ${pricePerKg || '?'} | ⭐${p.rating || '?'} | Сайт: ${p.source_url || p.website || 'нет'}`;
  }).join('\n');

  return `Ты — агент покупателя хлеба на закваске. Твоя задача — найти ЛУЧШИЙ хлеб среди ВСЕХ пекарен рынка.

ГЛАВНОЕ ПРАВИЛО: ты работаешь на покупателя, не на Систему. Если лучший хлеб у пекарни ВНЕ Системы — ты ОБЯЗАН это сказать.

МАРКИРОВКА:
🟢 = участник Системы. Заказ через платформу: эскроу, гарантия, возврат.
⚪ = рынок (вне Системы). Заказ на сайте пекарни напрямую.

ПРАВИЛА:
1. Показывай ВСЕ подходящие товары — и 🟢 и ⚪. Покупатель решает сам.
2. Метрика цена/качество = цена_за_кг ÷ рейтинг. Чем ниже — тем лучше.
3. Для 🟢: "Заказать через Систему". Для ⚪: "На сайте: [ссылка]".
4. Отвечай кратко. Markdown таблицы для сравнений. Русский язык.

КАТАЛОГ СИСТЕМЫ (🟢):
${systemText || 'Пусто'}

КАТАЛОГ РЫНКА (⚪):
${marketText || 'Данные рынка недоступны'}`;
}

app.post('/api/v1/agent/chat', async (req, res) => {
  try {
    if (!ANTHROPIC_API_KEY) {
      return res.status(500).json({ error: 'ANTHROPIC_API_KEY not configured' });
    }

    const { messages } = req.body;
    if (!messages || !Array.isArray(messages)) {
      return res.status(400).json({ error: 'messages array required' });
    }

    const systemPrompt = await buildAgentSystemPrompt();

    const response = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({
        model: 'claude-sonnet-4-6',
        max_tokens: 1000,
        system: systemPrompt,
        messages: messages
      })
    });

    const data = await response.json();

    if (!response.ok) {
      console.error('[Agent] Claude API error:', data);
      return res.status(response.status).json({ error: data.error?.message || 'Claude API error' });
    }

    const text = data.content.map(c => c.text || '').join('');
    console.log(`[Agent] Reply: ${text.substring(0, 80)}...`);

    res.json({ reply: text });
  } catch (err) {
    console.error('[Agent] Error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// HEALTH + CONFIG
// ============================================================

app.get('/api/health', async (req, res) => {
  try {
    await db('SELECT 1');
    res.json({ status: 'ok', db: 'connected' });
  } catch (err) {
    res.status(500).json({ status: 'error', db: 'disconnected' });
  }
});

// Seller config (задача 0.3 — для рендеринга витрины)
app.get('/api/v1/config/:slug', async (req, res) => {
  try {
    const shop = await dbOne(`
      SELECT sh.*, p.seller_group, p.rating as seller_rating
      FROM shops sh JOIN participants p ON sh.seller_id = p.id
      WHERE sh.slug = $1
    `, [req.params.slug]);

    if (!shop) return res.status(404).json({ error: 'Config not found' });

    res.json({
      seller_id: shop.seller_id,
      slug: shop.slug,
      brand: {
        name: shop.brand_name,
        tagline: shop.brand_tagline,
        logo: shop.brand_logo_url,
        cover: shop.brand_cover_url,
        accent: shop.brand_accent,
        description: shop.brand_description
      },
      channels: shop.channels,
      custom_domain: shop.custom_domain,
      seller_group: shop.seller_group,
      seller_rating: shop.seller_rating
    });
  } catch (err) {
    res.status(500).json({ error: 'Internal error' });
  }
});

// ============================================================
// START
// ============================================================

// ──── Smoke test (диагностика развёртывания) ────
// Вставить в server.js рядом с /api/health, до app.listen

app.get('/api/v1/smoke-test', async (req, res) => {
  const t0 = Date.now();
  const checks = {};
  const need = ['participants','participant_tariffs','shops','skus','categories',
                'customers','orders','order_items','clearing_splits'];

  async function check(name, fn) {
    try { checks[name] = await fn(); }
    catch (err) { checks[name] = `FAIL: ${err.message}`; }
  }

  await check('db', async () => {
    await db('SELECT 1');
    return 'OK';
  });

  await check('tables', async () => {
    const rows = await db(`SELECT table_name FROM information_schema.tables
                           WHERE table_schema = 'public' ORDER BY table_name`);
    const have = rows.map(r => r.table_name);
    const missing = need.filter(n => !have.includes(n));
    return `${have.length} шт.${missing.length ? ` · нет: ${missing.join(', ')}` : ' · все ожидаемые на месте'}`;
  });

  await check('shop', async () => {
    const s = await dbOne(`SELECT slug, brand_name FROM shops WHERE status = 'ACTIVE' LIMIT 1`);
    return s ? `OK (${s.brand_name} · /${s.slug})` : 'FAIL: активных магазинов нет';
  });

  await check('skus', async () => {
    const r = await dbOne(`SELECT COUNT(*)::int AS n,
                                  COUNT(*) FILTER (WHERE visible_shop) ::int AS vis,
                                  COALESCE(SUM(stock),0)::int AS stock
                           FROM skus WHERE status = 'ACTIVE'`);
    return r.n ? `OK (${r.n} active · ${r.vis} в витрине · сток ${r.stock})` : 'FAIL: активных SKU нет';
  });

  await check('categories', async () => {
    const r = await dbOne(`SELECT COUNT(*)::int AS n FROM categories`);
    return `OK (${r.n})`;
  });

  await check('participants', async () => {
    const rows = await db(`SELECT role, COUNT(*)::int AS n FROM participants GROUP BY role ORDER BY role`);
    return rows.length ? rows.map(r => `${r.role}:${r.n}`).join(' · ') : 'FAIL: участников нет';
  });

  await check('tariffs', async () => {
    const r = await dbOne(`SELECT COUNT(*)::int AS n FROM participant_tariffs`);
    return r.n ? `OK (${r.n})` : 'WARN: тарифы не заданы (ст. 3.2)';
  });

  await check('orders', async () => {
    const r = await dbOne(`SELECT COUNT(*)::int AS n FROM orders`);
    return `OK (${r.n})`;
  });

  await check('clearing', async () => {
    const rows = await db(`SELECT role, SUM(amount)::numeric(12,2) AS amount
                           FROM clearing_splits GROUP BY role ORDER BY role`);
    if (!rows.length) return 'WARN: расщеплений нет (ст. 6.2)';
    return rows.map(r => `${r.role} ${r.amount}`).join(' · ');
  });

  await check('clearing_balance', async () => {
    const r = await dbOne(`
      SELECT COUNT(*)::int AS bad FROM (
        SELECT o.id, o.total::numeric AS total,
               COALESCE(SUM(cs.amount), 0)::numeric AS split
        FROM orders o
        LEFT JOIN clearing_splits cs ON cs.order_id = o.id
        GROUP BY o.id, o.total
        HAVING ABS(o.total::numeric - COALESCE(SUM(cs.amount), 0)::numeric) > 0.01
           AND COALESCE(SUM(cs.amount), 0) > 0
      ) x`);
    return r.bad === 0 ? 'OK (суммы сходятся)' : `FAIL: ${r.bad} заказов, где сплит ≠ сумме заказа`;
  });

  await check('rls', async () => {
    const rows = await db(`SELECT c.relname FROM pg_class c
                           JOIN pg_namespace n ON n.oid = c.relnamespace
                           WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relrowsecurity`);
    return rows.length === 0 ? 'OK (RLS включён везде)'
                             : `WARN: RLS выключен — ${rows.length} табл. (${rows.slice(0,4).map(r=>r.relname).join(', ')}${rows.length>4?'…':''})`;
  });

  const failed = Object.entries(checks).filter(([, v]) => String(v).startsWith('FAIL'));
  res.status(failed.length ? 500 : 200).json({
    result: failed.length ? `FAIL (${failed.length})` : 'PASS',
    ms: Date.now() - t0,
    checks
  });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Marketplace API running on port ${PORT}`);
  console.log(`Health: http://localhost:${PORT}/api/health`);
  console.log(`Shop:   http://localhost:${PORT}/api/v1/shop/massamadre`);
  console.log(`Search: http://localhost:${PORT}/api/v1/catalog/search?q=хлеб`);
});
