#!/usr/bin/env bash
#
# Проверка защиты маршрутов продавца (первый коммит).
# Отвечает на один вопрос: закрыта ли дыра и не сломалось ли остальное.
#
# Запуск:
#   bash ops/test-auth.sh                                  # localhost:3000
#   bash ops/test-auth.sh https://marketplace-api-ujfh.onrender.com
#
# Логин и пароль продавца — через переменные окружения либо спросит сам:
#   SELLER_LOGIN=mm SELLER_PASSWORD=... bash ops/test-auth.sh <адрес>
#
# Без логина прогонит только проверки, не требующие входа.
#
# Контур допуска (ст. 16):
#   ADMISSION_KEY=...   тот же ключ, что в окружении сервера. Без него
#                       проверяется только отказ, положительный путь пропускается.
#   TEST_WRITES=1       разрешить проверки, которые ПИШУТ в базу. По умолчанию
#                       выключены: они оставляют строку в participants.
#
# Код возврата 0 — всё прошло, 1 — есть падения.
#
set -uo pipefail
export LC_ALL="${LC_ALL:-C.UTF-8}"

BASE="${1:-http://localhost:3000}"
SELLER_ID="${SELLER_ID:-PTR-12345}"
FOREIGN_ID="${FOREIGN_ID:-PTR-00000}"
ADMISSION_KEY="${ADMISSION_KEY:-}"
TEST_WRITES="${TEST_WRITES:-0}"

PASS=0; FAIL=0; SKIP=0
ok=$'\033[32m'; bad=$'\033[31m'; dim=$'\033[2m'; warn=$'\033[33m'; off=$'\033[0m'

pad() { local s="$1" w="${2:-40}" n; n=$(( w - ${#s} )); (( n < 0 )) && n=0; printf '%s%*s' "$s" "$n" ""; }

# code METHOD PATH [TOKEN] [BODY] [HEADER] → печатает HTTP-код
code() {
  local m="$1" p="$2" tok="${3:-}" body="${4:-}" hdr="${5:-}"
  local args=(-s -o /dev/null -w '%{http_code}' -m 20 -X "$m" -H 'Content-Type: application/json')
  [[ -n "$tok"  ]] && args+=(-H "Authorization: Bearer $tok")
  [[ -n "$hdr"  ]] && args+=(-H "$hdr")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}" "${BASE}${p}" 2>/dev/null
}

# expect ОПИСАНИЕ ОЖИДАЕМЫЙ_КОД МЕТОД ПУТЬ [TOKEN] [BODY] [HEADER]
expect() {
  local name="$1" want="$2" m="$3" p="$4" tok="${5:-}" body="${6:-}" hdr="${7:-}"
  local got; got="$(code "$m" "$p" "$tok" "$body" "$hdr")"
  if [[ "$got" == "$want" ]]; then
    printf '  %sok%s      %s %sожидался %s%s\n' "$ok" "$off" "$(pad "$name")" "$dim" "$want" "$off"
    PASS=$((PASS+1))
  elif [[ "$got" == "000" ]]; then
    printf '  %sПАДЕНИЕ%s %s соединение не установлено\n' "$bad" "$off" "$(pad "$name")"
    FAIL=$((FAIL+1))
  else
    printf '  %sПАДЕНИЕ%s %s получен %s, ожидался %s\n' "$bad" "$off" "$(pad "$name")" "$got" "$want"
    FAIL=$((FAIL+1))
  fi
}

skip() {
  printf '  %sпропуск%s %s %s\n' "$warn" "$off" "$(pad "$1")" "$2"
  SKIP=$((SKIP+1))
}

# expect_field ОПИСАНИЕ ПОДСТРОКА МЕТОД ПУТЬ [BODY] [HEADER]
# Там, где важен не код ответа, а его содержимое: заявка обязана вернуться
# со статусом PENDING, и 201 сам по себе этого не доказывает.
expect_field() {
  local name="$1" want="$2" m="$3" p="$4" body="${5:-}" hdr="${6:-}"
  local args=(-s -m 20 -X "$m" -H 'Content-Type: application/json')
  [[ -n "$hdr"  ]] && args+=(-H "$hdr")
  [[ -n "$body" ]] && args+=(-d "$body")
  local out; out="$(curl "${args[@]}" "${BASE}${p}" 2>/dev/null)"
  if [[ "$out" == *"$want"* ]]; then
    printf '  %sok%s      %s %sсодержит %s%s\n' "$ok" "$off" "$(pad "$name")" "$dim" "$want" "$off"
    PASS=$((PASS+1))
  else
    printf '  %sПАДЕНИЕ%s %s нет %s в ответе: %s\n' "$bad" "$off" "$(pad "$name")" "$want" "${out:0:120}"
    FAIL=$((FAIL+1))
  fi
}

# expect_absent ОПИСАНИЕ ПОДСТРОКА МЕТОД ПУТЬ
# Обратная expect_field: поля в ответе быть НЕ должно.
expect_absent() {
  local name="$1" bad_s="$2" m="$3" p="$4"
  local out; out="$(curl -s -m 20 -X "$m" "${BASE}${p}" 2>/dev/null)"
  if [[ "$out" != *"$bad_s"* ]]; then
    printf '  %sok%s      %s %sнет %s%s\n' "$ok" "$off" "$(pad "$name")" "$dim" "$bad_s" "$off"
    PASS=$((PASS+1))
  else
    printf '  %sПАДЕНИЕ%s %s в ответе есть %s: %s\n' "$bad" "$off" "$(pad "$name")" "$bad_s" "${out:0:120}"
    FAIL=$((FAIL+1))
  fi
}

echo
echo "Контур:   ${BASE}"
echo "Продавец: ${SELLER_ID}"
echo

# ── 1. Живость ────────────────────────────────────────────────
echo "Живость"
expect "сервер отвечает"                200 GET /api/health
expect "смоук-тест"                     200 GET /api/v1/smoke-test

# ── 2. Открытое остаётся открытым ────────────────────────────
# Если тут появится 401 — сломана витрина, а не защита.
echo
echo "Покупательские маршруты (токен не нужен)"
expect "магазин"                        200 GET "/api/v1/shop/massamadre"
expect "товары магазина"                200 GET "/api/v1/shop/massamadre/products"
expect "каталог магазинов"              200 GET /api/v1/catalog/shops
expect "категории"                      200 GET /api/v1/catalog/categories
expect "конфиг витрины"                 200 GET "/api/v1/config/massamadre"

# Конфиг витрины отдавал seller_id по одному слагу. Витрине он не нужен:
# она читает отсюда только brand.* и seller_rating.
expect_absent "конфиг без seller_id"    '"seller_id"'    GET "/api/v1/config/massamadre"
expect_absent "конфиг без seller_group" '"seller_group"' GET "/api/v1/config/massamadre"

# ── 3. Защита без токена ─────────────────────────────────────
# Это и есть закрытая дыра. До первого коммита здесь было 200.
echo
echo "Маршруты продавца без токена"
expect "чтение товаров, старый путь"    401 GET "/api/v1/seller/${SELLER_ID}/products"
expect "чтение товаров, новый путь"     401 GET /api/v1/seller/products
expect "создание товара"                401 POST "/api/v1/seller/${SELLER_ID}/products" "" '{"title":"x","price":1}'
expect "правка товара"                  401 PATCH "/api/v1/seller/${SELLER_ID}/products/SKU-001" "" '{"price":1}'
expect "статистика"                     401 GET "/api/v1/seller/${SELLER_ID}/stats"

# ── 4. Подделка подписи ──────────────────────────────────────
echo
echo "Негодные токены"
expect "мусор вместо токена"            401 GET /api/v1/seller/products "a.b.c"
# токен, подписанный чужим ключом: заголовок и тело валидные, подпись нет
FORGED='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzZWxsZXJfaWQiOiJQVFItMTIzNDUiLCJyb2xlIjoiU0VMTEVSIn0.ZmFrZQ'
expect "подпись чужим ключом"           401 GET /api/v1/seller/products "$FORGED"

# ── 5. Персональные данные без токена ────────────────────────
# Оба маршрута отдавали ПД кому угодно: карточка покупателя — телефон,
# имя и e-mail; заказ — адрес доставки и расщепление. Перебор CUST-<hex8>
# и ORD-<hex8> выгружал базу. Теперь оба требуют токен.
echo
echo "Персональные данные без токена"
expect "карточка покупателя"            401 GET /api/v1/customers/CUST-00000000
expect "заказ"                          401 GET /api/v1/orders/ORD-00000000

# ── 6. Контур допуска: выдача учётки ─────────────────────────
# Цепочка захвата аккаунта: seller_id публичен (витрина и каталог отдают его
# в каждом товаре) -> register был открыт -> учётка на чужого продавца.
# Рвём второе звено: без ключа допуска учётку не выдать.
echo
echo "Допуск: выдача учётки (POST /auth/register)"

# Тело заведомо не приводит к записи: пароль короткий отвергается позже,
# а участника FOREIGN_ID не существует. Проверяется только, кого пускают.
REG_SELF='{"seller_id":"'"${SELLER_ID}"'","login":"probe-login","password":"probe-password-123"}'
REG_NONE='{"seller_id":"'"${FOREIGN_ID}"'","login":"probe-login","password":"probe-password-123"}'

if [[ -z "$ADMISSION_KEY" ]]; then
  # Ключа нет в окружении проверяющего. Если сервер отвечает 501 — на нём
  # ключа тоже нет, и это правильное поведение: контур отключён целиком.
  # Если 403 — ключ на сервере есть, задайте его и здесь.
  GOT="$(code POST /api/v1/auth/register "" "$REG_SELF")"
  if [[ "$GOT" == "501" ]]; then
    printf '  %sok%s      %s %sконтур допуска отключён (501)%s\n' "$ok" "$off" "$(pad "ключ не задан на сервере")" "$dim" "$off"
    PASS=$((PASS+1))
  elif [[ "$GOT" == "403" ]]; then
    printf '  %sok%s      %s %sключ на сервере есть%s\n' "$ok" "$off" "$(pad "без заголовка отбито")" "$dim" "$off"
    PASS=$((PASS+1))
  else
    printf '  %sПАДЕНИЕ%s %s получен %s, ожидался 501 или 403\n' "$bad" "$off" "$(pad "выдача учётки без ключа")" "$GOT"
    FAIL=$((FAIL+1))
  fi
  skip "верный ключ пропускает"  "задайте ADMISSION_KEY"
  skip "неверный ключ отбивается" "задайте ADMISSION_KEY"
else
  expect "без заголовка"                403 POST /api/v1/auth/register "" "$REG_SELF"
  expect "неверный ключ"                403 POST /api/v1/auth/register "" "$REG_SELF" "X-Admission-Key: zavedomo-ne-tot-kluch"
  # Верный ключ на несуществующего участника: 404 доказывает, что ключ
  # приняли и дошли до сути. Ничего при этом не записывается.
  expect "верный ключ, участника нет"   404 POST /api/v1/auth/register "" "$REG_NONE" "X-Admission-Key: ${ADMISSION_KEY}"
fi

# ── 7. Контур допуска: реестр участников ─────────────────────
# Роли ORGANIZER, BANK, FINANCE через API не создаются вовсе (ст. 16:
# допуск — функция Организатора). Роли операторов — только с ключом.
# Все проверки отбиваются ДО вставки, база не меняется.
echo
echo "Допуск: реестр участников (POST /participants)"

pbody() { printf '{"inn":"7700000099","name":"Проверка допуска","role":"%s"}' "$1"; }

expect "роль ORGANIZER"               403 POST /api/v1/participants "" "$(pbody ORGANIZER)"
expect "роль BANK"                    403 POST /api/v1/participants "" "$(pbody BANK)"
expect "роль FINANCE"                 403 POST /api/v1/participants "" "$(pbody FINANCE)"
expect "роль FULFILLMENT без ключа"   403 POST /api/v1/participants "" "$(pbody FULFILLMENT)"
expect "роль LOGISTICS без ключа"     403 POST /api/v1/participants "" "$(pbody LOGISTICS)"
expect "несуществующая роль"          400 POST /api/v1/participants "" "$(pbody WIZARD)"

# Положительный путь пишет строку в реестр, поэтому по умолчанию выключен.
echo
echo "Допуск: публичная заявка (пишет в базу)"
if [[ "$TEST_WRITES" != "1" ]]; then
  skip "заявка создаётся как PENDING" "нужен TEST_WRITES=1"
else
  RAND_INN="7707$(printf '%08d' $(( (RANDOM * 32768 + RANDOM) % 100000000 )))"
  P_NEW="$(printf '{"inn":"%s","name":"Проверка допуска","role":"SELLER","seller_group":1}' "$RAND_INN")"
  expect_field "заявка создаётся как PENDING" '"status":"PENDING"' POST /api/v1/participants "$P_NEW"
  printf '  %sв participants осталась строка: ИНН %s — удалить вручную%s\n' "$warn" "$RAND_INN" "$off"
fi

# ── 8. С токеном ─────────────────────────────────────────────
echo
echo "Маршруты продавца с токеном"

LOGIN="${SELLER_LOGIN:-}"
PASSWORD="${SELLER_PASSWORD:-}"
if [[ -z "$LOGIN" && -t 0 ]]; then
  read -r -p "  Логин продавца (Enter — пропустить): " LOGIN
  [[ -n "$LOGIN" ]] && read -r -s -p "  Пароль: " PASSWORD && echo
fi

TOKEN=""
if [[ -n "$LOGIN" ]]; then
  RESP="$(curl -s -m 20 -X POST "${BASE}/api/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"login\":\"${LOGIN}\",\"password\":\"${PASSWORD}\"}" 2>/dev/null)"
  # без jq: вытаскиваем поле token
  TOKEN="$(printf '%s' "$RESP" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi

if [[ -z "$TOKEN" ]]; then
  skip "вход не выполнен" "задайте SELLER_LOGIN и SELLER_PASSWORD"
  skip "чтение своих товаров"    "нет токена"
  skip "чужой id в адресе"       "нет токена"
  skip "статистика"              "нет токена"
  skip "чужой заказ"             "нет токена"
  skip "чужой покупатель"        "нет токена"
else
  printf '  %sвход выполнен, токен получен%s\n' "$dim" "$off"
  expect "чтение своих товаров"         200 GET /api/v1/seller/products "$TOKEN"
  expect "старый путь, свой id"         200 GET "/api/v1/seller/${SELLER_ID}/products" "$TOKEN"
  # главное: чужой идентификатор в адресе не даёт доступа к чужим данным
  expect "старый путь, ЧУЖОЙ id"        403 GET "/api/v1/seller/${FOREIGN_ID}/products" "$TOKEN"
  expect "статистика"                   200 GET /api/v1/seller/stats "$TOKEN"
  # правка несуществующего товара: 404, а не «updated: true»
  expect "правка чужого товара"         404 PATCH /api/v1/seller/products/SKU-NOPE "$TOKEN" '{"price":100}'

  # Владение, а не просто наличие токена. Несуществующий и чужой отвечают
  # одинаково — 404, поэтому по ответу нельзя узнать, есть ли такой заказ.
  expect "чужой заказ"                  404 GET /api/v1/orders/ORD-00000000 "$TOKEN"
  expect "чужой покупатель"             404 GET /api/v1/customers/CUST-00000000 "$TOKEN"

  # Вход только что удался — значит учётка у этого продавца есть.
  # Повторная выдача обязана упереться в 409 и НЕ создать вторую:
  # второй вход к тому же seller_id владелец первого не увидит.
  # Проверка write-free: до INSERT дело не доходит.
  if [[ -n "$ADMISSION_KEY" ]]; then
    expect "вторая учётка тому же продавцу" 409 POST /api/v1/auth/register "" "$REG_SELF" "X-Admission-Key: ${ADMISSION_KEY}"
  else
    skip "вторая учётка тому же продавцу" "задайте ADMISSION_KEY"
  fi
fi

# ── Итог ─────────────────────────────────────────────────────
echo
printf 'Итог: %d прошло, %d упало' "$PASS" "$FAIL"
[[ "$SKIP" -gt 0 ]] && printf ', %d пропущено' "$SKIP"
echo; echo

if [[ "$FAIL" -gt 0 ]]; then
  cat <<'HINT'
Что означают падения:

  Покупательские маршруты дают 401
      Защита навешена слишком широко. Витрина сломана — откатывайте.

  Маршруты продавца без токена дают 200
      Первый коммит не выложен либо выложен не тот файл.

  Всё даёт «соединение не установлено»
      Сервис не поднялся. Скорее всего не задан JWT_SECRET: без него
      процесс завершается намеренно. Смотрите лог деплоя.

  Чужой id в адресе даёт 200
      Нет сверки токена с адресом — в файле отсутствует assertSelf.

  Выдача учётки без ключа даёт 201 или 404
      requireAdmission не навешен на POST /auth/register. Это и есть
      второе звено цепочки захвата аккаунта — выкладывайте коммит.

  Роль ORGANIZER или BANK даёт 201
      В POST /participants нет списка ROLES_NEVER_VIA_API. Проверьте,
      что созданного участника удалили из реестра.

  Заявка возвращает status ACTIVE
      Статус по-прежнему берётся из тела или зашит. Публичная форма
      обязана создавать PENDING: KYC в /join проверяется браузером.

  Вторая учётка тому же продавцу даёт 201
      Нет ни проверки в коде, ни индекса. Прогоните
      schema/07_seller_auth.sql и проверьте, что лишнюю учётку удалили:
      она даёт полный доступ к магазину мимо владельца.

  Карточка покупателя или заказ без токена дают 200
      Утечка персональных данных: телефон и e-mail покупателя, адрес
      доставки. Перебором идентификаторов выгружается вся база.

  Чужой заказ с токеном даёт 200
      Есть requireSeller, но нет предиката владения. Проверьте, что
      в выборке стоит AND seller_id = $2, а не отдельная проверка после.

  Конфиг витрины содержит seller_id
      Вернулась первая ступень цепочки захвата: по слагу витрины
      получается идентификатор продавца. Проверьте, что в выборке
      перечислены колонки, а не sh.*.

  Карточка покупателя даёт 501
      requireSeller не передан в customers-api при монтировании
      в server.js. Это fail-closed, не поломка: чтение отключено.
HINT
fi

[[ "$FAIL" -eq 0 ]]
