/* ============================================================
   Единая точка конфигурации фронта.

   Адрес API живёт здесь и только здесь. При переезде правится
   одна строка — PROD_API. Пять страниц (seller-login, shop-form,
   sku-crud, vitrina-live, alpha-dashboard-live) читают window.API_BASE.

   Подключается в <head> каждой страницы ДО основного скрипта:
     <script src="config.js"></script>
   ============================================================ */

(function () {
  'use strict';

  // Боевой адрес. ЕДИНСТВЕННОЕ место, которое правится при переезде API.
  var PROD_API = 'https://marketplace-api-ujfh.onrender.com';

  // Локальная разработка: страница, открытая с localhost или из файла,
  // сама целится в локальный сервер — исходники править не нужно.
  var LOCAL_API = 'http://localhost:3000';

  var host = window.location.hostname;
  var isLocal = host === 'localhost' || host === '127.0.0.1' || host === '';

  // Ручное переопределение без правки кода: ?api=https://stage.example.com
  // Нужно, чтобы ткнуть формы в проверочный контур и не забыть откатить.
  // Выбор живёт до закрытия вкладки.
  var override = null;
  try {
    var qs = new URLSearchParams(window.location.search).get('api');
    if (qs) { sessionStorage.setItem('API_OVERRIDE', qs); override = qs; }
    else { override = sessionStorage.getItem('API_OVERRIDE'); }
  } catch (e) { /* sessionStorage может быть недоступен — не повод падать */ }

  window.API_BASE = override || (isLocal ? LOCAL_API : PROD_API);

  if (override) {
    console.warn('[config] API переопределён вручную:', window.API_BASE,
                 '— сбросить: sessionStorage.removeItem("API_OVERRIDE")');
  } else {
    console.info('[config] API:', window.API_BASE);
  }
})();
