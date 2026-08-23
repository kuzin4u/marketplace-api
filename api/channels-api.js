// ============================================================
// АЛЬФА: API конфигуратора каналов (монтируемый модуль, стиль server.js)
// ЗАЩИЩЁННАЯ версия (ТРЕК C): запись только владельцу магазина.
// Подключение:  require('./channels-api')(app, { db, dbOne, requireSeller })
//   requireSeller — из auth-seller.js (кладёт req.seller_id из токена).
//   Если requireSeller не передан — писать НЕЛЬЗЯ (fail-closed заглушка 501),
//   чтобы забытая врезка auth не открыла запись всем.
// Реализует sku-visibility-seller: каналы, 3 уровня, храповик.
// ============================================================
module.exports = function (app, { db, dbOne, requireSeller }) {

  // Fail-closed: если auth-модуль не подключён, запись запрещена вовсе.
  const guard = requireSeller || function (req, res) {
    res.status(501).json({ error: 'auth_not_wired',
      detail: 'requireSeller не передан в channels-api — запись отключена' });
  };

  // Проверка владения магазином: seller_id из токена vs владелец shop_id.
  async function assertShopOwner(req, res, shop_id) {
    if (!shop_id) { res.status(400).json({ error: 'shop_id required' }); return false; }
    const shop = await dbOne('SELECT seller_id FROM shops WHERE id=$1', [shop_id]);
    if (!shop) { res.status(404).json({ error: 'shop_not_found' }); return false; }
    if (shop.seller_id !== req.seller_id) {
      res.status(403).json({ error: 'not_your_shop',
        detail: 'Магазин принадлежит другому продавцу' });
      return false;
    }
    return true;
  }

  // ── ЧТЕНИЕ — открыто ──

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

  // ── ЗАПИСЬ — только владельцу магазина (guard + assertShopOwner) ──

  app.put('/api/v1/visibility', guard, async (req, res) => {
    try {
      const { shop_id, scope, scope_ref = null, channel_code, enabled } = req.body;
      if (!(await assertShopOwner(req, res, shop_id))) return;
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

  app.put('/api/v1/fulfilment', guard, async (req, res) => {
    try {
      const { shop_id, scope, scope_ref = null, service_code, provider } = req.body;
      if (!(await assertShopOwner(req, res, shop_id))) return;
      await db(`
        INSERT INTO fulfilment_rules (shop_id, scope, scope_ref, service_code, provider, updated_at)
        VALUES ($1,$2,$3,$4,$5, now())
        ON CONFLICT (shop_id, scope, scope_ref, service_code)
        DO UPDATE SET provider=EXCLUDED.provider, updated_at=now()
      `, [shop_id, scope, scope_ref, service_code, provider]);
      res.json({ ok: true });
    } catch (e) { console.error('put fulfilment', e); res.status(500).json({ error: 'Internal error' }); }
  });

  app.put('/api/v1/settlement', guard, async (req, res) => {
    try {
      const { shop_id, scope, scope_ref = null, mode } = req.body;
      if (!(await assertShopOwner(req, res, shop_id))) return;
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

  app.post('/api/v1/ratchet/upgrade', guard, async (req, res) => {
    try {
      const { order_id, sku_id, to_level, reason } = req.body;
      const sku = await dbOne('SELECT shop_id FROM skus WHERE id=$1', [sku_id]);
      if (!sku) return res.status(404).json({ error: 'SKU not found' });
      if (!(await assertShopOwner(req, res, sku.shop_id))) return;
      const cur = await dbOne('SELECT service_level($1) AS lvl', [sku_id]);
      const from_level = cur ? Number(cur.lvl) : 0;
      if (Number(to_level) <= from_level)
        return res.status(409).json({ error: 'ratchet: only upgrade allowed', from_level, to_level });
      await db(`INSERT INTO ratchet_log (order_id, sku_id, from_level, to_level, reason)
                VALUES ($1,$2,$3,$4,$5)`, [order_id, sku_id, from_level, to_level, reason || null]);
      res.status(201).json({ ok: true, from_level, to_level });
    } catch (e) {
      if (String(e.message).includes('ratchet_log_check'))
        return res.status(409).json({ error: 'ratchet: downgrade blocked by DB' });
      console.error('ratchet', e); res.status(500).json({ error: 'Internal error' });
    }
  });

  console.log('[channels-api] mounted (protected): PUT requires shop ownership');
};
