extends SceneTree
# =============================================================================
#  ГЕНЕРАТОР ТЕКСТУР — НЕ ЧАСТЬ ИГРЫ
#
#  Инструмент делает файл `art/moss.png`, а игра его читает. Больше между ними
#  ничего нет: ни одной ветки в игровом коде на этот счёт не заведено.
#
#  Зачем. Заглушки всех тринадцати столбцов уже параметрические — внутри них
#  десятки чисел, поставленных на глаз и запертых в коде. Здесь эти числа
#  вынесены наружу и разложены по двум ЧЕРТАМ на картинку: девять вариантов —
#  это сетка три на три вокруг нынешнего рецепта. Пользователь смотрит картинку
#  и называет номер; чисел он не видит вовсе (его решение 31.08.2026).
#
#  Команды (запускает не пользователь, а я):
#
#    godot --headless --path ~/Desktop/TeaTrap --script res://Texture.gd -- \
#          --part=bark                 показать девять вариантов коры
#          --part=bark --take=4        принять четвёртый, пересобрать лист
#          --part=bark --move=0.4      те же девять, но теснее вокруг нынешнего
#          --part=bark --dark=0.1 --warm=0.2   сдвинуть цвет и показать заново
#          --build                     пересобрать лист по записанным рецептам
#          --hand                      вернуть рукописный мох из moss_hand.png
#          --check                     сторожа + сверка с рисовальщиками игры
#
#  ЦВЕТ ИДЁТ МИМО СЕТКИ. Девять вариантов — про форму; тон, теплота и светлота
#  правятся отдельно. Иначе девять клеток тратятся на оттенки, а форма стоит.
# =============================================================================

const Plants = preload("res://SpacePlants.gd")

const TILE: int = 32
const STAGES: int = 9
const KINDS: int = 4
const BODY_COL: int = 4
const BARK_COL: int = 5
const LEAF_COL: int = 6
const LEAF_KINDS: int = 3
const BLOOM_COL: int = 9
const BLOOM_KINDS: int = 2
const LIA_BODY_COL: int = 11
const LIA_FUZZ_COL: int = 12
const COLS: int = 13

const ART := "res://art/moss.png"
const HAND := "res://art/moss_hand.png"
const PREV := "res://art/moss_prev.png"
const PICK := "res://art/pick.png"
const AGES := "res://art/pick_ages.png"
const RECIPES := "res://art/recipes.json"

# Ступень, по которой судят вариант: седьмая из девяти — картинка уже взрослая,
# но ещё не предельная.
const SHOW: int = 6
const ZOOM: int = 4                 # во столько раз увеличен вариант на листе
const GAP: int = 14                 # промежуток между вариантами, точек
const NUM_H: int = 26               # полоска с номером над вариантом
const BACK := Color(0.16, 0.16, 0.17)   # фон листа вариантов
const INK := Color(0.95, 0.92, 0.70)    # цвет номера

# ЧЕРТЫ КАЖДОЙ КАРТИНКИ. Первая двигается по столбцам сетки, вторая по рядам.
# `solid` — сплошной образец (его показываем замощённым), иначе вырезанная
# фигурка (её показываем в ряд с соседками по возрасту).
const PARTS := {
	"moss": {
		"cols": [0, 1, 2, 3], "solid": false, "seed": 7101,
		"ru": "ворсинка мха", "knobs": ["puff", "edge"],
		"ax": ["пухлость подушки", "мохнатость края"]},
	"body": {
		"cols": [BODY_COL], "solid": true, "seed": 7102,
		"ru": "тело мха", "knobs": ["clump", "mottle"],
		"ax": ["крупность комочков", "пестрота"]},
	"bark": {
		"cols": [BARK_COL], "solid": true, "seed": 7103,
		"ru": "кора лианы", "knobs": ["rough", "groove"],
		"ax": ["грубость волокна", "глубина борозд"]},
	"leaf": {
		"cols": [LEAF_COL, LEAF_COL + 1, LEAF_COL + 2], "solid": false, "seed": 7104,
		"ru": "лист лианы", "knobs": ["cut", "edge"],
		"ax": ["изрезанность пластины", "резкость края"]},
	"bloom": {
		"cols": [BLOOM_COL, BLOOM_COL + 1], "solid": false, "seed": 7105,
		"ru": "лепесток цветка", "knobs": ["wide", "sharp"],
		"ax": ["ширина", "заострённость конца"]},
	"liabody": {
		"cols": [LIA_BODY_COL], "solid": true, "seed": 7106,
		"ru": "тело лиамоха", "knobs": ["many", "long"],
		"ax": ["густота волосков", "длина волосков"]},
	"liafuzz": {
		"cols": [LIA_FUZZ_COL], "solid": false, "seed": 7107,
		"ru": "ворсинка лиамоха", "knobs": ["many", "long"],
		"ax": ["густота пучка", "длина волоска"]},
}

# Числа мха-заглушки — те же, что в игре.
const CLUMP_YOUNG: int = 24
const CLUMP_OLD: int = 36
const BLOTCH: int = 5
const CLUMP_TORN: float = 0.9
const CLUMP_LONG: float = 0.55
const LIA_HAIR_YOUNG: int = 60
const LIA_HAIR_OLD: int = 130
const LIA_HAIR_SHORT: float = 0.10
const LIA_HAIR_LONG: float = 0.20
const LIA_TUFT_YOUNG: int = 3
const LIA_TUFT_OLD: int = 8

# Цифры 3×5 — на листе вариантов надо подписать номера, а рисовать текст в
# картинку движок не умеет.
const FONT := {
	"1": ["010", "110", "010", "010", "111"],
	"2": ["111", "001", "111", "100", "111"],
	"3": ["111", "001", "111", "001", "111"],
	"4": ["101", "101", "111", "001", "001"],
	"5": ["111", "100", "111", "001", "111"],
	"6": ["111", "100", "111", "101", "111"],
	"7": ["111", "001", "010", "010", "010"],
	"8": ["111", "101", "111", "101", "111"],
	"9": ["111", "101", "111", "001", "111"],
	"0": ["111", "101", "101", "101", "111"],
}

var _hgt := PackedFloat32Array()     # высоты комочков тела, как в игре


func _init() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"

	if args.has("check"):
		_check()
		quit()
		return
	if args.has("hand"):
		_hand_back()
		quit()
		return
	if args.has("build"):
		var rec := _load_recipes()
		_apply(rec)
		quit()
		return

	var part: String = str(args.get("part", ""))
	if not PARTS.has(part):
		print("Кому варианты? --part=", ", ".join(PARTS.keys()))
		print("Ещё есть: --build, --hand, --check")
		quit()
		return

	var recipes := _load_recipes()
	var base: Dictionary = recipes[part]
	# Слова пользователя двигают СЕРЕДИНУ сетки, а не одно число.
	for k in ["dark", "warm", "vivid"]:
		if args.has(k):
			base[k] = clampf(base[k] + float(args[k]), -0.9, 0.9)
	var knobs: Array = PARTS[part]["knobs"]
	if args.has("ax1"):
		base[knobs[0]] = maxf(0.15, base[knobs[0]] * float(args["ax1"]))
	if args.has("ax2"):
		base[knobs[1]] = maxf(0.15, base[knobs[1]] * float(args["ax2"]))

	if args.has("take"):
		var n: int = int(args["take"])
		if n < 1 or n > 9:
			print("Номер варианта от 1 до 9, а не ", n)
			quit()
			return
		var step: float = float(args.get("move", "1.0"))
		var grid := _grid(part, base, step)
		recipes[part] = grid[n - 1]
		_save_recipes(recipes)
		_apply(recipes)
		_ages_sheet(part, recipes[part])
		print("Принят вариант ", n, " для «", PARTS[part]["ru"], "»")
		quit()
		return

	var move: float = float(args.get("move", "1.0"))
	_pick_sheet(part, base, move)
	quit()


# =============================================================================
#  РЕЦЕПТЫ
# =============================================================================

func _fresh(part: String) -> Dictionary:
	var rec := {"dark": 0.0, "warm": 0.0, "vivid": 0.0}
	for k in PARTS[part]["knobs"]:
		rec[k] = 1.0
	return rec


func _default_recipes() -> Dictionary:
	var out := {}
	for p in PARTS.keys():
		out[p] = _fresh(p)
	return out


func _load_recipes() -> Dictionary:
	var out := _default_recipes()
	if not FileAccess.file_exists(ProjectSettings.globalize_path(RECIPES)):
		return out
	var txt := FileAccess.get_file_as_string(ProjectSettings.globalize_path(RECIPES))
	var got = JSON.parse_string(txt)
	if typeof(got) != TYPE_DICTIONARY:
		return out
	for p in out.keys():
		if not got.has(p):
			continue
		for k in out[p].keys():
			if got[p].has(k):
				out[p][k] = float(got[p][k])
	return out


func _save_recipes(rec: Dictionary) -> void:
	var f := FileAccess.open(ProjectSettings.globalize_path(RECIPES), FileAccess.WRITE)
	f.store_string(JSON.stringify(rec, "\t"))
	f.close()


# Девять рецептов сеткой: три значения первой черты на три значения второй.
# `move` сжимает или растягивает шаг — когда подошли близко, шаги мельчают.
func _grid(part: String, base: Dictionary, move: float) -> Array:
	var knobs: Array = PARTS[part]["knobs"]
	var step: float = clampf(0.42 * move, 0.05, 0.9)
	var mul := [1.0 / (1.0 + step), 1.0, 1.0 + step]
	var out := []
	for j in range(3):
		for i in range(3):
			var r := base.duplicate()
			r[knobs[0]] = maxf(0.15, base[knobs[0]] * mul[i])
			r[knobs[1]] = maxf(0.15, base[knobs[1]] * mul[j])
			out.append(r)
	return out


# =============================================================================
#  ЛИСТ ВАРИАНТОВ
# =============================================================================

func _pick_sheet(part: String, base: Dictionary, move: float) -> void:
	var grid := _grid(part, base, move)
	var solid: bool = PARTS[part]["solid"]
	var card_w: int = (TILE * 3 if solid else TILE * 3) * ZOOM
	var card_h: int = (TILE * 3 if solid else TILE) * ZOOM
	var wide: int = card_w * 3 + GAP * 4
	var high: int = (card_h + NUM_H) * 3 + GAP * 4
	var sheet := Image.create(wide, high, false, Image.FORMAT_RGBA8)
	sheet.fill(BACK)

	for n in range(9):
		var col: int = n % 3
		var row: int = n / 3
		var ox: int = GAP + col * (card_w + GAP)
		var oy: int = GAP + row * (card_h + NUM_H + GAP)
		_digit(sheet, ox, oy, str(n + 1))
		var card := _card(part, grid[n], solid)
		_blow(sheet, card, ox, oy + NUM_H)

	_save(sheet, PICK)
	print("«", PARTS[part]["ru"], "» — девять вариантов в art/pick.png")
	print("  по столбцам ", PARTS[part]["ax"][0], ", по рядам ", PARTS[part]["ax"][1])
	print("  шаг сетки ", "%.0f%%" % (clampf(0.42 * move, 0.05, 0.9) * 100.0))


# Один вариант: сплошной образец показываем замощённым три на три (только так
# виден повтор и шов), вырезанную фигурку — в ряд с соседками по возрасту.
func _card(part: String, rec: Dictionary, solid: bool) -> Image:
	var cell := Image.create(TILE * 3, TILE * 3 if solid else TILE, false,
		Image.FORMAT_RGBA8)
	cell.fill(Color(0.28, 0.28, 0.30, 1.0))
	if solid:
		var one := _one_cell(part, rec, SHOW, 0)
		for j in range(3):
			for i in range(3):
				cell.blit_rect(one, Rect2i(0, 0, TILE, TILE),
					Vector2i(i * TILE, j * TILE))
	else:
		var kinds: int = PARTS[part]["cols"].size()
		for i in range(3):
			var s: int = [SHOW - 3, SHOW, STAGES - 1][i]
			var one := _one_cell(part, rec, s, i % kinds)
			_over(cell, one, i * TILE, 0)
	return cell


func _one_cell(part: String, rec: Dictionary, s: int, kind: int) -> Image:
	var img := Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(PARTS[part]["seed"]) + kind * 977 + s * 31
	_paint(part, img, 0, 0, s, kind, rng, rec)
	return img


# Кладём фигурку поверх фона, уважая прозрачность.
func _over(dst: Image, src: Image, ox: int, oy: int) -> void:
	for y in range(src.get_height()):
		for x in range(src.get_width()):
			var c := src.get_pixel(x, y)
			if c.a <= 0.0:
				continue
			var b := dst.get_pixel(ox + x, oy + y)
			dst.set_pixel(ox + x, oy + y, b.lerp(Color(c.r, c.g, c.b, 1.0), c.a))


func _blow(dst: Image, src: Image, ox: int, oy: int) -> void:
	for y in range(src.get_height() * ZOOM):
		for x in range(src.get_width() * ZOOM):
			dst.set_pixel(ox + x, oy + y, src.get_pixel(x / ZOOM, y / ZOOM))


func _digit(img: Image, ox: int, oy: int, text: String) -> void:
	var k: int = 4
	for i in range(text.length()):
		var rows: Array = FONT.get(text[i], FONT["0"])
		for y in range(5):
			for x in range(3):
				if rows[y][x] != "1":
					continue
				for dy in range(k):
					for dx in range(k):
						img.set_pixel(ox + i * 4 * k + x * k + dx, oy + 2 + y * k + dy, INK)


# Полоска всех девяти возрастов принятого варианта.
func _ages_sheet(part: String, rec: Dictionary) -> void:
	var kinds: int = PARTS[part]["cols"].size()
	var strip := Image.create(TILE * STAGES, TILE * kinds, false, Image.FORMAT_RGBA8)
	strip.fill(Color(0.28, 0.28, 0.30, 1.0))
	for k in range(kinds):
		for s in range(STAGES):
			_over(strip, _one_cell(part, rec, s, k), s * TILE, k * TILE)
	var big := Image.create(strip.get_width() * ZOOM, strip.get_height() * ZOOM,
		false, Image.FORMAT_RGBA8)
	_blow(big, strip, 0, 0)
	_save(big, AGES)


# =============================================================================
#  СБОРКА ЛИСТА
# =============================================================================

# Рука главнее всего. Первый же запуск замораживает нарисованное в moss_hand.png
# и дальше его не трогает: что бы ни выбрал пользователь, вернуть работу можно
# всегда.
func _freeze_hand() -> void:
	var g := ProjectSettings.globalize_path(HAND)
	if FileAccess.file_exists(g):
		return
	if not FileAccess.file_exists(ProjectSettings.globalize_path(ART)):
		return
	var img := Image.load_from_file(ProjectSettings.globalize_path(ART))
	if img == null:
		return
	var keep := Image.create(TILE * KINDS, TILE * STAGES, false, Image.FORMAT_RGBA8)
	keep.fill(Color(0, 0, 0, 0))
	var take: int = mini(TILE * KINDS, img.get_width())
	keep.blit_rect(img, Rect2i(0, 0, take, TILE * STAGES), Vector2i.ZERO)
	_save(keep, HAND)
	print("Рукописный мох заморожен в art/moss_hand.png — он больше не тронется")


func _hand_from_file() -> Image:
	var g := ProjectSettings.globalize_path(HAND)
	if not FileAccess.file_exists(g):
		return null
	return Image.load_from_file(g)


func _build(rec: Dictionary, hand: Image) -> Image:
	var img := Image.create(TILE * COLS, TILE * STAGES, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	_hgt.resize(TILE * TILE * STAGES)
	if hand != null:
		img.blit_rect(hand, Rect2i(0, 0, TILE * KINDS, TILE * STAGES), Vector2i.ZERO)
	else:
		_column(img, "moss", rec["moss"])
	for p in ["body", "bark", "leaf", "bloom", "liabody", "liafuzz"]:
		_column(img, p, rec[p])
	return img


# СВОЙ ГЕНЕРАТОР СЛУЧАЙНОГО У КАЖДОЙ КАРТИНКИ. Иначе выбранная кора
# перетасовывает листья: они брали бы числа из общей череды.
func _column(img: Image, part: String, rec: Dictionary) -> void:
	var cols: Array = PARTS[part]["cols"]
	for k in range(cols.size()):
		var rng := RandomNumberGenerator.new()
		rng.seed = int(PARTS[part]["seed"]) + k * 104729
		for s in range(STAGES):
			_paint(part, img, int(cols[k]) * TILE, s * TILE, s, k, rng, rec)


func _apply(rec: Dictionary) -> void:
	_freeze_hand()
	var hand := _hand_from_file()
	var img := _build(rec, hand)
	var bad := _guards(img)
	if bad > 0:
		print("ЛИСТ НЕ ЗАПИСАН: сторожа насчитали ", bad, " нарушений")
		return
	var g := ProjectSettings.globalize_path(ART)
	if FileAccess.file_exists(g):
		var was := Image.load_from_file(g)
		if was != null:
			_save(was, PREV)
	_save(img, ART)
	print("Лист собран: ", img.get_width(), "×", img.get_height())


func _hand_back() -> void:
	var hand := _hand_from_file()
	if hand == null:
		print("art/moss_hand.png нет — возвращать нечего")
		return
	var rec := _load_recipes()
	var img := _build(rec, hand)
	_save(img, ART)
	print("Рукописный мох вернулся на первые четыре столбца")


# =============================================================================
#  СТОРОЖА
# =============================================================================

func _guards(img: Image) -> int:
	var bad: int = 0
	# 1. Сплошные столбцы — ни одной просвечивающей точки.
	for col in [BODY_COL, BARK_COL, LIA_BODY_COL]:
		var holes: int = 0
		for s in range(STAGES):
			for y in range(TILE):
				for x in range(TILE):
					if img.get_pixel(col * TILE + x, s * TILE + y).a < 1.0:
						holes += 1
		print("  столбец ", col, ": просвечивающих точек — ", holes)
		bad += holes
	# 2. Вырезанные фигурки не касаются левого, правого и верхнего краёв клетки:
	# иначе по краю листа идёт белая черта соседнего столбца. Низ — можно, лист и
	# ворсинка растут снизу.
	var touch: int = 0
	for part in ["leaf", "bloom", "liafuzz"]:
		for col in PARTS[part]["cols"]:
			for s in range(STAGES):
				for x in range(TILE):
					if img.get_pixel(int(col) * TILE + x, s * TILE).a > 0.0:
						touch += 1
				for y in range(TILE):
					if img.get_pixel(int(col) * TILE, s * TILE + y).a > 0.0:
						touch += 1
					if img.get_pixel(int(col) * TILE + TILE - 1, s * TILE + y).a > 0.0:
						touch += 1
	print("  фигурок, задевших край клетки: ", touch)
	bad += touch
	# 3. Размер листа.
	if img.get_width() != TILE * COLS or img.get_height() != TILE * STAGES:
		print("  РАЗМЕР НЕ ТОТ: ", img.get_width(), "×", img.get_height())
		bad += 1
	return bad


# Уклон столбца по яркости — той же меркой, какой его меряет игра. Нужен затем,
# что как только лист станет тринадцатистолбцовым, игра перестанет знать высоты
# комочков тела точно и начнёт снимать их с яркости.
func _slope(img: Image, col: int) -> float:
	var hgt := PackedFloat32Array()
	hgt.resize(TILE * TILE * STAGES)
	var raw := PackedFloat32Array()
	raw.resize(TILE * TILE)
	for s in range(STAGES):
		for y in range(TILE):
			for x in range(TILE):
				var c := img.get_pixel(col * TILE + x, s * TILE + y)
				raw[y * TILE + x] = (c.r + c.g + c.b) / 3.0
		for y in range(TILE):
			for x in range(TILE):
				var sum: float = 0.0
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						sum += raw[posmod(y + dy, TILE) * TILE + posmod(x + dx, TILE)]
				hgt[s * TILE * TILE + y * TILE + x] = sum / 9.0
	var tilt := PackedFloat32Array()
	for s in range(STAGES):
		var b: int = s * TILE * TILE
		for y in range(TILE):
			for x in range(TILE):
				var gx: float = hgt[b + y * TILE + posmod(x + 1, TILE)] \
					- hgt[b + y * TILE + posmod(x - 1, TILE)]
				var gy: float = hgt[b + posmod(y + 1, TILE) * TILE + x] \
					- hgt[b + posmod(y - 1, TILE) * TILE + x]
				tilt.append(sqrt(gx * gx + gy * gy))
	var arr := Array(tilt)
	arr.sort()
	return arr[int(float(arr.size()) * 0.9)]


# СВЕРКА С ИГРОЙ. Рисовальщики здесь — копии игровых, и копии умеют разойтись.
# Ловим это так: с рецептами по умолчанию и в том же порядке случайных чисел
# лист обязан совпасть с игровым ТОЧКА В ТОЧКУ.
func _check() -> void:
	print("=== СТОРОЖА ГЕНЕРАТОРА ТЕКСТУР ===")
	var plants := Plants.new()
	var want: Image = plants._blade_texture().get_image()
	if want.is_compressed():
		want.decompress()
	if want.get_format() != Image.FORMAT_RGBA8:
		want.convert(Image.FORMAT_RGBA8)

	# Тот же порядок, что у игры в `_widen_sheet`: одна череда случайных чисел,
	# семя 5501, столбцы по одному сверху вниз.
	var mine := Image.create(TILE * COLS, TILE * STAGES, false, Image.FORMAT_RGBA8)
	mine.fill(Color(0, 0, 0, 0))
	_hgt.resize(TILE * TILE * STAGES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5501
	var def := _default_recipes()
	for s in range(STAGES):
		_paint("body", mine, BODY_COL * TILE, s * TILE, s, 0, rng, def["body"])
	for s in range(STAGES):
		_paint("bark", mine, BARK_COL * TILE, s * TILE, s, 0, rng, def["bark"])
	for k in range(LEAF_KINDS):
		for s in range(STAGES):
			_paint("leaf", mine, (LEAF_COL + k) * TILE, s * TILE, s, k, rng, def["leaf"])
	for k in range(BLOOM_KINDS):
		for s in range(STAGES):
			_paint("bloom", mine, (BLOOM_COL + k) * TILE, s * TILE, s, k, rng, def["bloom"])
	for s in range(STAGES):
		_paint("liabody", mine, LIA_BODY_COL * TILE, s * TILE, s, 0, rng, def["liabody"])
	for s in range(STAGES):
		_paint("liafuzz", mine, LIA_FUZZ_COL * TILE, s * TILE, s, 0, rng, def["liafuzz"])

	var off: int = 0
	for col in range(KINDS, COLS):
		for s in range(STAGES):
			for y in range(TILE):
				for x in range(TILE):
					if want.get_pixel(col * TILE + x, s * TILE + y) \
							!= mine.get_pixel(col * TILE + x, s * TILE + y):
						off += 1
	print("Сверка с рисовальщиками игры: расхождений ", off, " (норма 0)")

	# Мховый столбец идёт своей чередой — в игре он рисуется после всех прочих.
	var full: Image = plants._make_blade_texture().get_image()
	if full.get_format() != Image.FORMAT_RGBA8:
		full.convert(Image.FORMAT_RGBA8)
	var mine2 := Image.create(TILE * COLS, TILE * STAGES, false, Image.FORMAT_RGBA8)
	mine2.fill(Color(0, 0, 0, 0))
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 913377
	for s in range(STAGES):
		_paint("body", mine2, BODY_COL * TILE, s * TILE, s, 0, rng2, def["body"])
		_paint("bark", mine2, BARK_COL * TILE, s * TILE, s, 0, rng2, def["bark"])
		for k in range(LEAF_KINDS):
			_paint("leaf", mine2, (LEAF_COL + k) * TILE, s * TILE, s, k, rng2, def["leaf"])
		for k in range(BLOOM_KINDS):
			_paint("bloom", mine2, (BLOOM_COL + k) * TILE, s * TILE, s, k, rng2, def["bloom"])
		_paint("liabody", mine2, LIA_BODY_COL * TILE, s * TILE, s, 0, rng2, def["liabody"])
		_paint("liafuzz", mine2, LIA_FUZZ_COL * TILE, s * TILE, s, 0, rng2, def["liafuzz"])
	for s in range(STAGES):
		for k in range(KINDS):
			_paint("moss", mine2, k * TILE, s * TILE, s, k, rng2, def["moss"])
	var off2: int = 0
	for col in range(0, KINDS):
		for s in range(STAGES):
			for y in range(TILE):
				for x in range(TILE):
					if full.get_pixel(col * TILE + x, s * TILE + y) \
							!= mine2.get_pixel(col * TILE + x, s * TILE + y):
						off2 += 1
	print("Сверка мхового столбца: расхождений ", off2, " (норма 0)")

	# Сторожа собранного листа.
	_freeze_hand()
	var built := _build(_load_recipes(), _hand_from_file())
	print("Сторожа собранного листа:")
	var bad := _guards(built)
	print("Всего нарушений: ", bad)

	# Рельеф тела мха: игра знает высоты точно, пока лист четырёхстолбцовый.
	# После записи полного листа она станет снимать их с яркости — меряем обе.
	var told := plants._make_bumps(plants._blade_texture())
	print("Уклон тела мха по яркости собранного листа: %.4f" % _slope(built, BODY_COL))
	print("  (у нынешнего листа игры: %.4f)" % _slope(want, BODY_COL))
	plants.free()


func _save(img: Image, path: String) -> void:
	var err := img.save_png(ProjectSettings.globalize_path(path))
	if err != OK:
		print(path, " — НЕ ЗАПИСАН, ошибка ", err)


# =============================================================================
#  РИСОВАЛЬЩИКИ — КОПИИ ИГРОВЫХ, ПЕРЕВЕДЁННЫЕ НА ЧИСЛА-МНОЖИТЕЛИ
#
#  Каждая черта входит МНОЖИТЕЛЕМ, и по умолчанию он равен единице. Умножение на
#  единицу ничего не меняет ни на одну последнюю цифру — оттого сверка с игрой и
#  сходится точка в точку.
# =============================================================================

func _paint(part: String, img: Image, ox: int, oy: int, s: int, kind: int,
		rng: RandomNumberGenerator, rec: Dictionary) -> void:
	match part:
		"moss": _moss(img, ox, oy, s, rng, rec)
		"body": _body(img, ox, oy, s, rng, rec)
		"bark": _bark(img, ox, oy, s, rng, rec)
		"leaf": _leaf(img, ox, oy, s, kind, rng, rec)
		"bloom": _bloom(img, ox, oy, s, kind, rng, rec)
		"liabody": _lia_body(img, ox, oy, s, rng, rec)
		"liafuzz": _lia_fuzz(img, ox, oy, s, rng, rec)


# Цвет правится мимо сетки вариантов. При нулях возвращаем краску нетронутой —
# на этом стоит точная сверка с игрой.
func _tint(c: Color, rec: Dictionary) -> Color:
	var d: float = rec.get("dark", 0.0)
	var w: float = rec.get("warm", 0.0)
	var v: float = rec.get("vivid", 0.0)
	if d == 0.0 and w == 0.0 and v == 0.0:
		return c
	var out := c
	if v != 0.0:
		var g: float = (out.r + out.g + out.b) / 3.0
		out = Color(g + (out.r - g) * (1.0 + v), g + (out.g - g) * (1.0 + v),
			g + (out.b - g) * (1.0 + v))
	if w != 0.0:
		out = Color(out.r + w * 0.09, out.g + w * 0.02, out.b - w * 0.09)
	if d != 0.0:
		out = out.darkened(d) if d > 0.0 else out.lightened(-d)
	return Color(clampf(out.r, 0.0, 1.0), clampf(out.g, 0.0, 1.0),
		clampf(out.b, 0.0, 1.0), c.a)


func _hash01(n: int) -> float:
	var x: int = (n * 1103515245 + 12345) & 0x7fffffff
	return float((x >> 8) & 0xffff) / 65535.0


func _to_line(p: Vector2, a: Vector2, b: Vector2) -> float:
	var way: Vector2 = b - a
	var len2: float = way.length_squared()
	if len2 < 0.000001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(way) / len2, 0.0, 1.0)
	return p.distance_to(a + way * t)


# --- ВОРСИНКА МХА: подушка в профиль, мохнатая по краю -----------------------
func _moss(img: Image, ox: int, oy: int, s: int, rng: RandomNumberGenerator,
		rec: Dictionary) -> void:
	var age: float = float(s) / float(STAGES - 1)
	var puff: float = rec["puff"]
	var edge: float = rec["edge"]
	var high: float = lerpf(0.16, 0.62, age) * float(TILE) * puff
	high = minf(high, float(TILE) * 0.92)
	var half: float = lerpf(0.22, 0.46, age) * float(TILE) * puff
	half = minf(half, float(TILE) * 0.47)
	var fuzz: int = int(round(lerpf(1.0, 4.0, age) * edge))
	var deep := _tint(Color(0.20, 0.31, 0.17).lerp(Color(0.17, 0.26, 0.15), age), rec)
	var body := _tint(Color(0.33, 0.47, 0.22).lerp(Color(0.29, 0.42, 0.19), age), rec)
	var lit := _tint(Color(0.47, 0.60, 0.29).lerp(Color(0.44, 0.55, 0.26), age), rec)
	var rust := _tint(Color(0.36, 0.31, 0.17), rec)

	var mid_x: float = float(TILE) * 0.5 + rng.randf_range(-2.0, 2.0)
	var wave_a: float = rng.randf_range(0.0, TAU)
	var wave_b: float = rng.randf_range(0.0, TAU)
	for x in range(TILE):
		var dx: float = (float(x) - mid_x) / half
		if absf(dx) >= 1.0:
			continue
		var dome: float = sqrt(maxf(0.0, 1.0 - dx * dx))
		var lump: float = sin(float(x) * 0.9 + wave_a) * 0.11 \
			+ sin(float(x) * 2.3 + wave_b) * 0.06
		var top: int = TILE - 1 - int(round(high * (dome + lump)))
		top = clampi(top, 0, TILE - 1)
		for y in range(top, TILE):
			var up: float = float(TILE - 1 - y) / maxf(high, 1.0)
			var col: Color = deep.lerp(body, clampf(up * 1.6, 0.0, 1.0))
			if up > 0.55:
				col = col.lerp(lit, (up - 0.55) / 0.45)
			if (x + int(up * 7.0)) % 3 == 0:
				col = col.darkened(0.10)
			elif x % 5 == 0:
				col = col.lightened(0.08)
			if age > 0.6 and rng.randf() < 0.012:
				col = col.lerp(rust, 0.5)
			img.set_pixel(ox + x, oy + y, Color(col.r, col.g, col.b, 1.0))
		for f in range(fuzz):
			if rng.randf() > 0.55 - 0.10 * float(f):
				continue
			var y2: int = top - 1 - f
			if y2 < 0:
				continue
			img.set_pixel(ox + x, oy + y2, Color(lit.r, lit.g, lit.b, 1.0))


# --- ТЕЛО МХА: куски с ломаными границами ------------------------------------
func _body(img: Image, ox: int, oy: int, s: int, rng: RandomNumberGenerator,
		rec: Dictionary) -> void:
	var age: float = float(s) / float(STAGES - 1)
	var big_k: float = rec["clump"]
	var mottle: float = rec["mottle"]
	var body := _tint(Color(0.31, 0.44, 0.21).lerp(Color(0.27, 0.39, 0.18), age), rec)
	var span: float = float(TILE)
	var half: float = span * 0.5

	var clumps: int = maxi(4, int(round(lerpf(float(CLUMP_YOUNG), float(CLUMP_OLD),
		age) / big_k)))
	var cx := PackedFloat32Array()
	var cy := PackedFloat32Array()
	var ca := PackedFloat32Array()
	var cb := PackedFloat32Array()
	var cc := PackedFloat32Array()
	var cs := PackedFloat32Array()
	var c_lit := PackedFloat32Array()
	var c_warm := PackedFloat32Array()
	cx.resize(clumps)
	cy.resize(clumps)
	ca.resize(clumps)
	cb.resize(clumps)
	cc.resize(clumps)
	cs.resize(clumps)
	c_lit.resize(clumps)
	c_warm.resize(clumps)
	var mean: float = sqrt(span * span / float(clumps)) * 0.62
	for i in range(clumps):
		cx[i] = rng.randf_range(0.0, span)
		cy[i] = rng.randf_range(0.0, span)
		var bulk: float = mean * rng.randf_range(0.7, 1.45)
		var long: float = rng.randf_range(1.0 - CLUMP_LONG, 1.0 + CLUMP_LONG)
		ca[i] = 1.0 / maxf(0.5, bulk * long)
		cb[i] = 1.0 / maxf(0.5, bulk / long)
		var turn: float = rng.randf_range(0.0, TAU)
		cc[i] = cos(turn)
		cs[i] = sin(turn)
		c_lit[i] = rng.randf_range(-0.13, 0.13)
		c_warm[i] = rng.randf_range(-0.045, 0.045)

	var bx := PackedFloat32Array()
	var by := PackedFloat32Array()
	var b_lit := PackedFloat32Array()
	var b_warm := PackedFloat32Array()
	bx.resize(BLOTCH)
	by.resize(BLOTCH)
	b_lit.resize(BLOTCH)
	b_warm.resize(BLOTCH)
	for i in range(BLOTCH):
		bx[i] = rng.randf_range(0.0, span)
		by[i] = rng.randf_range(0.0, span)
		b_lit[i] = rng.randf_range(-0.07, 0.07)
		b_warm[i] = rng.randf_range(-0.03, 0.03)

	var base: int = s * TILE * TILE
	for y in range(TILE):
		for x in range(TILE):
			var jx: float = float(x) + 0.5 \
				+ (_hash01(x * 7919 + y * 104729 + s * 61) - 0.5) * CLUMP_TORN
			var jy: float = float(y) + 0.5 \
				+ (_hash01(x * 104729 + y * 7919 + s * 977) - 0.5) * CLUMP_TORN
			var d1: float = 1e9
			var d2: float = 1e9
			var win: int = 0
			for i in range(clumps):
				var dx: float = jx - cx[i]
				if dx > half:
					dx -= span
				elif dx < -half:
					dx += span
				var dy: float = jy - cy[i]
				if dy > half:
					dy -= span
				elif dy < -half:
					dy += span
				var u: float = (dx * cc[i] + dy * cs[i]) * ca[i]
				var v: float = (dy * cc[i] - dx * cs[i]) * cb[i]
				var d: float = sqrt(u * u + v * v)
				if d < d1:
					d2 = d1
					d1 = d
					win = i
				elif d < d2:
					d2 = d
			var bigi: int = 0
			var bd: float = 1e9
			for i in range(BLOTCH):
				var dx: float = jx - bx[i]
				if dx > half:
					dx -= span
				elif dx < -half:
					dx += span
				var dy: float = jy - by[i]
				if dy > half:
					dy -= span
				elif dy < -half:
					dy += span
				var d: float = dx * dx + dy * dy
				if d < bd:
					bd = d
					bigi = i
			var edge: float = clampf((d2 / maxf(d1, 0.0001) - 1.0) / 0.5, 0.0, 1.0)
			var deep: float = edge * edge * (3.0 - 2.0 * edge)

			var lig: float = (c_lit[win] + b_lit[bigi] \
				+ (_hash01(x * 31337 + y * 6151 + s * 13) - 0.5) * 0.07) * mottle
			var col: Color = body.lightened(lig) if lig > 0.0 else body.darkened(-lig)
			var warm: float = (c_warm[win] + b_warm[bigi]) * mottle
			col = Color(clampf(col.r + warm, 0.0, 1.0), col.g,
				clampf(col.b - warm, 0.0, 1.0))
			col = col.darkened(0.13 * (1.0 - deep))
			img.set_pixel(ox + x, oy + y, Color(col.r, col.g, col.b, 1.0))
			_hgt[base + y * TILE + x] = deep


# --- КОРА: волокно вдоль стебля ---------------------------------------------
func _bark(img: Image, ox: int, oy: int, s: int, rng: RandomNumberGenerator,
		rec: Dictionary) -> void:
	var age: float = float(s) / float(STAGES - 1)
	var rough: float = lerpf(0.10, 0.34, age) * rec["rough"]
	var groove: float = rec["groove"]
	var fibre := PackedFloat32Array()
	fibre.resize(TILE)
	for x in range(TILE):
		fibre[x] = rng.randf_range(-1.0, 1.0)
	var soft := PackedFloat32Array()
	soft.resize(TILE)
	for x in range(TILE):
		soft[x] = (fibre[(x + TILE - 1) % TILE] + fibre[x] * 2.0
			+ fibre[(x + 1) % TILE]) / 4.0
	for _i in range(2 + int(round(3.0 * age * groove))):
		var at: int = rng.randi_range(0, TILE - 1)
		soft[at] = -1.0 * groove
		soft[(at + 1) % TILE] = lerpf(soft[(at + 1) % TILE], -0.7 * groove, 0.6)
	for y in range(TILE):
		for x in range(TILE):
			var along: float = (_hash01(x * 9173 + y * 311 + s * 77) - 0.5) * 0.5
			var tone: float = clampf(0.86 + (soft[x] + along) * rough, 0.30, 1.0)
			var c := _tint(Color(tone, tone, tone), rec)
			img.set_pixel(ox + x, oy + y, Color(c.r, c.g, c.b, 1.0))


# --- ЛИСТ ЛИАНЫ: пять лопастей, пальчатые жилки ------------------------------
func _leaf(img: Image, ox: int, oy: int, s: int, kind: int,
		rng: RandomNumberGenerator, rec: Dictionary) -> void:
	var age: float = float(s) / float(STAGES - 1)
	var cut_k: float = [1.0, 0.5, 1.7][kind] * rec["cut"]
	var wide_k: float = [1.0, 1.12, 0.88][kind]
	var stalk_k: float = [1.0, 0.85, 1.15][kind]
	var sinus: float = [0.45, 0.35, 0.55][kind] * stalk_k
	var sharp: float = rec["edge"]
	var rad: float = lerpf(9.2, 12.4, age)
	var cut: float = lerpf(0.12, 0.26, age) * cut_k
	var tooth: float = lerpf(0.03, 0.075, age) * cut_k * sharp
	var base_x: float = float(TILE) * 0.5
	var base_y: float = float(TILE) - 1.0
	var mid_x: float = base_x
	var mid_y: float = base_y - rad * 0.92
	var wob_a: float = rng.randf_range(0.0, TAU)
	var wob_b: float = rng.randf_range(0.0, TAU)

	var deep := _tint(Color(0.17, 0.26, 0.13).lerp(Color(0.14, 0.21, 0.11), age), rec)
	var body := _tint(Color(0.31, 0.44, 0.20).lerp(Color(0.26, 0.37, 0.17), age), rec)
	var lit := _tint(Color(0.45, 0.57, 0.27).lerp(Color(0.39, 0.49, 0.24), age), rec)
	var vein := _tint(Color(0.53, 0.61, 0.34).lerp(Color(0.47, 0.53, 0.30), age), rec)

	var tips: Array = []
	for k in range(5):
		var a: float = float(k - 2) * TAU / 5.0
		tips.append(Vector2(mid_x + rad * wide_k * sin(a), mid_y - rad * cos(a)))

	for y in range(TILE):
		for x in range(TILE):
			var px: float = float(x) + 0.5
			var py: float = float(y) + 0.5
			var dx: float = (px - mid_x) / wide_k
			var dy: float = py - mid_y
			var far: float = sqrt(dx * dx + dy * dy)
			if far > rad * 1.2:
				continue
			var phi: float = atan2(dx, -dy)
			var edge: float = rad * (1.0 - cut * (1.0 - cos(5.0 * phi)) * 0.5)
			var down: float = PI - absf(phi)
			edge *= 1.0 - sinus * exp(-(down / 0.55) * (down / 0.55))
			edge *= 1.0 + tooth * sin(19.0 * phi + wob_a) \
				+ 0.06 * sin(3.0 * phi + wob_b)
			if far > edge:
				continue
			var up: float = clampf((base_y - py) / maxf(rad * 1.4, 1.0), 0.0, 1.0)
			var col: Color = deep.lerp(body, clampf(up * 1.7, 0.0, 1.0))
			if far > edge * 0.55:
				col = col.lerp(lit, (far / edge - 0.55) / 0.45 * 0.6)
			var near_vein: float = 1e9
			for t in tips:
				near_vein = minf(near_vein,
					_to_line(Vector2(px, py), Vector2(base_x, base_y), t))
			if near_vein < 0.85:
				col = col.lerp(vein, 1.0 - near_vein / 0.85)
			if far > edge - 1.3:
				col = col.darkened(0.30 * sharp)
			img.set_pixel(ox + x, oy + y, Color(col.r, col.g, col.b, 1.0))


# --- ЛЕПЕСТОК: узкое донце, круглый свободный край ---------------------------
func _bloom(img: Image, ox: int, oy: int, s: int, kind: int,
		rng: RandomNumberGenerator, rec: Dictionary) -> void:
	var age: float = float(s) / float(STAGES - 1)
	var wide_k: float = [1.0, 0.82][kind] * rec["wide"]
	var tip_k: float = [1.0, 1.35][kind] * rec["sharp"]
	var open: float = clampf((age - 0.12) / 0.88, 0.0, 1.0)
	open = open * open * (3.0 - 2.0 * open)
	var long: float = lerpf(15.0, 29.0, open)
	var half: float = lerpf(3.4, 7.6, open) * wide_k
	half = minf(half, float(TILE) * 0.45)
	var foot_x: float = float(TILE) * 0.5
	var foot_y: float = float(TILE) - 1.0
	var wob: float = rng.randf_range(0.0, TAU)
	var bud := _tint(Color(0.55, 0.60, 0.38), rec)
	var body := _tint(Color(0.55, 0.60, 0.38).lerp(Color(0.92, 0.90, 0.78), open), rec)
	var lit := _tint(Color(0.62, 0.66, 0.44).lerp(Color(0.98, 0.96, 0.89), open), rec)
	var deep := _tint(Color(0.42, 0.47, 0.30).lerp(Color(0.72, 0.68, 0.56), open), rec)
	var vein := _tint(Color(0.50, 0.55, 0.34).lerp(Color(0.84, 0.80, 0.64), open), rec)

	for y in range(TILE):
		for x in range(TILE):
			var px: float = float(x) + 0.5
			var py: float = float(y) + 0.5
			var up: float = (foot_y - py) / long
			if up < 0.0 or up > 1.0:
				continue
			var wide_at: float = half * pow(sin(PI * clampf(up, 0.0, 1.0)),
				0.55 / tip_k)
			wide_at *= 1.0 + 0.06 * sin(5.0 * up * PI + wob)
			var dx: float = absf(px - foot_x)
			if dx > wide_at:
				continue
			var edge: float = dx / maxf(wide_at, 0.5)
			var col: Color = body.lerp(lit, up * 0.7)
			if dx < 0.9:
				col = col.lerp(vein, 1.0 - dx / 0.9)
			if edge > 0.72:
				col = col.lerp(deep, (edge - 0.72) / 0.28)
			if open < 0.35:
				col = col.lerp(bud, (0.35 - open) / 0.35 * 0.55)
			img.set_pixel(ox + x, oy + y, Color(col.r, col.g, col.b, 1.0))


# --- ТЕЛО ЛИАМОХА: светлые волоски по тёмному основанию ----------------------
func _lia_body(img: Image, ox: int, oy: int, s: int, rng: RandomNumberGenerator,
		rec: Dictionary) -> void:
	var age: float = float(s) / float(STAGES - 1)
	var ground := _tint(Color(0.38, 0.43, 0.32).lerp(Color(0.34, 0.39, 0.29), age), rec)
	for y in range(TILE):
		for x in range(TILE):
			var n: float = (_hash01(x * 7919 + y * 104729 + s * 61) - 0.5) * 0.09
			var c: Color = ground.lightened(n) if n > 0.0 else ground.darkened(-n)
			img.set_pixel(ox + x, oy + y, Color(c.r, c.g, c.b, 1.0))
	var many: int = maxi(4, int(round(lerpf(float(LIA_HAIR_YOUNG),
		float(LIA_HAIR_OLD), age) * rec["many"])))
	var long: float = float(TILE) * lerpf(LIA_HAIR_SHORT, LIA_HAIR_LONG, age) \
		* rec["long"]
	for i in range(many):
		var x0: float = rng.randf_range(0.0, float(TILE))
		var y0: float = rng.randf_range(0.0, float(TILE))
		var ang: float = rng.randf_range(0.0, TAU)
		var bend: float = rng.randf_range(-0.6, 0.6)
		var reach: float = long * rng.randf_range(0.6, 1.45)
		var tip: float = rng.randf_range(0.16, 0.45)
		var steps: int = maxi(2, int(ceil(reach * 2.0)))
		for j in range(steps):
			var t: float = float(j) / float(steps - 1)
			var a: float = ang + bend * t
			var px: int = int(round(x0 + cos(a) * reach * t))
			var py: int = int(round(y0 + sin(a) * reach * t))
			var c: Color = ground.lightened(tip * (0.35 + 0.65 * t))
			img.set_pixel(ox + posmod(px, TILE), oy + posmod(py, TILE),
				Color(c.r, c.g, c.b, 1.0))


# --- ВОРСИНКА ЛИАМОХА: пучок волосков от нижнего края ------------------------
func _lia_fuzz(img: Image, ox: int, oy: int, s: int, rng: RandomNumberGenerator,
		rec: Dictionary) -> void:
	var age: float = float(s) / float(STAGES - 1)
	for y in range(TILE):
		for x in range(TILE):
			img.set_pixel(ox + x, oy + y, Color(0, 0, 0, 0))
	var hairs: int = maxi(1, int(round(lerpf(float(LIA_TUFT_YOUNG),
		float(LIA_TUFT_OLD), age) * rec["many"])))
	var tall: float = float(TILE) * lerpf(0.45, 0.85, age) * rec["long"]
	tall = minf(tall, float(TILE) * 0.95)
	var root := _tint(Color(0.31, 0.38, 0.24), rec)
	var tip := _tint(Color(0.62, 0.68, 0.47), rec)
	for i in range(hairs):
		var x0: float = float(TILE) * (0.5 + (rng.randf() - 0.5) * 0.55)
		var reach: float = tall * rng.randf_range(0.6, 1.15)
		var lean: float = (x0 / float(TILE) - 0.5) * 1.2 + rng.randf_range(-0.2, 0.2)
		var wide: int = 2 if rng.randf() < 0.35 + 0.3 * age else 1
		var steps: int = maxi(3, int(ceil(reach)))
		for j in range(steps):
			var t: float = float(j) / float(steps - 1)
			var px: int = int(round(x0 + lean * reach * t * t))
			var py: int = TILE - 1 - int(round(reach * t))
			if px < 1 or px >= TILE - 1 or py < 1 or py >= TILE:
				continue
			var c: Color = root.lerp(tip, t)
			for w in range(wide):
				var qx: int = px + w
				if qx < 1 or qx >= TILE - 1:
					continue
				img.set_pixel(ox + qx, oy + py,
					Color(c.r, c.g, c.b, 1.0 if w == 0 else 1.0 - 0.55 * t))
