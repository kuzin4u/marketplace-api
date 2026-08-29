#!/usr/bin/env bash
#
# Снимает дамп с Supabase, поднимает локальный Postgres в Docker,
# восстанавливает туда дамп и сверяет счётчики строк.
#
# Зачем: доказать, что база переносится, НЕ создавая ни одного платного
# ресурса в облаке. Тот же дамп потом заливается в Yandex Cloud без изменений.
#
# Требуется: docker, pg_dump/pg_restore/psql (клиент той же мажорной версии
# или новее, чем сервер Supabase — версию покажет check-supabase.sql).
#
# Запуск:
#   export SUPABASE_URL='postgresql://postgres:ПАРОЛЬ@db.xxxx.supabase.co:5432/postgres'
#   bash dump-restore-verify.sh
#
set -euo pipefail

# --- параметры -------------------------------------------------------------
PG_MAJOR="${PG_MAJOR:-16}"          # мажорная версия локального Postgres
CONTAINER="${CONTAINER:-mm-restore-test}"
LOCAL_PORT="${LOCAL_PORT:-55432}"   # нестандартный, чтобы не конфликтовать
LOCAL_PASS="${LOCAL_PASS:-restore_test_pw}"
DB_NAME="${DB_NAME:-marketplace}"
STAMP="$(date +%Y%m%d-%H%M)"
DUMP_FILE="${DUMP_FILE:-mm-${STAMP}.dump}"
WORKDIR="$(pwd)"

LOCAL_URL="postgresql://postgres:${LOCAL_PASS}@127.0.0.1:${LOCAL_PORT}/${DB_NAME}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

if [[ -z "${SUPABASE_URL:-}" ]]; then
  echo "Не задан SUPABASE_URL." >&2
  echo "Возьмите ПРЯМОЕ подключение (порт 5432), не пулер — pg_dump требует" >&2
  echo "сессионного режима. Строка есть в Supabase: Project Settings > Database." >&2
  exit 1
fi

# --- 1. дамп ---------------------------------------------------------------
say "1/6 Снимаю дамп схемы public"
# --no-owner    — в целевой базе не будет роли postgres из Supabase
# --no-privileges — срезает гранты на anon/authenticated, которых в цели нет
# -Fc           — custom format, позволяет посмотреть содержимое до восстановления
pg_dump "$SUPABASE_URL" \
  --schema=public \
  --no-owner \
  --no-privileges \
  -Fc -f "$DUMP_FILE"

ls -lh "$DUMP_FILE"

say "2/6 Что внутри дампа"
pg_restore -l "$DUMP_FILE" | grep -E 'TABLE|SEQUENCE|INDEX|FUNCTION|TRIGGER' | sed 's/^[0-9;. ]*//' | sort | uniq -c | sort -rn
echo
echo "Список таблиц:"
pg_restore -l "$DUMP_FILE" | grep -E ' TABLE ' | awk '{print $NF}' | sort

# --- 2. локальный Postgres -------------------------------------------------
say "3/6 Поднимаю Postgres ${PG_MAJOR} в Docker"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
  -e POSTGRES_PASSWORD="$LOCAL_PASS" \
  -e POSTGRES_DB="$DB_NAME" \
  -p "${LOCAL_PORT}:5432" \
  "postgres:${PG_MAJOR}" >/dev/null

printf 'Жду готовности'
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER" pg_isready -U postgres -q 2>/dev/null; then break; fi
  printf '.'; sleep 1
done
echo ' готов'

# --- 3. расширения ---------------------------------------------------------
say "4/6 Ставлю расширения"
# ВАЖНО: список должен совпасть с выводом запроса [7] из check-supabase.sql.
# Если у вас расширения стоят в схеме extensions — раскомментируйте создание схемы.
# psql "$LOCAL_URL" -c 'create schema if not exists extensions;'
for ext in "uuid-ossp" "pgcrypto" "pg_trgm"; do
  psql "$LOCAL_URL" -v ON_ERROR_STOP=0 -c "create extension if not exists \"${ext}\";" >/dev/null \
    && echo "  ok: ${ext}" || echo "  ПРОПУЩЕНО: ${ext}"
done

# --- 4. восстановление -----------------------------------------------------
say "5/6 Восстанавливаю"
# --single-transaction: при ошибке не остаётся полуперенесённой базы
if pg_restore --no-owner --no-privileges --single-transaction \
     -d "$LOCAL_URL" "$DUMP_FILE" 2> "restore-${STAMP}.log"; then
  echo "Восстановление прошло без ошибок."
else
  echo "ОШИБКА при восстановлении. Лог: restore-${STAMP}.log"
  echo "--- последние 30 строк ---"
  tail -30 "restore-${STAMP}.log"
  echo
  echo "Частые причины: не установлено нужное расширение (см. запрос [7]),"
  echo "или объекты ссылаются на схему extensions, которой нет."
  exit 1
fi
if [[ -s "restore-${STAMP}.log" ]]; then
  echo "Предупреждения (не фатальные):"
  head -20 "restore-${STAMP}.log"
fi

# --- 5. сверка -------------------------------------------------------------
say "6/6 Сверяю"

COUNT_SQL="select relname,
  (xpath('/row/c/text()',
         query_to_xml(format('select count(*) as c from public.%I', relname),
                      false, true, '')))[1]::text::bigint
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='r' order by 1;"

psql "$SUPABASE_URL" -At -F'|' -c "$COUNT_SQL" > "counts-source-${STAMP}.txt"
psql "$LOCAL_URL"    -At -F'|' -c "$COUNT_SQL" > "counts-target-${STAMP}.txt"

echo "Строки:"
if diff -u "counts-source-${STAMP}.txt" "counts-target-${STAMP}.txt" > "diff-${STAMP}.txt"; then
  echo "  СОВПАДАЕТ — все таблицы, все строки."
  column -t -s'|' "counts-target-${STAMP}.txt" | sed 's/^/    /'
else
  echo "  РАСХОЖДЕНИЕ:"
  cat "diff-${STAMP}.txt"
fi

echo
echo "Индексы и ограничения:"
for label in source target; do
  url=$([[ $label == source ]] && echo "$SUPABASE_URL" || echo "$LOCAL_URL")
  idx=$(psql "$url" -At -c "select count(*) from pg_indexes where schemaname='public';")
  con=$(psql "$url" -At -c "select count(*) from pg_constraint c join pg_class r on r.oid=c.conrelid join pg_namespace n on n.oid=r.relnamespace where n.nspname='public';")
  printf '  %-7s индексов: %-4s ограничений: %s\n' "$label" "$idx" "$con"
done

echo
echo "Последовательности (проверка, что setval перенёсся):"
psql "$LOCAL_URL" -At -F'|' -c \
  "select sequencename, last_value from pg_sequences where schemaname='public' order by 1;" \
  | column -t -s'|' | sed 's/^/  /' || echo "  последовательностей нет"

# --- итог ------------------------------------------------------------------
cat <<EOF

------------------------------------------------------------
Дамп:      ${WORKDIR}/${DUMP_FILE}
Локальная: ${LOCAL_URL}

Дальше вручную:
  1) Поднять server.js с DATABASE_URL=${LOCAL_URL}
  2) GET /api/health и GET /api/v1/smoke-test
  3) Цепочка: продавец -> магазин -> товар -> витрина
  4) Проверить выдачу GET /catalog/search — совпадает ли порядок
     ранжирования с боевым (полнотекстовый поиск чувствителен
     к конфигурации словаря)

Прошло — этот же файл дампа заливается в Yandex Cloud без изменений,
меняется только строка подключения.

Остановить и удалить контейнер:
  docker rm -f ${CONTAINER}

ВНИМАНИЕ: ${DUMP_FILE} содержит персональные данные. Не коммитить,
не класть в облачные папки, удалить после проверки.
------------------------------------------------------------
EOF
