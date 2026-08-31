#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
СТОРОЖ ПИКСЕЛЬАРТА — проверяет лист по правилам, добытым разведкой 31.08.2026.

Отличается от `pixelstat.py` тем, что не описывает, а СУДИТ: у каждого правила
есть норма, и ответ — прошло или нет. Нормы взяты не с потолка: часть замерена
по рукописному листу пользователя, часть пришла из разбора приёмов пиксельарта.

Правила (в скобках — к чему применимо):

  силуэт        (фигурки) уменьшить маску вчетверо и вернуть: IoU >= 0.75.
                Форма, пропадающая при уменьшении, не читается и в игре.
  толщина       (фигурки) ничего тоньше двух точек: морфологическое открытие
                не должно съедать больше десятой части площади и не должно
                уничтожать ни одной связной части.
  разновидности (фигурки) три листа, два лепестка, четыре ворсинки обязаны
                отличаться СИЛУЭТОМ: попарная IoU <= 0.80.
  цвета         (все) на фигурке не больше 8 весомых цветов, на бесшовном
                образце не больше 14.
  пандус        (все) ступени стоят по светлоте ровно и с ощутимым шагом; двух
                почти одинаковых цветов быть не должно.
  тон           (цветные) от тёмной ступени к светлой оттенок уходит не меньше
                чем на 10 градусов. У серой коры правило не спрашивается.
  край          (фигурки) альфа только 0 или 255; под прозрачными точками у
                края краска залита (иначе на 3D по краю чёрная кайма).
  кластеры      (все) одиночных точек не больше, чем у руки.

Запуск:
    python3 tools/pixelcheck.py                  судить art/moss.png
    python3 tools/pixelcheck.py ЛИСТ --json
"""

import sys
import json
import colorsys
from collections import Counter, deque

from PIL import Image

TILE = 32
STAGES = 9

PARTS = {
    "moss": (list(range(0, 4)), "ворсинка мха", False),
    "body": ([4], "тело мха", True),
    "bark": ([5], "кора лианы", True),
    "leaf": ([6, 7, 8], "лист лианы", False),
    "bloom": ([9, 10], "лепесток цветка", False),
    "liabody": ([11], "тело лиамоха", True),
    "liafuzz": ([12], "ворсинка лиамоха", False),
}

# Кора серая нарочно: цвет ей дают вершины, и увести оттенок нельзя.
NO_HUE = {"bark"}

NORM = {
    "силуэт IoU": 0.75,
    "потеря на открытии": 0.10,
    "разновидности IoU": 0.80,
    "цветов фигурка": 8,
    "цветов образец": 14,
    "ступень наименьшая": 0.012,
    "сдвиг тона": 10.0,
    "доля полупрозрачных": 0.0,
    "доля одиночек": 0.62,
}


def cells(img, cols):
    out = []
    for c in cols:
        for s in range(STAGES):
            if (c + 1) * TILE > img.width or (s + 1) * TILE > img.height:
                continue
            sub = img.crop((c * TILE, s * TILE, (c + 1) * TILE, (s + 1) * TILE))
            if sub.getbbox() is None:
                continue
            out.append((c, s, sub))
    return out


def mask_of(sub):
    px = sub.load()
    return [[1 if px[x, y][3] > 127 else 0 for y in range(TILE)] for x in range(TILE)]


def iou(a, b):
    inter = sum(1 for x in range(TILE) for y in range(TILE) if a[x][y] and b[x][y])
    union = sum(1 for x in range(TILE) for y in range(TILE) if a[x][y] or b[x][y])
    return inter / union if union else 1.0


def shrink_grow(m, k=4):
    """Уменьшить маску в k раз усреднением и вернуть обратно."""
    small = []
    n = TILE // k
    for x in range(n):
        col = []
        for y in range(n):
            s = sum(m[x * k + i][y * k + j] for i in range(k) for j in range(k))
            col.append(1 if s >= k * k * 0.5 else 0)
        small.append(col)
    return [[small[x // k][y // k] for y in range(TILE)] for x in range(TILE)], small


def erode(m):
    out = [[0] * TILE for _ in range(TILE)]
    for x in range(TILE):
        for y in range(TILE):
            if not m[x][y]:
                continue
            ok = True
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if not (0 <= nx < TILE and 0 <= ny < TILE) or not m[nx][ny]:
                    ok = False
                    break
            out[x][y] = 1 if ok else 0
    return out


def dilate(m):
    out = [[0] * TILE for _ in range(TILE)]
    for x in range(TILE):
        for y in range(TILE):
            if m[x][y]:
                out[x][y] = 1
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < TILE and 0 <= ny < TILE and m[nx][ny]:
                    out[x][y] = 1
                    break
    return out


def parts_count(m):
    seen = [[False] * TILE for _ in range(TILE)]
    n = 0
    for x0 in range(TILE):
        for y0 in range(TILE):
            if m[x0][y0] and not seen[x0][y0]:
                n += 1
                q = deque([(x0, y0)])
                seen[x0][y0] = True
                while q:
                    x, y = q.popleft()
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < TILE and 0 <= ny < TILE \
                                and m[nx][ny] and not seen[nx][ny]:
                            seen[nx][ny] = True
                            q.append((nx, ny))
    return n


def area(m):
    return sum(sum(col) for col in m)


def colours(sub):
    px = sub.load()
    cnt = Counter()
    solid = 0
    for y in range(TILE):
        for x in range(TILE):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            solid += 1
            cnt[(r, g, b)] += 1
    return cnt, solid


def luma(c):
    return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255.0


def hue(c):
    h, _, _ = colorsys.rgb_to_hsv(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
    return h * 360.0


def hue_delta(a, b):
    return (b - a + 540.0) % 360.0 - 180.0


def check_part(img, key):
    cols, ru, solid_kind = PARTS[key]
    got = cells(img, cols)
    if not got:
        return None
    bad = []
    worst = {}

    # --- силуэт и толщина: только у вырезанных фигурок
    if not solid_kind:
        ious = []
        losses = []
        lost_parts = 0
        semi = 0
        bleed_bad = 0
        for c, s, sub in got:
            m = mask_of(sub)
            back, _ = shrink_grow(m)
            ious.append(iou(m, back))
            op = dilate(erode(m))
            a0 = area(m)
            if a0:
                losses.append((a0 - area(op)) / a0)
            if parts_count(op) < parts_count(m):
                lost_parts += 1
            px = sub.load()
            for y in range(TILE):
                for x in range(TILE):
                    a = px[x, y][3]
                    if 0 < a < 255:
                        semi += 1
                    if a == 0:
                        # Под прозрачной точкой у самого края краска должна быть
                        # залита: иначе билинейный фильтр в 3D тянет из неё
                        # чёрное и по силуэту идёт тёмная кайма.
                        near = any(0 <= x + dx < TILE and 0 <= y + dy < TILE
                                   and px[x + dx, y + dy][3] > 0
                                   for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
                        if near and px[x, y][:3] == (0, 0, 0):
                            bleed_bad += 1
        worst["силуэт IoU (мин)"] = round(min(ious), 3)
        worst["потеря на открытии (макс)"] = round(max(losses), 3)
        worst["частей потеряно, клеток"] = lost_parts
        worst["полупрозрачных точек"] = semi
        worst["чёрных точек под краем"] = bleed_bad
        if min(ious) < NORM["силуэт IoU"]:
            bad.append("силуэт пропадает при уменьшении")
        if max(losses) > NORM["потеря на открытии"]:
            bad.append("есть детали тоньше двух точек")
        if lost_parts:
            bad.append("при открытии пропадают целые части")
        if semi:
            bad.append("есть полупрозрачные точки")
        if bleed_bad:
            bad.append("под краем не залита краска — в 3D будет тёмная кайма")

        # разновидности расходятся силуэтом
        if len(cols) > 1:
            pair = []
            for s in range(STAGES):
                masks = [mask_of(sub) for c, ss, sub in got if ss == s]
                for i in range(len(masks)):
                    for j in range(i + 1, len(masks)):
                        pair.append(iou(masks[i], masks[j]))
            if pair:
                worst["разновидности IoU (макс)"] = round(max(pair), 3)
                if max(pair) > NORM["разновидности IoU"]:
                    bad.append("разновидности не расходятся силуэтом")

    # --- цвета и пандус: у всех
    cap = NORM["цветов образец"] if solid_kind else NORM["цветов фигурка"]
    many = 0
    small_step = 1.0
    twist = 0.0
    alone_max = 0.0
    for c, s, sub in got:
        cnt, solid = colours(sub)
        if not solid:
            continue
        weighty = [col for col, n in cnt.items() if n >= max(2, solid * 0.01)]
        many = max(many, len(weighty))
        if len(weighty) >= 2:
            weighty.sort(key=luma)
            steps = [luma(weighty[i + 1]) - luma(weighty[i])
                     for i in range(len(weighty) - 1)]
            small_step = min(small_step, min(steps))
            twist = max(twist, abs(hue_delta(hue(weighty[0]), hue(weighty[-1]))))
        # одиночки
        px = sub.load()
        alone = 0
        for y in range(TILE):
            for x in range(TILE):
                if px[x, y][3] == 0:
                    continue
                me = px[x, y][:3]
                same = False
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < TILE and 0 <= ny < TILE and px[nx, ny][3] \
                            and px[nx, ny][:3] == me:
                        same = True
                        break
                if not same:
                    alone += 1
        alone_max = max(alone_max, alone / solid)
    worst["цветов весомых (макс)"] = many
    worst["наименьший шаг ступени"] = round(small_step, 4)
    worst["сдвиг тона (макс)"] = round(twist, 1)
    worst["доля одиночек (макс)"] = round(alone_max, 3)
    if many > cap:
        bad.append("цветов больше %d" % cap)
    if small_step < NORM["ступень наименьшая"]:
        bad.append("две ступени почти одинаковы — это интерполяция, не пандус")
    if key not in NO_HUE and twist < NORM["сдвиг тона"]:
        bad.append("тон вдоль пандуса не уводится")
    if alone_max > NORM["доля одиночек"]:
        bad.append("слишком много одиночных точек")

    return {"часть": ru, "клеток": len(got), "числа": worst, "нарушения": bad}


# =============================================================================
#  ВТОРОЙ ЯРУС МЕРОК — из сводной разведки 31.08.2026
#
#  Это те правила, что отличают пиксельарт от посчитанной формулой картинки
#  вернее всего. Первое из них — самое сильное: у настоящего пиксельарта
#  соседние точки чаще всего ОДНОГО цвета, у интерполяции — почти никогда.
# =============================================================================

def lum255(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def step_stats(sub):
    """Правило «микроступенька — улика интерполяции».

    По всем парам соседей: доля равных и доля отличающихся «чуть-чуть».
    Норма: равных не меньше 0.45, микроступенек не больше 0.05.
    Билинейно уменьшенная фотография даёт примерно 0.05 и 0.40.
    """
    px = sub.load()
    same = micro = total = 0
    for y in range(TILE):
        for x in range(TILE):
            if px[x, y][3] == 0:
                continue
            for dx, dy in ((1, 0), (0, 1)):
                nx, ny = x + dx, y + dy
                if nx >= TILE or ny >= TILE or px[nx, ny][3] == 0:
                    continue
                total += 1
                d = abs(lum255(px[x, y]) - lum255(px[nx, ny]))
                if d < 0.5:
                    same += 1
                elif d < 8.0:
                    micro += 1
    if not total:
        return None
    return same / total, micro / total


def flat_levels(sub):
    """Правило «плоские ступени вместо градиента»: сколько занятых ступеней
    яркости и какой между ними зазор."""
    px = sub.load()
    hist = {}
    solid = 0
    for y in range(TILE):
        for x in range(TILE):
            if px[x, y][3] == 0:
                continue
            solid += 1
            b = int(round(lum255(px[x, y])))
            hist[b] = hist.get(b, 0) + 1
    if not solid:
        return None
    busy = sorted(b for b, n in hist.items() if n >= solid * 0.01)
    covered = sum(hist[b] for b in busy) / solid
    gaps = [busy[i + 1] - busy[i] for i in range(len(busy) - 1)]
    return len(busy), covered, (min(gaps) if gaps else 255)


def clump_stats(sub):
    """Правило «кластеры, а не бросок шума на точку»: доля точек, у которых
    меньше двух из восьми соседей своего цвета, и склейка J."""
    px = sub.load()
    lonely = solid = 0
    same = pairs = 0
    for y in range(TILE):
        for x in range(TILE):
            if px[x, y][3] == 0:
                continue
            solid += 1
            me = px[x, y][:3]
            kin = 0
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < TILE and 0 <= ny < TILE and px[nx, ny][3] \
                            and px[nx, ny][:3] == me:
                        kin += 1
            if kin < 2:
                lonely += 1
            for dx, dy in ((1, 0), (0, 1)):
                nx, ny = x + dx, y + dy
                if nx >= TILE or ny >= TILE or px[nx, ny][3] == 0:
                    continue
                pairs += 1
                if px[nx, ny][:3] == me:
                    same += 1
    if not solid or not pairs:
        return None
    return lonely / solid, same / pairs


def pillow(sub):
    """Правило «яркость не считать от расстояния до края»: связь яркости с
    удалением от фона. Высокая связь — это подушка (pillow shading)."""
    px = sub.load()
    # Расстояние до фона считаем волной по четырём соседям.
    INF = 999
    d = [[0 if px[x, y][3] == 0 else INF for y in range(TILE)] for x in range(TILE)]
    for _ in range(TILE):
        moved = False
        for x in range(TILE):
            for y in range(TILE):
                if d[x][y] == 0:
                    continue
                best = INF
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    v = d[nx][ny] if 0 <= nx < TILE and 0 <= ny < TILE else 0
                    best = min(best, v)
                if best + 1 < d[x][y]:
                    d[x][y] = best + 1
                    moved = True
        if not moved:
            break
    xs = []
    ys = []
    for x in range(TILE):
        for y in range(TILE):
            if px[x, y][3] == 0:
                continue
            xs.append(d[x][y])
            ys.append(lum255(px[x, y]))
    n = len(xs)
    if n < 8:
        return None
    mx = sum(xs) / n
    my = sum(ys) / n
    sxy = sum((a - mx) * (b - my) for a, b in zip(xs, ys))
    sxx = sum((a - mx) ** 2 for a in xs)
    syy = sum((b - my) ** 2 for b in ys)
    if sxx <= 0 or syy <= 0:
        return 0.0
    return sxy / (sxx * syy) ** 0.5


def solidity(sub):
    """Правило «силуэт не должен быть формулой»: доля площади маски в её
    выпуклой оболочке. Идеальный эллипс даёт единицу — это провал."""
    px = sub.load()
    pts = [(x, y) for x in range(TILE) for y in range(TILE) if px[x, y][3] > 127]
    if len(pts) < 8:
        return None
    pts = sorted(set(pts))

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lo = []
    for p in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0:
            lo.pop()
        lo.append(p)
    up = []
    for p in reversed(pts):
        while len(up) >= 2 and cross(up[-2], up[-1], p) <= 0:
            up.pop()
        up.append(p)
    hull = lo[:-1] + up[:-1]
    if len(hull) < 3:
        return None
    a2 = abs(sum(hull[i][0] * hull[(i + 1) % len(hull)][1]
                 - hull[(i + 1) % len(hull)][0] * hull[i][1]
                 for i in range(len(hull)))) / 2.0
    return len(pts) / a2 if a2 > 0 else None


def deep_report(path):
    img = Image.open(path).convert("RGBA")
    print("%-18s %6s %6s %6s %6s %6s %6s %6s" % (
        "часть", "равн", "микро", "ступ", "покр", "сирот", "склей", "подуш"))
    print("-" * 72)
    whole = set()
    bad = 0
    for key, (cols, ru, solid_kind) in PARTS.items():
        got = cells(img, cols)
        if not got:
            continue
        acc = {"same": [], "micro": [], "busy": [], "cov": [], "lone": [],
               "j": [], "pil": [], "sol": []}
        for c, s, sub in got:
            px = sub.load()
            for y in range(TILE):
                for x in range(TILE):
                    if px[x, y][3]:
                        whole.add(px[x, y][:3])
            st_ = step_stats(sub)
            if st_:
                acc["same"].append(st_[0])
                acc["micro"].append(st_[1])
            fl = flat_levels(sub)
            if fl:
                acc["busy"].append(fl[0])
                acc["cov"].append(fl[1])
            cl = clump_stats(sub)
            if cl:
                acc["lone"].append(cl[0])
                acc["j"].append(cl[1])
            pl = pillow(sub)
            if pl is not None:
                acc["pil"].append(abs(pl))
            if not solid_kind:
                so = solidity(sub)
                if so:
                    acc["sol"].append(so)
        m = lambda k: sorted(acc[k])[len(acc[k]) // 2] if acc[k] else 0.0
        print("%-18s %6.2f %6.2f %6.1f %6.2f %6.2f %6.2f %6.2f" % (
            ru[:18], m("same"), m("micro"), m("busy"), m("cov"),
            m("lone"), m("j"), m("pil")))
        lone_cap = 0.10 if solid_kind else 0.05
        if m("same") < 0.45:
            bad += 1
        if m("micro") > 0.05:
            bad += 1
        if not (3 <= m("busy") <= 8):
            bad += 1
        if m("cov") < 0.92:
            bad += 1
        if m("lone") > lone_cap:
            bad += 1
        if m("j") < 0.55:
            bad += 1
        if m("pil") > 0.45:
            bad += 1
    print("\nЦветов на всём листе: %d (норма 48)" % len(whole))
    if len(whole) > 48:
        bad += 1
    print("НАРУШЕНИЙ ВТОРОГО ЯРУСА:", bad)
    print("\nнормы: равных >= 0.45, микроступенек <= 0.05, ступеней 3..8,")
    print("       покрытие >= 0.92, сирот <= 0.10/0.05, склейка >= 0.55,")
    print("       подушка <= 0.45")


def main(argv):
    path = "art/moss.png"
    as_json = False
    deep = False
    for a in argv:
        if a == "--json":
            as_json = True
        elif a == "--deep":
            deep = True
        else:
            path = a
    if deep:
        deep_report(path)
        return 0
    img = Image.open(path).convert("RGBA")
    out = []
    for key in PARTS:
        got = check_part(img, key)
        if got:
            out.append(got)
    if as_json:
        print(json.dumps(out, ensure_ascii=False, indent=1))
        return 0
    total = 0
    for r in out:
        mark = "ЦЕЛО" if not r["нарушения"] else "БЬЁТ %d" % len(r["нарушения"])
        print("%-20s %-10s %s" % (r["часть"], mark,
                                  "; ".join(r["нарушения"])))
        for k, v in r["числа"].items():
            print("      %-34s %s" % (k, v))
        total += len(r["нарушения"])
    print("\nВСЕГО НАРУШЕНИЙ:", total)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
