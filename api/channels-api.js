// ============================================================
// АЛЬФА: API конфигуратора каналов (монтируемый модуль, стиль server.js)
// Подключение:  require('./channels-api')(app, { db, dbOne })
// Реализует sku-visibility-seller: каналы, 3 уровня, храповик
// ============================================================
module.exports = function (app, { db, dbOne }) {

  // GET эффективная конфигурация одного SKU (что реально включено с учётом приоритета)
  app.get('/api/v1/sku/:sku_id/config', async (req, res) => {
    try {
      const sku = await dbOne('SELECT id, title, category_id, shop_id FROM skus WHERE id=$1',
        [req.params.sku_id]);
      if (!sku) return res.status(404).json({ error: 'SKU not found' });

      const channels = await db('SELECT * FROM effective_channels($1)', [sku.id]);
      const fulfilment = await db('SELECT * FROM effective_fulfilment($1)', [sku.id]);
      const settlement = await dbOne('SELECT * FROM effective_settlement($1)', [sku.id]);
      const level = await dbOne('SELECT service_level($1) AS lvl', [sku.id]);

      res.json({
        sku: { id: sku.id, title: sku.title, category_id: sku.category_id },
        channels: channels.map(c => ({
          code: c.channel_code, title: c.title, enabled: c.enabled,
          from: c.source_scope, is_system: c.is_system, take_rate: Number(c.take_rate)
        })),
        fulfilment: fulfilment.map(f => ({ code: f.service_code, title: f.title, provider: f.provider, from: f.source_scope })),
        settlement: settlement ? { mode: settlement.mode, from: settlement.source_scope } : { mode: 'OWN', from: 'default' },
        service_level: level ? Number(level.lvl) : 0
      });
    } catch (e) { console.error('sku config', e); res.status(500).json({ error: 'Internal error' }); }
  });

  // PUT правило видимости канала на любом из трёх уровней
  // body: { shop_id, scope: SHOP|CATEGORY|SKU, scope_ref, channel_code, enabled }
  app.put('/api/v1/visibility', async (req, res) => {
    try {
      const { shop_id, scope, scope_ref = null, channel_code, enabled } = req.body;
      if (!['SHOP', 'CATEGORY', 'SKU'].includes(scope))
        return res.status(400).json({ error: 'bad scope' });
      await db(`
        INSERT INTO visibility_rules (shop_id, scope, scope_ref, channel_code, enabled, updated_at)
        VALUES ($1,$2,$3,$4,$5, now())
        ON CONFLICT (shop_id, scope, scope_ref, channel_code)
        DO UPDATE SET enabled=EXCLUDED.enabled, updated_at=now()
      `, [shop_id, scope, scope_ref, channel_code, enabled]);
      res.json({ ok: true });
    } catch (e) { console.error('put visibility', e); res.status(500).json({ error: 'Internal error' }); }
  });

  // PUT правило fulfilment
  app.put('/api/v1/fulfilment', async (req, res) => {
    try {
      const { shop_id, scope, scope_ref = null, service_code, provider } = req.body;
      await db(`
        INSERT INTO fulfilment_rules (shop_id, scope, scope_ref, service_code, provider, updated_at)
        VALUES ($1,$2,$3,$4,$5, now())
        ON CONFLICT (shop_id, scope, scope_ref, service_code)
        DO UPDATE SET provider=EXCLUDED.provider, updated_at=now()
      `, [shop_id, scope, scope_ref, service_code, provider]);
      res.json({ ok: true });
    } catch (e) { console.error('put fulfilment', e); res.status(500).json({ error: 'Internal error' }); }
  });

  // PUT правило расчёта
  app.put('/api/v1/settlement', async (req, res) => {
    try {
      const { shop_id, scope, scope_ref = null, mode } = req.body;
      if (!['OWN', 'SYSTEM', 'PER_ORDER'].includes(mode))
        return res.status(400).json({ error: 'bad mode' });
      await db(`
        INSERT INTO settlement_rules (shop_id, scope, scope_ref, mode, updated_at)
        VALUES ($1,$2,$3,$4, now())
        ON CONFLICT (shop_id, scope, scope_ref)
        DO UPDATE SET mode=EXCLUDED.mode, updated_at=now()
      `, [shop_id, scope, scope_ref, mode]);
      res.json({ ok: true });
    } catch (e) { console.error('put settlement', e); res.status(500).json({ error: 'Internal error' }); }
  });

  // POST храповик: повысить уровень сервиса при сделке (ТОЛЬКО ВВЕРХ)
  // body: { order_id, sku_id, to_level, reason }
  app.post('/api/v1/ratchet/upgrade', async (req, res) => {
    try {
      const { order_id, sku_id, to_level, reason } = req.body;
      const cur = await dbOne('SELECT service_level($1) AS lvl', [sku_id]);
      const from_level = cur ? Number(cur.lvl) : 0;
      if (Number(to_level) <= from_level)
        return res.status(409).json({ error: 'ratchet: only upgrade allowed', from_level, to_level });
      await db(`INSERT INTO ratchet_log (order_id, sku_id, from_level, to_level, reason)
                VALUES ($1,$2,$3,$4,$5)`, [order_id, sku_id, from_level, to_level, reason || null]);
      res.status(201).json({ ok: true, from_level, to_level });
    } catch (e) {
      // CHECK to_level>from_level в БД — вторая линия защиты
      if (String(e.message).includes('ratchet_log_check'))
        return res.status(409).json({ error: 'ratchet: downgrade blocked by DB' });
      console.error('ratchet', e); res.status(500).json({ error: 'Internal error' });
    }
  });

  // GET сводка магазина: уровень каждой категории (для кабинета селлера)
  app.get('/api/v1/shop/:shop_id/service-map', async (req, res) => {
    try {
      const rows = await db(`
        SELECT DISTINCT s.category_id, c.name AS category_name,
               (SELECT service_level(min(s2.id)) FROM skus s2
                 WHERE s2.shop_id=s.shop_id AND s2.category_id=s.category_id) AS level
        FROM skus s JOIN categories c ON c.id=s.category_id
        WHERE s.shop_id=$1
        ORDER BY s.category_id`, [req.params.shop_id]);
      res.json({ shop_id: req.params.shop_id, categories: rows.map(r => ({
        category_id: r.category_id, category_name: r.category_name, service_level: Number(r.level)
      })) });
    } catch (e) { console.error('service-map', e); res.status(500).json({ error: 'Internal error' }); }
  });

};
