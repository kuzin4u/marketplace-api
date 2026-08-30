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
# Код возврата 0 — всё прошло, 1 — есть падения.
#
set -uo pipefail
export LC_ALL="${LC_ALL:-C.UTF-8}"

BASE="${1:-http://localhost:3000}"
SELLER_ID="${SELLER_ID:-PTR-12345}"
FOREIGN_ID="${FOREIGN_ID:-PTR-00000}"

PASS=0; FAIL=0; SKIP=0
ok=$'\033[32m'; bad=$'\033[31m'; dim=$'\033[2m'; warn=$'\033[33m'; off=$'\033[0m'

pad() { local s="$1" w="${2:-40}" n; n=$(( w - ${#s} )); (( n < 0 )) && n=0; printf '%s%*s' "$s" "$n" ""; }

# code METHOD PATH [TOKEN] [BODY] → печатает HTTP-код
code() {
  local m="$1" p="$2" tok="${3:-}" body="${4:-}"
  local args=(-s -o /dev/null -w '%{http_code}' -m 20 -X "$m" -H 'Content-Type: application/json')
  [[ -n "$tok"  ]] && args+=(-H "Authorization: Bearer $tok")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}" "${BASE}${p}" 2>/dev/null
}

# expect ОПИСАНИЕ ОЖИДАЕМЫЙ_КОД МЕТОД ПУТЬ [TOKEN] [BODY]
expect() {
  local name="$1" want="$2" m="$3" p="$4" tok="${5:-}" body="${6:-}"
  local got; got="$(code "$m" "$p" "$tok" "$body")"
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

# ── 5. С токеном ─────────────────────────────────────────────
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
else
  printf '  %sвход выполнен, токен получен%s\n' "$dim" "$off"
  expect "чтение своих товаров"         200 GET /api/v1/seller/products "$TOKEN"
  expect "старый путь, свой id"         200 GET "/api/v1/seller/${SELLER_ID}/products" "$TOKEN"
  # главное: чужой идентификатор в адресе не даёт доступа к чужим данным
  expect "старый путь, ЧУЖОЙ id"        403 GET "/api/v1/seller/${FOREIGN_ID}/products" "$TOKEN"
  expect "статистика"                   200 GET /api/v1/seller/stats "$TOKEN"
  # правка несуществующего товара: 404, а не «updated: true»
  expect "правка чужого товара"         404 PATCH /api/v1/seller/products/SKU-NOPE "$TOKEN" '{"price":100}'
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
HINT
fi

[[ "$FAIL" -eq 0 ]]
