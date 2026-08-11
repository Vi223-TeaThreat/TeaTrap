extends RefCounted
# =============================================================================
#  ОБЪЁМНАЯ СЕТКА — ячейки Вороного в пространстве.
#
#  Ячейка — это область, которая ближе к своему семени, чем к любому другому.
#  В плоскости такая ячейка была многоугольником, в пространстве становится
#  многогранником — неправильной глыбой с плоскими гранями.
#
#  КАК СЧИТАЕМ. Обычно для этого строят трёхмерную триангуляцию, которой в
#  Godot нет и которая капризна. Мы идём проще: берём вокруг семени куб и
#  последовательно ОТСЕКАЕМ его плоскостями, равноудалёнными от этого семени
#  и от каждого соседнего. Что осталось — и есть ячейка. Каждая отсекающая
#  плоскость сразу говорит, кто сосед за этой гранью.
#
#  ВЫРЕЗАЕМ ПО ТРЕБОВАНИЮ. Семян в мире десятки тысяч, а нужны из них
#  считаные тысячи: только те, что лежат на поверхности острова. Глубина
#  острова никогда не видна, и её многогранники никому не нужны. Поэтому
#  ячейка вырезается в тот миг, когда её впервые спросили, и запоминается.
#  Обращаться к ячейкам ТОЛЬКО через `faces_of` / `is_valid` / `cell` —
#  прямое чтение `cells[i]` вернёт пустоту у ещё не вырезанной.
#
#  Что отдаёт наружу:
#    seeds  — семена (центры ячеек)
#    verts  — все вершины сетки (общие для соседних ячеек)
#    cells  — ячейки: список граней, у каждой петля вершин и номер соседа
#    solid  — какие ячейки заполнены породой на старте
# =============================================================================

const EPS: float = 0.00001
const WELD: float = 0.01          # на таком расстоянии вершины считаем одной

var seeds: PackedVector3Array = PackedVector3Array()
var lattice: PackedVector3Array = PackedVector3Array()   # узлы решётки семян
var verts: PackedVector3Array = PackedVector3Array()
var cells: Array = []             # {faces: Array[{loop, nb}], valid: bool}
var solid: Dictionary = {}        # номер ячейки -> true

var _spacing: float = 1.8
var _seed_hash: Dictionary = {}
var _vert_hash: Dictionary = {}
var _cell_size: float = 1.8
var _node_index: Dictionary = {}  # узел решётки Vector3i -> номер семени
var _play: PackedByteArray = PackedByteArray()    # семя внутри играбельного объёма
var _built: PackedByteArray = PackedByteArray()   # ячейку уже вырезали
const NO_CELL := {"faces": [], "valid": false}
var carve_usec: int = 0           # сколько всего ушло на вырезание


# --- Главная функция ---------------------------------------------------------
var _play_radius: float = 0.0
var _play_low: float = 0.0
var _play_high: float = 0.0


func generate(radius: float, top: float, bottom: float, headroom: float,
		spacing: float, grid_seed: int) -> void:
	_spacing = spacing
	_cell_size = spacing * 1.4
	# Играбельный объём: сам остров плюс запас по высоте для построек.
	_play_radius = radius + spacing * 0.6
	_play_low = bottom - spacing * 0.6
	_play_high = top + headroom
	var rng := RandomNumberGenerator.new()
	rng.seed = grid_seed

	var shape := FastNoiseLite.new()
	shape.seed = grid_seed
	shape.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	shape.frequency = 0.045

	# Семена берём с запасом за краем: у крайних ячеек нет всех соседей,
	# их не удаётся замкнуть, и мы их отбрасываем.
	var margin := spacing * 2.0
	_scatter(_play_radius + margin, _play_high + margin, _play_low - margin, rng)
	_build_seed_hash()
	_build_cells()
	_mark_terrain(radius, top, bottom, shape)
	_close_pits(2, top, bottom)


# --- Семена ------------------------------------------------------------------
# Семена сидят на решётке и разбросаны случайно вокруг своих узлов. Но два
# соседних узла могут качнуться навстречу и почти слипнуться — тогда грань
# между ними проходит вплотную к обоим, и обе ячейки выходят длинными
# лепёшками. Поэтому подошедшее вплотную семя ОТОДВИГАЕМ: разброс остаётся,
# вырожденные пары исчезают.
const MIN_SEP: float = 0.62       # доля шага, ближе семена не подпускаем
const JITTER: float = 0.30        # доля шага, на которую семя гуляет от узла

func _scatter(radius: float, top: float, bottom: float, rng: RandomNumberGenerator) -> void:
	seeds = PackedVector3Array()
	lattice = PackedVector3Array()
	_node_index = {}
	var gap := _spacing * MIN_SEP
	var nx := int(ceil(radius / _spacing)) + 1
	var ny_lo := int(floor(bottom / _spacing)) - 1
	var ny_hi := int(ceil(top / _spacing)) + 1
	for i in range(-nx, nx + 1):
		for j in range(ny_lo, ny_hi + 1):
			for k in range(-nx, nx + 1):
				var node := Vector3(i, j, k) * _spacing
				# Разброс умеренный. При большом семя на кромке улетает далеко
				# от своего узла, его ячейка вылезает наружу и после
				# сглаживания превращается в колючий шип.
				var p := node + Vector3(rng.randf_range(-JITTER, JITTER),
					rng.randf_range(-JITTER, JITTER), rng.randf_range(-JITTER, JITTER)) * _spacing
				if Vector2(p.x, p.z).length() > radius:
					continue
				if p.y < bottom or p.y > top:
					continue
				# Отодвигаем от уже поставленных соседей по решётке.
				for dx in range(-1, 2):
					for dy in range(-1, 2):
						for dz in range(-1, 2):
							var key := Vector3i(i + dx, j + dy, k + dz)
							if not _node_index.has(key):
								continue
							var other: Vector3 = seeds[_node_index[key]]
							var away: Vector3 = p - other
							var far: float = away.length()
							if far > 0.0001 and far < gap:
								p = other + away / far * gap
				_node_index[Vector3i(i, j, k)] = seeds.size()
				seeds.append(p)
				# Узел решётки запоминаем: по нему размечается порода. Если
				# мерить по разбросанному семени, береговая линия и верх
				# острова становятся рваными на масштабе ячейки — остров
				# покрывается бородавками и ямками.
				lattice.append(node)


func _build_seed_hash() -> void:
	_seed_hash = {}
	for i in range(seeds.size()):
		var key := _key_of(seeds[i])
		if not _seed_hash.has(key):
			_seed_hash[key] = []
		_seed_hash[key].append(i)


func _key_of(p: Vector3) -> Vector3i:
	return Vector3i(int(floor(p.x / _cell_size)), int(floor(p.y / _cell_size)),
		int(floor(p.z / _cell_size)))


# Соседние семена по возрастанию расстояния. Порядок важен: по нему работает
# раннее прекращение отсечения.
#
# Сортируем НАТИВНО, упаковав расстояние и номер в одно целое: квадрат
# расстояния в старшую часть, номер семени — в младшую. Сравнение лямбдой
# на десятках тысяч ячеек обходилось дороже самого отсечения.
func _near_seeds(index: int, reach: float) -> PackedInt32Array:
	var origin: Vector3 = seeds[index]
	var span := int(ceil(reach / _cell_size))
	var base := _key_of(origin)
	var reach2 := reach * reach
	var keyed := PackedInt64Array()
	for dx in range(-span, span + 1):
		for dy in range(-span, span + 1):
			for dz in range(-span, span + 1):
				var key := base + Vector3i(dx, dy, dz)
				if not _seed_hash.has(key):
					continue
				for j in _seed_hash[key]:
					if j == index:
						continue
					var d2: float = origin.distance_squared_to(seeds[j])
					if d2 <= reach2:
						keyed.append(int(d2 * 1000000.0) * 1048576 + j)
	keyed.sort()
	var out := PackedInt32Array()
	out.resize(keyed.size())
	for i in range(keyed.size()):
		out[i] = keyed[i] % 1048576
	return out


# Все семена вокруг точки — без вырезания ячеек. По этому дешёвому запросу
# видно, не погребена ли ячейка целиком внутри породы.
func seeds_near(p: Vector3, radius: float) -> PackedInt32Array:
	var span := int(ceil(radius / _cell_size))
	var base := _key_of(p)
	var r2 := radius * radius
	var out := PackedInt32Array()
	for dx in range(-span, span + 1):
		for dy in range(-span, span + 1):
			for dz in range(-span, span + 1):
				var key := base + Vector3i(dx, dy, dz)
				if not _seed_hash.has(key):
					continue
				for j in _seed_hash[key]:
					if seeds[j].distance_squared_to(p) <= r2:
						out.append(j)
	return out


# Радиус, в котором вообще могут оказаться соседи ячейки. Отсечение дальше
# не заглядывает, поэтому всё за этим радиусом соседом быть не может.
# Замерено на живой сетке: самый дальний сосед лежит в 2.39 шага, 99.9%
# связей короче двух. Запас до 2.5 — и ни шагом больше: каждая десятая
# доля радиуса стоит времени на каждой ячейке мира.
func neighbour_reach() -> float:
	return _spacing * 2.5


# --- Построение ячеек --------------------------------------------------------
# Сами многогранники здесь НЕ считаются — только отмечается, у каких семян
# они в принципе могут быть. Запасное кольцо за краем не вырезаем никогда:
# оно нужно лишь как соседи, чтобы крайние играбельные ячейки замкнулись.
func _build_cells() -> void:
	verts = PackedVector3Array()
	_vert_hash = {}
	cells = []
	cells.resize(seeds.size())
	_play = PackedByteArray()
	_built = PackedByteArray()
	_play.resize(seeds.size())
	_built.resize(seeds.size())
	for i in range(seeds.size()):
		_play[i] = 1 if _in_play(seeds[i]) else 0


# Ячейка по требованию: первый спрос её вырезает, дальше отдаём готовую.
func cell(index: int) -> Dictionary:
	if index < 0 or index >= cells.size():
		return NO_CELL
	if _built[index] == 0:
		_built[index] = 1
		if _play[index] == 1:
			var t0 := Time.get_ticks_usec()
			cells[index] = _finish_cell(_carve_closed(index))
			carve_usec += Time.get_ticks_usec() - t0
	var c = cells[index]
	return NO_CELL if c == null else c


func faces_of(index: int) -> Array:
	return cell(index)["faces"]


func is_valid(index: int) -> bool:
	return cell(index)["valid"]


# Может ли у семени вообще быть ячейка — без вырезания.
func in_play(index: int) -> bool:
	return index >= 0 and index < _play.size() and _play[index] == 1


# Вырезали ли уже эту ячейку. Спрашивать, чтобы случайно не заставить её
# вырезаться там, где нужно лишь прибраться за прежней геометрией.
func is_built(index: int) -> bool:
	return index >= 0 and index < cells.size() and cells[index] != null


func built_count() -> int:
	var n := 0
	for c in cells:
		if c != null:
			n += 1
	return n


func _in_play(p: Vector3) -> bool:
	if p.y < _play_low or p.y > _play_high:
		return false
	return Vector2(p.x, p.z).length() <= _play_radius


# Вырезаем ячейку из куба плоскостями соседей.
# Стартовый куб держим впритык: он должен вмещать ячейку целиком, но чем он
# меньше, тем раньше срабатывает раннее прекращение. Если промахнуться в
# меньшую сторону, грань куба уцелеет — тогда повторяем с запасом.
func _carve_closed(index: int) -> Dictionary:
	var poly := _carve(index, _spacing * 1.25)
	if _closed(poly):
		return poly
	return _carve(index, _spacing * 2.0)


func _closed(poly: Dictionary) -> bool:
	if poly.is_empty():
		return false
	for f in poly["faces"]:
		if int(f["nb"]) < 0:
			return false
	return true


func _carve(index: int, half: float) -> Dictionary:
	var origin: Vector3 = seeds[index]
	var poly := _box(origin, half)
	for j in _near_seeds(index, neighbour_reach()):
		var dist: float = origin.distance_to(seeds[j])
		# Плоскость проходит на полпути. Если это дальше самой дальней вершины,
		# она уже ничего не отрежет — и все следующие соседи тоже.
		if dist * 0.5 > _far_vertex(poly, origin) + EPS:
			break
		poly = _clip(poly, (origin + seeds[j]) * 0.5, (seeds[j] - origin).normalized(), j)
		if poly.is_empty():
			break
	return poly


func _finish_cell(poly: Dictionary) -> Dictionary:
	if poly.is_empty():
		return {"faces": [], "valid": false}
	# Ячейка годна, только если её со всех сторон обрезали соседи. Если уцелела
	# грань исходного куба — значит, ячейка не замкнута, и мы её не берём.
	for f in poly["faces"]:
		if int(f["nb"]) < 0:
			return {"faces": [], "valid": false}

	var local: Array = poly["verts"]
	var remap: Dictionary = {}
	var faces_out: Array = []
	for f in poly["faces"]:
		var loop := PackedInt32Array()
		for idx in f["loop"]:
			if not remap.has(idx):
				remap[idx] = _add_vertex(local[idx])
			loop.append(remap[idx])
		if loop.size() >= 3:
			faces_out.append({"loop": loop, "nb": int(f["nb"])})
	return {"faces": faces_out, "valid": faces_out.size() >= 4}


# Общие вершины соседних ячеек склеиваем — иначе поверхность не сошьётся.
# Склеиваем ПО РАССТОЯНИЮ, а не по округлению: каждая ячейка вырезается
# независимо, поэтому одна и та же вершина у двух соседей отличается в
# далёком знаке, и округление может развести их по разным ячейкам.
func _add_vertex(p: Vector3) -> int:
	var base := Vector3i(int(floor(p.x / WELD)), int(floor(p.y / WELD)),
		int(floor(p.z / WELD)))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var key := base + Vector3i(dx, dy, dz)
				if not _vert_hash.has(key):
					continue
				for i in _vert_hash[key]:
					if verts[i].distance_squared_to(p) < WELD * WELD:
						return i
	var idx := verts.size()
	verts.append(p)
	if not _vert_hash.has(base):
		_vert_hash[base] = []
	_vert_hash[base].append(idx)
	return idx


# --- Многогранник: куб и отсечение плоскостью --------------------------------
func _box(center: Vector3, half: float) -> Dictionary:
	var v: Array = []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				v.append(center + Vector3(sx, sy, sz) * half)
	# Порядок вершин: индекс = (sx>0)*4 + (sy>0)*2 + (sz>0)
	var loops := [
		[0, 1, 3, 2], [4, 6, 7, 5],
		[0, 4, 5, 1], [2, 3, 7, 6],
		[0, 2, 6, 4], [1, 5, 7, 3],
	]
	var faces: Array = []
	for l in loops:
		faces.append({"loop": l.duplicate(), "nb": -1})
	var poly := {"verts": v, "faces": faces}
	# Вместо ручной выверки обхода просто разворачиваем грани наружу.
	for f in poly["faces"]:
		if _newell(v, f["loop"]).dot(_loop_center(v, f["loop"]) - center) < 0.0:
			f["loop"].reverse()
	return poly


# Отсекает часть многогранника по плоскости. Нормаль смотрит наружу:
# всё, что «за» плоскостью, отбрасывается, а срез становится новой гранью.
func _clip(poly: Dictionary, point: Vector3, normal: Vector3, nb: int) -> Dictionary:
	var pv: Array = poly["verts"]
	# Расстояния держим в ПОЛНОЙ точности: у одинарной вершины на самой
	# плоскости классифицируются то так, то иначе — многогранник рассыпается.
	var dist := PackedFloat64Array()
	dist.resize(pv.size())
	var any_out := false
	var any_in := false
	for i in range(pv.size()):
		var d: float = (pv[i] - point).dot(normal)
		dist[i] = d
		if d > EPS:
			any_out = true
		else:
			any_in = true
	if not any_out:
		return poly
	if not any_in:
		return {}

	var nv: Array = pv.duplicate()
	var on_edge: Dictionary = {}
	var faces_out: Array = []

	for f in poly["faces"]:
		var loop: Array = f["loop"]
		var kept: Array = []
		var m := loop.size()
		for a in range(m):
			var u: int = loop[a]
			var v: int = loop[(a + 1) % m]
			if dist[u] <= EPS:
				kept.append(u)
			if (dist[u] > EPS) != (dist[v] > EPS):
				var key := Vector2i(mini(u, v), maxi(u, v))
				if not on_edge.has(key):
					var t: float = clampf(dist[u] / (dist[u] - dist[v]), 0.0, 1.0)
					on_edge[key] = nv.size()
					nv.append(pv[u].lerp(pv[v], t))
				kept.append(on_edge[key])
		# Вершина, лёгшая точно на плоскость, попадает в петлю дважды.
		var clean: Array = []
		for idx in kept:
			if clean.is_empty() or clean[clean.size() - 1] != idx:
				clean.append(idx)
		if clean.size() >= 2 and clean[0] == clean[clean.size() - 1]:
			clean.remove_at(clean.size() - 1)
		if clean.size() >= 3:
			faces_out.append({"loop": clean, "nb": f["nb"]})

	# Новая грань на месте среза. Собираем её не по цепочке рёбер, а по всем
	# вершинам, легшим на плоскость: у выпуклого тела срез всегда выпуклый,
	# поэтому достаточно упорядочить их по кругу. Цепочка рвалась всякий раз,
	# когда вершина попадала ровно на плоскость.
	var ring: Array = []
	var seen: Dictionary = {}
	for f in faces_out:
		for idx in f["loop"]:
			if seen.has(idx):
				continue
			seen[idx] = true
			if absf((nv[idx] - point).dot(normal)) <= EPS * 20.0:
				ring.append(idx)

	if ring.size() >= 3:
		var mid := Vector3.ZERO
		for idx in ring:
			mid += nv[idx]
		mid /= float(ring.size())
		var ax := normal.cross(Vector3.UP)
		if ax.length() < 0.1:
			ax = normal.cross(Vector3.RIGHT)
		ax = ax.normalized()
		var ay := normal.cross(ax).normalized()
		# Упорядочиваем по кругу нативной сортировкой: угол уходит в старшую
		# часть целого, номер вершины — в младшую. Сравнение лямбдой звалось
		# здесь по десять раз на каждый рез каждой ячейки мира.
		var keyed := PackedInt64Array()
		for idx in ring:
			var p: Vector3 = nv[idx] - mid
			keyed.append(int((atan2(p.dot(ay), p.dot(ax)) + 4.0) * 1000000.0) * 1048576 + idx)
		keyed.sort()
		var order: Array = []
		for k in keyed:
			order.append(k % 1048576)
		if _newell(nv, order).dot(normal) < 0.0:
			order.reverse()
		faces_out.append({"loop": order, "nb": nb})

	return _compact({"verts": nv, "faces": faces_out})


# Выбрасываем вершины, которые больше ни в одну грань не входят. Иначе они
# копятся с каждым отсечением: расчёт замедляется, а «самая дальняя вершина»
# навсегда остаётся прежней, и раннее прекращение не срабатывает.
func _compact(poly: Dictionary) -> Dictionary:
	var pv: Array = poly["verts"]
	var remap := PackedInt32Array()
	remap.resize(pv.size())
	remap.fill(-1)
	var nv: Array = []
	var nf: Array = []
	for f in poly["faces"]:
		var loop: Array = f["loop"]
		var out: Array = []
		out.resize(loop.size())
		for k in range(loop.size()):
			var i: int = loop[k]
			if remap[i] < 0:
				remap[i] = nv.size()
				nv.append(pv[i])
			out[k] = remap[i]
		nf.append({"loop": out, "nb": f["nb"]})
	return {"verts": nv, "faces": nf}


func _far_vertex(poly: Dictionary, center: Vector3) -> float:
	var best := 0.0
	for v in poly["verts"]:
		best = maxf(best, center.distance_to(v))
	return best


func _loop_center(vs: Array, loop: Array) -> Vector3:
	var s := Vector3.ZERO
	for i in loop:
		s += vs[i]
	return s / float(loop.size())


func _newell(vs: Array, loop: Array) -> Vector3:
	var n := Vector3.ZERO
	var m := loop.size()
	for i in range(m):
		var a: Vector3 = vs[loop[i]]
		var b: Vector3 = vs[loop[(i + 1) % m]]
		n.x += (a.y - b.y) * (a.z + b.z)
		n.y += (a.z - b.z) * (a.x + b.x)
		n.z += (a.x - b.x) * (a.y + b.y)
	return n.normalized() if n.length() > EPS else Vector3.UP


# --- Порода: какие ячейки заполнены на старте --------------------------------
# Порода размечается ПО СЕМЕНАМ, без вырезания: иначе пришлось бы посчитать
# все многогранники мира ради проверки, которой хватает координаты.
func _mark_terrain(radius: float, top: float, bottom: float, shape: FastNoiseLite) -> void:
	solid = {}
	for i in range(seeds.size()):
		if _play[i] == 0:
			continue
		# Меряем по УЗЛУ решётки, а не по разбросанному семени: иначе соседние
		# семена случайно оказываются по разные стороны поверхности, и граница
		# породы получается рваной на масштабе ячейки. Форма ячеек при этом
		# остаётся неправильной — рваной становилась именно кромка.
		# По высоте берём МЕЖДУ узлом и семенем: чистый узел даёт ровные
		# ступени-террасы вдоль горизонталей, чистое семя — рваную кромку.
		# Малой доли разброса хватает, чтобы разбить ступени, не разлохматив
		# поверхность.
		var s: Vector3 = lattice[i]
		s.y = lerpf(s.y, seeds[i].y, 0.6)
		if s.y < bottom or s.y > top:
			continue
		# Береговая линия слегка гуляет, а верх острова — холмистый.
		var edge := radius * (1.0 + 0.10 * shape.get_noise_2d(s.x * 2.0, s.z * 2.0))
		if Vector2(s.x, s.z).length() > edge:
			continue
		var surface := shape.get_noise_2d(s.x, s.z) * (top * 0.8)
		if s.y <= surface:
			solid[i] = true


# Затягиваем одиночные ямы и сбриваем одиночные бугры.
#
# Поверхность острова задана плавным полем высот, но семя гуляет вокруг своего
# узла и иногда перескакивает эту поверхность в одиночку: тогда прямо посреди
# склона появляется пустая ячейка — яма — или, наоборот, торчит одинокая глыба.
# Считаем по 26 соседям ПО РЕШЁТКЕ (это дёшево и не требует вырезания ячеек):
# пустая ячейка, у которой почти всё вокруг заполнено, — это яма, засыпаем;
# заполненная, у которой почти всё вокруг пусто, — бугор, убираем.
const FILL_AT: int = 19           # столько соседей из 26 — и пустота считается ямой
const DROP_AT: int = 9            # меньше стольких — и глыба считается бугром

func _close_pits(passes: int, top: float, bottom: float) -> void:
	for _p in range(passes):
		var fill: Array = []
		var drop: Array = []
		for node in _node_index:
			var i: int = _node_index[node]
			if _play[i] == 0:
				continue
			var around := 0
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					for dz in range(-1, 2):
						if dx == 0 and dy == 0 and dz == 0:
							continue
						var j = _node_index.get(node + Vector3i(dx, dy, dz), -1)
						if j >= 0 and solid.has(j):
							around += 1
			if solid.has(i):
				if around <= DROP_AT:
					drop.append(i)
			elif around >= FILL_AT:
				# Засыпать можно только в пределах самого острова.
				var y: float = lattice[i].y
				if y >= bottom and y <= top:
					fill.append(i)
		if fill.is_empty() and drop.is_empty():
			return
		for i in fill:
			solid[i] = true
		for i in drop:
			solid.erase(i)


# --- Запросы наружу ----------------------------------------------------------
# Ближайшая ячейка к точке — нужна, чтобы понимать, куда указывает курсор.
func cell_at(p: Vector3) -> int:
	var base := _key_of(p)
	var best := -1
	var best_d := INF
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var key := base + Vector3i(dx, dy, dz)
				if not _seed_hash.has(key):
					continue
				for i in _seed_hash[key]:
					var d: float = seeds[i].distance_squared_to(p)
					if d < best_d:
						best_d = d
						best = i
	return best


func neighbors_of(index: int) -> Array:
	var out: Array = []
	for f in faces_of(index):
		out.append(f["nb"])
	return out


# Считаем только по уже вырезанным — иначе запрос статистики построит весь мир.
func face_histogram() -> Dictionary:
	var h: Dictionary = {}
	for c in cells:
		if c == null or not c["valid"]:
			continue
		var n: int = c["faces"].size()
		h[n] = int(h.get(n, 0)) + 1
	var keys := h.keys()
	keys.sort()
	var sorted_h: Dictionary = {}
	for k in keys:
		sorted_h[k] = h[k]
	return sorted_h
