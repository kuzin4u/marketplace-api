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
const crypto = require('crypto');

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

// --- ключ допуска (ст. 16: допуск отделён от выдачи) ---
// Учётную запись продавцу выдаёт Организатор, а не сам продавец. Пока роли
// ORGANIZER в токене нет, её место занимает отдельный ключ: он не даёт
// доступа к данным и служит ровно одному — праву впустить участника.
//
// В отличие от JWT_SECRET сервер здесь не падает. Незаданный ключ не
// ослабляет защиту молча: маршруты допуска отвечают 501 и не работают
// вовсе — так же, как channels-api без requireSeller. Витрина и каталог
// при этом продолжают работать, и деплой не встаёт из-за незаполненной
// переменной.
const ADMISSION_KEY = process.env.ADMISSION_KEY || '';

if (!ADMISSION_KEY) {
  console.warn(
    '[auth] ADMISSION_KEY не задана — контур допуска отключён (501).\n' +
    '       Выдать учётку продавцу будет нельзя. Сгенерировать: openssl rand -base64 36');
} else {
  console.log('[auth] контур допуска включён (X-Admission-Key)');
}

// Сравнение за постоянное время: обычное === завершается на первом
// несовпавшем байте и по времени ответа выдаёт длину общего префикса.
function admissionKeyMatches(given) {
  const a = Buffer.from(String(given));
  const b = Buffer.from(ADMISSION_KEY);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

// Мягкая проверка: вызывающий сам решает, что делать без ключа.
// Нужна там, где маршрут открыт, но ключ расширяет права
// (POST /participants: без ключа — только заявка на роль SELLER).
function hasAdmission(req) {
  if (!ADMISSION_KEY) return false;
  const k = req.headers['x-admission-key'];
  return typeof k === 'string' && k.length > 0 && admissionKeyMatches(k);
}

// Жёсткая проверка: без ключа маршрута нет.
function requireAdmission(req, res, next) {
  if (!ADMISSION_KEY)
    return res.status(501).json({ error: 'admission_not_wired',
      detail: 'ADMISSION_KEY не задана — контур допуска отключён' });
  if (!hasAdmission(req))
    return res.status(403).json({ error: 'admission_required',
      detail: 'Требуется ключ допуска' });
  next();
}

module.exports = function initAuth(app, { db, dbOne, genId }) {

  // --- гарантируем таблицу учётных данных (не трогаем participants) ---
  // Дословно повторено в schema/07_seller_auth.sql. Правится в двух местах
  // сразу, иначе на разных базах окажутся разные таблицы с одним именем.
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
    // Одна учётка на участника. Здесь же, а не только в миграции: иначе
    // гарантия зависит от того, вспомнил ли кто-то прогнать 07.
    // Не встанет, если дубли уже есть, — тогда см. предполётную проверку
    // в миграции, она называет виновных поимённо.
    await db('CREATE UNIQUE INDEX IF NOT EXISTS uq_seller_auth_seller ON seller_auth (seller_id)');
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
  //
  // Маршрут был открыт: учётку получал любой, кто назовёт существующий
  // seller_id без логина. А seller_id — величина публичная, витрина и каталог
  // отдают его в каждом товаре. Вместе это давало захват аккаунта продавца
  // по одному лишь адресу магазина, поэтому здесь ключ допуска.
  app.post('/api/v1/auth/register', requireAdmission, async (req, res) => {
    try {
      const { seller_id, login, password } = req.body || {};
      if (!seller_id || !login || !password)
        return res.status(400).json({ error: 'seller_id, login, password required' });
      if (String(password).length < 8)
        return res.status(400).json({ error: 'weak_password', detail: 'Минимум 8 символов' });

      const p = await dbOne('SELECT id, role, status FROM participants WHERE id = $1', [seller_id]);
      if (!p) return res.status(404).json({ error: 'seller_not_found' });
      if (p.role !== 'SELLER') return res.status(400).json({ error: 'not_a_seller' });
      // Заявка (PENDING) — ещё не участник. Учётка выдаётся после допуска,
      // иначе публичная форма /join сама себе выписывала бы пропуск.
      if (p.status !== 'ACTIVE')
        return res.status(403).json({ error: 'seller_not_admitted',
          detail: `Участник не допущен, статус ${p.status}` });

      const exists = await dbOne('SELECT 1 FROM seller_auth WHERE login = $1', [login]);
      if (exists) return res.status(409).json({ error: 'login_taken' });

      // Одна учётка на продавца. Уникален был только login, поэтому одному
      // seller_id можно было завести второй вход и не отобрать первый.
      const already = await dbOne('SELECT login FROM seller_auth WHERE seller_id = $1', [seller_id]);
      if (already)
        return res.status(409).json({ error: 'seller_has_login',
          detail: 'У участника уже есть учётная запись' });

      const hash = await bcrypt.hash(String(password), 10);
      await db('INSERT INTO seller_auth (login, seller_id, password_hash) VALUES ($1,$2,$3)',
        [login, seller_id, hash]);
      res.status(201).json({ login, seller_id, ok: true });
    } catch (e) {
      // Две проверки выше делаются отдельными запросами, и между ними
      // и вставкой есть окно: одновременный запрос успевает вставить
      // строку первым. Настоящую гарантию даёт база — ловим её отказ
      // и отвечаем тем же кодом, что и проверка, а не 500.
      if (e && e.code === '23505') {
        if (e.constraint === 'uq_seller_auth_seller')
          return res.status(409).json({ error: 'seller_has_login',
            detail: 'У участника уже есть учётная запись' });
        return res.status(409).json({ error: 'login_taken' });
      }
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

  return { requireSeller, requireAdmission, hasAdmission };
};
