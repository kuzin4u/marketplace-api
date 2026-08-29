#!/usr/bin/env bash
#
# Смоук-проверка контура. Работает против любого адреса — локального,
# боевого, проверочного. Нужна в день переезда: одна команда отвечает
# на вопрос «новый контур живой или нет».
#
# Запуск:
#   bash ops/smoke.sh                                  # localhost:3000
#   bash ops/smoke.sh https://marketplace-api-ujfh.onrender.com
#
# Код возврата 0 — всё прошло, 1 — есть падения.
#
set -uo pipefail

# ${#s} считает символы только в UTF-8-локали, иначе байты
export LC_ALL="${LC_ALL:-C.UTF-8}"

BASE="${1:-http://localhost:3000}"
SLUG="${SLUG:-massamadre}"
PASS=0; FAIL=0

c_ok=$'\033[32m'; c_bad=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

# printf считает байты, а не символы — на кириллице колонки разъезжаются.
# Дополняем вручную по числу символов.
pad() {
  local s="$1" w="${2:-44}" n
  n=$(( w - ${#s} ))
  (( n < 0 )) && n=0
  printf '%s%*s' "$s" "$n" ""
}

check() {
  local name="$1" path="$2" expect="${3:-200}"
  local code body
  body="$(curl -sS -m 15 -w '\n%{http_code}' "${BASE}${path}" 2>/dev/null)" || {
    printf '  %sПАДЕНИЕ%s  %s соединение не установлено\n' "$c_bad" "$c_off" "$(pad "$name")"
    FAIL=$((FAIL+1)); return
  }
  code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [[ "$code" == "$expect" ]]; then
    printf '  %sok%s       %s %s%s%s\n' "$c_ok" "$c_off" "$(pad "$name")" "$c_dim" "${body:0:60}" "$c_off"
    PASS=$((PASS+1))
  else
    printf '  %sПАДЕНИЕ%s  %s ожидался %s, получен %s\n' "$c_bad" "$c_off" "$(pad "$name")" "$expect" "$code"
    printf '           %s%s%s\n' "$c_dim" "${body:0:160}" "$c_off"
    FAIL=$((FAIL+1))
  fi
}

echo
echo "Контур: ${BASE}"
echo "Магазин: ${SLUG}"
echo

echo "Живость"
check "health"                  "/api/health"
check "smoke-test"              "/api/v1/smoke-test"

echo
echo "Витрина"
check "магазин по адресу"       "/api/v1/shop/${SLUG}"
check "товары магазина"         "/api/v1/shop/${SLUG}/products"
check "конфиг магазина"         "/api/v1/config/${SLUG}"

echo
echo "Каталог"
check "поиск"                   "/api/v1/catalog/search?q=%D1%85%D0%BB%D0%B5%D0%B1"
check "магазины"                "/api/v1/catalog/shops"
check "категории"               "/api/v1/catalog/categories"

echo
echo "Защита"
# без токена запись должна отбиваться. 401 или 403 — оба приемлемы;
# 200 означает, что авторизация не работает, и это провал
code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -d '{}' \
  "${BASE}/api/v1/seller/products" 2>/dev/null)"
if [[ "$code" == "401" || "$code" == "403" ]]; then
  printf '  %sok%s       %s %s%s%s\n' "$c_ok" "$c_off" "$(pad "запись без токена отбита")" "$c_dim" "$code" "$c_off"
  PASS=$((PASS+1))
elif [[ "$code" == "000" ]]; then
  printf '  %sПАДЕНИЕ%s  %s соединение не установлено\n' "$c_bad" "$c_off" "$(pad "запись без токена")"
  FAIL=$((FAIL+1))
else
  printf '  %sПАДЕНИЕ%s  %s получен %s — запись доступна без токена\n' \
    "$c_bad" "$c_off" "$(pad "запись без токена")" "$code"
  FAIL=$((FAIL+1))
fi

echo
printf 'Итог: %d прошло, %d упало\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
