#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
СТЕНД СРАВНЕНИЯ — ставит рядом столбцы нашего листа, рукописный эталон и
скачанные референсы, и показывает, где мы от них отличаемся.

Зачем именно так. «Похоже на пиксельарт» — суждение, его нельзя ни повторить,
ни сравнить с прошлым разом. Здесь тот же вопрос задан числами, и у каждого
числа есть эталон: не выдуманная норма, а замер по настоящему пиксельарту.

Запуск:
    python3 tools/pixelcmp.py                     наш лист против руки
    python3 tools/pixelcmp.py --refs=art/refs     ... и против референсов
    python3 tools/pixelcmp.py --part=leaf         только лист лианы
"""

import os
import sys
import glob
import statistics as st

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pixelstat import load, crop_cell, measure  # noqa: E402


TILE = 32
STAGES = 9

# Столбцы листа по частям — те же, что в Texture.gd.
PARTS = {
    "moss": (list(range(0, 4)), "ворсинка мха"),
    "body": ([4], "тело мха"),
    "bark": ([5], "кора лианы"),
    "leaf": ([6, 7, 8], "лист лианы"),
    "bloom": ([9, 10], "лепесток цветка"),
    "liabody": ([11], "тело лиамоха"),
    "liafuzz": ([12], "ворсинка лиамоха"),
}

# Что показываем. Порядок — по важности: сверху то, что сильнее всего отличает
# пиксельарт от картинки, посчитанной формулой.
ROWS = [
    ("цвет", "цветов", "цветов всего"),
    ("цвет", "цветов на девять десятых", "цветов на 9/10 площади"),
    ("пандус", "ступеней", "ступеней тона"),
    ("пандус", "сдвиг тона, град", "сдвиг тона, град"),
    ("пандус", "размах яркости", "размах яркости"),
    ("пандус", "шаг яркости средний", "шаг ступени"),
    ("кластеры", "доля точек-одиночек", "доля одиночных точек"),
    ("кластеры", "пятно среднее", "пятно среднее, точек"),
    ("дизеринг", "доля шахматки", "доля шахматки"),
    ("край", "доля полупрозрачных", "доля полупрозрачных"),
    ("край", "неровность лесенки", "неровность лесенки"),
    ("замощение", "шов к перепаду", "шов к перепаду"),
    ("свет", "снос света всего", "снос света"),
]


def sheet_cells(path, cols):
    img = load(path)
    out = []
    for c in cols:
        if (c + 1) * TILE > img.width:
            continue
        for s in range(STAGES):
            if (s + 1) * TILE > img.height:
                continue
            sub = crop_cell(img, TILE, c, s)
            # Пустые клетки не меряем: они ничего не говорят.
            if sub.getbbox() is None:
                continue
            out.append(measure(sub, "%s[%d,%d]" % (os.path.basename(path), c, s)))
    return out


def ref_cells(folder):
    """Референсы: каждый файл целиком, но если он крупный — режем на клетки
    32x32 и берём непустые. Настоящие спрайтовые листы так и устроены."""
    out = []
    for path in sorted(glob.glob(os.path.join(folder, "*.png"))):
        img = load(path)
        if img.width <= 64 and img.height <= 64:
            out.append(measure(img, os.path.basename(path)))
            continue
        cols = img.width // TILE
        rows = img.height // TILE
        for c in range(cols):
            for r in range(rows):
                sub = crop_cell(img, TILE, c, r)
                if sub.getbbox() is None:
                    continue
                px = sub.load()
                solid = sum(1 for y in range(sub.height) for x in range(sub.width)
                            if px[x, y][3] > 0)
                # Клетка, занятая меньше чем на четверть, — это край спрайта, а
                # не картинка: мерить по ней палитру нечестно.
                if solid < TILE * TILE * 0.25:
                    continue
                out.append(measure(sub, "%s[%d,%d]" % (os.path.basename(path), c, r)))
    return out


def digest(cells, group, key):
    vals = [c[group][key] for c in cells if group in c and key in c[group]]
    if not vals:
        return None
    return st.median(vals), min(vals), max(vals)


def column(cells):
    return {(g, k): digest(cells, g, k) for g, k, _ in ROWS}


def main(argv):
    sheet = "art/moss.png"
    hand = "art/moss_hand.png"
    refs = None
    only = None
    for a in argv:
        if a.startswith("--refs="):
            refs = a.split("=", 1)[1]
        elif a.startswith("--part="):
            only = a.split("=", 1)[1]
        elif a.startswith("--sheet="):
            sheet = a.split("=", 1)[1]

    groups = []
    if refs and os.path.isdir(refs):
        cells = ref_cells(refs)
        if cells:
            groups.append(("РЕФЕРЕНСЫ (%d)" % len(cells), column(cells)))
    if os.path.exists(hand):
        cells = sheet_cells(hand, list(range(4)))
        groups.append(("РУКА (%d)" % len(cells), column(cells)))
    for key, (cols, ru) in PARTS.items():
        if only and key != only:
            continue
        cells = sheet_cells(sheet, cols)
        if cells:
            groups.append(("%s (%d)" % (ru, len(cells)), column(cells)))

    head = "%-26s" % "величина"
    for name, _ in groups:
        head += "%20s" % name[:20]
    print(head)
    print("-" * len(head))
    for g, k, ru in ROWS:
        line = "%-26s" % ru
        for _, col in groups:
            got = col.get((g, k))
            line += "%20s" % ("—" if got is None else "%.3f" % got[0])
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
