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
const SPREAD_NEAR: float = 0.09
const SPREAD_FAR: float = 0.22
# Ближе этого друг к другу не садимся — в долях СУММЫ ВЗРОСЛЫХ РАДИУСОВ пары.
#
# Раньше зазор был один на всех, и заросль выходила ровной, как клёпки: у всех
# кочек одна мерка, значит и мест для них — правильная упаковка. Теперь у каждой
# кочки свой размер, и место она требует по себе: рядом с крупной просторно,
# среди мелких тесно. Расстановка от этого перестаёт быть решёткой сама собой,
# без единого лишнего случайного числа.
#
# Половина суммы радиусов — это гарантированное СМЫКАНИЕ: взрослые соседи
# перекрываются, а не только касаются. Без перекрытия срастаться нечему.
const SIT_APART: float = 0.45

# РАЗМЕР КОЧКИ — СВОЙ У КАЖДОЙ, до четверти в обе стороны (решение пользователя).
# Наследуется, а не бросается заново: отросток берёт размер родителя, чуть
# убавленный и сбитый разбросом. Оттого вокруг самой крупной сидят крупные,
# вокруг тех — средние, а местами разброс перебивает убывание, и среди мелочи
# вырастает крупная. Просто случайный размер такого узора не даёт — выходит
# равномерная рябь, то есть те же клёпки, только разного калибра.
const BULK_MIN: float = 0.65
const BULK_MAX: float = 1.35
const BULK_FADE: float = 0.06               # насколько поколение мельчает
const BULK_DRIFT: float = 0.16              # и насколько разброс это перебивает
# Насколько гуляет сам зазор между соседями. Без этого расстановка выходит
# правильной упаковкой — той же решёткой, только с разными кружками.
const SIT_JITTER: float = 0.22

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
var _bump_spread: float = 0.0     # замеренный уклон образца, девятая десятая
var _bump_tilt: float = 0.0       # и во сколько градусов он обошёлся
var _body_hgt := PackedFloat32Array()   # высота образца, если его рисовали мы
var _sprout_try: int = 0                # попыток отростка у лиан
var _sprout_win: int = 0                # ... и сколько из них нашли место
# ПОЧЕМУ ПЛЕТЕЙ НЕТ — вопрос с двумя совершенно разными ответами: кончик до
# верхней кромки не дошёл (пробовать было негде) или дошёл и не нашёл, куда
# падать. По числу плетей их не различить, а чинить надо разное.
var _hang_try: int = 0                  # попыток перевалить через кромку
var _hang_edge: int = 0                 # ... из них шаг за кромку вышел в воздух
var _hang_win: int = 0                  # ... и под кромкой нашлось куда падать
# И НАСКОЛЬКО ГЛУБОКО МЕСТА ХВАТИЛО — по звеньям, от нуля до мерки. Мерку по этой
# записи и выбирали: гадать, три звена требовать или два, было бы гаданием.
var _hang_deep := PackedInt32Array()
# Всё, что у кочки ОДИНАКОВО ВСЕГДА: срез по кольцам, утопление обода, разрез
# картинки по кольцам и по секторам. Считается один раз при запуске. Внутри
# перестройки это были бы `pow` и `sin` на каждую вершину — сотня на кочку,
# сотни кочек, двадцать четыре перестройки за жизнь каждой.
var _ring_sink := PackedFloat32Array()
const PROF_STEPS: int = 32
var _prof_lut := PackedFloat32Array()
# Сплошной прямоугольник каждой клетки листа, в долях всей картинки. Ищется по
# самой картинке при запуске — см. `_scan_solid`.
var _solid_uv: Array = []
var _solid_holes: int = 0
var _solid_least: int = 0         # самая тесная клетка, в точках
# Сколько секторов за всё время не нашли под собой земли и были поджаты внутрь.
# Именно этот путь и давал повисшие над обрывом края, поэтому его надо видеть.
var _stub_sectors: int = 0


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
	_blade_mat.set_shader_parameter("bumps", _make_bumps(sheet))
	_blade_mat.set_shader_parameter("body_cell",
		Vector2(1.0 / float(COLS), 1.0 / float(STAGES)))
	# ГОЛОЕ ТЕЛО, БЕЗ РЕЛЬЕФА — для сравнения двух кадров одного места, как с
	# `--plain` у поверхности. С руки то же место не поймать, а рельеф либо
	# прибавляет, либо нет, и решается это только парой кадров рядом.
	if main.flat_moss:
		_blade_mat.set_shader_parameter("bump", 0.0)
	_scan_solid(sheet)

	var rings: int = RING_AT.size()
	_ring_sink.resize(rings)
	for r in range(rings):
		var t: float = float(RING_AT[r])
		_ring_sink[r] = RIM_SINK * t * t
	_hang_deep.resize(HANG_ROOM + 1)
	_prof_lut.resize(PROF_STEPS + 1)
	for i in range(PROF_STEPS + 1):
		_prof_lut[i] = _profile(float(i) / float(PROF_STEPS))


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
			#
			# СПРАШИВАЕМ ТОЛЬКО У СПЛОШНЫХ СТОЛБЦОВ — тела и коры. У вырезанной
			# фигурки плотной строки может не найтись вовсе (у листа внизу клетки
			# один черешок в две точки шириной), и тогда `_dense_box` отдаёт
			# запасную точку у корней — а она там прозрачная. Сторож поднял бы
			# крик о дыре в теле, которой нет: разметку вырезанных клеток никто
			# не читает.
			if kd != BODY_COL and kd != BARK_COL:
				continue
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


# Сколько секторов не нашли земли и были поджаты внутрь. Ноль значит, что путь
# добора в этом мире вообще не задействован, и мерить по нему нечего.
func stub_count() -> int:
	return _stub_sectors


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
# ШЕСТОЙ СТОЛБЕЦ — КОРА, и он устроен как образец тела: сплошной кусок
# поверхности, которым обивают трубку стебля. Отличие одно — он СЕРЫЙ. Цвет коры
# приходит с вершин, из каталога, потому что кора у разных лиан разная, а рисунок
# волокна один и тот же.
const BARK_COL: int = KINDS + 1
# СЕДЬМОЙ СТОЛБЕЦ — ЛИСТ ЛИАНЫ, и устроен он не как два предыдущих, а как
# столбцы ворсинок: это ВЫРЕЗАННАЯ ФИГУРКА, лист с черешком, вокруг прозрачный
# фон. Ею обтягивают выгнутую дощечку, и это верно — лист и в жизни плоский.
#
# По рядам тот же возраст, что и всюду на листе: молодой лист мельче, светлее и
# ещё без глубоких лопастей, старый крупнее, глуше и с грубой жилкой.
const LEAF_COL: int = KINDS + 2
# ТРИ РАЗНОВИДНОСТИ ЛИСТА (решение пользователя 2026-08-21), как и у ворсинок
# мха: одна картинка, повторённая сотни раз, читается повторением, сколько её ни
# верти. Разновидность берётся по соли звена, а не по случаю: раскладка обязана
# быть одной и той же при каждой пересборке.
const LEAF_KINDS: int = 3
const COLS: int = KINDS + 2 + LEAF_KINDS   # всего столбцов на листе

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
			# ЛЮБАЯ НЕДОСТАЮЩАЯ ШИРИНА ГОДИТСЯ. Столбцы прибавлялись по одному, по
			# мере надобности: сперва тело, потом кора. Заставлять переделывать
			# готовый рисунок при каждой такой прибавке неправильно — дорисовываем
			# кодом ровно то, чего в файле ещё нет.
			var have: int = got.x / TILE
			if got.y == TILE * STAGES and got.x % TILE == 0 \
					and have >= KINDS and have < COLS:
				return _widen_sheet(drawn, have)
			push_warning("art/moss.png ожидается %d×%d (или от %d столбцов), а он %s"
				% [want.x, want.y, KINDS, str(got)])
			return drawn
	return _make_blade_texture()


# Пририсовываем к нарисованному листу столбец тела. Саму работу пользователя не
# трогаем — она переносится точка в точку.
func _widen_sheet(drawn: Texture2D, have: int) -> ImageTexture:
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
	if have <= BODY_COL:
		_body_hgt.resize(TILE * TILE * STAGES)
		for s in range(STAGES):
			_paint_body_cell(img, BODY_COL * TILE, s * TILE, s, rng)
	if have <= BARK_COL:
		for s in range(STAGES):
			_paint_bark_cell(img, BARK_COL * TILE, s * TILE, s, rng)
	for k in range(LEAF_KINDS):
		if have > LEAF_COL + k:
			continue
		for s in range(STAGES):
			_paint_leaf_cell(img, (LEAF_COL + k) * TILE, s * TILE, s, k, rng)
	return ImageTexture.create_from_image(img)


# ОБРАЗЕЦ КОРЫ — заглушка, пока он не нарисован.
#
# Кора идёт ВОЛОКНОМ ВДОЛЬ СТЕБЛЯ, и в клетке это столбцы: разметка трубки кладёт
# поперёк неё ширину клетки, а вдоль — её высоту, значит ровная по высоте черта
# ложится вдоль стебля. У мха такая же черта дала звезду, а тут она-то и нужна.
#
# СЕРАЯ НАРОЧНО. Цвет коры приходит с вершин, из каталога: у винограда она бурая,
# у другой лианы будет зелёной или седой, а рисунок волокна один и тот же.
#
# С возрастом волокно грубеет: у молодого побега кора гладкая, у старого —
# бороздчатая. Ровно это и видно на живой лозе.
func _paint_bark_cell(img: Image, ox: int, oy: int, s: int,
		rng: RandomNumberGenerator) -> void:
	var age: float = float(s) / float(STAGES - 1)
	var rough: float = lerpf(0.10, 0.34, age)
	# Своя яркость у каждого столбца — это и есть волокно. Заворот по кругу тут
	# нужен так же, как у тела: образец повторяется поперёк трубки.
	var fibre := PackedFloat32Array()
	fibre.resize(TILE)
	for x in range(TILE):
		fibre[x] = rng.randf_range(-1.0, 1.0)
	# Разглаживаем по три: без этого волокна выходят в одну точку шириной и
	# читаются не корой, а рябью.
	var soft := PackedFloat32Array()
	soft.resize(TILE)
	for x in range(TILE):
		soft[x] = (fibre[(x + TILE - 1) % TILE] + fibre[x] * 2.0
			+ fibre[(x + 1) % TILE]) / 4.0
	# Борозды — те же волокна, только реже и глубже.
	for _i in range(2 + int(round(3.0 * age))):
		var at: int = rng.randi_range(0, TILE - 1)
		soft[at] = -1.0
		soft[(at + 1) % TILE] = lerpf(soft[(at + 1) % TILE], -0.7, 0.6)
	for y in range(TILE):
		for x in range(TILE):
			# Вдоль стебля кора тоже не ровная, но заметно слабее, чем поперёк.
			var along: float = (_hash01(x * 9173 + y * 311 + s * 77) - 0.5) * 0.5
			var tone: float = clampf(0.86 + (soft[x] + along) * rough, 0.30, 1.0)
			img.set_pixel(ox + x, oy + y, Color(tone, tone, tone, 1.0))


# ЛИСТ ЛИАНЫ — заглушка, пока он не нарисован.
#
# Лист виноградного склада: округлая пластина с ПЯТЬЮ ЛОПАСТЯМИ, вырезом у
# черешка и зубчатым краем. Всю форму задаёт одна косинусоида: у пяти лопастей
# вершины приходятся ровно на верх и на ±72°, ±144°, а впадины — на ±36°, ±108° и
# на 180°, то есть туда, где к листу подходит черешок. Отдельно вырез рисовать не
# пришлось, он вышел сам.
#
# ЖИЛКИ ИДУТ ОТ ЧЕРЕШКА К ВЕРШИНАМ ЛОПАСТЕЙ, а не из середины пластины: у листа
# с пальчатым жилкованием все главные жилки выходят из одной точки — той, где
# кончается черешок. Считаем расстояние до пяти отрезков, и рисунок получается
# сам собой правильным.
#
# КРАЙ ПРИТЕМНЁН нарочно. Листья лежат внахлёст, и без тёмной каёмки два соседних
# сливаются в одно зелёное пятно — на кадре это уже видели у мха.
#
# С ВОЗРАСТОМ лист крупнее, глуше и резче изрезан: у молодого побега пластина
# мелкая, светлая и почти цельная. Ряд листа — тот же возраст, что и у всех
# прочих столбцов.
func _paint_leaf_cell(img: Image, ox: int, oy: int, s: int, kind: int,
		rng: RandomNumberGenerator) -> void:
	var age: float = float(s) / float(STAGES - 1)
	# ТРИ РАЗНОВИДНОСТИ — это НЕ три разных растения, а три листа одной лозы:
	# у живого винограда на одной плети соседние листья заметно разные — один
	# почти цельный, другой изрезан до середины. Меняем поэтому глубину вырезов,
	# ширину пластины и длину черешка, а палитру и жилкование оставляем общими.
	var cut_k: float = [1.0, 0.5, 1.7][kind]             # насколько изрезан
	var wide_k: float = [1.0, 1.12, 0.88][kind]          # ширина пластины
	var stalk_k: float = [1.0, 0.85, 1.15][kind]         # длина черешка
	var sinus: float = [0.45, 0.35, 0.55][kind]          # вырез у черешка
	var stalk_h: float = lerpf(8.0, 6.0, age) * stalk_k  # черешок, точек
	var rad: float = lerpf(8.5, 12.4, age)               # радиус пластины
	var cut: float = lerpf(0.12, 0.26, age) * cut_k      # глубина вырезов
	var tooth: float = lerpf(0.03, 0.075, age) * cut_k   # зубчатость края
	var base_x: float = float(TILE) * 0.5
	var base_y: float = float(TILE) - 1.0 - stalk_h      # где черешок входит в лист
	var mid_x: float = base_x
	var mid_y: float = base_y - rad * 0.72               # середина пластины
	# Своя мелкая кривизна у каждого возраста: без неё девять клеток — одна и та
	# же фигура, только разного размера.
	var wob_a: float = rng.randf_range(0.0, TAU)
	var wob_b: float = rng.randf_range(0.0, TAU)

	var deep := Color(0.17, 0.26, 0.13).lerp(Color(0.14, 0.21, 0.11), age)
	var body := Color(0.31, 0.44, 0.20).lerp(Color(0.26, 0.37, 0.17), age)
	var lit := Color(0.45, 0.57, 0.27).lerp(Color(0.39, 0.49, 0.24), age)
	var vein := Color(0.53, 0.61, 0.34).lerp(Color(0.47, 0.53, 0.30), age)
	var stem := Color(0.44, 0.40, 0.22).lerp(Color(0.38, 0.31, 0.19), age)

	# Вершины лопастей — они же концы главных жилок.
	var tips: Array = []
	for k in range(5):
		var a: float = float(k - 2) * TAU / 5.0
		tips.append(Vector2(mid_x + rad * wide_k * sin(a), mid_y - rad * cos(a)))

	for y in range(TILE):
		for x in range(TILE):
			var px: float = float(x) + 0.5
			var py: float = float(y) + 0.5
			# ЧЕРЕШОК — от нижнего края клетки до пластины. Он же держит нижнюю
			# середину клетки закрашенной: туда смотрит запасная точка разметки.
			if py >= base_y and absf(px - base_x) <= 1.0:
				img.set_pixel(ox + x, oy + y, Color(stem.r, stem.g, stem.b, 1.0))
				continue
			# Ширину меряем СЖАТОЙ меркой: пластина у разных листьев то шире, то
			# уже, а считать её всё равно удобнее круглой.
			var dx: float = (px - mid_x) / wide_k
			var dy: float = py - mid_y
			var far: float = sqrt(dx * dx + dy * dy)
			if far > rad * 1.2:
				continue
			var phi: float = atan2(dx, -dy)              # ноль — вверх клетки
			# Пять лопастей, вырез у черешка и зубчатый край — одной строкой.
			var edge: float = rad * (1.0 - cut * (1.0 - cos(5.0 * phi)) * 0.5)
			var down: float = PI - absf(phi)
			edge *= 1.0 - sinus * exp(-(down / 0.55) * (down / 0.55))
			edge *= 1.0 + tooth * sin(19.0 * phi + wob_a) \
				+ 0.06 * sin(3.0 * phi + wob_b)
			if far > edge:
				continue
			# Цвет: от глубокого у черешка к светлому у края, поверх жилки.
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
			# Каёмка: без неё два листа внахлёст сливаются в одно пятно.
			if far > edge - 1.3:
				col = col.darkened(0.30)
			img.set_pixel(ox + x, oy + y, Color(col.r, col.g, col.b, 1.0))


# Расстояние от точки до отрезка — для жилок.
func _to_line(p: Vector2, a: Vector2, b: Vector2) -> float:
	var way: Vector2 = b - a
	var len2: float = way.length_squared()
	if len2 < 0.000001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(way) / len2, 0.0, 1.0)
	return p.distance_to(a + way * t)


# ОБРАЗЕЦ ДЛЯ ТЕЛА — заглушка, пока он не нарисован.
#
# Это не куртинка в профиль, а мховая поверхность вплотную СВЕРХУ. Заполнено
# насквозь, без единой прозрачной точки: тело — цельная оболочка, и любая дырка
# в образце стала бы дыркой в кочке. Всё считается с заворотом через край
# клетки — образец обязан стыковаться сам с собой, он лежит на теле с повтором.
#
# КУСКИ, А НЕ КРУГЛЫЕ ПЯТНА (решение пользователя 2026-08-20). Прежде тут лежали
# круглые холмики, и цвет считался по расстоянию до ближайшей середины. Круг
# читается кругом, сколько его ни разбрасывай, и мох выходил гороховым. Теперь
# клетка ДЕЛИТСЯ на куски: точка достаётся тому пятну, чья мерка ближе. Границы
# получаются ломаными, а не дугами.
#
# Куски НЕРАВНЫ И НЕКРУГЛЫ, и это три разных приёма, ни один сам по себе не
# хватает:
#   * у каждого своя мерка — кто мерит щедрее, тот забирает больше места, и
#     площади выходят разными;
#   * мерка РАЗНАЯ ПО ДВУМ ОСЯМ и повёрнута — оттого кусок вытянут, и каждый в
#     свою сторону;
#   * сама точка перед замером чуть сдвигается — на столько же граница идёт
#     рваной, а не ровной чертой. Пиксельному мху рваная и нужна.
#
# ЦВЕТ СЛОЖНЕЕ, ЧЕМ СВЕТЛОЕ И ТЁМНОЕ: у каждого куска свой оттенок — светлее или
# темнее, теплее или холоднее; поверх лежит второй дележ, на несколько крупных
# пятен; поверх ещё крупинка на каждую точку. Три слоя, и ни одного правильного
# круга. Свет по карте нормалей идёт четвёртым, и лепит он те же куски.
const CLUMP_YOUNG: int = 24                 # кусков в клетке на первой ступени
const CLUMP_OLD: int = 36                   # ... и на девятой: мох густеет
const BLOTCH: int = 5                       # крупных пятен второго слоя
const CLUMP_TORN: float = 0.9               # на сколько точек рвётся граница
const CLUMP_LONG: float = 0.55              # насколько кусок бывает вытянут

func _paint_body_cell(img: Image, ox: int, oy: int, s: int, rng: RandomNumberGenerator) -> void:
	var age: float = float(s) / float(STAGES - 1)
	var body := Color(0.31, 0.44, 0.21).lerp(Color(0.27, 0.39, 0.18), age)
	var span: float = float(TILE)
	var half: float = span * 0.5

	# Мелкие куски: середина, мерка по двум осям, поворот и свой оттенок.
	var clumps: int = int(round(lerpf(float(CLUMP_YOUNG), float(CLUMP_OLD), age)))
	var cx := PackedFloat32Array()
	var cy := PackedFloat32Array()
	var ca := PackedFloat32Array()
	var cb := PackedFloat32Array()
	var cc := PackedFloat32Array()
	var cs := PackedFloat32Array()
	var c_lit := PackedFloat32Array()
	var c_warm := PackedFloat32Array()
	# РАЗМЕР КАЖДОМУ ЗАДАЁМ ПОИМЕННО. Сложить их в список и пройтись по нему
	# нельзя: набор чисел в Godot — величина, а не ссылка, и в списке лежала бы
	# его копия. Менялась бы копия, а исходный набор остался бы пустым.
	cx.resize(clumps)
	cy.resize(clumps)
	ca.resize(clumps)
	cb.resize(clumps)
	cc.resize(clumps)
	cs.resize(clumps)
	c_lit.resize(clumps)
	c_warm.resize(clumps)
	# Средняя мерка — чтобы куски покрывали клетку целиком: чем их больше, тем
	# каждый мельче. Считаем от площади, а не подбираем числом.
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

	# Крупные пятна: тот же дележ, только вширь и слабее по цвету.
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
			var big: int = 0
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
					big = i
			# ГЛУБИНА В СВОЁМ КУСКЕ, а не расстояние до середины: ноль на границе
			# с соседом, единица в самой сердцевине. Берём отношением, а не
			# разностью, — куски разной величины иначе мерились бы разной меркой.
			var edge: float = clampf((d2 / maxf(d1, 0.0001) - 1.0) / 0.5, 0.0, 1.0)
			var deep: float = edge * edge * (3.0 - 2.0 * edge)

			var lig: float = c_lit[win] + b_lit[big] \
				+ (_hash01(x * 31337 + y * 6151 + s * 13) - 0.5) * 0.07
			var col: Color = body.lightened(lig) if lig > 0.0 \
				else body.darkened(-lig)
			var warm: float = c_warm[win] + b_warm[big]
			col = Color(clampf(col.r + warm, 0.0, 1.0), col.g,
				clampf(col.b - warm, 0.0, 1.0))
			# Шов между кусками темнее — но чуть-чуть: холмы лепит свет, а не
			# нарисованная тень, и вторая тень поверх спорила бы с первой.
			col = col.darkened(0.13 * (1.0 - deep))
			img.set_pixel(ox + x, oy + y, Color(col.r, col.g, col.b, 1.0))
			# ВЫСОТУ ЗАПОМИНАЕМ ОТДЕЛЬНО ОТ ЦВЕТА. Считать её потом по яркости,
			# как считается у нарисованного от руки образца, тут уже нельзя:
			# цвет нарочно сложный, и яркость в нём — это оттенок куска, а вовсе
			# не его высота. А куски мы знаем точно, вот они.
			_body_hgt[base + y * TILE + x] = deep


# =============================================================================
#  РЕЛЬЕФ ТЕЛА — КАРТА НОРМАЛЕЙ, СНЯТАЯ С САМОЙ КАРТИНКИ
# =============================================================================
#
# Купол кочки гладкий, а холмики на образце НАРИСОВАНЫ светом и тенью. Оттого
# они одинаковы со всех сторон и при любом солнце, и вблизи тело читается
# наклейкой, натянутой на купол. Карта нормалей делает нарисованное настоящим:
# свет ложится по холмикам сам, макушка ловит солнце, стык уходит в тень, и при
# повороте камеры рисунок отзывается. Треугольников на это не уходит ни одного.
#
# ВЫСОТУ БЕРЁМ У ТОГО, КТО ЕЁ ЗНАЕТ. Свой образец мы рисуем сами и высоту его
# холмиков помним точно (`_body_hgt`) — её и берём. Раньше её считали по яркости
# рисунка, но цвет образца нарочно сделан ровным, и выжимать рельеф из ровного
# цвета уже нечем.
#
# А вот НАРИСОВАННЫЙ ОТ РУКИ столбец про свои высоты ничего не расскажет — там
# по-прежнему идём от яркости: светлое выше, тёмное ниже. Правило простое, и
# работу переделывать не придётся.
#
# КРУТИЗНУ НАЗНАЧАЕМ ПО ЗАМЕРЕННОМУ РАЗМАХУ, а не по типу величины — свои же
# грабли: «яркость от нуля до единицы» на деле держится в пятой части этого
# размаха, и число, поставленное на глаз, промахнулось бы в разы. Считаем уклоны
# по всему столбцу, берём девятую десятую и её приравниваем к `BUMP_STEEP`. Так
# и заглушка, и рисунок от руки дадут рельеф одной силы, каким бы бледным или
# контрастным ни был рисунок.
#
# Столбец меряем ЦЕЛИКОМ, а не каждый возраст порознь: с возрастом холмиков
# больше и они мельче, и это должно быть видно. Порознь все возрасты вышли бы
# одинаково рельефными.
const BUMP_STEEP: float = 0.9               # уклон самой крутой десятой, тангенсом
const BUMP_FLAT: float = 0.0005             # ниже этого считаем рисунок ровным

func _make_bumps(sheet: Texture2D) -> ImageTexture:
	var src: Image = sheet.get_image()
	if src.is_compressed():
		src.decompress()
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	var out := Image.create(src.get_width(), src.get_height(), false,
		Image.FORMAT_RGB8)
	# Ровно всюду, кроме сплошных столбцов: прочие клетки — вырезанные фигурки
	# для ворса, рельефа им не надо.
	out.fill(Color(0.5, 0.5, 1.0))
	# Телу высоту мы знаем точно, если образец рисовали сами. Коре — никогда: её
	# волокно и есть перепад высоты, и берётся он из яркости.
	var told: Vector2 = _bump_column(src, out, BODY_COL, _body_hgt)
	_bump_column(src, out, BARK_COL, PackedFloat32Array())
	_bump_spread = told.x
	_bump_tilt = told.y
	return ImageTexture.create_from_image(out)


# Рельеф одного столбца. Возвращает замеренный уклон и наибольший наклон.
func _bump_column(src: Image, out: Image, col: int,
		known: PackedFloat32Array) -> Vector2:
	var ox: int = col * TILE
	if ox + TILE > src.get_width():
		return Vector2.ZERO

	var hgt := PackedFloat32Array()
	if known.size() == TILE * TILE * STAGES:
		# Свой образец: высота известна точно, разглаживать нечего.
		hgt = known
	else:
		# Рисунок от руки: высота — это яркость, РАЗГЛАЖЕННАЯ по три точки. Без
		# разглаживания одинокая тёмная точка встаёт отвесной иглой.
		hgt.resize(TILE * TILE * STAGES)
		var raw := PackedFloat32Array()
		raw.resize(TILE * TILE)
		for s in range(STAGES):
			var oy: int = s * TILE
			for y in range(TILE):
				for x in range(TILE):
					var c: Color = src.get_pixel(ox + x, oy + y)
					raw[y * TILE + x] = (c.r + c.g + c.b) / 3.0
			for y in range(TILE):
				for x in range(TILE):
					var sum: float = 0.0
					for dy in range(-1, 2):
						for dx in range(-1, 2):
							sum += raw[_tile_at(x + dx, y + dy)] \
								* float((2 - absi(dx)) * (2 - absi(dy)))
					hgt[s * TILE * TILE + y * TILE + x] = sum / 16.0

	# Уклон — разностью соседей, с заворотом через край клетки: образец
	# стыкуется сам с собой, и рельеф на шве не должен ломаться.
	var gu := PackedFloat32Array()
	var gv := PackedFloat32Array()
	var mag := PackedFloat32Array()
	gu.resize(TILE * TILE * STAGES)
	gv.resize(TILE * TILE * STAGES)
	mag.resize(TILE * TILE * STAGES)
	for s in range(STAGES):
		var base: int = s * TILE * TILE
		for y in range(TILE):
			for x in range(TILE):
				var i: int = base + y * TILE + x
				var du: float = (hgt[base + _tile_at(x + 1, y)]
					- hgt[base + _tile_at(x - 1, y)]) * 0.5
				var dv: float = (hgt[base + _tile_at(x, y + 1)]
					- hgt[base + _tile_at(x, y - 1)]) * 0.5
				gu[i] = du
				gv[i] = dv
				mag[i] = sqrt(du * du + dv * dv)

	var ranked := mag.duplicate()
	ranked.sort()
	var spread: float = ranked[int(float(ranked.size()) * 0.9)]
	# Образец без перепадов — рельефа из него не выжать, и раздувать шум до
	# крутизны нельзя: выйдет крупа вместо холмиков.
	if spread < BUMP_FLAT:
		return Vector2.ZERO
	var lift: float = BUMP_STEEP / spread

	var tilt: float = 0.0
	for s in range(STAGES):
		var oy: int = s * TILE
		var base: int = s * TILE * TILE
		for y in range(TILE):
			for x in range(TILE):
				var i: int = base + y * TILE + x
				# Светлее — выше, значит нормаль валится ОТ макушки: со знаком
				# минус. Третья доля всегда единица до нормировки — поверхность
				# наклоняется, но не переворачивается.
				var n := Vector3(-gu[i] * lift, -gv[i] * lift, 1.0).normalized()
				tilt = maxf(tilt, rad_to_deg(acos(n.z)))
				out.set_pixel(ox + x, oy + y, Color(
					n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5))
	return Vector2(spread, tilt)


# Место в клетке с заворотом через край.
func _tile_at(x: int, y: int) -> int:
	return ((y + TILE) % TILE) * TILE + ((x + TILE) % TILE)


# Чем обошёлся рельеф: замеренный уклон образца и наибольший наклон в градусах.
func bump_stats() -> Vector2:
	return Vector2(_bump_spread, _bump_tilt)


# ЧТО ВЫРОСЛО У ЛИАНЫ. Только для самопроверки: плеть видно на кадре, а кадров я
# не сужу — значит, у неё должны быть числа.
#
# Главное здесь — «на круче»: лиане велено самой искать опору, и если она этого
# не делает, доля звеньев на крутом будет такой же, как доля крутого на острове,
# то есть маленькой. Это и есть проверка поведения, а не отрисовки.
func vine_stats() -> Dictionary:
	var links := 0
	var roots := 0
	var steep := 0.0
	var rock := 0
	var forks := 0
	var rise := 0.0
	var run := 0.0
	var deep := 0
	var tall := 0.0
	var longest := 0.0
	var spots: Array = []
	var order := 0
	var flying := 0
	var riding := 0
	var ends: Array = []
	var end_of := -1
	var thin := 1e9
	var fat := 0.0
	var leaves := 0
	var leaf_in := 0
	var hangs := 0
	var plaits := 0
	var plait := 0
	var drop := 0.0
	var sunk := -1e9
	var depth: Dictionary = {}
	var root_y := 0.0
	for pid in patches:
		var p: Dictionary = patches[pid]
		if not _is_stem(PlantsData.ITEMS[p["id"]]):
			continue
		links += 1
		spots.append(Vector3(p["pos"]))
		var from: int = int(p.get("from", -1))
		if not patches.has(from):
			roots += 1
			root_y = Vector3(p["pos"]).y
		# Перелезшие через старшую ветвь тоже не привязаны к земле, но это НЕ
		# вольная ветвь: считаем их порознь, иначе одно число прячет другое.
		if bool(p.get("rode", false)):
			riding += 1
		elif bool(p.get("air", false)):
			flying += 1
		# КОНЧИКИ — это и есть ответ на «все ветви сходятся в одну точку». Если
		# сходятся, кончики лежат кучей, и разброс между ними куда меньше ширины
		# всей заросли; расходятся — числа сближаются.
		if int(p.get("kids", 0)) == 0:
			ends.append(Vector3(p["pos"]))
		if int(p.get("kids", 0)) > 1:
			forks += 1
		order = maxi(order, int(p.get("order", 0)))
		# КРУТИЗНУ СКЛАДЫВАЕМ, А НЕ СЧИТАЕМ ПО ПОРОГУ. Свои же грабли: порог стоял
		# на 0.5, а вся крутизна на острове доходит до 0.41 — то есть он не мог
		# сработать НИКОГДА и честно показывал ноль при любом поведении. Средняя
		# же сравнивается со средней по острову, и порог для этого не нужен вовсе.
		steep += main.grid.steepness_of(int(p["cell"]))
		# А ГЛАВНЫЙ ОТВЕТ ВООБЩЕ БЕЗ МЕРОК: залезла лиана на камень или нет.
		# Порода у ячейки либо есть, либо нет, и спорить тут не о чем.
		if main.grid.stone_of(int(p["cell"])) > 0.02:
			rock += 1
		# Длина плети — сколько звеньев от корня. Считаем по цепочке вверх, с
		# памятью: без неё это работа в квадрате от длины.
		var walk: Array = []
		var at: int = pid
		var far: int = 0
		while patches.has(at) and not depth.has(at):
			walk.append(at)
			var up: int = int(patches[at].get("from", -1))
			if not patches.has(up):
				far = 0
				break
			at = up
		if depth.has(at):
			far = int(depth[at])
		for i in range(walk.size() - 1, -1, -1):
			far += 1
			depth[walk[i]] = far
		if int(depth.get(pid, 1)) > deep:
			deep = int(depth.get(pid, 1))
			end_of = pid
		var ring: Dictionary = _stem_ring(p, PlantsData.ITEMS[p["id"]])
		thin = minf(thin, float(ring["r"]))
		fat = maxf(fat, float(ring["r"]))
		# СВИСАЮЩИЕ ПЛЕТИ: сколько их всего и насколько длинной вышла самая
		# длинная. Первое звено плети помечено единицей — по нему их и считаем.
		var down: int = int(p.get("hangs", 0))
		if down > 0:
			hangs += 1
			plait = maxi(plait, down)
			if down == 1:
				plaits += 1
			# И НА СКОЛЬКО ОНА СВЕСИЛАСЬ — в метрах, а не в звеньях: длина звена
			# случайна, и «девять звеньев» само по себе ни о чём не говорит.
			# Идём вверх до начала своей плети — шагов там не больше её длины.
			var head: int = pid
			for _s in range(down):
				var above: int = int(patches[head].get("from", -1))
				if not patches.has(above) \
						or int(patches[above].get("hangs", 0)) == 0:
					break
				head = above
			drop = maxf(drop, Vector3(patches[head]["pos"]).y
				- Vector3(p["pos"]).y)
		# ЛИСТЬЯ. Раскладку спрашиваем у той же самой, что рисует, — иначе
		# проверка мерила бы не то, что видно на кадре.
		#
		# И ГЛАВНЫЙ СТОРОЖ ПО НИМ — сколько листьев вошло кончиком В ПОРОДУ. Лист
		# отходит от опоры вслепую, по нормали земли под звеном, и на вогнутом
		# месте эта нормаль врёт: рядом стенка, а лист уходит в неё. Знак вылета
		# тут такой же честный, как у колена.
		var back: Dictionary = ring
		if patches.has(from):
			back = _stem_ring(patches[from], PlantsData.ITEMS[p["id"]])
		var here: Array = _leaf_plan(p, PlantsData.ITEMS[p["id"]], ring, back)
		leaves += here.size()
		for leaf in here:
			var tip: Vector3 = Vector3(leaf["at"]) \
				+ Vector3(leaf["along"]) * float(leaf["long"])
			var land: Dictionary = main.grid.surface_near(tip)
			if land.is_empty():
				continue
			if (tip - Vector3(land["pos"])).dot(land["nrm"]) < -0.02:
				leaf_in += 1
		if patches.has(from):
			var d: Vector3 = Vector3(p["pos"]) - Vector3(patches[from]["pos"])
			rise += d.y
			run += d.length()
			# НЕ УШЛО ЛИ КОЛЕНО ПОД ЗЕМЛЮ. Колено идёт по прямой, а земля между
			# звеньями выгнута — середина хорды и ныряет. Меряем в самой опасной
			# точке, посередине, и по НИЖНЕЙ стороне трубки: она уходит под землю
			# первой.
			#
			# ГРАБЛИ, дважды подряд. Сперва мерили «ближе ли точка к поверхности,
			# чем радиус трубки» — у вогнутого угла трубка законно касается стенок,
			# и мерка кричала о семи сантиметрах там, где всё в порядке. Потом
			# мерили по касательным плоскостям обоих звеньев — а эта, наоборот,
			# ПРОЩАЛА вогнутые места, где хорда как раз и режет породу.
			#
			# Честно только одно: ЗНАК ВЫЛЕТА. Отрицательный — точка внутри камня,
			# и спорить не о чем. Меряем по всей длине колена, а не в середине:
			# резать породу оно может где угодно.
			var up_ring: Dictionary = _stem_ring(patches[from],
				PlantsData.ITEMS[p["id"]])
			for k in [0.2, 0.4, 0.6, 0.8]:
				var probe: Vector3 = Vector3(up_ring["at"]).lerp(Vector3(ring["at"]), k)
				var land: Dictionary = main.grid.surface_near(probe)
				if land.is_empty():
					continue
				sunk = maxf(sunk, -(probe - Vector3(land["pos"])).dot(land["nrm"]))
			# САМОЕ ДЛИННОЕ КОЛЕНО — сторож растянутых палок. При росте оно не
			# может выйти за шаг отростка; выйдет — значит звенья разъехались при
			# правке рельефа, и цепь пора рвать.
			longest = maxf(longest, d.length())
	# НАСКОЛЬКО ПОДНЯЛАСЬ НАД КОРНЕМ — второй заход по уже собранным звеньям, зато
	# число говорящее. Средний подъём на звено врёт: вверх и вниз в нём гасят друг
	# друга, и у лианы, честно залезшей и спустившейся, выходит ровный ноль.
	for pid in patches:
		var p: Dictionary = patches[pid]
		if _is_stem(PlantsData.ITEMS[p["id"]]):
			tall = maxf(tall, Vector3(p["pos"]).y - root_y)
	# ШИРИНА ЗАРОСЛИ — сторож тесноты. Побегам велено расходиться, и если они всё
	# равно идут пучком, ширина будет чуть больше шага звена, сколько бы их ни
	# было. Меряем по земле, без высоты: вверх лиана и должна тянуться.
	var wide := 0.0
	for i in range(spots.size()):
		for j in range(i + 1, spots.size()):
			var a: Vector3 = spots[i]
			var b: Vector3 = spots[j]
			wide = maxf(wide, Vector2(a.x - b.x, a.z - b.z).length())
	# НАСКОЛЬКО ПЛЕТЬ ПРЯМАЯ. Идём от самого дальнего кончика к корню и делим
	# расстояние по прямой на пройденный путь. Единица — струна, около нуля —
	# клубок: на ровном месте лоза сворачивалась в моток, и вот это его и ловит.
	var walk_len := 0.0
	var walk_far := 0.0
	if patches.has(end_of):
		var at: int = end_of
		var head: Vector3 = Vector3(patches[at]["pos"])
		for _step in range(400):
			var up: int = int(patches[at].get("from", -1))
			if not patches.has(up):
				break
			walk_len += Vector3(patches[at]["pos"]).distance_to(patches[up]["pos"])
			at = up
		walk_far = head.distance_to(patches[at]["pos"])

	# САМЫЙ КРУТОЙ ИЗЛОМ — сторож переломов. Меряем угол между тем, откуда звено
	# пришло, и тем, куда ушло: сторож у самой мерки, которой этот излом и
	# ограничен.
	var sharp := 0.0
	for pid in patches:
		var p: Dictionary = patches[pid]
		if not _is_stem(PlantsData.ITEMS[p["id"]]):
			continue
		var up: int = int(p.get("from", -1))
		if not patches.has(up):
			continue
		var top: int = int(patches[up].get("from", -1))
		if not patches.has(top):
			continue
		var went: Vector3 = Vector3(p["pos"]) - Vector3(patches[up]["pos"])
		var came: Vector3 = Vector3(patches[up]["pos"]) - Vector3(patches[top]["pos"])
		if went.length_squared() < 0.000001 or came.length_squared() < 0.000001:
			continue
		sharp = maxf(sharp, rad_to_deg(came.angle_to(went)))

	# ЗАКРУТКА — сторож МОТКА, и это не то же самое, что клубок.
	#
	# Клубок ловится теснотой: много звеньев в одном шаре. А моток — это побег,
	# который поворачивает ВСЁ ВРЕМЯ В ОДНУ СТОРОНУ и сматывается спиралью; звенья
	# при этом могут лежать просторно, и теснота его не увидит. Пользователь
	# показала такой на кадре, а все числа тогда молчали.
	#
	# Мерим ПОВОРОТ СО ЗНАКОМ вокруг нормали земли, сложенный по последним
	# `COIL_BACK` звеньям. Полный оборот — 360°: столько накопить можно, только
	# заворачивая в одну сторону.
	var coil := 0.0
	var coiled := 0
	for pid in patches:
		if not _is_stem(PlantsData.ITEMS[patches[pid]["id"]]):
			continue
		var spin := 0.0
		var at: int = pid
		var was_dir := Vector3.ZERO
		for _i in range(COIL_BACK):
			var up: int = int(patches[at].get("from", -1))
			if not patches.has(up):
				break
			var step: Vector3 = Vector3(patches[at]["pos"]) \
				- Vector3(patches[up]["pos"])
			if step.length_squared() < 0.000001:
				break
			step = step.normalized()
			if was_dir != Vector3.ZERO:
				var up_nrm: Vector3 = patches[at]["nrm"]
				spin += atan2(step.cross(was_dir).dot(up_nrm), step.dot(was_dir))
			was_dir = step
			at = up
		coil = maxf(coil, absf(spin))
		if absf(spin) > deg_to_rad(300.0):
			coiled += 1

	# КЛУБОК — это просто много звеньев в одном месте. На вершине глыбы лиану
	# водило кругами, и никакая средняя ширина этого не показывала: заросль-то
	# широкая, а моток в ней локальный. Считаем, сколько звеньев набилось в шар
	# радиусом в треть метра вокруг самого тесного из них.
	var knot := 0
	for i in range(spots.size()):
		var near_here := 0
		for j in range(spots.size()):
			if Vector3(spots[i]).distance_to(spots[j]) < 0.3:
				near_here += 1
		knot = maxi(knot, near_here)

	var apart_ends := 0.0
	for i in range(ends.size()):
		for j in range(i + 1, ends.size()):
			var e1: Vector3 = ends[i]
			var e2: Vector3 = ends[j]
			apart_ends = maxf(apart_ends, Vector2(e1.x - e2.x, e1.z - e2.z).length())
	# СКОЛЬКО ЗВЕНЬЕВ У САМОЙ БЕДНОЙ ЛИАНЫ. Средние числа прячут застрявшую: одна
	# плеть в полсотни звеньев и три по пять дают на глаз то же «в среднем
	# четырнадцать», а на кадре это совсем разные вещи.
	var mine: Dictionary = {}
	for pid in patches:
		if not _is_stem(PlantsData.ITEMS[patches[pid]["id"]]):
			continue
		var at: int = pid
		for _step in range(400):
			var up: int = int(patches[at].get("from", -1))
			if not patches.has(up):
				break
			at = up
		mine[at] = int(mine.get(at, 0)) + 1
	var least: int = 1 << 30
	var most := 0
	for r in mine:
		least = mini(least, int(mine[r]))
		most = maxi(most, int(mine[r]))
	return {"links": links, "roots": roots, "steep": steep, "rock": rock,
		"forks": forks, "deep": deep, "rise": rise, "run": run, "tall": tall,
		"long": longest, "cap": _stem_max(PlantsData.ITEMS["vine"]), "wide": wide,
		"order": order,
		"least": 0 if mine.is_empty() else least, "most": most,
		"tries": _sprout_try, "wins": _sprout_win, "air": flying,
		"tips": ends.size(), "tips_wide": apart_ends,
		"straight": walk_far / maxf(walk_len, 0.0001),
		"thin": 0.0 if links == 0 else thin, "fat": fat,
		"sunk": 0.0 if links == 0 else sunk, "knot": knot, "sharp": sharp,
		"rode": riding, "leaves": leaves, "leaf_in": leaf_in,
		"coil": rad_to_deg(coil), "coiled": coiled,
		"hangs": hangs, "plaits": plaits, "plait": plait, "drop": drop,
		"hang_try": _hang_try, "hang_edge": _hang_edge, "hang_win": _hang_win,
		"hang_deep": _hang_deep}


func _make_blade_texture() -> ImageTexture:
	var img := Image.create(TILE * COLS, TILE * STAGES, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 913377
	_body_hgt.resize(TILE * TILE * STAGES)
	for s in range(STAGES):
		_paint_body_cell(img, BODY_COL * TILE, s * TILE, s, rng)
		_paint_bark_cell(img, BARK_COL * TILE, s * TILE, s, rng)
		for k in range(LEAF_KINDS):
			_paint_leaf_cell(img, (LEAF_COL + k) * TILE, s * TILE, s, k, rng)

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
	# Посаженная игроком — САМАЯ КРУПНАЯ в своём пятне: от неё размер и убывает
	# к краю. Не ровно предельная, чтобы два пятна рядом различались.
	var bulk: float = _rng.randf_range(BULK_MAX - 0.2, BULK_MAX)
	if _crowded(spot["pos"], bulk):
		return -1
	return _create(spot, id, 0.15, bulk)


# ПЕРЕСОБРАТЬ ДЕТЕЙ. Колено лианы рисуется в куске РЕБЁНКА, а не родителя: сдвинь
# или снеси родителя молча — и трубка останется тянуться к прежнему месту до
# следующей пересборки чужого куска, то есть, может быть, вечно.
#
# Детей ищем по соседним ячейкам, а не по списку: список пришлось бы держать в
# порядке при каждой гибели, а звено дальше шага решётки от родителя не отходит.
#
# `orphan` — осиротить: родителя больше не будет, ребёнок сам становится корнем.
func _touch_kids(pid: int, orphan: bool = false, snap: float = 0.0) -> void:
	if not patches.has(pid):
		return
	var here: Vector3 = patches[pid]["pos"]
	var node: Vector3i = main.grid.node_of(int(patches[pid]["cell"]))
	var torn: Array = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var c: int = main.grid.node_seed(node + Vector3i(dx, dy, dz))
				if c < 0:
					continue
				for kid in by_cell.get(c, {}):
					if not patches.has(kid):
						continue
					if int(patches[kid].get("from", -1)) != pid:
						continue
					if orphan:
						patches[kid]["from"] = -1
					# И РВЁМ РЕБЁНКА, КОТОРОГО РАСТЯНУЛО. Разрыв по своему
					# родителю звено проверяет само, но при правке рельефа
					# переехать может ЛЮБОЙ конец колена: сдвинули родителя, а
					# ребёнок лежал в стороне от правки — и его никто не
					# спрашивал. На кадре это два разных изъяна сразу: кусок
					# лозы, стоящий сам по себе неведомо откуда, и плоский срез
					# на том конце, где колено оборвалось.
					elif snap > 0.0 and here.distance_to(patches[kid]["pos"]) > snap:
						torn.append(kid)
					_dirty[int(patches[kid]["cell"])] = true
	for kid in torn:
		_unlink(kid)         # и родителю вернуть счёт детей: он снова кончик


# НОША И НАПРАВЛЕНИЕ ВЫХОДА — ведутся при рождении звена.
#
# НОША (`load`) — сколько звеньев висит ниже по течению. Толщина стебля берётся
# от неё, и считать её на каждой отрисовке было бы обходом всего дерева; проще
# прибавлять единицу всем предкам, когда звено родилось. Цепь длиной в полтораста
# звеньев — это полтораста шагов на рождение, и всё.
#
# НАПРАВЛЕНИЕ ВЫХОДА (`out`) нужно кольцу: оно стоит по биссектрисе входа и
# выхода, иначе на повороте срез сплющивается. У звена с двумя детьми берём
# среднее — точнее одного из них и заметно проще списка детей.
func _stem_born(pid: int, from: int) -> void:
	var way: Vector3 = Vector3(patches[pid]["pos"]) - Vector3(patches[from]["pos"])
	if way.length_squared() > 0.000001:
		var had: Vector3 = patches[from].get("out", Vector3.ZERO)
		patches[from]["out"] = (had + way.normalized()).normalized()
	# И ПОКОЛЕНИЯ, КОТОРЫЕ ПРЕДКИ НА СЕБЕ ДЕРЖАТ. `kidorder` — самый дальний
	# порядок ветвления ниже по течению; по разнице с собственным порядком лист и
	# растёт (`leaf_gen`). Ведём при рождении, тем же обходом, что и ношу.
	#
	# ПРИ ГИБЕЛИ ЭТО ЧИСЛО НЕ УБАВЛЯЕТСЯ: убыль потребовала бы обойти всех детей
	# у каждого предка, а не одну цепочку. Отмерла ветвь — предки помнят её
	# порядок, и листья у них остаются чуть крупнее, чем следовало. Цена этому —
	# несколько процентов размера у самого низа, и она того не стоит.
	# ЗАКРУТКА — СКОЛЬКО ПОБЕГ УЖЕ НАКРУТИЛ В ОДНУ СТОРОНУ.
	#
	# Пользователь показала на кадре моток на боку глыбы, а числа тогда молчали:
	# теснота его не видит (звенья лежат просторно), прямизна тоже (моток —
	# участок, а мерят всю плеть). Замерено потом особой меркой: двенадцать
	# звеньев подряд давали 357°, то есть полный виток.
	#
	# Ведём поворот СО ЗНАКОМ вокруг нормали земли, с забыванием (`SPIN_FADE`):
	# память выходит примерно на семь звеньев, а числа не копятся без конца.
	# Читает это `_one_sprout` — и разворачивает побег, если тот крутит слишком
	# долго в одну сторону.
	var spin: float = 0.0
	var gran: int = int(patches[from].get("from", -1))
	if patches.has(gran) and way.length_squared() > 0.000001:
		var was: Vector3 = Vector3(patches[from]["pos"]) \
			- Vector3(patches[gran]["pos"])
		if was.length_squared() > 0.000001:
			var a: Vector3 = was.normalized()
			var b: Vector3 = way.normalized()
			var nrm: Vector3 = patches[pid]["nrm"]
			spin = atan2(a.cross(b).dot(nrm), a.dot(b))
	patches[pid]["spin"] = float(patches[from].get("spin", 0.0)) * SPIN_FADE + spin

	var deep: int = int(patches[pid].get("order", 0))
	var at: int = from
	for _step in range(400):
		patches[at]["load"] = int(patches[at].get("load", 0)) + 1
		if int(patches[at].get("kidorder", 0)) < deep:
			patches[at]["kidorder"] = deep
		_dirty[int(patches[at]["cell"])] = true
		at = int(patches[at].get("from", -1))
		if not patches.has(at):
			return


# ОТВЯЗАТЬ ЗВЕНО ОТ РОДИТЕЛЯ, не забыв убавить у того счёт детей.
#
# ГРАБЛИ, и крупные: счёт детей только рос. Свободно растёт лишь кончик — у него
# детей ноль, — а стоило кончику погибнуть (правка земли под ним, снос), и у его
# родителя счётчик оставался единицей. Родитель навсегда числился серединой
# плети и пробовал расти уже не в полную силу, а по редкой частоте ветвления;
# дальше он взрослел, срок ветвления выходил, и ЛИАНА ОСТАНАВЛИВАЛАСЬ НАВСЕГДА.
# На кадре это два коротких обрубка, которые не растут, сколько ни жди.
func _unlink(pid: int) -> void:
	var up: int = int(patches[pid].get("from", -1))
	patches[pid]["from"] = -1
	if not patches.has(up):
		return
	patches[up]["kids"] = maxi(0, int(patches[up].get("kids", 0)) - 1)
	_dirty[int(patches[up]["cell"])] = true
	# И НОШУ У ПРЕДКОВ УБАВЛЯЕМ — на всё, что ушло вместе с этим звеном. Иначе
	# основание навсегда останется толстым по давно оторванной ветви.
	var gone: int = 1 + int(patches[pid].get("load", 0))
	var at: int = up
	for _step in range(400):
		patches[at]["load"] = maxi(0, int(patches[at].get("load", 0)) - gone)
		_dirty[int(patches[at]["cell"])] = true
		at = int(patches[at].get("from", -1))
		if not patches.has(at):
			return


func remove_at(pid: int) -> void:
	if not patches.has(pid):
		return
	_unlink(pid)
	var cell: int = int(patches[pid]["cell"])
	_touch_kids(pid, true)
	patches.erase(pid)
	if by_cell.has(cell):
		by_cell[cell].erase(pid)
	_dirty[cell] = true
	_flush()


# Что растёт ближе всего к точке — по нему работает снятие под курсором.
# СНЕСТИ ВЕСЬ САД РАЗОМ. Проверкам случается расчищать место целиком, и
# поштучный снос для этого не годится: каждая гибель зовёт `_flush`, а тот
# обходит ВЕСЬ сад — работа выходит в квадрате от числа растений. На полутора
# тысячах звеньев это минуты чистого ожидания.
func clear_all() -> void:
	patches.clear()
	by_cell.clear()
	_dirty.clear()
	for cell in cell_nodes:
		cell_nodes[cell].queue_free()
	cell_nodes.clear()


func nearest_to(pos: Vector3, radius: float) -> int:
	var best := -1
	var best_d: float = radius * radius
	for pid in patches:
		var d: float = pos.distance_squared_to(patches[pid]["pos"])
		if d < best_d:
			best_d = d
			best = pid
	return best


# РАСТЕНИЕ-НИТЬ: рисуется стеблем от родителя, а не кочкой. Отличие проходит по
# всему файлу — и в рождении, и в росте, и в отрисовке, — поэтому спрашиваем его
# в одном месте, а не сверяем строку «vine» по десятку мест.
static func _is_stem(def: Dictionary) -> bool:
	return String(def.get("shape", "")) == "vine"


# ЕСТЬ ЛИ РАЗВИЛКА ПОБЛИЗОСТИ ВВЕРХ ПО ЦЕПИ. Идём от звена к родителю столько
# шагов, сколько велено, и если по дороге попалась развилка — этому звену
# ветвиться рано.
func _fork_near(pid: int, gap: int) -> bool:
	var at: int = pid
	for _i in range(gap):
		at = int(patches[at].get("from", -1))
		if not patches.has(at):
			return false
		if int(patches[at].get("kids", 0)) > 1:
			return true
	return false


# НРАВ ПОБЕГА — своё у каждой ветви, а не одно на всю лиану.
#
# ГРАБЛИ, видные только на кадре: пока тяга вверх и тяга к опоре были одни на
# всех, каждый побег вёл себя ровно как соседний — и все они сходились в одну и ту
# же верхнюю точку глыбы, как связанный сноп. Общий рисунок при этом верный,
# сильна была одинаковость.
#
# Продолжение кончика НАСЛЕДУЕТ нрав родителя, чуть сбитый; боковой побег берёт
# свой, заново. Оттого плеть идёт цельной линией, а новая ветвь может оказаться
# и ползучей (вверх не тянется вовсе), и вольной (отлипает от камня в воздух).
func _stem_traits(from: int, def: Dictionary) -> Dictionary:
	var fresh: bool = true
	if patches.has(from):
		fresh = int(patches[from].get("kids", 0)) > 0    # это уже боковой побег
	if not fresh:
		var up: Dictionary = patches[from]
		var drift: float = float(def.get("trait_drift", 0.08))
		return {
			"climb_k": clampf(float(up.get("climb_k", 1.0))
				+ _rng.randf_range(-drift, drift), 0.0, 2.0),
			"pull_k": clampf(float(up.get("pull_k", 1.0))
				+ _rng.randf_range(-drift, drift), 0.0, 2.0),
			"free_k": clampf(float(up.get("free_k", 0.0))
				+ _rng.randf_range(-drift, drift), 0.0, 1.0),
			# ИНДЕКС ДЕЛЕНИЯ НЕ УБЫВАЕТ (решение пользователя 2026-08-20). У
			# побега своя охота ветвиться, и при делении она передаётся ребёнку
			# как есть, а не половинится: иначе дальние порядки перестают
			# ветвиться вовсе и заросль выходит редкой.
			"fork_k": float(up.get("fork_k", 1.0)),
		}
	var climb: Array = def.get("climb_vary", [1.0, 1.0])
	var pull: Array = def.get("pull_vary", [1.0, 1.0])
	var free: Array = def.get("free_vary", [0.0, 0.0])
	var fork: Array = def.get("fork_vary", [1.0, 1.0])
	# Боковой побег берёт свой нрав заново — КРОМЕ индекса деления: тот идёт от
	# родителя без убыли, иначе ветвление глохнет вглубь дерева.
	var keep: float = float(patches[from].get("fork_k", 1.0)) \
		if patches.has(from) else _rng.randf_range(float(fork[0]), float(fork[1]))
	return {
		"climb_k": _rng.randf_range(float(climb[0]), float(climb[1])),
		"pull_k": _rng.randf_range(float(pull[0]), float(pull[1])),
		"free_k": _rng.randf_range(float(free[0]), float(free[1])),
		"fork_k": keep,
	}


# Какого порядка будет отросток от этого звена. Спрашивать надо ДО того, как у
# родителя прибавится ребёнок: первый — это продолжение кончика, второй и дальше
# — уже боковой побег.
func _order_after(from: int) -> int:
	if not patches.has(from):
		return 0
	var up: int = int(patches[from].get("order", 0))
	return up + 1 if int(patches[from].get("kids", 0)) > 0 else up


func _create(spot: Dictionary, id: String, maturity: float, bulk: float,
		from: int = -1) -> int:
	var cell: int = int(spot["cell"])
	var salt: int = _next * 7919 + int(absf(spot["pos"].x) * 131)
	var def: Dictionary = PlantsData.ITEMS[id]
	var body: Dictionary
	if _is_stem(def):
		# СТЕБЛЮ КОЧКА НЕ НУЖНА. Тело — это купол, севший на землю ободом; у
		# лианы же звено рисуется трубкой до родителя, и обод ему не нужен.
		# Оставляем ту же горстку полей, что читают общие места (`up`, `rise`), —
		# иначе пришлось бы обвешивать проверками каждое из них.
		body = {"up": spot["nrm"], "rise": 1.0, "rim": [],
			"age": _hash01(salt + 577), "shade": 0.92 + 0.14 * _hash01(salt + 1223),
			"warp": Vector2(_hash01(salt + 2683), _hash01(salt + 3407))}
	else:
		# Тело считаем ДО рождения: не нашлось земли под ободом — кочки не будет
		# вовсе, и номер зря не расходуется.
		body = _make_cushion(spot, def, salt, bulk)
		if body.is_empty():
			return -1
	var pid := _next
	_next += 1
	patches[pid] = {
		"pos": spot["pos"], "nrm": spot["nrm"], "id": id,
		"m": maturity, "step": -1, "cell": cell, "salt": salt,
		"bulk": bulk, "body": body, "near": [],
		# ОТ КОГО ОТРОСЛО. Из этой одной записи и получается нить: у мха она
		# просто не используется, у лианы по ней тянется стебель.
		#
		# И КАКОГО ОНО ПОРЯДКА. Продолжение кончика наследует порядок родителя, а
		# боковой побег — на единицу больше. По порядку ветви и расходятся: чем
		# дальше от главной плети, тем шире надо расти, иначе дальние порядки
		# сбиваются в метлу у самой опоры.
		"from": from, "kids": 0, "order": _order_after(from),
	}
	if _is_stem(def):
		patches[pid].merge(_stem_traits(from, def))
		# ВИСИТ ЛИ ЗВЕНО В ВОЗДУХЕ и сколько таких подряд. Вольная ветвь отлипает
		# от камня, но не может лететь бесконечно: счёт подряд идущих висящих
		# звеньев её и останавливает.
		var air: bool = bool(spot.get("air", false))
		patches[pid]["air"] = air
		patches[pid]["rode"] = bool(spot.get("rode", false))
		patches[pid]["airlen"] = (int(patches[from].get("airlen", 0)) + 1 \
			if air and patches.has(from) else (1 if air else 0))
		# КОТОРОЕ ОНО ПО СЧЁТУ ОТ КОРНЯ. По этому числу листья садятся ПО СПИРАЛИ:
		# каждый следующий отвёрнут от предыдущего на постоянный угол, как оно и
		# растёт у живой лозы. Ставь мы лист наугад — спираль читалась бы
		# россыпью, а её на побеге видно.
		patches[pid]["rank"] = (int(patches[from].get("rank", 0)) + 1 \
			if patches.has(from) else 0)
		# Самый дальний порядок ветвления ниже по течению. У новорождённого это он
		# сам; предкам его разносит `_stem_born`.
		patches[pid]["kidorder"] = int(patches[pid]["order"])
		# СВИСАЮЩАЯ ПЛЕТЬ: которое звено уже свесилось и сколько их всего
		# положено. Длина отмеряется при перевале через кромку и дальше
		# наследуется — иначе каждое звено мерило бы плеть заново.
		if int(spot.get("hangs", 0)) > 0:
			patches[pid]["hangs"] = int(spot["hangs"])
			patches[pid]["hang_max"] = int(spot.get("hang_max", 1))
	if from >= 0 and patches.has(from):
		patches[from]["kids"] = int(patches[from]["kids"]) + 1
		# Родитель перерисовывается вместе с ребёнком: у стебля они делят стык.
		_dirty[int(patches[from]["cell"])] = true
		if _is_stem(def):
			_stem_born(pid, from)
	if not by_cell.has(cell):
		by_cell[cell] = {}
	by_cell[cell][pid] = true
	_link_near(pid)
	_dirty[cell] = true
	return pid


# С КЕМ КОЧКА МОЖЕТ СОМКНУТЬСЯ. Список считается ОДИН РАЗ, при рождении: слияние
# спрашивает соседей на каждой перестройке, а перебирать ради этого сад — работа
# в квадрате от числа кочек.
#
# Связь двусторонняя: новорождённая записывает соседей себе и себя — им. Список
# не чистится при гибели: пропавший номер отсеивается при чтении, а чистка стоила
# бы обхода всех, кто на него ссылался.
func _link_near(pid: int) -> void:
	var p: Dictionary = patches[pid]
	# СТЕБЕЛЬ НИ С КЕМ НЕ СРАСТАЕТСЯ. Список соседей нужен для слияния куполов, а
	# у лианы купола нет вовсе; попади она в чужой список — мох стал бы считать
	# её бугром и всплывать над ней.
	if _is_stem(PlantsData.ITEMS[p["id"]]):
		return
	var pos: Vector3 = p["pos"]
	# Дальше двух взрослых радиусов купола не встретятся никогда.
	var far: float = _patch_span(1.0, BULK_MAX) * 2.0
	var node: Vector3i = main.grid.node_of(int(p["cell"]))
	var list: Array = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var c: int = main.grid.node_seed(node + Vector3i(dx, dy, dz))
				if c < 0:
					continue
				for other in by_cell.get(c, {}):
					if other == pid or not patches.has(other):
						continue
					# Срастаются только СВОИ С СВОИМИ: поле складывается из чужих
					# бугров, а бугор чужого вида — это уже не тот же ковёр.
					if String(patches[other]["id"]) != String(p["id"]):
						continue
					if pos.distance_to(patches[other]["pos"]) > far:
						continue
					list.append(other)
					var theirs: Array = patches[other]["near"]
					if not theirs.has(pid):
						theirs.append(pid)
	p["near"] = list


# Есть ли кто-то вплотную. Смотрим ТОЛЬКО ячейку под точкой и её соседей по
# решётке: перебор всего сада на каждый отросток — это работа в квадрате от
# числа кочек, и заросшая карта встала бы колом.
func _crowded(pos: Vector3, bulk: float) -> bool:
	var home: int = main.grid.cell_at(pos)
	if home < 0:
		return false
	# Место требуется ПО СЕБЕ И ПО СОСЕДУ: у крупной кочки локоть шире. Меряем по
	# взрослым радиусам, а не по нынешним, — иначе на молодняке заросль сбивалась
	# бы в кучу, а к старости кочки лезли бы одна из другой.
	var mine: float = _patch_span(1.0, bulk)
	var node: Vector3i = main.grid.node_of(home)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var c: int = main.grid.node_seed(node + Vector3i(dx, dy, dz))
				if c < 0:
					continue
				for pid in by_cell.get(c, {}):
					# Зазор ГУЛЯЕТ: без этого выходит правильная упаковка — та же
					# решётка, только с кружками разного калибра.
					var room: float = SIT_APART * (mine
						+ _patch_span(1.0, float(patches[pid]["bulk"]))) \
						* _rng.randf_range(1.0 - SIT_JITTER, 1.0 + SIT_JITTER)
					if pos.distance_squared_to(patches[pid]["pos"]) < room * room:
						return true
	return false


# =============================================================================
#  Рост и расползание
# =============================================================================
func _tick(dt: float) -> void:
	var sprouts: Array = []
	var fallen: Array = []
	for pid in patches:
		var p: Dictionary = patches[pid]
		var def: Dictionary = PlantsData.ITEMS[p["id"]]
		# ВИСЯЩЕМУ ЗВЕНУ БЕЗ РОДИТЕЛЯ ДЕРЖАТЬСЯ НЕ НА ЧЕМ. Родитель мог погибнуть
		# или оторваться — тогда кусок остаётся парить сам по себе. Снимаем не на
		# месте, а списком: гибель звена трогает соседей, а мы посреди обхода.
		if bool(p.get("air", false)) and not patches.has(int(p.get("from", -1))):
			fallen.append(pid)
			continue
		var rate: float = def["grow_rate"] * (1.0 + def["shade_love"] * _shade(p))
		# В складке растению вольготнее: туда наносит землю и дольше держится
		# сырость. Величину складки считает сама сетка.
		var fold: float = maxf(0.0, main.grid.cavity_of(int(p["cell"])))
		rate *= 1.0 + def["joint_love"] * fold
		# Ступень тем длиннее, чем растение взрослее.
		rate /= STAGE_COST[clampi(int(p["m"] * float(STAGES)), 0, STAGES - 1)]
		# НА РОВНОМ РОСТ МЕДЛЕННЕЕ — у тех, кому это записано. Лиане подпоркой
		# служит крутизна, и без неё она должна не глохнуть совсем, а тянуться
		# нехотя. Множитель идёт и в зрелость, и в частоту отростков: замедли одну
		# зрелость — и плеть поползла бы с прежней скоростью, только с молодыми
		# звеньями.
		#
		# РОВНОСТЬ БЕРЁМ У НОРМАЛИ, А НЕ У КРУТИЗНЫ ПОЛЯ. Крутизна на этом острове
		# доходит всего до 0.41 и в среднем держится около 0.19 и на земле, и на
		# камне: считай по ней — и «вдвое медленнее на ровном» превратится в
		# «на сорок процентов медленнее везде». Нормаль же говорит прямо: смотрит
		# вверх — лежим на ровном, смотрит вбок — стоим на стене.
		var slow: float = 1.0
		if def.has("flat_slow"):
			var tilt: float = 1.0 - clampf(Vector3(p["nrm"]).y, 0.0, 1.0)
			slow = lerpf(float(def["flat_slow"]), 1.0, tilt)
		p["m"] = minf(1.0, p["m"] + rate * slow * dt)

		# РАСТЁТ ТОЛЬКО КОНЧИК, а звено с отростком даёт второй редко. Без этого
		# «сдержанное ветвление» не выйдет ничем: у мха отросток даёт каждая
		# кочка, и лиана расплылась бы тем же ковром, только вытянутым.
		var chance: float = float(def["spread_rate"])
		if def.has("branch"):
			var kids: int = int(p.get("kids", 0))
			if kids >= int(def.get("branch_max", 2)):
				chance = 0.0
			elif kids > 0:
				# БОКОВОЙ ПОБЕГ ИДЁТ ТОЛЬКО ИЗ МОЛОДОГО ЗВЕНА. Без этого срока
				# редкость ветвления обманчива: попытки у старого звена не
				# кончаются никогда, и рано или поздно ветвится КАЖДОЕ. Замерено:
				# шесть развилок на тридцать шесть звеньев — это уже не
				# сдержанно. У живой лозы новый побег тоже идёт по молодому.
				#
				# И РАЗВИЛКИ ДЕРЖАТСЯ ДРУГ ОТ ДРУГА ПОДАЛЬШЕ (`fork_gap`). Одной
				# частоты мало: она делит развилки поровну между звеньями, а
				# метлу делает не число, а их КУЧНОСТЬ — три подряд на одном
				# участке видно метлой, три на разных концах плети не видно вовсе.
				if float(p["m"]) > float(def.get("branch_until", 0.7)) \
						or _fork_near(pid, int(def.get("fork_gap", 0))):
					chance = 0.0
				else:
					# ДАЛЬНИМ ПОКОЛЕНИЯМ — ПРИБАВКА (решение пользователя
					# 2026-08-20): за каждое поколение сверх `fork_gain_from`
					# охота ветвиться растёт на `fork_gain`. Иначе тонкие ветви
					# идут голыми прутьями, а у живой лозы всё наоборот — чем
					# дальше от ствола, тем чаще деление.
					var late: int = maxi(0, int(p.get("order", 0))
						- int(def.get("fork_gain_from", 5)))
					chance *= float(def["branch"]) * float(p.get("fork_k", 1.0)) \
						* (1.0 + float(late) * float(def.get("fork_gain", 0.0)))
		# ПЛЕТЬ СВЕСИЛАСЬ НА ВСЮ ДЛИНУ — расти ей больше некуда. Пробовать при этом
		# не перестанешь: попытки упирались бы в отказ, а в числах проверки это
		# читается как «лиана не находит места» — то есть одна беда прикинулась бы
		# другой.
		if p.has("hangs") and int(p["hangs"]) >= int(p.get("hang_max", 0)):
			chance = 0.0
		if p["m"] >= def["spread_at"] and _rng.randf() < chance * slow * dt:
			# СЧИТАЕМ ПОПЫТКИ И УДАЧИ. «Лиана застряла» бывает по двум совершенно
			# разным причинам: она не пробует расти (частота, зрелость, запрет на
			# ветвление) или пробует и не находит куда (земля, наклон, шаг). По
			# самому числу звеньев их не различить, а чинить надо разное.
			if _is_stem(def):
				_sprout_try += 1
			var target := _sprout_from(pid, p, def)
			if not target.is_empty():
				if _is_stem(def):
					_sprout_win += 1
				sprouts.append([target, p["id"], _child_bulk(float(p["bulk"])), pid])

	for pid in fallen:
		remove_at(pid)
	for s in sprouts:
		# Звено лианы садится ВПЛОТНУЮ к родителю — на то она и нить. Запрет на
		# тесноту писался под ковёр мха, где две кочки в одной точке — это брак.
		if _is_stem(PlantsData.ITEMS[String(s[1])]) or not _crowded(s[0]["pos"], float(s[2])):
			_create(s[0], s[1], 0.05, float(s[2]), int(s[3]))
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
func _sprout_from(pid: int, p: Dictionary, def: Dictionary) -> Dictionary:
	# ЛИАНА САМА ИЩЕТ ОПОРУ. Пробуем несколько сторон и садимся туда, где земля
	# КРУЧЕ: на ровном месте это почти случайность, а рядом с глыбой — верный
	# поворот к ней. Отсюда и главное на кадре: поставил валун — лиана к нему
	# пошла. Одним перевесом вверх (`climb`) такого не получить: он говорит, куда
	# лезть, когда ты УЖЕ на круче, а не как до неё добраться.
	# ПЕРЕВАЛ ЧЕРЕЗ КРОМКУ РЕШАЕТСЯ ОТДЕЛЬНО ОТ ПРОБ ПО ЗЕМЛЕ — и до них. Это не
	# «ещё одна сторона» в общем зачёте, а решение отпустить опору: у живой лозы
	# кончик, дошедший до верха, свешивается, а не ищет, за что зацепиться дальше.
	# Заодно и цена: перевал щупает поверхность десяток раз, и звать его на каждую
	# из шести проб было бы вшестеро дороже впустую.
	if float(def.get("hang", 0.0)) > 0.0:
		var bend_max: float = deg_to_rad(float(def.get("bend_max", 180.0)))
		# УЖЕ СВЕСИЛАСЬ — ЗНАЧИТ, ПАДАТЬ, ПОКА ПАДАЕТСЯ. Землю висящему звену
		# искать нельзя: под кромкой она есть, внизу у подошвы глыбы, и поиск
		# затащил бы плеть на неё — вместо занавеса вышел бы обычный побег понизу.
		#
		# А ВОТ КОГДА ПАДАТЬ БОЛЬШЕ НЕКУДА — плеть ДОСТАЛА до земли или упёрлась в
		# камень, — она перестаёт висеть и растёт дальше обычным побегом. Так и у
		# живой лозы: дотянувшаяся до земли плеть на ней и укореняется. Прежде тут
		# стоял отказ, и кончик такой плети замирал навсегда.
		if int(p.get("hangs", 0)) > 0:
			var down: Dictionary = _hang_step(p, def, Vector3.ZERO, bend_max,
				int(p["hangs"]) + 1)
			if not down.is_empty():
				return down
		# КРОМКУ ИЩЕМ ГЕОМЕТРИЕЙ, А НЕ ВЫСОТОЙ.
		#
		# ГРАБЛИ, замеренные: сперва перевал разрешался только «на макушке» — там,
		# где выше по склону опоры уже нет. Но кромка и макушка — разные вещи: у
		# края острова выше по склону есть весь его купол, и настоящая кромка,
		# единственная в этом мире, отсеивалась начисто. А на ровной земле, где
		# нормаль смотрит вверх, «макушкой» оказывалось КАЖДОЕ место, и попытки
		# уходили впустую. Замерено: 523 попытки, за кромку вышли 9.
		#
		# Спрашивать надо не про высоту, а про то, есть ли куда падать, — и это
		# уже спрашивается ниже, самим шагом.
		#
		# Свеситься можно ДВУМЯ путями, и оба ведут сюда: перевалить через кромку
		# или доболтаться вольной ветвью до конца её запаса полёта. Что именно
		# случилось, разбирает сам `_hang_step` — здесь только частота.
		#
		# ПЛЕТИ ИДУТ ОТ ВОЛЬНЫХ ВЕТВЕЙ, а не от всякой. Нрав у ветви свой
		# (`free_k`) — он решает, охотно ли она отлипает от камня; пусть решает и
		# про плеть. Иначе висеть начинает пол-лозы: замерено при общей частоте —
		# 88 плетей, 461 звено из 1008, то есть почти половина, и лоза читается не
		# лозой на камне, а шваброй.
		if _rng.randf() < float(def.get("hang_rate", 0.5)) \
				* float(p.get("free_k", 1.0)):
			_hang_try += 1
			var over: Dictionary = _hang_step(p, def, Vector3.ZERO, bend_max, 1)
			if not over.is_empty():
				_hang_win += 1
				return over
	var tries: int = maxi(int(def.get("support_tries", 1)), 1)
	# Тяга к опоре тоже СВОЯ У КАЖДОЙ ВЕТВИ: у одной опора решает всё, другая
	# уходит в сторону по пустому месту. Одинаковая тяга и сгоняла их в сноп.
	var pull: float = float(def.get("support_love", 0.0)) \
		* float(p.get("pull_k", 1.0))
	# ЧЕМ ДАЛЬШЕ ПОРЯДОК, ТЕМ ШИРЕ РАСТЁМ (решение пользователя 2026-08-20). Ветви
	# дальних порядков идут после главной плети, по уже занятому месту, и на кадре
	# сбиваются к ней в метлу. Растим им и силу расхождения, и расстояние, на
	# котором они друг друга ещё стесняют.
	var wide: float = 1.0 + float(p.get("order", 0)) \
		* float(def.get("apart_grow", 0.0))
	var apart: float = float(def.get("apart_love", 0.0)) * wide
	var best: Dictionary = {}
	var best_score: float = -INF
	for _try in range(tries):
		var spot: Dictionary = _one_sprout(pid, p, def)
		if spot.is_empty():
			continue
		if tries == 1:
			return spot
		# Случайность оставляем заметной: без неё все звенья ходят по одной и той
		# же самой крутой дорожке, и лиана вырождается в прямую линию.
		var score: float = _rng.randf() * 0.35
		if bool(spot.get("air", false)):
			# ВОЛЬНОЕ НАПРАВЛЕНИЕ СУДИМ ПО СВОЕЙ МЕРКЕ. Опоры впереди у него нет и
			# быть не может — на то оно и вольное, — а тяга к опоре сильная, и в
			# общем зачёте оно проигрывало всегда. Замерено: висящих звеньев 1%
			# вместо задуманных шести, сколько ни поднимай их частоту. Теперь вес
			# ему даёт собственная вольность побега.
			score += float(def.get("air_love", 3.0)) * float(p.get("free_k", 0.0))
		else:
			score += pull * _support_ahead(p, spot, def)
		# И РАСХОДИМСЯ СО СВОИМИ. Опора тянет все побеги в одну и ту же лучшую
		# сторону, и на глыбе они шли тесным пучком вверх — «метла», только из
		# параллельных плетей. Место, где своя же лиана уже есть, теперь хуже
		# пустого; пересечения от этого не исчезают, а становятся редкими, как оно
		# и должно быть.
		if apart > 0.0:
			score -= apart * _stem_crowd(pid, p, spot, def, wide)
		if score > best_score:
			best_score = score
			best = spot
	return best


# НАСКОЛЬКО ТЕСНО В ЭТОМ МЕСТЕ ОТ СВОИХ ЖЕ. Считаем по соседним ячейкам, как и
# запрет на тесноту у мха: перебор всего сада на каждую попытку — работа в
# квадрате от числа звеньев.
#
# Родителя и себя не считаем: они рядом по построению и одинаково мешали бы
# каждой из сторон, ничего между ними не различая.
func _stem_crowd(pid: int, p: Dictionary, spot: Dictionary, def: Dictionary,
		wide: float) -> float:
	var keep: float = main.CELL_SPACING * float(def.get("apart_near", 0.45)) * wide
	var at: Vector3 = spot["pos"]
	# СВОЯ СОБСТВЕННАЯ СПИНА — НЕ ТЕСНОТА.
	#
	# ГРАБЛИ, и на кадре они выглядели как моток на боку глыбы: побег изгибается,
	# и его же недавние звенья оказываются сбоку в двух вершках. Считая их за
	# тесноту, побег отходит от них — то есть заворачивает всё в ту же сторону, шаг
	# за шагом, и сматывается в спираль. Пропускали при этом только родителя,
	# чего мало: спираль замыкается через пять-восемь звеньев.
	#
	# Расходиться надо с ДРУГИМИ ветвями, а не с собой: ради этого правило и
	# писалось.
	var skip: Dictionary = {pid: true}
	var back: int = pid
	for _i in range(CROWD_BACK):
		back = int(patches[back].get("from", -1))
		if not patches.has(back):
			break
		skip[back] = true
	var node: Vector3i = main.grid.node_of(int(spot["cell"]))
	var crowd := 0.0
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var c: int = main.grid.node_seed(node + Vector3i(dx, dy, dz))
				if c < 0:
					continue
				for other in by_cell.get(c, {}):
					if skip.has(other) or not patches.has(other):
						continue
					if String(patches[other]["id"]) != String(p["id"]):
						continue
					var d: float = at.distance_to(patches[other]["pos"])
					if d < keep:
						crowd += 1.0 - d / keep
	return crowd


# ЧТО ВПЕРЕДИ ПО ЭТОЙ СТОРОНЕ — на несколько шагов, а не на один.
#
# ГРАБЛИ, замеренные: сперва крутизна спрашивалась у той самой ячейки, куда сел
# бы отросток, — то есть на 11 см вперёд. Опору на таком расстоянии лиана
# нащупывает, только уже упёршись в неё носом, а до того бродит наугад и находит
# глыбу разве что случайно. Замерено: 36 звеньев, из них НА КРУЧЕ НОЛЬ, хотя
# глыба была в метре.
#
# Теперь смотрим вдоль стороны на несколько шагов и берём самое крутое, что
# попалось. Дальнее весит меньше ближнего: опора под носом важнее опоры за три
# шага, иначе лиана будет всю жизнь целиться в дальнюю гору мимо ближнего валуна.
func _support_ahead(p: Dictionary, spot: Dictionary, def: Dictionary) -> float:
	var step: Vector3 = Vector3(spot["pos"]) - Vector3(p["pos"])
	if step.length_squared() < 0.000001:
		return 0.0
	var dir: Vector3 = step.normalized()
	var reach: float = main.CELL_SPACING * float(def.get("support_reach", 3.0))
	return _support_ray(Vector3(p["pos"]), dir, reach)


# ЕСТЬ ЛИ ВПЕРЕДИ ПОРОДА ВЫШЕ НАС — вот и вся опора.
#
# Мерку пришлось искать трижды, и обе первые были негодны, причём проверить это
# удалось только замером:
#
#   1) КРУТИЗНА ПОЛЯ у ячейки впереди. Замерено: на камне она в среднем 0.214, на
#      земле 0.186, а местами земля и круче. То есть глыбу от острова эта мерка не
#      отличает вовсе.
#   2) НАСКОЛЬКО ЗЕМЛЯ ВПЕРЕДИ ВЫШЕ. Звучит верно, а на деле рядом со стеной
#      ближайшая поверхность — это её БОК на той же высоте, и подъём выходит
#      нулевой. Замерено: у самой подошвы глыбы «подъём вокруг» 0.08.
#
# Спрашиваем прямо: пощупаем несколько точек впереди НА ВЫСОТЕ ПОЯСА И ПЛЕЧА и
# посмотрим, не занята ли они породой. Занята — значит впереди стена, и лезть
# есть по чему. Ни порогов, ни размахов: ячейка либо внутри тела, либо снаружи.
#
# БЛИЖНЕЕ ВЕСИТ НАМНОГО БОЛЬШЕ ДАЛЬНЕГО, и первая точка щупается почти под носом
# — иначе чутьё НАСЫЩАЕТСЯ. Замерено: у подошвы глыбы все стороны в пределах
# полутора метров видят её одинаково, выбирать не из чего, и лиана ползёт вдоль
# основания, не поднимаясь (1 звено на камне из 38, подъём ноль). Стена в двадцати
# сантиметрах и стена в трёх метрах должны различаться, иначе «искать опору»
# кончается на том, чтобы её найти.
const SUPPORT_STEPS := [[0.06, 1.0], [0.2, 0.72], [0.5, 0.5], [1.0, 0.32]]

func _support_ray(here: Vector3, dir: Vector3, reach: float) -> float:
	var seen: float = 0.0
	for probe in SUPPORT_STEPS:
		var base: Vector3 = here + dir * (reach * float(probe[0]))
		var hit: float = 0.0
		# Две высоты: по пояс — это ещё может быть бугорок, по плечо — уже стена.
		for up in [[0.35, 0.65], [0.85, 1.0]]:
			var c: int = main.grid.cell_at(base + Vector3.UP * float(up[0]))
			if c < 0 or not main.grid.in_play(c):
				continue
			if main.grid.fill_of(c) > main.grid.SOLID_AT:
				hit = maxf(hit, float(up[1]))
		seen = maxf(seen, hit * float(probe[1]))
	return seen


# ЧТО ВООБЩЕ ЕСТЬ ВОКРУГ ТОЧКИ — самая крутая земля в пределах взгляда. Только
# для самопроверки: если лиана не пришла к глыбе, надо сперва понять, видела ли
# она её с того места, где стояла. Иначе чинить будешь выбор стороны, а сломано
# чутьё — или наоборот.
func support_around(pos: Vector3, reach: float) -> float:
	var seen := 0.0
	for k in range(16):
		var a: float = TAU * float(k) / 16.0
		seen = maxf(seen, _support_ray(pos, Vector3(cos(a), 0.0, sin(a)), reach))
	return seen


# НЕ РЕЖЕТ ЛИ КОЛЕНО ПОРОДУ. Щупаем несколько точек по дороге и у каждой
# спрашиваем поверхность: точка должна лежать СНАРУЖИ, по ту сторону нормали.
#
# ГРАБЛИ, дважды: сперва путь проверялся по заполнению ЯЧЕЙКИ. Ячейка — это
# две трети метра, а колено — десять сантиметров; тонкую стенку такая проверка не
# видит вовсе, и лоза ныряла сквозь неё.
#
# И ВОГНУТЫЕ МЕСТА ОПАСНЕЕ ВЫПУКЛЫХ. На выпуклом перегибе хорда идёт снаружи, а
# вот в ложбине между двумя горбами она режет породу насквозь — и прежняя мерка
# по касательным плоскостям такие места как раз ПРОЩАЛА. Здесь знак честный:
# отрицательный вылет — это внутри камня, и спорить не о чем.
# ТЕРПИМ КАСАНИЕ, НЕ ТЕРПИМ ПОГРУЖЕНИЕ. Оба конца колена лежат НА поверхности,
# и вылет у них ноль; требуй мы зазора — не прошло бы ни одно колено на свете.
# Замерено: с таким требованием лиана выросла на три звена за три минуты вместо
# трёхсот. Ловим только то, что ушло внутрь глубже терпимости.
const PATH_DEEP: float = 0.02               # насколько внутрь ещё простительно, м

func _path_clear(from: Vector3, to: Vector3) -> bool:
	# Конец колена проверяем ТОЖЕ (доля 1.0): у висящего звена он и есть то место,
	# где можно влезть в породу, а у стоящего на земле вылет там ровно ноль и
	# проверке не мешает.
	for k in [0.2, 0.4, 0.6, 0.8, 1.0]:
		var probe: Vector3 = from.lerp(to, k)
		var land: Dictionary = main.grid.surface_near(probe)
		if land.is_empty():
			continue                 # поверхности рядом нет — значит, чистый воздух
		if (probe - Vector3(land["pos"])).dot(land["nrm"]) < -PATH_DEEP:
			return false
	return true


# ЕСТЬ ЛИ ЗЕМЛЯ ПОД ЭТИМ МЕСТОМ — на такую-то глубину.
#
# Нужно это тем, кто висит в воздухе: и плети, и вольной ветви. Висеть можно НАД
# САДОМ, но не за его краем: у кромки острова под ней пусто на всю высоту мира, и
# свесившаяся там лоза уходит ниже поверхности — на кадре это «лиана растёт под
# текстуру». Мху расти на исподе острова запрещено ровно за это же (`surfaces` без
# «под»), и висящей лозе незачем.
#
# Щупаем ЯЧЕЙКАМИ, а не поверхностью: на глубине в метры поверхности рядом уже
# нет, и `surface_near` вернёт пустоту — то есть соврёт «чисто». А заполнение у
# ячейки есть всегда, семена стоят по всему миру, не только в породе. Точность
# тут в треть метра, и её довольно: вопрос грубый — сад под нами или пропасть.
func _ground_below(at: Vector3, deep: float) -> bool:
	# Пробы идут ГУЩЕ У СЕБЯ ПОД НОГАМИ и реже вдаль: у кромки острова земля
	# тонкая, и ровный шаг в метр перескочил бы её насквозь — вышло бы «подо мной
	# пропасть» там, где под плетью честные полметра земли.
	for k in [0.05, 0.15, 0.4, 1.0]:
		var c: int = main.grid.cell_at(at + Vector3.DOWN * (deep * k))
		if c >= 0 and main.grid.fill_of(c) > main.grid.SOLID_AT:
			return true
	return false


# Одна попытка отростка: куда шагнули и что там нашлось.
func _one_sprout(pid: int, p: Dictionary, def: Dictionary) -> Dictionary:
	var nrm: Vector3 = p["nrm"]
	var side: Vector3 = nrm.cross(Vector3.UP)
	if side.length_squared() < 0.001:
		side = nrm.cross(Vector3.RIGHT)
	side = side.normalized()
	var along: Vector3 = nrm.cross(side).normalized()
	var a: float = _rng.randf() * TAU
	var dir: Vector3 = side * cos(a) + along * sin(a)
	# ПОБЕГ ДЕРЖИТ СВОЮ СТОРОНУ. Без этого каждое звено выбирает направление
	# заново, и плеть идёт мелкой пилой вместо линии; а боковой побег, едва
	# отойдя, разворачивается туда же, куда и главный, — оттого они и шли пучком.
	#
	# У ДАЛЬНИХ ПОКОЛЕНИЙ ДЕРЖИТ СЛАБЕЕ (решение пользователя 2026-08-20): ветви
	# дальних порядков выходили слишком прямыми, а тонкому побегу положено виться.
	var order: int = int(p.get("order", 0))
	var late: int = maxi(0, order - int(def.get("fork_gain_from", 5)))
	var keep_on: float = float(def.get("keep_on", 0.0)) \
		/ (1.0 + float(late) * float(def.get("keep_fade", 0.0)))
	# КУДА ШЛИ ДО СИХ ПОР. Нужно и повороту, и его ограничению ниже.
	var came := Vector3.ZERO
	var was: int = int(p.get("from", -1))
	if patches.has(was):
		var went: Vector3 = Vector3(p["pos"]) - Vector3(patches[was]["pos"])
		if went.length_squared() > 0.000001:
			came = went.normalized()
	if keep_on > 0.0 and came != Vector3.ZERO:
		var along_land: Vector3 = came - nrm * came.dot(nrm)   # только вдоль земли
		if along_land.length_squared() > 0.000001:
			dir = (dir + along_land.normalized() * keep_on).normalized()

	var bend_max: float = deg_to_rad(float(def.get("bend_max", 180.0)))
	# Лиана лезет ВВЕРХ: тот же отросток, но с сильным перевесом по подъёму. Сила
	# перевеса СВОЯ У КАЖДОЙ ВЕТВИ — иначе все они лезут одинаково и сходятся в
	# одну верхнюю точку.
	var climb: float = float(def.get("climb", 0.0)) * float(p.get("climb_k", 1.0))
	if climb > 0.0 and not _at_top(p, def):
		var up: Vector3 = (Vector3.UP - nrm * nrm.dot(Vector3.UP))
		if up.length_squared() > 0.001:
			dir = (dir + up.normalized() * climb).normalized()
	# МОТОК РАСКРУЧИВАЕМ. Побег, который крутит всё время в одну сторону,
	# сматывается спиралью — на кадре это виток на боку глыбы, и читается он не
	# лозой, а шлангом. Накрученное ведётся при рождении звена (`spin`); перебрал
	# мерку — следующий поворот отражаем на другую сторону, оставив ему ту же
	# крутизну. Запрета «не поворачивай» тут нет: побегу положено виться, нельзя
	# только виться по кругу.
	var spin: float = float(p.get("spin", 0.0))
	if absf(spin) > SPIN_MAX and came != Vector3.ZERO:
		var side_turn: float = atan2(came.cross(dir).dot(nrm), came.dot(dir))
		if signf(side_turn) == signf(spin):
			dir = (came * (2.0 * came.dot(dir)) - dir).normalized()
	# ПОВОРОТ НА СТЫКЕ НЕ КРУЧЕ МЕРКИ (решение пользователя 2026-08-20). Резкий
	# излом читается не изгибом ветви, а её переломом.
	#
	# ГРАБЛИ: отводили намерение ДО того, как приложена тяга вверх, — а она потом
	# доворачивала его обратно, и мерка обходилась с чёрного хода. Замерено: 72.8°
	# при пределе 60. Отводить надо ПОСЛЕДНИМ, когда направление уже сложилось из
	# всех своих слагаемых.
	if came != Vector3.ZERO and bend_max < PI:
		var turn: float = came.angle_to(dir)
		if turn > bend_max and turn > 0.000001:
			dir = came.slerp(dir, bend_max / turn).normalized()

	# ДЛИНА ШАГА — из каталога, если она там задана. У мха она общая (`SPREAD_*`),
	# а лозе нижний край подняли вдвое: короткие колена дают частые изломы, и
	# трубка на них ломается, сколько её ни скругляй.
	var step: float = main.CELL_SPACING * _rng.randf_range(
		float(def.get("step_near", SPREAD_NEAR)),
		float(def.get("step_far", SPREAD_FAR)))

	# ВОЛЬНАЯ ВЕТВЬ ОТЛИПАЕТ ОТ ПОВЕРХНОСТИ (решение пользователя 2026-08-20).
	# Такое звено садится не на землю, а в воздух, и по дороге его клонит вниз
	# собственной тяжестью. Подряд их идёт не больше `air_max`: без этого счёта
	# вольная ветвь улетала бы с острова.
	var free: float = float(p.get("free_k", 0.0)) * float(def.get("air_rate", 0.0))
	if free > 0.0 and int(p.get("airlen", 0)) < int(def.get("air_max", 3)) \
			and _rng.randf() < free:
		var sag: Vector3 = (dir + Vector3.DOWN * float(def.get("air_droop", 0.5)))
		# Провисание — тоже поворот, и мерку излома оно обходить не должно.
		if came != Vector3.ZERO and bend_max < PI \
				and sag.length_squared() > 0.000001:
			var fall: float = came.angle_to(sag.normalized())
			if fall > bend_max and fall > 0.000001:
				sag = came.slerp(sag.normalized(), bend_max / fall)
		if sag.length_squared() > 0.000001:
			var to: Vector3 = Vector3(p["pos"]) + sag.normalized() * step
			var c: int = main.grid.cell_at(to)
			# В воздухе — значит, в породу не влезаем и за край мира не уходим.
			# ПРОВЕРЯЕМ ВЕСЬ ПУТЬ, А НЕ ТОЛЬКО КОНЕЦ: колено идёт по прямой, и
			# конец может выйти по ту сторону тонкой стенки, а само колено пройти
			# сквозь неё. На кадре это лоза, ныряющая в камень.
			# Заполнение ЯЧЕЙКИ здесь больше не спрашиваем: ячейка — две трети
			# метра, и у точки, честно висящей в десяти сантиметрах от стены,
			# ближайшее семя нередко лежит ВНУТРИ камня. Такая проверка резала
			# вольные ветви пачками (замерено: 1% вместо 6%), а настоящую защиту
			# даёт `_path_clear` — он спрашивает поверхность, а не ячейку.
			# И ПОД ВОЛЬНОЙ ВЕТВЬЮ ТОЖЕ ДОЛЖЕН БЫТЬ САД, а не пропасть за кромкой
			# острова: она висит в воздухе на тех же правах, что и плеть, и уходит
			# под поверхность точно так же.
			if c >= 0 and main.grid.in_play(c) \
					and _path_clear(Vector3(p["pos"]), to) \
					and _ground_below(to, HANG_OVER):
				return {"pos": to, "nrm": nrm, "cell": c, "air": true}

	var spot: Dictionary = main.grid.surface_near(p["pos"] + dir * step)
	if spot.is_empty():
		return {}
	# Отросток обязан сесть РЯДОМ и на СВОЙ ЛАД повёрнутую землю. Проверка не
	# придирка: от точки в воздухе у края острова ближайшая земля — это его
	# исподняя сторона, и поросль уходила туда одним прыжком, огибая кромку.
	if spot["pos"].distance_to(p["pos"]) > step * 1.7:
		return {}
	# НАСКОЛЬКО КРУТО ЗЕМЛЯ МОЖЕТ ЗАВЕРНУТЬСЯ ЗА ОДИН ШАГ. У мха 0.35 — резче
	# семидесяти градусов это уже перескок через кромку, а не расползание.
	#
	# ЛИАНЕ ЭТОТ ЗАПРЕТ МЕШАЛ ЖИТЬ. Переход с ровной земли на бок глыбы — это как
	# раз поворот под прямым углом, и лиана его не проходила: доходила до подошвы
	# и ползла вдоль неё. Замерено: 1 звено на камне из 38, подъём ноль на звено,
	# при том что земля под ней уже в 1.64 раза круче средней по острову. Ей
	# нужно ровно то, чего мху нельзя, — влезать на стену; но за прямой угол не
	# пускаем и её, иначе уйдёт на исподнюю сторону.
	if spot["nrm"].dot(p["nrm"]) < float(def.get("turn_max", 0.35)):
		return {}
	if not _fits_surface(spot["nrm"], def):
		return {}
	# И ПУТЬ ДО НОВОГО МЕСТА ДОЛЖЕН БЫТЬ ЧИСТ. Оба конца колена лежат на земле,
	# а само оно идёт по прямой: в ложбине между двумя горбами такая прямая режет
	# породу насквозь. Ровно это и видно на кадре — лоза ныряет в камень.
	if _is_stem(def) and not _path_clear(Vector3(p["pos"]), Vector3(spot["pos"])):
		return {}
	# И ПОВОРОТ У ГОТОВОГО МЕСТА — тоже. Намерение мы отвели выше, но поверхность
	# сдвигает точку по-своему, и излом может вернуться.
	if came != Vector3.ZERO and bend_max < PI:
		var real: Vector3 = Vector3(spot["pos"]) - Vector3(p["pos"])
		if real.length_squared() > 0.000001 \
				and came.angle_to(real.normalized()) > bend_max:
			return {}
	if _is_stem(def):
		var rode: Dictionary = _ride_over(pid, p, spot, def)
		if rode != spot:
			# ПЕРЕЛЕЗАНИЕ СДВИГАЕТ ТОЧКУ, а значит и поворот на стыке. Проверяем
			# заново: иначе предел излома обходится с чёрного хода (замерено:
			# 68° при мерке 60°). Не вышло — отказываем целиком, попыток хватает.
			if came != Vector3.ZERO and bend_max < PI:
				var moved: Vector3 = Vector3(rode["pos"]) - Vector3(p["pos"])
				if moved.length_squared() < 0.000001 \
						or came.angle_to(moved.normalized()) > bend_max:
					return {}
			spot = rode
	return spot


# ЛЕЗТЬ БОЛЬШЕ НЕКУДА — то есть мы на макушке или на верхней кромке.
#
# Спрашиваем ту же опору, что и всегда, но в сторону подъёма: пусто — значит,
# выше ничего нет, и тяга вверх снимается. Иначе лиану водит кругами вокруг
# вершины — на кадре клубок. Нормаль строго вверх — мы лежим на верхней площадке,
# и спрашивать нечего: там макушка по построению.
#
# А ВОТ ДЛЯ ПЕРЕВАЛА ЧЕРЕЗ КРОМКУ ЭТО НЕ МЕРКА, хотя поначалу стояло и там:
# кромка и макушка — разные вещи. См. `_hang_step`.
func _at_top(p: Dictionary, def: Dictionary) -> bool:
	var nrm: Vector3 = p["nrm"]
	var up: Vector3 = Vector3.UP - nrm * nrm.dot(Vector3.UP)
	if up.length_squared() <= 0.001:
		return true
	return _support_ray(Vector3(p["pos"]), up.normalized(),
		main.CELL_SPACING * float(def.get("support_reach", 3.0))) <= 0.1


# ЕСТЬ ЛИ В ЭТОМ МИРЕ ВООБЩЕ ГДЕ СВЕСИТЬСЯ. Спрашиваем не лиану, а саму землю:
# обходим все видимые места, с каждого пробуем падение теми же правилами, что и у
# плети, и считаем, на сколько звеньев хватило места.
#
# Без этого «плетей ноль» — ответ без причины: то ли лиана не дошла до кромки, то
# ли кромок в мире нет вовсе, то ли мерка просевам не по росту. Числа по самой
# лиане этих трёх бед не различают, а чинить надо разное.
#
# Идём с каждого места ВНИЗ ПО СКЛОНУ: так к кромке и подходит побег.
func hang_spots(id: String) -> Dictionary:
	var def: Dictionary = PlantsData.ITEMS[id]
	if not def.has("hang"):
		return {}
	var step: float = main.CELL_SPACING * float(def.get("step_far", SPREAD_FAR))
	var room := PackedInt32Array()
	room.resize(HANG_ROOM + 1)
	var seen := 0
	var off := 0
	var void_off := 0
	var best := Vector3(0.0, -1e9, 0.0)
	for cell in range(main.grid.seeds.size()):
		if not main.grid.in_play(cell):
			continue
		var at: Vector3 = main.grid.seeds[cell]
		if main.grid.surface_gap(at) < 0.0:
			continue
		var land: Dictionary = main.grid.surface_near(at)
		if land.is_empty():
			continue
		var nrm: Vector3 = land["nrm"]
		# Считаем только те места, где лиана вообще может стоять: с потолка ей
		# свеситься было бы негде, и такое место в счёте только врало бы.
		if not _fits_surface(nrm, def):
			continue
		var slope: Vector3 = Vector3.DOWN - nrm * Vector3.DOWN.dot(nrm)
		if slope.length_squared() < 0.000001:
			continue                 # отвесная стена или потолок — склона нет
		seen += 1
		var here: Vector3 = land["pos"]
		var dir: Vector3 = _hang_dir(def, slope.normalized(), 1, 0.0).normalized()
		var to: Vector3 = here + dir * step
		if not _path_clear(here, to):
			continue                 # первый же шаг упёрся в землю — не кромка
		# И ОТДЕЛЬНО — СКОЛЬКО МЕСТ ОТСЕЯЛ ЗАПРЕТ ВИСЕТЬ ЗА КРАЕМ САДА. Само по
		# себе «плетей столько-то» об этом запрете не скажет ничего: в кадре с
		# глыбой он вообще не срабатывает, а у кромки острова решает всё.
		if not _ground_below(to, HANG_OVER):
			void_off += 1
			continue
		off += 1
		var got: int = _hang_room(def, to, dir, step)
		room[got] += 1
		# И ЗАПОМИНАЕМ ОДНУ ГОДНУЮ КРОМКУ — самую высокую. По ней проверка потом
		# сажает лиану и смотрит, вырастет ли плеть на самом деле.
		if got >= HANG_ROOM and here.y > best.y:
			best = here
	return {"seen": seen, "off": off, "room": room, "at": best, "void": void_off}


# СВИСАЮЩАЯ ПЛЕТЬ — ЭТО ПАДЕНИЕ, А НЕ РОСТ ПО ЗЕМЛЕ (решение пользователя
# 2026-08-21).
#
# Звено садится в воздух, и валит его вниз собственная тяжесть: куда шли, плюс
# тяга вниз (`hang`). За кромку плеть от этого загибается САМА, за два-три звена,
# и перелома на ней не выходит — предел излома тут тот же, что и везде.
#
# ДЛИНА ОТМЕРЕНА ЗВЕНЬЯМИ (`hang_len`), а не тем, докуда достанет: у пользователя
# выбрано восемь-десять, около 1.2 метра. Дотянись плеть до земли — она бы там
# снова зацепилась, и занавес превратился бы в обычный побег понизу.
#
# Висящее звено ничем не держится за рельеф, и это ему уже разрешено: пересадка
# при правке земли его не трогает, а потеряв родителя, оно снимается вместе с
# остатком плети.
# ЕСТЬ ЛИ ПОД КРОМКОЙ МЕСТО ХОТЯ БЫ НА ТРИ ЗВЕНА. Проходим падение вперёд тем же
# правилом, каким оно и пойдёт: тяга вниз, предел излома, тот же шаг. Плеть в одно
# звено — это не плеть, а огрызок, торчащий из кромки.
const HANG_ROOM: int = 3
# Как быстро тяжесть берёт своё у плети — см. `_hang_dir`. `HANG_RISE` — до
# какого звена побег ещё выносит вверх, `HANG_LIFT` — насколько сильно, `HANG_EASE`
# — насколько круче он валится с каждым следующим звеном. При этих числах плеть
# идёт так: первое звено вверх-наружу, второе прямо, третье клонится, к пятому
# висит почти отвесно.
const HANG_EASE: float = 0.5
const HANG_RISE: float = 2.0
const HANG_LIFT: float = 0.5
# И насколько плеть отрывается от опоры в самом начале — чтобы не чиркнуть по ней
# первым же звеном.
const HANG_OFF: float = 0.5
# Над чем плеть вообще может висеть, в метрах вниз. Нет земли на эту глубину —
# значит, мы за краем сада, и висеть тут нельзя.
const HANG_OVER: float = 4.0
# И на сколько плеть обязана отойти от опоры, в метрах: ближе — это уже не
# свисание, а лежание на камне.
#
# ЧИСЛО ВЫБРАНО ПО РЕЛЬЕФУ, а не на глаз. Плеть отходит от склона, пока падает
# ПОЛОГО его, и возвращается, когда тяжесть довернёт её круче. На боку глыбы в
# сорок градусов наибольший просвет выходит около восьми сантиметров — с меркой в
# десять там не завелась бы ни одна плеть, что и было замерено: 17 годных мест на
# 2000. Пять сантиметров при плети толщиной в один-три — это всё ещё воздух, а не
# прилипание.
const HANG_FREE: float = 0.05

# КУДА ПАДАЕТ ПЛЕТЬ НА ЭТОМ ЗВЕНЕ — одно правило и для роста, и для обеих
# проверок. Тяжесть клонит тем сильнее, чем больше уже свесилось (`HANG_EASE`),
# и к этому добавляется виляние.
func _hang_dir(def: Dictionary, way: Vector3, hangs: int, sway: float) -> Vector3:
	# ТЯЖЕСТЬ БЕРЁТ СВОЁ НЕ СРАЗУ. Молодой побег держит себя сам: у настоящего
	# винограда плеть сперва выносит ВВЕРХ И НАРУЖУ, и только отросши, она
	# переваливается и повисает. Отсюда и «перевал» — он не только у кромки.
	#
	# ЗАЧЕМ, числами: пока тяжесть тянула вниз с первого же звена, плеть могла
	# завестись лишь там, где под ней сразу обрыв. Таких мест в этом мире 44 на
	# 2000, и лиана к ним не идёт — она лезет вверх. Замерено: 26 попыток за
	# кромку, из них с местом на плеть одна.
	var lean: float = clampf((float(hangs) - HANG_RISE) * HANG_EASE,
		-HANG_LIFT, 1.0)
	var out: Vector3 = way.normalized() \
		+ Vector3.DOWN * (float(def.get("hang", 1.0)) * lean)
	if sway > 0.0:
		out += Vector3(_rng.randf_range(-1.0, 1.0), 0.0,
			_rng.randf_range(-1.0, 1.0)) * sway
	return out


func _hang_room(def: Dictionary, at: Vector3, way: Vector3, step: float,
		free: float = HANG_FREE) -> int:
	var bend_max: float = deg_to_rad(float(def.get("bend_max", 180.0)))
	var here: Vector3 = at
	var dir: Vector3 = way
	for i in range(HANG_ROOM):
		# Своей случайности проверка не берёт: она отвечает на вопрос «пройдёт ли
		# плеть», а не «как именно она вильнёт».
		var next_dir: Vector3 = _hang_dir(def, dir, i + 2, 0.0).normalized()
		var turn: float = dir.angle_to(next_dir)
		if turn > bend_max and turn > 0.000001:
			next_dir = dir.slerp(next_dir, bend_max / turn).normalized()
		var to: Vector3 = here + next_dir * step
		if not _path_clear(here, to):
			return i
		# И ОТОЙТИ ОТ ОПОРЫ ПЛЕТЬ ОБЯЗАНА. Идущая в сантиметре от камня читается
		# лежащей на нём, а не свисающей, — а ради свисания всё и затевалось. На
		# выпуклом боку глыбы падение и склон уходят вниз почти вровень, и без
		# этой мерки такое место сошло бы за кромку.
		if free > 0.0:
			var land: Dictionary = main.grid.surface_near(to)
			if not land.is_empty() \
					and (to - Vector3(land["pos"])).dot(land["nrm"]) < free:
				return i
		here = to
		dir = next_dir
	return HANG_ROOM


func _hang_step(p: Dictionary, def: Dictionary, way: Vector3,
		bend_max: float, hangs: int) -> Dictionary:
	var most: int = int(p.get("hang_max", 0))
	if most <= 0:
		# Начало плети: длину берём с разбросом, иначе все занавесы под одну мерку.
		most = maxi(1, int(round(float(def.get("hang_len", 8))
			* _rng.randf_range(0.8, 1.2))))
	if hangs > most:
		return {}
	# ИЗЛОМ МЕРЯЕМ ОТ НАСТОЯЩЕГО ВХОДА, а не от того, куда собрались: на перевале
	# это разные вещи, и мерка обошлась бы с чёрного хода — свои же грабли, уже
	# наступали на них дважды.
	var came := Vector3.ZERO
	var was: int = int(p.get("from", -1))
	if patches.has(was):
		var went: Vector3 = Vector3(p["pos"]) - Vector3(patches[was]["pos"])
		if went.length_squared() > 0.000001:
			came = went.normalized()
	var fall: Vector3 = way if way.length_squared() > 0.000001 else came
	if fall.length_squared() < 0.000001:
		fall = Vector3.DOWN
	# ВОЛЬНАЯ ВЕТВЬ, У КОТОРОЙ КОНЧИЛСЯ ЗАПАС ПОЛЁТА, — ВТОРОЙ ПУТЬ К ПЛЕТИ, и
	# кромки ему не нужно вовсе. Ветвь уже висит в воздухе и опоры впереди не
	# ищет; выбор у неё небогатый — сесть на землю или повиснуть, и половина
	# садится, половина виснет.
	#
	# ЗАЧЕМ ЭТО, числами: кромок, годных для плети, в мире 17 на 2000 видимых
	# мест, и лиана до них не доходит — она ЛЕЗЕТ ВВЕРХ, то есть уходит от всякого
	# обрыва. Замерено: посаженная прямо на кромку лиана за минуту не свесилась ни
	# разу. Одной кромкой плеть остаётся правилом, которое почти не срабатывает.
	var free: bool = bool(p.get("air", false))
	if hangs <= 1 and free:
		# Не всякая висящая ветвь: она должна сперва ОТОЙТИ от опоры на несколько
		# звеньев (`hang_air`). Иначе вольная ветвь виснет с первого же звена, и
		# её собственный полёт пропадает вовсе.
		if int(p.get("airlen", 0)) < int(def.get("hang_air", 2)):
			return {}
	elif hangs <= 1:
		# ХЛЫСТ: побег отрывается от опоры ТУДА, КУДА ШЁЛ, чуть приподнявшись над
		# ней (`HANG_OFF`), — а дальше его выносит и переваливает своим чередом
		# (`_hang_dir`). Отрыв в сторону ската был первой попыткой и оказался
		# полумерой: с крутого места плеть уходила вниз, но на пологом сразу
		# ныряла в землю.
		if came == Vector3.ZERO:
			return {}
		var nrm: Vector3 = p["nrm"]
		# И ТОЛЬКО ТАМ, ГДЕ ОПОРА УХОДИТ ИЗ-ПОД ПОБЕГА: он должен идти вниз или
		# поперёк склона. Иначе лозу выносило бы хлыстом посреди ровной земли, на
		# каждом шагу, — а это уже не плеть, а прыжок.
		var slope: Vector3 = Vector3.DOWN - nrm * nrm.dot(Vector3.DOWN)
		if slope.length_squared() < 0.000001 or came.dot(slope.normalized()) < 0.0:
			return {}
		fall = (came + nrm * HANG_OFF).normalized()
	# ТЯЖЕСТЬ КЛОНИТ ТЕМ СИЛЬНЕЕ, ЧЕМ БОЛЬШЕ УЖЕ СВЕСИЛОСЬ (`_hang_dir`). Первое
	# звено идёт почти туда же, куда шёл побег: оно ещё держится кромкой. Дальше
	# плеть валится всё круче.
	#
	# ГРАБЛИ, замеренные: сперва вниз тянуло полной силой с первого же звена, и
	# шаг за кромку упирался в предел излома — 60° к земле. Завестись плеть могла
	# тогда только на обрыве КРУЧЕ шестидесяти градусов, а таких мест в этом мире
	# нет вовсе: бок глыбы — сорок. Замерено: 1033 попытки, за кромку вышли 7,
	# плетей ноль. Дело было не в редкости кромок, а в том, что лоза пыталась
	# сорваться отвесно там, где живая просто растёт вбок и провисает.
	#
	# Виляние: отвес по нитке читается верёвкой, а не плетью.
	var dir: Vector3 = _hang_dir(def, fall, hangs,
		float(def.get("hang_sway", 0.0)))
	if dir.length_squared() < 0.000001:
		return {}
	dir = dir.normalized()
	if came != Vector3.ZERO and bend_max < PI:
		var turn: float = came.angle_to(dir)
		if turn > bend_max and turn > 0.000001:
			dir = came.slerp(dir, bend_max / turn).normalized()
	var step: float = main.CELL_SPACING * _rng.randf_range(
		float(def.get("step_near", SPREAD_NEAR)),
		float(def.get("step_far", SPREAD_FAR)))
	var to: Vector3 = Vector3(p["pos"]) + dir * step
	var c: int = main.grid.cell_at(to)
	if c < 0 or not main.grid.in_play(c):
		return {}
	# ПУТЬ ДОЛЖЕН БЫТЬ ЧИСТ. Посреди верхней площадки под звеном камень, проба
	# упирается в него и отказывает сама.
	if not _path_clear(Vector3(p["pos"]), to):
		return {}
	# И ВИСЕТЬ ПЛЕТЬ ДОЛЖНА НАД САДОМ, А НЕ ЗА ЕГО КРАЕМ (`HANG_OVER`). У кромки
	# острова под ней пусто на всю высоту мира, и плеть уходит ниже поверхности —
	# на кадре это лоза, растущая под текстурой.
	if not _ground_below(to, HANG_OVER):
		return {}
	if hangs <= 1:
		_hang_edge += 1
	# И ПОД КРОМКОЙ ДОЛЖНО БЫТЬ КУДА ПАДАТЬ.
	#
	# ГРАБЛИ, замеренные: одного чистого шага мало. На выпуклом бугре земли шаг
	# «вперёд и вниз» тоже выходит в воздух — земля уходит из-под него быстрее,
	# чем идёт колено, — и плеть заводилась там, где никакой кромки нет, а на
	# втором звене упиралась в землю и обрывалась. Замерено: шесть плетей, в
	# каждой ровно ОДНО звено, свес ноль сантиметров.
	#
	# Спрашиваем поэтому не про один шаг, а про то, пройдёт ли плеть хотя бы три
	# звена, — и спрашиваем ТЕМ ЖЕ ПАДЕНИЕМ, которым она пойдёт. Отвесом мерить
	# нельзя: первые звенья идут наружу и вниз, и перед наклонным боком глыбы
	# плеть проходит там, где отвес давно бы в него вошёл.
	#
	# Только у начала плети: дальше упереться в землю не беда, там плеть просто
	# кончается, и это честный конец.
	if hangs <= 1:
		# У ВОЛЬНОЙ ВЕТВИ ОТХОДИТЬ НЕ ОТ ЧЕГО — она и так в воздухе. Мерка отхода
		# писана для той плети, что сходит с камня: там она отличает свисание от
		# лежания на боку. Требуй её и от вольной — и плеть отказалась бы виснуть
		# всюду, где под ней близко земля, то есть почти везде.
		var room: int = _hang_room(def, to, dir, step, 0.0 if free else HANG_FREE)
		# И СРАЗУ ЗАПИСЫВАЕМ, СКОЛЬКО МЕСТА НАШЛОСЬ. «Плетей ноль» — ответ без
		# причины: то ли места нет вовсе, то ли его на звено меньше мерки. Числом
		# это видно, гаданием нет.
		_hang_deep[room] += 1
		# И СПРОС С ДВУХ ПУТЕЙ РАЗНЫЙ. С кромки плеть обязана пройти три звена: там
		# она вместо занавеса могла бы выйти огрызком, торчащим из склона. А
		# вольная ветвь уже висит и уже падает — ей довольно ОДНОГО чистого шага,
		# дальше она просто дотянется до земли и укоренится. Замерено: с меркой в
		# три звена вольная не свесилась ни разу — она летит в полуметре над
		# землёй, и трёх звеньев падения под ней нет нигде.
		if room < (1 if free else HANG_ROOM):
			return {}
	return {"pos": to, "nrm": p["nrm"], "cell": c, "air": true,
		"hangs": hangs, "hang_max": most}


# МОЛОДОЙ ПОБЕГ ПЕРЕЛЕЗАЕТ ЧЕРЕЗ СТАРЫЙ, А НЕ ПРОХОДИТ СКВОЗЬ (решение
# пользователя 2026-08-20). На кадре тонкие ветви ныряли прямо в толстый ствол.
#
# Ищем поблизости своё же звено ТОЛЩЕ нашего и, если новое место попадает в его
# тело, кладём точку ему НА СПИНУ — вдоль его нормали, на сумму радиусов с
# зазором. Звено при этом перестаёт быть привязанным к земле (`air`), иначе
# пересадка при правке рельефа стащит его обратно вниз.
#
# Только толще: иначе два побега одинаковой толщины начнут вечно залезать друг на
# друга, и получится не лоза, а слоёный пирог.
func _ride_over(pid: int, p: Dictionary, spot: Dictionary,
		def: Dictionary) -> Dictionary:
	var mine: float = lerpf(float(def.get("stem_thin", 0.005)),
		float(def.get("stem_thick", 0.075)),
		pow(clampf(float(p.get("load", 0)) / maxf(1.0,
			float(def.get("load_full", 120.0))), 0.0, 1.0), 0.35))
	var at: Vector3 = spot["pos"]
	var skip: int = int(p.get("from", -1))
	var node: Vector3i = main.grid.node_of(int(spot["cell"]))
	var best: int = -1
	var best_r: float = mine * RIDE_THICKER
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var c: int = main.grid.node_seed(node + Vector3i(dx, dy, dz))
				if c < 0:
					continue
				for other in by_cell.get(c, {}):
					if other == pid or other == skip or not patches.has(other):
						continue
					var q: Dictionary = patches[other]
					if String(q["id"]) != String(p["id"]):
						continue
					var his: float = float(_stem_ring(q, def)["r"])
					if his <= best_r:
						continue
					if at.distance_to(q["pos"]) > his + mine:
						continue
					best = other
					best_r = his
	if best < 0:
		return spot
	var over: Dictionary = patches[best]
	var lift: Vector3 = Vector3(over["nrm"])
	return {"pos": Vector3(over["pos"]) + lift * (best_r + mine + RIDE_GAP),
		"nrm": lift, "cell": int(over["cell"]), "air": true, "rode": true}


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
	var moved: Array = []
	for pid in suspect:
		var p: Dictionary = patches[pid]
		# ВИСЯЩЕЕ ЗВЕНО К ЗЕМЛЕ НЕ ПРИВЯЗАНО. Пересадка ищет ему поверхность, не
		# находит её рядом — и убивает; то есть вольная ветвь погибала бы при
		# первой же правке рельефа где угодно на острове.
		if bool(p.get("air", false)):
			continue
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
		#
		# СТЕБЛЮ ЗДЕСЬ ДЕЛАТЬ НЕЧЕГО. У него нет обода, и попытка посадить его
		# как кочку кончалась бы отказом на всякой круче — то есть лиана гибла бы
		# ровно там, куда лезет.
		var stem: bool = _is_stem(PlantsData.ITEMS[p["id"]])
		var again: Dictionary = p["body"]
		if not stem:
			again = _make_cushion(spot, PlantsData.ITEMS[p["id"]],
				int(p["salt"]), float(p["bulk"]))
			if again.is_empty():
				doomed.append(pid)
				continue
		var was: int = int(p["cell"])
		p["pos"] = spot["pos"]
		p["nrm"] = spot["nrm"]
		if stem:
			again["up"] = spot["nrm"]
			# Колено рисуется у РЕБЁНКА, а сдвинулись мы: без этого трубка
			# осталась бы тянуться к прежнему месту.
			_touch_kids(pid)
			# А РАЗРЫВ РАСТЯНУТЫХ — ВТОРЫМ ЗАХОДОМ, ниже: пока пересадка идёт,
			# переехать может и второй конец колена, и разрыв по дороге оторвал бы
			# цепь, которая через миг сошлась бы сама.
			moved.append(pid)
		p["body"] = again
		_link_near(pid)          # переехала — соседи у неё могли смениться
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
	# И РВЁМ ЦЕПЬ, ЕСЛИ ЕЁ РАСТЯНУЛО. Правка рельефа пересаживает каждое звено
	# САМО ПО СЕБЕ, и соседи по цепочке разъезжаются: под поднятым холмом между
	# ними оказывается весь его склон. Рвём насовсем, а не только прячем колено —
	# иначе оно всплывало бы при каждой следующей правке, а на кадре оставались бы
	# оборванные срезы и куски лозы, стоящие сами по себе.
	#
	# Спрашиваем ОБА конца: своего родителя и своих детей. Одного мало — при
	# правке переезжает то одно звено, то другое.
	for pid in moved:
		if not patches.has(pid):
			continue
		var cap: float = _stem_max(PlantsData.ITEMS[patches[pid]["id"]])
		var kin: int = int(patches[pid].get("from", -1))
		if patches.has(kin) \
				and Vector3(patches[pid]["pos"]).distance_to(patches[kin]["pos"]) > cap:
			_unlink(pid)
		_touch_kids(pid, false, cap)
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
const SECTORS: int = 10                     # углов у кочки, если смотреть сверху
const RING_AT := [0.42, 0.75, 1.0]          # где идут кольца, в долях радиуса
# Насколько сектор может быть длиннее соседнего. Ступенька больше этой даёт
# вытянутый лоскут, и кочка читается порванной.
const RIM_STEP: float = 1.35
# Насколько широкая перемычка получается там, где сходятся два бугра, в долях
# высоты кочки. Ноль — острая складка на стыке, много — кочки расплываются в
# общее одеяло и перестают читаться поодиночке.
const FIELD_BLEND: float = 0.35
# С КАКОЙ ЗРЕЛОСТИ КОЧКИ НАЧИНАЮТ СЛИВАТЬСЯ (решение пользователя 2026-08-17):
# с пятой ступени из девяти. До неё соседи друг друга не замечают вовсе и стоят
# каждый сам по себе; дальше их влияние набирается к девятой. Так у заросли
# появляется возраст, который видно: молодая — россыпь бугорков, старая — сплошь.
const MERGE_FROM: float = 4.0 / 9.0
# Кочка МЕЛЬЧЕ прежнего в полтора раза (решение пользователя 2026-08-17). Зазор
# между соседями считается в долях их радиусов, поэтому кочки заодно сели ВДВОЕ
# ГУЩЕ — расстояние ужалось вместе с размером, а густота идёт от него в квадрате.
const BODY_WIDE: float = 0.92               # радиус тела в долях «М»
const BODY_RISE: float = 0.58               # высота тела в долях его радиуса
const RIM_SINK: float = 0.10                # на сколько обод утоплен в землю
# ВОРС СТОИТ КОЛЬЦАМИ — по разрезу, нарисованному пользователем. Прежде он
# сеялся по золотому углу, ровно по площади; на глаз это россыпь, а на разрезе
# видно другое: ворсинки идут поясами от обода к макушке, и чем ближе к ободу,
# тем сильнее завалены наружу. Завал считать не нужно — он сам берётся из наклона
# купола в этом месте.
#
# Не меньше пяти-шести на кольцо (решение пользователя): реже — и кольцо
# перестаёт читаться кольцом, распадаясь на отдельные торчки.
const FUZZ_RINGS := [0.32, 0.64, 0.90]      # где идут пояса, в долях радиуса
const FUZZ_PER_RING: int = 6
const FUZZ_CROWN: int = 3                   # ещё столько на самой макушке
const FUZZ_MIN: int = 4
# ДЛИНА ВОРСИНКИ — не короче половины радиуса кочки (решение пользователя).
# Мерить её в долях «М», как раньше, больше нельзя: кочка с возрастом ширится
# вдвое с лишним, и ворс, привязанный к «М», на взрослой терялся бы щетинкой.
# Оба правила оставлены, берётся большее из них.
const FUZZ_TALL: float = 0.62               # рост ворсинки в долях «М»
const FUZZ_OF_SPAN: float = 0.5             # ... и в долях радиуса кочки
# Куда по картинке смотрит тело кочки — в долях СПЛОШНОГО ПРЯМОУГОЛЬНИКА клетки,
# а не самой клетки.
#
# ГРАБЛИ: сперва тело брало нутро клетки на глазок, 45–85% её высоты. У молодых
# возрастов куртинка нарисована только у нижнего края, выше прозрачный фон, а
# движок режет по порогу — и у кочки МЛАДШЕ СЕДЬМОЙ СТУПЕНИ ПРОСВЕЧИВАЛ ЦЕНТР:
# макушка тела попадала в пустоту. К седьмой рисунок дорастал, и дыра сама
# закрывалась. Теперь сплошной прямоугольник у каждой клетки НАХОДИТСЯ ПО САМОЙ
# КАРТИНКЕ при запуске, поэтому дыр не будет ни при какой рисовке.
# СТОРОНА ОДНОЙ ТОЧКИ ОБРАЗЦА В МИРЕ — этим числом и задаётся, насколько мох
# пиксельный. Больше — точка крупнее и мха на кочке умещается меньше. От размера
# кочки не зависит: на крупной точек просто больше, и потому заросль читается
# одной поверхностью, а не набором наклеек разного калибра.
const BODY_TEXEL: float = 0.009
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

# ЗА ЖИЗНЬ КУРТИНА ШИРИТСЯ ВДВОЕ (решение пользователя 2026-08-17, предел поднят
# 2026-08-20).
#
# Пробовали и вдвое с лишним (молодая не доставала до соседей вовсе, заросль
# стояла россыпью), и всего на четверть (роста не видно). Полтора было серединой:
# место кочке отводится по взрослой мерке, и пока она мала, между соседями видна
# земля; к зрелости она это место занимает и смыкается с ними.
#
# Разницу между соседями при этом даёт не возраст, а собственный размер
# (`BULK_MIN`…`BULK_MAX`) — на него и приходится весь разнобой.
const PATCH_YOUNG: float = 0.97             # радиус на первой ступени, в долях М
const PATCH_OLD: float = 1.885              # ... и на девятой; по ней и печём

# РАСПЛЮЩИВАНИЕ К СТАРОСТИ (решение пользователя 2026-08-20). Предел разброса
# вширь поднят на 30% — было 1.45, стало 1.885, — а В ВЫСОТУ КОЧКА ЭТУ ПРИБАВКУ
# НЕ БЕРЁТ.
#
# Одной прибавки к ширине мало: `BODY_RISE` — доля радиуса, и высота пошла бы за
# ней сама собой. Кочка выросла бы вся целиком на треть, а форма осталась бы
# прежней — это рост, а не расплющивание. Поэтому долю радиуса убавляем ровно во
# столько же раз: ширина прибавила, высота осталась та, что была. Живой мох к
# старости и стелется лепёшкой, а не растёт вверх.
#
# Считать это надо В ОДНОМ МЕСТЕ (`_flat_of`): высоту спрашивают трое — само
# тело, поле соседей и замер срастания, — и разойдись они хоть на волос, кочка
# станет считать чужой бугор не тем, что рисуется, и в перемычке прорежется щель.
const BODY_FLAT: float = 1.30

func _flat_of(m: float) -> float:
	return lerpf(1.0, 1.0 / BODY_FLAT, clampf(m, 0.0, 1.0))

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


# Тот же срез, но ПО ТАБЛИЦЕ. Слияние с соседями спрашивает высоту чужого купола
# для каждой точки тела и каждого соседа — это сотня с лишним обращений на кочку
# за перестройку, а в самом срезе две степени. Таблицу считаем один раз.
func _profile_fast(t: float) -> float:
	if t <= 0.0:
		return 1.0
	if t >= 1.0:
		return 0.0
	var f: float = t * float(PROF_STEPS)
	var i: int = int(f)
	return lerpf(_prof_lut[i], _prof_lut[i + 1], f - float(i))


# ГДЕ КОЧКА УПИРАЕТСЯ В СОСЕДЕЙ. Для каждого сектора: докуда он дожил (доля от
# полного вылета) и на какой высоте кончился.
#
# Шов между двумя кочками — плоскость, делящая расстояние между серединами в
# отношении их радиусов. Бок кочки на нём кончается, сосед со своей стороны
# кончается на том же шве, и обе стенки растут от него к своим макушкам: это и
# есть седловина. Высоту шва оба считают по одной формуле от общих величин,
# поэтому сходятся вплотную, а не ступенькой.
#
# ЕДИНСТВЕННОЕ место, где решается срастание: и отрисовка, и самопроверка ходят
# сюда. Отдельная копия для замера рано или поздно разошлась бы с рисуемым.
func _seam_cut(rim: Array, up: Vector3, k: float, kin_t: Array,
		kin_r: PackedFloat32Array, kin_weld: PackedFloat32Array,
		span: float) -> PackedFloat32Array:
	var cut := PackedFloat32Array()
	cut.resize(rim.size())
	for s in range(rim.size()):
		var o: Vector3 = Vector3(rim[s]["off"]) * k
		var flat: Vector3 = o - up * o.dot(up)
		var reach: float = flat.length()
		var keep: float = 1.0
		if reach > 0.0001:
			var d: Vector3 = flat / reach
			for i in range(kin_t.size()):
				var to: Vector3 = Vector3(kin_t[i])
				var gap: float = to.length()
				if gap < 0.0001:
					continue
				var lean: float = d.dot(to / gap)
				if lean <= 0.05:
					continue             # граница в стороне, сектор не задет
				# Пока пара не срослась, границу не проводим вовсе: молодая кочка
				# должна стоять кругляшом сама по себе, а не быть обрезанной по
				# соседу, с которым она ещё не слилась.
				var lim: float = (gap * span / (span + kin_r[i])) / lean
				var soft: float = lerpf(reach, lim, kin_weld[i])
				if soft < reach * keep:
					keep = soft / reach
		# Совсем в точку сектор не сжимаем: у слишком близкой пары граница прошла
		# бы у самой середины, и от кочки остались бы вырожденные лоскуты.
		cut[s] = maxf(keep, 0.25)
	return cut


# СОСЕДИ, ПРИВЕДЁННЫЕ К СВОЕЙ СИСТЕМЕ: смещение вбок и радиус. Считается один раз
# на кочку, а спрашивается на каждой её вершине.
#
# Высота земли под соседом сюда НЕ ВХОДИТ нарочно: поле — это толщина мха над
# землёй, а не высота над чьей-то серединой. Иначе на склоне сосед сверху дарил
# бы нижней кочке полсклона высоты, и мох всплывал бы над рельефом.
func _neighbours(p: Dictionary, centre: Vector3, up: Vector3, span: float) -> Array:
	var kin_t: Array = []
	var kin_r := PackedFloat32Array()
	var kin_top := PackedFloat32Array()
	var kin_weld := PackedFloat32Array()
	for nb in p.get("near", []):
		if not patches.has(nb):
			continue                     # сосед погиб; список нарочно не чистится
		var q: Dictionary = patches[nb]
		var qs: float = _patch_span(float(q["m"]), float(q["bulk"]))
		var off: Vector3 = Vector3(q["pos"]) - centre
		var flat: Vector3 = off - up * off.dot(up)
		var side_len: float = flat.length()
		if side_len > qs + span:
			continue                     # ещё не дорос до нас
		# СОСЕД ЗА ПЕРЕГИБОМ — НЕ СОСЕД. Поле считается в своей касательной
		# плоскости, и кочка с другой стороны гребня проецируется в неё близко,
		# хотя по земле до неё далеко. Сливаясь с такой, кочка тянулась поперёк
		# перегиба и отрывалась от склона. Две проверки: земля под соседом должна
		# смотреть примерно туда же, и настоящее расстояние не должно быть много
		# больше проекции.
		if Vector3(q["nrm"]).dot(up) < GROUND_TURN:
			continue
		if side_len < 0.0001 or off.length() > side_len * 1.6:
			continue
		kin_t.append(flat)
		kin_r.append(qs)
		# Пухлость у соседа СВОЯ, и её надо знать: поле складывается из чужих
		# бугров, а не из своего, натянутого на чужой радиус.
		kin_top.append(qs * BODY_RISE * float(q["body"]["rise"])
			* _flat_of(float(q["m"])))
		# Насколько эта пара уже срослась. По МЛАДШЕЙ из двух: слиться в одиночку
		# нельзя, и взрослая кочка не должна втягивать в себя молодую.
		kin_weld.append(minf(_weld_of(float(p["m"])), _weld_of(float(q["m"]))))
	return [kin_t, kin_r, kin_top, kin_weld]


# Насколько кочка этой зрелости готова сливаться с соседями: до пятой ступени
# ноль, дальше плавно до единицы к девятой.
func _weld_of(m: float) -> float:
	return clampf((m - MERGE_FROM) / (1.0 - MERGE_FROM), 0.0, 1.0)


# МЯГКИЙ МАКСИМУМ. Обычный даёт на стыке двух бугров острую складку — след от
# того, что тут кончился один и начался другой. Мягкий скругляет её перемычкой
# шириной `k`: две сошедшиеся кочки сливаются так же, как сливаются две лужи.
static func _smax(a: float, b: float, k: float) -> float:
	var h: float = clampf(0.5 + 0.5 * (a - b) / k, 0.0, 1.0)
	return lerpf(b, a, h) + k * h * (1.0 - h)


# РАЗБРОС РАЗМЕРОВ: наименьший, наибольший и насколько в среднем разнятся СОСЕДИ.
#
# Третье число и проверяет правило «рядом с крупной сидят крупные». Размер
# наследуется, значит у соседей он должен различаться заметно меньше, чем размах
# по всей заросли; будь он случайным, разница соседей вышла бы примерно в треть
# размаха. Только для самопроверки.
# СТОИТ ЛИ КОЧКА ПОПЕРЁК СКЛОНА: наибольший наклон её оси от мировой вертикали и
# наибольший наклон самой земли под кочками, в градусах. Числа должны совпадать —
# ось кочки и есть нормаль земли. Разойдутся — значит, где-то мировой верх
# просочился туда, где ему не место.
func tilt_stats() -> Vector2:
	var axis := 0.0
	var land := 0.0
	for pid in patches:
		var p: Dictionary = patches[pid]
		if _is_stem(PlantsData.ITEMS[p["id"]]):
			continue                 # у стебля купола нет, мерить нечего
		axis = maxf(axis, acos(clampf(Vector3(p["body"]["up"]).dot(Vector3.UP),
			-1.0, 1.0)))
		var spot: Dictionary = main.grid.surface_near(p["pos"])
		if not spot.is_empty():
			land = maxf(land, acos(clampf(Vector3(spot["nrm"]).dot(Vector3.UP),
				-1.0, 1.0)))
	return Vector2(rad_to_deg(axis), rad_to_deg(land))


func size_stats() -> Vector3:
	var low := 9.0
	var high := 0.0
	var apart := 0.0
	var pairs := 0.0
	for pid in patches:
		if _is_stem(PlantsData.ITEMS[patches[pid]["id"]]):
			continue                 # размер стебля даёт возраст, а не разброс
		var mine: float = float(patches[pid]["bulk"])
		low = minf(low, mine)
		high = maxf(high, mine)
		for nb in patches[pid].get("near", []):
			if not patches.has(nb):
				continue
			apart += absf(mine - float(patches[nb]["bulk"]))
			pairs += 1.0
	if patches.is_empty():
		return Vector3.ZERO
	return Vector3(low, high, apart / maxf(1.0, pairs))


# НАСКОЛЬКО КОЧКИ СРОСЛИСЬ: какая доля боков упёрлась в соседа и насколько высоко
# по своей высоте проходит шов. Второе и есть седловина: ноль — кочки только
# коснулись у земли, единица — срослись по самую макушку.
#
# Только для самопроверки. Единый силуэт виден на кадре, а кадров я не сужу —
# значит, у него должно быть число.
func merge_stats() -> Vector2:
	var joined := 0.0
	var pairs := 0.0
	var saddle := 0.0
	for pid in patches:
		var p: Dictionary = patches[pid]
		if _is_stem(PlantsData.ITEMS[p["id"]]):
			continue                 # стебель ни с кем не срастается
		var body: Dictionary = p["body"]
		var centre: Vector3 = p["pos"]
		var up: Vector3 = body["up"]
		var span: float = _patch_span(float(p["m"]), float(p["bulk"]))
		var high: float = span * BODY_RISE * float(body["rise"]) \
			* _flat_of(float(p["m"]))
		var kin: Array = _neighbours(p, centre, up, span)
		var kin_t: Array = kin[0]
		var kin_r: PackedFloat32Array = kin[1]
		var kin_top: PackedFloat32Array = kin[2]
		var kin_weld: PackedFloat32Array = kin[3]
		var best := 0.0
		for i in range(kin_t.size()):
			pairs += 1.0
			# Перемычка меряется НА ПОЛПУТИ до соседа: там поле ниже всего, и
			# только там видно, слились кочки или лишь коснулись. Землю из-под
			# перемычки вычитаем — иначе на склоне уклон пошёл бы в зачёт
			# срастания, и число врало бы в свою пользу.
			var mid: Vector3 = Vector3(kin_t[i]) * 0.5
			var own: float = high * _profile_fast(minf(mid.length() / span, 1.0))
			var d: float = (mid - Vector3(kin_t[i])).length() / kin_r[i]
			var his: float = kin_top[i] * (_profile_fast(d) if d < 1.0 else 0.0)
			# В долях НИЗШЕЙ из двух макушек: сотня значит, что провала между
			# кочками нет вовсе, ноль — что они сошлись у самой земли.
			var lowest: float = maxf(0.0001, minf(high, kin_top[i]))
			# Слияние вводится постепенно — меряем ровно то, что рисуется.
			var neck: float = lerpf(own, _smax(own, his, high * FIELD_BLEND),
				kin_weld[i])
			best = maxf(best, neck / lowest)
		if not kin_t.is_empty():
			joined += 1.0
			saddle += best
	return Vector2(pairs / maxf(1.0, float(patches.size())),
		saddle / maxf(1.0, joined))


# РАДИУС КОЧКИ на этой зрелости. Спрашивают двое: своя отрисовка и слияние —
# соседу надо знать, докуда дотянулся чужой купол.
func _patch_span(m: float, bulk: float) -> float:
	var stage_no: float = clampf(m * float(STAGES) + 0.5, 1.0, float(STAGES))
	return main.CELL_SPACING * ADULT_SIZE * BODY_WIDE * bulk \
		* lerpf(PATCH_YOUNG, PATCH_OLD, (stage_no - 1.0) / float(STAGES - 1))


# Размер отростка. Родительский, чуть убавленный и сбитый разбросом — см.
# `BULK_MIN`: убавление ведёт мельчание от крупной кочки к краю пятна, разброс
# местами его перебивает, и порядок не читается порядком.
func _child_bulk(parent: float) -> float:
	return clampf(parent - BULK_FADE
		+ _rng.randf_range(-BULK_DRIFT, BULK_DRIFT * 1.4), BULK_MIN, BULK_MAX)


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
# ГДЕ ЗЕМЛЯ В ЭТУ СТОРОНУ НА ТАКОМ УДАЛЕНИИ. Смещение от середины кочки, либо
# ноль, если земли там нет.
#
# ПРОВЕРКИ ЖЁСТКИЕ, и это главное. `surface_near` ищет землю в полутора ячейках
# вокруг точки, то есть может вернуть место почти за три метра; прежний допуск
# пускал внутрь всё, что ближе ДВУХ задуманных радиусов, и с нормалью, отвёрнутой
# почти на прямой угол. На ровном месте это не мешало, а на изломе склона обод
# уезжал вдвое дальше своей мерки и заворачивался за перегиб — кочку растягивало
# в плоское полотнище, торчащее из склона. Ровно это и было видно на кадре.
#
# Теперь место должно быть ТАМ, КУДА ЦЕЛИЛИСЬ (четверть допуска на длину) и на
# СВОЕЙ СТОРОНЕ рельефа (нормаль не круче ~57° к своей).
const GROUND_LONG: float = 1.25             # насколько дальше цели допустимо
const GROUND_SHORT: float = 0.55            # ... и насколько ближе
const GROUND_TURN: float = 0.55             # и как круто может завернуться земля
const MID_RING: float = 0.58                # где щупаем середину бока

func _ground_at(centre: Vector3, nrm: Vector3, dir: Vector3, want: float) -> Vector3:
	var on: Dictionary = main.grid.surface_near(centre + dir * want)
	if on.is_empty():
		return Vector3.ZERO
	var off: Vector3 = Vector3(on["pos"]) - centre
	var d: float = off.length()
	if d > want * GROUND_LONG or d < want * GROUND_SHORT:
		return Vector3.ZERO
	if Vector3(on["nrm"]).dot(nrm) < GROUND_TURN:
		return Vector3.ZERO
	return off


func _make_cushion(spot: Dictionary, def: Dictionary, salt: int,
		bulk: float) -> Dictionary:
	var centre: Vector3 = spot["pos"]
	# ОСЬ КОЧКИ — НОРМАЛЬ ЗЕМЛИ, а не мировая вертикаль: на склоне подушка стоит
	# поперёк склона, как ей и положено. Мировой верх нужен здесь ровно один раз
	# и только чтобы построить хоть какую-то раму поперёк оси.
	var nrm: Vector3 = spot["nrm"]
	var side: Vector3 = nrm.cross(Vector3.UP)
	if side.length_squared() < 0.001:
		side = nrm.cross(Vector3.RIGHT)
	side = side.normalized()
	var along: Vector3 = nrm.cross(side).normalized()
	# СВОЙ ПОВОРОТ вокруг оси (решение пользователя 2026-08-17). Рама строилась от
	# мировой вертикали, поэтому у всех кочек нулевой сектор смотрел в одну и ту
	# же сторону света: неровности обода и бугорки повторялись от кочки к кочке
	# одинаково развёрнутыми, и заросль читалась штампом, сколько ни разбрасывай
	# размеры.
	var turn: float = TAU * _hash01(salt + 4241)
	var spun: Vector3 = side * cos(turn) + along * sin(turn)
	along = side * -sin(turn) + along * cos(turn)
	side = spun

	# Растяжка пятна вдоль подъёма. Ею рисовалась ЛИАНА, пока была подушкой,
	# вытянутой по склону; теперь у неё стебель, и сюда она не заходит вовсе.
	# Правило остаётся: сильнее полутора раз растягивать нельзя — кочка
	# вырождается в лезвие.
	var creep: float = 1.0

	var reach: float = main.CELL_SPACING * ADULT_SIZE * BODY_WIDE * PATCH_OLD * bulk
	var rings: int = RING_AT.size()
	var rim: Array = []
	var holds := 0
	var short_len := INF
	var sum_lift := 0.0
	for s in range(SECTORS):
		var a: float = TAU * float(s) / float(SECTORS)
		# Радиус у каждого сектора свой — отсюда неправильный многоугольник
		# сверху. Ровный круг сразу читается штампом, повторённым сотни раз.
		var wob: float = 0.78 + 0.42 * _hash01(salt + s * 7717)
		var dir: Vector3 = (side * (cos(a) * creep) + along * sin(a)).normalized()
		var far: float = reach * wob
		# Не нашлось на полном радиусе — подбираем сектор ближе к середине. Кочка
		# у кромки выйдет кривобокой, но целой.
		var off := Vector3.ZERO
		var used: float = far
		# Лесенка подбора частая: у кромки обрыва земля кончается где-то посередине
		# луча, и чем мельче шаг, тем ближе к настоящему краю сядет обод.
		for k in [1.0, 0.82, 0.66, 0.52, 0.40, 0.30]:
			off = _ground_at(centre, nrm, dir, far * k)
			if off != Vector3.ZERO:
				used = far * k
				break
		# СЕРЕДИНУ БОКА ЩУПАЕМ ОТДЕЛЬНО. По одному ободу тело идёт от середины к
		# краю ПО ХОРДЕ, а хорда на перегибе уходит и в землю, и в воздух: на
		# гребне кочка выгибалась горбом, в ложбине повисала. Двух точек на луч
		# хватает, чтобы бок повторил склон.
		var mid := Vector3.ZERO
		if off != Vector3.ZERO:
			mid = _ground_at(centre, nrm, dir, used * MID_RING)
			if mid == Vector3.ZERO:
				mid = off * MID_RING
			holds += 1
			short_len = minf(short_len, off.length())
			sum_lift += off.dot(nrm)
		var lump := PackedFloat32Array()
		lump.resize(rings)
		for r in range(rings):
			lump[r] = 0.90 + 0.20 * _hash01(salt + s * 131 + r * 977)
		rim.append({"off": off, "mid": mid, "dir": dir, "lump": lump})

	# Ни одного сектора не нашло земли — кочке негде лежать.
	if holds == 0:
		return {}
	# ПРОВАЛИВШИЙСЯ СЕКТОР ПОДЖИМАЕМ ВНУТРЬ, а не достраиваем наружу.
	#
	# ГРАБЛИ, свои же: сперва такой сектор дотягивался до СРЕДНЕЙ длины удавшихся
	# и клался в касательную плоскость. А проваливается сектор ровно там, где
	# земля уходит из-под него — на кромке обрыва. Средняя длина в касательной
	# плоскости — это точка В ВОЗДУХЕ за кромкой: кочки повисали над склоном, а
	# рядом с длинным сектором оказывался короткий, и треугольник между ними
	# растягивало в полотнище.
	#
	# Теперь наоборот: берём САМЫЙ КОРОТКИЙ из удавшихся, ещё поджатый. Дальше
	# земли, которую нашли, кочка не вылезет ни при каких обстоятельствах.
	if holds < SECTORS:
		_stub_sectors += SECTORS - holds
		var stub: float = short_len * 0.8
		var lift_avg: float = sum_lift / float(holds)
		for s in range(SECTORS):
			if rim[s]["off"] != Vector3.ZERO:
				continue
			var patch: Vector3 = Vector3(rim[s]["dir"]) * stub \
				+ nrm * (lift_avg * stub / maxf(short_len, 0.0001))
			rim[s]["off"] = patch
			rim[s]["mid"] = patch * MID_RING

	# ОБОД РАЗГЛАЖИВАЕМ ПО КРУГУ. Сосед сектора не должен быть вдвое длиннее:
	# такая ступенька и даёт вытянутые лоскуты, которые на кадре читаются
	# искажением. Только укорачиваем — удлинять нельзя, за длиной стоит найденная
	# земля, а за укорочением ничего не стоит.
	for _pass in range(2):
		var was := PackedFloat32Array()
		was.resize(SECTORS)
		for s in range(SECTORS):
			was[s] = Vector3(rim[s]["off"]).length()
		for s in range(SECTORS):
			var lo: float = minf(was[(s + SECTORS - 1) % SECTORS],
				was[(s + 1) % SECTORS])
			var cap: float = lo * RIM_STEP
			if was[s] > cap and was[s] > 0.0001:
				var squeeze: float = cap / was[s]
				rim[s]["off"] = Vector3(rim[s]["off"]) * squeeze
				rim[s]["mid"] = Vector3(rim[s]["mid"]) * squeeze

	return {
		"up": nrm, "rim": rim,
		"age": _hash01(salt + 577),
		"shade": 0.92 + 0.14 * _hash01(salt + 1223),
		# Пухлость своя у каждой: при одной на всех кочки одного размера выходят
		# слепками друг друга, и разброс размера этого не спасает.
		"rise": 0.85 + 0.30 * _hash01(salt + 1777),
		# И СВОЙ КУСОК ОБРАЗЦА. Клетка тела сплошная, значит по ней можно ездить
		# как угодно: сдвиг заворачивается внутри той же клетки и наружу не
		# вылезает. Без него у всех кочек одна и та же зелень в одних и тех же
		# местах — на глаз это и есть «все одинаковые».
		"warp": Vector2(_hash01(salt + 2683), _hash01(salt + 3407)),
	}


# =============================================================================
#  СТЕБЕЛЬ ЛИАНЫ — ТРУБКА ОТ РОДИТЕЛЯ
# =============================================================================
#
# Звено рисует ОДНО колено: от того, от кого оно отросло, до себя. Вся плеть
# складывается сама собой — каждое звено кладёт свой кусок, и цепочка выходит
# сплошной. Корень колена не рисует: ему не от чего.
#
# ТОЛЩИНУ ДАЁТ ВОЗРАСТ ЗВЕНА, и отдельно её считать не нужно. Корень родился
# первым и первым же дорос, кончик — последним; значит, «толще у земли, тоньше к
# верхушке» получается само, безо всякой записи о том, сколько над кем висит.
#
# РАМУ ВЕДЁМ ОТ ЗЕМЛИ, а не откуда придётся. У двух колен, сошедшихся в одном
# звене, оси разные, и рамы, построенные каждая от своей оси, разъезжаются — на
# стыке трубка выворачивается винтом. Общая земля под ними держит их рядом.
const STEM_SIDES: int = 8                   # граней у трубки
const STEM_LIFT: float = 1.30               # на сколько своих радиусов приподнята
const STEM_SAG: float = 0.50                # запас на перегиб, в долях длины колена
const ROOT_STUB: float = 2.6                 # насколько корень уходит в землю, в радиусах
const ROOT_FLARE: float = 1.6               # и во сколько раз он там шире — наплыв
# И НЕ МЕНЬШЕ ЭТОГО, в метрах, сколько бы тонок ни был корень.
#
# ГРАБЛИ, с кадра: глубину считали ТОЛЬКО в радиусах, а у только что посаженной
# лианы радиус пять миллиметров — значит, срез прятался под землю всего на
# полсантиметра. На бугре, на склоне, да просто при взгляде сбоку он вылезал
# наружу, и лоза читалась «начинающейся со среза».
const ROOT_DEEP: float = 0.06
const TIP_DOME: float = 0.85                # высота куполка на кончике, в радиусах
const RIDE_THICKER: float = 1.25            # во сколько раз чужое звено должно быть толще
const RIDE_GAP: float = 0.004               # зазор при переползании, м
# Сколько своих же звеньев вверх по цепи побег не считает теснотой — см.
# `_stem_crowd`. Спираль замыкается через пять-восемь звеньев, отсюда и число.
const CROWD_BACK: int = 8
# А по стольким звеньям меряется закрутка — см. `vine_stats`. Виток спирали на
# кадре укладывался примерно в дюжину звеньев.
const COIL_BACK: int = 12
# СКОЛЬКО ПОБЕГУ ПОЗВОЛЕНО НАКРУТИТЬ В ОДНУ СТОРОНУ, и насколько быстро он это
# забывает. При забывании в 0.85 память держится около семи звеньев, а мерка в
# 140° отвечает примерно двадцати градусам поворота на звено подряд — виться
# можно, сматываться в моток нельзя.
const SPIN_FADE: float = 0.85
const SPIN_MAX: float = 2.44               # 140° в радианах
# ДОКУДА КОЛЕНО ЕЩЁ КОЛЕНО, в долях самого длинного шага отростка. Дальше это уже
# не стебель, а растянутая через полкарты палка — см. `_stem_max`.
const STEM_STRETCH: float = 2.2

# Предельная длина колена. Считаем от самого длинного шага отростка, а не числом:
# поменяется шаг — мерка поедет за ним сама.
func _stem_max(def: Dictionary = {}) -> float:
	return main.CELL_SPACING * float(def.get("step_far", SPREAD_FAR)) * STEM_STRETCH


# КОЛЬЦО ПРИНАДЛЕЖИТ ЗВЕНУ, А НЕ КОЛЕНУ.
#
# ГРАБЛИ: сперва каждое колено строило себе ОБА кольца от своей оси. У двух колен,
# сошедшихся в одном звене, оси разные — значит, и кольца разные, и на изгибе
# между ними зияет клин. На кадре стебель читался не веткой, а нанизанными
# обрубками.
#
# Теперь кольцо считается только по тому, ОТКУДА ЗВЕНО ВЫРОСЛО. Все колена, что в
# нём сходятся, берут одно и то же кольцо и сходятся точно — как столярный ус.
# Для исходящего колена кольцо выходит косым, но это и правильно: у гнутой трубы
# срез на изгибе косой.
func _stem_ring(p: Dictionary, def: Dictionary) -> Dictionary:
	var nrm: Vector3 = p["nrm"]
	# ТОЛЩИНУ ДАЁТ НЕ ВОЗРАСТ, А НОША. Прежде радиус шёл от зрелости звена, и
	# разницы почти не было видно: звено взрослеет за десяток секунд, и вся плеть
	# быстро становилась одинаково толстой. Теперь считаем, сколько звеньев висит
	# НИЖЕ по течению (`load`): у основания это вся лиана, у кончика ноль. Так
	# толщина и устроена у живой лозы — стебель держит то, что над ним.
	var full: float = maxf(1.0, float(def.get("load_full", 120.0)))
	var t: float = pow(clampf(float(p.get("load", 0)) / full, 0.0, 1.0), 0.35)
	var r: float = lerpf(float(def.get("stem_thin", 0.005)),
		float(def.get("stem_thick", 0.030)), t)
	var from: int = int(p.get("from", -1))
	# ОСЬ КОЛЬЦА — БИССЕКТРИСА, а не направление входа.
	#
	# ГРАБЛИ: кольцо стояло поперёк ВХОДЯЩЕГО колена. Для исходящего оно тогда
	# косое, и на крутом повороте косой срез сплющивается в складку — на кадре
	# трубка ломается треугольником. Биссектриса делит угол пополам: оба колена
	# встречают кольцо одинаково, и сечение остаётся кругом, лишь слегка вытянутым.
	var in_dir := Vector3.ZERO
	if patches.has(from):
		var d: Vector3 = Vector3(p["pos"]) - Vector3(patches[from]["pos"])
		if d.length_squared() > 0.000001:
			in_dir = d.normalized()
	var out_dir: Vector3 = p.get("out", Vector3.ZERO)
	var axis: Vector3 = in_dir + out_dir
	if axis.length_squared() < 0.000001:
		axis = in_dir if in_dir.length_squared() > 0.000001 else nrm
	axis = axis.normalized()
	var side: Vector3 = axis.cross(nrm)
	if side.length_squared() < 0.000001:
		side = axis.cross(Vector3.RIGHT)
	if side.length_squared() < 0.000001:
		side = axis.cross(Vector3.UP)
	side = side.normalized()
	# ПОДЪЁМ НАД ЗЕМЛЁЙ — С ЗАПАСОМ НА ПЕРЕГИБ. Одного радиуса мало: колено идёт
	# от звена к звену ПО ПРЯМОЙ, а земля между ними выгнута, и середина хорды
	# уходит под неё. На кадре это лоза, ныряющая в камень. Запас берём по тому,
	# насколько разошлись нормали: на ровном он нулевой, на перегибе растёт сам.
	var lift: float = r * STEM_LIFT
	if patches.has(from):
		var bend: float = 1.0 - clampf(nrm.dot(Vector3(patches[from]["nrm"])),
			-1.0, 1.0)
		lift += STEM_SAG * Vector3(p["pos"]).distance_to(patches[from]["pos"]) * bend
	return {"at": Vector3(p["pos"]) + nrm * lift, "r": r, "axis": axis,
		"side": side, "turn": side.cross(axis).normalized()}


func _emit_stem(st: SurfaceTool, p: Dictionary, def: Dictionary) -> bool:
	var from: int = int(p.get("from", -1))
	var mine: Dictionary = _stem_ring(p, def)
	var theirs: Dictionary
	if patches.has(from):
		theirs = _stem_ring(patches[from], def)
	else:
		# КОРЕНЬ РИСУЕТ ПЕНЁК. Колена у него нет — не от кого, — и без пенька
		# только что посаженная лиана была бы НЕВИДИМА секунды четыре, пока не
		# даст первое звено. Игрок ткнул, а на земле пусто: это читается как
		# «не сработало», и он ткнёт ещё раз.
		# КОРЕНЬ УХОДИТ В ЗЕМЛЮ, А НЕ ОБРЫВАЕТСЯ НА НЕЙ. Прежде пенёк начинался
		# ровно на поверхности, и его открытый торец читался плоским кружком,
		# приклеенным к склону. Теперь начало утоплено ниже земли — срез просто
		# не виден, — а сам корень у основания шире: у живой лозы там наплыв.
		theirs = mine.duplicate()
		theirs["at"] = Vector3(mine["at"]) - Vector3(p["nrm"]) \
			* maxf(float(mine["r"]) * ROOT_STUB, ROOT_DEEP)
		theirs["r"] = float(mine["r"]) * ROOT_FLARE
	var a: Vector3 = theirs["at"]
	var b: Vector3 = mine["at"]
	var span: float = a.distance_to(b)
	if span < 0.0001:
		return false
	# КОЛЕНО ДЛИННЕЕ МЕРКИ НЕ РИСУЕМ. Оно там неоткуда взяться при росте — шаг
	# отростка ограничен, — но при правке рельефа каждое звено пересаживается САМО
	# ПО СЕБЕ, и соседи по цепочке разъезжаются: подними игрок холм под лианой, и
	# между двумя звеньями окажется весь его склон. На кадре это толстые прямые
	# палки через полкарты.
	if span > _stem_max(def):
		return false

	var r_a: float = theirs["r"]
	var r_b: float = mine["r"]
	# Разметка коры: поперёк — ровно один оборот образца, вдоль — столько же по
	# длине. Точка выходит примерно квадратной сама собой, и подгонять её числом
	# не надо: чем толще стебель, тем крупнее на нём кора, как оно и бывает.
	var round_len: float = TAU * maxf(r_a, r_b)
	var v_far: float = span / maxf(round_len, 0.0001)
	var stage: int = clampi(int(float(p["m"]) * float(STAGES)), 0, STAGES - 1)
	st.set_uv2(Vector2(float(BARK_COL) / float(COLS), float(stage) / float(STAGES)))
	var bark: Color = def.get("stem_color", Color(0.34, 0.26, 0.17))
	st.set_color((bark * float(p["body"]["shade"])).srgb_to_linear())

	var ring_a: Array = []
	var ring_b: Array = []
	var nrms: Array = []
	for i in range(STEM_SIDES + 1):
		var ang: float = TAU * float(i) / float(STEM_SIDES)
		var out_a: Vector3 = Vector3(theirs["side"]) * cos(ang) \
			+ Vector3(theirs["turn"]) * sin(ang)
		var out_b: Vector3 = Vector3(mine["side"]) * cos(ang) \
			+ Vector3(mine["turn"]) * sin(ang)
		nrms.append([out_a, out_b])
		ring_a.append(a + out_a * r_a)
		ring_b.append(b + out_b * r_b)
	# Обход не важен: у материала стороны не отсекаются.
	for i in range(STEM_SIDES):
		var u0: float = float(i) / float(STEM_SIDES)
		var u1: float = float(i + 1) / float(STEM_SIDES)
		for k in BAND_TRI:
			var far: bool = int(k[0]) == 1
			var nxt: bool = int(k[1]) == 1
			st.set_normal(nrms[i + 1 if nxt else i][1 if far else 0])
			st.set_uv(Vector2(u1 if nxt else u0, v_far if far else 0.0))
			var ring: Array = ring_b if far else ring_a
			st.add_vertex(ring[i + 1] if nxt else ring[i])

	# КОНЧИК ЗАКРЫВАЕМ КУПОЛКОМ. У звена без продолжения трубка обрывалась
	# открытым торцом, и он читался плоским кружком, будто ветвь отпилили.
	if int(p.get("kids", 0)) == 0:
		var tip: Vector3 = (b - a).normalized()
		var top: Vector3 = b + tip * (r_b * TIP_DOME)
		for i in range(STEM_SIDES):
			st.set_normal(tip)
			st.set_uv(Vector2(0.5, v_far))
			st.add_vertex(top)
			st.set_normal((Vector3(nrms[i][1]) + tip).normalized())
			st.set_uv(Vector2(float(i) / float(STEM_SIDES), v_far))
			st.add_vertex(ring_b[i])
			st.set_normal((Vector3(nrms[i + 1][1]) + tip).normalized())
			st.set_uv(Vector2(float(i + 1) / float(STEM_SIDES), v_far))
			st.add_vertex(ring_b[i + 1])
	_emit_leaves(st, p, def, mine, theirs)
	return true


# =============================================================================
#  ЛИСТЬЯ — КАРТИНКА НА ВЫГНУТОЙ ДОЩЕЧКЕ
# =============================================================================
#
# Лист и в жизни плоский, так что дощечка тут не подделка — в отличие от мха, где
# плоская картинка врала об объёме. ВЫГИБ нужен ради вида с ребра: у ровной
# дощечки он вырождается в линию и лист пропадает, у выгнутой видна полоска.
# Выгиба два, и они разные: поперёк края подняты чашей (`leaf_bow`), вдоль кончик
# свешивается под своей тяжестью (`leaf_sag`).
#
# ЛИСТ СИДИТ НА ЧЕРЕШКЕ И РАЗВЁРНУТ К СВЕТУ (решение пользователя 2026-08-21), а
# не лежит плашмя по опоре. Отсюда три правила, и все три обязательны:
#   * от стебля лист отходит ПО СПИРАЛИ — угол берётся от номера звена, и
#     соседние листья не смотрят в одну сторону;
#   * в опору он не лезет: сторона, глядящая в камень, отводится наружу
#     (`leaf_off`) — луча тут не надо, довольно нормали земли под звеном;
#   * плоскость развёрнута вверх (`leaf_up`), потому что к свету, а свет сверху.
#
# ГУЩЕ К КОНЧИКУ. Число листьев считается по НОШЕ звена — сколько висит ниже по
# течению. У кончика она ноль, у основания вся лиана; значит, молодой прирост
# облиствен, а старая древесина внизу почти гола, как оно и есть у живой лозы.
# Своего счётчика возраста заводить не пришлось — ноша уже говорит то же самое.
const LEAF_GRID: int = 2                    # клеток у дощечки по каждой оси
const LEAF_SINK: float = 0.9                # насколько черешок утоплен в стебель
const LEAF_APART: float = 0.3               # на сколько колена отступают листья друг от друга

func _leaf_plan(p: Dictionary, def: Dictionary, ring: Dictionary,
		back: Dictionary) -> Array:
	if not def.has("leaf_long"):
		return []
	# ЛИСТ РАЗВОРАЧИВАЕТСЯ, А НЕ ВЫСКАКИВАЕТ. Звено рождается голым, и лист на нём
	# растёт вместе с ним: иначе на кончике плети лист возникал бы целиком за один
	# кадр.
	var at: float = float(def.get("leaf_at", 0.15))
	var grown: float = clampf((float(p["m"]) - at) / maxf(1.0 - at, 0.0001),
		0.0, 1.0)
	if grown <= 0.001:
		return []
	grown = grown * grown * (3.0 - 2.0 * grown)
	var load: float = clampf(float(p.get("load", 0))
		/ maxf(1.0, float(def.get("leaf_shed", 45.0))), 0.0, 1.0)
	var want: float = lerpf(float(def.get("leaf_young", 2.6)),
		float(def.get("leaf_old", 0.35)), load)
	var salt: int = int(p["salt"])
	var many: int = int(floor(want))
	# Дробный остаток — не «полтора листа», а вероятность лишнего. Считаем от
	# соли звена, а не от случайности: раскладка обязана быть одной и той же при
	# каждой пересборке, иначе листья прыгали бы на каждой ступени роста.
	if _hash01(salt + 4409) < want - floor(want):
		many += 1
	if many <= 0:
		return []
	var nrm: Vector3 = p["nrm"]
	var side: Vector3 = ring["side"]
	var turn: Vector3 = ring["turn"]
	var axis: Vector3 = ring["axis"]
	var rad: float = float(ring["r"])
	var spiral: float = deg_to_rad(float(def.get("leaf_turn", 137.5)))
	var off: float = float(def.get("leaf_off", 0.25))
	var up_love: float = float(def.get("leaf_up", 0.45))
	var vary: float = float(def.get("leaf_vary", 0.2))
	# ЛИСТ НА СТАРОМ СТЕБЛЕ КРУПНЕЕ (решение пользователя 2026-08-21): десятая
	# доля на каждое ПОКОЛЕНИЕ ВЕТВЕЙ, которое этот стебель на себе держит.
	# Поколение тут — не звено, а порядок ветвления: у ствола под ним семь-восемь
	# порядков, у кончика ноль, и лист выходит крупнее у земли примерно вдвое.
	# Считай мы по звеньям — у ствола их полторы тысячи, и лист вышел бы с куст.
	var gen: int = maxi(0, int(p.get("kidorder", 0)) - int(p.get("order", 0)))
	var long_at: float = float(def["leaf_long"]) * grown \
		* (1.0 + float(def.get("leaf_gen", 0.0)) * float(gen))
	var wide_at: float = float(def.get("leaf_wide", 0.95))
	# Молодой прирост светлее старого — на живой лозе это первое, что видно.
	var tone: float = lerpf(1.10, 0.92, load) * float(p["body"]["shade"])
	# КУДА СМОТРИТ «НАРУЖУ» в плоскости кольца — по ней и разводим листья.
	var out_ref: Vector3 = nrm - axis * nrm.dot(axis)
	if out_ref.length_squared() < 0.000001:
		out_ref = side
	out_ref = out_ref.normalized()
	var out_turn: Vector3 = axis.cross(out_ref).normalized()
	# Дуга, в которую заворачивается полный круг: лист не смотрит в опору, но и
	# соседние листья не сходятся в одну сторону.
	var arc: float = acos(clampf(off, -1.0, 1.0))
	var root: Vector3 = back.get("at", ring["at"])
	var root_r: float = float(back.get("r", ring["r"]))
	# У КОРНЯ «НАЗАД» — ЭТО ПЕНЁК ПОД ЗЕМЛЁЙ, и отступать туда листу нельзя: он
	# оказался бы закопан. Корню все листья садятся на него самого.
	if not patches.has(int(p.get("from", -1))):
		root = ring["at"]
		root_r = float(ring["r"])
	var out: Array = []
	for i in range(many):
		# СПИРАЛЬ ВЕДЁТСЯ ОТ НОМЕРА ЗВЕНА, и листья одного звена продолжают ту же
		# спираль, а не расходятся звёздочкой.
		var ang: float = spiral * float(int(p.get("rank", 0)) + i) \
			+ _hash01(salt + i * 131 + 17) * 0.6
		# В ОПОРУ ЛИСТ НЕ ЛЕЗЕТ, и это не обрезка, а ЗАВОРОТ круга в дугу.
		#
		# ГРАБЛИ, видные на кадре: сторону, глядящую в камень, отводили наружу
		# прибавкой нормали. Два листа, смотревшие в камень под разными углами,
		# после такой прибавки смотрели ПОЧТИ ОДИНАКОВО — и вставали парой, один
		# поверх другого. Заворот же сжимает весь круг в дугу перед опорой: ни
		# один лист в камень не смотрит, а порядок и разница между ними целы.
		var turn_at: float = wrapf(ang, -PI, PI) / PI * arc
		var away: Vector3 = out_ref * cos(turn_at) + out_turn * sin(turn_at)
		var along: Vector3 = (away + Vector3.UP * up_love).normalized()
		# Плоскость листа — к свету, то есть вверх. Выродится (лист смотрит прямо
		# в небо) — берём плоскость, в которой лежит сам стебель.
		var face: Vector3 = Vector3.UP - along * along.dot(Vector3.UP)
		if face.length_squared() < 0.02:
			face = axis - along * along.dot(axis)
		if face.length_squared() < 0.000001:
			face = along.cross(Vector3.RIGHT)
		face = face.normalized()
		var wide: Vector3 = face.cross(along).normalized()
		var long: float = long_at * (1.0 + vary * (_hash01(salt + i * 313 + 71) - 0.5) * 2.0)
		# ЛИСТЬЯ ОДНОГО ЗВЕНА СИДЯТ НЕ В ОДНОЙ ТОЧКЕ, А ВДОЛЬ КОЛЕНА.
		#
		# ГРАБЛИ, с кадра: у живой лозы лист сидит в узле, по одному, и «два-три
		# листа на звено» — наша стилизация ради густоты. Посаженные в одну точку,
		# они и читались парой из одного места. Разводим их по колену: последний
		# у самого звена, прочие отступают назад, к родителю.
		var slot: float = 1.0 - float(many - 1 - i) * LEAF_APART
		var seat: Vector3 = root.lerp(Vector3(ring["at"]), clampf(slot, 0.0, 1.0))
		var seat_r: float = lerpf(root_r, rad, clampf(slot, 0.0, 1.0))
		out.append({
			"at": seat + away * (seat_r * LEAF_SINK),
			"along": along, "face": face, "wide": wide,
			"long": long, "half": long * wide_at * 0.5,
			"kind": int(_hash01(salt + i * 617 + 29) * float(LEAF_KINDS)) % LEAF_KINDS,
			"flip": _hash01(salt + i * 97 + 5) < 0.5, "shade": tone,
		})
	return out


func _emit_leaves(st: SurfaceTool, p: Dictionary, def: Dictionary,
		ring: Dictionary, back: Dictionary) -> void:
	var plan: Array = _leaf_plan(p, def, ring, back)
	if plan.is_empty():
		return
	# Цвет вида берём БЕЗ его темноты и подмешиваем наполовину — та же мерка, что
	# и у кочки: на полную он перекрасил бы картинку в свой цвет, стирая всю
	# проработку, ради которой она и рисуется.
	var c: Color = def["color"]
	var lum: float = maxf(0.001, (c.r + c.g + c.b) / 3.0)
	var hue := Color(1.0, 1.0, 1.0).lerp(
		Color(c.r / lum, c.g / lum, c.b / lum), 0.5)
	var stage: int = clampi(int(float(p["m"]) * float(STAGES)), 0, STAGES - 1)
	# РАЗМЕТКУ ЗАВОДИМ ВНУТРЬ КЛЕТКИ НА ПОЛТОЧКИ, а не по её краю.
	#
	# ГРАБЛИ, и на кадре они выглядели загадочно: по краю каждого листа шла тонкая
	# белая черта. Это не черта, а СОСЕДНИЙ СТОЛБЕЦ ЛИСТА — кора, она серая почти
	# добела и сплошная, то есть прозрачностью не отсекается. Край дощечки лежал
	# ровно на границе клеток, а разметка по треугольнику считается с округлением
	# — и крайняя точка кадра нет-нет да и брала точку слева. Полточки внутрь
	# убирают это начисто: по краям дощечки теперь СЕРЕДИНЫ крайних точек клетки.
	var wide_px: float = float(COLS * TILE)
	var high_px: float = float(STAGES * TILE)
	var v_tip: float = (float(stage * TILE) + 0.5) / high_px   # верх клетки — кончик
	var v_foot: float = (float((stage + 1) * TILE) - 0.5) / high_px   # низ — черешок
	var bow: float = float(def.get("leaf_bow", 0.3))
	var sag: float = float(def.get("leaf_sag", 0.22))
	# Вторая разметка ОТРИЦАТЕЛЬНАЯ — знак шейдеру, что заворачивать нечего: лист
	# берёт вырезанную фигурку целиком, а не повторяющийся образец, как кора.
	st.set_uv2(Vector2(-1.0, -1.0))
	var steps: int = LEAF_GRID + 1
	for leaf in plan:
		st.set_color((hue * float(leaf["shade"])).srgb_to_linear())
		var col: int = LEAF_COL + int(leaf["kind"])
		var u0: float = (float(col * TILE) + 0.5) / wide_px
		var u1: float = (float((col + 1) * TILE) - 0.5) / wide_px
		var along: Vector3 = leaf["along"]
		var face: Vector3 = leaf["face"]
		var wide: Vector3 = leaf["wide"]
		var long: float = leaf["long"]
		var half: float = leaf["half"]
		var pts: Array = []
		for iy in range(steps):
			var t: float = float(iy) / float(LEAF_GRID)
			var row: Array = []
			for ix in range(steps):
				var w: float = float(ix) / float(LEAF_GRID) * 2.0 - 1.0
				# Чаша поперёк — от черешка к кончику, а не по всей длине: у
				# самого черешка листу выгибаться нечем.
				var lift: float = bow * half * w * w * t - sag * long * t * t
				row.append(Vector3(leaf["at"]) + along * (long * t)
					+ wide * (half * w) + face * lift)
			pts.append(row)
		# Нормали — по соседним точкам самой дощечки: взятая от геометрии всегда
		# сходится с тем, что видно, а выведенная отдельной формулой рано или
		# поздно с ней разойдётся.
		var nrms: Array = []
		for iy in range(steps):
			var row: Array = []
			for ix in range(steps):
				var du: Vector3 = Vector3(pts[iy][mini(ix + 1, steps - 1)]) \
					- Vector3(pts[iy][maxi(ix - 1, 0)])
				var dv: Vector3 = Vector3(pts[mini(iy + 1, steps - 1)][ix]) \
					- Vector3(pts[maxi(iy - 1, 0)][ix])
				var n: Vector3 = du.cross(dv)
				if n.length_squared() < 0.000000001:
					n = face
				n = n.normalized()
				row.append(n if n.dot(face) >= 0.0 else -n)
			nrms.append(row)
		for iy in range(LEAF_GRID):
			for ix in range(LEAF_GRID):
				for k in BAND_TRI:
					var far: bool = int(k[0]) == 1
					var nxt: bool = int(k[1]) == 1
					var gy: int = iy + (1 if far else 0)
					var gx: int = ix + (1 if nxt else 0)
					var fu: float = float(gx) / float(LEAF_GRID)
					if bool(leaf["flip"]):
						fu = 1.0 - fu
					st.set_normal(nrms[gy][gx])
					st.set_uv(Vector2(lerpf(u0, u1, fu),
						lerpf(v_foot, v_tip, float(gy) / float(LEAF_GRID))))
					st.add_vertex(pts[gy][gx])


# ВОРС — раскладка торчащих картинок. Место на теле: доля радиуса и угол,
# остальное считается по куполу.
#
# ЖДЁТ ПОДКЛЮЧЕНИЯ. Ворс СНЯТ по решению пользователя 2026-08-17: на кадре он
# читался россыпью мелких царапин поверх кочки, а не пушистым краем, и мешал
# смотреть на саму форму. Ни раскладка, ни отрисовка не зовутся; лист с
# картинками остаётся на месте — телу он всё равно нужен, и ворс к нему вернётся,
# когда будет решено, как он должен выглядеть.
func _make_fuzz(rim: Array, side: Vector3, along: Vector3, creep: float,
		salt: int) -> Array:
	# Порядок поясов — ОТ МАКУШКИ К ОБОДУ: он же порядок всхода, и растущая кочка
	# добавляет ворс с краю, а не втыкает посреди уже готового.
	var spots: Array = []
	for c in range(FUZZ_CROWN):
		spots.append([0.10, TAU * float(c) / float(FUZZ_CROWN)])
	for r in range(FUZZ_RINGS.size()):
		for j in range(FUZZ_PER_RING):
			# Соседние пояса сдвинуты на полшага, иначе ворсинки выстраиваются
			# лучами от середины и кочка идёт спицами.
			spots.append([float(FUZZ_RINGS[r]),
				TAU * (float(j) + 0.5 * float(r)) / float(FUZZ_PER_RING)])

	var fuzz: Array = []
	for i in range(spots.size()):
		var t: float = float(spots[i][0])
		# Углы сбиваем на треть промежутка: ровное кольцо читается частоколом.
		var a: float = float(spots[i][1]) + (_hash01(salt + i * 1013) - 0.5) * 0.7
		var dir: Vector3 = (side * (cos(a) * creep) + along * sin(a)).normalized()
		# Насколько далеко обод в эту сторону — берём между соседними секторами.
		var at: float = float(SECTORS) * a / TAU
		var s0: int = int(floor(at)) % SECTORS
		var s1: int = (s0 + 1) % SECTORS
		var mix: float = at - floor(at)
		var near: float = lerpf(Vector3(rim[s0]["off"]).length(),
			Vector3(rim[s1]["off"]).length(), mix)
		# Между какими секторами сидит — по ним при отрисовке берётся, упёрлось ли
		# тело в соседа в эту сторону.
		#
		# Срез купола под ворсинкой печём ЗАРАНЕЕ для случая, когда сектор свободен:
		# он тогда не меняется всю жизнь, а таких ворсинок больше половины. У
		# упёршихся его приходится считать заново — обрезка ходит, пока соседи
		# растут, — но платят за это только они.
		var tc: float = minf(t, 0.92)
		var t2: float = minf(1.0, tc + 0.08)
		fuzz.append({
			"dir": dir, "t": tc, "reach": near,
			"s0": s0, "s1": s1, "mix": mix,
			"prof": _profile(tc), "dprof": _profile(t2) - _profile(tc),
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
	return fuzz


func _emit_tuft(st: SurfaceTool, p: Dictionary) -> bool:
	var def: Dictionary = PlantsData.ITEMS[p["id"]]
	if _is_stem(def):
		return _emit_stem(st, p, def)
	var m: float = p["m"]
	var body: Dictionary = p.get("body", {})
	if body.is_empty():
		return false
	var rim: Array = body["rim"]
	var centre: Vector3 = p["pos"]
	var up: Vector3 = body["up"]

	var stage_f: float = m * float(STAGES)
	# Номер ступени как непрерывная величина: середина первой — ровно 1, середина
	# пятой — ровно 5. Считаем непрерывно, а не по целой ступени, чтобы размер не
	# подскакивал на переходе — ради этого и участились пересборки.
	var stage_no: float = clampf(stage_f + 0.5, 1.0, float(STAGES))
	# Раскладка испечена при самом широком возрасте, младшие сжимают её к середине.
	var wide_at: float = lerpf(PATCH_YOUNG, PATCH_OLD,
		(stage_no - 1.0) / float(STAGES - 1))
	var k: float = wide_at / PATCH_OLD
	var span: float = main.CELL_SPACING * ADULT_SIZE * BODY_WIDE * wide_at \
		* float(p["bulk"])
	var high: float = span * BODY_RISE * float(body["rise"]) * _flat_of(m)

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
	#
	# ВЫСОТУ БЕРЁМ НЕ У СВОЕГО КУПОЛА, А У ОБЩЕГО ПОЛЯ. Это и есть срастание, и
	# двух прежних попыток тут не хватило: ни подъёма точек до чужого купола (на
	# редкой сетке линию пересечения передать нечем — кочки просто входили одна в
	# другую), ни шва-плоскости (кочки от него отодвигались друг от друга и
	# касались в одной точке сектора).
	#
	# Теперь у каждой кочки есть свой бугор, а поверхность — МЯГКИЙ МАКСИМУМ всех
	# бугров вокруг. Мягкий, а не обычный: обычный даёт острую складку на стыке,
	# мягкий — плавную перемычку, и две сошедшиеся кочки сливаются, как сливаются
	# две лужи. Отсюда и форма разлитой воды: плоская середина, круглый край,
	# перетяжки между слипшимися каплями.
	#
	# Своей области кочка при этом всё равно держится (`_seam_cut`): рисует поле
	# только там, где она сама главная. Соседи делают то же со своей стороны, а на
	# границе оба считают ОДНО И ТО ЖЕ значение поля — потому куски сходятся
	# вплотную и ничто ни во что не входит.
	var kin: Array = _neighbours(p, centre, up, span)
	var kin_t: Array = kin[0]
	var kin_r: PackedFloat32Array = kin[1]
	var kin_top: PackedFloat32Array = kin[2]
	var kin_weld: PackedFloat32Array = kin[3]
	var cut: PackedFloat32Array = _seam_cut(rim, up, k, kin_t, kin_r, kin_weld, span)
	var blend: float = high * FIELD_BLEND

	# =========================================================================
	#  ТЕЛО: поверхность поля по кольцам
	# =========================================================================
	var rings: int = RING_AT.size()
	var pts: Array = []
	for r in range(rings):
		var t: float = float(RING_AT[r])
		var ring: Array = []
		for s in range(SECTORS):
			var keep: float = cut[s]
			# Идём от середины к ободу ПО ЗЕМЛЕ, через прощупанную середину бока,
			# а не по прямой хорде: на перегибе хорда уходит в землю или в воздух.
			var tt: float = t * k * keep
			var o: Vector3
			if tt <= MID_RING:
				o = Vector3(rim[s]["mid"]) * (tt / MID_RING)
			else:
				o = Vector3(rim[s]["mid"]).lerp(Vector3(rim[s]["off"]),
					(tt - MID_RING) / (1.0 - MID_RING))
			var oh: float = o.dot(up)
			var xt: Vector3 = o - up * oh
			# ПОЛЕ — ЭТО ТОЛЩИНА МХА НАД ЗЕМЛЁЙ, а не высота над серединой кочки.
			# Разница видна на склоне: считай мы вклад соседа от ЕГО земли, кочка
			# ниже по склону получала бы от него добавку в полсклона и всплывала
			# бы над рельефом. Мох же лежит по земле — как и разлитая вода.
			#
			# Бугристость (`lump`) идёт только в свой бугор: у соседей она своя, и
			# подглядывать в неё незачем.
			var far: float = xt.length() / span
			var bump: float = high * float(rim[s]["lump"][r]) \
				* (_profile_fast(far) if far < 1.0 else 0.0)
			for i in range(kin_t.size()):
				var d: float = (xt - Vector3(kin_t[i])).length() / kin_r[i]
				if d >= 1.0:
					continue
				# Влияние соседа ВВОДИТСЯ ПОСТЕПЕННО, с пятой ступени: не гасим
				# его бугор, а подмешиваем слитую поверхность к своей. Гасить
				# нельзя — сосед просел бы у себя дома, а не отступил от нас.
				bump = lerpf(bump, _smax(bump, kin_top[i] * _profile_fast(d), blend),
					kin_weld[i])
			# Утапливаем в землю только ТАМ, ГДЕ ОБОД И ПРАВДА ЛЁГ на землю: где
			# его поднял сосед, топить нечего — иначе в перемычке прорежется щель.
			bump -= _ring_sink[r] * high * clampf(1.0 - bump / (0.25 * high), 0.0, 1.0)
			ring.append(centre + xt + up * (oh + bump))
		pts.append(ring)
	# Макушка — тоже по полю: рядом может стоять кочка крупнее, и тогда середина
	# этой уходит под её склон, а не торчит из него бугорком.
	var top: float = high * (0.95 + 0.10 * float(body["age"]))
	for i in range(kin_t.size()):
		var d: float = Vector3(kin_t[i]).length() / kin_r[i]
		if d < 1.0:
			top = lerpf(top, _smax(top, kin_top[i] * _profile_fast(d), blend),
				kin_weld[i])
	var apex: Vector3 = centre + up * top

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

	# ОБРАЗЕЦ КЛАДЁТСЯ ПО ПОВЕРХНОСТИ, А НЕ ОТ МАКУШКИ К ОБОДУ.
	#
	# ГРАБЛИ, свои же и крупные. Прежде картинка резалась по кольцу и по сектору:
	# доля образца по кругу, доля по радиусу. Разметки такого рода на теле не
	# видно вовсе — виден СМАЗ. Точек всего десять по кругу и четыре по радиусу,
	# между ними картинка тянется, и всякая тёмная черта образца становится
	# тёмным лучом от макушки к ободу. Ровно эти лучи и стояли на кадре звездой.
	# Рельеф резался той же разметкой, значит смазывался вместе с цветом, — оттого
	# карты нормалей и не было заметно.
	#
	# Теперь место в картинке — это ПУТЬ ПО КУПОЛУ от макушки, отложенный в ту
	# сторону, куда идёт сектор. Путь, а не проекция сверху: у проекции точка на
	# крутом боку растягивается вдвое, а по пути она везде одного размера.
	#
	# Образец при этом ПОВТОРЯЕТСЯ — он стыкуется сам с собой. Заворот делает
	# шейдер, на месте: вершин мало, и заворачивать по ним значило бы прогнать
	# картинку задом наперёд через всю клетку внутри одного треугольника.
	var bstage: int = clampi(int(stage_f + float(body["age"])), 0, STAGES - 1)
	# Свой сдвиг по образцу у каждой кочки — иначе у всех одна и та же зелень в
	# одних и тех же местах.
	var warp: Vector2 = body["warp"]
	# Рама для плоских долей — от нулевого сектора. Какая именно, неважно: у
	# каждой кочки свой поворот, а сдвиг по образцу и подавно свой.
	var flat_x: Vector3 = Vector3(rim[0]["dir"]).normalized()
	var flat_y: Vector3 = up.cross(flat_x).normalized()
	var per_metre: float = 1.0 / (BODY_TEXEL * float(TILE))
	var dir2: Array = []
	for s in range(SECTORS):
		var d: Vector3 = Vector3(rim[s]["dir"])
		var flat := Vector2(d.dot(flat_x), d.dot(flat_y))
		dir2.append(flat.normalized() if flat.length_squared() > 0.000001
			else Vector2.RIGHT)
	var cuts: Array = []
	var walk := PackedFloat32Array()
	walk.resize(SECTORS)
	for r in range(rings):
		var ring_uv: Array = []
		for s in range(SECTORS):
			var back: Vector3 = apex if r == 0 else pts[r - 1][s]
			walk[s] += Vector3(pts[r][s]).distance_to(back)
			ring_uv.append(warp + dir2[s] * (walk[s] * per_metre))
		cuts.append(ring_uv)
	var apex_uv: Vector2 = warp

	# КЛЕТКУ ОБРАЗЦА ПЕРЕДАЁМ ВТОРОЙ РАЗМЕТКОЙ: заворот идёт внутри неё, и
	# шейдеру надо знать, где она начинается. Берём клетку ЦЕЛИКОМ, а не найденный
	# сплошной кусок (`_scan_solid`): повторяться без шва образец умеет только по
	# целой клетке, а что она сплошная — стережёт `see_through`.
	st.set_uv2(Vector2(float(BODY_COL) / float(COLS),
		float(bstage) / float(STAGES)))
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

	return true


# ВОРС: картинки, растущие ИЗ ТЕЛА по его нормали. Направление берётся у самого
# купола — на макушке ворсинка стоит торчком, у края завалена наружу; отдельного
# правила для этого не нужно, оно уже есть в форме тела.
#
# ЧИСЛО РАСТЁТ НЕ ЦЕЛЫМИ: у каждой ворсинки свой отрезок зрелости
# (`SPROUT_SPAN`), и она вытягивается по нему от нуля. Возникшая разом ворсинка
# в полный рост читается миганием, а не ростом.
#
# ЖДЁТ ПОДКЛЮЧЕНИЯ. Снят вместе с `_make_fuzz` — см. там же, почему. Когда
# вернётся, высоту под ворсинкой надо будет брать НЕ у своего купола, а у общего
# поля (`_field_at`): тело теперь стоит по нему, и ворс обязан сесть на ту же
# поверхность, иначе повиснет над ней или утонет.
func _emit_fuzz(st: SurfaceTool, fuzz: Array, m: float, centre: Vector3,
		up: Vector3, k: float, high: float, span: float,
		cut: PackedFloat32Array, hue: Color, stage_f: float) -> void:
	# Длина ворсинки — большее из двух правил: «М ±5% за ступень» (решение
	# пользователя о размере) и «не короче половины радиуса кочки». На молодой
	# верх берёт первое, на взрослой второе: кочка ширится вдвое с лишним, и ворс,
	# привязанный только к «М», на взрослой терялся бы щетинкой.
	var stage_no: float = clampf(m * float(STAGES) + 0.5, 1.0, float(STAGES))
	var size: float = 1.0 + SIZE_PER_STAGE * (stage_no - MID_STAGE)
	var tall: float = maxf(main.CELL_SPACING * ADULT_SIZE * size * FUZZ_TALL,
		span * FUZZ_OF_SPAN)
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
		# Ворсинка стоит на теле, а тело в эту сторону могло упереться в соседа —
		# значит, и она переезжает вместе с ним. Обрезку берём между секторами,
		# как и вылет обода.
		var mix: float = float(b["mix"])
		var keep: float = lerpf(cut[int(b["s0"])], cut[int(b["s1"])], mix)
		var reach: float = float(b["reach"]) * k * keep
		var t: float = float(b["t"])
		var t2: float = minf(1.0, t + 0.08)
		var base_h: float
		var dh: float
		if keep >= 0.999:
			base_h = high * float(b["prof"])          # сектор свободен, срез испечён
			dh = high * float(b["dprof"])
		else:
			base_h = high * _profile_fast(t * keep)
			dh = high * _profile_fast(t2 * keep) - base_h
		var foot0: Vector3 = centre + dir * (reach * t) + up * base_h
		# Нормаль купола в этой точке — по срезу, численно. Наклон среза здесь и
		# заваливает ворсинку наружу тем сильнее, чем ближе к ободу; на шве с
		# соседом склон пологий, и ворсинка встаёт прямее — так и должно быть.
		var stand: Vector3 = up * (reach * (t2 - t)) - dir * dh
		stand = stand.normalized() if stand.length_squared() > 0.0000001 else up

		# ЛИЦОМ ОТ СЕРЕДИНЫ КОЧКИ (решение пользователя): ширина ворсинки идёт
		# поперёк луча из середины, значит плоскость картинки развёрнута наружу и
		# видна снаружи плашмя. Случайного поворота больше нет — от него ворс
		# читался россыпью царапин, а не расходящимся из середины пучком.
		var face: Vector3 = stand.cross(dir)
		if face.length_squared() < 0.000001:
			face = stand.cross(Vector3.UP)
		face = face.normalized()
		var w: float = tall * float(b["wide"]) * grow
		var h: float = tall * float(b["high"]) * grow
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

		# Вторая разметка ОТРИЦАТЕЛЬНАЯ — знак для шейдера, что заворачивать
		# нечего: ворсинка берёт вырезанную фигурку целиком, а не повторяющийся
		# образец, как тело.
		st.set_uv2(Vector2(-1.0, -1.0))
		st.set_color((hue * float(b["shade"])).srgb_to_linear())
		var quad := [foot - half, foot + half,
			foot + half + stand * h, foot - half + stand * h]
		var uvs := [Vector2(u0, v1), Vector2(u1, v1), Vector2(u1, v0), Vector2(u0, v0)]
		# Стороны у материала не отсекаются, поэтому порядок обхода не важен.
		for tri in [[0, 1, 2], [0, 2, 3]]:
			for j in tri:
				st.set_normal(stand)
				st.set_uv(uvs[j])
				st.add_vertex(quad[j])


func _hash01(n: int) -> float:
	var x: int = (n * 1103515245 + 12345) & 0x7fffffff
	return float((x >> 8) & 0xffff) / 65535.0
