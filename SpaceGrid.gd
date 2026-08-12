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
var fill: PackedFloat32Array = PackedFloat32Array()       # насколько ячейка полна
var base_fill: PackedFloat32Array = PackedFloat32Array()  # природный рельеф
var edits: Dictionary = {}        # ячейка -> +1 поставлено, -1 снято
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
const OFF_MAX: float = 0.46       # дальше этого семя от своего узла не уходит

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
const EDIT_R: float = 1.25        # радиус мазка в шагах решётки
const EDIT_SPAN: int = 2          # столько узлов решётки он захватывает

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
# Предел большой: он страхует от совсем уж дикого перепада, но не мешает
# копать и насыпать. От остриёв спасает не он, а подтягивание к соседям —
# оно срезает резкие перепады и почти не трогает уже гладкую форму, поэтому
# лепить можно сколько угодно, а угловатости не набирается.
const EDIT_CAP: float = 6.0
const RELAX: float = 0.34         # насколько ячейка подтягивается к соседям

func stroke_at(point: Vector3, radius: float, amount: float) -> Array:
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
					edits[j] = clampf(float(edits.get(j, 0.0)) + amount * w * w,
						-EDIT_CAP, EDIT_CAP)
					touched[j] = true

	# Сглаживаем не только сам мазок, но и КОЛЬЦО вокруг него. Пока сглаживание
	# шло лишь по задетым ячейкам, соседи за краем мазка не менялись никогда:
	# на границе копился уступ, и от повторных наращиваний холм набирал
	# угловатость. С кольцом мазок растушёвывается в окружающий рельеф.
	var zone: Dictionary = touched.duplicate()
	for j in touched:
		var node: Vector3i = node_of(j)
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var n: int = node_seed(node + Vector3i(dx, dy, dz))
					if n >= 0:
						zone[n] = true

	for _pass in range(2):
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
				mixed[j] = lerpf(float(edits.get(j, 0.0)), sum / float(count), RELAX)
		for j in mixed:
			edits[j] = mixed[j]

	for j in zone:
		if absf(float(edits.get(j, 0.0))) < 0.002:
			edits.erase(j)
			fill[j] = base_fill[j]
		else:
			fill[j] = base_fill[j] + float(edits[j])
	return zone.keys()


func stroke_many(cells: Array, amount: float) -> Array:
	for c in cells:
		if c >= 0 and c < fill.size():
			edits[c] = float(edits.get(c, 0.0)) + amount
			if absf(float(edits[c])) < 0.001:
				edits.erase(c)
	# Пересчитываем разом всю задетую округу: у мазка кистью области соседей
	# перекрываются, и по отдельности это была бы та же работа десять раз.
	var touched: Dictionary = {}
	for c in cells:
		if c < 0:
			continue
		var node: Vector3i = node_of(c)
		for dx in range(-EDIT_SPAN, EDIT_SPAN + 1):
			for dy in range(-EDIT_SPAN, EDIT_SPAN + 1):
				for dz in range(-EDIT_SPAN, EDIT_SPAN + 1):
					var j: int = node_seed(node + Vector3i(dx, dy, dz))
					if j >= 0:
						touched[j] = true
	for j in touched:
		_refresh_fill(j)
	return touched.keys()


# Заполнение ячейки = природный рельеф плюс сумма мазков вокруг. Считается
# заново от исходных данных, поэтому отмена возвращает поверхность точно.
func _refresh_fill(index: int) -> void:
	var here: Vector3 = seeds[index]
	var node: Vector3i = node_of(index)
	var sum := 0.0
	for dx in range(-EDIT_SPAN, EDIT_SPAN + 1):
		for dy in range(-EDIT_SPAN, EDIT_SPAN + 1):
			for dz in range(-EDIT_SPAN, EDIT_SPAN + 1):
				var j: int = node_seed(node + Vector3i(dx, dy, dz))
				if j < 0 or not edits.has(j):
					continue
				var d: float = here.distance_to(seeds[j]) / _spacing
				if d >= EDIT_R:
					continue
				var t: float = 1.0 - (d / EDIT_R) * (d / EDIT_R)
				sum += float(edits[j]) * t * t
	# Тоже без обрезки: мазок сдвигает поверхность ровно на свою величину, и
	# насыпь растёт от земли, а не всплывает отдельной коркой рядом с ней.
	fill[index] = base_fill[index] + sum


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
