#!/usr/bin/env python3
"""
Собирает docs/code-map.tsv в HTML-страницу для пула документов.

Источник правды — TSV в репозитории: он меняется тем же коммитом,
что и код. HTML — производная, её кладут в пул рядом с указателем.
Руками HTML не правят: правка потеряется при следующей сборке.

Запуск из корня репозитория:
    python3 ops/render-code-map.py [выходной_файл]

По умолчанию пишет в code-map.html.
"""

import sys
import csv
import html
import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# реестр ищем рядом со скриптом, затем в docs/ — чтобы переезд файла
# между ops/ и docs/ не ломал сборку
CANDIDATES = [ROOT / "ops" / "code-map.tsv", ROOT / "docs" / "code-map.tsv"]
SRC = next((p for p in CANDIDATES if p.exists()), CANDIDATES[0])
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("code-map.html")

STATUS_CLASS = {
    "актуально": "ok",
    "расходится": "bad",
    "не сверялось": "unk",
}
LINK_CLASS = {
    "дубль": "dup",
    "контракт": "con",
    "описание": "des",
}


def read_rows(path: Path):
    if not path.exists():
        sys.exit("Не найден code-map.tsv. Искал: " + ", ".join(str(c) for c in CANDIDATES))
    rows = []
    with path.open(encoding="utf-8") as fh:
        lines = [ln for ln in fh if not ln.startswith("#") and ln.strip()]
    reader = csv.DictReader(lines, delimiter="\t")
    for r in reader:
        rows.append({(k or "").strip(): (v or "").strip() for k, v in r.items()})
    return rows


def esc(s):
    return html.escape(s or "")


def build(rows):
    counts = {"актуально": 0, "расходится": 0, "не сверялось": 0}
    dup = 0
    for r in rows:
        counts[r.get("статус", "")] = counts.get(r.get("статус", ""), 0) + 1
        if r.get("связь") == "дубль":
            dup += 1

    body = []
    for r in rows:
        st = r.get("статус", "")
        lk = r.get("связь", "")
        doc = r.get("документ", "")
        # строки, где документ = имя перенесённого файла, показываем иначе
        moved = r.get("описывает", "") == "—"
        doc_cell = (
            f'<span class="moved">{esc(doc)}</span>'
            if moved
            else f'<a href="{esc(doc)}">{esc(doc)}</a>'
        )
        haystack = " ".join([
            doc, r.get("описывает",""), r.get("код",""), lk, st, r.get("замечание","")
        ]).lower()
        body.append(
            f'<tr data-st="{esc(st)}" data-lk="{esc(lk)}" data-q="{esc(haystack)}">'
            f'<td class="doc">{doc_cell}</td>'
            f'<td>{esc(r.get("описывает",""))}</td>'
            f'<td class="mono">{esc(r.get("код",""))}</td>'
            f'<td><span class="tag {LINK_CLASS.get(lk,"")}">{esc(lk)}</span></td>'
            f'<td class="dt">{esc(r.get("сверено",""))}</td>'
            f'<td><span class="tag {STATUS_CLASS.get(st,"")}">{esc(st)}</span></td>'
            f'<td class="note">{esc(r.get("замечание",""))}</td>'
            "</tr>"
        )

    stamp = datetime.date.today().isoformat()
    return f"""<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Реестр соответствия · документы и код</title>
<style>
:root{{--ink:#141A21;--ink2:#3E4A57;--ink3:#6C7681;--paper:#F7F8F6;--paper2:#fff;
--line:#DDE2DB;--ok:#0E7A4E;--warn:#9A6A12;--stop:#A62B2B;--blue:#1D5FBF;}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--paper);color:var(--ink);font-size:14px;line-height:1.55;
font-family:-apple-system,'Segoe UI',Roboto,sans-serif}}
.w{{max-width:1240px;margin:0 auto;padding:26px 20px 70px}}
h1{{font-size:20px;margin:0 0 4px}}
.sub{{color:var(--ink2);font-size:13px;max-width:88ch;margin:0 0 14px}}
.bar{{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:14px 0 10px}}
.bar input{{flex:1;min-width:200px;max-width:340px;padding:7px 11px;border:1px solid var(--line);
border-radius:6px;font-size:13px;font-family:inherit;background:var(--paper2);color:var(--ink)}}
.bar input:focus{{outline:2px solid var(--blue);outline-offset:-1px}}
.stats{{display:flex;gap:8px;flex-wrap:wrap;margin:0 0 18px}}
.st{{border:1px solid var(--line);background:var(--paper2);border-radius:4px;padding:7px 12px;
font-size:12.5px;cursor:pointer;user-select:none;font-family:inherit;color:var(--ink);text-align:left}}
.st:hover{{border-color:var(--ink3)}}
.st b{{font-size:16px;display:block;line-height:1.15}}
.st.on{{background:var(--ink);border-color:var(--ink);color:#fff}}
.st.on b{{color:#fff}}
.shown{{font-size:12px;color:var(--ink3);margin-left:auto}}
.empty{{padding:26px 10px;text-align:center;color:var(--ink3);font-size:13px}}
tr.hide{{display:none}}
table{{width:100%;border-collapse:collapse;background:var(--paper2);border:1px solid var(--line);font-size:12.7px}}
th{{text-align:left;padding:8px 9px;background:var(--paper);border-bottom:1px solid var(--line);
font-size:10.5px;letter-spacing:.05em;text-transform:uppercase;color:var(--ink3);font-weight:600}}
td{{padding:8px 9px;border-bottom:1px solid var(--line);vertical-align:top}}
tr:last-child td{{border-bottom:none}}
.doc a{{color:var(--blue);text-decoration:none;font-family:ui-monospace,monospace;font-size:11.8px}}
.doc a:hover{{text-decoration:underline}}
.moved{{font-family:ui-monospace,monospace;font-size:11.8px;color:var(--ink3)}}
.mono{{font-family:ui-monospace,monospace;font-size:11.5px;color:var(--ink2)}}
.dt{{font-family:ui-monospace,monospace;font-size:11.5px;white-space:nowrap;color:var(--ink2)}}
.note{{color:var(--ink2);font-size:12px;max-width:42ch}}
.tag{{display:inline-block;font-size:10.5px;font-weight:600;border-radius:2px;padding:1px 7px;white-space:nowrap}}
.ok{{background:rgba(14,122,78,.1);color:var(--ok);border:1px solid rgba(14,122,78,.3)}}
.bad{{background:rgba(166,43,43,.08);color:var(--stop);border:1px solid rgba(166,43,43,.3)}}
.unk{{background:rgba(154,106,18,.1);color:var(--warn);border:1px solid rgba(154,106,18,.32)}}
.dup{{background:rgba(166,43,43,.08);color:var(--stop);border:1px solid rgba(166,43,43,.3)}}
.con{{background:rgba(29,95,191,.09);color:var(--blue);border:1px solid rgba(29,95,191,.3)}}
.des{{background:var(--paper);color:var(--ink3);border:1px solid var(--line)}}
footer{{margin-top:22px;font-size:12px;color:var(--ink3)}}
</style>
</head>
<body><div class="w">
<h1>Реестр соответствия · документы пула и код</h1>
<p class="sub">Какой документ описывает какой файл кода и сверялись ли они. Источник правды —
<code>{SRC.parent.name}/code-map.tsv</code> в репозитории; эта страница собирается из него и правится только там.
Правило: меняешь логику в коде — в том же коммите ставишь дату сверки или помечаешь документ как расходящийся.</p>
<div class="bar">
  <input id="q" type="search" placeholder="Поиск по документу, коду, замечанию…" autocomplete="off">
  <span class="shown" id="shown"></span>
</div>
<div class="stats" id="filters">
  <button class="st on" data-f="all"><b>{len(rows)}</b>все записи</button>
  <button class="st" data-f="st:актуально"><b>{counts.get('актуально',0)}</b>актуально</button>
  <button class="st" data-f="st:расходится"><b>{counts.get('расходится',0)}</b>расходится</button>
  <button class="st" data-f="st:не сверялось"><b>{counts.get('не сверялось',0)}</b>не сверялось</button>
  <button class="st" data-f="lk:дубль"><b>{dup}</b>дублируют логику</button>
</div>
<table>
<thead><tr><th>Документ</th><th>Описывает</th><th>Код</th><th>Связь</th><th>Сверено</th><th>Статус</th><th>Замечание</th></tr></thead>
<tbody>
{chr(10).join(body)}
</tbody></table>
<div class="empty" id="empty" style="display:none">Ничего не найдено</div>
<footer>Собрано {stamp} из <code>{SRC.parent.name}/code-map.tsv</code>. Пересобрать: <code>python3 ops/render-code-map.py</code></footer>
</div>
<script>
(function(){{
  var rows = Array.prototype.slice.call(document.querySelectorAll('tbody tr'));
  var btns = Array.prototype.slice.call(document.querySelectorAll('#filters .st'));
  var q = document.getElementById('q');
  var shown = document.getElementById('shown');
  var empty = document.getElementById('empty');
  var table = document.querySelector('table');
  var flt = 'all';

  function apply(){{
    var s = (q.value || '').trim().toLowerCase();
    var n = 0;
    rows.forEach(function(tr){{
      var okF = true;
      if (flt !== 'all') {{
        var parts = flt.split(':');
        var val = parts[0] === 'st' ? tr.getAttribute('data-st') : tr.getAttribute('data-lk');
        okF = (val === parts.slice(1).join(':'));
      }}
      var okQ = !s || (tr.getAttribute('data-q') || '').indexOf(s) !== -1;
      var show = okF && okQ;
      tr.classList.toggle('hide', !show);
      if (show) n++;
    }});
    shown.textContent = n === rows.length ? '' : ('показано ' + n + ' из ' + rows.length);
    empty.style.display = n ? 'none' : 'block';
    table.style.display = n ? '' : 'none';
  }}

  btns.forEach(function(b){{
    b.addEventListener('click', function(){{
      // повторный клик по активному фильтру снимает его
      if (b.classList.contains('on') && flt !== 'all') {{ flt = 'all'; }}
      else {{ flt = b.getAttribute('data-f'); }}
      btns.forEach(function(x){{
        x.classList.toggle('on', x.getAttribute('data-f') === flt);
      }});
      apply();
    }});
  }});

  q.addEventListener('input', apply);
  apply();
}})();
</script>
</body></html>
"""


if __name__ == "__main__":
    rows = read_rows(SRC)
    OUT.write_text(build(rows), encoding="utf-8")
    print(f"{OUT} — {len(rows)} записей")
