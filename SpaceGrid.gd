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
# Шесть прямых соседей по решётке. Кольцо нарочно узкое: по всем двадцати шести
# всё, что считается по соседям, расползается заметно дальше своего места.
const NEIGHBOURS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

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
var fill: PackedFloat32Array = PackedFloat32Array()       # насколько ячейка полна
var base_fill: PackedFloat32Array = PackedFloat32Array()  # природный рельеф
var cavity: PackedFloat32Array = PackedFloat32Array()     # −1 выступ, +1 щель
var edits: Dictionary = {}        # ячейка -> насколько её подняли мазками
var stone: Dictionary = {}        # ячейка -> насколько она каменистая, 0..1
var _rock_noise: FastNoiseLite
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

	# Рельеф в ДВА масштаба: крупная волна задаёт холмы, мелкая ломает её
	# горизонтали на неправильные пятна.
	var shape := FastNoiseLite.new()
	shape.seed = grid_seed
	shape.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	shape.frequency = 0.045
	_rock_noise = FastNoiseLite.new()
	_rock_noise.seed = grid_seed + 4243
	_rock_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_rock_noise.frequency = 0.55

	var detail := FastNoiseLite.new()
	detail.seed = grid_seed + 7717
	detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	detail.frequency = 0.26

	# Семена берём с запасом за краем: у крайних ячеек нет всех соседей,
	# их не удаётся замкнуть, и мы их отбрасываем.
	var margin := spacing * 2.0
	_scatter(_play_radius + margin, _play_high + margin, _play_low - margin, rng,
		shape, detail, top)
	_build_seed_hash()
	_build_cells()
	_fill_terrain(radius, top, bottom, shape, detail)


# --- Семена ------------------------------------------------------------------
# Семена сидят на решётке и разбросаны случайно вокруг своих узлов. Но два
# соседних узла могут качнуться навстречу и почти слипнуться — тогда грань
# между ними проходит вплотную к обоим, и обе ячейки выходят длинными
# лепёшками. Поэтому подошедшее вплотную семя ОТОДВИГАЕМ: разброс остаётся,
# вырожденные пары исчезают.
const MIN_SEP: float = 0.62       # доля шага, ближе семена не подпускаем
# Разброс снова полноценный и по всем осям. Раньше его приходилось зажимать
# ради гладкости: поверхность могла пройти только по границам ячеек, и любая
# пляска семян по высоте выходила буграми. Теперь поверхность идёт по уровню
# ЗАПОЛНЕНИЯ и от разброса не зависит — можно вернуть миру неправильность.
const JITTER: float = 0.34
const JITTER_Y: float = 0.30
# Дальше этого семя от своего узла не уходит. Величина не косметическая:
# два соседних семени могут двинуться навстречу, и если вместе они пройдут
# больше шага решётки, четвёрка семян ВЫВОРАЧИВАЕТСЯ. Вывернутые тетраэдры
# перекрываются с соседними, поверхность идёт в них двумя пересекающимися
# лоскутами, и сквозь место их пересечения видно небо — это и были дыры.
const OFF_MAX: float = 0.27

func _scatter(radius: float, top_edge: float, bottom: float, rng: RandomNumberGenerator,
		shape: FastNoiseLite, detail: FastNoiseLite, top: float) -> void:
	seeds = PackedVector3Array()
	lattice = PackedVector3Array()
	_node_index = {}
	var gap := _spacing * MIN_SEP
	var nx := int(ceil(radius / _spacing)) + 1
	var ny_lo := int(floor(bottom / _spacing)) - 1
	var ny_hi := int(ceil(top_edge / _spacing)) + 1
	for i in range(-nx, nx + 1):
		for k in range(-nx, nx + 1):
			for j in range(ny_lo, ny_hi + 1):
				var node := Vector3(i, j, k) * _spacing
				var p := node + Vector3(rng.randf_range(-JITTER, JITTER),
					rng.randf_range(-JITTER_Y, JITTER_Y),
					rng.randf_range(-JITTER, JITTER)) * _spacing
				if Vector2(p.x, p.z).length() > radius:
					continue
				if p.y < bottom or p.y > top_edge:
					continue
				# Отодвигаем от уже поставленных соседей по решётке.
				for dx in range(-1, 2):
					for dy in range(-1, 2):
						for dz in range(-1, 2):
							var key := Vector3i(i + dx, j + dy, k + dz)
							if not _node_index.has(key):
								continue
							var other: Vector3 = seeds[_node_index[key]]
							# Раздвигаем ТОЛЬКО в плане: подняв семя, мы вернули бы
							# ту самую пляску высот, из-за которой поверхность
							# идёт буграми.
							var away: Vector3 = p - other
							var far: float = away.length()
							if far > 0.0001 and far < gap:
								p = other + away / far * gap
				# Далеко от своего узла семя не уходит: разбиение решётки на
				# тетраэдры держится на том, что семя остаётся «своим» углом.
				var off: Vector3 = p - node
				var span: float = off.length()
				if span > _spacing * OFF_MAX:
					p = node + off / span * (_spacing * OFF_MAX)
				_node_index[Vector3i(i, j, k)] = seeds.size()
				seeds.append(p)
				# Узел решётки запоминаем: по нему размечается порода. Если
				# мерить по разбросанному семени, соседи случайно оказываются
				# по разные стороны поверхности и она идёт бородавками.
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


# Может ли у семени вообще быть ячейка — без вырезания.
func in_play(index: int) -> bool:
	return index >= 0 and index < _play.size() and _play[index] == 1


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


# --- Порода: ПОЛЕ ЗАПОЛНЕНИЯ -------------------------------------------------
# У каждого семени не «да/нет», а насколько вокруг него порода. Поверхность —
# уровень, на котором заполнение равно половине, и она проходит СКВОЗЬ ячейки
# на любой высоте. Пока почва была логической величиной, поверхность могла
# лечь только по границам ячеек, и её точность по вертикали навсегда равнялась
# размеру ячейки: отсюда были и бугры, и ступени.
const SOLID_AT: float = 0.5       # выше этого ячейка считается породой

func _fill_terrain(radius: float, top: float, bottom: float,
		shape: FastNoiseLite, detail: FastNoiseLite) -> void:
	solid = {}
	fill = PackedFloat32Array()
	fill.resize(seeds.size())
	for i in range(seeds.size()):
		if _play[i] == 0:
			continue
		var s: Vector3 = seeds[i]
		# Поверхность острова, его край и дно — три плавных ограничения.
		# Берём самое строгое; ничего не округляем по ячейкам, в этом весь смысл.
		var height: float = shape.get_noise_2d(s.x, s.z) * (top * 0.8) \
			+ detail.get_noise_2d(s.x, s.z) * (_spacing * 0.9)
		var edge := radius * (1.0 + 0.10 * shape.get_noise_2d(s.x * 2.0, s.z * 2.0))
		var under: float = (height - s.y) / _spacing
		var inside: float = (edge - Vector2(s.x, s.z).length()) / _spacing
		var over: float = (s.y - bottom) / _spacing
		# Соединяем ограничения МЯГКИМ минимумом. Обычный минимум даёт острое
		# ребро всюду, где два ограничения пересекаются: по кромке острова и
		# по низу склонов вырастали тонкие гребни-плавники. Мягкий скругляет
		# стык так же, как сложение мазков скругляет стык лепки.
		#
		# НЕ ОБРЕЗАЕМ значение. Величина показывает, насколько глубоко точка
		# внутри породы или далеко снаружи, и это важно: если всё, что над
		# землёй, свести к одному нулю, любая прибавка в воздухе сразу
		# подтянет его к половине и родит тонкую плёнку, оторванную от земли.
		# Именно так появлялись летающие куски и закрученные лоскуты.
		fill[i] = 0.5 + _smin(_smin(under, inside, 0.9), over, 0.9)
		if fill[i] > SOLID_AT:
			solid[i] = true
	base_fill = fill.duplicate()
	edits = {}
	cavity.resize(seeds.size())
	for i in range(seeds.size()):
		if _play[i] != 0:
			_refresh_cavity(i)
	_smooth_cavity()


# ВПАДИНА. Насколько ячейка сидит в складке: −1 на голом выступе, 0 на ровном,
# +1 в глубокой щели. Считается по перегибу поля — у впадины соседи в среднем
# полнее самой ячейки, у выступа беднее, и величина этой разницы говорит,
# насколько круто поверхность заворачивает.
#
# Это ловит сразу всё, что нужно окраске: щели между глыбами, складки огранки,
# стык насыпи с землёй и подножие камня. По этому числу шейдер темнит стыки,
# пускает зелень в трещины и целиком зарастает затенённые глыбы — до сих пор
# вместо него в поверхность клалась постоянная, и вся эта треть облика молча
# умножалась на ноль.
const CAVITY_GAIN: float = 2.6

func _refresh_cavity(index: int) -> void:
	if index < 0 or index >= cavity.size():
		return
	var node: Vector3i = node_of(index)
	var sum := 0.0
	var count := 0
	for step in NEIGHBOURS:
		var s: int = node_seed(node + step)
		if s < 0:
			continue
		sum += fill[s]
		count += 1
	if count == 0:
		cavity[index] = 0.0
		return
	cavity[index] = clampf((sum / float(count) - fill[index]) * CAVITY_GAIN, -1.0, 1.0)


# Наклон поля у семени. Та же величина, по которой `Surface.gd` берёт нормаль,
# — там она посчитана своей копией нарочно: это самое горячее место отрисовки,
# и вызов через ссылку стоил бы кадра. ПРАВИТЬ ОБЕ.
func field_slope(index: int) -> Vector3:
	var node: Vector3i = node_of(index)
	var here: Vector3 = seeds[index]
	var f0: float = fill[index]
	var g := Vector3.ZERO
	for step in NEIGHBOURS:
		var s: int = node_seed(node + step)
		if s < 0:
			continue
		var d: Vector3 = seeds[s] - here
		var len2: float = d.length_squared()
		if len2 > 0.000001:
			g += d * ((fill[s] - f0) / len2)
	return g


# ГДЕ РЯДОМ С ТОЧКОЙ ПРОХОДИТ ЗЕМЛЯ. Нужно всему, что на земле живёт: растение
# садится не в ячейку, а в точку, и точку эту надо посадить ровно на уровень.
#
# Поле у семени продолжаем его наклоном: до половинного уровня по прямой
# остаётся ровно (заполнение − половина), делённое на крутизну. Шага хватает
# двух — после первого точка уже у поверхности, второе семя её уточняет.
#
# Считаем ПОЛЕМ, а не лучом по телу столкновений: луч можно пускать только в
# такт физики, а рост растений идёт своим ходом и в проверке — вообще без окна.
func surface_near(p: Vector3) -> Dictionary:
	var at := p
	var j: int = -1
	for _step in range(3):
		j = cell_at(at)
		if j < 0 or not in_play(j):
			return {}
		var g: Vector3 = field_slope(j)
		var mag2: float = g.length_squared()
		if mag2 < 0.0000001:
			return {}
		var here: float = fill[j] + g.dot(at - seeds[j])
		# Шаг ОГРАНИЧЕН одной ячейкой. Наклон — это прямая, продолженная от
		# семени, и вдали от поверхности она врёт тем сильнее, чем дальше:
		# у обрыва она выбрасывала точку на другую сторону кромки или вовсе в
		# воздух. Короткими шагами приходим туда же, а мимо не улетаем.
		var move: Vector3 = -g * ((here - SOLID_AT) / mag2)
		var span: float = move.length()
		if span > _spacing:
			move *= _spacing / span
		at += move
	j = cell_at(at)
	if j < 0 or not in_play(j):
		return {}
	# ПРОВЕРЯЕМ, ЧТО ПРИШЛИ. Поле у семени продолжается прямой, и если точка
	# села далеко от него, значит прямую продолжили за пределы, где она верна:
	# такому месту верить нельзя, лучше признать, что земли рядом нет.
	if absf(fill[j] - SOLID_AT) > 0.5:
		return {}
	if at.distance_to(p) > _spacing * 1.5:
		return {}
	var n: Vector3 = field_slope(j)
	if n.length_squared() < 0.0000001:
		return {}
	return {"pos": at, "nrm": -n.normalized(), "cell": j}


# РАЗГЛАЖИВАЕМ ВПАДИНУ по соседям. Она считается вторым перегибом поля, а
# вторая разность у соседних семян скачет — семена разбросаны, и у одного из
# них соседи чуть ближе. Дальше это число идёт в порог, а порог превращает
# скачок между двумя вершинами в ПРЯМУЮ ЛИНИЮ поперёк треугольника: на камне
# вылезали резкие зелёные клинья по форме сетки.
#
# Сглаживание — единственное настоящее лекарство: подсовывать под порог ровную
# величину, а не подкрашивать последствия.
func _smooth_cavity(cells: Array = []) -> void:
	var soft := PackedFloat32Array()
	var which: Array = cells
	if which.is_empty():
		which = range(cavity.size())
	soft.resize(which.size())
	var at := 0
	for i in which:
		var node: Vector3i = node_of(i)
		var sum: float = cavity[i]
		var count := 1
		for step in NEIGHBOURS:
			var s: int = node_seed(node + step)
			if s < 0:
				continue
			sum += cavity[s]
			count += 1
		soft[at] = sum / float(count)
		at += 1
	at = 0
	for i in which:
		cavity[i] = soft[at]
		at += 1


func cavity_of(index: int) -> float:
	if index < 0 or index >= cavity.size():
		return 0.0
	return cavity[index]


# Мягкий минимум: там, где два ограничения близки, стык скругляется на `k`.
static func _smin(a: float, b: float, k: float) -> float:
	var h: float = clampf(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
	return lerpf(b, a, h) - k * h * (1.0 - h)


func fill_of(index: int) -> float:
	if index < 0 or index >= fill.size():
		return 0.0
	return fill[index]


# Правка игрока кладётся в поле НЕ единицей в одну ячейку, а плавным отпечатком:
# сама ячейка наполняется до края, соседи подтягиваются почти до половины.
#
# Без этого поставленный блок выходит восьмигранником с острыми углами (поле
# резко падает с единицы до нуля, и поверхность режется ровно посередине), а
# два блока по диагонали касаются лишь точкой — между ними остаётся просвет.
# С отпечатком поле меняется плавно, блоки сливаются, углы скругляются.
#
# Мазки СКЛАДЫВАЮТСЯ, а не объединяются. Это ключ к слиянию без шва: жёсткое
# объединение двух отпечатков всегда даёт складку на стыке, а сложение —
# плавную галтель, как у капель ртути. И вес считается по НАСТОЯЩЕМУ
# расстоянию, а не по числу шагов по решётке: иначе по диагонали куба отпечаток
# дотягивается дальше, чем по оси, и ком выпирает углами.
# Мазок кладётся В ТОЧКУ ПРИЦЕЛА, а не в ближайшее семя. Семена разбросаны,
# и ближайшее к курсору бывает заметно в стороне: мазок уходил не туда, куда
# наведено, и попасть в углубление было почти нельзя.
#
# Величина прибавки ОГРАНИЧЕНА. Без предела она росла от каждого повторного
# мазка, и поверхность переставала зависеть от величин — она прилипала к самим
# семенам, превращаясь в угловатое тело с остриями. Предел держит форму
# гладкой, а расти вверх заставляет двигать курсор, а не долбить в одну точку.
#
# ОГРАНИЧИВАЕМ МЯГКО, а не обрезкой. Обрезка ломает наклон ровно по тому
# контуру, где она включилась: внутри него поле стоит на месте, снаружи ещё
# растёт — и на стыке идёт ОСТРАЯ СКЛАДКА через всю насыпь. Пока мазок ставили
# щелчками, до предела доходили редко; с удержанием кнопки в него упираются за
# секунду, и складки полезли.
#
# Мягкое насыщение подходит к тому же потолку, но плавно: наклон нигде не
# рвётся, складке взяться неоткуда. В словаре при этом лежит НЕОБРЕЗАННЫЙ счёт —
# иначе отмена, вычитая своё, не вернула бы ровно то, что было.
const EDIT_CAP: float = 6.0

# Мягко и БЕЗ ИЗЛОМОВ ПО ВСЕЙ ДЛИНЕ. Отдельной ветки «вдали от потолка вернуть
# как есть» тут быть не должно: на её границе снова появится излом, только в
# другом месте. У малых величин `tanh` и так почти не гнёт — на единице разница
# в один процент.
func _edit_of(index: int) -> float:
	return EDIT_CAP * tanh(float(edits.get(index, 0.0)) / EDIT_CAP)
# Подтягивание к соседям — это диффузия: она разглаживает не только сам мазок,
# но и всё, что уже вылеплено рядом. При большой силе мазок возле холма
# подъедал холм. Держим её слабой: острия она снимает и такой, а форму,
# сделанную руками, почти не трогает.
const RELAX: float = 0.09
# Насколько каменистость может уйти за свои границы. Запас нужен, чтобы отмена
# была точной; наружу всё равно отдаётся доля от нуля до единицы.
# Запас БОЛЬШОЙ. Он не косметический: у обрезки нет обратного хода, и стоит
# счёту упереться в потолок, как отмена мазка перестаёт возвращать ровно то,
# что было. Четырёх не хватало — три мазка камня подряд уже упирались.
const STONE_ROOM: float = 24.0


# Доля породы у ячейки: ноль — земля, единица — скала. Читать каменистость
# ТОЛЬКО отсюда: в самом словаре лежит необрезанный счёт мазков.
func stone_of(index: int) -> float:
	return clampf(float(stone.get(index, 0.0)), 0.0, 1.0)


# Для проверок: во что обходится ячейке огранка и насколько круто она стоит.
func facet_of(index: int) -> float:
	return _facet(index)


func steepness_of(index: int) -> float:
	return _steepness(index)


# `stone_push` — куда мазок ведёт каменистость: +1 прибавляет камня, −1 уводит
# в землю. Знак задаёт вызывающий, а не выводится из знака мазка: снятие всегда
# уводит камень прочь, а отмена обязана вернуть ровно то, что было, — для этого
# она повторяет мазок с обратным знаком по ОБЕИМ величинам.
func stroke_at(point: Vector3, radius: float, amount: float,
		stone_push: float = 0.0) -> Array:
	var touched: Dictionary = {}
	var span := int(ceil(radius / _cell_size)) + 1
	var base := _key_of(point)
	for dx in range(-span, span + 1):
		for dy in range(-span, span + 1):
			for dz in range(-span, span + 1):
				var key := base + Vector3i(dx, dy, dz)
				if not _seed_hash.has(key):
					continue
				for j in _seed_hash[key]:
					var d: float = seeds[j].distance_to(point) / radius
					if d >= 1.0:
						continue
					var w: float = 1.0 - d * d
					edits[j] = float(edits.get(j, 0.0)) + amount * w * w
					# Каменистость кладётся тем же мазком, поэтому меняется
					# плавно: у камня нет резкой границы, он сходит на нет.
					#
					# Каменистость идёт ПО ТОМУ ЖЕ ПРОФИЛЮ, что и прибавка
					# высоты. Пока она расходилась шире массы, серое ложилось
					# на ровное место вокруг глыбы: выходило «покрашено камнем»,
					# а не «лежит камень». Множитель лишь ускоряет насыщение
					# у сердцевины.
					#
					# Величину держим НЕОБРЕЗАННОЙ, обрезаем только при чтении.
					# Обрезка на месте необратима: два мазка камня подряд упёрлись
					# бы в единицу, и отмена одного из них стёрла бы оба. Теперь
					# каменистость — счёт положенного, а не сама доля.
					if stone_push != 0.0:
						stone[j] = clampf(float(stone.get(j, 0.0))
							+ stone_push * absf(amount) * w * w * 1.9,
							-STONE_ROOM, STONE_ROOM)
					touched[j] = true

	# Сглаживаем не только сам мазок, но и КОЛЬЦО вокруг него. Пока сглаживание
	# шло лишь по задетым ячейкам, соседи за краем мазка не менялись никогда:
	# на границе копился уступ, и от повторных наращиваний холм набирал
	# угловатость. С кольцом мазок растушёвывается в окружающий рельеф.
	# Кольцо берём узкое — только шесть прямых соседей. По всем двадцати шести
	# диффузия расползалась заметно дальше мазка и подъедала соседние формы.
	var zone: Dictionary = touched.duplicate()
	for j in touched:
		var node: Vector3i = node_of(j)
		for step in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
				Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			var n: int = node_seed(node + step)
			if n >= 0:
				zone[n] = true

	for _pass in range(1):
		var mixed: Dictionary = {}
		for j in zone:
			var node2: Vector3i = node_of(j)
			var sum := 0.0
			var count := 0
			for step in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
					Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
				var n2: int = node_seed(node2 + step)
				if n2 < 0:
					continue
				sum += float(edits.get(n2, 0.0))
				count += 1
			if count > 0:
				# Камень ДЕРЖИТ ФОРМУ: к соседям он подтягивается впятеро
				# слабее земли, поэтому граница глыбы с травой остаётся чёткой,
				# а не расплывается, как насыпь.
				var soft: float = lerpf(RELAX, RELAX * 0.2, stone_of(j))
				mixed[j] = lerpf(float(edits.get(j, 0.0)), sum / float(count), soft)
		for j in mixed:
			edits[j] = mixed[j]

	for j in zone:
		if absf(float(edits.get(j, 0.0))) < 0.002:
			edits.erase(j)
		# Огранка прибавляется ЗДЕСЬ, на живом пути лепки. Раньше она жила в
		# пересчёте по ядру, которого никто не звал, и до картинки не доходила:
		# камень отличался от земли одним цветом.
		fill[j] = base_fill[j] + _edit_of(j) + _facet(j)

	# Впадину пересчитываем ШИРЕ мазка: она смотрит на соседей, и у ячейки за
	# краем зоны сосед только что изменился. Наружу отдаём всё равно саму зону —
	# ячейки за её краем не поменяли ни породы, ни вида, только затенение стыка.
	var seen: Dictionary = zone.duplicate()
	for j in zone:
		var node3: Vector3i = node_of(j)
		for step in NEIGHBOURS:
			var n3: int = node_seed(node3 + step)
			if n3 >= 0:
				seen[n3] = true
	for j in seen:
		_refresh_cavity(j)
	_smooth_cavity(seen.keys())
	return zone.keys()


# РАЗМЫВАНИЕ. Кисть, которая ничего не прибавляет и не убавляет, а СГЛАЖИВАЕТ:
# каждая ячейка подтягивается к среднему по своим соседям. Ею снимают уступы,
# заглаживают стык двух насыпей и растушёвывают склон — то, чего мазком не
# сделать, потому что мазок всегда что-то кладёт.
#
# Правка ложится в те же `edits`, что и лепка, поэтому размывание работает и по
# природному рельефу, и по вылепленному. Но обратить его нельзя вычислением:
# сколько снялось, зависит от того, что было вокруг. Поэтому наружу отдаётся
# СПИСОК ПРИБАВОК — по нему отмена возвращает всё в точности.
func blur_at(point: Vector3, radius: float, strength: float) -> Dictionary:
	var inside: Dictionary = {}
	var span := int(ceil(radius / _cell_size)) + 1
	var base := _key_of(point)
	for dx in range(-span, span + 1):
		for dy in range(-span, span + 1):
			for dz in range(-span, span + 1):
				var key := base + Vector3i(dx, dy, dz)
				if not _seed_hash.has(key):
					continue
				for j in _seed_hash[key]:
					var d: float = seeds[j].distance_to(point) / radius
					if d >= 1.0:
						continue
					inside[j] = (1.0 - d * d) * (1.0 - d * d)

	# Среднее считаем ПО ИСХОДНОМУ полю, до правок: если менять на ходу, ячейки
	# в начале списка сглаживаются по уже сглаженным соседям, и кисть тянет
	# рельеф в сторону обхода.
	var delta: Dictionary = {}
	for j in inside:
		var node: Vector3i = node_of(j)
		var sum := 0.0
		var count := 0
		for step in NEIGHBOURS:
			var n: int = node_seed(node + step)
			if n < 0:
				continue
			sum += fill[n]
			count += 1
		if count == 0:
			continue
		var want: float = sum / float(count) - fill[j]
		var add: float = want * strength * float(inside[j])
		if absf(add) > 0.0005:
			delta[j] = add

	apply_delta(delta, 1.0)
	return delta


# Прибавляет к правкам готовый список — им ходят и размывание, и его отмена
# (с обратным знаком).
func apply_delta(delta: Dictionary, sign: float) -> Array:
	var zone: Dictionary = {}
	for j in delta:
		edits[j] = float(edits.get(j, 0.0)) + float(delta[j]) * sign
		if absf(float(edits[j])) < 0.002:
			edits.erase(j)
		zone[j] = true
	for j in zone:
		fill[j] = base_fill[j] + _edit_of(j) + _facet(j)
	var seen: Dictionary = zone.duplicate()
	for j in zone:
		var node: Vector3i = node_of(j)
		for step in NEIGHBOURS:
			var n: int = node_seed(node + step)
			if n >= 0:
				seen[n] = true
	for j in seen:
		_refresh_cavity(j)
	_smooth_cavity(seen.keys())
	return zone.keys()


# ОГРАНЁННОСТЬ КАМНЯ. К полю возле камня добавляется крупный шум: поверхность
# набирает широкие плосковатые грани и складки, как у окатанных глыб на
# снимках. Шипов от этого быть не может — это плавная величина, а не отдельные
# тела; резкость даёт только частота, и она нарочно низкая.
#
# Облик зависит от МЕСТА:
#   больше камня в кучке — сильнее гранёность (одинокий валун окатан, массив
#     набирает уступы);
#   выше над морем — крупнее и жёстче грани (внизу мягкие спины, наверху плиты);
#   круче склон — резче выступает (на пологом глыба тонет в дёрне).
#
# Величина мала не случайно. Сдвиг поля на единицу двигает поверхность примерно
# на шаг решётки, то есть почти на два метра: столько «шума» оторвало бы от
# глыбы куски и разбросало их вокруг. Грани должны читаться уступами, а не
# перекраивать тело.
const FACET_AMP: float = 1.10

func _facet(index: int) -> float:
	var s: float = stone_of(index)
	if s < 0.02 or _rock_noise == null:
		return 0.0
	var p: Vector3 = seeds[index]
	var high: float = clampf((p.y + 3.0) / 6.0, 0.0, 1.0)
	var coarse: float = 0.55 + 0.45 * high
	var n1: float = _rock_noise.get_noise_3d(p.x / coarse, p.y / coarse, p.z / coarse)
	var n2: float = _rock_noise.get_noise_3d(p.x * 2.3, p.y * 2.3, p.z * 2.3)
	var n: float = n1 * 0.75 + n2 * 0.25
	# СТУПЕНЬКИ. Ровный шум даёт мягкую волну — камень от земли не отличить.
	# Подтягивая значение к ближайшей ступени, получаем широкие плоские грани,
	# разделённые складками: это и есть облик окатанной глыбы. Рёбра остаются
	# округлыми, потому что подтягиваем лишь частично, а не защёлкиваем.
	#
	# Ступень берём СГЛАЖЕННУЮ, а не округлением. У округления наклон на границе
	# ступени рвётся, и по этому месту через всю глыбу идёт острая складка —
	# ровно та, что вылезала при лепке. Здесь плато остаются плоскими, а переход
	# между ними имеет нулевой наклон с обоих концов: грань есть, лезвия нет.
	var steps := 2.5
	var q: float = n * steps
	var base: float = floor(q)
	var frac: float = q - base
	n = lerpf(n, (base + smoothstep(0.30, 0.70, frac)) / steps, 0.65)
	var steep: float = _steepness(index)
	var out: float = n * s * s * (0.55 + 0.75 * high) * (0.45 + 1.05 * steep) * FACET_AMP
	if out > 0.0:
		# ПРИБАВЛЯТЬ ПОРОДУ МОЖНО ТОЛЬКО ТАМ, ГДЕ ОНА УЖЕ ЕСТЬ. Огранка — это
		# прибавка к полю, и в пустом месте рядом с глыбой она поднимает его
		# выше уровня: от тела отрастает тонкая плита, висящая в воздухе. Их и
		# видно было отдельными лоскутами у подножия.
		#
		# Убавлять — можно где угодно: выемка в пустоте ничего не создаёт.
		var body: float = base_fill[index] + _edit_of(index)
		out *= clampf((body - (SOLID_AT - 1.0)) / 0.9, 0.0, 1.0)
	return out


# Насколько круто стоит поверхность у этой ячейки: 0 — плоско, 1 — отвесно.
#
# Считаем по полю БЕЗ огранки. По готовому полю нельзя: огранка тогда кормит
# сама себя — где она задрала склон, наклон становится круче, огранка ещё
# сильнее, и камень идёт шипами.
func _steepness(index: int) -> float:
	var node: Vector3i = node_of(index)
	var here: Vector3 = seeds[index]
	var f0: float = base_fill[index] + _edit_of(index)
	var g := Vector3.ZERO
	for step in NEIGHBOURS:
		var s: int = node_seed(node + step)
		if s < 0:
			continue
		var d: Vector3 = seeds[s] - here
		var len2: float = d.length_squared()
		if len2 > 0.000001:
			g += d * ((base_fill[s] + _edit_of(s) - f0) / len2)
	var mag: float = g.length()
	if mag < 0.000001:
		return 0.0
	return clampf(1.0 - absf(g.y) / mag, 0.0, 1.0)


# Семя по узлу решётки — по этому строится разбиение на тетраэдры.
func node_seed(node: Vector3i) -> int:
	return int(_node_index.get(node, -1))


func node_of(index: int) -> Vector3i:
	var p: Vector3 = lattice[index] / _spacing
	return Vector3i(int(round(p.x)), int(round(p.y)), int(round(p.z)))


func spacing() -> float:
	return _spacing


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
