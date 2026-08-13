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


func setup(main_ref: Node3D) -> void:
	main = main_ref
	_rng.seed = 20260811
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 0.95


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
	return main.grid.surface_near(p["pos"] + dir * step)


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
				or spot["pos"].distance_to(p["pos"]) > main.CELL_SPACING * 0.5:
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


func _rebuild_cell(cell: int) -> void:
	if cell_nodes.has(cell):
		cell_nodes[cell].queue_free()
		cell_nodes.erase(cell)

	var here: Dictionary = by_cell.get(cell, {})
	if here.is_empty():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for pid in here:
		if patches.has(pid) and _emit_patch(st, patches[pid]):
			any = true
	if not any:
		return

	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	cell_nodes[cell] = mi


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
