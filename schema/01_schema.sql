-- ============================================================
-- СПРИНТ 0 · Задача 0.1 · Схема БД
-- Распределённый маркетплейс НСВР
-- ============================================================
-- Каждая таблица привязана к статье Правил системы ред. 2
-- Порядок создания учитывает FK-зависимости
-- ============================================================

-- 1. Участники реестра (ст. 4 — Зонтичный бренд и реестр)
CREATE TABLE participants (
    id              TEXT PRIMARY KEY,          -- PTR-12345
    inn             TEXT NOT NULL,
    name            TEXT NOT NULL,             -- из ФНС
    legal_type      TEXT NOT NULL CHECK (legal_type IN ('FL','SELF_EMPLOYED','IP','OOO')),
    role            TEXT NOT NULL CHECK (role IN ('SELLER','FULFILLMENT','LOGISTICS','TRUNK','WAREHOUSE','ORGANIZER','BANK')),
    seller_group    INTEGER CHECK (seller_group IN (1, 2, 3)),  -- ст. 13: группы селлеров
    region          TEXT NOT NULL DEFAULT 'MSK',
    status          TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('PENDING','ACTIVE','SUSPENDED','EXITED')),
    rating          NUMERIC(3,2) DEFAULT 0.00,
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    contact_phone   TEXT,
    contact_email   TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. Тарифы участников (ст. 3.2 — оферта в реестре)
CREATE TABLE participant_tariffs (
    id              TEXT PRIMARY KEY,
    participant_id  TEXT NOT NULL REFERENCES participants(id),
    service_type    TEXT NOT NULL,              -- 'ASSEMBLY','STORAGE','DELIVERY_ZONE_1','TRUNK_MSK_SPB',...
    unit            TEXT NOT NULL,              -- 'PER_ITEM','PER_PALLET_DAY','PER_ORDER','PERCENT'
    rate            NUMERIC(12,2) NOT NULL,     -- ставка в рублях или %
    min_amount      NUMERIC(12,2) DEFAULT 0,
    valid_from      DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_to        DATE,                      -- NULL = бессрочно
    notify_days     INTEGER DEFAULT 14,        -- уведомление об изменении за N дней
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_tariffs_participant ON participant_tariffs(participant_id);

-- 3. Привязка селлер ↔ операторы (ст. 3.3.1 — binding)
CREATE TABLE infra_bindings (
    id              TEXT PRIMARY KEY,
    seller_id       TEXT NOT NULL REFERENCES participants(id),
    fulfillment_id  TEXT REFERENCES participants(id),
    logistics_id    TEXT REFERENCES participants(id),
    trunk_id        TEXT REFERENCES participants(id),
    warehouse_id    TEXT REFERENCES participants(id),
    active          BOOLEAN NOT NULL DEFAULT TRUE,
    bound_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX idx_binding_seller_active ON infra_bindings(seller_id) WHERE active = TRUE;

-- 4. Магазины (ст. 9.2 — магазин селлера, нижний уровень витрины)
CREATE TABLE shops (
    id              TEXT PRIMARY KEY,          -- SHOP-massamadre
    seller_id       TEXT NOT NULL UNIQUE REFERENCES participants(id),
    slug            TEXT NOT NULL UNIQUE,       -- URL: /shop/{slug}
    brand_name      TEXT NOT NULL,
    brand_tagline   TEXT,
    brand_logo_url  TEXT,
    brand_cover_url TEXT,
    brand_accent    TEXT DEFAULT '#2563eb',     -- hex color
    brand_description TEXT,
    status          TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('SETUP','ACTIVE','SUSPENDED','CLOSED')),
    channels        JSONB NOT NULL DEFAULT '{"telegram":true,"website":true,"vk":false,"max":false,"instagram":false}',
    custom_domain   TEXT,                      -- massamadre.ru
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 5. Категории товаров (ст. 4.6 — единое дерево)
CREATE TABLE categories (
    id              TEXT PRIMARY KEY,
    parent_id       TEXT REFERENCES categories(id),
    name            TEXT NOT NULL,
    slug            TEXT NOT NULL UNIQUE,
    icon            TEXT,
    sort_order      INTEGER DEFAULT 0,
    is_active       BOOLEAN DEFAULT TRUE
);

-- 6. Товары / SKU (ст. 9.4 — SKU-атом обеих витрин)
CREATE TABLE skus (
    id              TEXT PRIMARY KEY,          -- SKU-001
    seller_id       TEXT NOT NULL REFERENCES participants(id),
    shop_id         TEXT NOT NULL REFERENCES shops(id),
    title           TEXT NOT NULL,
    description     TEXT,
    images          TEXT[] DEFAULT '{}',
    category_id     TEXT REFERENCES categories(id),
    tags            TEXT[] DEFAULT '{}',
    price           NUMERIC(12,2) NOT NULL CHECK (price > 0),
    currency        TEXT NOT NULL DEFAULT 'RUB',
    stock           INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0),
    stock_reserved  INTEGER NOT NULL DEFAULT 0 CHECK (stock_reserved >= 0),
    unit            TEXT DEFAULT 'шт',
    weight_g        INTEGER,
    dimensions_mm   JSONB,                     -- {"l":250,"w":120,"h":80}
    shipping_zones  TEXT[] DEFAULT '{MSK}',
    visible_shop    BOOLEAN NOT NULL DEFAULT TRUE,
    visible_catalog BOOLEAN NOT NULL DEFAULT TRUE,
    status          TEXT NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','MODERATION','ACTIVE','OUT_OF_STOCK','ARCHIVED','REJECTED','BLOCKED')),
    moderation_status TEXT DEFAULT 'PENDING' CHECK (moderation_status IN ('PENDING','AUTO_APPROVED','MANUAL_APPROVED','REJECTED')),
    moderation_confidence NUMERIC(3,2),
    rating          NUMERIC(3,2) DEFAULT 0.00,
    reviews_count   INTEGER DEFAULT 0,
    orders_count    INTEGER DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Инвариант И4 (ст. 9.4): visible_catalog=true → visible_shop=true
    CONSTRAINT chk_visibility CHECK (NOT (visible_catalog = TRUE AND visible_shop = FALSE))
);
CREATE INDEX idx_skus_seller ON skus(seller_id);
CREATE INDEX idx_skus_shop ON skus(shop_id);
CREATE INDEX idx_skus_category ON skus(category_id);
CREATE INDEX idx_skus_status ON skus(status) WHERE status = 'ACTIVE';
-- Для полнотекстового поиска (до подключения Elasticsearch)
CREATE INDEX idx_skus_search ON skus USING gin(to_tsvector('russian', title || ' ' || COALESCE(description,'')));

-- 7. Покупатели и привязка к базе (ст. 10 — клиентская база)
CREATE TABLE customers (
    id              TEXT PRIMARY KEY,
    phone           TEXT UNIQUE,
    name            TEXT,
    email           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE customer_bindings (
    id              TEXT PRIMARY KEY,
    customer_id     TEXT NOT NULL REFERENCES customers(id),
    seller_id       TEXT NOT NULL REFERENCES participants(id),
    source_type     TEXT NOT NULL CHECK (source_type IN ('MIGRATED','NETWORK')),  -- ст. 10.4
    first_order_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    orders_count    INTEGER DEFAULT 1,
    total_gmv       NUMERIC(12,2) DEFAULT 0,
    UNIQUE(customer_id, seller_id)
);

-- 8. Заказы (ст. 6 — расчёты, эскроу, клиринг)
CREATE TABLE orders (
    id              TEXT PRIMARY KEY,          -- ORD-78431
    deal_id         TEXT,                      -- FK → Deal Engine (будущее)
    customer_id     TEXT NOT NULL REFERENCES customers(id),
    seller_id       TEXT NOT NULL REFERENCES participants(id),
    shop_id         TEXT NOT NULL REFERENCES shops(id),
    entry_point     TEXT NOT NULL CHECK (entry_point IN ('SHOP','CATALOG','CHANNEL','REFERRAL')),  -- ст. 10.4
    source_type     TEXT NOT NULL CHECK (source_type IN ('MIGRATED','NETWORK')),                   -- ст. 10.4
    shipping_address JSONB,
    total_goods     NUMERIC(12,2) NOT NULL,    -- сумма товаров
    total_delivery  NUMERIC(12,2) DEFAULT 0,   -- стоимость доставки
    total_amount    NUMERIC(12,2) NOT NULL,     -- итого покупателю
    payment_method  TEXT DEFAULT 'DIRECT' CHECK (payment_method IN ('DIRECT','ESCROW','SBP','CARD','CASH')),
    status          TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN (
        'PENDING','PAID','FULFILLING','SHIPPING','PENDING_ACCEPT',
        'CLEARING','COMPLETED','CANCELLED','DISPUTE','REFUNDED'
    )),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_orders_seller ON orders(seller_id);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_status ON orders(status);

CREATE TABLE order_items (
    id              TEXT PRIMARY KEY,
    order_id        TEXT NOT NULL REFERENCES orders(id),
    sku_id          TEXT NOT NULL REFERENCES skus(id),
    qty             INTEGER NOT NULL CHECK (qty > 0),
    price_at_order  NUMERIC(12,2) NOT NULL,    -- цена зафиксирована
    total           NUMERIC(12,2) NOT NULL
);
CREATE INDEX idx_order_items_order ON order_items(order_id);

-- 9. Клиринг / расщепление (ст. 6.7 — flow денег)
CREATE TABLE clearing_splits (
    id              TEXT PRIMARY KEY,
    order_id        TEXT NOT NULL REFERENCES orders(id),
    participant_id  TEXT NOT NULL REFERENCES participants(id),
    role            TEXT NOT NULL,              -- 'SELLER','FULFILLMENT','LOGISTICS','ORGANIZER'
    amount          NUMERIC(12,2) NOT NULL,
    tariff_ref      TEXT,                      -- ссылка на tariff_id
    calculation     TEXT,                      -- '3 × 200₽' — для прозрачности
    status          TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','RELEASED','FAILED')),
    released_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_splits_order ON clearing_splits(order_id);

-- 10. Отзывы (ст. 4.8 — рейтинг магазина)
CREATE TABLE reviews (
    id              TEXT PRIMARY KEY,
    sku_id          TEXT NOT NULL REFERENCES skus(id),
    customer_id     TEXT NOT NULL REFERENCES customers(id),
    order_id        TEXT NOT NULL REFERENCES orders(id),
    rating          INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
    text            TEXT,
    images          TEXT[] DEFAULT '{}',
    seller_reply    TEXT,
    status          TEXT NOT NULL DEFAULT 'PUBLISHED' CHECK (status IN ('PENDING','PUBLISHED','HIDDEN')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(order_id, sku_id)  -- один отзыв на заказ+товар (антиманипуляция ст. 11.6)
);

-- 11. Аудит-лог (неизменяемый)
CREATE TABLE audit_log (
    id              BIGSERIAL PRIMARY KEY,
    entity_type     TEXT NOT NULL,             -- 'ORDER','SKU','PARTICIPANT',...
    entity_id       TEXT NOT NULL,
    action          TEXT NOT NULL,             -- 'CREATED','UPDATED','STATUS_CHANGED',...
    actor_id        TEXT,                      -- кто сделал
    actor_role      TEXT,
    old_value       JSONB,
    new_value       JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_audit_entity ON audit_log(entity_type, entity_id);
CREATE INDEX idx_audit_time ON audit_log(created_at);

-- ============================================================
-- Триггер: автообновление updated_at
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_participants_updated BEFORE UPDATE ON participants FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_shops_updated BEFORE UPDATE ON shops FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_skus_updated BEFORE UPDATE ON skus FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_orders_updated BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- Триггер: автостатус OUT_OF_STOCK (ст. 9.4)
-- ============================================================
CREATE OR REPLACE FUNCTION auto_stock_status()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.stock = 0 AND NEW.stock_reserved = 0 AND NEW.status = 'ACTIVE' THEN
        NEW.status = 'OUT_OF_STOCK';
    ELSIF NEW.stock > 0 AND NEW.status = 'OUT_OF_STOCK' THEN
        NEW.status = 'ACTIVE';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_skus_stock BEFORE UPDATE ON skus FOR EACH ROW EXECUTE FUNCTION auto_stock_status();
