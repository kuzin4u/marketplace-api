/* ============================================================
   auth-guard.js — вход и сессия для страниц продавца.

   Подключается ПОСЛЕ config.js:
       <script src="config.js"></script>
       <script src="auth-guard.js"></script>

   Что делает:
     1. Охрана. Нет токена — сразу переадресация на вход, а не
        пустая форма. Адрес текущей страницы передаётся, чтобы
        после входа вернуться туда, откуда ушёл.
     2. Обработка 401. Любой запрос через AUTH.fetch при истёкшей
        сессии показывает «Сессия истекла» и кнопку входа —
        вместо молчания или мнимого успеха.
     3. Шапка. Под кем вошёл и кнопка выхода: на чужом компьютере
        токен живёт двенадцать часов и переживает закрытие вкладки.

   Страницы покупателя (витрина, корзина) НЕ подключают этот файл:
   покупательские маршруты открыты и токена не требуют.
   ============================================================ */

(function () {
  'use strict';

  var TOKEN_KEY  = 'seller_token';
  var SELLER_KEY = 'seller_id';
  var LOGIN_PAGE = 'seller-login.html';

  var base = (window.API_BASE || '').replace(/\/+$/, '');

  function token()  { try { return localStorage.getItem(TOKEN_KEY) || null; } catch (e) { return null; } }
  function seller() { try { return localStorage.getItem(SELLER_KEY) || null; } catch (e) { return null; } }

  function clear() {
    try { localStorage.removeItem(TOKEN_KEY); localStorage.removeItem(SELLER_KEY); } catch (e) {}
  }

  // Куда вернуться после входа. Только имя файла с параметрами —
  // абсолютный адрес принимать нельзя, иначе форму входа можно
  // использовать для переброса на чужой сайт.
  function returnTo() {
    return encodeURIComponent(location.pathname.split('/').pop() + location.search);
  }

  function toLogin(reason) {
    var q = '?next=' + returnTo() + (reason ? '&reason=' + reason : '');
    location.replace(LOGIN_PAGE + q);
  }

  // ---------- сообщение об истёкшей сессии ----------
  var shown = false;
  function sessionExpired(detail) {
    if (shown) return;
    shown = true;
    clear();

    var box = document.createElement('div');
    box.setAttribute('role', 'alert');
    box.style.cssText =
      'position:fixed;inset:0;z-index:99999;display:flex;align-items:center;' +
      'justify-content:center;background:rgba(20,26,33,.55);backdrop-filter:blur(3px);' +
      'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif';
    box.innerHTML =
      '<div style="background:#fff;border-radius:10px;padding:26px 28px;max-width:380px;' +
      'box-shadow:0 12px 40px rgba(0,0,0,.25);text-align:center">' +
      '<div style="font-size:17px;font-weight:600;margin-bottom:8px;color:#141A21">Сессия истекла</div>' +
      '<div style="font-size:14px;color:#3E4A57;line-height:1.5;margin-bottom:20px">' +
      (detail || 'Войдите снова, чтобы продолжить работу.') + '</div>' +
      '<button id="ag-relogin" style="background:#2E5B3A;color:#fff;border:0;border-radius:6px;' +
      'padding:10px 22px;font-size:14px;font-weight:500;cursor:pointer;font-family:inherit">Войти</button>' +
      '</div>';
    document.body.appendChild(box);
    document.getElementById('ag-relogin').addEventListener('click', function () { toLogin('expired'); });
  }

  // ---------- запрос с токеном ----------
  // Возвращает Response, как обычный fetch. При 401 показывает
  // сообщение и отклоняет промис — вызывающий код не должен
  // принять неудачу за успех.
  function authFetch(url, opts) {
    opts = opts || {};
    var headers = Object.assign({}, opts.headers || {});
    var t = token();
    if (t) headers['Authorization'] = 'Bearer ' + t;

    return fetch(url, Object.assign({}, opts, { headers: headers })).then(function (res) {
      if (res.status === 401) {
        return res.json().catch(function () { return {}; }).then(function (body) {
          sessionExpired(body.detail);
          throw new Error(body.error || 'unauthorized');
        });
      }
      if (res.status === 403) {
        return res.json().catch(function () { return {}; }).then(function (body) {
          throw new Error(body.detail || 'Доступ запрещён');
        });
      }
      return res;
    });
  }

  // ---------- шапка ----------
  function mountBar(login, sellerId) {
    if (document.getElementById('ag-bar')) return;
    var bar = document.createElement('div');
    bar.id = 'ag-bar';
    bar.style.cssText =
      'position:fixed;top:0;right:0;z-index:9998;display:flex;align-items:center;gap:10px;' +
      'padding:6px 12px;background:rgba(255,255,255,.94);border:1px solid #DDE2DB;' +
      'border-top:0;border-right:0;border-radius:0 0 0 8px;font-size:12.5px;' +
      'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;color:#3E4A57';
    bar.innerHTML =
      '<span title="' + (sellerId || '') + '">' + (login || sellerId || 'продавец') + '</span>' +
      '<button id="ag-logout" style="background:none;border:0;color:#A62B2B;cursor:pointer;' +
      'font-size:12.5px;font-family:inherit;padding:2px 4px">выйти</button>';
    document.body.appendChild(bar);
    document.getElementById('ag-logout').addEventListener('click', function () {
      clear();
      location.replace(LOGIN_PAGE);
    });
  }

  // ---------- охрана ----------
  // Вызывается страницей явно: на самой форме входа охрана не нужна.
  function guard() {
    if (!token()) { toLogin('required'); return false; }

    // Токен есть, но мог истечь. Проверяем и заодно узнаём, кто вошёл.
    authFetch(base + '/api/v1/auth/me')
      .then(function (r) { return r.json(); })
      .then(function (me) { mountBar(me.login, me.seller_id); })
      .catch(function () { /* 401 уже показан в authFetch */ });

    return true;
  }

  window.AUTH = {
    token: token,
    sellerId: seller,
    fetch: authFetch,
    guard: guard,
    logout: function () { clear(); location.replace(LOGIN_PAGE); },
    headers: function (extra) {
      var h = Object.assign({}, extra || {});
      var t = token();
      if (t) h['Authorization'] = 'Bearer ' + t;
      return h;
    }
  };
})();
