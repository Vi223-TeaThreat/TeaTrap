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


static func _emit_tet(st: SurfaceTool, grid, idx: PackedInt32Array,
		val: PackedFloat32Array, t: Array, stone_of: Callable) -> bool:
	var inside: Array = []
	var outside: Array = []
	for c in t:
		if val[c] > ISO:
			inside.append(c)
		else:
			outside.append(c)
	if inside.is_empty() or outside.is_empty():
		return false

	var pts: Array = []
	# Точки среза лежат на рёбрах «изнутри наружу».
	for a in inside:
		for b in outside:
			pts.append(_cut(grid, idx, val, a, b))
	if pts.size() < 3:
		return false

	# Куда смотреть лицом: от заполненного к пустому.
	var solid_mid := Vector3.ZERO
	for a in inside:
		solid_mid += grid.seeds[idx[a]]
	solid_mid /= float(inside.size())
	var empty_mid := Vector3.ZERO
	for b in outside:
		empty_mid += grid.seeds[idx[b]]
	empty_mid /= float(outside.size())
	var want: Vector3 = (empty_mid - solid_mid).normalized()

	if pts.size() == 3:
		_face(st, [pts[0], pts[1], pts[2]], want, grid, stone_of)
	else:
		# Четыре точки: два ребра от каждого заполненного угла. Порядок
		# 0,1,3,2 замыкает их в четырёхугольник без самопересечения.
		_face(st, [pts[0], pts[1], pts[3], pts[2]], want, grid, stone_of)
	return true


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


static func _face(st: SurfaceTool, cut: Array, want: Vector3, grid,
		stone_of: Callable) -> void:
	var seq: Array = cut.duplicate()
	# В Godot лицевая сторона — обход ПО ЧАСОВОЙ снаружи.
	var n := Vector3.ZERO
	var m := seq.size()
	for i in range(m):
		var a: Vector3 = seq[i]["p"]
		var b: Vector3 = seq[(i + 1) % m]["p"]
		n.x += (a.y - b.y) * (a.z + b.z)
		n.y += (a.z - b.z) * (a.x + b.x)
		n.z += (a.x - b.x) * (a.y + b.y)
	if n.length() < 0.0000001:
		return
	if n.normalized().dot(want) > 0.0:
		seq.reverse()

	for i in range(1, seq.size() - 1):
		for c in [seq[0], seq[i], seq[i + 1]]:
			var stone: float = lerpf(float(stone_of.call(int(c["a"]))),
				float(stone_of.call(int(c["b"]))), float(c["t"]))
			st.set_uv(Vector2(stone, 0.5))
			st.set_normal(_slope(grid, c))
			st.add_vertex(c["p"])


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
