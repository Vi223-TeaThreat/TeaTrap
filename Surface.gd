extends RefCounted
# =============================================================================
#  ПОВЕРХНОСТЬ ПО УРОВНЮ ЗАПОЛНЕНИЯ.
#
#  Раньше поверхностью была граница ячеек: грани многогранников между породой
#  и пустотой. У такой поверхности точность по вертикали навсегда равна размеру
#  ячейки — отсюда были и бугры, и ступени, сколько их ни сглаживай.
#
#  Теперь у каждого семени есть ЗАПОЛНЕНИЕ, и поверхность — это уровень, где
#  оно равно половине. Проходит она сквозь ячейки на любой высоте.
#
#  КАК СТРОИМ. Семена сидят на решётке, поэтому восемь соседних семян образуют
#  косой кубик, а он делится на шесть тетраэдров. В каждом тетраэдре смотрим,
#  у каких углов заполнение выше половины: если у всех или ни у кого — грани
#  нет; иначе она отсекает от тетраэдра треугольник или четырёхугольник. Точку
#  на ребре берём по пропорции — отсюда и берётся плавность.
#
#  Швов между кусками не бывает по построению: точка на ребре считается по
#  одной и той же пропорции с обеих сторон. Нормаль берём не от треугольника,
#  а от НАКЛОНА ПОЛЯ в вершине — тогда и освещение сходится через границу
#  куска, и поверхность выглядит гладкой без всякого сглаживания.
#
#  Разбиение кубика на шесть тетраэдров одинаково у соседних кубиков, поэтому
#  общие грани у них совпадают и дыр не остаётся.
# =============================================================================

const ISO: float = 0.5

# Шесть тетраэдров косого кубика. Углы пронумерованы битами: 1 — сдвиг по x,
# 2 — по y, 4 — по z. Все шесть содержат ребро 0-7, поэтому разбиение
# согласовано с соседними кубиками.
const TETS := [
	[0, 7, 1, 3], [0, 7, 3, 2], [0, 7, 2, 6],
	[0, 7, 6, 4], [0, 7, 4, 5], [0, 7, 5, 1],
]

const CORNER := [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0),
	Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(0, 1, 1), Vector3i(1, 1, 1),
]


# Собирает кусок поверхности по кубикам решётки в заданных пределах.
# `grid` — сетка, `lo`/`hi` — углы области в узлах решётки.
# `stone_of` — доля породы у семени (0 земля, 1 скала), для раскраски.
static func build(grid, lo: Vector3i, hi: Vector3i, stone_of: Callable) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false

	var idx := PackedInt32Array()
	idx.resize(8)
	var val := PackedFloat32Array()
	val.resize(8)

	for i in range(lo.x, hi.x):
		for j in range(lo.y, hi.y):
			for k in range(lo.z, hi.z):
				var here := Vector3i(i, j, k)
				var ok := true
				var below := 0
				for c in range(8):
					var s: int = grid.node_seed(here + CORNER[c])
					if s < 0:
						ok = false
						break
					idx[c] = s
					val[c] = grid.fill[s]
					if val[c] <= ISO:
						below += 1
				if not ok or below == 0 or below == 8:
					continue
				for t in TETS:
					if _emit_tet(st, grid, idx, val, t, stone_of):
						any = true

	if not any:
		return null
	return st.commit()


# Многоугольник среза тетраэдра, уже в правильном порядке обхода. Отдельно от
# отрисовки, чтобы проверка на дыры считала РОВНО ту же геометрию, а не свою
# копию: разошедшаяся копия врала бы про целостность.
static func tet_polygon(grid, idx: PackedInt32Array, val: PackedFloat32Array,
		t: Array) -> Array:
	var inside: Array = []
	var outside: Array = []
	for c in t:
		if val[c] > ISO:
			inside.append(c)
		else:
			outside.append(c)
	if inside.is_empty() or outside.is_empty():
		return []

	var pts: Array = []
	# Точки среза лежат на рёбрах «изнутри наружу».
	for a in inside:
		for b in outside:
			pts.append(_cut(grid, idx, val, a, b))
	if pts.size() < 3:
		return []
	if pts.size() == 3:
		return pts
	# Четыре точки: два ребра от каждого заполненного угла. Порядок 0,1,3,2
	# замыкает их в четырёхугольник без самопересечения.
	return [pts[0], pts[1], pts[3], pts[2]]


static func _emit_tet(st: SurfaceTool, grid, idx: PackedInt32Array,
		val: PackedFloat32Array, t: Array, stone_of: Callable) -> bool:
	var poly: Array = tet_polygon(grid, idx, val, t)
	if poly.is_empty():
		return false

	_face(st, poly, _outward(grid, idx, val, t), grid, stone_of)
	return true


# Ищем ДЫРЫ. У замкнутой поверхности каждое ребро принадлежит ровно двум
# треугольникам; ребро с одним — это край дыры. Точку среза узнаём по паре
# семян, на ребре между которыми она лежит: такой ключ одинаков у всех
# тетраэдров и кубиков, которые её породили.
static func audit(grid, lo: Vector3i, hi: Vector3i, edges: Dictionary) -> void:
	var idx := PackedInt32Array()
	idx.resize(8)
	var val := PackedFloat32Array()
	val.resize(8)
	for i in range(lo.x, hi.x):
		for j in range(lo.y, hi.y):
			for k in range(lo.z, hi.z):
				var here := Vector3i(i, j, k)
				var ok := true
				var below := 0
				for c in range(8):
					var s: int = grid.node_seed(here + CORNER[c])
					if s < 0:
						ok = false
						break
					idx[c] = s
					val[c] = grid.fill[s]
					if val[c] <= ISO:
						below += 1
				if not ok or below == 0 or below == 8:
					continue
				for t in TETS:
					var poly: Array = tet_polygon(grid, idx, val, t)
					if poly.is_empty():
						continue
					var want: Vector3 = _outward(grid, idx, val, t)
					for f in range(1, poly.size() - 1):
						var tri: Array = wound([poly[0], poly[f], poly[f + 1]], grid, want)
						if tri.is_empty():
							continue
						# Пишем НАПРАВЛЕННЫЕ рёбра. У согласованной поверхности
						# каждое направленное ребро встречается ровно один раз:
						# соседние треугольники проходят общее ребро навстречу
						# друг другу. Встретилось дважды — треугольник вывернут.
						for pair in [[0, 1], [1, 2], [2, 0]]:
							var u := _vkey(tri[pair[0]])
							var v := _vkey(tri[pair[1]])
							if u == v:
								continue
							var s2 := "%s>%s" % [u, v]
							edges[s2] = int(edges.get(s2, 0)) + 1


static func _vkey(c: Dictionary) -> String:
	return "%d.%d" % [mini(int(c["a"]), int(c["b"])), maxi(int(c["a"]), int(c["b"]))]


static func _outward(grid, idx: PackedInt32Array, val: PackedFloat32Array,
		t: Array) -> Vector3:
	var solid_mid := Vector3.ZERO
	var empty_mid := Vector3.ZERO
	var n_in := 0
	var n_out := 0
	for c in t:
		if val[c] > ISO:
			solid_mid += grid.seeds[idx[c]]
			n_in += 1
		else:
			empty_mid += grid.seeds[idx[c]]
			n_out += 1
	if n_in == 0 or n_out == 0:
		return Vector3.UP
	return (empty_mid / float(n_out) - solid_mid / float(n_in)).normalized()


# Точка на ребре и всё, что к ней прилагается: наклон поля и доля породы.
static func _cut(grid, idx: PackedInt32Array, val: PackedFloat32Array,
		a: int, b: int) -> Dictionary:
	var fa: float = val[a]
	var fb: float = val[b]
	var span: float = fa - fb
	var t: float = 0.5 if absf(span) < 0.00001 else clampf((fa - ISO) / span, 0.0, 1.0)
	var sa: int = idx[a]
	var sb: int = idx[b]
	return {
		"p": grid.seeds[sa].lerp(grid.seeds[sb], t),
		"a": sa, "b": sb, "t": t,
	}


# Сторону определяем У КАЖДОГО ТРЕУГОЛЬНИКА ОТДЕЛЬНО, а не на весь
# многоугольник сразу. Четырёхугольник среза в тетраэдре почти всегда неплоский,
# и при общем решении один из двух его треугольников оказывался вывернутым.
# Вывернутый треугольник не рисуется со своей стороны — сквозь него видно небо,
# и это неотличимо от дыры с прямыми краями. Сетка при этом остаётся замкнутой,
# поэтому поиск незамкнутых рёбер таких мест не находит.
static func _face(st: SurfaceTool, cut: Array, want: Vector3, grid,
		stone_of: Callable) -> void:
	for i in range(1, cut.size() - 1):
		var tri: Array = wound([cut[0], cut[i], cut[i + 1]], grid, want)
		if tri.is_empty():
			continue
		for cc in tri:
			var stone: float = lerpf(float(stone_of.call(int(cc["a"]))),
				float(stone_of.call(int(cc["b"]))), float(cc["t"]))
			st.set_uv(Vector2(stone, 0.5))
			st.set_normal(_slope(grid, cc))
			st.add_vertex(cc["p"])


# Разворачиваем треугольник лицом наружу. ЕДИНСТВЕННОЕ место, где решается
# сторона, — и отрисовка, и проверка целостности ходят через него.
#
# Наружу смотрим по направлению от заполненных углов тетраэдра к пустым.
# Наклон поля для этого не годится: там, где поле упирается в предел и
# становится плоским, наклон вырождается и может указать не туда — тогда
# треугольник выворачивается, перестаёт рисоваться со своей стороны, и сквозь
# него видно небо. Это неотличимо от дыры, хотя сетка остаётся замкнутой.
static func wound(tri: Array, grid, want: Vector3) -> Array:
	var a: Vector3 = tri[0]["p"]
	var b: Vector3 = tri[1]["p"]
	var c: Vector3 = tri[2]["p"]
	var face_n: Vector3 = (b - a).cross(c - a)
	# Порог только против полного вырождения. Отбрасывать «волоски» по
	# относительному порогу пробовали — вместо ста вывернутых треугольников
	# получилось семьсот незамкнутых рёбер: щели оказались настоящими дырами.
	if face_n.length() < 0.000000001:
		return []
	# В Godot лицевая сторона — обход ПО ЧАСОВОЙ снаружи.
	if face_n.dot(want) > 0.0:
		return [tri[2], tri[1], tri[0]]
	return tri


# Нормаль берём от НАКЛОНА ПОЛЯ, а не от треугольника: она непрерывна и
# одинакова с обеих сторон границы куска, поэтому шва не возникает и
# поверхность выглядит гладкой без отдельного сглаживания.
static func _slope(grid, c: Dictionary) -> Vector3:
	var ga := _gradient(grid, int(c["a"]))
	var gb := _gradient(grid, int(c["b"]))
	var g: Vector3 = ga.lerp(gb, float(c["t"]))
	if g.length() < 0.000001:
		return (grid.seeds[int(c["b"])] - grid.seeds[int(c["a"])]).normalized()
	return -g.normalized()


static func _gradient(grid, seed_index: int) -> Vector3:
	var node: Vector3i = grid.node_of(seed_index)
	var here: Vector3 = grid.seeds[seed_index]
	var f0: float = grid.fill[seed_index]
	var g := Vector3.ZERO
	for step in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
			Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		var s: int = grid.node_seed(node + step)
		if s < 0:
			continue
		var d: Vector3 = grid.seeds[s] - here
		var len2: float = d.length_squared()
		if len2 > 0.000001:
			g += d * ((grid.fill[s] - f0) / len2)
	return g
