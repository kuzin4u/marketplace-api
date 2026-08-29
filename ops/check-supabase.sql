-- ============================================================
-- Диагностика базы перед переносом.
-- Запускать в SQL-панели Supabase. Ничего не меняет, только читает.
-- Цель: понять, переносится ли база обычным pg_dump/pg_restore,
-- или в ней есть механизмы, специфичные для Supabase.
-- ============================================================

-- [1] ВЕРСИЯ. Целевой кластер должен быть той же мажорной версии или выше.
select version() as pg_version;

-- [2] ГДЕ ЛЕЖАТ ТАБЛИЦЫ.
-- Ожидание: ваши таблицы только в public. Схемы auth, storage, realtime,
-- vault, graphql — служебные, они принадлежат Supabase и НЕ переносятся.
select table_schema, count(*) as tables
from information_schema.tables
where table_schema not in ('pg_catalog','information_schema')
group by 1
order by 2 desc;

-- [3] СПИСОК ВАШИХ ТАБЛИЦ + размер. Сверить с ожидаемыми 13 + 2 каталожные.
select c.relname as table_name,
       pg_size_pretty(pg_total_relation_size(c.oid)) as size,
       c.reltuples::bigint as approx_rows
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by pg_total_relation_size(c.oid) desc;

-- [4] RLS. КРИТИЧНО.
-- Пусто = хорошо. Если что-то вернулось — на этих таблицах включён
-- row level security; после переноса приложение может молча получать
-- ноль строк, потому что ролей anon/authenticated в целевой базе нет.
select c.relname, c.relrowsecurity, c.relforcerowsecurity
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity;

-- [5] ПОЛИТИКИ RLS. Пусто = хорошо.
select tablename, policyname, roles, cmd
from pg_policies
where schemaname = 'public';

-- [6] ССЫЛКИ ИЗ public В СЛУЖЕБНЫЕ СХЕМЫ. Пусто = хорошо.
-- Если есть FK на auth.users — авторизация завязана на Supabase Auth,
-- и перенос перестаёт быть механическим.
select conrelid::regclass as from_table,
       conname,
       confrelid::regclass as to_table
from pg_constraint
where confrelid::regclass::text ~ '^(auth|storage|realtime)\.';

-- [7] РАСШИРЕНИЯ И ИХ СХЕМА.
-- Эти же расширения нужно включить в целевом кластере ДО восстановления.
-- Обратите внимание на колонку schema: если extensions, а не public,
-- в целевой базе нужно создать схему extensions и ставить туда же.
select e.extname, n.nspname as schema, e.extversion
from pg_extension e
join pg_namespace n on n.oid = e.extnamespace
order by 1;

-- [8] ФУНКЦИИ И ТРИГГЕРЫ В public.
-- Переносятся дампом, но полезно знать, что они есть.
select p.proname, pg_get_function_identity_arguments(p.oid) as args
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
order by 1;

select c.relname as table_name, t.tgname as trigger_name
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and not t.tgisinternal
order by 1, 2;

-- [9] ПОЛНОТЕКСТОВЫЙ ПОИСК.
-- Проверить, на какой конфигурации словаря построены индексы каталога.
-- Если 'russian' — в целевом кластере она есть, но выдачу сверить.
select indexname, indexdef
from pg_indexes
where schemaname = 'public'
  and (indexdef ilike '%tsvector%' or indexdef ilike '%gin%' or indexdef ilike '%trgm%');

-- [10] ВЛАДЕЛЬЦЫ И ГРАНТЫ.
-- Если владелец таблиц — postgres, дамп с --no-owner ляжет ровно.
select tablename, tableowner from pg_tables where schemaname = 'public' order by 1;

select grantee, count(*) as grants
from information_schema.role_table_grants
where table_schema = 'public'
group by 1
order by 2 desc;

-- [11] ТОЧНЫЕ СЧЁТЧИКИ СТРОК — эталон для сверки после восстановления.
-- Сохраните вывод. Тот же запрос выполняется на целевой базе, числа должны совпасть.
select relname as table_name,
       (xpath('/row/c/text()',
              query_to_xml(format('select count(*) as c from public.%I', relname),
                           false, true, '')))[1]::text::bigint as exact_rows
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by 1;

-- ============================================================
-- КАК ЧИТАТЬ РЕЗУЛЬТАТ
--
-- Запросы 4, 5, 6 пустые  -> чистый случай. Перенос = pg_dump + pg_restore.
-- Запрос 4 или 5 не пустой -> RLS включён. Не блокер, но требует решения:
--                             либо отключить RLS в целевой базе,
--                             либо создать роли, на которые ссылаются политики.
-- Запрос 6 не пустой       -> используется Supabase Auth. Останавливаемся
--                             и разбираемся отдельно, что именно переносить.
-- ============================================================
