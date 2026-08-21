// ============================================================
// customers-api.js — регистрация покупателя (находка E2E #1)
// Монтируется как channels-api: require('./customers-api')(app, { db, dbOne, genId })
// Стиль server.js: genId, валидация, 201, ошибка текстом.
// ============================================================
// Закрывает пробел: заказ требует существующий customer_id,
// но маршрута создания покупателя не было. Теперь есть.
// ============================================================

module.exports = function (app, { db, dbOne, genId }) {

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
      console.error('POST /customers', err.message);
      res.status(500).json({ error: err.message });
    }
  });

  // GET /api/v1/customers/:id — прочитать покупателя
  app.get('/api/v1/customers/:id', async (req, res) => {
    try {
      const customer = await dbOne('SELECT * FROM customers WHERE id = $1', [req.params.id]);
      if (!customer) return res.status(404).json({ error: 'Customer not found' });
      res.json(customer);
    } catch (err) {
      console.error('GET /customers/:id', err.message);
      res.status(500).json({ error: err.message });
    }
  });

  console.log('[customers-api] mounted: POST /customers, GET /customers/:id');
};
