extends Node3D
# =============================================================================
#  РАСТЕНИЯ НА ОБЪЁМНОЙ ПОВЕРХНОСТИ.
#
#  В плоской версии приходилось различать «верх / стену / крышу / уровень».
#  Здесь этого нет: поверхность мира — просто набор граней, и растение живёт
#  на КУСОЧКЕ грани. Ключ кусочка — (ячейка, номер грани, угол).
#
#  Каждая грань после сглаживания распадается на кусочки по числу своих углов:
#  угол — точка ребра — середина грани — точка другого ребра. Растения ложатся
#  прямо на эти кусочки, то есть ровно на видимую поверхность.
#
#  Расползание идёт по соседним кусочкам: внутри грани и через ребро на
#  соседнюю грань — хоть на стену, хоть под нависание, хоть на макушку.
# =============================================================================

const PlantsData = preload("res://Plants.gd")

const TICK: float = 0.15
const STEPS: int = 6

# Дробление грани. Кусочек — полоса от РЕБРА грани к её середине. Такие
# полосы всегда компактные трапеции. (Раньше полоса шла вокруг угла, от
# ребра к ребру, и на острых углах выходила буквой Г.)
# Колец тем больше, чем дальше ребро от середины грани.
# Полосы делятся ещё и ВДОЛЬ ребра на столбцы — иначе на длинном ребре
# кусочек выходит вытянутым. А в середине грани сидит отдельный кусочек:
# без него кольца сходились бы в тонкий клин.
const RING_SIZE: float = 0.6      # желаемый размер кусочка
const RINGS_MAX: int = 3
const COLS_MAX: int = 3
const RING_JIT: float = 0.14      # насколько гуляют границы колец
const RING_MIN: float = 0.18      # тоньше этой доли полосу не делаем — иначе осколки
const CORE_T: float = 0.78        # докуда доходят кольца, дальше — серединка
const MERGE_P: float = 0.40       # доля кусочков, сросшихся с соседним столбцом

var main: Node3D
var patches: Dictionary = {}      # Vector3i(ячейка, грань, угол) -> {id, m, step}
var cell_nodes: Dictionary = {}   # ячейка -> меш со всеми её растениями
var time_scale: float = 1.0
var _dirty: Dictionary = {}
var _accum: float = 0.0
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
#  Рост и расползание
# =============================================================================
func _tick(dt: float) -> void:
	var sprouts: Array = []
	for key in patches:
		var p: Dictionary = patches[key]
		var def: Dictionary = PlantsData.ITEMS[p["id"]]
		var rate: float = def["grow_rate"] * (1.0 + def["shade_love"] * _shade(key))
		if _at_joint(key):
			rate *= 1.0 + def["joint_love"]
		p["m"] = minf(1.0, p["m"] + rate * dt)

		if p["m"] >= def["spread_at"] and _rng.randf() < def["spread_rate"] * dt:
			var target = _pick_target(key, p["id"], def)
			if target != null:
				sprouts.append([target, p["id"]])

	for s in sprouts:
		_create(s[0], s[1], 0.05)
	_flush()


func plant(key: Vector3i, id: String) -> bool:
	if patches.has(key) or not _valid(key):
		return false
	_create(key, id, 0.15)
	_flush()
	return true


func remove_at(key: Vector3i) -> void:
	if patches.has(key):
		patches.erase(key)
		_dirty[key.x] = true
		_flush()


func _create(key: Vector3i, id: String, maturity: float) -> void:
	if patches.has(key):
		return
	patches[key] = {"id": id, "m": maturity, "step": -1}
	_dirty[key.x] = true


# Всплеск роста от действия игрока.
func burst_at(cell: int, amount: float = 0.30) -> void:
	var touched: Dictionary = {cell: true}
	for nb in main.grid.neighbors_of(cell):
		if nb >= 0:
			touched[nb] = true
	for key in patches:
		if touched.has(key.x):
			patches[key]["m"] = minf(1.0, patches[key]["m"] + amount)
			_dirty[key.x] = true
	_flush()


# Поверхность мира перестроилась — убираем растения с исчезнувших граней
# и перерисовываем остальные: они могли сдвинуться вместе с оболочкой.
func surface_changed() -> void:
	var doomed: Array = []
	for key in patches:
		if not _valid(key):
			doomed.append(key)
	for key in doomed:
		patches.erase(key)
	for key in patches:
		_dirty[key.x] = true
	for cell in cell_nodes:
		_dirty[cell] = true
	_flush()


# =============================================================================
#  Поверхности
# =============================================================================
func _face_key(key: Vector3i) -> Vector2i:
	return Vector2i(key.x, key.y)


func _valid(key: Vector3i) -> bool:
	var fk := _face_key(key)
	if not main.face_geo.has(fk):
		return false
	var geo: Dictionary = main.face_geo[fk]
	if _decode(key, geo).is_empty():
		return false
	# Там, где стоит объект, растению места нет.
	return main.props == null or not main.props.has_prop(key)


func _slots_per_edge() -> int:
	return RINGS_MAX * COLS_MAX


# Разбираем номер кусочка на ребро, кольцо и столбец. Пустой ответ — такого
# кусочка нет. Отдельное значение — серединка грани.
func _decode(key: Vector3i, geo: Dictionary) -> Dictionary:
	var n: int = geo["corners"].size()
	var total := n * _slots_per_edge()
	if key.z == total:
		return {"core": true}
	if key.z < 0 or key.z > total:
		return {}
	var k: int = key.z / _slots_per_edge()
	var rest: int = key.z % _slots_per_edge()
	var r: int = rest / COLS_MAX
	var c: int = rest % COLS_MAX
	if k >= n:
		return {}
	var rings := _rings_for(geo, k)
	if r >= rings:
		return {}
	var cols := _cols_for(key, geo, k, r, rings)
	if c >= cols:
		return {}
	if _absorbed(key, k, r, c, cols):
		return {}                 # этот кусочек сросся с предыдущим
	return {"core": false, "edge": k, "ring": r, "col": c, "rings": rings, "cols": cols,
		"wide": _leads(key, k, r, c, cols)}


# Часть кусочков срастается с соседом справа — так их меньше, а формы
# разнообразнее. Решение всегда одно и то же для одного и того же места.
func _merge_roll(key: Vector3i, k: int, r: int, c: int) -> bool:
	return _hash01(key.x * 311 + key.y * 71 + k * 29 + r * 13 + c * 5) < MERGE_P


func _leads(key: Vector3i, k: int, r: int, c: int, cols: int) -> bool:
	if c + 1 >= cols:
		return false
	if _absorbed(key, k, r, c, cols):
		return false
	return _merge_roll(key, k, r, c)


func _absorbed(key: Vector3i, k: int, r: int, c: int, cols: int) -> bool:
	if c <= 0 or c >= cols:
		return false
	if _absorbed(key, k, r, c - 1, cols):
		return false              # предыдущий сам поглощён, значит не ведущий
	return _merge_roll(key, k, r, c - 1)


# Если кусочек поглощён — возвращаем того, кто его поглотил.
func _canonical(key: Vector3i) -> Vector3i:
	var fk := _face_key(key)
	if not main.face_geo.has(fk):
		return key
	var geo: Dictionary = main.face_geo[fk]
	var n: int = geo["corners"].size()
	if key.z < 0 or key.z >= n * _slots_per_edge():
		return key
	var k: int = key.z / _slots_per_edge()
	var rest: int = key.z % _slots_per_edge()
	var r: int = rest / COLS_MAX
	var c: int = rest % COLS_MAX
	if k >= n or r >= _rings_for(geo, k):
		return key
	var cols := _cols_for(key, geo, k, r, _rings_for(geo, k))
	if c < cols and _absorbed(key, k, r, c, cols):
		return Vector3i(key.x, key.y, _slot(k, r, c - 1))
	return key


func _slot(k: int, r: int, c: int) -> int:
	return k * _slots_per_edge() + r * COLS_MAX + c


# Сколько колец у этого ребра — по тому, как далеко до середины грани.
func _rings_for(geo: Dictionary, edge: int) -> int:
	var mids: PackedVector3Array = geo["mids"]
	var depth: float = mids[edge].distance_to(geo["mid"]) * CORE_T
	return clampi(int(round(depth / RING_SIZE)), 1, RINGS_MAX)


# Сколько столбцов у этой полосы — по её ширине. Ближе к середине грани
# полоса уже, поэтому столбцов там меньше.
func _cols_for(key: Vector3i, geo: Dictionary, edge: int, ring: int, rings: int) -> int:
	var corners: PackedVector3Array = geo["corners"]
	var n := corners.size()
	var t0 := _ring_t(key, edge, ring, rings)
	var t1 := _ring_t(key, edge, ring + 1, rings)
	var width: float = corners[edge].distance_to(corners[(edge + 1) % n]) \
		* (1.0 - (t0 + t1) * 0.5)
	return clampi(int(round(width / RING_SIZE)), 1, COLS_MAX)


# Граница кольца: доля пути от ребра к середине грани. Гуляет от места к месту,
# но всегда одинаково — иначе соседние кусочки разошлись бы.
func _ring_t(key: Vector3i, edge: int, i: int, rings: int) -> float:
	if i <= 0:
		return 0.0
	if i >= rings:
		return CORE_T
	var base := float(i) / float(rings) * CORE_T
	var jit := _hash01(key.x * 131 + key.y * 37 + edge * 17 + i * 7) * 2.0 - 1.0
	return clampf(base + RING_JIT * jit, RING_MIN, CORE_T - RING_MIN * 0.5)


func _col_u(key: Vector3i, edge: int, ring: int, i: int, cols: int) -> float:
	if i <= 0:
		return 0.0
	if i >= cols:
		return 1.0
	var base := float(i) / float(cols)
	var jit := _hash01(key.x * 91 + key.y * 43 + edge * 23 + ring * 11 + i * 5) * 2.0 - 1.0
	return clampf(base + RING_JIT * jit, RING_MIN, 1.0 - RING_MIN)


# Все соседи приводятся к «ведущему» кусочку, иначе сросшиеся выпадали бы
# из расползания.
func _neighbors_canon(key: Vector3i) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for k in _neighbors(key):
		var c := _canonical(k)
		if c == key or seen.has(c):
			continue
		seen[c] = true
		out.append(c)
	return out


func _pick_target(key: Vector3i, id: String, def: Dictionary):
	var free: Array = []
	for k in _neighbors_canon(key):
		if not patches.has(k) and _valid(k):
			free.append(k)
	if free.is_empty():
		return null
	# Выбор не равновероятный: растение охотнее идёт туда, где ему хорошо.
	# Для лианы это же правило превращает расползание в НАПРАВЛЕННЫЙ побег:
	# сильный перевес вверх — и мох ползёт ковром, а лиана лезет плетью.
	var here: Vector3 = _patch_centre(key)
	var weights: Array = []
	var total := 0.0
	for k in free:
		var w: float = 1.0 + def["shade_love"] * _shade(k)
		if _at_joint(k):
			w += def["joint_love"]
		var climb: float = float(def.get("climb", 0.0))
		if climb > 0.0:
			var there: Vector3 = _patch_centre(k)
			var up: float = there.y - here.y
			var reach: float = maxf(absf(up), 0.0001)
			# Вверх — охотно; вниз — только если это низ нависания, тогда
			# лиана переваливается через кромку и свисает.
			if up > 0.0:
				w += climb * clampf(up / reach, 0.0, 1.0) * 3.0
			elif _patch_normal(k).y < -0.25:
				w += float(def.get("hang", 0.0)) * 2.5
			else:
				w *= 0.25
		var prop_love: float = float(def.get("support_love", 0.0))
		if prop_love > 0.0 and _near_support(k):
			w += prop_love
		weights.append(w)
		total += w
	var roll := _rng.randf() * total
	for i in range(free.size()):
		roll -= weights[i]
		if roll <= 0.0:
			return free[i]
	return free[free.size() - 1]


func _neighbors(key: Vector3i) -> Array:
	var out: Array = []
	var loop := _face_loop(key)
	if loop.is_empty():
		return out
	var fk := _face_key(key)
	if not main.face_geo.has(fk):
		return out
	var geo: Dictionary = main.face_geo[fk]
	var part := _decode(key, geo)
	if part.is_empty():
		return out
	var n := loop.size()

	# Серединка граничит со всеми внутренними кольцами грани.
	if part["core"]:
		for k2 in range(n):
			var rings2 := _rings_for(geo, k2)
			for c2 in range(COLS_MAX):
				out.append(Vector3i(key.x, key.y, _slot(k2, rings2 - 1, c2)))
		return out

	var k: int = part["edge"]
	var r: int = part["ring"]
	var c: int = part["col"]
	var core_slot := n * _slots_per_edge()

	# Соседи по столбцам и по кольцам внутри своей полосы.
	out.append(Vector3i(key.x, key.y, _slot(k, r, c - 1)))
	out.append(Vector3i(key.x, key.y, _slot(k, r, c + 1)))
	if r > 0:
		out.append(Vector3i(key.x, key.y, _slot(k, r - 1, c)))
	if r + 1 < int(part["rings"]):
		out.append(Vector3i(key.x, key.y, _slot(k, r + 1, c)))
	else:
		out.append(Vector3i(key.x, key.y, core_slot))
	# По краям столбцов — на соседнее ребро грани, за угол.
	if c == 0:
		out.append(Vector3i(key.x, key.y, _slot((k - 1 + n) % n, r, COLS_MAX - 1)))
	if c + 1 >= int(part["cols"]):
		out.append(Vector3i(key.x, key.y, _slot((k + 1) % n, r, 0)))

	# Наружу за грань уходит только внешнее кольцо — через своё ребро.
	if r > 0:
		return out
	var e := Vector2i(mini(loop[k], loop[(k + 1) % n]), maxi(loop[k], loop[(k + 1) % n]))
	if not main.edge_faces.has(e):
		return out
	for other in main.edge_faces[e]:
		if other == _face_key(key):
			continue
		var other_loop := _face_loop(Vector3i(other.x, other.y, 0))
		var m := other_loop.size()
		for j in range(m):
			var oe := Vector2i(mini(other_loop[j], other_loop[(j + 1) % m]),
				maxi(other_loop[j], other_loop[(j + 1) % m]))
			if oe == e:
				for c3 in range(COLS_MAX):
					out.append(Vector3i(other.x, other.y, _slot(j, 0, c3)))
				break
	return out


func _face_loop(key: Vector3i) -> PackedInt32Array:
	var cell_faces: Array = main.grid.faces_of(key.x)
	if key.y < 0 or key.y >= cell_faces.size():
		return PackedInt32Array()
	return cell_faces[key.y]["loop"]


# Кусочек на стыке: соседняя грань принадлежит ДРУГОЙ глыбе — то есть здесь
# проходит шов между двумя телами.
func _at_joint(key: Vector3i) -> bool:
	var loop := _face_loop(key)
	if loop.is_empty():
		return false
	var fk := _face_key(key)
	if not main.face_geo.has(fk):
		return false
	var part := _decode(key, main.face_geo[fk])
	if part.is_empty() or part["core"] or int(part["ring"]) != 0:
		return false                      # к шву примыкает только внешнее кольцо
	var n := loop.size()
	var k: int = part["edge"]
	var e := Vector2i(mini(loop[k], loop[(k + 1) % n]), maxi(loop[k], loop[(k + 1) % n]))
	if not main.edge_faces.has(e):
		return false
	for other in main.edge_faces[e]:
		if other.x != key.x:
			return true
	# Подножие объекта — тоже стык: у камня и стены мох селится охотнее.
	# Считаем соседей только если объекты вообще есть — иначе это лишняя работа
	# на каждом шаге роста.
	if main.props != null and not main.props.is_empty():
		return main.props.any_near(_neighbors_canon(key))
	return false


# Затенение: чем больше вокруг глыбы соседей и чем меньше грань смотрит вверх,
# тем темнее место.
func _shade(key: Vector3i) -> float:
	var nbs: Array = main.grid.neighbors_of(key.x)
	if nbs.is_empty():
		return 0.0
	var closed := 0
	for nb in nbs:
		if nb >= 0 and main.solid.has(nb):
			closed += 1
	var enclosure := float(closed) / float(nbs.size())
	var up := clampf(_patch_normal(key).y, -1.0, 1.0)
	var shade := enclosure * 0.6 + (1.0 - (up + 1.0) * 0.5) * 0.4
	# Стоящие рядом объекты тоже затеняют.
	if main.props != null and not main.props.is_empty():
		shade += main.props.shade_at(_neighbors_canon(key)) * 0.5
	return clampf(shade, 0.0, 1.0)


# =============================================================================
#  Геометрия кусочка
# =============================================================================
func _patch_polygon(key: Vector3i) -> Array:
	var fk := _face_key(key)
	if not main.face_geo.has(fk):
		return []
	var geo: Dictionary = main.face_geo[fk]
	var part := _decode(key, geo)
	if part.is_empty():
		return []
	var corners: PackedVector3Array = geo["corners"]
	var mid: Vector3 = geo["mid"]
	var n := corners.size()

	if part["core"]:
		# Серединка грани — уменьшенная копия всей грани.
		var core: Array = []
		for v in corners:
			core.append(v.lerp(mid, CORE_T))
		return core

	var k: int = part["edge"]
	var a: Vector3 = corners[k]
	var b: Vector3 = corners[(k + 1) % n]
	var t0 := _ring_t(key, k, part["ring"], part["rings"])
	var t1 := _ring_t(key, k, int(part["ring"]) + 1, part["rings"])
	var u0 := _col_u(key, k, part["ring"], part["col"], part["cols"])
	var span := 2 if part["wide"] else 1     # сросшийся кусочек шире вдвое
	var u1 := _col_u(key, k, part["ring"], int(part["col"]) + span, part["cols"])

	# Четырёхугольник: по ребру — от u0 до u1, вглубь грани — от t0 до t1.
	return [
		a.lerp(b, u0).lerp(mid, t0), a.lerp(b, u1).lerp(mid, t0),
		a.lerp(b, u1).lerp(mid, t1), a.lerp(b, u0).lerp(mid, t1),
	]


# Какой кусочек поверхности ближе всего к лучу от курсора. Считаем именно по
# лучу, а не по точке попадания: коллизия у глыб нескруглённая и лежит чуть
# снаружи видимой поверхности, поэтому точка попадания всегда немного мимо.
func spot_under_ray(from: Vector3, dir: Vector3, cells: Array) -> Vector3i:
	var best := Vector3i(-1, -1, -1)
	var best_d := INF
	for cell in cells:
		if not main.solid.has(cell):
			continue
		var cell_faces: Array = main.grid.faces_of(cell)
		for fi in range(cell_faces.size()):
			var fk := Vector2i(cell, fi)
			if not main.face_geo.has(fk):
				continue
			var geo: Dictionary = main.face_geo[fk]
			var corners: PackedVector3Array = geo["corners"]
			var n := corners.size()
			var slots: Array = [n * _slots_per_edge()]     # серединка грани
			for k in range(n):
				# Дешёвая отбраковка обратной стороны — до сборки кусочков.
				if (corners[k] - main.grid.seeds[cell]).dot(dir) > 0.0:
					continue
				for r in range(RINGS_MAX):
					for c in range(COLS_MAX):
						slots.append(_slot(k, r, c))
			for slot in slots:
				var key := Vector3i(cell, fi, slot)
				var poly := _patch_polygon(key)
				if poly.size() < 3:
					continue
				var mid := Vector3.ZERO
				for p in poly:
					mid += p
				mid /= float(poly.size())
				if (mid - main.grid.seeds[cell]).dot(dir) > 0.0:
					continue
				var t: float = (mid - from).dot(dir)
				if t <= 0.0:
					continue
				var d: float = (mid - (from + dir * t)).length_squared()
				if d < best_d:
					best_d = d
					best = key
	return best


func plant_at(key: Vector3i, id: String) -> bool:
	return plant(_canonical(key), id)


func patch_outline(key: Vector3i) -> Array:
	return _patch_polygon(key)


func patch_normal(key: Vector3i) -> Vector3:
	return _patch_normal(key)


# Существует ли такой кусочек поверхности (объектам нужно то же самое).
func spot_exists(key: Vector3i) -> bool:
	var fk := _face_key(key)
	if not main.face_geo.has(fk):
		return false
	return not _decode(key, main.face_geo[fk]).is_empty()


# На кусочек встал объект — растение оттуда убираем.
func spot_blocked(key: Vector3i) -> void:
	if patches.has(key):
		patches.erase(key)
		_dirty[key.x] = true
		_flush()


# Середина кусочка — по ней лиана понимает, где верх, а где низ.
func _patch_centre(key: Vector3i) -> Vector3:
	var poly := _patch_polygon(key)
	if poly.is_empty():
		return Vector3.ZERO
	var mid := Vector3.ZERO
	for p in poly:
		mid += p
	return mid / float(poly.size())


# Есть ли рядом опора: камень, коряга или стена. Лиана у опоры идёт бодрее.
func _near_support(key: Vector3i) -> bool:
	if main.props != null and not main.props.is_empty():
		if main.props.any_near(_neighbors_canon(key)):
			return true
	for nb in main.grid.neighbors_of(key.x):
		if nb < 0:
			continue
		var m: String = main.material_of(nb)
		if m == "building" or m == "cliff":
			return true
	return false


func _patch_normal(key: Vector3i) -> Vector3:
	var poly := _patch_polygon(key)
	if poly.size() < 3:
		return Vector3.UP
	var n: Vector3 = (poly[1] - poly[0]).cross(poly[2] - poly[0])
	if n.length() < 0.000001:
		return Vector3.UP
	n = n.normalized()
	# Разворачиваем наружу — от центра глыбы.
	var mid := Vector3.ZERO
	for p in poly:
		mid += p
	mid /= float(poly.size())
	return -n if n.dot(mid - main.grid.seeds[key.x]) < 0.0 else n


# =============================================================================
#  Отрисовка: один меш на глыбу
# =============================================================================
func _flush() -> void:
	for key in patches:
		var p: Dictionary = patches[key]
		var step := int(p["m"] * STEPS)
		if step != p["step"]:
			p["step"] = step
			_dirty[key.x] = true
	for cell in _dirty:
		_rebuild_cell(cell)
	_dirty.clear()


func _rebuild_cell(cell: int) -> void:
	if cell_nodes.has(cell):
		cell_nodes[cell].queue_free()
		cell_nodes.erase(cell)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for key in patches:
		if key.x == cell and _emit_patch(st, key, patches[key]):
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

func _emit_patch(st: SurfaceTool, key: Vector3i, p: Dictionary) -> bool:
	var poly := _patch_polygon(key)
	if poly.size() < 3:
		return false
	var nrm := _patch_normal(key)
	var def: Dictionary = PlantsData.ITEMS[p["id"]]
	if str(def.get("shape", "")) == "vine":
		return _emit_vine(st, key, p, def, poly, nrm)
	var m: float = p["m"]
	var salt := key.x * 733 + key.y * 97 + key.z * 31

	var centre := Vector3.ZERO
	for v in poly:
		centre += v
	centre /= float(poly.size())

	# Уплотняем контур — по две точки на сторону, чтобы кочка была округлой.
	var rim: Array = []
	var n := poly.size()
	for i in range(n):
		var a: Vector3 = poly[i]
		var b: Vector3 = poly[(i + 1) % n]
		rim.append(a)
		rim.append(a.lerp(b, 0.5))

	# Взрослая кочка чуть перехлёстывает свой кусочек: иначе между соседними
	# кочками остаётся голая межа, и заросшая поверхность выглядит расчерченной.
	var spread: float = lerpf(0.30, 1.03, m)
	var reach := 0.0
	for v in rim:
		reach += centre.distance_to(v)
	reach /= float(rim.size())
	var height: float = reach * spread * 1.25 * (0.35 + 0.65 * m)
	# Кочку ПРИТАПЛИВАЕМ. Кольца строятся по прямой от середины кусочка к его
	# краю, а поверхность под ними выгнута — на вогнутом месте кочка повисала
	# над землёй с видимым зазором. Осадка берётся от собственной высоты, чтобы
	# и молодая, плоская кочка не утонула целиком.
	var sink: float = height * 0.30

	# Неровность задаём ОДИН РАЗ на точку контура и применяем ко всем кольцам.
	# Если сбивать каждое кольцо по отдельности, кольца пересекаются и кочка
	# обрастает шипами вместо мягких бугров.
	var bump: Array = []
	var swell: Array = []
	for i in range(rim.size()):
		bump.append(0.88 + 0.24 * _hash01(salt + i * 17))
		swell.append(0.85 + 0.30 * _hash01(salt + i * 53))

	var levels: Array = []
	for li in range(CUSHION.size()):
		var ring: Array = []
		for i in range(rim.size()):
			var flat: Vector3 = centre + (rim[i] - centre) * spread \
				* float(CUSHION[li]["scale"]) * bump[i]
			ring.append(flat + nrm * (height * float(CUSHION[li]["height"]) * swell[i] - sink))
		levels.append(ring)
	var crown := centre + nrm * (height - sink)

	var base_color: Color = def["color"]
	var count := rim.size()
	for li in range(levels.size()):
		# Снизу темнее, к макушке светлее — так бугор читается объёмным.
		var shade: float = float(li) / float(levels.size())
		var tint := base_color.darkened(0.16 * (1.0 - shade)).lightened(0.16 * shade)
		tint = tint.lightened(0.10 * _hash01(salt + 3))
		st.set_color(tint.srgb_to_linear())
		var lower: Array = levels[li]
		if li < levels.size() - 1:
			var upper: Array = levels[li + 1]
			for i in range(count):
				var j: int = (i + 1) % count
				var want: Vector3 = ((lower[i] + lower[j]) * 0.5 - centre).normalized() + nrm
				main._emit_polygon(st, [lower[i], lower[j], upper[j], upper[i]], want.normalized())
		else:
			for i in range(count):
				var j2: int = (i + 1) % count
				main._emit_polygon(st, [crown, lower[i], lower[j2]], nrm)
	return true


# =============================================================================
#  ЛИАНА
#
#  Не подушка, а плеть: тонкий стебель, идущий поперёк кусочка, и гроздья
#  листьев вдоль него. Молодая — одна ниточка с парой листьев; зрелая пускает
#  несколько плетей рядом, и они смыкаются в полог. Стебель ведём СВЕРХУ ВНИЗ
#  по кусочку, поэтому на стене плети читаются вертикально, а под нависанием
#  свисают.
# =============================================================================
func _emit_vine(st: SurfaceTool, key: Vector3i, p: Dictionary, def: Dictionary,
		poly: Array, nrm: Vector3) -> bool:
	var m: float = p["m"]
	var salt := key.x * 733 + key.y * 97 + key.z * 31

	var centre := Vector3.ZERO
	for v in poly:
		centre += v
	centre /= float(poly.size())
	var reach := 0.0
	for v in poly:
		reach += centre.distance_to(v)
	reach /= float(poly.size())

	# Вдоль чего тянуть плеть: берём направление «вниз по поверхности».
	# На пологом месте вниз нет — тогда тянем вдоль самой длинной оси кусочка.
	var down: Vector3 = Vector3.DOWN - nrm * Vector3.DOWN.dot(nrm)
	if down.length() < 0.15:
		down = poly[0] - centre
	down = down.normalized()
	var across: Vector3 = nrm.cross(down).normalized()

	var strands: int = 1 + int(round(m * 2.0))
	var leaf_color: Color = Color(def["color"])
	var stem_color: Color = leaf_color.darkened(0.45)
	var thick: float = reach * 0.10

	for s in range(strands):
		var lane: float = 0.0 if strands == 1 else (float(s) / float(strands - 1) - 0.5)
		var side: Vector3 = across * lane * reach * 1.1
		var head: Vector3 = centre - down * reach * 0.95 + side
		var tail: Vector3 = centre + down * reach * (0.35 + 0.65 * m) + side
		var wobble: Vector3 = across * reach * 0.30 * (_hash01(salt + s * 29) - 0.5)

		# Стебель — узкая лента из трёх звеньев, слегка виляющая.
		st.set_color(stem_color.srgb_to_linear())
		var prev: Vector3 = head
		for i in range(1, 4):
			var t: float = float(i) / 3.0
			var here: Vector3 = head.lerp(tail, t) + wobble * sin(t * PI)
			var lift: Vector3 = nrm * thick * 0.6
			main._emit_polygon(st, [prev + lift - across * thick,
				prev + lift + across * thick,
				here + lift + across * thick,
				here + lift - across * thick], nrm)
			prev = here

		# Листья — маленькие ромбы вдоль стебля, тем гуще, чем взрослее.
		var leaves: int = 2 + int(round(m * 3.0))
		for i in range(leaves):
			var t2: float = (float(i) + 0.5) / float(leaves)
			var at: Vector3 = head.lerp(tail, t2) + wobble * sin(t2 * PI)
			var flip: float = 1.0 if (i % 2) == 0 else -1.0
			var size: float = reach * (0.18 + 0.20 * m) * (0.7 + 0.6 * _hash01(salt + i * 13 + s * 7))
			var out: Vector3 = across * flip * size
			var along: Vector3 = down * size * 0.75
			var lift2: Vector3 = nrm * thick * (1.1 + 0.5 * _hash01(salt + i * 5))
			st.set_color(leaf_color.lightened(0.14 * _hash01(salt + i * 3)).srgb_to_linear())
			main._emit_polygon(st, [at + lift2 - along,
				at + lift2 + out * 0.6 - along * 0.1,
				at + lift2 + along * 1.2,
				at + lift2 + out * 0.15 + along * 0.2], nrm)
	return true


func _hash01(n: int) -> float:
	var x := (n * 1103515245 + 12345) & 0x7fffffff
	return float(x % 10007) / 10007.0
