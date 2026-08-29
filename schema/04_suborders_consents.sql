-- ============================================================
-- СПРИНТ 0 · Миграция 04 · Задача 0.1
--
-- Три изменения, которые нельзя делать по отдельности, потому что
-- все три трогают заказ:
--
--   1. ПОДЗАКАЗЫ. Заказ распадается на родительский и дочерние
--      по числу продавцов. Основа мультипродавцовой корзины.
--   2. СОГЛАСИЯ. Неизменяемая запись факта согласия покупателя.
--      Единственная необратимая часть плана: согласие, записанное
--      неверно, нельзя исправить задним числом.
--   3. КОПЕЙКИ (задача 0.2). Денежные поля переходят в целые
--      копейки. Делается здесь же, чтобы не переносить историю
--      дважды.
--
-- Плюс уровень участия со шкалой 2–7 и храповиком по сделке.
--
-- ПРИМЕНЯЕТСЯ ПОСЛЕ 01, 02, 03.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f schema/04_suborders_consents.sql
--
-- ВНИМАНИЕ: миграция ломает контракт API. Из orders уезжают
-- seller_id и shop_id, order_items переезжают на подзаказ.
-- Код обновляется в задаче 0.3. До этого оставлено совместимое
-- представление orders_flat — см. блок 9.
-- ============================================================

BEGIN;

-- ============================================================
-- 0. ПРЕДПОЛЁТНАЯ ПРОВЕРКА
--
-- Главный риск — деньги. Рубли с копейками переводятся в целые
-- копейки умножением на сто; если в базе есть суммы с долями
-- копейки, умножение даст дробь, и округление молча изменит
-- сумму. Такое надо увидеть до, а не после.
-- ============================================================
DO $$
DECLARE
    problems TEXT := '';
    n        BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema='public' AND table_name='suborders') THEN
        RAISE EXCEPTION 'Миграция 04 уже применена: таблица suborders существует.';
    END IF;

    SELECT count(*) INTO n FROM skus WHERE price * 100 <> round(price * 100);
    IF n > 0 THEN problems := problems || format(E'\n  - товаров с дробной копейкой в цене: %s', n); END IF;

    SELECT count(*) INTO n FROM orders
    WHERE total_goods*100 <> round(total_goods*100)
       OR total_amount*100 <> round(total_amount*100)
       OR COALESCE(total_delivery,0)*100 <> round(COALESCE(total_delivery,0)*100);
    IF n > 0 THEN problems := problems || format(E'\n  - заказов с дробной копейкой: %s', n); END IF;

    SELECT count(*) INTO n FROM order_items
    WHERE price_at_order*100 <> round(price_at_order*100) OR total*100 <> round(total*100);
    IF n > 0 THEN problems := problems || format(E'\n  - позиций заказа с дробной копейкой: %s', n); END IF;

    SELECT count(*) INTO n FROM clearing_splits
    WHERE amount*100 <> round(amount*100);
    IF n > 0 THEN problems := problems || format(E'\n  - строк расщепления с дробной копейкой: %s', n); END IF;

    -- заказ без магазина мигрировать в подзаказ нечем
    SELECT count(*) INTO n FROM orders WHERE seller_id IS NULL OR shop_id IS NULL;
    IF n > 0 THEN problems := problems || format(E'\n  - заказов без продавца или магазина: %s', n); END IF;

    IF problems <> '' THEN
        RAISE EXCEPTION E'Миграция остановлена.%\n\nДробные копейки округлять автоматически нельзя: это изменение сумм в уже закрытых сделках. Разберите каждый случай вручную.', problems;
    END IF;

    RAISE NOTICE 'Предполётная проверка пройдена.';
END $$;

-- ============================================================
-- 1. УРОВЕНЬ УЧАСТИЯ (шкала 2–7)
--
-- Уровень настраивается магазином и может меняться в обе стороны.
-- Но у совершённой сделки уровень зафиксирован храповиком:
-- понизить его задним числом нельзя, потому что от уровня зависит
-- состав услуг и расчёт. Иначе можно было бы «удешевить» уже
-- проведённую сделку, изменив настройку магазина.
-- ============================================================
ALTER TABLE shops
    ADD COLUMN participation_level SMALLINT NOT NULL DEFAULT 2
        CHECK (participation_level BETWEEN 2 AND 7);

COMMENT ON COLUMN shops.participation_level IS
    'Глубина участия, 2–7. Меняется в обе стороны. На сделку переносится в момент её создания.';

-- ============================================================
-- 2. СОГЛАСИЯ (ст. 23 — Система как оператор персональных данных)
--
-- Записи неизменяемы. Отзыв согласия — не правка старой записи,
-- а НОВАЯ запись с action='WITHDRAWN': историю согласий нужно
-- уметь предъявить целиком, включая то, что было отозвано.
--
-- text_hash хранит отпечаток текста, на который согласился
-- покупатель. Сам текст версионируется отдельно; хеш доказывает,
-- что предъявляемая сейчас редакция — та самая.
-- ============================================================
CREATE TABLE consents (
    id              TEXT PRIMARY KEY,
    customer_id     TEXT NOT NULL REFERENCES customers(id),
    action          TEXT NOT NULL CHECK (action IN ('GIVEN','WITHDRAWN')),
    purpose         TEXT NOT NULL CHECK (purpose IN (
                        'ORDER_PROCESSING',   -- обработка заказа
                        'DELIVERY',           -- передача оператору доставки
                        'MARKETING',          -- рассылки
                        'REVIEWS'             -- публикация отзывов
                    )),
    policy_version  TEXT NOT NULL,            -- редакция политики, напр. '2026-08-01'
    text_hash       TEXT NOT NULL,            -- sha256 текста, на который согласились
    channel         TEXT NOT NULL CHECK (channel IN ('SHOP','CATALOG','CHANNEL','AGENT','OFFLINE')),
    source_ip       INET,
    user_agent      TEXT,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    supersedes_id   TEXT REFERENCES consents(id)   -- какую запись отзывает
);
CREATE INDEX idx_consents_customer ON consents(customer_id, purpose, recorded_at DESC);

CREATE OR REPLACE FUNCTION deny_consent_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Запись согласия неизменяема: операция % запрещена. Отзыв согласия оформляется новой записью с action=WITHDRAWN.', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_consents_no_update BEFORE UPDATE ON consents
    FOR EACH ROW EXECUTE FUNCTION deny_consent_mutation();
CREATE TRIGGER trg_consents_no_delete BEFORE DELETE ON consents
    FOR EACH ROW EXECUTE FUNCTION deny_consent_mutation();

-- Отзыв обязан ссылаться на то, что отзывает; выдача — не обязана.
CREATE OR REPLACE FUNCTION check_consent_shape()
RETURNS TRIGGER AS $$
DECLARE
    prior consents%ROWTYPE;
BEGIN
    IF NEW.action = 'WITHDRAWN' THEN
        IF NEW.supersedes_id IS NULL THEN
            RAISE EXCEPTION 'Отзыв согласия должен ссылаться на отзываемую запись (supersedes_id)';
        END IF;
        SELECT * INTO prior FROM consents WHERE id = NEW.supersedes_id;
        IF prior.customer_id <> NEW.customer_id THEN
            RAISE EXCEPTION 'Отзыв оформлен от имени другого покупателя';
        END IF;
        IF prior.action <> 'GIVEN' THEN
            RAISE EXCEPTION 'Отзывать можно только выданное согласие';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_consents_shape BEFORE INSERT ON consents
    FOR EACH ROW EXECUTE FUNCTION check_consent_shape();

-- ============================================================
-- 3. ПОДЗАКАЗЫ
--
-- orders становится родительским: покупатель, точка входа, итог,
-- оплата. Всё, что относится к конкретному продавцу, уезжает
-- в suborders.
-- ============================================================
CREATE TABLE suborders (
    id                  TEXT PRIMARY KEY,             -- ORD-00001-1
    order_id            TEXT NOT NULL REFERENCES orders(id),
    seller_id           TEXT NOT NULL REFERENCES participants(id),
    shop_id             TEXT NOT NULL REFERENCES shops(id),
    participation_level SMALLINT NOT NULL CHECK (participation_level BETWEEN 2 AND 7),
    total_goods_kop     BIGINT NOT NULL CHECK (total_goods_kop >= 0),
    total_delivery_kop  BIGINT NOT NULL DEFAULT 0 CHECK (total_delivery_kop >= 0),
    total_amount_kop    BIGINT NOT NULL CHECK (total_amount_kop >= 0),
    status              TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN (
                            'PENDING','PAID','FULFILLING','SHIPPING','PENDING_ACCEPT',
                            'CLEARING','COMPLETED','CANCELLED','DISPUTE','REFUNDED')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_suborder_totals
        CHECK (total_amount_kop = total_goods_kop + total_delivery_kop),
    CONSTRAINT uq_suborder_order_seller UNIQUE (order_id, seller_id)
);
CREATE INDEX idx_suborders_order ON suborders(order_id);
CREATE INDEX idx_suborders_seller ON suborders(seller_id);
CREATE INDEX idx_suborders_status ON suborders(status);

CREATE TRIGGER trg_suborders_updated BEFORE UPDATE ON suborders
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- Храповик: уровень участия сделки не понижается.
CREATE OR REPLACE FUNCTION check_level_ratchet()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.participation_level < OLD.participation_level THEN
        RAISE EXCEPTION 'Уровень участия сделки % нельзя понизить с % до %',
            OLD.id, OLD.participation_level, NEW.participation_level;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_suborders_ratchet BEFORE UPDATE ON suborders
    FOR EACH ROW EXECUTE FUNCTION check_level_ratchet();

-- ============================================================
-- 4. ДЕНЬГИ В КОПЕЙКАХ
--
-- Целое число копеек вместо NUMERIC в рублях. Причина не в месте
-- на диске, а в том, что дробные типы складываются с потерей:
-- расщепление на три участника из суммы в рублях может не сойтись
-- с исходной суммой на копейку, и это всплывёт в ежедневной сверке.
--
-- Единица вынесена в имя поля: price_kop нельзя случайно принять
-- за рубли, в отличие от price.
-- ============================================================

-- 4.1 Товары
ALTER TABLE skus ADD COLUMN price_kop BIGINT;
UPDATE skus SET price_kop = round(price * 100)::BIGINT;
ALTER TABLE skus
    ALTER COLUMN price_kop SET NOT NULL,
    ADD CONSTRAINT chk_price_kop_positive CHECK (price_kop > 0);
ALTER TABLE skus DROP COLUMN price;

-- 4.2 Заказы. seller_id и shop_id уезжают в подзаказ.
ALTER TABLE orders
    ADD COLUMN total_goods_kop    BIGINT,
    ADD COLUMN total_delivery_kop BIGINT,
    ADD COLUMN total_amount_kop   BIGINT,
    ADD COLUMN consent_status     TEXT NOT NULL DEFAULT 'PRE_CONSENT'
        CHECK (consent_status IN ('PRE_CONSENT','RECORDED')),
    ADD COLUMN consent_id         TEXT REFERENCES consents(id);

COMMENT ON COLUMN orders.consent_status IS
    'PRE_CONSENT — заказ создан до введения согласий (перенос истории пилота). RECORDED — согласие записано, consent_id заполнен.';

UPDATE orders SET
    total_goods_kop    = round(total_goods * 100)::BIGINT,
    total_delivery_kop = round(COALESCE(total_delivery,0) * 100)::BIGINT,
    total_amount_kop   = round(total_amount * 100)::BIGINT;

ALTER TABLE orders
    ALTER COLUMN total_goods_kop SET NOT NULL,
    ALTER COLUMN total_delivery_kop SET NOT NULL,
    ALTER COLUMN total_amount_kop SET NOT NULL;

-- 4.3 Позиции заказа переезжают на подзаказ
ALTER TABLE order_items
    ADD COLUMN suborder_id       TEXT,
    ADD COLUMN price_at_order_kop BIGINT,
    ADD COLUMN total_kop          BIGINT;

UPDATE order_items SET
    price_at_order_kop = round(price_at_order * 100)::BIGINT,
    total_kop          = round(total * 100)::BIGINT;

-- 4.4 Расщепление
ALTER TABLE clearing_splits
    ADD COLUMN suborder_id TEXT,
    ADD COLUMN amount_kop  BIGINT;
UPDATE clearing_splits SET amount_kop = round(amount * 100)::BIGINT;

-- 4.5 Оборот покупателя
ALTER TABLE customer_bindings ADD COLUMN total_gmv_kop BIGINT;
UPDATE customer_bindings SET total_gmv_kop = round(COALESCE(total_gmv,0) * 100)::BIGINT;
ALTER TABLE customer_bindings
    ALTER COLUMN total_gmv_kop SET NOT NULL,
    DROP COLUMN total_gmv;

-- 4.6 Тарифы: денежные ставки и процентные — разные величины
--
-- rate=0.20 при unit='PERCENT' означает 0.2 процента, а при
-- unit='PER_ITEM' — двадцать копеек. Одной колонкой это не выразить
-- без постоянной путаницы, поэтому их две. Проценты хранятся
-- в базисных пунктах: 0.2% = 20 б.п., 12.5% = 1250 б.п.
ALTER TABLE participant_tariffs
    ADD COLUMN rate_kop BIGINT,
    ADD COLUMN rate_bp  INTEGER;

UPDATE participant_tariffs
SET rate_kop = CASE WHEN unit <> 'PERCENT' THEN round(rate * 100)::BIGINT END,
    rate_bp  = CASE WHEN unit =  'PERCENT' THEN round(rate * 100)::INTEGER END;

ALTER TABLE participant_tariffs
    ADD CONSTRAINT chk_tariff_rate_shape CHECK (
        (unit =  'PERCENT' AND rate_bp  IS NOT NULL AND rate_kop IS NULL) OR
        (unit <> 'PERCENT' AND rate_kop IS NOT NULL AND rate_bp  IS NULL)
    );
ALTER TABLE participant_tariffs DROP COLUMN rate;
ALTER TABLE participant_tariffs DROP COLUMN min_amount;
ALTER TABLE participant_tariffs ADD COLUMN min_amount_kop BIGINT DEFAULT 0;

-- ============================================================
-- 5. ПЕРЕНОС СУЩЕСТВУЮЩИХ ЗАКАЗОВ В ПОДЗАКАЗЫ
--
-- Каждый существующий заказ становится родительским с ровно одним
-- подзаказом: продавец у него был один. Идентификатор подзаказа —
-- идентификатор заказа с суффиксом -1.
-- ============================================================
INSERT INTO suborders (
    id, order_id, seller_id, shop_id, participation_level,
    total_goods_kop, total_delivery_kop, total_amount_kop, status, created_at
)
SELECT
    o.id || '-1', o.id, o.seller_id, o.shop_id,
    COALESCE(s.participation_level, 2),
    o.total_goods_kop, o.total_delivery_kop, o.total_amount_kop,
    o.status, o.created_at
FROM orders o
JOIN shops s ON s.id = o.shop_id;

UPDATE order_items oi SET suborder_id = oi.order_id || '-1';
UPDATE clearing_splits cs SET suborder_id = cs.order_id || '-1';

-- ============================================================
-- 6. ЗАКРЕПЛЕНИЕ НОВЫХ СВЯЗЕЙ
-- ============================================================
ALTER TABLE order_items
    ALTER COLUMN suborder_id SET NOT NULL,
    ALTER COLUMN price_at_order_kop SET NOT NULL,
    ALTER COLUMN total_kop SET NOT NULL,
    ADD CONSTRAINT fk_order_items_suborder
        FOREIGN KEY (suborder_id) REFERENCES suborders(id),
    DROP COLUMN price_at_order,
    DROP COLUMN total,
    DROP COLUMN order_id;

ALTER TABLE order_items
    ADD CONSTRAINT uq_order_items_suborder_sku UNIQUE (suborder_id, sku_id);
CREATE INDEX idx_order_items_suborder ON order_items(suborder_id);

ALTER TABLE clearing_splits
    ALTER COLUMN suborder_id SET NOT NULL,
    ALTER COLUMN amount_kop SET NOT NULL,
    ADD CONSTRAINT fk_splits_suborder
        FOREIGN KEY (suborder_id) REFERENCES suborders(id),
    DROP COLUMN amount,
    DROP COLUMN order_id;
CREATE INDEX idx_splits_suborder ON clearing_splits(suborder_id);

-- Отзыв относится к подзаказу: продавец у товара один.
--
-- ВАЖНО: миграция 03 создала триггер проверки подлинности отзыва,
-- который читал reviews.order_id и order_items.order_id. Обе колонки
-- здесь исчезают, и триггер сломался бы на первом же отзыве.
-- Переписываем его на подзаказ.
CREATE OR REPLACE FUNCTION check_review_authenticity()
RETURNS TRIGGER AS $$
DECLARE
    order_customer TEXT;
BEGIN
    SELECT o.customer_id INTO order_customer
    FROM suborders s JOIN orders o ON o.id = s.order_id
    WHERE s.id = NEW.suborder_id;

    IF order_customer IS NULL THEN
        RAISE EXCEPTION 'Отзыв ссылается на несуществующий подзаказ %', NEW.suborder_id;
    END IF;

    IF order_customer <> NEW.customer_id THEN
        RAISE EXCEPTION 'Отзыв на подзаказ % оставлен покупателем %, а заказ принадлежит %',
            NEW.suborder_id, NEW.customer_id, order_customer;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM order_items
        WHERE suborder_id = NEW.suborder_id AND sku_id = NEW.sku_id
    ) THEN
        RAISE EXCEPTION 'Товара % не было в подзаказе %', NEW.sku_id, NEW.suborder_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

ALTER TABLE reviews ADD COLUMN suborder_id TEXT;
UPDATE reviews SET suborder_id = order_id || '-1';
ALTER TABLE reviews
    ALTER COLUMN suborder_id SET NOT NULL,
    ADD CONSTRAINT fk_reviews_suborder
        FOREIGN KEY (suborder_id) REFERENCES suborders(id),
    DROP COLUMN order_id;
ALTER TABLE reviews ADD CONSTRAINT uq_reviews_suborder_sku UNIQUE (suborder_id, sku_id);

-- Родительский заказ больше не знает про продавца
ALTER TABLE orders
    DROP COLUMN seller_id,
    DROP COLUMN shop_id,
    DROP COLUMN total_goods,
    DROP COLUMN total_delivery,
    DROP COLUMN total_amount;

-- ============================================================
-- 7. ОТЛОЖЕННЫЕ ПРОВЕРКИ СХОДИМОСТИ
--
-- Эти равенства нельзя проверять построчно: подзаказ вставляется
-- раньше своих позиций, и обычный триггер сработал бы, когда
-- позиций ещё нет. Отложенный триггер срабатывает на фиксации
-- транзакции, когда картина уже полная.
--
-- Отсюда требование к коду: заказ и его позиции пишутся в ОДНОЙ
-- транзакции. Иначе фиксация упадёт.
-- ============================================================
CREATE OR REPLACE FUNCTION check_suborder_sums()
RETURNS TRIGGER AS $$
DECLARE
    sub_id    TEXT;
    items_sum BIGINT;
    declared  BIGINT;
BEGIN
    sub_id := COALESCE(NEW.suborder_id, OLD.suborder_id);

    SELECT total_goods_kop INTO declared FROM suborders WHERE id = sub_id;
    IF declared IS NULL THEN RETURN NULL; END IF;   -- подзаказ удалён

    SELECT COALESCE(sum(total_kop), 0) INTO items_sum
    FROM order_items WHERE suborder_id = sub_id;

    IF items_sum <> declared THEN
        RAISE EXCEPTION 'Подзаказ %: сумма позиций % коп. не равна заявленной % коп.',
            sub_id, items_sum, declared;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_suborder_sums
    AFTER INSERT OR UPDATE OR DELETE ON order_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_suborder_sums();

-- Позиция должна стоить qty × цену
ALTER TABLE order_items
    ADD CONSTRAINT chk_item_total CHECK (total_kop = qty * price_at_order_kop);

-- Итог родительского заказа равен сумме подзаказов
CREATE OR REPLACE FUNCTION check_order_sums()
RETURNS TRIGGER AS $$
DECLARE
    ord_id   TEXT;
    subs_sum BIGINT;
    declared BIGINT;
BEGIN
    ord_id := COALESCE(NEW.order_id, OLD.order_id);

    SELECT total_amount_kop INTO declared FROM orders WHERE id = ord_id;
    IF declared IS NULL THEN RETURN NULL; END IF;

    SELECT COALESCE(sum(total_amount_kop), 0) INTO subs_sum
    FROM suborders WHERE order_id = ord_id;

    IF subs_sum <> declared THEN
        RAISE EXCEPTION 'Заказ %: сумма подзаказов % коп. не равна заявленной % коп.',
            ord_id, subs_sum, declared;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_order_sums
    AFTER INSERT OR UPDATE OR DELETE ON suborders
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_order_sums();

-- ============================================================
-- 8. СОГЛАСИЕ ОБЯЗАТЕЛЬНО ДЛЯ НОВЫХ ЗАКАЗОВ
--
-- Признак PRE_CONSENT предназначен только для истории, перенесённой
-- из прежнего хранилища. Новый заказ обязан ссылаться на согласие.
-- ============================================================
CREATE OR REPLACE FUNCTION check_order_consent()
RETURNS TRIGGER AS $$
DECLARE
    c consents%ROWTYPE;
BEGIN
    -- PRE_CONSENT разрешён только внутри переноса истории, и перенос
    -- обязан объявить себя явно:
    --     SET LOCAL app.history_migration = 'on';
    -- Проверка по времени создания заказа не годится: дату можно
    -- подставить любую, и запрет обошёлся бы одной строкой.
    IF NEW.consent_status = 'PRE_CONSENT' THEN
        IF COALESCE(current_setting('app.history_migration', TRUE), 'off') <> 'on' THEN
            RAISE EXCEPTION 'Признак PRE_CONSENT допустим только при переносе истории. Новый заказ требует записанного согласия.';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.consent_id IS NULL THEN
        RAISE EXCEPTION 'consent_status=RECORDED требует заполненного consent_id';
    END IF;

    SELECT * INTO c FROM consents WHERE id = NEW.consent_id;
    IF c.customer_id <> NEW.customer_id THEN
        RAISE EXCEPTION 'Согласие % принадлежит другому покупателю', NEW.consent_id;
    END IF;
    IF c.action <> 'GIVEN' THEN
        RAISE EXCEPTION 'Заказ не может ссылаться на отозванное согласие';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_orders_consent BEFORE INSERT OR UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION check_order_consent();

-- Перенесённая история помечается признаком явно.
-- SET LOCAL действует до конца транзакции миграции и дальше не живёт.
SET LOCAL app.history_migration = 'on';
UPDATE orders SET consent_status = 'PRE_CONSENT' WHERE consent_id IS NULL;

-- ============================================================
-- 9. СОВМЕСТИМОЕ ПРЕДСТАВЛЕНИЕ
--
-- Временная опора для кода, который ещё ждёт seller_id и shop_id
-- в заказе. Работает, пока у заказа один подзаказ. Убирается
-- в задаче 0.3, когда слой доступа переписан на подзаказы.
-- ============================================================
CREATE VIEW orders_flat AS
SELECT
    o.id, o.customer_id,
    s.seller_id, s.shop_id,
    o.entry_point, o.source_type, o.shipping_address,
    s.total_goods_kop, s.total_delivery_kop, s.total_amount_kop,
    o.payment_method, o.status, o.consent_status,
    o.created_at, o.updated_at,
    s.id AS suborder_id, s.participation_level
FROM orders o
JOIN suborders s ON s.order_id = o.id;

COMMENT ON VIEW orders_flat IS
    'Совместимость на время задачи 0.3. Для заказа с несколькими продавцами вернёт по строке на продавца.';

COMMIT;
