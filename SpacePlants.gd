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
const SPREAD_NEAR: float = 0.20
const SPREAD_FAR: float = 0.60
# Ближе этого друг к другу не садимся: иначе пятно сгущается в одну точку и
# кочки лезут одна из другой.
const CROWD: float = 0.17

var main: Node3D
var patches: Dictionary = {}      # номер -> {pos, nrm, id, m, step, cell, salt}
var by_cell: Dictionary = {}      # ячейка -> {номер: true}
var cell_nodes: Dictionary = {}   # ячейка -> меш со всеми её растениями
var time_scale: float = 1.0
var _dirty: Dictionary = {}
var _accum: float = 0.0
var _next: int = 1
var _rng := RandomNumberGenerator.new()
var _blade_mat: StandardMaterial3D


func setup(main_ref: Node3D) -> void:
	main = main_ref
	_rng.seed = 20260811
	# Материал пучков. Прозрачность — ОТСЕЧЕНИЕМ, а не смешиванием: у смешивания
	# порядок отрисовки решается по расстоянию до всего меша целиком, и сотни
	# перекрывающихся пучков начинают мигать друг сквозь друга. Отсечение
	# работает по глубине, как обычная поверхность, и стоит дешевле.
	#
	# Стороны не отсекаем: лист один и тот же с обеих сторон.
	# Фильтр — ближайший: картинка нарочно пиксельная, сглаживание съело бы её.
	_blade_mat = StandardMaterial3D.new()
	_blade_mat.albedo_texture = _make_blade_texture()
	_blade_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	_blade_mat.alpha_scissor_threshold = 0.5
	_blade_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_blade_mat.vertex_color_use_as_albedo = true
	_blade_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_blade_mat.roughness = 1.0
	_blade_mat.metallic_specular = 0.0
	# СВЕТ ПО МХУ МЯГКИЙ. Мох просвечивает: на солнце он светится изнутри, а в
	# тени не проваливается в чёрное. Подсвет сзади и снимает жёсткость — без
	# него теневая сторона подушки выходит грязно-тёмной, будто выжжена.
	_blade_mat.backlight_enabled = true
	_blade_mat.backlight = Color(0.26, 0.36, 0.16)
	# Своего блика у мха нет совсем — он матовый до бархатности.
	_blade_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED


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
		# Палитра тесная: у мха нет ни сухой соломы, ни чёрных теней — весь он
		# в узкой жёлто-зелёной вилке, и разница между тенью и светом мала.
		# Резкий перепад сразу превращает бархат в щётку из палок.
		var deep := Color(0.26, 0.40, 0.15).lerp(Color(0.21, 0.34, 0.12), age)
		var body := Color(0.44, 0.62, 0.21).lerp(Color(0.38, 0.56, 0.18), age)
		var lit := Color(0.58, 0.74, 0.29).lerp(Color(0.54, 0.68, 0.24), age)
		var rust := Color(0.40, 0.34, 0.15)      # ржавчина у старых куртин

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
	patches[pid] = {
		"pos": spot["pos"], "nrm": spot["nrm"], "id": id,
		"m": maturity, "step": -1, "cell": cell,
		"salt": pid * 7919 + int(absf(spot["pos"].x) * 131),
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
const BLADES_MIN: int = 4
const BLADES_MAX: int = 18

func _emit_tuft(st: SurfaceTool, p: Dictionary) -> bool:
	var def: Dictionary = PlantsData.ITEMS[p["id"]]
	var m: float = p["m"]
	var salt: int = int(p["salt"])
	var centre: Vector3 = p["pos"]
	var nrm: Vector3 = p["nrm"]

	var side: Vector3 = nrm.cross(Vector3.UP)
	if side.length_squared() < 0.001:
		side = nrm.cross(Vector3.RIGHT)
	side = side.normalized()
	var along: Vector3 = nrm.cross(side).normalized()

	# Молодая кочка — несколько ворсинок, взрослая — густая подушка.
	var count: int = BLADES_MIN + int(float(BLADES_MAX - BLADES_MIN) * m)
	var reach: float = main.CELL_SPACING * lerpf(0.04, 0.13, m)
	var tall: float = main.CELL_SPACING * lerpf(0.05, 0.16, m)

	# ЛИАНА — тот же пучок, но не круглый, а вытянутый по подъёму: плеть ползёт
	# вверх по склону узкой полосой. Своей формы — стебля с листьями — у неё
	# пока нет, и это заглушка, а не решение.
	var creep: float = 1.0
	var climb_dir: Vector3 = side
	if str(def.get("shape", "")) == "vine":
		var up: Vector3 = Vector3.UP - nrm * nrm.dot(Vector3.UP)
		if up.length_squared() > 0.001:
			climb_dir = up.normalized()
			side = climb_dir
			along = nrm.cross(side).normalized()
		creep = 2.4

	# Цвет вида берём БЕЗ его темноты: тень и свет уже нарисованы на картинке,
	# и умножение на тёмно-зелёный сделало бы пучок чёрным.
	var c: Color = def["color"]
	var lum: float = maxf(0.001, (c.r + c.g + c.b) / 3.0)
	var hue := Color(c.r / lum, c.g / lum, c.b / lum)

	for i in range(count):
		# Отходим от середины по кругу, но не по краю: корень квадратный из
		# случайного даёт равномерное пятно, а не кольцо.
		var ra: float = TAU * _hash01(salt + i * 13)
		var rr: float = reach * sqrt(_hash01(salt + i * 71))
		var out: Vector3 = (side * (cos(ra) * creep) + along * sin(ra)).normalized()
		var at: Vector3 = centre + (side * (cos(ra) * creep) + along * sin(ra)) * rr
		# Своя сторона у каждой дощечки — она и даёт «под разными углами».
		var turn: float = TAU * _hash01(salt + i * 29)
		var face: Vector3 = side * cos(turn) + along * sin(turn)
		# Подушка ШИРЕ, чем выше: мох стелется, а не тянется вверх.
		var w: float = tall * (1.15 + 0.55 * _hash01(salt + i * 97))
		# КРАЙ КОЧКИ ЛОЖИТСЯ. В середине былинки стоят торчком, а к краю всё
		# сильнее заваливаются наружу и к земле — так растёт живая подушка: она
		# расползается кромкой, а не обрывается стенкой. Заодно пропадает вид
		# щётки: у щётки все ворсинки одной высоты и одного наклона.
		var edge: float = rr / maxf(reach, 0.0001)
		var lie: float = edge * edge * 0.85
		var h: float = tall * (0.60 + 0.45 * _hash01(salt + i * 53)) * (1.0 - 0.35 * lie)
		# Заваливаем дощечку набок — иначе пучок стоит звездой из ровных стенок.
		var up: Vector3 = (nrm * (1.0 - lie * 0.75) + out * lie
			+ face * (_hash01(salt + i * 37) - 0.5) * 0.55).normalized()
		var half: Vector3 = face * (w * 0.5)
		var foot: Vector3 = at - nrm * (h * 0.12)   # корень чуть утоплен в землю

		# Столбец — разновидность, строка — возраст. Возраст берём у растения,
		# разновидность у самой дощечки: в одном пучке стоят разные былинки.
		var cx: int = (salt + i * 7) % KINDS
		var cy: int = clampi(int(m * float(STAGES)), 0, STAGES - 1)
		var u0: float = float(cx) / float(KINDS)
		var u1: float = float(cx + 1) / float(KINDS)
		var v0: float = float(cy) / float(STAGES)         # верх клетки — концы
		var v1: float = float(cy + 1) / float(STAGES)     # низ — корни

		# Разброс яркости между дощечками МАЛЫЙ. При большом соседние ворсинки
		# одной подушки отличаются как день и ночь, и бархат рассыпается на
		# отдельные лоскуты. У живого мха вся куртинка почти одного тона.
		var shade: float = 0.92 + 0.14 * _hash01(salt + i * 11)
		st.set_color((hue * shade).srgb_to_linear())
		var quad := [foot - half, foot + half,
			foot + half + up * h, foot - half + up * h]
		var uvs := [Vector2(u0, v1), Vector2(u1, v1), Vector2(u1, v0), Vector2(u0, v0)]
		# Стороны у материала не отсекаются, поэтому порядок обхода не важен.
		for tri in [[0, 1, 2], [0, 2, 3]]:
			for k in tri:
				st.set_normal(nrm)
				st.set_uv(uvs[k])
				st.add_vertex(quad[k])
	return count > 0


func _hash01(n: int) -> float:
	var x: int = (n * 1103515245 + 12345) & 0x7fffffff
	return float((x >> 8) & 0xffff) / 65535.0
