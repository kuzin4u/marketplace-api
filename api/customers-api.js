// ============================================================
// customers-api.js — регистрация покупателя (находка E2E #1)
// Монтируется как channels-api: require('./customers-api')(app, { db, dbOne, genId })
// Стиль server.js: genId, валидация, 201, ошибка текстом.
// ============================================================
// Закрывает пробел: заказ требует существующий customer_id,
// но маршрута создания покупателя не было. Теперь есть.
// ============================================================

module.exports = function (app, { db, dbOne, genId, requireSeller, fromDbError }) {

  // Fail-closed, как в channels-api: если auth-модуль не передан, чтение
  // карточки покупателя не открывается «пока что», а отключается вовсе.
  const guard = requireSeller || function (req, res) {
    res.status(501).json({ error: 'auth_not_wired',
      detail: 'requireSeller не передан в customers-api — чтение отключено' });
  };

  // Общий формат ошибок server.js. Раньше модуль отдавал err.message
  // клиенту целиком — с именами таблиц и ограничений.
  const dbErr = fromDbError || function (res, err, where) {
    console.error(where || 'db', err && err.message);
    return res.status(500).json({ error: 'Internal error' });
  };

  // POST /api/v1/customers — зарегистрировать покупателя
  app.post('/api/v1/customers', async (req, res) => {
    try {
      const { name, phone, email } = req.body;
      // Минимальная валидация: имя ИЛИ телефон должны быть (покупателя надо как-то опознать)
      if (!name && !phone) {
        return res.status(400).json({ error: 'name or phone required' });
      }

      const id = genId('CUST');

      // Реальная таблица customers: id, name, phone, email (без status).
      await db(`
        INSERT INTO customers (id, name, phone, email)
        VALUES ($1, $2, $3, $4)
      `, [id, name || null, phone || null, email || null]);

      console.log(`[Customer] Created ${id}: ${name || phone}`);
      res.status(201).json({ id, name, phone, email });
    } catch (err) {
      // customers.phone уникален: повтор даёт 409, а не 500.
      return dbErr(res, err, 'POST /customers');
    }
  });

  // GET /api/v1/customers/:id — прочитать покупателя
  //
  // Маршрут был открыт и отдавал телефон, имя и e-mail без токена: перебор
  // CUST-<hex8> выгружал базу покупателей целиком. Теперь — только продавцу
  // и только про своего покупателя: связь берётся из customer_bindings,
  // то есть право видеть контакты даёт состоявшийся заказ, а не наличие
  // токена вообще.
  //
  // Чужой и несуществующий покупатель отвечают одинаково — 404. Иначе
  // разница ответов сама по себе подтверждала бы, что такой CUST- есть.
  app.get('/api/v1/customers/:id', guard, async (req, res) => {
    try {
      const customer = await dbOne(`
        SELECT c.* FROM customers c
        JOIN customer_bindings cb ON cb.customer_id = c.id
        WHERE c.id = $1 AND cb.seller_id = $2
      `, [req.params.id, req.seller_id]);
      if (!customer) return res.status(404).json({ error: 'Customer not found' });
      res.json(customer);
    } catch (err) {
      return dbErr(res, err, 'GET /customers/:id');
    }
  });

  console.log('[customers-api] mounted: POST /customers (открыт), GET /customers/:id (токен + связь)');
};
