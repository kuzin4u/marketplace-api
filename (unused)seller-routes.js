'use strict';
// seller-routes.js — недостающие маршруты пути селлера для marketplace-api.
// Закрывает уровень 3 плана тестирования: POST /shops, POST /seller/products,
// POST /orders + GET /shop/:slug (проверку уникальности вызывает shop-form).
//
// Подключение в server.js одной строкой, НИЧЕГО не ломает в существующем коде:
//     const sellerRoutes = require('./seller-routes');
//     app.use('/api/v1', express.json(), sellerRoutes);   // express.json уже может стоять глобально
//
// Требует: DATABASE_URL (pg). Стиль — как Agent Service: db/dbOne/tx, идемпотентность,
// ошибки ограничений БД → осмысленный ответ. Своё pg-подключение, чтобы модуль
// работал даже если в server.js пул назван иначе.

const express = require('express');
const { Pool } = require('pg');

// --- подключение к тому же PostgreSQL (как в agent-service/db.js) ---
const useSsl = /supabase|render|amazonaws/i.test(process.env.DATABASE_URL || '');
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: useSsl ? { rejectUnauthorized: false } : false,
  max: Number(process.env.PG_POOL_MAX || 5),
  idleTimeoutMillis: 30000
});
pool.on('error', e => console.error('[seller-routes db] idle client error:', e.message));

const db    = async (sql, p = []) => (await pool.query(sql, p)).rows;
const dbOne = async (sql, p = []) => (await db(sql, p))[0] || null;
async function tx(fn) {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    const out = await fn(
      async (s, p = []) => (await c.query(s, p)).rows,
      async (s, p = []) => (await c.query(s, p)).rows[0] || null
    );
    await c.query('COMMIT');
    return out;
  } catch (e) { await c.query('ROLLBACK').catch(() => {}); throw e; }
  finally { c.release(); }
}

// --- перевод ошибок БД в осмысленный ответ (как errors.js) ---
function fromDbError(res, e) {
  // нарушение уникальности slug → 409, а не 500
  if (e && e.code === '23505') {
    return res.status(409).json({ error: 'slug_taken', detail: 'Магазин с таким адресом уже существует' });
  }
  if (e && e.code === '23514') { // CHECK
    return res.status(422).json({ error: 'constraint_violation', detail: e.constraint || e.message });
  }
  if (e && e.code === '23502') { // NOT NULL
    return res.status(422).json({ error: 'missing_required_field', detail: e.column || e.message });
  }
  console.error('[seller-routes] error:', e && e.message);
  return res.status(500).json({ error: 'internal_error' });
}
const asyncH = fn => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(e => fromDbError(res, e));

// --- утилиты ---
const SLUG_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
function badSlug(s) { return !s || s.length < 3 || s.length > 63 || !SLUG_RE.test(s); }
function toKop(v) {                       // рубли (число/строка, . или ,) → копейки, минус недопустим
  if (v == null) return NaN;
  const s = String(v).trim();
  if (s.includes('-')) return NaN;
  const n = parseFloat(s.replace(/\s/g, '').replace(',', '.').replace(/[^\d.]/g, ''));
  return isNaN(n) ? NaN : Math.round(n * 100);
}
// принимает цену либо как price_kop (уже копейки), либо как price (рубли)
function resolveKop(body) {
  if (Number.isInteger(body.price_kop) && body.price_kop > 0) return body.price_kop;
  return toKop(body.price);
}

const router = express.Router();

// GET /shop/:slug — проверка существования (shop-form дергает для уникальности).
// 200 = занят (магазин есть), 404 = свободен.
router.get('/shop/:slug', asyncH(async (req, res) => {
  const slug = String(req.params.slug || '').toLowerCase();
  const row = await dbOne('select shop_id, slug, brand, accent from shops where slug = $1', [slug]);
  if (!row) return res.status(404).json({ error: 'not_found', slug });
  res.json(row);
}));

// POST /shops — создать магазин + привязки. Идемпотентно по Idempotency-Key.
router.post('/shops', asyncH(async (req, res) => {
  const b = req.body || {};
  const slug = String(b.slug || '').toLowerCase();
  const brand = (b.title || b.brand || '').trim();
  const accent = b.accent_color || b.accent || '#2E5B3A';

  if (badSlug(slug)) return res.status(422).json({ error: 'invalid_slug', detail: 'Латиница, цифры, дефис; 3–63 символа' });
  if (!brand)        return res.status(422).json({ error: 'missing_brand', detail: 'Название магазина обязательно' });

  const idem = req.get('Idempotency-Key') || null;
  if (idem) {
    const seen = await dbOne('select shop_id, slug, brand, accent from shops where idempotency_key = $1', [idem]).catch(() => null);
    if (seen) return res.status(200).json({ ...seen, idempotent: true });
  }

  const created = await tx(async (q, q1) => {
    // защита от гонки: повторная проверка внутри транзакции; UNIQUE(slug) в схеме — последний рубеж
    const exists = await q1('select 1 from shops where slug = $1', [slug]);
    if (exists) { const err = new Error('duplicate'); err.code = '23505'; throw err; }

    const shop = await q1(
      `insert into shops (slug, brand, accent${idem ? ', idempotency_key' : ''})
       values ($1, $2, $3${idem ? ', $4' : ''})
       returning shop_id, slug, brand, accent`,
      idem ? [slug, brand, accent, idem] : [slug, brand, accent]
    );

    // привязки инфраструктуры (регион/фулфилмент) — best-effort, не валит создание магазина
    const regions = Array.isArray(b.regions) ? b.regions : [];
    const ff = b.fulfillment || null;
    try {
      await q(
        `insert into infra_bindings (shop_id, kind, value)
         select $1, 'region', unnest($2::text[])
         where array_length($2::text[],1) is not null`,
        [shop.shop_id, regions]
      );
      if (ff) await q(`insert into infra_bindings (shop_id, kind, value) values ($1, 'fulfillment', $2)`, [shop.shop_id, ff]);
    } catch (e) { console.warn('[seller-routes] infra_bindings skipped:', e.message); }

    return shop;
  });

  res.status(201).json(created);
}));

// POST /seller/products — создать товар (SKU). Цена в копейках. Идемпотентно.
router.post('/seller/products', asyncH(async (req, res) => {
  const b = req.body || {};
  const title = (b.title || '').trim();
  const price_kop = resolveKop(b);
  const stock = Number.isInteger(b.stock) ? b.stock : parseInt(b.stock, 10) || 0;
  const status = (b.status === 'DRAFT') ? 'DRAFT' : 'ACTIVE';

  if (!title)                 return res.status(422).json({ error: 'missing_title' });
  if (!(price_kop > 0))       return res.status(422).json({ error: 'invalid_price', detail: 'Цена в копейках должна быть > 0' });
  if (stock < 0)              return res.status(422).json({ error: 'invalid_stock' });

  const idem = req.get('Idempotency-Key') || null;
  if (idem) {
    const seen = await dbOne('select sku_id, title, price_kop, stock, status from skus where idempotency_key = $1', [idem]).catch(() => null);
    if (seen) return res.status(200).json({ ...seen, idempotent: true });
  }

  const shop_id = b.shop_id || null;
  const row = await dbOne(
    `insert into skus (shop_id, title, description, price_kop, stock, category, status${idem ? ', idempotency_key' : ''})
     values ($1, $2, $3, $4, $5, $6, $7${idem ? ', $8' : ''})
     returning sku_id, title, price_kop, stock, status`,
    idem ? [shop_id, title, b.description || '', price_kop, stock, b.category || 'Другое', status, idem]
         : [shop_id, title, b.description || '', price_kop, stock, b.category || 'Другое', status]
  );
  res.status(201).json(row);
}));

// POST /orders — создать заказ (недостающий маршрут). Минимальный: покупатель + позиции.
router.post('/orders', asyncH(async (req, res) => {
  const b = req.body || {};
  const items = Array.isArray(b.items) ? b.items : [];
  if (!items.length) return res.status(422).json({ error: 'empty_order', detail: 'Заказ без позиций' });

  const idem = req.get('Idempotency-Key') || null;
  if (idem) {
    const seen = await dbOne('select order_id, status, total_kop from orders where idempotency_key = $1', [idem]).catch(() => null);
    if (seen) return res.status(200).json({ ...seen, idempotent: true });
  }

  const order = await tx(async (q, q1) => {
    // сумма из актуальных цен товаров, а не из тела запроса (защита от подмены цены)
    let total = 0;
    for (const it of items) {
      const sku = await q1('select price_kop, stock from skus where sku_id = $1 and status = $2', [it.sku_id, 'ACTIVE']);
      if (!sku) { const e = new Error('sku_unavailable'); e.code = '23514'; e.constraint = 'sku_not_active'; throw e; }
      const qty = Math.max(1, parseInt(it.qty, 10) || 1);
      total += sku.price_kop * qty;
    }
    const ord = await q1(
      `insert into orders (buyer_ref, total_kop, status${idem ? ', idempotency_key' : ''})
       values ($1, $2, 'CREATED'${idem ? ', $3' : ''})
       returning order_id, status, total_kop`,
      idem ? [b.buyer_ref || null, total, idem] : [b.buyer_ref || null, total]
    );
    for (const it of items) {
      await q(`insert into order_items (order_id, sku_id, qty) values ($1, $2, $3)`,
        [ord.order_id, it.sku_id, Math.max(1, parseInt(it.qty, 10) || 1)]);
    }
    return ord;
  });

  res.status(201).json(order);
}));

// health для смоук-теста уровня 3
router.get('/seller/health', asyncH(async (req, res) => {
  const r = await dbOne('select 1 as ok');
  res.json({ ok: r ? true : false, routes: ['GET /shop/:slug', 'POST /shops', 'POST /seller/products', 'POST /orders'] });
}));

module.exports = router;
module.exports.pool = pool; // на случай переиспользования подключения
