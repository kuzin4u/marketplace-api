// ============================================================
// auth-seller.js — боевая авторизация продавца (JWT)
// Врезается в server.js marketplace-api. Закрывает дыру:
// seller_id больше НЕ берётся из тела/URL, а из подписанного токена.
// ============================================================
// Подключение в server.js (после app.use(express.json())):
//   const initAuth = require('./auth-seller');
//   const { requireSeller } = initAuth(app, { db, dbOne, genId });
// затем на защищаемых маршрутах заменить чтение seller_id:
//   app.post('/api/v1/shops', requireSeller, async (req,res)=>{ const seller_id = req.seller_id; ... })
//   app.post('/api/v1/seller/products', requireSeller, ...)   // seller_id из токена, не из :param
// ============================================================

const jwt = require('jsonwebtoken');
const bcrypt = require('bcryptjs');

// Значение по умолчанию убрано намеренно. Подпись на известном секрете
// подделывается за минуту, а seller_id внутри токена определяет, чьи товары
// и заказы видны. Сервер обязан не подняться, а не работать «как будто».
const JWT_SECRET = process.env.JWT_SECRET;
const TOKEN_TTL = process.env.JWT_TTL || '12h';

if (!JWT_SECRET || JWT_SECRET === 'DEV-ONLY-CHANGE-ME' || JWT_SECRET.length < 32) {
  console.error(
    '\n[auth] ОСТАНОВКА: переменная окружения JWT_SECRET не задана,\n' +
    '       оставлена значением по умолчанию или короче 32 символов.\n\n' +
    '       Сгенерировать:  openssl rand -base64 48\n' +
    '       Задать: Render → Environment → JWT_SECRET\n');
  process.exit(1);
}

module.exports = function initAuth(app, { db, dbOne, genId }) {

  // --- гарантируем таблицу учётных данных (не трогаем participants) ---
  async function ensureSchema() {
    await db(`
      CREATE TABLE IF NOT EXISTS seller_auth (
        login         TEXT PRIMARY KEY,
        seller_id     TEXT NOT NULL REFERENCES participants(id),
        password_hash TEXT NOT NULL,
        created_at    TIMESTAMPTZ DEFAULT now(),
        last_login    TIMESTAMPTZ
      )
    `);
  }
  ensureSchema().catch(e => console.error('[auth] schema init:', e.message));

  // --- middleware: проверяет Bearer-токен, кладёт seller_id в req ---
  function requireSeller(req, res, next) {
    const h = req.headers.authorization || '';
    const token = h.startsWith('Bearer ') ? h.slice(7) : null;
    if (!token) return res.status(401).json({ error: 'no_token', detail: 'Требуется вход' });
    try {
      const payload = jwt.verify(token, JWT_SECRET);
      if (payload.role !== 'SELLER') return res.status(403).json({ error: 'not_seller' });
      req.seller_id = payload.seller_id;      // ← источник истины, не тело/URL
      req.seller_login = payload.login;
      next();
    } catch (e) {
      return res.status(401).json({ error: 'invalid_token', detail: 'Сессия истекла, войдите снова' });
    }
  }

  // --- РЕГИСТРАЦИЯ: задать логин+пароль существующему продавцу ---
  // Продавец уже создан в participants (реестр/KYC). Здесь он получает учётку.
  app.post('/api/v1/auth/register', async (req, res) => {
    try {
      const { seller_id, login, password } = req.body || {};
      if (!seller_id || !login || !password)
        return res.status(400).json({ error: 'seller_id, login, password required' });
      if (String(password).length < 8)
        return res.status(400).json({ error: 'weak_password', detail: 'Минимум 8 символов' });

      const p = await dbOne('SELECT id, role FROM participants WHERE id = $1', [seller_id]);
      if (!p) return res.status(404).json({ error: 'seller_not_found' });
      if (p.role !== 'SELLER') return res.status(400).json({ error: 'not_a_seller' });

      const exists = await dbOne('SELECT 1 FROM seller_auth WHERE login = $1', [login]);
      if (exists) return res.status(409).json({ error: 'login_taken' });

      const hash = await bcrypt.hash(String(password), 10);
      await db('INSERT INTO seller_auth (login, seller_id, password_hash) VALUES ($1,$2,$3)',
        [login, seller_id, hash]);
      res.status(201).json({ login, seller_id, ok: true });
    } catch (e) {
      console.error('POST /auth/register', e.message);
      res.status(500).json({ error: 'internal_error' });
    }
  });

  // --- ЛОГИН: логин+пароль → JWT с seller_id внутри ---
  app.post('/api/v1/auth/login', async (req, res) => {
    try {
      const { login, password } = req.body || {};
      if (!login || !password) return res.status(400).json({ error: 'login, password required' });

      const row = await dbOne('SELECT login, seller_id, password_hash FROM seller_auth WHERE login = $1', [login]);
      // одинаковый ответ на «нет логина» и «неверный пароль» — не выдаём, что существует
      const ok = row && await bcrypt.compare(String(password), row.password_hash);
      if (!ok) return res.status(401).json({ error: 'bad_credentials', detail: 'Неверный логин или пароль' });

      await db('UPDATE seller_auth SET last_login = now() WHERE login = $1', [login]).catch(() => {});
      const token = jwt.sign(
        { seller_id: row.seller_id, login: row.login, role: 'SELLER' },
        JWT_SECRET, { expiresIn: TOKEN_TTL }
      );
      res.json({ token, seller_id: row.seller_id, expires_in: TOKEN_TTL });
    } catch (e) {
      console.error('POST /auth/login', e.message);
      res.status(500).json({ error: 'internal_error' });
    }
  });

  // --- КТО Я: форма может подтянуть свой seller_id по токену ---
  app.get('/api/v1/auth/me', requireSeller, (req, res) => {
    res.json({ seller_id: req.seller_id, login: req.seller_login, role: 'SELLER' });
  });

  return { requireSeller };
};
