# Спринт 0 · Фундамент

Замена Google Sheets на PostgreSQL + REST API для маркетплейса.
massamadre.ru продолжает работать — данные переезжают из Sheets в БД.

## Структура

```
sprint0/
├── schema/
│   └── 01_schema.sql       # 13 таблиц (привязаны к статьям Правил ред. 2)
├── seed/
│   └── 02_seed_massamadre.sql  # Пилот: 4 SKU, 3 покупателя, тарифы, клиринг
├── api/
│   └── server.js            # REST API (Express + pg)
├── config/
│   └── seller.config.example.json  # Конфиг магазина (задача 0.3)
├── package.json
└── README.md
```

## Запуск

```bash
# 1. PostgreSQL (локально или Supabase/Render)
createdb marketplace

# 2. Схема + данные
psql marketplace -f schema/01_schema.sql
psql marketplace -f seed/02_seed_massamadre.sql

# 3. API
npm install
DATABASE_URL=postgresql://localhost:5432/marketplace npm start

# 4. Проверка
curl http://localhost:3000/api/health
curl http://localhost:3000/api/v1/shop/massamadre
curl http://localhost:3000/api/v1/shop/massamadre/products
curl "http://localhost:3000/api/v1/catalog/search?q=хлеб"
curl http://localhost:3000/api/v1/config/massamadre
```

## Endpoints

### Public (покупатель)
- `GET /api/v1/shop/{slug}` — магазин по slug
- `GET /api/v1/shop/{slug}/products` — товары магазина (?cat, ?sort, ?page)
- `GET /api/v1/sku/{id}` — карточка SKU (source of truth)
- `GET /api/v1/catalog/search` — каталог Системы (?q, ?cat, ?price_min, ?sort)
- `GET /api/v1/catalog/shops` — каталог магазинов
- `GET /api/v1/catalog/categories` — дерево категорий
- `POST /api/v1/cart/add` — добавить в корзину (атомарное резервирование)
- `POST /api/v1/orders` — создать заказ (+ авто-клиринг)
- `GET /api/v1/orders/{id}` — заказ с позициями и клирингом

### Seller
- `GET /api/v1/seller/{id}/products` — товары селлера
- `POST /api/v1/seller/{id}/products` — создать SKU
- `PATCH /api/v1/seller/{id}/products/{sku_id}` — обновить SKU
- `GET /api/v1/seller/{id}/stats` — статистика

### Config
- `GET /api/v1/config/{slug}` — конфиг магазина для рендеринга витрины

## Привязка к Правилам системы ред. 2

| Таблица | Статья | Что реализует |
|---------|--------|---------------|
| participants | ст. 4 | Реестр участников |
| participant_tariffs | ст. 3.2 | Тарифы-оферта |
| infra_bindings | ст. 3.3.1 | Привязка селлер ↔ операторы |
| shops | ст. 9.2 | Магазин селлера |
| skus | ст. 9.4 | SKU-атом + инвариант И4 |
| customers | ст. 10 | Покупательская база |
| customer_bindings | ст. 10.4 | source_type MIGRATED/NETWORK |
| orders | ст. 6 | Заказы (entry_point, source_type) |
| clearing_splits | ст. 6.7 | Расщепление клиринга |
| reviews | ст. 4.8 | Отзывы (антиманипуляция) |

## Следующий шаг

Задача 0.4: Routing — URL /{seller_slug}/* подгружает конфиг из API.
massamadre.ru/catalog → /massamadre/catalog (редирект).
