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
#
# УБАВЛЕНО 0.2 → 0.08 (2026-09-01, её кадр: «образуются очередные ромбовидные
# грубые структуры, их не должно быть»).
#
# Ромб — это ДВА ТРЕУГОЛЬНИКА РЕШЁТКИ, ставшие видимыми. Свет по граням тянет
# нормаль к нормали самого треугольника, то есть красит поверхность по решётке,
# а не по форме. Само по себе это давало едва заметную разницу — но её ловит
# постеризация: тон на камне разложен по двадцати ступеням, и «чуть иначе»
# превращается в ступень с ЖЁСТКОЙ ПРЯМОЙ границей по ребру треугольника.
#
# Замер, почему не убрано совсем: плоских рёбер на камне 36.9%, но слипаются они
# в 562 плиты по десятой доле метра — то есть настоящих широких граней у формы
# нет, и сними свет по граням до нуля, глыба вернётся к пластилиновой гладкости.
# Оставлена треть прежнего: твёрдость есть, ступень по ребру не набирается.
static var face_light: float = 0.08

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
#
# СОБИРАЕМ В ПЛОСКИЕ ЧИСЛОВЫЕ МАССИВЫ, а не через `SurfaceTool`. Тот кладёт
# вершину тремя вызовами и держит её в своей записи; вершин у куска тысячи, а
# кусков на широкий мазок — под сорок. Меш выходит ТОТ ЖЕ (проверено слепком
# всей поверхности: то же число вершин и то же их содержимое).
#
# Всё, что берётся у сетки, берётся ОДИН РАЗ и в типизированные переменные:
# обращение к полю через нетипизированную ссылку — самое дорогое, что тут есть.
# Про это в файле уже записано однажды (наклоны), и правило то же.
static func build(grid, lo: Vector3i, hi: Vector3i) -> ArrayMesh:
	var seeds: PackedVector3Array = grid.seeds
	var fill: PackedFloat32Array = grid.fill
	var slopes: PackedVector3Array = grid.shade_slope
	var cav_all: PackedFloat32Array = grid.cavity
	var stone_raw: Dictionary = grid.stone
	var nodes: Dictionary = grid.node_index()

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()

	var idx := PackedInt32Array()
	idx.resize(8)
	var val := PackedFloat32Array()
	val.resize(8)
	# Буферы под точки среза: их не бывает больше четырёх, и заводятся они один
	# раз на весь кусок, а не на каждый тетраэдр.
	var cpos := PackedVector3Array()
	cpos.resize(4)
	var ca := PackedInt32Array()
	ca.resize(4)
	var cb := PackedInt32Array()
	cb.resize(4)
	var cw := PackedFloat64Array()
	cw.resize(4)

	for i in range(lo.x, hi.x):
		for j in range(lo.y, hi.y):
			for k in range(lo.z, hi.z):
				var here := Vector3i(i, j, k)
				var ok := true
				var below := 0
				for c in range(8):
					var s: int = int(nodes.get(here + CORNER[c], -1))
					if s < 0:
						ok = false
						break
					idx[c] = s
					val[c] = fill[s]
					if val[c] <= ISO:
						below += 1
				if not ok or below == 0 or below == 8:
					continue
				for t in TETS:
					var cnt: int = tet_polygon(seeds, idx, val, t,
						cpos, ca, cb, cw)
					if cnt == 0:
						continue
					_face(cnt, _outward(seeds, idx, val, t), seeds, slopes,
						cav_all, stone_raw, cpos, ca, cb, cw,
						verts, norms, uvs)

	if verts.is_empty():
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Многоугольник среза тетраэдра, уже в правильном порядке обхода. Отдельно от
# отрисовки, чтобы проверка на дыры считала РОВНО ту же геометрию, а не свою
# копию: разошедшаяся копия врала бы про целостность.
#
# Точки кладутся в буферы вызывающего (их не бывает больше четырёх); возвращаем,
# сколько легло. Ноль — среза нет.
static func tet_polygon(seeds: PackedVector3Array, idx: PackedInt32Array,
		val: PackedFloat32Array, t: Array, cpos: PackedVector3Array,
		ca: PackedInt32Array, cb: PackedInt32Array,
		cw: PackedFloat64Array) -> int:
	var inside: Array = []
	var outside: Array = []
	for c in t:
		if val[c] > ISO:
			inside.append(c)
		else:
			outside.append(c)
	if inside.is_empty() or outside.is_empty():
		return 0

	var n := 0
	# Точки среза лежат на рёбрах «изнутри наружу».
	for a in inside:
		for b in outside:
			_cut(seeds, idx, val, a, b, n, cpos, ca, cb, cw)
			n += 1
	if n < 3:
		return 0
	if n == 4:
		# Четыре точки: два ребра от каждого заполненного угла. Порядок 0,1,3,2
		# замыкает их в четырёхугольник без самопересечения — меняем местами
		# третью и четвёртую.
		var p: Vector3 = cpos[2]
		var a2: int = ca[2]
		var b2: int = cb[2]
		var w2: float = cw[2]
		cpos[2] = cpos[3]
		ca[2] = ca[3]
		cb[2] = cb[3]
		cw[2] = cw[3]
		cpos[3] = p
		ca[3] = a2
		cb[3] = b2
		cw[3] = w2
	return n


# Ищем ДЫРЫ. У замкнутой поверхности каждое ребро принадлежит ровно двум
# треугольникам; ребро с одним — это край дыры. Точку среза узнаём по паре
# семян, на ребре между которыми она лежит: такой ключ одинаков у всех
# тетраэдров и кубиков, которые её породили.
static func audit(grid, lo: Vector3i, hi: Vector3i, edges: Dictionary,
		stats: Dictionary) -> void:
	var seeds: PackedVector3Array = grid.seeds
	var idx := PackedInt32Array()
	idx.resize(8)
	var val := PackedFloat32Array()
	val.resize(8)
	var cpos := PackedVector3Array()
	cpos.resize(4)
	var ca := PackedInt32Array()
	ca.resize(4)
	var cb := PackedInt32Array()
	cb.resize(4)
	var cw := PackedFloat64Array()
	cw.resize(4)
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
					var cnt: int = tet_polygon(seeds, idx, val, t,
						cpos, ca, cb, cw)
					if cnt == 0:
						continue
					# Не вывернулся ли сам тетраэдр. Семя уходит от своего узла
					# почти на половину ячейки, и при неудачном совпадении
					# четвёрка семян меняет ориентацию: тетраэдры начинают
					# перекрываться, и срез в них смотрит не туда.
					if _volume(seeds[idx[t[0]]], seeds[idx[t[1]]],
							seeds[idx[t[2]]], seeds[idx[t[3]]]) \
							* _volume(Vector3(CORNER[t[0]]), Vector3(CORNER[t[1]]),
							Vector3(CORNER[t[2]]), Vector3(CORNER[t[3]])) < 0.0:
						stats["inverted"] = int(stats.get("inverted", 0)) + 1
					var want: Vector3 = _outward(seeds, idx, val, t)
					for f in range(1, cnt - 1):
						var turn: int = wound_order(cpos[0], cpos[f],
							cpos[f + 1], want)
						if turn < 0:
							continue
						var tri: Array = [0, f, f + 1]
						if turn == 1:
							tri = [f + 1, f, 0]
						# Пишем НАПРАВЛЕННЫЕ рёбра. У согласованной поверхности
						# каждое направленное ребро встречается ровно один раз:
						# соседние треугольники проходят общее ребро навстречу
						# друг другу. Встретилось дважды — треугольник вывернут.
						for pair in [[0, 1], [1, 2], [2, 0]]:
							var u := _vkey(ca[tri[pair[0]]], cb[tri[pair[0]]])
							var v := _vkey(ca[tri[pair[1]]], cb[tri[pair[1]]])
							if u == v:
								continue
							var s2 := "%s>%s" % [u, v]
							edges[s2] = int(edges.get(s2, 0)) + 1


static func _volume(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> float:
	return (b - a).cross(c - a).dot(d - a)


static func _vkey(a: int, b: int) -> String:
	return "%d.%d" % [mini(a, b), maxi(a, b)]


static func _outward(seeds: PackedVector3Array, idx: PackedInt32Array,
		val: PackedFloat32Array, t: Array) -> Vector3:
	var solid_mid := Vector3.ZERO
	var empty_mid := Vector3.ZERO
	var n_in := 0
	var n_out := 0
	for c in t:
		if val[c] > ISO:
			solid_mid += seeds[idx[c]]
			n_in += 1
		else:
			empty_mid += seeds[idx[c]]
			n_out += 1
	if n_in == 0 or n_out == 0:
		return Vector3.UP
	return (empty_mid / float(n_out) - solid_mid / float(n_in)).normalized()


# Точка на ребре и всё, что к ней прилагается: наклон поля и доля породы.
#
# ТОЧКА КЛАДЁТСЯ В ПЕРЕДАННЫЕ БУФЕРЫ, а не возвращается словарём. Словарь с
# именами полей — самое дорогое, что есть в GDScript, а точек этих в куске
# тысячи, и каждая читается по шесть раз. Замерено: на сборке мешей земли
# уходило 98% цены мазка.
static func _cut(seeds: PackedVector3Array, idx: PackedInt32Array,
		val: PackedFloat32Array, a: int, b: int, n: int,
		cpos: PackedVector3Array, ca: PackedInt32Array,
		cb: PackedInt32Array, cw: PackedFloat64Array) -> void:
	var fa: float = val[a]
	var fb: float = val[b]
	var span: float = fa - fb
	var t: float = 0.5 if absf(span) < 0.00001 else clampf((fa - ISO) / span, 0.0, 1.0)
	var sa: int = idx[a]
	var sb: int = idx[b]
	cpos[n] = seeds[sa].lerp(seeds[sb], t)
	ca[n] = sa
	cb[n] = sb
	cw[n] = t


# Сторону определяем У КАЖДОГО ТРЕУГОЛЬНИКА ОТДЕЛЬНО, а не на весь
# многоугольник сразу. Четырёхугольник среза в тетраэдре почти всегда неплоский,
# и при общем решении один из двух его треугольников оказывался вывернутым.
# Вывернутый треугольник не рисуется со своей стороны — сквозь него видно небо,
# и это неотличимо от дыры с прямыми краями. Сетка при этом остаётся замкнутой,
# поэтому поиск незамкнутых рёбер таких мест не находит.
#
# Всё, что берётся у сетки, приходит сюда ГОТОВЫМ и типизированным: обращение к
# полю через нетипизированную ссылку — самое дорогое, что тут есть, а вершин у
# куска тысячи. Наклоны посчитаны по ПОЛЮ ДЛЯ СВЕТА, а срез идёт по настоящему:
# форма остаётся ровно там, где была, а свет по ней течёт мягче.
#
# ВТОРОГО НАБОРА РАЗМЕТКИ У ЗЕМЛИ БОЛЬШЕ НЕТ. В нём лежала толща под точкой,
# и шейдер её не читал ни одной строкой — а считалась она на каждый мазок и
# писалась в каждую вершину. Убрана 2026-09-01 вместе с самой толщей.
static func _face(cnt: int, want: Vector3, seeds: PackedVector3Array,
		slopes: PackedVector3Array, cav_all: PackedFloat32Array,
		stone_raw: Dictionary, cpos: PackedVector3Array, ca: PackedInt32Array,
		cb: PackedInt32Array, cw: PackedFloat64Array,
		verts: PackedVector3Array, norms: PackedVector3Array,
		uvs: PackedVector2Array) -> void:
	for i in range(1, cnt - 1):
		var i0 := 0
		var i1 := i
		var i2 := i + 1
		var turn: int = wound_order(cpos[i0], cpos[i1], cpos[i2], want)
		if turn < 0:
			continue
		if turn == 1:
			var swap := i0
			i0 = i2
			i2 = swap
		# КАМЕНЬ ГРАНИТСЯ СВЕТОМ. Поверхность и так набрана из треугольников по
		# полторы-две сажени — но нормаль у неё берётся от наклона поля, и свет
		# течёт по ним гладко, пряча грани. Земле так и надо. Камню — нет: у него
		# нормаль ведём к нормали самого треугольника, и глыба сразу читается
		# многогранником. Это ничего не стоит и ничем не рискует: сама сетка не
		# меняется, меняется только то, как её освещает.
		var p0: Vector3 = cpos[i0]
		var p1: Vector3 = cpos[i1]
		var p2: Vector3 = cpos[i2]
		var flat: Vector3 = (p1 - p0).cross(p2 - p0)
		flat = flat.normalized() if flat.length() > 0.000001 else Vector3.ZERO
		for k in range(3):
			var at: int = i0 if k == 0 else (i1 if k == 1 else i2)
			var a: int = ca[at]
			var b: int = cb[at]
			var w: float = cw[at]
			var stone: float = clampf(lerpf(float(stone_raw.get(a, 0.0)),
				float(stone_raw.get(b, 0.0)), w), 0.0, 1.0)
			# Впадина приходит с сетки: по ней шейдер темнит стыки и пускает
			# зелень в трещины. Половина — ровное место, больше — щель.
			var cav: float = 0.5 + 0.5 * lerpf(cav_all[a], cav_all[b], w)
			var smooth: Vector3 = _slope(seeds, slopes, a, b, w)
			var n: Vector3 = smooth
			if flat != Vector3.ZERO and stone > 0.0:
				# Сторону берём от гладкой нормали: у треугольника своей нет,
				# он одинаково смотрит в обе.
				var faced: Vector3 = flat if flat.dot(smooth) > 0.0 else -flat
				n = smooth.lerp(faced, minf(stone, 1.0) * face_light).normalized()
			uvs.append(Vector2(stone, cav))
			norms.append(n)
			verts.append(cpos[at])


# Разворачиваем треугольник лицом наружу. ЕДИНСТВЕННОЕ место, где решается
# сторона, — и отрисовка, и проверка целостности ходят через него.
#
# Наружу смотрим по направлению от заполненных углов тетраэдра к пустым.
# Наклон поля для этого не годится: там, где поле упирается в предел и
# становится плоским, наклон вырождается и может указать не туда — тогда
# треугольник выворачивается, перестаёт рисоваться со своей стороны, и сквозь
# него видно небо. Это неотличимо от дыры, хотя сетка остаётся замкнутой.
#
# Возвращает ПОРЯДОК ОБХОДА, а не новый список: 0 — как дано, 1 — наоборот,
# −1 — треугольник выродился. Список тут заводился на каждый треугольник, а их
# в куске тысячи.
static func wound_order(a: Vector3, b: Vector3, c: Vector3, want: Vector3) -> int:
	var face_n: Vector3 = (b - a).cross(c - a)
	# Порог только против полного вырождения. Отбрасывать «волоски» по
	# относительному порогу пробовали — вместо ста вывернутых треугольников
	# получилось семьсот незамкнутых рёбер: щели оказались настоящими дырами.
	if face_n.length() < 0.000000001:
		return -1
	# В Godot лицевая сторона — обход ПО ЧАСОВОЙ снаружи.
	return 1 if face_n.dot(want) > 0.0 else 0


# Нормаль берём от НАКЛОНА ПОЛЯ, а не от треугольника: она непрерывна и
# одинакова с обеих сторон границы куска, поэтому шва не возникает и
# поверхность выглядит гладкой без отдельного сглаживания.
# Наклон БЕРЁТСЯ ГОТОВЫМ, а не считается здесь. Он принадлежит семени, а не
# вершине: одно семя попадает в десяток вершин, и обход шестерых соседей ради
# него повторялся десять раз подряд. Замерено — на этом уходило две трети всей
# пересборки куска.
static func _slope(seeds: PackedVector3Array, slopes: PackedVector3Array,
		a: int, b: int, w: float) -> Vector3:
	var g: Vector3 = slopes[a].lerp(slopes[b], w)
	if g.length() < 0.000001:
		return (seeds[b] - seeds[a]).normalized()
	return -g.normalized()


