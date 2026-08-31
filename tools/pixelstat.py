#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
МЕРКА ПИКСЕЛЬАРТА — считает по картинке то, чем настоящий пиксельарт отличается
от уменьшенной или сгенерированной формулой картинки.

Не часть игры. Нужна затем, что «похоже на пиксельарт» — суждение, а суждение
нельзя ни повторить, ни сравнить. Здесь те же вопросы заданы числами:

  цветов            сколько всего цветов у непрозрачных точек и сколько из них
                    занимают больше сотой доли площади. У пиксельарта их
                    единицы, у формулы — сотни.
  ступени           сколько различимых ступеней яркости и ровные ли они. Плавная
                    растяжка даёт десятки почти одинаковых ступеней.
  сдвиг тона        уходит ли оттенок в холод к тени и в тепло к свету. Это
                    главный признак руки: простое затемнение оттенка не меняет.
  кластеры          доля точек, сидящих поодиночке (сосед другого цвета со всех
                    сторон). Одиночные точки читаются шумом.
  край              полупрозрачные точки по краю фигурки (у пиксельарта их нет),
                    и ровность лесенки силуэта.
  дизеринг          доля шахматки: точек, у которых оба горизонтальных соседа
                    одного цвета, а сама она другого.
  замощение         шов на стыке и заметность решётки при повторе.

Запуск:
    python3 tools/pixelstat.py КАРТИНКА [КАРТИНКА...]           весь файл целиком
    python3 tools/pixelstat.py --cell=32 --col=6 --row=6 ЛИСТ   одна клетка листа
    python3 tools/pixelstat.py --cell=32 --grid ЛИСТ            все клетки, сводкой
    python3 tools/pixelstat.py --json ...                       машинный ответ
"""

import sys
import json
import math
import colorsys
from collections import Counter, deque

from PIL import Image


# ---------------------------------------------------------------- вспомогательное

def rgb_to_hsv(c):
    r, g, b = c[0] / 255.0, c[1] / 255.0, c[2] / 255.0
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    return h * 360.0, s, v


def luma(c):
    return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255.0


def hue_delta(a, b):
    """Разница оттенков по кругу, со знаком: куда ушёл b относительно a."""
    d = (b - a + 540.0) % 360.0 - 180.0
    return d


def load(path):
    img = Image.open(path).convert("RGBA")
    return img


def crop_cell(img, cell, col, row):
    return img.crop((col * cell, row * cell, (col + 1) * cell, (row + 1) * cell))


# ---------------------------------------------------------------- сами мерки

def stat_colors(px, w, h):
    """Сколько цветов и сколько из них весомых."""
    cnt = Counter()
    solid = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            solid += 1
            cnt[(r, g, b)] += 1
    if solid == 0:
        return None
    weighty = [c for c, n in cnt.items() if n >= max(1, solid * 0.01)]
    # Сколько цветов покрывает девять десятых площади — «рабочая палитра».
    run = 0
    core = 0
    for c, n in cnt.most_common():
        run += n
        core += 1
        if run >= solid * 0.9:
            break
    return {
        "точек": solid,
        "цветов": len(cnt),
        "цветов весомых": len(weighty),      # каждый занял больше сотой доли
        "цветов на девять десятых": core,
        "самый частый, доля": round(cnt.most_common(1)[0][1] / solid, 3),
    }


def stat_ramp(px, w, h):
    """Ступени яркости и сдвиг тона вдоль них.

    Ступень — это скопление цветов близкой яркости. Считаем по весомым цветам:
    редкая точка не ступень, а сор.
    """
    cnt = Counter()
    solid = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            solid += 1
            cnt[(r, g, b)] += 1
    if solid == 0:
        return None
    weighty = [(c, n) for c, n in cnt.items() if n >= max(2, solid * 0.01)]
    if len(weighty) < 2:
        return {"ступеней": len(weighty), "сдвиг тона, град": 0.0,
                "прирост насыщенности к тени": 0.0, "шаг яркости средний": 0.0}
    weighty.sort(key=lambda t: luma(t[0]))
    lums = [luma(c) for c, _ in weighty]
    steps = [lums[i + 1] - lums[i] for i in range(len(lums) - 1)]
    # Сдвиг тона: от самой тёмной весомой ступени к самой светлой.
    dark_h, dark_s, _ = rgb_to_hsv(weighty[0][0])
    lite_h, lite_s, _ = rgb_to_hsv(weighty[-1][0])
    # Насыщенность обычно выше в полутени и падает к свету.
    return {
        "ступеней": len(weighty),
        "сдвиг тона, град": round(hue_delta(dark_h, lite_h), 1),
        "насыщенность тень": round(dark_s, 3),
        "насыщенность свет": round(lite_s, 3),
        "шаг яркости средний": round(sum(steps) / len(steps), 4),
        "шаг яркости наибольший": round(max(steps), 4),
        "размах яркости": round(lums[-1] - lums[0], 3),
    }


def _clusters(px, w, h):
    """Связные пятна одного цвета, четырьмя соседями."""
    seen = [[False] * h for _ in range(w)]
    sizes = []
    for y0 in range(h):
        for x0 in range(w):
            if seen[x0][y0]:
                continue
            r, g, b, a = px[x0, y0]
            if a == 0:
                seen[x0][y0] = True
                continue
            col = (r, g, b)
            q = deque([(x0, y0)])
            seen[x0][y0] = True
            n = 0
            while q:
                x, y = q.popleft()
                n += 1
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and not seen[nx][ny]:
                        rr, gg, bb, aa = px[nx, ny]
                        if aa != 0 and (rr, gg, bb) == col:
                            seen[nx][ny] = True
                            q.append((nx, ny))
            sizes.append(n)
    return sizes


def stat_clusters(px, w, h):
    sizes = _clusters(px, w, h)
    if not sizes:
        return None
    total = sum(sizes)
    alone = sum(s for s in sizes if s == 1)
    tiny = sum(s for s in sizes if s <= 2)
    sizes_sorted = sorted(sizes)
    return {
        "пятен": len(sizes),
        "доля точек-одиночек": round(alone / total, 3),
        "доля в пятнах до двух точек": round(tiny / total, 3),
        "пятно среднее": round(total / len(sizes), 2),
        "пятно срединное": sizes_sorted[len(sizes_sorted) // 2],
        "пятно наибольшее": max(sizes),
    }


def stat_edge(px, w, h):
    """Край фигурки: полупрозрачность и ровность лесенки."""
    semi = 0
    solid = 0
    for y in range(h):
        for x in range(w):
            a = px[x, y][3]
            if a == 0:
                continue
            solid += 1
            if a != 255:
                semi += 1
    if solid == 0:
        return None
    # Лесенка: для каждой строки — где начинается и кончается фигурка. Резкие
    # скачки длины ступени и есть «кривая лесенка».
    runs = []
    prev_left = None
    for y in range(h):
        xs = [x for x in range(w) if px[x, y][3] > 0]
        if not xs:
            prev_left = None
            continue
        left = min(xs)
        if prev_left is not None:
            runs.append(abs(left - prev_left))
        prev_left = left
    jag = 0.0
    if len(runs) > 1:
        mean = sum(runs) / len(runs)
        jag = math.sqrt(sum((r - mean) ** 2 for r in runs) / len(runs))
    return {
        "точек непрозрачных": solid,
        "доля полупрозрачных": round(semi / solid, 3),
        "неровность лесенки": round(jag, 2),
    }


def stat_dither(px, w, h):
    """Шахматка: точка, у которой оба соседа слева и справа одного цвета, а она
    другого. У честного дизеринга такие точки складываются в узор, у шума —
    рассыпаны."""
    hits = 0
    solid = 0
    for y in range(h):
        for x in range(1, w - 1):
            c = px[x, y]
            if c[3] == 0:
                continue
            solid += 1
            l, r = px[x - 1, y], px[x + 1, y]
            if l[3] and r[3] and l[:3] == r[:3] and l[:3] != c[:3]:
                hits += 1
    if solid == 0:
        return None
    return {"доля шахматки": round(hits / solid, 3)}


def stat_tile(px, w, h):
    """Бесшовность: насколько стык с самим собой отличается от середины."""
    def diff(a, b):
        return sum(abs(a[i] - b[i]) for i in range(3)) / 3.0

    seam_x = sum(diff(px[w - 1, y], px[0, y]) for y in range(h)) / h
    seam_y = sum(diff(px[x, h - 1], px[x, 0]) for x in range(w)) / w
    inner_x = sum(diff(px[x, y], px[x + 1, y])
                  for y in range(h) for x in range(w - 1)) / (h * (w - 1))
    inner_y = sum(diff(px[x, y], px[x, y + 1])
                  for x in range(w) for y in range(h - 1)) / (w * (h - 1))
    inner = (inner_x + inner_y) / 2.0
    seam = (seam_x + seam_y) / 2.0
    return {
        "шов": round(seam, 2),
        "перепад внутри": round(inner, 2),
        "шов к перепаду": round(seam / inner, 2) if inner > 0.01 else 0.0,
    }


def stat_light(px, w, h):
    """Куда светит: считаем, куда смещён центр тяжести яркости относительно
    центра фигуры. У пиксельарта свет из одного угла, у «подушки» — из центра."""
    sx = sy = wsum = 0.0
    cx = cy = n = 0.0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            l = luma((r, g, b))
            sx += x * l
            sy += y * l
            wsum += l
            cx += x
            cy += y
            n += 1
    if n == 0 or wsum == 0:
        return None
    dx = sx / wsum - cx / n
    dy = sy / wsum - cy / n
    return {
        "снос света по x": round(dx, 2),
        "снос света по y": round(dy, 2),
        "снос света всего": round(math.hypot(dx, dy), 2),
    }


def measure(img, name=""):
    px = img.load()
    w, h = img.size
    out = {"имя": name, "размер": [w, h]}
    for key, fn in (("цвет", stat_colors), ("пандус", stat_ramp),
                    ("кластеры", stat_clusters), ("край", stat_edge),
                    ("дизеринг", stat_dither), ("замощение", stat_tile),
                    ("свет", stat_light)):
        got = fn(px, w, h)
        if got:
            out[key] = got
    return out


# ---------------------------------------------------------------- вывод

def show(m):
    print("=" * 70)
    print(m["имя"], " ", m["размер"][0], "x", m["размер"][1])
    for key in ("цвет", "пандус", "кластеры", "край", "дизеринг", "замощение", "свет"):
        if key not in m:
            continue
        print("  " + key + ":")
        for k, v in m[key].items():
            print("    %-32s %s" % (k, v))


def main(argv):
    cell = None
    col = row = None
    grid = False
    as_json = False
    files = []
    for a in argv:
        if a.startswith("--cell="):
            cell = int(a.split("=")[1])
        elif a.startswith("--col="):
            col = int(a.split("=")[1])
        elif a.startswith("--row="):
            row = int(a.split("=")[1])
        elif a == "--grid":
            grid = True
        elif a == "--json":
            as_json = True
        else:
            files.append(a)

    out = []
    for f in files:
        img = load(f)
        if cell and grid:
            cols = img.width // cell
            rows = img.height // cell
            for c in range(cols):
                for r in range(rows):
                    sub = crop_cell(img, cell, c, r)
                    out.append(measure(sub, "%s [%d,%d]" % (f, c, r)))
        elif cell and col is not None:
            sub = crop_cell(img, cell, col, row if row is not None else 0)
            out.append(measure(sub, "%s [%d,%d]" % (f, col, row or 0)))
        else:
            out.append(measure(img, f))

    if as_json:
        print(json.dumps(out, ensure_ascii=False, indent=1))
    else:
        for m in out:
            show(m)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
