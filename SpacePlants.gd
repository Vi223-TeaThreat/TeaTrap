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
const STEPS: int = 6              # ступеней роста, на которых меш пересобирается

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
var _material: StandardMaterial3D
var _blade_mat: StandardMaterial3D


func setup(main_ref: Node3D) -> void:
	main = main_ref
	_rng.seed = 20260811
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 0.95

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
	_blade_mat.roughness = 0.95
	_blade_mat.metallic_specular = 0.05


# ПУЧОК ТРАВЫ — рисуем прямо в коде, без файла с картинкой. Четыре разных
# пучка в одном листе: по два в ряд. Разные пучки на соседних дощечках дают
# кочке неповторяющийся вид — один и тот же рисунок, повёрнутый вокруг, сразу
# читается как повторение.
const TILE: int = 32               # сторона одного пучка в точках
const ATLAS: int = 2               # столько пучков в ряду

func _make_blade_texture() -> ImageTexture:
	var size := TILE * ATLAS
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 913377
	# Палитра снизу вверх: у земли бурое, в середине зелёное, на концах жёлтое.
	var root := Color(0.20, 0.20, 0.09)
	var mid := Color(0.33, 0.46, 0.15)
	var tip := Color(0.62, 0.66, 0.26)

	for cy in range(ATLAS):
		for cx in range(ATLAS):
			var ox := cx * TILE
			var oy := cy * TILE
			for _b in range(rng.randi_range(7, 11)):
				var x0: float = rng.randf_range(5.0, float(TILE) - 5.0)
				var high: int = rng.randi_range(13, TILE - 5)
				var lean: float = rng.randf_range(-7.0, 7.0)
				var shift: float = rng.randf_range(-0.10, 0.10)
				for t in range(high):
					var f: float = float(t) / float(high)
					# Наклон растёт к концу по квадрату — стебель гнётся, а не
					# стоит под углом от самого корня.
					var x: int = int(round(x0 + lean * f * f))
					var y: int = TILE - 1 - t
					# Толщина: у корня две точки, к концу одна.
					var wide: int = 2 if f < 0.55 else 1
					var col: Color = root.lerp(mid, minf(f * 2.2, 1.0))
					if f > 0.45:
						col = col.lerp(tip, (f - 0.45) / 0.55)
					col = col.lightened(shift) if shift > 0.0 else col.darkened(-shift)
					for w in range(wide):
						var px: int = ox + x + w
						if px >= ox and px < ox + TILE and y >= 0:
							img.set_pixel(px, oy + y, Color(col.r, col.g, col.b, 1.0))
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


# У ячейки может выйти ДВА набора граней: пучки на своём материале с картинкой
# и подушки на простом. Материал вешаем на каждый набор отдельно, а не на весь
# меш: `material_override` накрыл бы оба одним.
func _rebuild_cell(cell: int) -> void:
	if cell_nodes.has(cell):
		cell_nodes[cell].queue_free()
		cell_nodes.erase(cell)

	var here: Dictionary = by_cell.get(cell, {})
	if here.is_empty():
		return

	var tufts := SurfaceTool.new()
	tufts.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cushions := SurfaceTool.new()
	cushions.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any_tuft := false
	var any_cushion := false
	for pid in here:
		if not patches.has(pid):
			continue
		var p: Dictionary = patches[pid]
		if str(PlantsData.ITEMS[p["id"]].get("shape", "")) == "vine":
			if _emit_patch(cushions, p):
				any_cushion = true
		elif _emit_tuft(tufts, p):
			any_tuft = true
	if not any_tuft and not any_cushion:
		return

	var mesh: ArrayMesh = null
	if any_tuft:
		tufts.set_material(_blade_mat)
		mesh = tufts.commit()
	if any_cushion:
		cushions.set_material(_material)
		mesh = cushions.commit(mesh)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	cell_nodes[cell] = mi


# КОЧКА — не подушка, а ПУЧОК ПЛОСКИХ КАРТИНОК, поставленных под разными
# углами вокруг своей точки. С любой стороны часть дощечек видна плашмя, часть
# с ребра — и пучок читается объёмным, ничего объёмного не строя. Так рисуют
# траву во всех играх, и на пиксельных образцах видно ровно это.
#
# Освещаем пучок НОРМАЛЬЮ ЗЕМЛИ, а не своей: у стоячей дощечки нормаль смотрит
# вбок, и трава на солнечном склоне вышла бы тёмной, будто в тени.
const BLADES_MIN: int = 3
const BLADES_MAX: int = 12

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

	# Молодая кочка — три былинки, взрослая — дюжина: пучок густеет числом.
	var count: int = BLADES_MIN + int(float(BLADES_MAX - BLADES_MIN) * m)
	var reach: float = main.CELL_SPACING * lerpf(0.04, 0.13, m)
	var tall: float = main.CELL_SPACING * lerpf(0.05, 0.16, m)

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
		var at: Vector3 = centre + (side * cos(ra) + along * sin(ra)) * rr
		# Своя сторона у каждой дощечки — она и даёт «под разными углами».
		var turn: float = TAU * _hash01(salt + i * 29)
		var face: Vector3 = side * cos(turn) + along * sin(turn)
		var w: float = tall * (0.50 + 0.45 * _hash01(salt + i * 97))
		var h: float = tall * (0.65 + 0.70 * _hash01(salt + i * 53))
		# Заваливаем дощечку набок — иначе пучок стоит звездой из ровных стенок.
		var up: Vector3 = (nrm + face * (_hash01(salt + i * 37) - 0.5) * 0.55).normalized()
		var half: Vector3 = face * (w * 0.5)
		var foot: Vector3 = at - nrm * (h * 0.12)   # корень чуть утоплен в землю

		var cx: int = (salt + i * 7) % ATLAS
		var cy: int = (salt / 3 + i * 5) % ATLAS
		var u0: float = float(cx) / float(ATLAS)
		var u1: float = float(cx + 1) / float(ATLAS)
		var v0: float = float(cy) / float(ATLAS)          # верх листа — концы
		var v1: float = float(cy + 1) / float(ATLAS)      # низ — корни

		var shade: float = 0.80 + 0.34 * _hash01(salt + i * 11)
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


# Кочка: несколько сужающихся кверху колец, каждое со своей неровностью.
# Получается пухлый бугор неправильной формы, а не плоская нашлёпка.
const CUSHION := [
	{"scale": 1.00, "height": 0.00},
	{"scale": 0.88, "height": 0.48},
	{"scale": 0.56, "height": 0.84},
]
const RIM_POINTS: int = 9          # столько точек по кругу подушки

func _emit_patch(st: SurfaceTool, p: Dictionary) -> bool:
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

	# Молодая кочка мала, взрослая — с ладонь. Размер держим МЕЛКИМ: подушка в
	# полшага решётки — это полтора метра мха, валун, а не кочка. Заросли должны
	# набираться числом кочек, а не величиной каждой.
	var reach: float = main.CELL_SPACING * lerpf(0.07, 0.22, m)
	# Лиана не подушка, а плеть: тот же бугор, но вытянутый по склону вверх и
	# приплюснутый. Отдельная плеть с листьями вернётся, когда дойдут руки.
	var stretch: float = 1.0
	var flat: float = 1.0
	var lead: Vector3 = side
	if str(def.get("shape", "")) == "vine":
		var up: Vector3 = Vector3.UP - nrm * nrm.dot(Vector3.UP)
		if up.length_squared() > 0.001:
			lead = up.normalized()
			side = lead
			along = nrm.cross(side).normalized()
		stretch = 2.1
		flat = 0.45

	# Точки обода — по кругу, каждая со своим отклонением. Отклонение считаем
	# ОДИН РАЗ на точку и применяем ко всем кольцам: если сбивать каждое кольцо
	# отдельно, они пересекаются и кочка обрастает шипами.
	var rim: Array = []
	var swell: Array = []
	for i in range(RIM_POINTS):
		var a: float = TAU * float(i) / float(RIM_POINTS)
		var wobble: float = 0.74 + 0.52 * _hash01(salt + i * 17)
		var dir: Vector3 = side * (cos(a) * stretch) + along * sin(a)
		rim.append(centre + dir * reach * wobble)
		swell.append(0.85 + 0.30 * _hash01(salt + i * 53))

	var height: float = reach * flat * 0.85 * (0.35 + 0.65 * m)
	# Кочку ПРИТАПЛИВАЕМ: обод строится по прямой от середины, а земля под ним
	# выгнута — на вогнутом месте кочка повисала бы с видимым зазором.
	var sink: float = height * 0.30

	var levels: Array = []
	for li in range(CUSHION.size()):
		var ring: Array = []
		for i in range(RIM_POINTS):
			var f: Vector3 = centre + (rim[i] - centre) * float(CUSHION[li]["scale"])
			ring.append(f + nrm * (height * float(CUSHION[li]["height"]) * swell[i] - sink))
		levels.append(ring)
	var crown: Vector3 = centre + nrm * (height - sink)

	var base_color: Color = def["color"]
	for li in range(levels.size()):
		# Снизу темнее, к макушке светлее — так бугор читается объёмным.
		var shade: float = float(li) / float(levels.size())
		var tint := base_color.darkened(0.16 * (1.0 - shade)).lightened(0.16 * shade)
		tint = tint.lightened(0.10 * _hash01(salt + 3))
		st.set_color(tint.srgb_to_linear())
		var lower: Array = levels[li]
		if li < levels.size() - 1:
			var upper: Array = levels[li + 1]
			for i in range(RIM_POINTS):
				var j: int = (i + 1) % RIM_POINTS
				var want: Vector3 = ((lower[i] + lower[j]) * 0.5 - centre).normalized() + nrm
				main._emit_polygon(st, [lower[i], lower[j], upper[j], upper[i]],
					want.normalized())
		else:
			for i in range(RIM_POINTS):
				var j2: int = (i + 1) % RIM_POINTS
				main._emit_polygon(st, [crown, lower[i], lower[j2]], nrm)
	return true


func _hash01(n: int) -> float:
	var x: int = (n * 1103515245 + 12345) & 0x7fffffff
	return float((x >> 8) & 0xffff) / 65535.0
