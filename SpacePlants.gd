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
# Ступеней роста, на которых меш пересобирается. Ровно столько же, сколько
# возрастов у картинки: реже — и кочка меняла бы вид не тогда, когда взрослеет.
const STEPS: int = 9

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
	_blade_mat.set_shader_parameter("blades", _blade_texture())


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
const TILE: int = 32               # сторона одного пучка в точках
const STAGES: int = 9              # столько возрастов
const KINDS: int = 4               # столько разновидностей у каждого возраста

# НАРИСОВАННЫЙ ЛИСТ ГЛАВНЕЕ СЧИТАННОГО. Если в `art/moss.png` лежит картинка,
# берём её; иначе рисуем сами. Так рисунок от руки подменяет заглушку без
# единой правки в коде — и без риска потерять заглушку, если файла нет.
#
# Разметка листа та же: `KINDS` клеток в ряду (разновидности), `STAGES` рядов
# (возрасты, сверху молодой), клетка `TILE`×`TILE`, фон прозрачный.
const ART_PATH := "res://art/moss.png"

func _blade_texture() -> Texture2D:
	if ResourceLoader.exists(ART_PATH):
		var drawn = load(ART_PATH)
		if drawn is Texture2D:
			var want := Vector2i(TILE * KINDS, TILE * STAGES)
			if drawn.get_size() != Vector2(want):
				push_warning("art/moss.png ожидается %d×%d, а он %s"
					% [want.x, want.y, str(drawn.get_size())])
			return drawn
	return _make_blade_texture()


func _make_blade_texture() -> ImageTexture:
	var img := Image.create(TILE * KINDS, TILE * STAGES, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 913377

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
	var pid := _next
	_next += 1
	var cell: int = int(spot["cell"])
	var salt: int = pid * 7919 + int(absf(spot["pos"].x) * 131)
	patches[pid] = {
		"pos": spot["pos"], "nrm": spot["nrm"], "id": id,
		"m": maturity, "step": -1, "cell": cell, "salt": salt,
		"blades": _make_blades(spot, PlantsData.ITEMS[id], salt),
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
		var was: int = int(p["cell"])
		p["pos"] = spot["pos"]
		p["nrm"] = spot["nrm"]
		# Земля сдвинулась — раскладку ворсинок пересаживаем заново, иначе
		# подушка останется висеть по старому рельефу.
		p["blades"] = _make_blades(spot, PlantsData.ITEMS[p["id"]], int(p["salt"]))
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


# КОЧКА — не подушка, а ПУЧОК ПЛОСКИХ КАРТИНОК, поставленных под разными
# углами вокруг своей точки. С любой стороны часть дощечек видна плашмя, часть
# с ребра — и пучок читается объёмным, ничего объёмного не строя. Так рисуют
# траву во всех играх, и на пиксельных образцах видно ровно это.
#
# Освещаем пучок НОРМАЛЬЮ ЗЕМЛИ, а не своей: у стоячей дощечки нормаль смотрит
# вбок, и трава на солнечном склоне вышла бы тёмной, будто в тени.
# Дощечек в пучке. Кочка должна быть ГУСТОЙ: редкий пучок читается пучком
# соломы, а не подушкой мха.
# Ворсинок в подушке. Их МНОГО и они МЕЛКИЕ: пышность набирается числом, а
# несколько крупных дощечек всегда читаются несколькими дощечками.
const BLADES_MAX: int = 22
const BLADES_MIN: int = 3
# Насколько подушка выпуклая: середина приподнята над краем на эту долю своей
# высоты. Без этого все ворсинки стоят корнями на одном уровне, и кочка выходит
# плоской лепёшкой, сколько ни добавляй дощечек.
const DOME: float = 0.55


# РАСКЛАДКА ВОРСИНОК СЧИТАЕТСЯ ОДИН РАЗ, при рождении кочки, и живёт с ней.
#
# Каждая ворсинка сажается на НАСТОЯЩУЮ землю — поиском по полю. Раньше место
# бралось по плоскости наклона с поправкой на кривизну, и на валуне подушка то
# висела в воздухе, то уходила внутрь камня: одной кривизной изгиб не описать.
# Считать это на каждой перестройке нельзя (сорок пять секунд роста стоили
# двадцати четырёх секунд счёта), а один раз на кочку — вполне.
#
# Порядок ворсинок — ОТ СЕРЕДИНЫ К КРАЮ, по золотому углу. Тогда растущая
# подушка добавляет их с краю, а не втыкает посреди уже готовых: разрастание
# читается разрастанием, а не мельтешением.
func _make_blades(spot: Dictionary, def: Dictionary, salt: int) -> Array:
	var centre: Vector3 = spot["pos"]
	var nrm: Vector3 = spot["nrm"]
	var side: Vector3 = nrm.cross(Vector3.UP)
	if side.length_squared() < 0.001:
		side = nrm.cross(Vector3.RIGHT)
	side = side.normalized()
	var along: Vector3 = nrm.cross(side).normalized()

	# Лиана ползёт вверх по склону узкой полосой — её пятно вытянуто. Сильнее
	# полутора раз растягивать нельзя: дощечки выстраиваются вдоль одной оси и
	# складываются стопкой, как страницы в книге.
	var creep: float = 1.0
	if str(def.get("shape", "")) == "vine":
		var up: Vector3 = Vector3.UP - nrm * nrm.dot(Vector3.UP)
		if up.length_squared() > 0.001:
			side = up.normalized()
			along = nrm.cross(side).normalized()
		creep = 1.5

	var span: float = main.CELL_SPACING * 0.115      # радиус взрослой подушки
	var out: Array = []
	for i in range(BLADES_MAX):
		var t: float = float(i) / float(BLADES_MAX - 1)
		var r: float = sqrt(t)                       # равномерно по площади
		var a: float = float(i) * 2.39996323          # золотой угол: без колец и лучей
		var wob: float = 0.72 + 0.56 * _hash01(salt + i * 7717)
		var dir: Vector3 = (side * (cos(a) * creep) + along * sin(a))
		var at: Vector3 = centre + dir * (r * span * wob)
		var on: Dictionary = main.grid.surface_near(at)
		# Не села — ворсинки просто НЕ БУДЕТ. Раньше на этом месте оставалась
		# точка «как есть», то есть висящая в воздухе: у кромки обрыва такие
		# ворсинки торчали наружу целыми охапками. Пусть подушка у края будет
		# пореже, чем с бахромой из ничего.
		if on.is_empty():
			continue
		var pos: Vector3 = on["pos"]
		var up_n: Vector3 = on["nrm"]
		# И место, и наклон должны быть СВОИ. Уехала дальше, чем отпущено, или
		# завернулась круче прямого угла — значит нашлась чужая земля за краем.
		if pos.distance_to(at) > span * 0.9 or up_n.dot(nrm) < 0.2:
			continue
		out.append({
			"pos": pos, "nrm": up_n,
			"out": dir.normalized() if dir.length_squared() > 0.0001 else side,
			"r": r,
			"turn": TAU * _hash01(salt + i * 2113),
			"lean": _hash01(salt + i * 3319) - 0.5,
			"wide": 0.70 + 0.60 * _hash01(salt + i * 4409),
			"high": 0.65 + 0.70 * _hash01(salt + i * 5501),
			"kind": int(_hash01(salt + i * 6607) * float(KINDS)) % KINDS,
			"shade": 0.90 + 0.18 * _hash01(salt + i * 8819),
		})
	return out


func _emit_tuft(st: SurfaceTool, p: Dictionary) -> bool:
	var def: Dictionary = PlantsData.ITEMS[p["id"]]
	var m: float = p["m"]
	var blades: Array = p.get("blades", [])
	if blades.is_empty():
		return false

	# Молодая кочка — три ворсинки, взрослая — все тридцать. Растёт и число, и
	# рост каждой: одним ростом получается раздутая копия младенца.
	# Ворсинок может оказаться меньше задуманного: те, что не нашли под собой
	# земли, не родились вовсе.
	var count: int = clampi(BLADES_MIN + int(float(BLADES_MAX - BLADES_MIN) * m),
		1, blades.size())
	var tall: float = main.CELL_SPACING * lerpf(0.035, 0.105, m)
	var stage: int = clampi(int(m * float(STAGES)), 0, STAGES - 1)

	# Цвет вида берём БЕЗ его темноты: тень и свет уже нарисованы на картинке,
	# и умножение на тёмно-зелёный сделало бы пучок чёрным. И оттенок подмешиваем
	# лишь наполовину — на полную он перекрашивал картинку в свой цвет, стирая
	# всю проработку, ради которой она и рисовалась.
	var c: Color = def["color"]
	var lum: float = maxf(0.001, (c.r + c.g + c.b) / 3.0)
	var hue := Color(1.0, 1.0, 1.0).lerp(
		Color(c.r / lum, c.g / lum, c.b / lum), 0.5)

	for i in range(count):
		var b: Dictionary = blades[i]
		var stand: Vector3 = b["nrm"]
		var side: Vector3 = stand.cross(Vector3.UP)
		if side.length_squared() < 0.001:
			side = stand.cross(Vector3.RIGHT)
		side = side.normalized()
		var along: Vector3 = stand.cross(side).normalized()
		var turn: float = float(b["turn"])
		var face: Vector3 = side * cos(turn) + along * sin(turn)

		# ВЫПУКЛОСТЬ ПОДУШКИ: середина поднята, край лежит на земле. Отсюда и
		# пышность — силуэт становится куполом, а не блином.
		var r: float = float(b["r"])
		var rise: float = (1.0 - r * r) * tall * DOME
		# Край ЗАВАЛИВАЕТСЯ наружу: подушка расползается кромкой, а не
		# обрывается стенкой.
		var lie: float = r * r * 0.8
		var w: float = tall * float(b["wide"])
		var h: float = tall * float(b["high"]) * (1.0 - 0.3 * lie)
		var up: Vector3 = (stand * (1.0 - lie * 0.7) + Vector3(b["out"]) * lie
			+ face * (float(b["lean"]) * 0.5)).normalized()
		var half: Vector3 = face * (w * 0.5)
		var foot: Vector3 = Vector3(b["pos"]) + stand * (rise - h * 0.30)

		var cx: int = int(b["kind"])
		var u0: float = float(cx) / float(KINDS)
		var u1: float = float(cx + 1) / float(KINDS)
		var v0: float = float(stage) / float(STAGES)      # верх клетки — концы
		var v1: float = float(stage + 1) / float(STAGES)  # низ — корни

		st.set_color((hue * float(b["shade"])).srgb_to_linear())
		var quad := [foot - half, foot + half,
			foot + half + up * h, foot - half + up * h]
		var uvs := [Vector2(u0, v1), Vector2(u1, v1), Vector2(u1, v0), Vector2(u0, v0)]
		# Стороны у материала не отсекаются, поэтому порядок обхода не важен.
		for tri in [[0, 1, 2], [0, 2, 3]]:
			for k in tri:
				st.set_normal(stand)
				st.set_uv(uvs[k])
				st.add_vertex(quad[k])

	# ШАПКА. Стоячие дощечки видны сверху с ребра, и посреди пучка зияет плешь —
	# смотришь на кочку сверху, а видишь землю между ворсинками. Кладём поверх
	# несколько лоскутов ПО ЗЕМЛЕ, по макушке купола: сверху они закрывают
	# середину, сбоку почти не видны. У мха это ещё и правда: подушка сверху
	# сплошная.
	var caps: int = 2 + int(7.0 * m)
	for i in range(caps):
		var b: Dictionary = blades[(i * 5 + 1) % count]
		var cn: Vector3 = b["nrm"]
		var cs: Vector3 = cn.cross(Vector3.UP)
		if cs.length_squared() < 0.001:
			cs = cn.cross(Vector3.RIGHT)
		cs = cs.normalized()
		var cl: Vector3 = cn.cross(cs).normalized()
		var cr: float = float(b["r"])
		var turn2: float = float(b["turn"]) * 0.7
		# Шапки МЕЛКИЕ. Крупная лежачая заплата видна сбоку плоским листом, и
		# подушка сразу читается наклейкой; мелкие же прячутся между ворсинками
		# и делают своё дело только сверху.
		var wide: float = tall * (0.50 + 0.30 * float(b["wide"]))
		var e1: Vector3 = (cs * cos(turn2) + cl * sin(turn2)) * wide
		var e2: Vector3 = (cs * -sin(turn2) + cl * cos(turn2)) * (wide * 0.85)
		# Кладём по макушке купола, а не по земле: иначе шапка торчит из-под
		# ворсинок юбкой.
		var c0: Vector3 = Vector3(b["pos"]) \
			+ cn * ((1.0 - cr * cr) * tall * DOME + tall * 0.20)
		var cap := [c0 - e1 - e2, c0 + e1 - e2, c0 + e1 + e2, c0 - e1 + e2]
		# Берём середину клетки — самую густую часть подушки, без её края.
		var ck: int = int(b["kind"])
		var mu0: float = (float(ck) + 0.18) / float(KINDS)
		var mu1: float = (float(ck) + 0.82) / float(KINDS)
		var mv0: float = (float(stage) + 0.10) / float(STAGES)
		var mv1: float = (float(stage) + 0.62) / float(STAGES)
		var cuv := [Vector2(mu0, mv1), Vector2(mu1, mv1), Vector2(mu1, mv0), Vector2(mu0, mv0)]
		st.set_color((hue * float(b["shade"])).srgb_to_linear())
		for tri2 in [[0, 1, 2], [0, 2, 3]]:
			for k in tri2:
				st.set_normal(cn)
				st.set_uv(cuv[k])
				st.add_vertex(cap[k])
	return count > 0


func _hash01(n: int) -> float:
	var x: int = (n * 1103515245 + 12345) & 0x7fffffff
	return float((x >> 8) & 0xffff) / 65535.0
