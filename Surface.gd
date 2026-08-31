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

# Насколько камень освещается по граням, а не по гладкому полю: 0 — как земля,
# 1 — чистый многогранник.
#
# ДЕРЖАТЬ МАЛЫМ. При единице видно КАЖДЫЙ треугольник решётки, а они мелкие и
# неправильные — глыба рассыпается в калейдоскоп из чешуек. На снимках камень
# наоборот цельный: широкие грани со скруглёнными рёбрами, а структуру дают не
# грани, а тонкие тёмные трещины. Здесь остаётся ровно столько, чтобы крупные
# плоскости от огранки читались чуть твёрже, чем дёрн.
#
# ДЕРЖИМ ПЕРЕМЕННОЙ, А НЕ ПОСТОЯННОЙ — ради режима `--plain`. Он снимает с
# поверхности всё, что не форма, и свет по граням снимать надо тоже: иначе на
# «голом» кадре останутся плоские пятна от него самого, и по нему нельзя будет
# судить, кривит ли сама поверхность.
static var face_light: float = 0.2

const CORNER := [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0),
	Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(0, 1, 1), Vector3i(1, 1, 1),
]


# Собирает кусок поверхности по кубикам решётки в заданных пределах.
# `grid` — сетка, `lo`/`hi` — углы области в узлах решётки.
#
# Породу и впадину берём У САМОЙ СЕТКИ, без посредника. Раньше долю породы
# приносил переданный сюда вызов, и на каждую вершину приходилось по два таких
# обращения; вершин у куска тысячи, и один клик стоил тридцати семи миллисекунд
# вместо трёх. Отклик здесь дороже красоты устройства.
static func build(grid, lo: Vector3i, hi: Vector3i) -> ArrayMesh:
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
					if _emit_tet(st, grid, idx, val, t):
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
		val: PackedFloat32Array, t: Array) -> bool:
	var poly: Array = tet_polygon(grid, idx, val, t)
	if poly.is_empty():
		return false

	_face(st, poly, _outward(grid, idx, val, t), grid)
	return true


# Ищем ДЫРЫ. У замкнутой поверхности каждое ребро принадлежит ровно двум
# треугольникам; ребро с одним — это край дыры. Точку среза узнаём по паре
# семян, на ребре между которыми она лежит: такой ключ одинаков у всех
# тетраэдров и кубиков, которые её породили.
static func audit(grid, lo: Vector3i, hi: Vector3i, edges: Dictionary,
		stats: Dictionary) -> void:
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
					# Не вывернулся ли сам тетраэдр. Семя уходит от своего узла
					# почти на половину ячейки, и при неудачном совпадении
					# четвёрка семян меняет ориентацию: тетраэдры начинают
					# перекрываться, и срез в них смотрит не туда.
					if _volume(grid.seeds[idx[t[0]]], grid.seeds[idx[t[1]]],
							grid.seeds[idx[t[2]]], grid.seeds[idx[t[3]]]) \
							* _volume(Vector3(CORNER[t[0]]), Vector3(CORNER[t[1]]),
							Vector3(CORNER[t[2]]), Vector3(CORNER[t[3]])) < 0.0:
						stats["inverted"] = int(stats.get("inverted", 0)) + 1
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


static func _volume(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> float:
	return (b - a).cross(c - a).dot(d - a)


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
static func _face(st: SurfaceTool, cut: Array, want: Vector3, grid) -> void:
	var stone_raw: Dictionary = grid.stone
	var cav_all: PackedFloat32Array = grid.cavity
	# Наклоны берём ОДИН РАЗ на треугольник, а не на каждую вершину: обращение
	# к полю через нетипизированную ссылку — самое дорогое, что тут есть, а
	# вершин у куска тысячи.
	#
	# Они посчитаны по ПОЛЮ ДЛЯ СВЕТА, а срез идёт по настоящему. Форма остаётся
	# ровно там, где была, а свет по ней течёт мягче: у решётки в 0.67 м любая
	# вылепленная форма набрана из считаных граней, и резкий свет выдаёт каждую.
	var slopes: PackedVector3Array = grid.shade_slope
	# РАЗГЛАЖЕННАЯ, а не сырая: сырая ступенчата (пять значений с шагом в
	# четверть) и даёт на камне треугольные выносы травы по граням сетки.
	var rest: PackedFloat32Array = grid.under
	# ГЛУБИНА ТРЕЩИНЫ — вторым числом второго набора. По ней шейдер кладёт тень
	# в яму: см. `crack_cut` в `SpaceGrid.gd`.
	# Второе число второго набора свободно: тень по трещинам убрана.
	for i in range(1, cut.size() - 1):
		var tri: Array = wound([cut[0], cut[i], cut[i + 1]], grid, want)
		if tri.is_empty():
			continue
		# КАМЕНЬ ГРАНИТСЯ СВЕТОМ. Поверхность и так набрана из треугольников по
		# полторы-две сажени — но нормаль у неё берётся от наклона поля, и свет
		# течёт по ним гладко, пряча грани. Земле так и надо. Камню — нет: у него
		# нормаль ведём к нормали самого треугольника, и глыба сразу читается
		# многогранником. Это ничего не стоит и ничем не рискует: сама сетка не
		# меняется, меняется только то, как её освещает.
		var stones := [0.0, 0.0, 0.0]
		var cavs := [0.0, 0.0, 0.0]
		for k in range(3):
			var a: int = int(tri[k]["a"])
			var b: int = int(tri[k]["b"])
			var w: float = float(tri[k]["t"])
			stones[k] = clampf(lerpf(float(stone_raw.get(a, 0.0)),
				float(stone_raw.get(b, 0.0)), w), 0.0, 1.0)
			# Впадина приходит с сетки: по ней шейдер темнит стыки и пускает
			# зелень в трещины. Половина — ровное место, больше — щель.
			cavs[k] = 0.5 + 0.5 * lerpf(cav_all[a], cav_all[b], w)
		var flat: Vector3 = (tri[1]["p"] - tri[0]["p"]).cross(tri[2]["p"] - tri[0]["p"])
		flat = flat.normalized() if flat.length() > 0.000001 else Vector3.ZERO
		for k in range(3):
			var cc: Dictionary = tri[k]
			var smooth: Vector3 = _slope(grid, slopes, cc)
			var n: Vector3 = smooth
			if flat != Vector3.ZERO and stones[k] > 0.0:
				# Сторону берём от гладкой нормали: у треугольника своей нет,
				# он одинаково смотрит в обе.
				var faced: Vector3 = flat if flat.dot(smooth) > 0.0 else -flat
				n = smooth.lerp(faced, minf(stones[k], 1.0) * face_light).normalized()
			st.set_uv(Vector2(stones[k], cavs[k]))
			# Вторым набором — сколько под точкой земли. По нему шейдер решает,
			# может ли тут что-то осесть: на потолке пещеры и на нависающем
			# краю оседать нечему.
			var cc2: Dictionary = tri[k]
			# Второе число второго набора СВОБОДНО. По нему шла тень в трещинах,
			# и она убрана по кадру пользователя — см. «ТЁМНЫХ ТРЕЩИН НЕТ» в
			# `Terrain.gdshader`.
			st.set_uv2(Vector2(lerpf(rest[int(cc2["a"])], rest[int(cc2["b"])],
				float(cc2["t"])), 0.0))
			st.set_normal(n)
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
# Наклон БЕРЁТСЯ ГОТОВЫМ, а не считается здесь. Он принадлежит семени, а не
# вершине: одно семя попадает в десяток вершин, и обход шестерых соседей ради
# него повторялся десять раз подряд. Замерено — на этом уходило две трети всей
# пересборки куска.
static func _slope(grid, slopes: PackedVector3Array, c: Dictionary) -> Vector3:
	var g: Vector3 = slopes[int(c["a"])].lerp(slopes[int(c["b"])], float(c["t"]))
	if g.length() < 0.000001:
		return (grid.seeds[int(c["b"])] - grid.seeds[int(c["a"])]).normalized()
	return -g.normalized()


