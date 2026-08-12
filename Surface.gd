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

	# Куда смотреть лицом: от заполненного к пустому.
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
	var want: Vector3 = (empty_mid / float(n_out) - solid_mid / float(n_in)).normalized()
	_face(st, poly, want, grid, stone_of)
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
					var keys: Array = []
					for c in poly:
						keys.append(Vector2i(mini(int(c["a"]), int(c["b"])),
							maxi(int(c["a"]), int(c["b"]))))
					for f in range(1, keys.size() - 1):
						for pair in [[0, f], [f, f + 1], [f + 1, 0]]:
							var u: Vector2i = keys[pair[0]]
							var v: Vector2i = keys[pair[1]]
							if u == v:
								continue          # вырожденное ребро
							var key := [u, v] if _before(u, v) else [v, u]
							var s2 := "%d,%d|%d,%d" % [key[0].x, key[0].y, key[1].x, key[1].y]
							edges[s2] = int(edges.get(s2, 0)) + 1


static func _before(a: Vector2i, b: Vector2i) -> bool:
	return a.x < b.x or (a.x == b.x and a.y < b.y)


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
		var tri: Array = [cut[0], cut[i], cut[i + 1]]
		var slopes: Array = []
		var out := Vector3.ZERO
		for c in tri:
			var s: Vector3 = _slope(grid, c)
			slopes.append(s)
			out += s
		# Наружу — по наклону поля в вершинах; он всегда осмыслен у поверхности.
		# Если вдруг выродился, берём запасное направление от породы к пустоте.
		if out.length() < 0.0001:
			out = want
		else:
			out = out.normalized()

		var a: Vector3 = tri[0]["p"]
		var b: Vector3 = tri[1]["p"]
		var c2: Vector3 = tri[2]["p"]
		var face_n: Vector3 = (b - a).cross(c2 - a)
		if face_n.length() < 0.0000000001:
			continue                      # выродившийся треугольник
		# В Godot лицевая сторона — обход ПО ЧАСОВОЙ снаружи.
		if face_n.dot(out) > 0.0:
			tri.reverse()
			slopes.reverse()

		for k in range(3):
			var cc: Dictionary = tri[k]
			var stone: float = lerpf(float(stone_of.call(int(cc["a"]))),
				float(stone_of.call(int(cc["b"]))), float(cc["t"]))
			st.set_uv(Vector2(stone, 0.5))
			st.set_normal(slopes[k])
			st.add_vertex(cc["p"])


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
