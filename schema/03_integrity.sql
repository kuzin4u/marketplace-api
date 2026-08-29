-- ============================================================
-- СПРИНТ 0 · Миграция 03 · Целостность
--
-- Закрывает шесть мест, где схема разрешала невозможное.
-- Найдены прогоном 01_schema.sql + 02_seed на PostgreSQL 16.
--
-- НЕ трогает структуру таблиц и не требует правок в коде:
-- добавляются только ограничения и триггеры. Работающее приложение
-- продолжает работать, если оно не записывало заведомо неверные данные.
--
-- Применение:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f schema/03_integrity.sql
--
-- Вся миграция в одной транзакции: либо применяется целиком,
-- либо не применяется вовсе. Повторный запуск безопасен:
-- уже существующие ограничения пропускаются.
-- ============================================================

BEGIN;

-- ============================================================
-- 0. ПРЕДПОЛЁТНАЯ ПРОВЕРКА
--
-- Ограничения ниже не встанут, если в базе уже есть данные,
-- которые их нарушают. Обычный ALTER сообщил бы про первую же
-- строку и остановился; этот блок показывает сразу всё, чтобы
-- не чинить по одному в семь заходов.
-- ============================================================
DO $$
DECLARE
    problems  TEXT := '';
    n         BIGINT;
BEGIN
    SELECT count(*) INTO n FROM skus WHERE stock_reserved > stock;
    IF n > 0 THEN
        problems := problems || format(E'\n  - товаров, где резерв больше остатка: %s', n);
    END IF;

    SELECT count(*) INTO n
    FROM (SELECT inn, role FROM participants GROUP BY 1,2 HAVING count(*) > 1) x;
    IF n > 0 THEN
        problems := problems || format(E'\n  - повторяющихся пар ИНН+роль у участников: %s', n);
    END IF;

    SELECT count(*) INTO n
    FROM (SELECT order_id, sku_id FROM order_items GROUP BY 1,2 HAVING count(*) > 1) x;
    IF n > 0 THEN
        problems := problems || format(E'\n  - дублирующихся позиций в заказах: %s', n);
    END IF;

    SELECT count(*) INTO n
    FROM orders
    WHERE total_amount <> total_goods + COALESCE(total_delivery, 0);
    IF n > 0 THEN
        problems := problems || format(E'\n  - заказов, где итог не равен товары+доставка: %s', n);
    END IF;

    SELECT count(*) INTO n
    FROM reviews r JOIN orders o ON o.id = r.order_id
    WHERE r.customer_id <> o.customer_id;
    IF n > 0 THEN
        problems := problems || format(E'\n  - отзывов от постороннего покупателя: %s', n);
    END IF;

    SELECT count(*) INTO n
    FROM reviews r
    WHERE NOT EXISTS (
        SELECT 1 FROM order_items oi
        WHERE oi.order_id = r.order_id AND oi.sku_id = r.sku_id
    );
    IF n > 0 THEN
        problems := problems || format(E'\n  - отзывов на товар, которого не было в заказе: %s', n);
    END IF;

    IF problems <> '' THEN
        -- в RAISE подстановка обозначается %, а не %s
        RAISE EXCEPTION E'Миграция остановлена: в базе есть данные, нарушающие новые правила.%\n\nПочините данные и повторите. Запросы для поиска нарушителей — в блоке 0 этого файла: замените count(*) на сами строки.', problems;
    END IF;

    RAISE NOTICE 'Предполётная проверка пройдена, нарушений нет.';
END $$;

-- ============================================================
-- 1. РЕЗЕРВ НЕ БОЛЬШЕ ОСТАТКА
--
-- Было: stock=5, stock_reserved=100 записывалось молча.
-- Резерв сверх остатка означает, что корзина пообещала товар,
-- которого нет, и обнаружится это при сборке заказа.
-- ============================================================
DO $$ BEGIN
    ALTER TABLE skus
        ADD CONSTRAINT chk_reserved_within_stock
        CHECK (stock_reserved <= stock);
EXCEPTION WHEN duplicate_object THEN
    RAISE NOTICE 'chk_reserved_within_stock уже есть, пропускаю';
END $$;

-- ============================================================
-- 2. ИНН НЕ ПОВТОРЯЕТСЯ В ПРЕДЕЛАХ РОЛИ
--
-- Было: два участника с одинаковым ИНН создавались свободно.
--
-- Уникальность по одному ИНН была бы неверной: у физлица и его ИП
-- ИНН совпадает, и один и тот же человек может быть в реестре
-- и продавцом, и оператором логистики. Уникальна пара ИНН+роль.
-- ============================================================
CREATE UNIQUE INDEX IF NOT EXISTS idx_participants_inn_role
    ON participants (inn, role);

-- ============================================================
-- 3. ПОЗИЦИЯ ТОВАРА В ЗАКАЗЕ НЕ ДУБЛИРУЕТСЯ
--
-- Было: один и тот же товар добавлялся в заказ дважды отдельными
-- строками. Количество должно расти в qty, а не размножать строки:
-- иначе клиринг и остатки считаются по-разному в разных местах.
-- ============================================================
DO $$ BEGIN
    ALTER TABLE order_items
        ADD CONSTRAINT uq_order_items_order_sku UNIQUE (order_id, sku_id);
EXCEPTION WHEN duplicate_table OR duplicate_object THEN
    RAISE NOTICE 'uq_order_items_order_sku уже есть, пропускаю';
END $$;

-- ============================================================
-- 4. АРИФМЕТИКА ЗАКАЗА
--
-- Было: заказ на товары в 100 рублей с итогом 999 999 записывался.
--
-- Проверяется только сходимость в пределах строки. Равенство
-- total_goods сумме позиций — задача 0.1: там заказ распадается
-- на родительский и подзаказы, и проверять надо будет иначе.
-- ============================================================
DO $$ BEGIN
    ALTER TABLE orders
        ADD CONSTRAINT chk_order_totals
        CHECK (total_amount = total_goods + COALESCE(total_delivery, 0));
EXCEPTION WHEN duplicate_object THEN
    RAISE NOTICE 'chk_order_totals уже есть, пропускаю';
END $$;

DO $$ BEGIN
    ALTER TABLE orders
        ADD CONSTRAINT chk_order_amounts_positive
        CHECK (total_goods >= 0 AND COALESCE(total_delivery, 0) >= 0);
EXCEPTION WHEN duplicate_object THEN
    RAISE NOTICE 'chk_order_amounts_positive уже есть, пропускаю';
END $$;

-- ============================================================
-- 5. ОТЗЫВ ТОЛЬКО ОТ УЧАСТНИКА СДЕЛКИ
--
-- Было: посторонний покупатель оставлял отзыв на чужой заказ,
-- и даже на товар, которого в том заказе не было.
--
-- Ограничением CHECK это не выражается — нужен запрос к другим
-- таблицам, поэтому триггер.
-- ============================================================
CREATE OR REPLACE FUNCTION check_review_authenticity()
RETURNS TRIGGER AS $$
DECLARE
    order_customer TEXT;
BEGIN
    SELECT customer_id INTO order_customer FROM orders WHERE id = NEW.order_id;

    IF order_customer IS NULL THEN
        RAISE EXCEPTION 'Отзыв ссылается на несуществующий заказ %', NEW.order_id;
    END IF;

    IF order_customer <> NEW.customer_id THEN
        RAISE EXCEPTION 'Отзыв на заказ % оставлен покупателем %, а заказ принадлежит %',
            NEW.order_id, NEW.customer_id, order_customer;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM order_items
        WHERE order_id = NEW.order_id AND sku_id = NEW.sku_id
    ) THEN
        RAISE EXCEPTION 'Товара % не было в заказе %', NEW.sku_id, NEW.order_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_reviews_authenticity ON reviews;
CREATE TRIGGER trg_reviews_authenticity
    BEFORE INSERT OR UPDATE ON reviews
    FOR EACH ROW EXECUTE FUNCTION check_review_authenticity();

-- ============================================================
-- 6. АУДИТ-ЛОГ ДЕЙСТВИТЕЛЬНО НЕИЗМЕНЯЕМЫЙ
--
-- Было: таблица помечена комментарием «неизменяемый», но UPDATE
-- и DELETE проходили без препятствий. Комментарий создавал
-- ощущение гарантии, которой не было.
--
-- Это важнее остальных пунктов: на журнал будут ссылаться
-- при разборе споров, и запись, которую можно поправить задним
-- числом, доказательством не является.
--
-- Защита от приложения и от случайной ошибки. Владелец базы
-- по-прежнему может удалить триггер — от него защищают права
-- доступа, а не схема.
-- ============================================================
CREATE OR REPLACE FUNCTION deny_audit_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Аудит-лог неизменяем: операция % запрещена', TG_OP;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_audit_no_update ON audit_log;
CREATE TRIGGER trg_audit_no_update
    BEFORE UPDATE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION deny_audit_mutation();

DROP TRIGGER IF EXISTS trg_audit_no_delete ON audit_log;
CREATE TRIGGER trg_audit_no_delete
    BEFORE DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION deny_audit_mutation();

-- Построчный триггер на пустой таблице не срабатывает: DELETE без строк
-- проходит молча. Это не дыра, удалять нечего — но при проверке защиты
-- следите, чтобы в журнале была хотя бы одна запись.

-- Хранение журнала не вечное: когда появится политика сроков
-- (задача В.2, сроки хранения по категориям данных), удаление
-- старых записей делается отключением триггера в обслуживающей
-- процедуре, а не отменой правила.

-- ============================================================
-- 7. АВТОСТАТУС ОСТАТКА РАБОТАЕТ И ПРИ СОЗДАНИИ ТОВАРА
--
-- Было: триггер висел только на UPDATE. Товар, созданный сразу
-- с нулевым остатком и статусом ACTIVE, таким и оставался —
-- попадал в витрину, продавался, а собрать его было нечем.
-- ============================================================
DROP TRIGGER IF EXISTS trg_skus_stock ON skus;

CREATE TRIGGER trg_skus_stock
    BEFORE INSERT OR UPDATE ON skus
    FOR EACH ROW EXECUTE FUNCTION auto_stock_status();

COMMIT;

-- ============================================================
-- ЧЕГО ЭТА МИГРАЦИЯ НЕ ДЕЛАЕТ
--
-- Осознанно отложено до задачи 0.1, где меняется структура заказа:
--
--   - равенство total_goods сумме позиций заказа;
--   - равенство суммы расщепления сумме заказа;
--   - подзаказы (родительский заказ + дочерние по числу продавцов);
--   - таблица согласий;
--   - перевод денежных полей в копейки целым числом (задача 0.2).
--
-- Первые два требуют отложенной проверки на момент фиксации
-- транзакции: заказ вставляется раньше своих позиций, и обычный
-- триггер сработал бы до того, как позиции появились.
-- ============================================================
