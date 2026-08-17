extends Node3D
# =============================================================================
#  РАСТЕНИЯ НА ПОВЕРХНОСТИ.
#
#  Растение живёт В ТОЧКЕ, а не в клетке. У него есть место, наклон земли под
#  ним и зрелость; всё остальное — следствие. Разрастается оно пятном: даёт
#  отросток на случайной стороне от себя, и тот садится на землю там, где она
#  в этот миг проходит.
#
#  Прежде растения жили на кусочках ГРАНЕЙ ячеек, разложенных по кольцам и
#  столбцам. Граней у поверхности больше нет — она идёт по уровню заполнения
#  сквозь ячейки, — и вся та раскладка снята. Заодно ушло главное её свойство:
#  заросли ложились по клеткам мира, а не по рельефу.
#
#  К ЯЧЕЙКЕ растение всё же приписано — к той, что под ним. Не ради места, а
#  чтобы знать, кого проверять, когда игрок изменил землю, и на какой меш
#  собирать: перебирать все заросли на каждый мазок было бы разорительно.
# =============================================================================

const PlantsData = preload("res://Plants.gd")

const TICK: float = 0.15
# Ступеней роста, на которых меш пересобирается.
#
# Прежде их было девять — по числу возрастов картинки, — и кочка росла заметными
# толчками: раз в полторы секунды подскакивала в размере и разом меняла возраст.
# Ступень — это ПОТОЛОК плавности: что бы ни считалось непрерывно, на глаз оно
# всё равно шагает с этой частотой. Замерено: втрое чаще стоит 4.6 → 7.4 с счёта
# на 45 секунд роста четырёхсот кочек, то есть около шестой доли ядра. За это
# берём плавность.
const STEPS: int = 24

# СКОЛЬКО ДЛИТСЯ КАЖДАЯ СТУПЕНЬ, в долях «Т» — времени одной ранней ступени.
#
# Молодая куртинка набирает вид быстро, а взрослая дозревает долго: первые пять
# ступеней идут ровно по Т, дальше вдвое, втрое, вчетверо и впятеро дольше.
# Смысл не в самом возрасте, а в том, что зрелость — это ПОРА РАЗМНОЖЕНИЯ:
# отростки мох даёт с третьей ступени, и чем дольше он стоит взрослым, тем
# дальше успевает расползтись. Прежде рост был ровным, и кочка добегала до
# последней ступени раньше, чем занимала место вокруг себя.
#
# Таблица пока общая на всех: у лианы своих чисел нет. Понадобятся — переедет
# в каталог отдельным полем карточки.
const STAGE_COST := [1.0, 1.0, 1.0, 1.0, 1.0, 2.0, 3.0, 4.0, 5.0]

# Насколько далеко от себя растение даёт отросток, в долях шага решётки.
const SPREAD_NEAR: float = 0.13
const SPREAD_FAR: float = 0.34
# Ближе этого друг к другу не садимся: иначе пятно сгущается в одну точку и
# кочки лезут одна из другой. Подушки должны СМЫКАТЬСЯ краями, поэтому зазор
# чуть меньше их поперечника.
const CROWD: float = 0.15

var main: Node3D
var patches: Dictionary = {}      # номер -> {pos, nrm, id, m, step, cell, salt}
var by_cell: Dictionary = {}      # ячейка -> {номер: true}
var cell_nodes: Dictionary = {}   # ячейка -> меш со всеми её растениями
var time_scale: float = 1.0
var _dirty: Dictionary = {}
var _accum: float = 0.0
var _next: int = 1
var _rng := RandomNumberGenerator.new()
var _blade_mat: ShaderMaterial
# Всё, что у кочки ОДИНАКОВО ВСЕГДА: срез по кольцам, утопление обода, разрез
# картинки по кольцам и по секторам. Считается один раз при запуске. Внутри
# перестройки это были бы `pow` и `sin` на каждую вершину — сотня на кочку,
# сотни кочек, двадцать четыре перестройки за жизнь каждой.
var _ring_prof := PackedFloat32Array()
var _ring_sink := PackedFloat32Array()
var _ring_v := PackedFloat32Array()
var _sector_u := PackedFloat32Array()
# Сплошной прямоугольник каждой клетки листа, в долях всей картинки. Ищется по
# самой картинке при запуске — см. `_scan_solid`.
var _solid_uv: Array = []
var _solid_holes: int = 0
var _solid_least: int = 0         # самая тесная клетка, в точках


func setup(main_ref: Node3D) -> void:
	main = main_ref
	_rng.seed = 20260811
	# Материал пучков — СВОЙ шейдер, не встроенный. Встроенный переворачивал
	# нормаль у изнанки дощечки, и половина квадратов в пучке чернела; и свет
	# у него ложится жёстко, с резкой границей тени. Подробности в `Blades.gdshader`.
	#
	# Прозрачность — ОТСЕЧЕНИЕМ, а не смешиванием: у смешивания порядок
	# отрисовки решается по расстоянию до всего меша целиком, и сотни
	# перекрывающихся пучков начинают мигать друг сквозь друга.
	_blade_mat = ShaderMaterial.new()
	_blade_mat.shader = load("res://Blades.gdshader")
	var sheet: Texture2D = _blade_texture()
	_blade_mat.set_shader_parameter("blades", sheet)
	_scan_solid(sheet)

	var rings: int = RING_AT.size()
	_ring_prof.resize(rings)
	_ring_sink.resize(rings)
	_ring_v.resize(rings)
	for r in range(rings):
		var t: float = float(RING_AT[r])
		_ring_prof[r] = _profile(t)
		_ring_sink[r] = RIM_SINK * t * t
		_ring_v[r] = lerpf(BODY_V_TOP, BODY_V_RIM, t)
	_sector_u.resize(SECTORS)
	for s in range(SECTORS):
		# Разрез ведём по кругу волной: иначе на всех семи секторах ложится одна
		# и та же полоса рисунка. Волна замкнутая — на стыке шва нет.
		_sector_u[s] = 0.12 + 0.76 * absf(sin(TAU * float(s) / float(SECTORS)))


# СПЛОШНОЙ ПРЯМОУГОЛЬНИК КАЖДОЙ КЛЕТКИ — ищем ПО САМОЙ КАРТИНКЕ, один раз при
# запуске. Тело кочки — цельная оболочка, и брать ей рисунок можно только оттуда,
# где он закрашен насквозь: любая прозрачная точка станет дырой навылет, потому
# что движок режет по порогу, а не смешивает.
#
# Знать наперёд, где у клетки закрашено, нельзя: лист рисует пользователь, и
# высота куртинки в клетке у каждого возраста своя. Поэтому не угадываем, а
# СМОТРИМ: идём от корней вверх, пока в строке есть сплошной кусок не уже
# `DENSE_ROW` ширины клетки, и пересекаем эти куски между собой. Пересечение
# сплошных отрезков сплошное по построению — дыр внутри не будет.
func _scan_solid(sheet: Texture2D) -> void:
	_solid_uv.resize(STAGES * COLS)
	_solid_holes = 0
	_solid_least = 1 << 30
	var img: Image = sheet.get_image() if sheet != null else null
	if img == null:
		for i in range(STAGES * COLS):
			_solid_uv[i] = Rect2(0.4, 0.4, 0.2, 0.2)
		_solid_least = 0
		return
	if img.is_compressed():
		img.decompress()
	var w: int = img.get_width()
	var h: int = img.get_height()
	var cw: int = maxi(1, w / COLS)
	var ch: int = maxi(1, h / STAGES)
	for s in range(STAGES):
		for kd in range(COLS):
			var box: Rect2i = _dense_box(img, kd * cw, s * ch, cw, ch)
			# Тесноту считаем ТОЛЬКО по столбцу тела: у клеток с фигурками
			# сплошного места мало по природе, и его там никто не ищет.
			if kd == BODY_COL:
				_solid_least = mini(_solid_least, box.size.x * box.size.y)
			_solid_uv[s * COLS + kd] = Rect2(
				float(box.position.x) / float(w), float(box.position.y) / float(h),
				float(box.size.x) / float(w), float(box.size.y) / float(h))
			# Сторож: внутри найденного прямоугольника прозрачных точек быть не
			# может. Если появились — разметка врёт, и центр опять просветится.
			for y in range(box.position.y, box.position.y + box.size.y):
				for x in range(box.position.x, box.position.x + box.size.x):
					if img.get_pixel(x, y).a < 0.5:
						_solid_holes += 1


func _dense_box(img: Image, ox: int, oy: int, cw: int, ch: int) -> Rect2i:
	var lo := -1
	var hi := -1
	var top: int = oy + ch
	for y in range(oy + ch - 1, oy - 1, -1):
		# Самый длинный СПЛОШНОЙ кусок строки. Именно сплошной, а не «от первой
		# закрашенной до последней»: между двумя холмиками бывает просвет, и по
		# краям он бы попал внутрь прямоугольника.
		var run := 0
		var best := 0
		var best_end := -1
		for x in range(ox, ox + cw):
			if img.get_pixel(x, y).a >= 0.5:
				run += 1
				if run > best:
					best = run
					best_end = x
			else:
				run = 0
		if best_end < 0 or float(best) < DENSE_ROW * float(cw):
			break
		var x0: int = best_end - best + 1
		var nl: int = x0 if lo < 0 else maxi(lo, x0)
		var nh: int = best_end if hi < 0 else mini(hi, best_end)
		if nh - nl + 1 < 2:
			break
		lo = nl
		hi = nh
		top = y
	if lo < 0:
		# Ни одной плотной строки — клетка пустая или нарисована совсем иначе.
		# Берём точку у корней: пусть тело будет одноцветным, но не дырявым.
		return Rect2i(ox + cw / 2, oy + ch - 2, 1, 1)
	return Rect2i(lo, top, hi - lo + 1, oy + ch - top)


# Сколько просвечивающих точек попало в разметку тела (норма — ноль) и насколько
# тесной вышла самая скупая клетка. Числом меряется то, что иначе видно только на
# кадре: дыра в центре молодой кочки и одноцветное тело.
func see_through() -> Vector2i:
	return Vector2i(_solid_holes, _solid_least)


# ЛИСТ С КУРТИНКАМИ МХА — рисуем прямо в коде, без файла с картинкой.
#
# МОХ — НЕ ПУЧОК ТРАВИНОК, а плотная бархатная подушка из очень коротких
# ворсинок: на снимках отдельной былинки не разглядеть ни с какого расстояния,
# видно сросшиеся округлые холмики с мохнатым краем. Поэтому каждая клетка
# листа — не букет стеблей, а купол: тело подушки с вертикальной рябью внутри
# и короткой щетиной по макушке.
#
# Разложен лист ДВУМЯ ОСЯМИ. По вертикали — возраст: девять ступеней от плоской
# лепёшки до пухлой подушки. По горизонтали — разновидности одного возраста:
# без них поворот одной картинки вокруг оси сразу читается как повторение,
# кочка к кочке.
#
# Возраст меняет не только рост, но и ворс: у молодой куртинки край почти
# гладкий, у старой мохнатый, и местами проступает ржавчина. Одним масштабом
# такого не изобразить — у растянутой вчетверо картинки и ворс стал бы бревном.
const TILE: int = 32               # сторона одной клетки в точках
const STAGES: int = 9              # столько возрастов
const KINDS: int = 4               # столько разновидностей ворсинки у возраста
# ПЯТЫЙ СТОЛБЕЦ — ОБРАЗЕЦ ДЛЯ ТЕЛА, и он устроен иначе всех прочих.
#
# Клетки разновидностей — это ВЫРЕЗАННЫЕ ФИГУРКИ: куртинка в профиль, вокруг
# прозрачный фон. Ими обтягивают плоскую дощечку, и это верно. Тело же —
# замкнутая оболочка, его надо ОБИВАТЬ, как мебель обивают тканью, а вырезанной
# фигуркой не обобьёшь: у неё нет ни однородности, ни повторяемости, и она
# наполовину прозрачна. Оттого у молодых кочек и просвечивал центр.
#
# В пятом столбце лежит не фигурка, а КУСОК МХОВОЙ ПОВЕРХНОСТИ вплотную сверху:
# заполнено от края до края, прозрачного фона нет вовсе, свой на каждый возраст.
const BODY_COL: int = KINDS
const COLS: int = KINDS + 1        # всего столбцов на листе

# НАРИСОВАННЫЙ ЛИСТ ГЛАВНЕЕ СЧИТАННОГО. Если в `art/moss.png` лежит картинка,
# берём её; иначе рисуем сами. Так рисунок от руки подменяет заглушку без
# единой правки в коде — и без риска потерять заглушку, если файла нет.
#
# Разметка листа: `COLS` клеток в ряду — четыре разновидности ворсинки и пятая,
# образец для тела, — `STAGES` рядов (возрасты, сверху молодой), клетка
# `TILE`×`TILE`.
#
# ЛИСТ ПРЕЖНЕЙ ШИРИНЫ ТОЖЕ ГОДИТСЯ. Пятый столбец появился позже, чем был
# нарисован лист, и заставлять переделывать готовую работу неправильно: если в
# файле только четыре столбца, столбец тела дорисовывается кодом на лету. Как
# только он будет нарисован, лист станет шире, и дорисовка сама отключится.
const ART_PATH := "res://art/moss.png"

func _blade_texture() -> Texture2D:
	if ResourceLoader.exists(ART_PATH):
		var drawn = load(ART_PATH)
		if drawn is Texture2D:
			var want := Vector2i(TILE * COLS, TILE * STAGES)
			var got: Vector2i = Vector2i(drawn.get_size())
			if got == want:
				return drawn
			if got == Vector2i(TILE * KINDS, TILE * STAGES):
				return _widen_sheet(drawn)
			push_warning("art/moss.png ожидается %d×%d (или %d×%d без столбца тела), а он %s"
				% [want.x, want.y, TILE * KINDS, TILE * STAGES, str(got)])
			return drawn
	return _make_blade_texture()


# Пририсовываем к нарисованному листу столбец тела. Саму работу пользователя не
# трогаем — она переносится точка в точку.
func _widen_sheet(drawn: Texture2D) -> ImageTexture:
	var src: Image = drawn.get_image()
	if src.is_compressed():
		src.decompress()
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	var img := Image.create(TILE * COLS, TILE * STAGES, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.blit_rect(src, Rect2i(0, 0, src.get_width(), src.get_height()), Vector2i.ZERO)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5501
	for s in range(STAGES):
		_paint_body_cell(img, BODY_COL * TILE, s * TILE, s, rng)
	return ImageTexture.create_from_image(img)


# ОБРАЗЕЦ ДЛЯ ТЕЛА — заглушка, пока он не нарисован.
#
# Это не куртинка в профиль, а мховая поверхность вплотную СВЕРХУ: сросшиеся
# округлые холмики, светлые на макушках и тёмные в стыках, поверх — та же
# вертикальная рябь, что делает бархат. Заполнено насквозь, без единой
# прозрачной точки: тело — цельная оболочка, и любая дырка в образце стала бы
# дыркой в кочке.
#
# Расстояние до холмика считаем ПО КРУГУ, с заворотом через край клетки: тогда
# образец стыкуется сам с собой, и у него нет заметного края.
func _paint_body_cell(img: Image, ox: int, oy: int, s: int, rng: RandomNumberGenerator) -> void:
	var age: float = float(s) / float(STAGES - 1)
	var deep := Color(0.20, 0.31, 0.17).lerp(Color(0.17, 0.26, 0.15), age)
	var body := Color(0.33, 0.47, 0.22).lerp(Color(0.29, 0.42, 0.19), age)
	var lit := Color(0.47, 0.60, 0.29).lerp(Color(0.44, 0.55, 0.26), age)
	var rust := Color(0.36, 0.31, 0.17)
	# С возрастом холмиков больше, и они мельче: подушка не разрастается вширь,
	# а густеет.
	var humps: int = 4 + int(round(3.0 * age))
	var hx := PackedFloat32Array()
	var hy := PackedFloat32Array()
	var hr := PackedFloat32Array()
	hx.resize(humps)
	hy.resize(humps)
	hr.resize(humps)
	for i in range(humps):
		hx[i] = rng.randf_range(0.0, float(TILE))
		hy[i] = rng.randf_range(0.0, float(TILE))
		hr[i] = lerpf(11.0, 7.0, age) * rng.randf_range(0.75, 1.25)
	for y in range(TILE):
		for x in range(TILE):
			var near: float = 1000.0
			for i in range(humps):
				var dx: float = absf(float(x) + 0.5 - hx[i])
				dx = minf(dx, float(TILE) - dx)
				var dy: float = absf(float(y) + 0.5 - hy[i])
				dy = minf(dy, float(TILE) - dy)
				near = minf(near, sqrt(dx * dx + dy * dy) / hr[i])
			var col: Color
			if near < 0.55:
				col = lit.lerp(body, near / 0.55)
			else:
				col = body.lerp(deep, clampf((near - 0.55) / 0.75, 0.0, 1.0))
			if (x + int(near * 5.0)) % 3 == 0:
				col = col.darkened(0.07)
			elif x % 5 == 0:
				col = col.lightened(0.05)
			if age > 0.55 and rng.randf() < 0.010:
				col = col.lerp(rust, 0.55)
			img.set_pixel(ox + x, oy + y, Color(col.r, col.g, col.b, 1.0))


func _make_blade_texture() -> ImageTexture:
	var img := Image.create(TILE * COLS, TILE * STAGES, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 913377
	for s in range(STAGES):
		_paint_body_cell(img, BODY_COL * TILE, s * TILE, s, rng)

	for s in range(STAGES):
		var age: float = float(s) / float(STAGES - 1)
		# Молодая куртинка — низкая лепёшка, взрослая — пухлая подушка. Ворс с
		# возрастом длиннее, а край мохнатее.
		var high: float = lerpf(0.16, 0.62, age) * float(TILE)
		var half: float = lerpf(0.22, 0.46, age) * float(TILE)
		var fuzz: int = int(round(lerpf(1.0, 4.0, age)))
		# Палитра тесная и ПРИГЛУШЁННАЯ. Ядовитая салатовая зелень сразу выдаёт
		# компьютерную картинку; на рисованных задниках зелень плотная, чуть
		# сизая в тени и тёплая на свету, а разница между ними невелика.
		# Резкий перепад к тому же превращает бархат в щётку из палок.
		var deep := Color(0.20, 0.31, 0.17).lerp(Color(0.17, 0.26, 0.15), age)
		var body := Color(0.33, 0.47, 0.22).lerp(Color(0.29, 0.42, 0.19), age)
		var lit := Color(0.47, 0.60, 0.29).lerp(Color(0.44, 0.55, 0.26), age)
		var rust := Color(0.36, 0.31, 0.17)      # ржавчина у старых куртин

		for k in range(KINDS):
			var ox := k * TILE
			var oy := s * TILE
			var mid_x: float = float(TILE) * 0.5 + rng.randf_range(-2.0, 2.0)
			# Верхний край подушки — эллипс, сбитый мелкой волной: у живого мха
			# он бугристый, из сросшихся холмиков, а не гладкая дуга.
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
				# Тело подушки: снизу глубже и темнее, к макушке светлее.
				for y in range(top, TILE):
					var up: float = float(TILE - 1 - y) / maxf(high, 1.0)
					var col: Color = deep.lerp(body, clampf(up * 1.6, 0.0, 1.0))
					if up > 0.55:
						col = col.lerp(lit, (up - 0.55) / 0.45)
					# Ворсинки: тонкая вертикальная рябь через столбец. Именно
					# она и делает бархат — сплошная заливка выглядит краской.
					if (x + int(up * 7.0)) % 3 == 0:
						col = col.darkened(0.10)
					elif x % 5 == 0:
						col = col.lightened(0.08)
					if age > 0.6 and rng.randf() < 0.012:
						col = col.lerp(rust, 0.5)
					img.set_pixel(ox + x, oy + y, Color(col.r, col.g, col.b, 1.0))
				# Мохнатый край: короткие ворсинки поверх макушки, редеющие
				# кверху. Без них подушка обрезана ножницами.
				for f in range(fuzz):
					if rng.randf() > 0.55 - 0.10 * float(f):
						continue
					var y2: int = top - 1 - f
					if y2 < 0:
						continue
					img.set_pixel(ox + x, oy + y2,
						Color(lit.r, lit.g, lit.b, 1.0))
	return ImageTexture.create_from_image(img)


func _process(delta: float) -> void:
	if patches.is_empty() or time_scale <= 0.0:
		return
	_accum += delta * time_scale
	while _accum >= TICK:
		_accum -= TICK
		_tick(TICK)


# =============================================================================
#  Посадка и снятие
# =============================================================================
# Сажаем в точку. Наклон берём у земли, а не у луча: под курсором может
# оказаться кромка, и нормаль попадания там скачет.
func plant_at(pos: Vector3, id: String) -> int:
	if not PlantsData.is_plant(id):
		return -1
	var spot: Dictionary = main.grid.surface_near(pos)
	if spot.is_empty():
		return -1
	if not _fits_surface(spot["nrm"], PlantsData.ITEMS[id]):
		return -1
	if _crowded(spot["pos"], CROWD * main.CELL_SPACING):
		return -1
	return _create(spot, id, 0.15)


func remove_at(pid: int) -> void:
	if not patches.has(pid):
		return
	var cell: int = int(patches[pid]["cell"])
	patches.erase(pid)
	if by_cell.has(cell):
		by_cell[cell].erase(pid)
	_dirty[cell] = true
	_flush()


# Что растёт ближе всего к точке — по нему работает снятие под курсором.
func nearest_to(pos: Vector3, radius: float) -> int:
	var best := -1
	var best_d: float = radius * radius
	for pid in patches:
		var d: float = pos.distance_squared_to(patches[pid]["pos"])
		if d < best_d:
			best_d = d
			best = pid
	return best


func _create(spot: Dictionary, id: String, maturity: float) -> int:
	var cell: int = int(spot["cell"])
	var salt: int = _next * 7919 + int(absf(spot["pos"].x) * 131)
	# Тело считаем ДО рождения: не нашлось земли под ободом — кочки не будет
	# вовсе, и номер зря не расходуется.
	var body: Dictionary = _make_cushion(spot, PlantsData.ITEMS[id], salt)
	if body.is_empty():
		return -1
	var pid := _next
	_next += 1
	patches[pid] = {
		"pos": spot["pos"], "nrm": spot["nrm"], "id": id,
		"m": maturity, "step": -1, "cell": cell, "salt": salt,
		"body": body,
	}
	if not by_cell.has(cell):
		by_cell[cell] = {}
	by_cell[cell][pid] = true
	_dirty[cell] = true
	return pid


# Есть ли кто-то вплотную. Смотрим ТОЛЬКО ячейку под точкой и её соседей по
# решётке: перебор всего сада на каждый отросток — это работа в квадрате от
# числа кочек, и заросшая карта встала бы колом.
func _crowded(pos: Vector3, gap: float) -> bool:
	var home: int = main.grid.cell_at(pos)
	if home < 0:
		return false
	var g2: float = gap * gap
	var node: Vector3i = main.grid.node_of(home)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var c: int = main.grid.node_seed(node + Vector3i(dx, dy, dz))
				if c < 0:
					continue
				for pid in by_cell.get(c, {}):
					if pos.distance_squared_to(patches[pid]["pos"]) < g2:
						return true
	return false


# =============================================================================
#  Рост и расползание
# =============================================================================
func _tick(dt: float) -> void:
	var sprouts: Array = []
	for pid in patches:
		var p: Dictionary = patches[pid]
		var def: Dictionary = PlantsData.ITEMS[p["id"]]
		var rate: float = def["grow_rate"] * (1.0 + def["shade_love"] * _shade(p))
		# В складке растению вольготнее: туда наносит землю и дольше держится
		# сырость. Величину складки считает сама сетка.
		var fold: float = maxf(0.0, main.grid.cavity_of(int(p["cell"])))
		rate *= 1.0 + def["joint_love"] * fold
		# Ступень тем длиннее, чем растение взрослее.
		rate /= STAGE_COST[clampi(int(p["m"] * float(STAGES)), 0, STAGES - 1)]
		p["m"] = minf(1.0, p["m"] + rate * dt)

		if p["m"] >= def["spread_at"] and _rng.randf() < def["spread_rate"] * dt:
			var target := _sprout_from(p, def)
			if not target.is_empty():
				sprouts.append([target, p["id"]])

	for s in sprouts:
		if not _crowded(s[0]["pos"], CROWD * main.CELL_SPACING):
			_create(s[0], s[1], 0.05)
	_flush()


# На какой земле растение вообще держится. Список сторон берём из каталога:
# у мха это «низ, верх, бок» — потолка среди них нет, и правильно: мох не
# растёт вниз головой. Без этой проверки поросль переваливала через кромку
# острова и свисала с его исподу — в кадре это выглядело как зелёная борода.
func _fits_surface(nrm: Vector3, def: Dictionary) -> bool:
	var kinds: Array = def.get("surfaces", [])
	var where := "under"
	if nrm.y > 0.45:
		where = "top"
	elif nrm.y > -0.25:
		where = "side"
	if where == "top":
		return kinds.has("top") or kinds.has("ground")
	return kinds.has(where)


# Отросток уходит в сторону ПО ЗЕМЛЕ: направление берём в плоскости склона,
# иначе на крутом месте побег улетал бы в воздух или в породу.
func _sprout_from(p: Dictionary, def: Dictionary) -> Dictionary:
	var nrm: Vector3 = p["nrm"]
	var side: Vector3 = nrm.cross(Vector3.UP)
	if side.length_squared() < 0.001:
		side = nrm.cross(Vector3.RIGHT)
	side = side.normalized()
	var along: Vector3 = nrm.cross(side).normalized()
	var a: float = _rng.randf() * TAU
	var dir: Vector3 = side * cos(a) + along * sin(a)
	# Лиана лезет ВВЕРХ: тот же отросток, но с сильным перевесом по подъёму.
	var climb: float = float(def.get("climb", 0.0))
	if climb > 0.0:
		var up: Vector3 = (Vector3.UP - nrm * nrm.dot(Vector3.UP))
		if up.length_squared() > 0.001:
			dir = (dir + up.normalized() * climb).normalized()
	var step: float = main.CELL_SPACING * _rng.randf_range(SPREAD_NEAR, SPREAD_FAR)
	var spot: Dictionary = main.grid.surface_near(p["pos"] + dir * step)
	if spot.is_empty():
		return {}
	# Отросток обязан сесть РЯДОМ и на СВОЙ ЛАД повёрнутую землю. Проверка не
	# придирка: от точки в воздухе у края острова ближайшая земля — это его
	# исподняя сторона, и поросль уходила туда одним прыжком, огибая кромку.
	if spot["pos"].distance_to(p["pos"]) > step * 1.7:
		return {}
	if spot["nrm"].dot(p["nrm"]) < 0.35:      # круче ~70° за шаг — это перескок
		return {}
	if not _fits_surface(spot["nrm"], def):
		return {}
	return spot


# Насколько место затенено. Пока у нас нет ни полога, ни солнца, тенью служит
# складка: в щели и под нависанием света меньше. Вернуться сюда, когда появятся
# верхние ярусы — они и будут главной тенью.
func _shade(p: Dictionary) -> float:
	return clampf(main.grid.cavity_of(int(p["cell"])) * 0.5 + 0.5 - p["nrm"].y * 0.5,
		0.0, 1.0)


# Всплеск роста от действия игрока — рядом с местом мазка.
#
# ЖДЁТ ПОДКЛЮЧЕНИЯ. Механика была в прежней версии растений и потерялась при
# переписывании: её никто не зовёт. Смысл — чтобы правка рельефа отзывалась
# ростом рядом, и мир отвечал на действие сразу, а не только со временем.
# Решить вместе с пользователем: от чего именно всплеск — от любого мазка, от
# дождя, от полива, — и тогда позвать.
func burst_at(cell: int, amount: float = 0.30) -> void:
	if cell < 0:
		return
	var here: Vector3 = main.grid.seeds[cell]
	var reach: float = main.CELL_SPACING * 1.6
	for pid in patches:
		var p: Dictionary = patches[pid]
		if p["pos"].distance_to(here) < reach:
			p["m"] = minf(1.0, p["m"] + amount)
			_dirty[int(p["cell"])] = true
	_flush()


# =============================================================================
#  Земля под растением изменилась
# =============================================================================
# Проверяем только тех, кто сидел на задетых ячейках, и их соседей: мазок
# двигает поверхность и вокруг себя. Растение либо переезжает вслед за землёй,
# либо гибнет, если земли под ним больше нет.
func surface_changed(cells: Array = []) -> void:
	var suspect: Dictionary = {}
	if cells.is_empty():
		for pid in patches:
			suspect[pid] = true
	else:
		for c in cells:
			for pid in by_cell.get(c, {}):
				suspect[pid] = true

	var doomed: Array = []
	for pid in suspect:
		var p: Dictionary = patches[pid]
		var spot: Dictionary = main.grid.surface_near(p["pos"])
		# Ушла дальше половины ячейки — значит, землю из-под растения вынули
		# или засыпали его с головой.
		if spot.is_empty() \
				or spot["pos"].distance_to(p["pos"]) > main.CELL_SPACING * 0.5 \
				or not _fits_surface(spot["nrm"], PlantsData.ITEMS[p["id"]]):
			doomed.append(pid)
			continue
		# Земля сдвинулась — раскладку пересаживаем заново, иначе кочка останется
		# висеть по старому рельефу. Не нашлось нового места ободу — растение
		# гибнет: рваного тела быть не должно.
		var again: Dictionary = _make_cushion(spot, PlantsData.ITEMS[p["id"]],
			int(p["salt"]))
		if again.is_empty():
			doomed.append(pid)
			continue
		var was: int = int(p["cell"])
		p["pos"] = spot["pos"]
		p["nrm"] = spot["nrm"]
		p["body"] = again
		var now: int = int(spot["cell"])
		if now != was:
			if by_cell.has(was):
				by_cell[was].erase(pid)
			if not by_cell.has(now):
				by_cell[now] = {}
			by_cell[now][pid] = true
			p["cell"] = now
			_dirty[was] = true
		_dirty[now] = true
	for pid in doomed:
		remove_at(pid)
	_flush()


# =============================================================================
#  Отрисовка: один меш на ячейку
# =============================================================================
func _flush() -> void:
	for pid in patches:
		var p: Dictionary = patches[pid]
		var step := int(p["m"] * float(STEPS))
		if step != p["step"]:
			p["step"] = step
			_dirty[int(p["cell"])] = true
	for cell in _dirty:
		_rebuild_cell(cell)
	_dirty.clear()


# Всё живое рисуется одинаково — дощечками с картинкой. Гладкая подушка для
# лианы, стоявшая тут прежде, оказалась хуже заглушки: бледные пузыри облепляли
# глыбу и забивали собой весь кадр. Лиана теперь тот же пучок, только вытянутый
# по подъёму; своя форма со стеблем и листьями за ней всё ещё числится.
func _rebuild_cell(cell: int) -> void:
	var here: Dictionary = by_cell.get(cell, {})
	if here.is_empty():
		if cell_nodes.has(cell):
			cell_nodes[cell].queue_free()
			cell_nodes.erase(cell)
		return

	var tufts := SurfaceTool.new()
	tufts.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any_tuft := false
	for pid in here:
		if patches.has(pid) and _emit_tuft(tufts, patches[pid]):
			any_tuft = true
	if not any_tuft:
		if cell_nodes.has(cell):
			cell_nodes[cell].queue_free()
			cell_nodes.erase(cell)
		return

	# И УЗЕЛ, И МЕШ ПЕРЕИСПОЛЬЗУЕМ, а не создаём заново. Кочка пересобирается на
	# каждой ступени роста, ступеней девять, кочек сотни — за один прогон это
	# тысячи мешей. Снятие узла отложенное, и старые доживают до конца кадра
	# рядом с новыми: видеокарта упиралась в предел числа буферов и переставала
	# выдавать новые («Can't create buffer of size…»). Со снятием граней у того
	# же меша буферы освобождаются на месте, и запас не копится.
	var mi: MeshInstance3D = cell_nodes.get(cell)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.mesh = ArrayMesh.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		cell_nodes[cell] = mi
	var mesh: ArrayMesh = mi.mesh
	mesh.clear_surfaces()
	tufts.set_material(_blade_mat)
	tufts.commit(mesh)


# КОЧКА — ТЕЛО ПЛЮС ВОРС (решение пользователя, по двум её рисункам).
#
# Прежде кочка была только пучком плоских картинок под разными углами. Объём у
# такого пучка мнимый: он держится, пока часть дощечек видна плашмя, и рушится,
# стоит посмотреть вдоль них — подушка схлопывается в зелёную нитку. Никаким
# числом дощечек это не лечится, потому что лечить нечего: объёма там нет.
#
# Теперь объём НАСТОЯЩИЙ. У кочки есть тело — низкий купол из колец: сверху
# неправильный многоугольник (в меру угловатый), сбоку плоская макушка,
# скруглённое плечо и крутой бок. Ворсинки-картинки растут ИЗ ЭТОГО ТЕЛА по его
# нормали: на макушке торчком, у края завалены наружу. Тело даёт массу и силуэт,
# ворс — пушистый край; поодиночке ни то, ни другое мхом не выглядит.
#
# ЧЕМ ЭТО ПЛАТИТСЯ. Треугольников выходит примерно столько же, сколько было у
# пучка с шапками, а поиск земли — ВТРОЕ ДЕШЕВЛЕ: раньше на землю сажали каждую
# ворсинку по отдельности, теперь только обод и середину, а всё внутри
# достраивается между ними.
const SECTORS: int = 7                      # углов у кочки, если смотреть сверху
const RING_AT := [0.45, 0.78, 1.0]          # где идут кольца, в долях радиуса
const BODY_WIDE: float = 1.31               # радиус тела в долях «М»
const BODY_RISE: float = 0.58               # высота тела в долях его радиуса
const RIM_SINK: float = 0.10                # на сколько обод утоплен в землю
# Ворсинок В РАЗЫ МЕНЬШЕ, чем было: пышность теперь держит тело, а ворс только
# ломает силуэт. Прежние двадцать две поверх готового купола — это оплаченная
# дважды одна и та же масса.
const FUZZ_MAX: int = 14
const FUZZ_MIN: int = 4
const FUZZ_TALL: float = 0.62               # рост ворсинки в долях «М»
# Куда по картинке смотрит тело кочки — в долях СПЛОШНОГО ПРЯМОУГОЛЬНИКА клетки,
# а не самой клетки.
#
# ГРАБЛИ: сперва тело брало нутро клетки на глазок, 45–85% её высоты. У молодых
# возрастов куртинка нарисована только у нижнего края, выше прозрачный фон, а
# движок режет по порогу — и у кочки МЛАДШЕ СЕДЬМОЙ СТУПЕНИ ПРОСВЕЧИВАЛ ЦЕНТР:
# макушка тела попадала в пустоту. К седьмой рисунок дорастал, и дыра сама
# закрывалась. Теперь сплошной прямоугольник у каждой клетки НАХОДИТСЯ ПО САМОЙ
# КАРТИНКЕ при запуске, поэтому дыр не будет ни при какой рисовке.
const BODY_V_TOP: float = 0.15
const BODY_V_RIM: float = 0.92
# Строка клетки считается плотной, если сплошной кусок в ней не уже этой доли
# ширины клетки. По таким строкам и собирается прямоугольник.
const DENSE_ROW: float = 0.30
# Два треугольника пояса между кольцами: сдвиг по кольцу и по сектору. Таблица
# ПОСТОЯННАЯ нарочно — собранная на месте, она бы заводила по шесть коротких
# списков на каждый сектор каждого пояса каждой перестройки.
const BAND_TRI := [[0, 0], [0, 1], [1, 1], [0, 0], [1, 1], [1, 0]]
# РАЗМЕР ПОЧТИ НЕ МЕНЯЕТСЯ С ВОЗРАСТОМ — так решено по кадру.
#
# Прежде кочка росла втрое (0.035 → 0.105 доли шага), и молодую было не
# разглядеть: три крошечные ворсинки, разбросанные по всему пятну. Теперь
# размер пятой ступени — «М», три четверти прежнего предела, а каждая ступень
# в сторону меняет его на пять сотых: первая — 80% М, девятая — 120% М.
#
# Взрослеет мох, стало быть, не размером, а ГУСТОТОЙ и самим рисунком: ворсинок
# прибывает, и картинка возраста меняется с плоской лепёшки на пухлую подушку.
const ADULT_SIZE: float = 0.105 * 0.75      # «М» — доля шага решётки
const SIZE_PER_STAGE: float = 0.05
const MID_STAGE: float = 5.0                # ступень, на которой размер ровно М

# ШИРИНА КУРТИНЫ РАСТЁТ САМА, много круче размера ворсинки (решение пользователя
# 2026-08-17). Молодая кочка — отдельный бугорок уже своей мерки, взрослые же
# должны СОМКНУТЬСЯ В СПЛОШНОЙ МАССИВ: садиться ближе 0.27 м друг к другу им
# нельзя, значит к старости радиус должен этот зазор перекрыть.
#
# Ворсинка при этом держится прежнего правила «М ±5% за ступень». Так и у живого
# мха: подушка ширится числом побегов, а не тем, что каждый побег толстеет.
const PATCH_YOUNG: float = 0.65             # радиус на первой ступени, в долях М
const PATCH_OLD: float = 1.45               # ... и на девятой; по ней и печём

# Какую долю зрелости ворсинка тянется от нуля до полного роста. Отрезки
# соседних ворсинок НАХЛЁСТЫВАЮТСЯ: чем длиннее отрезок, тем больше их растёт
# разом и тем меньше каждая прибавляет за ступень. Слишком длинный — и кочка
# всю жизнь стоит недоросшей.
const SPROUT_SPAN: float = 0.22


# ПРОДОЛЬНЫЙ СРЕЗ КОЧКИ, от макушки (0) к ободу (1). Не полусфера: у мховой
# подушки макушка плоская, плечо скруглено, а бок почти отвесный — так на рисунке
# пользователя, и так же на снимках живого мха.
static func _profile(t: float) -> float:
	return pow(maxf(0.0, 1.0 - pow(t, 3.0)), 0.45)


# РАСКЛАДКА КОЧКИ СЧИТАЕТСЯ ОДИН РАЗ, при рождении, и живёт с ней.
#
# На землю сажаем ТОЛЬКО ОБОД — семь точек по кругу — и середину. Всё, что внутри,
# достраивается между ними: кочка поперёк вчетверо мельче ячейки, и земля на
# таком клочке от хорды почти не отличается. Раньше на землю садили каждую из
# двадцати двух ворсинок, и это была самая дорогая часть роста.
#
# Печём при САМОМ СТАРШЕМ размере, а младшие ступени сжимают обод к середине.
# Иначе обод пришлось бы искать заново на каждой ступени роста.
#
# Не нашлось земли под ободом — кочки НЕ БУДЕТ вовсе. У пучка можно было
# обронить отдельную ворсинку, у сплошного тела дыра в ободе — это рваная
# оболочка. Зато у обрыва мох теперь не свесится: ему просто негде лечь.
func _make_cushion(spot: Dictionary, def: Dictionary, salt: int) -> Dictionary:
	var centre: Vector3 = spot["pos"]
	var nrm: Vector3 = spot["nrm"]
	var side: Vector3 = nrm.cross(Vector3.UP)
	if side.length_squared() < 0.001:
		side = nrm.cross(Vector3.RIGHT)
	side = side.normalized()
	var along: Vector3 = nrm.cross(side).normalized()

	# Лиана ползёт вверх по склону узкой полосой — её пятно вытянуто. Сильнее
	# полутора раз растягивать нельзя: кочка вырождается в лезвие.
	var creep: float = 1.0
	if str(def.get("shape", "")) == "vine":
		var up: Vector3 = Vector3.UP - nrm * nrm.dot(Vector3.UP)
		if up.length_squared() > 0.001:
			side = up.normalized()
			along = nrm.cross(side).normalized()
		creep = 1.5

	var reach: float = main.CELL_SPACING * ADULT_SIZE * BODY_WIDE * PATCH_OLD
	var rings: int = RING_AT.size()
	var rim: Array = []
	for s in range(SECTORS):
		var a: float = TAU * float(s) / float(SECTORS)
		# Радиус у каждого сектора свой — отсюда неправильный многоугольник
		# сверху. Ровный круг сразу читается штампом, повторённым сотни раз.
		var wob: float = 0.78 + 0.42 * _hash01(salt + s * 7717)
		var dir: Vector3 = (side * (cos(a) * creep) + along * sin(a)).normalized()
		var far: float = reach * wob
		var pos := Vector3.ZERO
		var got := false
		# Не нашлось на полном радиусе — подбираем сектор ближе к середине. Кочка
		# у кромки выйдет кривобокой, но целой.
		for k in [1.0, 0.62, 0.3]:
			var on: Dictionary = main.grid.surface_near(centre + dir * (far * k))
			if on.is_empty():
				continue
			if on["pos"].distance_to(centre) > far * k * 1.9 or on["nrm"].dot(nrm) < 0.2:
				continue
			pos = on["pos"]
			got = true
			break
		if not got:
			return {}
		# Бугорки на макушке: каждое кольцо каждого сектора чуть выше или ниже
		# ровного среза. Без них купол гладкий, как надувной, а мховая подушка
		# сложена из сросшихся холмиков.
		var lump := PackedFloat32Array()
		lump.resize(rings)
		for r in range(rings):
			lump[r] = 0.90 + 0.20 * _hash01(salt + s * 131 + r * 977)
		rim.append({"off": pos - centre, "lump": lump})

	# ВОРС. Место — на теле, а не на земле: доля радиуса и угол, остальное
	# считается по куполу. Порядок — ОТ СЕРЕДИНЫ К КРАЮ по золотому углу: растущая
	# кочка добавляет ворсинки с краю, а не втыкает посреди уже готовых.
	var fuzz: Array = []
	for i in range(FUZZ_MAX):
		var t: float = sqrt(float(i) / float(FUZZ_MAX - 1))   # равномерно по площади
		var a: float = float(i) * 2.39996323
		var dir: Vector3 = (side * (cos(a) * creep) + along * sin(a)).normalized()
		# Насколько далеко обод в эту сторону — берём между соседними секторами.
		var at: float = float(SECTORS) * a / TAU
		var s0: int = int(floor(at)) % SECTORS
		var s1: int = (s0 + 1) % SECTORS
		var mix: float = at - floor(at)
		var near: float = lerpf(Vector3(rim[s0]["off"]).length(),
			Vector3(rim[s1]["off"]).length(), mix)
		# Срез купола под ворсинкой и его наклон — величины ПОСТОЯННЫЕ: доля
		# радиуса у ворсинки своя на всю жизнь, меняется только общий размер.
		# Считать их при каждой перестройке значило бы звать `pow` по два раза
		# на каждую ворсинку каждой кочки.
		var tc: float = minf(t, 0.92)
		var t2: float = minf(1.0, tc + 0.08)
		fuzz.append({
			"dir": dir, "t": tc, "reach": near,
			"prof": _profile(tc), "dprof": _profile(t2) - _profile(tc),
			"dt": t2 - tc,
			"turn": TAU * _hash01(salt + i * 2113),
			"lean": _hash01(salt + i * 3319) - 0.5,
			"wide": 0.70 + 0.60 * _hash01(salt + i * 4409),
			"high": 0.65 + 0.70 * _hash01(salt + i * 5501),
			"kind": int(_hash01(salt + i * 6607) * float(KINDS)) % KINDS,
			"shade": 0.90 + 0.18 * _hash01(salt + i * 8819),
			# СВОЙ ВОЗРАСТ У КАЖДОЙ ВОРСИНКИ — точнее, свой сдвиг на доле ступени.
			# Возрастов у картинки девять, и пока весь ворс переключался разом,
			# кочка меняла облик рывком, сколько бы ни было ступеней роста. Со
			# сдвигом ворсинки переваливают на следующий возраст поодиночке: в
			# любой миг кочка набрана из двух соседних возрастов, и их доля
			# перетекает плавно.
			"age": _hash01(salt + i * 9931),
		})

	return {
		"up": nrm, "rim": rim, "fuzz": fuzz,
		"age": _hash01(salt + 577),
		"shade": 0.92 + 0.14 * _hash01(salt + 1223),
	}


func _emit_tuft(st: SurfaceTool, p: Dictionary) -> bool:
	var def: Dictionary = PlantsData.ITEMS[p["id"]]
	var m: float = p["m"]
	var body: Dictionary = p.get("body", {})
	if body.is_empty():
		return false
	var rim: Array = body["rim"]
	var fuzz: Array = body["fuzz"]
	var centre: Vector3 = p["pos"]
	var up: Vector3 = body["up"]

	var stage_f: float = m * float(STAGES)
	# Номер ступени как непрерывная величина: середина первой — ровно 1, середина
	# пятой — ровно 5. Считаем непрерывно, а не по целой ступени, чтобы размер не
	# подскакивал на переходе — ради этого и участились пересборки.
	var stage_no: float = clampf(stage_f + 0.5, 1.0, float(STAGES))
	# Ворсинка — по правилу «М ±5% за ступень», куртина — по своему, куда круче.
	# Раскладка испечена при самом широком возрасте, младшие сжимают её к середине.
	var size: float = 1.0 + SIZE_PER_STAGE * (stage_no - MID_STAGE)
	var wide_at: float = lerpf(PATCH_YOUNG, PATCH_OLD,
		(stage_no - 1.0) / float(STAGES - 1))
	var k: float = wide_at / PATCH_OLD
	var high: float = main.CELL_SPACING * ADULT_SIZE * BODY_WIDE * wide_at * BODY_RISE
	var tall: float = main.CELL_SPACING * ADULT_SIZE * size * FUZZ_TALL

	# Цвет вида берём БЕЗ его темноты: тень и свет уже нарисованы на картинке,
	# и умножение на тёмно-зелёный сделало бы кочку чёрной. И оттенок подмешиваем
	# лишь наполовину — на полную он перекрашивал картинку в свой цвет, стирая
	# всю проработку, ради которой она и рисовалась.
	var c: Color = def["color"]
	var lum: float = maxf(0.001, (c.r + c.g + c.b) / 3.0)
	var hue := Color(1.0, 1.0, 1.0).lerp(
		Color(c.r / lum, c.g / lum, c.b / lum), 0.5)

	# =========================================================================
	#  ТЕЛО: купол из колец
	# =========================================================================
	# Сначала считаем ВСЕ точки, потом нормали по соседям, и только потом
	# выкладываем треугольники. Нормаль, взятая от соседних точек самого меша,
	# всегда сходится с тем, что видно; выведенная отдельной формулой — рано или
	# поздно разойдётся с геометрией, и купол засветится не по своей форме.
	var rings: int = RING_AT.size()
	var apex: Vector3 = centre + up * (high * (0.95 + 0.10 * float(body["age"])))
	var pts: Array = []
	for r in range(rings):
		var t: float = float(RING_AT[r])
		var ring: Array = []
		for s in range(SECTORS):
			# Обод топим в землю (`RIM_SINK`), иначе по кромке идёт шов: тело
			# кончается ровно на поверхности, и в стык видно землю на просвет.
			var lift: float = high * (_ring_prof[r] * float(rim[s]["lump"][r])
				- _ring_sink[r])
			ring.append(centre + Vector3(rim[s]["off"]) * (t * k) + up * lift)
		pts.append(ring)

	# Сторону нормали решаем по точке ВНУТРИ тела: у макушки она смотрит вверх,
	# у крутого бока — наружу, и одна проверка на высоту тут не годится.
	var inside: Vector3 = centre + up * (high * 0.35)
	var nrms: Array = []
	for r in range(rings):
		var ring_n: Array = []
		for s in range(SECTORS):
			var here: Vector3 = pts[r][s]
			var nxt: Vector3 = pts[r][(s + 1) % SECTORS]
			var prv: Vector3 = pts[r][(s + SECTORS - 1) % SECTORS]
			var inner: Vector3 = apex if r == 0 else pts[r - 1][s]
			var outer: Vector3 = pts[r + 1][s] if r + 1 < rings \
				else here + (here - inner)
			var n: Vector3 = (nxt - prv).cross(outer - inner)
			if n.length_squared() < 0.0000001:
				n = up
			else:
				n = n.normalized()
				if n.dot(here - inside) < 0.0:
					n = -n
			ring_n.append(n)
		nrms.append(ring_n)

	# Разрез картинки — тоже вперёд, по кольцу и по сектору: внутри выкладки он
	# считался бы заново на каждую из сотни вершин.
	var bstage: int = clampi(int(stage_f + float(body["age"])), 0, STAGES - 1)
	# Тело обтягиваем ОБРАЗЦОМ ИЗ ПЯТОГО СТОЛБЦА, а не клеткой с фигуркой. И даже
	# у него берём не клетку целиком, а найденную сплошную часть: если образец
	# нарисован не во всю клетку, дыр всё равно не будет. См. `_scan_solid`.
	var box: Rect2 = _solid_uv[bstage * COLS + BODY_COL]
	var cuts: Array = []
	for r in range(rings):
		var vv: float = box.position.y + box.size.y * _ring_v[r]
		var ring_uv: Array = []
		for s in range(SECTORS):
			ring_uv.append(Vector2(box.position.x + box.size.x * _sector_u[s], vv))
		cuts.append(ring_uv)
	var apex_uv := Vector2(box.position.x + box.size.x * 0.5,
		box.position.y + box.size.y * BODY_V_TOP)

	st.set_color((hue * float(body["shade"])).srgb_to_linear())
	for s in range(SECTORS):
		var s2: int = (s + 1) % SECTORS
		# Макушка: веер от середины к первому кольцу.
		st.set_normal(up)
		st.set_uv(apex_uv)
		st.add_vertex(apex)
		st.set_normal(nrms[0][s])
		st.set_uv(cuts[0][s])
		st.add_vertex(pts[0][s])
		st.set_normal(nrms[0][s2])
		st.set_uv(cuts[0][s2])
		st.add_vertex(pts[0][s2])
		# Пояса между кольцами.
		for r in range(rings - 1):
			for q in BAND_TRI:
				var rr: int = r + int(q[0])
				var ss: int = s2 if int(q[1]) == 1 else s
				st.set_normal(nrms[rr][ss])
				st.set_uv(cuts[rr][ss])
				st.add_vertex(pts[rr][ss])

	# =========================================================================
	#  ВОРС: картинки, растущие ИЗ ТЕЛА по его нормали
	# =========================================================================
	# Направление берём у самого купола: на макушке ворсинка стоит торчком, у
	# края завалена наружу — ровно так на разрезе у пользователя. Считать это
	# отдельным правилом не нужно, оно уже есть в форме тела.
	#
	# ЧИСЛО РАСТЁТ НЕ ЦЕЛЫМИ: у каждой ворсинки свой отрезок зрелости
	# (`SPROUT_SPAN`), и она вытягивается по нему от нуля. Возникшая разом
	# ворсинка в полный рост читается миганием, а не ростом. Первые `FUZZ_MIN`
	# есть сразу — у только что севшей кочки иначе торчал бы голый купол.
	var many: int = fuzz.size()
	var spread: float = float(maxi(1, many - FUZZ_MIN))
	for i in range(many):
		var b: Dictionary = fuzz[i]
		var grow: float = 1.0
		if i >= FUZZ_MIN:
			var born: float = float(i - FUZZ_MIN) / spread * (1.0 - SPROUT_SPAN)
			grow = (m - born) / SPROUT_SPAN
			if grow <= 0.0:
				break          # дальше по списку всходят только позже этой
			grow = clampf(grow, 0.0, 1.0)
			grow = grow * grow * (3.0 - 2.0 * grow)     # мягко от нуля и к полному
		var dir: Vector3 = b["dir"]
		var reach: float = float(b["reach"]) * k
		var foot0: Vector3 = centre + dir * (reach * float(b["t"])) \
			+ up * (high * float(b["prof"]))
		# Нормаль купола в этой точке — по срезу. Наклон среза здесь и заваливает
		# ворсинку наружу тем сильнее, чем ближе к ободу.
		var stand: Vector3 = up * (reach * float(b["dt"])) \
			- dir * (high * float(b["dprof"]))
		stand = stand.normalized() if stand.length_squared() > 0.0000001 else up

		var side: Vector3 = stand.cross(Vector3.UP)
		if side.length_squared() < 0.001:
			side = stand.cross(Vector3.RIGHT)
		side = side.normalized()
		var along: Vector3 = stand.cross(side).normalized()
		var turn: float = float(b["turn"])
		var face: Vector3 = side * cos(turn) + along * sin(turn)
		var w: float = tall * float(b["wide"]) * grow
		var h: float = tall * float(b["high"]) * grow
		var lean: Vector3 = (stand + face * (float(b["lean"]) * 0.35)).normalized()
		var half: Vector3 = face * (w * 0.5)
		# Корень УТАПЛИВАЕМ в тело: иначе между картинкой и куполом просвечивает
		# щель, и ворс читается воткнутым, а не выросшим.
		var foot: Vector3 = foot0 - stand * (h * 0.28)

		var cx: int = int(b["kind"])
		var stage: int = clampi(int(stage_f + float(b["age"])), 0, STAGES - 1)
		var u0: float = float(cx) / float(COLS)
		var u1: float = float(cx + 1) / float(COLS)
		var v0: float = float(stage) / float(STAGES)      # верх клетки — концы
		var v1: float = float(stage + 1) / float(STAGES)  # низ — корни

		st.set_color((hue * float(b["shade"])).srgb_to_linear())
		var quad := [foot - half, foot + half,
			foot + half + lean * h, foot - half + lean * h]
		var uvs := [Vector2(u0, v1), Vector2(u1, v1), Vector2(u1, v0), Vector2(u0, v0)]
		# Стороны у материала не отсекаются, поэтому порядок обхода не важен.
		for tri in [[0, 1, 2], [0, 2, 3]]:
			for j in tri:
				st.set_normal(stand)
				st.set_uv(uvs[j])
				st.add_vertex(quad[j])
	return true


func _hash01(n: int) -> float:
	var x: int = (n * 1103515245 + 12345) & 0x7fffffff
	return float((x >> 8) & 0xffff) / 65535.0
