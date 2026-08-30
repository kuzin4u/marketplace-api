-- ============================================================
-- СПРИНТ 0 · Миграция 06 · Шкала уровней участия
--
-- Приводит данные к решению «Шкала уровней участия · принятое
-- решение» (23.08.2026) и к статьям 9.11–9.13, 6.11 Правил ред. 3.
--
-- Что меняется против миграции 04:
--
--   1. СОСТАВ ВМЕСТО ЧИСЛА. Глубина перестаёт быть настройкой
--      и становится вычисляемой величиной: продавец выбирает
--      сервисы, число выводится из состава. «Число продавцу
--      не показывается» — оно служебное, для расчёта и проверки.
--
--   2. ПРОВЕРКА ПЕРЕЕЗЖАЕТ. В 04 храповик стоял только на UPDATE
--      подзаказа. По решению проверка должна выполняться ПРИ
--      СОЗДАНИИ заказа и сравнивать уровень сделки с конфигурацией
--      на тот момент, а не с прежним значением.
--
--   3. СНИМОК КОНФИГУРАЦИИ. Без него сравнивать не с чем, а прошлые
--      заказы начинают пересчитываться после правки настроек.
--      Решение называет это условием работы проверки, а связанный
--      тест — важнейшим из всех.
--
--   4. ВЕРСИЯ ШКАЛЫ. Прежние шкалы отменены: линейка с убыванием
--      и ранг конфигуратора от нуля. Без пометки версии через
--      полгода неясно, что означала цифра три.
--
-- ПРИМЕНЯЕТСЯ ПОСЛЕ 05.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f schema/06_participation_scale.sql
-- ============================================================

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='suborders') THEN
        RAISE EXCEPTION 'Сначала примените миграцию 04.';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='shops' AND column_name='svc_catalog') THEN
        RAISE EXCEPTION 'Миграция 06 уже применена.';
    END IF;
END $$;

-- ============================================================
-- 1. ФОРМУЛА ГЛУБИНЫ
--
--   расчёт через Систему   +2   всегда после решения о едином расчёте
--   исполнение полностью   +2   все звенья отданы операторам
--   исполнение частично    +1   часть звеньев, каким бы ни был набор
--   витрина в Системе      +1   своя витрина прибавки не даёт
--   каталог Системы        +1
--   агент                  +1   требует включённого каталога
--
-- Отсюда диапазон 2–7: нижняя граница два, а не ноль, потому что
-- расчёт через Систему есть всегда.
--
-- Почему расчёт весит вдвое: он единственный, что нельзя взять
-- частично, и единственный, что даёт покупателю гарантию.
-- ============================================================
CREATE OR REPLACE FUNCTION participation_depth(
    execution   TEXT,      -- 'NONE' | 'PARTIAL' | 'FULL'
    storefront  BOOLEAN,   -- витрина в Системе
    catalog     BOOLEAN,   -- виден в каталоге Системы
    agent       BOOLEAN    -- доступен агенту
) RETURNS SMALLINT
LANGUAGE sql IMMUTABLE AS $$
    SELECT (2                                             -- расчёт через Систему
        + CASE execution WHEN 'FULL' THEN 2
                         WHEN 'PARTIAL' THEN 1
                         ELSE 0 END
        + CASE WHEN storefront THEN 1 ELSE 0 END
        + CASE WHEN catalog    THEN 1 ELSE 0 END
        + CASE WHEN agent      THEN 1 ELSE 0 END)::SMALLINT;
$$;

COMMENT ON FUNCTION participation_depth IS
    'Глубина участия по шкале версии 3 (возрастающая, 2–7). Решение от 23.08.2026.';

-- ============================================================
-- 2. СОСТАВ СЕРВИСОВ В КОНФИГУРАЦИИ МАГАЗИНА
--
-- Уровень больше не задаётся числом напрямую: продавец включает
-- и выключает звенья, число выводится. Так исключается состояние,
-- когда число не соответствует фактическому составу.
-- ============================================================
ALTER TABLE shops
    ADD COLUMN svc_execution  TEXT NOT NULL DEFAULT 'NONE'
        CHECK (svc_execution IN ('NONE','PARTIAL','FULL')),
    ADD COLUMN svc_storefront BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN svc_catalog    BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN svc_agent      BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN scale_version  SMALLINT NOT NULL DEFAULT 3;

-- Агент требует включённого каталога — прямо из таблицы прибавок.
ALTER TABLE shops
    ADD CONSTRAINT chk_agent_needs_catalog
    CHECK (NOT (svc_agent AND NOT svc_catalog));

-- Переносим то, что было записано числом в миграции 04.
-- Пилот: витрина в Системе есть, каталог включён, исполнение своё.
UPDATE shops SET svc_storefront = TRUE,
                 svc_catalog    = TRUE,
                 svc_execution  = 'NONE',
                 svc_agent      = FALSE;

-- Глубина становится вычисляемой. Рассогласовать состав и число
-- теперь невозможно: колонка не принимает запись.
ALTER TABLE shops DROP COLUMN participation_level;
ALTER TABLE shops
    ADD COLUMN participation_level SMALLINT
    GENERATED ALWAYS AS (
        participation_depth(svc_execution, svc_storefront, svc_catalog, svc_agent)
    ) STORED;

COMMENT ON COLUMN shops.participation_level IS
    'Служебная величина, выводится из состава сервисов. Продавцу не показывается — в интерфейсе только названия схем.';

-- ============================================================
-- 3. СНИМОК КОНФИГУРАЦИИ В СДЕЛКЕ
--
-- Условие работы проверки, а не украшение: сравнивать уровень
-- сделки не с чем, если конфигурация на момент создания не
-- сохранена. И защита истории — ст. 9.12: изменение настроек
-- не распространяется на созданные ранее сделки.
-- ============================================================
ALTER TABLE suborders
    ADD COLUMN configured_level SMALLINT,     -- глубина конфигурации НА МОМЕНТ создания
    ADD COLUMN config_snapshot  JSONB,        -- сам состав, чтобы было видно, из чего число
    ADD COLUMN scale_version    SMALLINT NOT NULL DEFAULT 3;

-- Существующим подзаказам проставляем то, что настроено сейчас:
-- других данных о прошлом состоянии нет.
UPDATE suborders s SET
    configured_level = sh.participation_level,
    config_snapshot  = jsonb_build_object(
        'execution',  sh.svc_execution,
        'storefront', sh.svc_storefront,
        'catalog',    sh.svc_catalog,
        'agent',      sh.svc_agent,
        'restored',   TRUE      -- признак: снимок восстановлен, а не снят при создании
    )
FROM shops sh WHERE sh.id = s.shop_id;

-- UPDATE выше поставил в очередь отложенные триггеры сходимости
-- из миграции 04. Пока они не выполнены, ALTER TABLE на этой таблице
-- невозможен: PostgreSQL отвечает «pending trigger events».
-- Выполняем их немедленно — данные не менялись, проверки пройдут.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE suborders
    ALTER COLUMN configured_level SET NOT NULL,
    ALTER COLUMN config_snapshot  SET NOT NULL;

-- ============================================================
-- 4. ХРАПОВИК ТАМ, ГДЕ ЕМУ МЕСТО
--
-- Было (миграция 04 и channels-api):
--     новый_уровень > прежний_уровень       — на журнале
--     блокировало законное понижение настройки
--
-- Стало (решение по шкале):
--     уровень_сделки >= уровень_конфигурации_на_момент_заказа
--     конфигурация меняется свободно в обе стороны
--
-- Ст. 9.13: при создании сделки состав может быть расширен
-- относительно настроек; уменьшение не допускается.
-- ============================================================
CREATE OR REPLACE FUNCTION check_suborder_level()
RETURNS TRIGGER AS $$
DECLARE
    sh shops%ROWTYPE;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT * INTO sh FROM shops WHERE id = NEW.shop_id;
        IF sh.id IS NULL THEN
            RAISE EXCEPTION 'Подзаказ ссылается на несуществующий магазин %', NEW.shop_id;
        END IF;

        -- Снимок снимается здесь, а не передаётся снаружи: иначе его
        -- можно подделать и обойти проверку.
        NEW.configured_level := sh.participation_level;
        NEW.config_snapshot  := jsonb_build_object(
            'execution',  sh.svc_execution,
            'storefront', sh.svc_storefront,
            'catalog',    sh.svc_catalog,
            'agent',      sh.svc_agent
        );
        NEW.scale_version := sh.scale_version;

        IF NEW.participation_level IS NULL THEN
            NEW.participation_level := sh.participation_level;
        END IF;

        IF NEW.participation_level < NEW.configured_level THEN
            RAISE EXCEPTION 'Сделка ниже настроек: уровень % при сконфигурированном %. Уменьшение состава при создании сделки не допускается (ст. 9.13)',
                NEW.participation_level, NEW.configured_level;
        END IF;

        RETURN NEW;
    END IF;

    -- UPDATE: уровень совершённой сделки не понижается — иначе её
    -- можно удешевить задним числом, забрав деньги у оператора,
    -- который работу уже сделал.
    IF NEW.participation_level < OLD.participation_level THEN
        RAISE EXCEPTION 'Уровень совершённой сделки % нельзя понизить с % до %',
            OLD.id, OLD.participation_level, NEW.participation_level;
    END IF;

    -- Снимок неизменяем: он и есть доказательство того, что было
    -- настроено на момент сделки.
    IF NEW.config_snapshot IS DISTINCT FROM OLD.config_snapshot
       OR NEW.configured_level IS DISTINCT FROM OLD.configured_level THEN
        RAISE EXCEPTION 'Снимок конфигурации сделки % изменять нельзя', OLD.id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Старый триггер из миграции 04 заменяется: он проверял только UPDATE
-- и не знал про конфигурацию.
DROP TRIGGER IF EXISTS trg_suborders_ratchet ON suborders;

CREATE TRIGGER trg_suborders_level
    BEFORE INSERT OR UPDATE ON suborders
    FOR EACH ROW EXECUTE FUNCTION check_suborder_level();

-- ============================================================
-- 5. ВЕРСИЯ ШКАЛЫ В ЖУРНАЛЕ ПОВЫШЕНИЙ
--
-- Прежние записи не пересчитываются — достаточно, чтобы каждая
-- знала своё происхождение. Таблица ratchet_log живёт вне файлов
-- схемы (создана вручную), поэтому колонка добавляется условно.
-- ============================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema='public' AND table_name='ratchet_log') THEN
        EXECUTE 'ALTER TABLE ratchet_log ADD COLUMN IF NOT EXISTS scale_version SMALLINT';
        -- всё, что записано до этой миграции, сделано по прежней шкале
        EXECUTE 'UPDATE ratchet_log SET scale_version = 0 WHERE scale_version IS NULL';
        EXECUTE 'ALTER TABLE ratchet_log ALTER COLUMN scale_version SET DEFAULT 3';
        RAISE NOTICE 'ratchet_log: версия шкалы добавлена, прежние записи помечены версией 0';

        -- Ограничение, блокирующее законное понижение настройки, снимается.
        -- Отказ должен возникать при создании сделки, а не здесь.
        BEGIN
            EXECUTE 'ALTER TABLE ratchet_log DROP CONSTRAINT IF EXISTS ratchet_log_check';
            RAISE NOTICE 'ratchet_log: ограничение to_level > from_level снято';
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'ratchet_log: ограничение снять не удалось, снимите вручную';
        END;
    ELSE
        RAISE NOTICE 'ratchet_log отсутствует — пропускаю. Если он есть в боевой базе, примените этот блок там.';
    END IF;
END $$;

COMMIT;

-- ============================================================
-- ЧТО ОСТАЁТСЯ СДЕЛАТЬ В КОДЕ
--
--   api/channels-api.js — снять 409 на понижение в /ratchet/upgrade.
--       Понижение конфигурации законно (ст. 9.12).
--
--   api/server.js — при создании подзаказа не передавать
--       participation_level вручную: триггер проставит его из
--       конфигурации. Передавать только при разовом повышении.
--
--   панель конфигуратора — убрать «ранг N» из интерфейса.
--       Показывать названия схем: «своя витрина и каталог»,
--       «исполнение Системы», «полная система».
--
-- ПРОВЕРКА, ЧТО ПЕРЕВОД ВЫПОЛНЕН (из решения по шкале)
--
--   1. Включить каталог у категории      -> глубина растёт на единицу
--   2. Выключить звено исполнения        -> проходит, отказа нет
--   3. После понижения открыть вчерашний заказ -> состав и суммы прежние
--   4. Заказ с фулфилментом при своём исполнении -> проходит,
--      конфигурация после заказа прежняя
--   5. Прямым вызовом заказ ниже конфигурации -> отказ
--   6. Доли повышенного заказа против обычного -> появилась строка оператора
--   7. Старая и новая записи журнала -> у каждой своя версия шкалы
--
-- Третий важнее остальных: если вчерашний заказ пересчитался,
-- снимка конфигурации нет, и прочие проверки смысла не имеют.
-- ============================================================
