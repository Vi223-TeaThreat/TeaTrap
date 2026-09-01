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
		"ax": ["форма: плющ / виноград / ива", "выраженность формы: мягче / как есть / резче"],
		# НАПРАВЛЕНИЕ СМЕНЕНО ПО РЕФЕРЕНСАМ (решение пользователя 31.08.2026,
		# Пинтерест по «pixel art leaf»): не один лист с разной глубиной
		# вырезов, а разные СИЛУЭТЫ. С референсов взяты приёмы, а не картинки.
		# Вторым решением того же дня ВСЕ ВАРИАНТЫ — В МЯГКОЙ ОКРАСКЕ: выбор
		# манеры из сетки убран. Пиксельартовая ступенчатость с тех пор стала
		# общей для всего листа и в сетке не участвует.
		"cats": [
			["shape", ["ivy", "grape", "willow"], "grape"],
			["cut", [0.7, 1.0, 1.4], 1.0]]},
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
	# Забрать нарисованное от руки из её файла. Генератор при этом не работает.
	if args.has("hand-from"):
		_take_hand(str(args["hand-from"]), str(args.get("part", "")))
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
	# ЛИСТ ЦЕЛИКОМ СВОЙ — для суда сторожей. Рукописные столбцы не наша работа
	# и судить их нашими мерками нечестно: они эталон, а не подопытный.
	if args.has("all"):
		var rec2 := _load_recipes()
		_hgt.resize(TILE * TILE * STAGES)
		var img2 := _build(rec2, null)
		_save(img2, "res://art/pick_all.png")
		print("Лист целиком своей работы — art/pick_all.png")
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
	for cat in PARTS[part].get("cats", []):
		if args.has(cat[0]) and cat[1].has(str(args[cat[0]])):
			base[cat[0]] = str(args[cat[0]])

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
	for cat in PARTS[part].get("cats", []):
		rec[cat[0]] = cat[2]
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
			if not got[p].has(k):
				continue
			# Черты-сочетания хранятся словом, черты-множители числом.
			if typeof(out[p][k]) == TYPE_STRING:
				out[p][k] = str(got[p][k])
			else:
				out[p][k] = float(got[p][k])
	return out


func _save_recipes(rec: Dictionary) -> void:
	var f := FileAccess.open(ProjectSettings.globalize_path(RECIPES), FileAccess.WRITE)
	f.store_string(JSON.stringify(rec, "\t"))
	f.close()


# Девять рецептов сеткой: три значения первой черты на три значения второй.
# `move` сжимает или растягивает шаг — когда подошли близко, шаги мельчают.
# У картинки с чертами-СОЧЕТАНИЯМИ (лист: форма и окраска) сетка перечисляет
# сочетания, и `move` ей не указ — между «плющом» и «ивой» середины нет.
func _grid(part: String, base: Dictionary, move: float) -> Array:
	var out := []
	if PARTS[part].has("cats"):
		var cats: Array = PARTS[part]["cats"]
		for j in range(3):
			for i in range(3):
				var r := base.duplicate()
				r[cats[0][0]] = cats[0][1][i]
				r[cats[1][0]] = cats[1][1][j]
				out.append(r)
		return out
	var knobs: Array = PARTS[part]["knobs"]
	var step: float = clampf(0.42 * move, 0.05, 0.9)
	var mul := [1.0 / (1.0 + step), 1.0, 1.0 + step]
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
	if not PARTS[part].has("cats"):
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


# =============================================================================
#  ЗАБРАТЬ НАРИСОВАННОЕ ОТ РУКИ  (`--hand-from=<файл> --part=<кто>`)
# =============================================================================
#
#  Она рисует в КОПИИ листа-заготовки (свой файл, игра его не читает), а потом
#  говорит, что готово. Дело этой команды — перенести нарисованные столбцы в
#  игру, не тронув ничего другого.
#
#  ГЕНЕРАТОР ПРИ ЭТОМ НЕ ЗАПУСКАЕТСЯ ВОВСЕ, и это главное. Её решение 01.09.2026
#  — «используй текстуры старые, не нагенерированные вчера»; пересборка листа
#  рецептами вернула бы машинные картинки во все прочие столбцы. Поэтому
#  столбцы кладутся ПРЯМО в `art/moss.png` поверх нынешнего, точка в точку.
#
#  Заодно они попадают в `art/moss_hand.png` — оттуда генератор их уже не
#  тронет, если она когда-нибудь снова захочет им пользоваться.
#
#  СТОРОЖА ТЕ ЖЕ. Нарисованное проверяется на то же, на что и своя работа:
#  полупрозрачные точки в вырезанной фигурке и заезд на край клетки (по краю
#  дощечки картинка тянется от соседнего столбца, и на силуэте это черта чужого
#  цвета). Отказ печатается, файл не трогается.
func _take_hand(path: String, part: String) -> void:
	if not PARTS.has(part):
		print("Чью работу берём? --part=", ", ".join(PARTS.keys()))
		return
	var src := Image.load_from_file(ProjectSettings.globalize_path(path))
	if src == null:
		print("Файла ", path, " нет или он не читается")
		return
	if src.get_height() != TILE * STAGES:
		print("Лист должен быть ", TILE * STAGES, " точек в высоту, а он ",
			src.get_height())
		return
	var cols: Array = PARTS[part]["cols"]
	var solid: bool = PARTS[part]["solid"]
	var have: int = int(src.get_width() / TILE)
	var bad := 0
	var empty := 0
	for c in cols:
		var col: int = int(c)
		if col >= have:
			print("В файле нет столбца ", col + 1, " — он всего ", have, " шириной")
			return
		for s in range(STAGES):
			var seen := 0
			for x in range(TILE):
				for y in range(TILE):
					var p := src.get_pixel(col * TILE + x, s * TILE + y)
					if p.a <= 0.02:
						continue
					seen += 1
					if not solid:
						if p.a < 0.98:
							bad += 1
						elif x == 0 or x == TILE - 1 or y == 0:
							bad += 1
			if seen == 0:
				empty += 1
	if bad > 0:
		print("НЕ ВЗЯТО: сторожа насчитали ", bad,
			" нарушений — полупрозрачные точки или заезд на край клетки")
		return
	if empty > 0:
		print("ВНИМАНИЕ: пустых клеток ", empty,
			" — в этих возрастах картинки не будет вовсе")
	# В ИГРОВОЙ ЛИСТ — прямо, поверх нынешнего.
	var art := Image.load_from_file(ProjectSettings.globalize_path(ART))
	if art == null:
		print("Игрового листа ", ART, " нет — брать некуда")
		return
	_save(art, PREV)
	# И В ЗАМОРОЗКУ РУКИ. Файл мог быть узким (в нём только мховые столбцы) —
	# расширяем до полного, недостающее остаётся прозрачным.
	var hand := _hand_from_file()
	var keep := Image.create(TILE * COLS, TILE * STAGES, false, Image.FORMAT_RGBA8)
	keep.fill(Color(0, 0, 0, 0))
	if hand != null:
		keep.blit_rect(hand, Rect2i(0, 0, hand.get_width(), TILE * STAGES),
			Vector2i.ZERO)
	for c in cols:
		var col: int = int(c)
		var box := Rect2i(col * TILE, 0, TILE, TILE * STAGES)
		art.blit_rect(src, box, Vector2i(col * TILE, 0))
		keep.blit_rect(src, box, Vector2i(col * TILE, 0))
	_save(art, ART)
	_save(keep, HAND)
	print("Взято от руки: «", PARTS[part]["ru"], "», столбцов ", cols.size(),
		" — легли в art/moss.png и заморожены в art/moss_hand.png")
	print("Прежний лист сохранён в art/moss_prev.png — один шаг отмены")


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
	# ПРАВИЛА АРТА (решения пользователя 31.08.2026):
	#   1. Лист примыкает к черешку точкой А — низом середины клетки: на
	#      средних столбцах в нижней части клетки обязана быть непрозрачная
	#      точка, иначе пластина висит над черешком. Глубина взята от игры:
	#      трубочка черешка входит в пластину на `stalk_lap` 0.45 — досягать
	#      надо до её конца, это 12 точек от низа клетки.
	#   2. Жилкование начинается от точки А — это держат сами рисовальщики
	#      (жилки всех форм строятся лучами из А), сторожу тут мерить нечего.
	var a_bad: int = 0
	for col in PARTS["leaf"]["cols"]:
		for s in range(STAGES):
			var stuck := false
			for x in [TILE / 2 - 1, TILE / 2]:
				for y in range(TILE - 12, TILE):
					if img.get_pixel(int(col) * TILE + x, s * TILE + y).a > 0.0:
						stuck = true
			if not stuck:
				a_bad += 1
	print("  клеток листа, не примкнувших к черешку точкой А: ", a_bad)
	bad += a_bad
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
#
# Сравниваем с ЧИСТЫМИ рисовальщиками (`_make_blade_texture`), а не с тем, что
# игра читает: как только генератор записал полный лист, `_blade_texture`
# отдаёт файл — то есть наш же вчерашний выбор, и сверка с ним мерила бы нас об
# нас самих (грабля «мерку и инструмент нельзя строить на одной формуле»).
func _check() -> void:
	print("=== СТОРОЖА ГЕНЕРАТОРА ТЕКСТУР ===")
	var plants := Plants.new()
	var def := _default_recipes()
	var full: Image = plants._make_blade_texture().get_image()
	if full.get_format() != Image.FORMAT_RGBA8:
		full.convert(Image.FORMAT_RGBA8)
	# Тот же порядок, что у игры: семя 913377, на каждом возрасте все особые
	# столбцы, мох после всех своей чередой.
	var mine := Image.create(TILE * COLS, TILE * STAGES, false, Image.FORMAT_RGBA8)
	mine.fill(Color(0, 0, 0, 0))
	_hgt.resize(TILE * TILE * STAGES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 913377
	for s in range(STAGES):
		_paint("body", mine, BODY_COL * TILE, s * TILE, s, 0, rng, def["body"])
		_paint("bark", mine, BARK_COL * TILE, s * TILE, s, 0, rng, def["bark"])
		for k in range(LEAF_KINDS):
			_paint("leaf", mine, (LEAF_COL + k) * TILE, s * TILE, s, k, rng, def["leaf"])
		for k in range(BLOOM_KINDS):
			_paint("bloom", mine, (BLOOM_COL + k) * TILE, s * TILE, s, k, rng, def["bloom"])
		_paint("liabody", mine, LIA_BODY_COL * TILE, s * TILE, s, 0, rng, def["liabody"])
		_paint("liafuzz", mine, LIA_FUZZ_COL * TILE, s * TILE, s, 0, rng, def["liafuzz"])
	for s in range(STAGES):
		for k in range(KINDS):
			_paint("moss", mine, k * TILE, s * TILE, s, k, rng, def["moss"])
	var off: int = 0
	for col in range(COLS):
		for s in range(STAGES):
			for y in range(TILE):
				for x in range(TILE):
					if full.get_pixel(col * TILE + x, s * TILE + y) \
							!= mine.get_pixel(col * TILE + x, s * TILE + y):
						off += 1
	print("Сверка с рисовальщиками игры (все 13 столбцов): расхождений ", off,
		" (норма 0)")

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
	print("  (у чистой заглушки игры: %.4f)" % _slope(full, BODY_COL))
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
		"moss": _moss(img, ox, oy, s, kind, rng, rec)
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


# =============================================================================
#  ПАНДУС И КЛЕТЧАТЫЙ ПОРОГ — ЯДРО ПИКСЕЛЬАРТА
#
#  ЗАМЕР, С КОТОРОГО ВСЁ НАЧАЛОСЬ (31.08.2026, `tools/pixelcmp.py`). Рукописный
#  мох пользователя против того, что рисовал генератор:
#
#      величина              рука      тело мха      кора      лист
#      цветов в клетке         14           741       107       120
#      сдвиг тона, град      −26.2           0.0       0.0      −3.3
#      размах яркости        0.379             —     0.200     0.173
#      шаг ступени           0.029         0.000     0.005     0.009
#      доля одиночек         0.544         0.980     0.905     0.631
#      доля шахматки         0.104         0.002     0.014     0.003
#
#  Семьсот сорок один цвет против четырнадцати — это не «другой облик», это
#  разные ремёсла. Плавная растяжка цвета даёт сотни почти одинаковых оттенков,
#  каждая точка своего цвета, и потому каждая сидит одна: пиксельарт держится
#  на ПЯТНАХ ОДНОГО ЦВЕТА, а пятен нет вовсе.
#
#  ЧИНИТСЯ ОДНИМ: рисовальщик кладёт не цвет, а НОМЕР СТУПЕНИ. Цвета берутся из
#  пандуса — короткого упорядоченного набора, построенного заранее.
#
#  ТРИ ВЕЩИ ДЕЛАЮТ ПАНДУС ПАНДУСОМ, а не набором затемнений:
#    * СДВИГ ТОНА. К свету оттенок уходит в тепло, к тени — в холод. Простое
#      затемнение оттенка не меняет, и рука это видит сразу. У пользователя
#      замерено 26 градусов, у нас было ноль.
#    * НАСЫЩЕННОСТЬ ГОРБОМ. Она наибольшая в полутени и падает к свету: на
#      свету краска выцветает, в глубокой тени уходит в серость.
#    * РАЗМАХ. Между самой тёмной и самой светлой ступенью должна быть треть
#      яркости, иначе фигурка читается плоским пятном.
#
#  ПРОМЕЖУТКИ МЕЖДУ СТУПЕНЯМИ ЗАКРЫВАЕТ КЛЕТЧАТЫЙ ПОРОГ (Байер 4×4), а не
#  подмешивание цвета: подмешаешь — снова получишь сотни оттенков. Порог 4×4
#  делит 32 нацело, поэтому на бесшовном образце узор сходится сам с собой.
# =============================================================================

const BAYER := [
	[0, 8, 2, 10],
	[12, 4, 14, 6],
	[3, 11, 1, 9],
	[15, 7, 13, 5],
]


# ОДНА ПАЛИТРА НА ВЕСЬ ЛИСТ. Прежде пандус строился заново на каждый возраст
# каждого столбца — и на листе набиралось 302 цвета при норме 48. Настоящий
# пиксельарт так не делают: у него один словарь на всю работу, и семейство
# картинок расходится СДВИГОМ ПО ОБЩЕМУ ПАНДУСУ, а не своими красками.
#
# Отсюда устройство: три длинных пандуса (зелень, серость коры, кремовый цветок)
# плюс короткий ржавый. Столбец берёт из них ОКНО — свой кусок, — и возраст
# двигает это окно, а не перекрашивает ступени. Лиамох потому и светлее мха, что
# сидит выше по тому же пандусу: так его светлота приходит от рисунка, как и
# записано в README, но новых цветов при этом не заводится.
var _pal := {}

func _palette(rec: Dictionary) -> Dictionary:
	var key: String = "%.3f|%.3f|%.3f" % [rec.get("dark", 0.0),
		rec.get("warm", 0.0), rec.get("vivid", 0.0)]
	if _pal.has(key):
		return _pal[key]
	var made := {
		"green": _ramp(Color(0.33, 0.47, 0.22), 11, 0.82, -92.0, rec),
		"bark": _ramp(Color(0.62, 0.62, 0.62), 7, 0.58, 0.0, rec),
		"bloom": _ramp(Color(0.74, 0.75, 0.56), 8, 0.62, 52.0, rec),
		"rust": _ramp(Color(0.42, 0.33, 0.18), 3, 0.30, -26.0, rec),
	}
	_pal[key] = made
	return made


# Окно пандуса: кусок общего набора от `lo` до `hi` включительно. Столбцы берут
# разные окна — этим они и различаются по светлоте, не заводя своих красок.
func _slice(ramp: PackedColorArray, lo: int, hi: int) -> PackedColorArray:
	var out := PackedColorArray()
	for i in range(clampi(lo, 0, ramp.size() - 1), clampi(hi, 0, ramp.size() - 1) + 1):
		out.append(ramp[i])
	return out


# Пандус: `steps` ступеней вокруг `base`, размахом `span` по яркости и с уводом
# оттенка на `twist` градусов от тёмного конца к светлому.
func _ramp(base: Color, steps: int, span: float, twist: float,
		rec: Dictionary) -> PackedColorArray:
	var b: Color = _tint(base, rec)
	var out := PackedColorArray()
	for i in range(steps):
		var t: float = float(i) / float(steps - 1)
		var v: float = clampf(b.v + (t - 0.5) * span, 0.04, 1.0)
		var h: float = fposmod(b.h + (t - 0.5) * twist / 360.0, 1.0)
		# Горб насыщенности: гуще всего в полутени, бледнее к свету.
		var s: float = clampf(b.s * (1.0 + 0.22 * sin(PI * t) - 0.34 * t), 0.0, 1.0)
		out.append(Color.from_hsv(h, s, v))
	return out


# «Положить точку ступенью пандуса» (`_lay`) убрана 2026-09-01: её никто не
# звал. Укладку ступеней делает `_finish` по готовому полю долей — см. ниже.


# ПОЛЕ СТУПЕНЕЙ. Рисовальщик заполняет не картинку, а поле долей: −1 значит
# «здесь пусто». Так между расчётом формы и укладкой цвета появляется место, где
# можно навести пиксельартовый порядок разом для всех картинок — обвести край,
# вычистить одиночные точки, — не трогая ни одной формулы формы.
func _field() -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(TILE * TILE)
	f.fill(-1.0)
	return f


# Уложить поле цветом: доли превращаются в номера ступеней клетчатым порогом,
# затем чистятся одиночки, и только потом ложится краска.
# `rim` — на сколько СТУПЕНЕЙ темнеет точка у края силуэта. Мера в ступенях, а не
# в долях: окна пандуса у столбцов разной длины, и одна и та же доля означала бы
# у лепестка неполную ступень (то есть каёмку, которой на трети контура нет), а у
# листа — почти две.
#
# `wrap` — заворот по клетке для бесшовных образцов: у них соседом левого края
# служит правый, и чистить сор надо с этим же заворотом, иначе при замощении
# вычищенная середина сходится с невычищенной рамкой.
func _finish(img: Image, ox: int, oy: int, lv: PackedFloat32Array,
		ramp: PackedColorArray, dither: float, tidy: int = 1,
		rim: int = 0, wrap: bool = false) -> void:
	var top: int = ramp.size() - 1
	var idx := PackedInt32Array()
	idx.resize(TILE * TILE)
	for y in range(TILE):
		for x in range(TILE):
			var p: int = y * TILE + x
			if lv[p] < 0.0:
				idx[p] = -1
				continue
			var f: float = clampf(lv[p], 0.0, 1.0) * float(top)
			var i: int = int(floorf(f))
			var frac: float = f - float(i)
			if i >= top:
				i = top
				frac = 0.0
			var gate: float = 0.5
			if dither > 0.0:
				var bay: float = (float(BAYER[y & 3][x & 3]) + 0.5) / 16.0
				gate = lerpf(0.5, bay, clampf(dither, 0.0, 1.0))
			idx[p] = clampi(i + (1 if frac > gate else 0), 0, top)
	for _pass in range(tidy):
		idx = _declutter(idx, wrap)
	# КАЁМКА — ПОСЛЕ ЧИСТКИ. Прежде она наводилась до неё, и чистка видела в
	# обводе цепочку точек, у которых меньше двух родных соседей, и притягивала
	# её обратно к телу фигурки: у лепестка и у ворсинки лиамоха обвода не
	# оставалось на большей половине контура.
	if rim > 0:
		var was := idx.duplicate()
		for y in range(TILE):
			for x in range(TILE):
				var q: int = y * TILE + x
				if was[q] < 0:
					continue
				var edge := false
				for n in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
					var nx: int = x + int(n[0])
					var ny: int = y + int(n[1])
					# Низ не в счёт: им фигурка растёт из тела, и каёмка там
					# рисовала бы черту поперёк стыка.
					if ny >= TILE:
						continue
					if nx < 0 or nx >= TILE or ny < 0 or was[ny * TILE + nx] < 0:
						edge = true
						break
				if edge:
					idx[q] = maxi(0, was[q] - rim)
	for y in range(TILE):
		for x in range(TILE):
			var p: int = y * TILE + x
			if idx[p] < 0:
				continue
			var c: Color = ramp[idx[p]]
			img.set_pixel(ox + x, oy + y, Color(c.r, c.g, c.b, 1.0))
	_bleed(img, ox, oy, idx, ramp)


# КРАСКА ЗАХОДИТ ПОД ПРОЗРАЧНОЕ — ЗАПАС, А НЕ ЛЕЧЕНИЕ.
#
# ЧЕСТНО О ТОМ, ЗАЧЕМ ЭТО (перепроверка 01.09.2026). Сперва здесь было написано,
# что без такой заливки по силуэту листа в игре идёт тёмная кайма. ЭТО БЫЛО
# НЕВЕРНО, и проверка показала почему: лист читается `filter_nearest` (см.
# `Blades.gdshader`), мипмапы у него выключены (`mipmaps/generate=false` в
# `art/moss.png.import`), а сам Godot при ввозе заливает край сам
# (`process/fix_alpha_border=true`) — и делает это на четыре кольца, глубже нас.
# Никакой каймы не было и быть не могло: при выборке ближайшей точки цвет из-под
# прозрачного не берётся вовсе.
#
# Почему оставлено. Стоит это доли миллисекунды, а держит ровно один случай:
# если фильтр когда-нибудь станет линейным или включатся мипмапы, чёрное из-под
# края полезет наружу. Пусть лежит запасом — но называть это починкой нельзя.
func _bleed(img: Image, ox: int, oy: int, idx: PackedInt32Array,
		ramp: PackedColorArray) -> void:
	for y in range(TILE):
		for x in range(TILE):
			if idx[y * TILE + x] >= 0:
				continue
			# НЕ ТРОГАТЬ ЧУЖОЕ. У ворсинки мха `_finish` зовётся дважды —
			# зеленью и ржавчиной, — и заливка второго прохода СТИРАЛА
			# нарисованное первым: всё, чего нет в ржавом поле, объявлялось
			# пустым и получало нулевую прозрачность. Мохнатый край съедался
			# начисто, а замеры силуэта делались по выеденной картинке.
			if img.get_pixel(ox + x, oy + y).a > 0.0:
				continue
			var near: int = -1
			for n in [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [-1, -1],
					[1, -1], [-1, 1]]:
				var nx: int = x + int(n[0])
				var ny: int = y + int(n[1])
				if nx < 0 or nx >= TILE or ny < 0 or ny >= TILE:
					continue
				if idx[ny * TILE + nx] >= 0:
					near = idx[ny * TILE + nx]
					break
			if near < 0:
				continue
			var c: Color = ramp[near]
			img.set_pixel(ox + x, oy + y, Color(c.r, c.g, c.b, 0.0))


# ЧИСТКА ОДИНОЧЕК. Точка, у которой ни один сосед не одного с ней цвета, читается
# не рисунком, а сором: пиксельарт держится на ПЯТНАХ. Такую точку притягиваем к
# самому частому соседу — не к среднему, иначе родится новый оттенок и одиночка
# просто переедет. Обход идёт по образу, снятому до правки: иначе исправленная
# точка тут же начинает влиять на следующую, и чистка ползёт волной.
func _declutter(src: PackedInt32Array, wrap: bool = false) -> PackedInt32Array:
	var out := src.duplicate()
	for y in range(TILE):
		for x in range(TILE):
			var p: int = y * TILE + x
			if src[p] < 0:
				continue
			# СЧИТАЕМ ПО ВОСЬМИ СОСЕДЯМ И ТРЕБУЕМ ДВУХ РОДНЫХ. Одного мало:
			# пара точек по диагонали читается не пятном, а сором — у настоящего
			# пиксельарта таких меньше двадцатой доли.
			var seen := {}
			var kin: int = 0
			for dx in [-1, 0, 1]:
				for dy in [-1, 0, 1]:
					if dx == 0 and dy == 0:
						continue
					var nx: int = x + dx
					var ny: int = y + dy
					if wrap:
						nx = posmod(nx, TILE)
						ny = posmod(ny, TILE)
					elif nx < 0 or nx >= TILE or ny < 0 or ny >= TILE:
						continue
					var q: int = src[ny * TILE + nx]
					if q < 0:
						continue
					if q == src[p]:
						kin += 1
					else:
						seen[q] = int(seen.get(q, 0)) + 1
			if kin >= 2 or seen.is_empty():
				continue
			var best: int = -1
			var many: int = 0
			for k in seen.keys():
				if int(seen[k]) > many or (int(seen[k]) == many and int(k) < best):
					many = int(seen[k])
					best = int(k)
			out[p] = best
	return out


# МЯГКИЕ ПЯТНА, СТЫКУЮЩИЕСЯ САМИ С СОБОЙ. Решётка `cells` на клетку, значения в
# узлах от хеша, между узлами — сглаженная доля. Заворот по решётке делает
# образец бесшовным.
#
# Зачем понадобилось. У фактуры бесшовного образца есть две ямы, и обе мы прошли:
# крупинка НА КАЖДУЮ ТОЧКУ читается телевизионным снегом (а линейный хеш вдобавок
# рисует диагональную рябь), ровная же заливка — клеёнкой. Замер: у тела лиамоха
# доля совершенно плоских мест дошла до 0.82 при 0.66 у верхней границы
# настоящего пиксельарта. Верное между ними — ПЯТНА размером в несколько точек:
# после укладки ступенями они дают острова соседних тонов, то есть ту самую
# фактуру, какую рисуют рукой.
func _blobs(x: int, y: int, cells: int, seed: int) -> float:
	var fx: float = float(x) / float(TILE) * float(cells)
	var fy: float = float(y) / float(TILE) * float(cells)
	var x0: int = int(floorf(fx))
	var y0: int = int(floorf(fy))
	var tx: float = fx - float(x0)
	var ty: float = fy - float(y0)
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var at := func(ax: int, ay: int) -> float:
		return _hash01(posmod(ax, cells) * 374761393
			+ posmod(ay, cells) * 668265263 + seed * 1442695041)
	return lerpf(lerpf(at.call(x0, y0), at.call(x0 + 1, y0), tx),
		lerpf(at.call(x0, y0 + 1), at.call(x0 + 1, y0 + 1), tx), ty)


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
# --- ВОРСИНКА МХА: подушка в профиль, мохнатая по краю -----------------------
#
# Ворсинки 1-4 нарисованы пользователем от руки; здесь — генераторская
# разновидность на случай, если предложенная понравится больше своей.
func _moss(img: Image, ox: int, oy: int, s: int, kind: int,
		rng: RandomNumberGenerator, rec: Dictionary) -> void:
	var age: float = float(s) / float(STAGES - 1)
	# ЧЕТЫРЕ РАЗНОВИДНОСТИ ОБЯЗАНЫ РАСХОДИТЬСЯ СИЛУЭТОМ, а не рисунком: разница,
	# видимая только вблизи, не разница вовсе. Прежде kind не спрашивался вовсе,
	# и четыре столбца выходили одинаковыми до точки.
	var tall_k: float = [1.0, 0.70, 1.30, 0.90][kind]
	var wide_k: float = [1.0, 1.30, 0.74, 1.12][kind]
	var lump_k: float = [1.0, 0.5, 1.7, 1.25][kind]
	var lean: float = [0.0, 1.6, -1.4, 0.7][kind]
	var puff: float = rec["puff"]
	var edge_k: float = rec["edge"]
	var high: float = lerpf(0.16, 0.62, age) * float(TILE) * puff * tall_k
	high = minf(high, float(TILE) * 0.92)
	var half: float = lerpf(0.22, 0.46, age) * float(TILE) * puff * wide_k
	half = minf(half, float(TILE) * 0.47)
	var fuzz: int = int(round(lerpf(1.0, 4.0, age) * edge_k))

	var lv := _field()
	var rust := _field()
	var mid_x: float = float(TILE) * 0.5 + lean + rng.randf_range(-2.0, 2.0)
	var wave_a: float = rng.randf_range(0.0, TAU)
	var wave_b: float = rng.randf_range(0.0, TAU)
	for x in range(TILE):
		var dx: float = (float(x) - mid_x) / half
		if absf(dx) >= 1.0:
			continue
		var dome: float = sqrt(maxf(0.0, 1.0 - dx * dx))
		var lump: float = (sin(float(x) * 0.9 + wave_a) * 0.11 \
			+ sin(float(x) * 2.3 + wave_b) * 0.06) * lump_k
		# Ворс поднимает САМУ МАКУШКУ, а не сыплется точками поверх неё: тогда у
		# подушки один силуэт и ни одного оторванного куска.
		var shag: float = 0.0
		if fuzz > 0:
			shag = float(fuzz) * (0.45 + 0.55
				* _hash01((x / 2) * 7919 + s * 61 + kind * 977))
		var top: int = TILE - 1 - int(round(high * (dome + lump) + shag))
		top = clampi(top, 1, TILE - 1)
		for y in range(top, TILE):
			var up: float = float(TILE - 1 - y) / maxf(high, 1.0)
			var level: float = 0.10 + 0.60 * clampf(up * 1.6, 0.0, 1.0)
			if up > 0.55:
				level += 0.24 * (up - 0.55) / 0.45
			# Ворсинки: тонкая вертикальная рябь через столбец. Именно она и
			# делает бархат — сплошная заливка выглядит краской.
			if (x + int(up * 7.0)) % 3 == 0:
				level -= 0.12
			elif x % 5 == 0:
				level += 0.10
			lv[y * TILE + x] = clampf(level, 0.0, 1.0)
			# Ржавчина у старых куртин идёт СВОИМ пандусом: подмешивать её в
			# зелёный значило бы плодить оттенки, а их и так было слишком много.
			# РЖАВЧИНА — СУХИЕ КОНЧИКИ, А НЕ ПЯТНА ПО ТЕЛУ. Пятно посреди зелени
			# читается дыркой или комком грязи; в жизни у старой куртины буреют
			# именно верхушки. Поэтому берём только верхнюю треть подушки и
			# ведём мазок вниз по столбцу — выходит подсохший кончик.
			if age > 0.6 and up > 0.62 and rng.randf() < 0.035:
				for dy in range(2):
					var qy: int = y + dy
					if qy >= TILE:
						continue
					rust[qy * TILE + x] = clampf(0.35 + up * 0.5, 0.0, 1.0)
		# МОХНАТЫЙ КРАЙ — ЧАСТЬ СИЛУЭТА, А НЕ ТОЧКИ ПОВЕРХ НЕГО. Прежде ворс
		# сыпался отдельными точками над макушкой, и сторож насчитал 24 клетки,
		# где открытие уничтожало целые куски: точка в одну точку толщиной не
		# живёт ни при уменьшении, ни в игре. Теперь ворсинка — зубец, стоящий
		# на теле подушки, и она не тоньше двух точек.

	var base := Color(0.33, 0.47, 0.22).lerp(Color(0.29, 0.42, 0.19), age)
	var gp: PackedColorArray = _palette(rec)["green"]
	var sh: int = int(round(age * 2.0))
	_finish(img, ox, oy, lv, _slice(gp, 2 - sh, 9 - sh), 0.16, 2, 1)
	_finish(img, ox, oy, rust, _palette(rec)["rust"], 0.0, 0)


# --- ТЕЛО МХА: куски с ломаными границами ------------------------------------
#
# Клетка ДЕЛИТСЯ на куски: точка достаётся тому пятну, чья мерка ближе. Куски
# неравны, некруглы и с рваной границей — три приёма, ни одного круга.
#
# ОТ ЦВЕТА КАЖДОГО КУСКА ПРИШЛОСЬ ОТКАЗАТЬСЯ. Прежде у куска был свой оттенок,
# у крупного пятна свой, да ещё крупинка на точку — и в клетке набиралось 741
# цветов при четырнадцати у руки. Теперь оттенок куска правит НОМЕРОМ СТУПЕНИ, а
# не цветом: тот же рисунок, но красками из пандуса.
func _body(img: Image, ox: int, oy: int, s: int, rng: RandomNumberGenerator,
		rec: Dictionary) -> void:
	var age: float = float(s) / float(STAGES - 1)
	var big_k: float = rec["clump"]
	var mottle: float = rec["mottle"]
	var base := Color(0.31, 0.44, 0.21).lerp(Color(0.27, 0.39, 0.18), age)
	var lv := _field()
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

	var at: int = s * TILE * TILE
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

			# Оттенок куска, крупного пятна и крупинки — всё это теперь двигает
			# НОМЕР СТУПЕНИ. Множители подобраны так, чтобы размах вышел как у
			# руки (0.38 по яркости), а не как прежде (его не было вовсе).
			var lig: float = (c_lit[win] + b_lit[bigi] \
				+ (_hash01(x * 31337 + y * 6151 + s * 13) - 0.5) * 0.07) * mottle
			var level: float = 0.52 + lig * 3.1
			# Шов между кусками темнее — но чуть-чуть: холмы лепит свет, а не
			# нарисованная тень.
			level -= 0.26 * (1.0 - deep)
			lv[y * TILE + x] = clampf(level, 0.0, 1.0)
			_hgt[at + y * TILE + x] = deep

	# Чистку одиночек телу НЕ даём: мховая подушка вблизи и есть россыпь
	# сросшихся комочков, и вычищенная она станет гладкой клеёнкой. Одиночек
	# здесь убавляет сама короткость пандуса.
	var gp2: PackedColorArray = _palette(rec)["green"]
	var sh2: int = int(round(age * 2.0))
	# ДИЗЕРИНГА ЗДЕСЬ НЕТ ВОВСЕ. С этого столбца снимается карта нормалей —
	# высота берётся из яркости, — и клетчатый порог превратил бы ровный склон в
	# частокол игл. Чистка одиночек, наоборот, включена: без неё образец читался
	# рябью (склейка 0.36 при норме 0.55).
	_finish(img, ox, oy, lv, _slice(gp2, 2 - sh2, 8 - sh2), 0.0, 1, 0, true)


# --- КОРА: волокно вдоль стебля ---------------------------------------------
#
# СЕРАЯ НАРОЧНО: цвет коры приходит с вершин, из каталога. Оттого у неё одной
# СДВИГА ТОНА НЕТ И БЫТЬ НЕ МОЖЕТ — увести оттенок значило бы подкрасить все
# лианы разом. Пиксельарт держится тут на ступенях и на размахе, а не на тоне.
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
	var lv := _field()
	for y in range(TILE):
		for x in range(TILE):
			var along: float = (_hash01(x * 9173 + y * 311 + s * 77) - 0.5) * 0.5
			# Прежде тон считался вокруг 0.86 и почти не расходился: размах вышел
			# 0.20 при 0.38 у руки. Ступень берём от середины пандуса и даём
			# волокну полный ход.
			lv[y * TILE + x] = clampf(0.62 + (soft[x] + along) * rough * 1.9,
				0.0, 1.0)
	# Волокно идёт СТОЛБЦАМИ, и клетчатый порог рвал бы их поперёк. Поэтому у
	# коры дизеринга нет вовсе, а одиночки чистятся: волокно — это полосы.
	_finish(img, ox, oy, lv, _palette(rec)["bark"], 0.0, 1, 0, true)


# --- ЛИСТ ЛИАНЫ: три формы, ступенчатая окраска -------------------------------
#
# НАПРАВЛЕНИЕ СМЕНЕНО по референсам с Пинтереста («pixel art leaf», решение
# пользователя 31.08.2026). Взяты ПРИЁМЫ, а не картинки: разные силуэты — сердце
# плюща с острым носом, пятипалый виноградный, вытянутый ивовый.
#
# ФОРМА СЧИТАЕТСЯ В ПОЛЕ ДОЛЕЙ, а не сразу цветом: сперва каждой точке
# назначается доля от тени к свету, потом поле разом обводится по краю,
# укладывается ступенями пандуса и чистится от одиночек. Оттого у листа выходит
# горстка цветов вместо ста двадцати, и они складываются в пятна.
#
# ПРАВИЛА АРТА (решения пользователя 31.08.2026):
#   1. Лист примыкает к черешку ТОЧКОЙ А — низом середины клетки.
#   2. От точки А всегда начинается жилкование: жилки всех трёх форм строятся
#      лучами из неё, а не из середины пластины.
func _leaf(img: Image, ox: int, oy: int, s: int, kind: int,
		rng: RandomNumberGenerator, rec: Dictionary) -> void:
	var age: float = float(s) / float(STAGES - 1)
	var shape: String = str(rec.get("shape", "grape"))
	var wob_a: float = rng.randf_range(0.0, TAU)
	var wob_b: float = rng.randf_range(0.0, TAU)

	var lv := _field()
	match shape:
		"ivy":
			_leaf_ivy(lv, age, kind, wob_a, wob_b, rec)
		"willow":
			_leaf_willow(lv, age, kind, wob_a, rec)
		_:
			_leaf_grape(lv, age, kind, wob_a, wob_b, rec)
	# Каёмка была у листа и прежде: без неё два листа внахлёст сливаются в одно
	# зелёное пятно. Наводится она теперь ВНУТРИ `_finish`, после чистки, и
	# меряется ступенями пандуса.

	var base := Color(0.31, 0.44, 0.20).lerp(Color(0.26, 0.37, 0.17), age)
	var gp3: PackedColorArray = _palette(rec)["green"]
	var sh3: int = int(round(age * 2.0))
	_finish(img, ox, oy, lv, _slice(gp3, 2 - sh3, 8 - sh3), 0.26, 1, 2)


# Виноградный: пять лопастей, вырез у черешка, зубчатый край.
func _leaf_grape(lv: PackedFloat32Array, age: float, kind: int,
		wob_a: float, wob_b: float, rec: Dictionary) -> void:
	# РАЗНОВИДНОСТИ РАСХОДЯТСЯ ЧИСЛОМ ЛОПАСТЕЙ, а не глубиной выреза. Глубина
	# видна только вблизи, и сторож это поймал: попарная схожесть силуэтов была
	# 0.86 при норме 0.80. Три, пять и семь лопастей ни с чем не спутать.
	var lobes: float = [5.0, 3.0, 7.0][kind]
	# У трёхлопастного нос вытянут: без него он читался холмом, а не листом.
	var nose_k: float = [0.0, 0.26, 0.0][kind]
	var cut_k: float = [0.9, 1.15, 0.75][kind] * rec["cut"]
	var wide_k: float = [1.0, 1.24, 0.78][kind]
	var tall_k: float = [1.0, 1.02, 1.28][kind]
	var stalk_k: float = [1.0, 0.85, 1.15][kind]
	var sinus: float = [0.45, 0.35, 0.55][kind] * stalk_k
	var rad: float = lerpf(9.2, 12.4, age)
	# ВЫРЕЗЫ И ЗУБЦЫ УБАВЛЕНЫ. Глубокий вырез и мелкий зубец пропадают при
	# уменьшении вчетверо (силуэт IoU был 0.65 при норме 0.75): всё, что тоньше
	# двух точек, живёт только в полном размере.
	var cut: float = lerpf(0.10, 0.21, age) * cut_k
	var tooth: float = lerpf(0.02, 0.05, age) * cut_k * rec["edge"]
	var base_x: float = float(TILE) * 0.5
	var base_y: float = float(TILE) - 1.0
	var mid_x: float = base_x
	# ВЕРХА КЛЕТКИ ПЛАСТИНА НЕ КАСАЕТСЯ. Вытянутая разновидность при старшем
	# возрасте упиралась в него, а по краю клетки картинка тянется от соседнего
	# столбца: на силуэте это черта чужого цвета. Высоту потому и ограничиваем
	# произведением, а не каждым числом порознь.
	tall_k = minf(tall_k, 15.2 / maxf(rad, 0.01))
	var mid_y: float = base_y - rad * 0.92 * tall_k

	# Жилки — лучи ИЗ ТОЧКИ А к вершинам лопастей (правило 2).
	var tips: Array = []
	var many: int = int(lobes)
	for k in range(many):
		var a: float = (float(k) - float(many - 1) * 0.5) * TAU / lobes
		tips.append(Vector2(mid_x + rad * wide_k * sin(a),
			mid_y - rad * tall_k * cos(a)))

	for y in range(TILE):
		for x in range(TILE):
			var px: float = float(x) + 0.5
			var py: float = float(y) + 0.5
			var dx: float = (px - mid_x) / wide_k
			var dy: float = (py - mid_y) / tall_k
			var far: float = sqrt(dx * dx + dy * dy)
			if far > rad * 1.2:
				continue
			var phi: float = atan2(dx, -dy)
			var edge: float = rad * (1.0 - cut * (1.0 - cos(lobes * phi)) * 0.5)
			edge *= 1.0 + nose_k * pow(maxf(0.0, cos(phi)), 3.0)
			var down: float = PI - absf(phi)
			edge *= 1.0 - sinus * exp(-(down / 0.55) * (down / 0.55))
			edge *= 1.0 + tooth * sin(lobes * 3.0 * phi + wob_a) \
				+ 0.06 * sin(3.0 * phi + wob_b)
			if far > edge:
				continue
			var up: float = clampf((base_y - py) / maxf(rad * 1.4, 1.0), 0.0, 1.0)
			var level: float = 0.10 + 0.60 * clampf(up * 1.55, 0.0, 1.0)
			if far > edge * 0.55:
				level += 0.28 * (far / edge - 0.55) / 0.45 \
					+ 0.12 * (-dx / maxf(edge, 0.001))
			# ОДИН СВЕТ НА ВЕСЬ ЛИСТ. Прежде боковую подсветку имел только
			# лепесток, а лист светился ровно от середины к краю — на кадре лист
			# и цветок одной лозы оказывались освещены по-разному. Свет идёт
			# сверху-слева у всех.
			level += _vein(Vector2(px, py), Vector2(base_x, base_y), tips,
				far / maxf(edge, 0.001))
			lv[y * TILE + x] = clampf(level, 0.0, 1.0)


# Плющ: сердце-щит с острым носом, три лопасти.
func _leaf_ivy(lv: PackedFloat32Array, age: float, kind: int,
		wob_a: float, wob_b: float, rec: Dictionary) -> void:
	var cut_k: float = [1.0, 0.65, 1.4][kind] * rec["cut"]
	var wide_k: float = [1.0, 1.12, 0.9][kind]
	var nose: float = [0.34, 0.26, 0.42][kind]
	var rad: float = lerpf(8.8, 12.0, age)
	var cut: float = lerpf(0.08, 0.20, age) * cut_k
	var tooth: float = lerpf(0.015, 0.04, age) * rec["edge"]
	var base_x: float = float(TILE) * 0.5
	var base_y: float = float(TILE) - 1.0
	var mid_x: float = base_x
	var mid_y: float = base_y - rad * 0.98

	var tips: Array = []
	for k in range(3):
		var a: float = float(k - 1) * 1.15
		tips.append(Vector2(mid_x + rad * wide_k * sin(a) * 0.9,
			mid_y - rad * cos(a) * (1.0 + (nose if k == 1 else 0.0))))

	for y in range(TILE):
		for x in range(TILE):
			var px: float = float(x) + 0.5
			var py: float = float(y) + 0.5
			var dx: float = (px - mid_x) / wide_k
			var dy: float = py - mid_y
			var far: float = sqrt(dx * dx + dy * dy)
			if far > rad * 1.45:
				continue
			var phi: float = atan2(dx, -dy)
			var edge: float = rad * (1.0 - cut * (1.0 - cos(3.0 * phi)) * 0.5)
			edge *= 1.0 + nose * pow(maxf(0.0, cos(phi)), 3.0)
			var down: float = PI - absf(phi)
			edge *= 1.0 - 0.5 * exp(-(down / 0.5) * (down / 0.5))
			edge *= 1.0 + tooth * sin(13.0 * phi + wob_a) \
				+ 0.05 * sin(2.0 * phi + wob_b)
			if far > edge:
				continue
			var up: float = clampf((base_y - py) / maxf(rad * 1.4, 1.0), 0.0, 1.0)
			var level: float = 0.10 + 0.60 * clampf(up * 1.55, 0.0, 1.0)
			if far > edge * 0.5:
				level += 0.26 * (far / edge - 0.5) / 0.5 \
					+ 0.12 * (-dx / maxf(edge, 0.001))
			# ОДИН СВЕТ НА ВЕСЬ ЛИСТ. Прежде боковую подсветку имел только
			# лепесток, а лист светился ровно от середины к краю — на кадре лист
			# и цветок одной лозы оказывались освещены по-разному. Свет идёт
			# сверху-слева у всех.
			level += _vein(Vector2(px, py), Vector2(base_x, base_y), tips,
				far / maxf(edge, 0.001))
			lv[y * TILE + x] = clampf(level, 0.0, 1.0)


# Ива: узкая вытянутая пластина остриём вверх, одна жилка по оси, светлый бок
# со стороны света (сверху-слева).
func _leaf_willow(lv: PackedFloat32Array, age: float, kind: int,
		wob_a: float, rec: Dictionary) -> void:
	var wide_k: float = [1.0, 1.25, 0.8][kind]
	var bow: float = [0.0, 1.8, -1.8][kind]
	var long: float = lerpf(19.0, 28.0, age)
	# ШИРЕ, ЧЕМ БЫЛО. При 2.6-4.6 точки пластина на уменьшении вчетверо пропадала
	# начисто (силуэт IoU 0.15): узкое остриё живёт только в полном размере.
	var half: float = lerpf(3.8, 6.2, age) * wide_k * rec["cut"]
	half = minf(half, 7.5)
	var base_x: float = float(TILE) * 0.5
	var base_y: float = float(TILE) - 1.0

	for y in range(TILE):
		for x in range(TILE):
			var px: float = float(x) + 0.5
			var py: float = float(y) + 0.5
			var t: float = (base_y - py) / long
			if t < 0.0 or t > 1.0:
				continue
			var wide_at: float = half * pow(sin(PI * t), 0.75)
			wide_at *= 1.0 + 0.07 * sin(4.0 * t * PI + wob_a)
			# ПРАВИЛО ТОЧКИ А: у основания синус сходит в ноль, и без пятки
			# пластина повисала бы над черешком.
			wide_at = maxf(wide_at, 1.4 * maxf(0.0, 1.0 - t / 0.10))
			var mid: float = base_x + bow * sin(PI * t)
			var dx: float = px - mid
			if absf(dx) > wide_at:
				continue
			var edge: float = absf(dx) / maxf(wide_at, 0.5)
			var level: float = 0.14 + 0.54 * clampf(t * 2.0, 0.0, 1.0)
			if dx < 0.0:
				level += 0.24 * (1.0 - edge)
			# Жилка идёт из точки А по оси — та же жилка из одной точки.
			# На одну ступень, а не в самый верх: жилка светлее пластины, но
			# она не блик.
			if absf(dx) < 0.7 and t < 0.82:
				level += 0.15
			lv[y * TILE + x] = clampf(level, 0.0, 1.0)


# ЖИЛКА — НЕ ЛУЧ. Прямые лучи одинаковой яркости от точки А складываются в
# ЗВЕЗДУ: те же грабли, что у мха («смаз и звёзды из тёмных лучей», README).
# Живая жилка сходит на нет к краю и главная толще боковых, поэтому:
#   * прибавка одна ступень, а не «в самый верх» — жилка светлее пластины, но
#     она не блик;
#   * к краю пластины жилка гаснет (`out` — доля пути от точки А к кромке) и до
#     каймы не доходит вовсе;
#   * первая в списке — главная, ей и толщина, и полная длина.
func _vein(p: Vector2, a: Vector2, tips: Array, out: float) -> float:
	if out > 0.86:
		return 0.0
	var best: float = 0.0
	for i in range(tips.size()):
		var main: bool = i == int(tips.size() / 2)
		var wide: float = 0.95 if main else 0.62
		var reach: float = 0.86 if main else 0.66
		if out > reach:
			continue
		var d: float = _to_line(p, a, tips[i])
		if d >= wide:
			continue
		# Гаснет и поперёк, и вдоль: у кромки от жилки остаётся ничего.
		var fade: float = (1.0 - d / wide) * (1.0 - smoothstep(reach - 0.28,
			reach, out))
		best = maxf(best, fade)
	return 0.17 * best


# --- ЛЕПЕСТОК: узкое донце, круглый свободный край ---------------------------
# --- ЛЕПЕСТОК: узкое донце, круглый свободный край ---------------------------
#
# ВОЗРАСТ РЯДА — ЭТО РАСКРЫТИЕ: сверху тугой зеленоватый бутон, ниже раскрытый
# кремовый лепесток. Пандус потому строится не от возраста, а от раскрытия.
func _bloom(img: Image, ox: int, oy: int, s: int, kind: int,
		rng: RandomNumberGenerator, rec: Dictionary) -> void:
	var age: float = float(s) / float(STAGES - 1)
	# ДВЕ РАЗНОВИДНОСТИ ДОЛЖНЫ РАСХОДИТЬСЯ СИЛУЭТОМ (было IoU 0.90 при норме
	# 0.80): прежде они разнились на пятую часть ширины, и это видно только
	# вблизи. Теперь у второй лепесток заметно уже, длиннее и острее.
	var wide_k: float = [1.0, 0.66][kind] * rec["wide"]
	var tip_k: float = [1.0, 1.75][kind] * rec["sharp"]
	var long_k: float = [1.0, 1.18][kind]
	var open: float = clampf((age - 0.12) / 0.88, 0.0, 1.0)
	open = open * open * (3.0 - 2.0 * open)
	# Длину держим так, чтобы лепесток не доставал до верха клетки: там его
	# край сливался бы с соседним столбцом.
	var long: float = minf(lerpf(14.0, 26.0, open) * long_k, 25.0)
	# ШИРЕ: у прежнего лепестка силуэт при уменьшении терялся (IoU 0.48).
	# ШИРИНУ ВЕРНУЛИ. Погоня за силуэтной меркой раздула лепесток в яйцо: на
	# кадре шесть таких складывались в белый ком, а не в цветок. Мерка тут и
	# должна уступить — лепесток читается не сам по себе, а шестёркой (см.
	# послабление в `tools/pixelcheck.py`).
	var half: float = lerpf(4.0, 7.8, open) * wide_k
	half = minf(half, float(TILE) * 0.45)
	var foot_x: float = float(TILE) * 0.5
	var foot_y: float = float(TILE) - 1.0
	var wob: float = rng.randf_range(0.0, TAU)

	var lv := _field()
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
			# СВЕТ С ОДНОЙ СТОРОНЫ, А НЕ ОТ КРАЯ ВНУТРЬ. Прежде яркость падала к
			# обоим краям разом, и связь яркости с удалением от края вышла 0.70
			# при норме 0.45 — это «подушка» (pillow shading), первый признак
			# посчитанной, а не нарисованной картинки. Свет на листе один и
			# идёт сверху-слева, значит левый край лепестка светлый, правый — в
			# тени, и оба края темнеть не могут.
			var side: float = (px - foot_x) / maxf(wide_at, 0.5)   # −1 слева
			var level: float = 0.40 + 0.34 * up - 0.26 * side
			# Жилка по середине — она же держит лепесток «сложенным» на вид.
			if absf(px - foot_x) < 0.9:
				level = maxf(level, 0.86)
			# Тень только со СВОЕЙ стороны. Затемнять оба края разом — это и есть
			# подушка: яркость начинает следовать за удалением от края, а не за
			# светом.
			if side > 0.55:
				level -= 0.34 * (side - 0.55) / 0.45
			lv[y * TILE + x] = clampf(level, 0.0, 1.0)

	# Чистый белый не берём — на солнце он выжигается в плоское пятно без формы.
	# Цветок ТЕПЛЕЕТ к свету, потому сдвиг тона у него со знаком плюс: у зелени
	# свет уходит в жёлтое от зелёного, у кремового — в жёлто-розовое.
	var base := Color(0.55, 0.60, 0.38).lerp(Color(0.88, 0.86, 0.72), open)
	var bp: PackedColorArray = _palette(rec)["bloom"]
	var lo: int = int(round((1.0 - open) * 2.0))
	_finish(img, ox, oy, lv, _slice(bp, lo, lo + 5), 0.10, 2, 0)


# --- ТЕЛО ЛИАМОХА: светлые волоски по тёмному основанию ----------------------
#
# ВЫСОТА У ЭТОГО СТОЛБЦА БЕРЁТСЯ ИЗ ЯРКОСТИ (так устроена игра), значит светлое
# обязано быть выше тёмного. Волосок и есть светлая черта по тёмному основанию,
# и ступени пандуса этого не ломают: номер ступени растёт вместе с высотой.
func _lia_body(img: Image, ox: int, oy: int, s: int, rng: RandomNumberGenerator,
		rec: Dictionary) -> void:
	var age: float = float(s) / float(STAGES - 1)
	var lv := _field()
	for y in range(TILE):
		for x in range(TILE):
			# ОСНОВАНИЕ ПЯТНАМИ. Крупинка на точку читалась снегом, а линейный
			# хеш вдобавок рисовал диагональную рябь; ровная же заливка сделала
			# образец плоским на 0.82 при верхней границе живого пиксельарта
			# 0.66. Две волны пятен — покрупнее и помельче — дают острова
			# соседних тонов: это и есть фактура.
			var patch: float = _blobs(x, y, 8, s * 13 + 1) * 0.55 \
				+ _blobs(x, y, 16, s * 13 + 7) * 0.45
			lv[y * TILE + x] = clampf(0.10 + patch * 0.40, 0.0, 1.0)
	# ВОЛОСКОВ ВДВОЕ МЕНЬШЕ, ЗАТО КАЖДЫЙ ВИДЕН. Сотня волосков в одну точку
	# толщиной — это не мех, а шум: у референсов пятно среднее 5.4 точки, у нас
	# было 1.0. Пиксельарт рисует пучки, а не ворсинки поштучно.
	var many: int = maxi(3, int(round(lerpf(float(LIA_HAIR_YOUNG),
		float(LIA_HAIR_OLD), age) * rec["many"] * 0.45)))
	var long: float = float(TILE) * lerpf(LIA_HAIR_SHORT, LIA_HAIR_LONG, age) \
		* rec["long"] * 0.75
	# ПУЧКАМИ, А НЕ ВРАЗБРОС. Волоски, рассыпанные по клетке поодиночке, дают
	# ровную рябь — «телевизионный снег»: у референсов пятно среднее 5.4 точки,
	# у нас выходило 1.0. Пух растёт кустиками, и рисовать его надо кустиками:
	# несколько волосков из общего корня, и уже корни вразброс.
	var nests: int = maxi(2, int(round(float(many) / 7.0)))
	var nx0 := PackedFloat32Array()
	var ny0 := PackedFloat32Array()
	var nang := PackedFloat32Array()
	for i in range(nests):
		nx0.append(rng.randf_range(0.0, float(TILE)))
		ny0.append(rng.randf_range(0.0, float(TILE)))
		nang.append(rng.randf_range(0.0, TAU))
	for i in range(many):
		var nest: int = i % nests
		var x0: float = nx0[nest] + rng.randf_range(-1.6, 1.6)
		var y0: float = ny0[nest] + rng.randf_range(-1.6, 1.6)
		var ang: float = nang[nest] + rng.randf_range(-0.7, 0.7)
		var bend: float = rng.randf_range(-0.6, 0.6)
		# КОРОЧЕ И ГУЩЕ. Длинный волосок вьётся по клетке червяком, и образец
		# читается лишайником, а не пухом: пушистое делают короткие волоски,
		# сидящие кучно.
		var reach: float = long * rng.randf_range(0.45, 0.95)
		var tip: float = rng.randf_range(0.22, 0.5)
		var steps: int = maxi(2, int(ceil(reach * 2.0)))
		for j in range(steps):
			var t: float = float(j) / float(steps - 1)
			var a: float = ang + bend * t
			var px: int = int(round(x0 + cos(a) * reach * t))
			var py: int = int(round(y0 + sin(a) * reach * t))
			# Заворот по клетке: образец повторяется, и волосок, вышедший за
			# край, обязан войти с другой стороны.
			var hot: float = clampf(0.44 + tip * (0.35 + 0.65 * t) * 2.4, 0.0, 1.0)
			# Волосок не тоньше двух точек — иначе он пропадает при первом же
			# уменьшении. Вторую точку кладём ПОПЕРЁК волоска: прежде она всегда
			# ложилась снизу, и у стоячего волоска попадала на его же следующий
			# шаг — то есть больше половины пуха так и оставалась в одну точку.
			var side_x: int = 1 if absf(sin(a)) > absf(cos(a)) else 0
			var side_y: int = 0 if side_x == 1 else 1
			lv[posmod(py, TILE) * TILE + posmod(px, TILE)] = maxf(
				lv[posmod(py, TILE) * TILE + posmod(px, TILE)], hot)
			var q2: int = posmod(py + side_y, TILE) * TILE + posmod(px + side_x, TILE)
			lv[q2] = maxf(lv[q2], hot - 0.14)
	# Волоскам чистка одиночек противопоказана: волосок в одну точку толщиной —
	# это и есть рисунок, а не сор.
	var gp4: PackedColorArray = _palette(rec)["green"]
	var sh4: int = int(round(age * 1.0))
	# Дизеринга нет по той же причине, что у тела мха: отсюда берётся рельеф.
	_finish(img, ox, oy, lv, _slice(gp4, 4 - sh4, 10 - sh4), 0.0, 0, 0, true)


# --- ВОРСИНКА ЛИАМОХА: пучок телом, зубцы силуэтом -------------------------
#
# ПЕРЕДЕЛАНО 31.08.2026 по разведке приёмов пиксельарта. Прежде пучок рисовался
# ОТДЕЛЬНЫМИ ВОЛОСКАМИ в одну-две точки толщиной, и сторож показал, чего это
# стоит: силуэт при уменьшении вчетверо сохранялся на 0.15 (норма 0.75), а
# морфологическое открытие съедало 65% площади — то есть почти всё нарисованное
# тоньше двух точек и в игре пропадёт первым.
#
# Пиксельарт решает это иначе: рисуют не волоски, а ПУЧОК — сплошное тело с
# зубчатым верхом. Отдельные волоски остаются только сверху, поштучно, и каждый
# не тоньше двух точек. Ровно тот же урок, что уже записан в README про мох:
# «чего решётка не держит, нельзя подменить узором».
#
# ПОЛУПРОЗРАЧНЫХ ТОЧЕК ЗДЕСЬ БЫТЬ НЕ ДОЛЖНО (замер: их было 28%). Мягкость
# кончика делают ступенью тона, а не прозрачностью: полупрозрачная точка на
# просвет тянет за собой чужой фон.
func _lia_fuzz(img: Image, ox: int, oy: int, s: int, rng: RandomNumberGenerator,
		rec: Dictionary) -> void:
	var age: float = float(s) / float(STAGES - 1)
	var lv := _field()
	var tall: float = float(TILE) * lerpf(0.45, 0.85, age) * rec["long"]
	tall = minf(tall, float(TILE) * 0.92)
	var half: float = lerpf(5.0, 9.5, age) * clampf(rec["many"], 0.5, 1.6)
	half = minf(half, float(TILE) * 0.44)
	var mid: float = float(TILE) * 0.5
	# Сколько зубцов у верхнего края. Их считаем ЗУБЦАМИ СИЛУЭТА, а не
	# волосками: каждый шире двух точек и сидит на теле пучка.
	var teeth: int = maxi(3, int(round(lerpf(3.0, 6.0, age) * rec["many"])))
	var phase := PackedFloat32Array()
	var lift := PackedFloat32Array()
	for i in range(teeth):
		phase.append(rng.randf_range(-0.35, 0.35))
		lift.append(rng.randf_range(0.55, 1.0))

	for x in range(TILE):
		var dx: float = (float(x) - mid) / half
		if absf(dx) >= 1.0:
			continue
		# Тело пучка: купол, сужающийся кверху. Зубцы наращивают его выборочно.
		var dome: float = pow(maxf(0.0, 1.0 - dx * dx), 0.62)
		var t: float = (float(x) - mid) / half * 0.5 + 0.5     # 0..1 поперёк
		var tooth: float = 0.0
		for i in range(teeth):
			var at: float = (float(i) + 0.5) / float(teeth) + phase[i] / float(teeth)
			var d: float = absf(t - at) * float(teeth)
			if d < 1.0:
				tooth = maxf(tooth, lift[i] * (1.0 - d * d))
		var top_y: int = TILE - 1 - int(round(tall * dome * (0.62 + 0.38 * tooth)))
		top_y = clampi(top_y, 1, TILE - 1)
		for y in range(top_y, TILE):
			var up: float = float(TILE - 1 - y) / maxf(tall, 1.0)
			# Светлее кверху: у ворса кончики ловят свет, основание в тени.
			var level: float = 0.14 + 0.74 * clampf(up * 1.25, 0.0, 1.0)
			# Волокно вдоль: чередование через столбец делает ворс, а сплошная
			# заливка — лопату.
			if x % 3 == int(up * 2.0) % 3:
				level -= 0.10
			lv[y * TILE + x] = clampf(level, 0.0, 1.0)
	# Краёв клетки пучок не касается: по краю дощечки картинка тянется от
	# соседнего столбца и рисует по силуэту чужой цвет.
	for y in range(TILE):
		lv[y * TILE] = -1.0
		lv[y * TILE + TILE - 1] = -1.0
	for x in range(TILE):
		lv[x] = -1.0
	_finish(img, ox, oy, lv, _slice(_palette(rec)["green"], 3, 9), 0.10, 2, 1)
