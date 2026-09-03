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
# Разбиение кубика на тетраэдры берём У ОТРИСОВКИ, а не заводим своё: посадка
# растений обязана попадать в ту же поверхность, которую видно, и вторая копия
# таблицы рано или поздно разошлась бы с первой.
const SurfaceGeo = preload("res://Surface.gd")
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
# ПОЛЕ ДЛЯ СВЕТА — то же заполнение, но с разглаженной кривизной. Нормаль
# берётся ОТСЮДА, а сама поверхность режется по `fill`: форма не двигается, а
# свет по ней течёт мягче. Свет читается раньше силуэта, и это самая дешёвая
# правка из возможных — считается тем же проходом, что и впадина.
var fill_soft: PackedFloat32Array = PackedFloat32Array()
# НАКЛОН ПОЛЯ ДЛЯ СВЕТА, ПОСЧИТАННЫЙ ЗАРАНЕЕ. Нормаль вершины — это наклон на
# концах ребра, а наклон принадлежит СЕМЕНИ, не вершине. Одно семя попадает в
# десяток вершин, и он пересчитывался десять раз подряд, каждый раз обходя
# шестерых соседей. Замерено: на этом уходило две трети всей пересборки куска,
# и хранение наклона у семени ускоряет её в 2.16 раза.
var shade_slope: PackedVector3Array = PackedVector3Array()
# Рама для наклона: по 6 чисел на семя — обратная матрица направлений к
# соседям. Считается один раз, потому что семена больше не двигаются.
var slope_basis: PackedFloat32Array = PackedFloat32Array()
# ТАБЛИЦА СОСЕДЕЙ: по 6 номеров на семя, −1 если соседа нет. Всё, что считается
# по округе, ходило за соседом через словарь узлов, а ключ там — Vector3i, и
# каждое обращение стоит хеширования трёх целых. На один мазок таких обращений
# десятки тысяч. Соседи не меняются никогда — значит, их место в массиве.
var nb_table: PackedInt32Array = PackedInt32Array()
var edits: Dictionary = {}        # ячейка -> насколько её подняли мазками
var stone: Dictionary = {}        # ячейка -> насколько она каменистая, 0..1
# КАМЕНИСТОСТЬ, РАЗГЛАЖЕННАЯ ПО СОСЕДЯМ — ТОЛЬКО ДЛЯ СКЛАДОК. Цвет по-прежнему
# берёт сырую `stone`: край породы должен оставаться резким. См. `_facet` —
# там же, почему складкам нужна именно разглаженная.
# Два прохода, поэтому и массива два: `stone_mid` — после первого.
var stone_mid: PackedFloat32Array = PackedFloat32Array()
var stone_soft: PackedFloat32Array = PackedFloat32Array()
# СКОЛЬКО ТРЕЩИНЫ ОТНЯЛИ У ЯЧЕЙКИ. Нужен, чтобы растения могли спросить
# поверхность БЕЗ трещин — см. `calm_surface_near`. Хранить дешевле, чем
# считать шум второй раз: трещины стоят пяти обращений к шуму на ячейку.
var crack_cut: PackedFloat32Array = PackedFloat32Array()
# ЧЕРТА ТРЕЩИНЫ ДЛЯ ПОКРАСКИ: 0 на самой трещине, 1 и дальше — вне её.
#
# ЗАЧЕМ ОТДЕЛЬНО ОТ ФОРМЫ. Трещина в поле — это ложбина, и уже полутора метров
# она быть не может: решётка не удержит. А на камне трещина — ЧЕРТА, тонкая и
# длинная. Кадр пользователя: «трещины так и не появились: они должны быть
# длинными и тянуться какое-то время по поверхности скалы» — и это правда,
# ложбина в полтора метра на шестиметровом камне читается вмятиной, а не чертой.
#
# Поэтому работа делится: ФОРМА даёт углубление там, где решётка это может, а
# КРАСКА проводит в том же углублении тонкую черту. Плоскости у них одни и те
# же, поэтому черта ложится точно в ложбину — это не нарисованный поверх
# гладкого тела шов, а проявленная настоящая трещина.
# Сколько отняла трещина у ячейки, которую считают ПРЯМО СЕЙЧАС. Заводить
# отдельный возврат у `_joints` не за чем: её зовут из одного места.
var _cut_here: float = 0.0
var _rock_noise: FastNoiseLite
var _ledge_warp: FastNoiseLite
# Волны рельефа самого острова — см. `_land_height`.
var _land_hill: FastNoiseLite
var _land_cliff: FastNoiseLite
var _land_gully: FastNoiseLite
var _land_edge: FastNoiseLite
# ТРИ СЕМЕЙСТВА ТРЕЩИН — то, чем порода расколота на грани. См. `_joints`.
var _joint_sets: Array = []
# Во сколько раз растянуть шаг семейств трещин. Стенд крутит, игра берёт единицу.
# РАСТЯЖКА ШАГА СЕМЕЙСТВ — и это оказалось главным числом всей трещины.
#
# Раскрыв трещины держит решётка: уже двух с половиной метров его не сделать
# (замерено — стенка в 0.85 м даёт шесть шипов, в 0.45 м восемнадцать). А шаг
# семейств стоял 3.3–4.0 м. Значит, одна трещина занимала три четверти
# пространства своего семейства, а три семейства вместе — ВСЁ.
#
# Замер это и показал: 96% камня лежало внутри углубления, 76% темнело. Рока
# между трещинами не оставалось вовсе, и оттого не было видно ни одной: когда
# всё трещина, не видно ничего. Это и есть тот «паттерн долины», на который
# пожаловалась пользователь.
#
# Лечится не силой, а РЕДКОСТЬЮ:
#   растяжка  плоских  тень   в яме   шипов  вогн
#   1.0        34.1%   75.8%  96.2%    3     85.9°  ← было
#   1.8        36.8%   37.3%  62.7%    1     86.9°
#   2.6        36.9%    6.0%  16.8%    0     84.8°  ← стало
#   3.4        38.6%    0.7%   5.5%    0     66.1°
# На 2.6 тень ложится на шесть процентов камня — ровно та доля, что видна на
# снимках обнажений, — а плоских граней становится БОЛЬШЕ: тело камня между
# трещинами уцелело. Шаг семейств выходит 8.6, 8.8 и 10.4 м, то есть на глыбу в
# шесть с половиной метров приходится две-три трещины, как на снимках.
var joint_span: float = 2.6
# ГЛЫБЫ ПО МАЗКАМ: сколько мазков положено — на столько камней массив и
# делится. См. `_claim_lump` и `_refresh_seam`.
var lumps: Array = []             # {pos: Vector3, r: float, mass: float}
var seam: PackedFloat32Array = PackedFloat32Array()   # 0 внутри глыбы, 1 на стыке
var _lump_hash: Dictionary = {}   # грубая клетка -> номера глыб
var _play: PackedByteArray = PackedByteArray()    # семя внутри играбельного объёма
var _built: PackedByteArray = PackedByteArray()   # ячейку уже вырезали
const NO_CELL := {"faces": [], "valid": false}
var carve_usec: int = 0           # сколько всего ушло на вырезание


# --- Главная функция ---------------------------------------------------------
var _play_radius: float = 0.0
var _land_span: float = 0.0        # радиус острова — для спада холмов к кромке
var _play_low: float = 0.0
var _play_high: float = 0.0


func generate(radius: float, top: float, bottom: float, headroom: float,
		underroom: float, spacing: float, grid_seed: int) -> void:
	_spacing = spacing
	_cell_size = spacing * 1.4
	# ИГРАБЕЛЬНЫЙ ОБЪЁМ: сам остров плюс запас по высоте — вверх и вниз.
	#
	# ЗАПАС СНИЗУ — ОТДЕЛЬНОЕ ЧИСЛО, А НЕ СДВИГ ДНА (решение пользователя
	# 2026-08-28: «увеличь доступную комнату в высоту, количество изначальной
	# земли оставь прежним»). Опусти мы `bottom` — и остров стал бы толще: это
	# же число задаёт его подошву в `_fill_terrain`. Запас же копать вниз
	# позволяет, а породы не прибавляет.
	_play_radius = radius + spacing * 0.6
	_play_low = bottom - maxf(underroom, spacing * 0.6)
	_play_high = top + headroom
	var rng := RandomNumberGenerator.new()
	rng.seed = grid_seed

	# Рельеф ОДНОЙ волной. Второй, мелкий слой шума (частота 0.26, высота 0.9
	# шага) стоял тут ради «неправильных пятен» — а на деле давал ПОЛОВИНУ всей
	# угловатости земли и почти ничего не давал самому рельефу. Замерено: излом
	# поверхности с ним 8.6°, без него 4.3°, а размах высоты — 0.71 м против
	# 0.69 м. Три сантиметра высоты за вдвое более мятую землю.
	#
	# Мельче четырёх шагов решётки волну вообще держать нельзя — она вырождается
	# в дрожь по ячейкам. Эта была на грани и потому читалась не рельефом, а
	# рябью.
	# Соразмерность острову — см. `LAND_TUNED_AT`. Длины волн растут вместе с
	# высотами, оттого частоты и делятся на ту же величину. Считается ДО первой
	# волны: на ней же и делится.
	_land_k = radius / LAND_TUNED_AT
	var shape := FastNoiseLite.new()
	shape.seed = grid_seed
	shape.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	shape.frequency = SWELL_WAVE / _land_k
	# Три волны рельефа сверх зыби — холмы, обрывы, овраги. Разбор у
	# `_land_height`, длины волн там же в постоянных.
	_land_hill = FastNoiseLite.new()
	_land_hill.seed = grid_seed + 1777
	_land_hill.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_land_hill.frequency = HILL_WAVE / _land_k
	_land_cliff = FastNoiseLite.new()
	_land_cliff.seed = grid_seed + 2887
	_land_cliff.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_land_cliff.frequency = CLIFF_WAVE / _land_k
	_land_gully = FastNoiseLite.new()
	_land_gully.seed = grid_seed + 3557
	_land_gully.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_land_gully.frequency = GULLY_WAVE / _land_k
	# КРОМКЕ ОСТРОВА — СВОЯ ВОЛНА, И ЭТО НЕ ПРИДИРКА, А ЗАМЕР.
	#
	# Прежде очертание бралось от волны рельефа, взятой двойной частотой. Пока
	# рельеф шёл волной в 22 м, кромка виляла с шагом 11 м — плавно. Стоило
	# укоротить волну рельефа до 11.8 м, и кромка стала вилять с шагом 5.9 м:
	# полтора метра туда-сюда на трёх метрах дуги. Решётка такого не держит —
	# поверхность в тридцати одном месте перестала замыкаться (замер: «незамкнутых
	# — 31» против нуля), а это ровно то, чего не пропускает хук перед пушем.
	#
	# Теперь очертание не зависит от рельефа вовсе и виляет с прежним шагом.
	_land_edge = FastNoiseLite.new()
	_land_edge.seed = grid_seed + 4649
	_land_edge.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_land_edge.frequency = EDGE_WAVE / _land_k
	_rock_noise = FastNoiseLite.new()
	_rock_noise.seed = grid_seed + 4243
	_rock_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	# Доли камня: 1/0.16 = 6.25 м, это 9.4 ячейки. См. `_facet` — там же вторая,
	# средняя доля. Мельче четырёх ячеек решётка не держит ничего.
	_rock_noise.frequency = 0.16
	# Волна, которой ведут уровни слоёв, — 11.8 м, крупнее любой глыбы. Без неё
	# полки одинаковы во всём мире и читаются разлиновкой.
	_ledge_warp = FastNoiseLite.new()
	_ledge_warp.seed = grid_seed + 909
	_ledge_warp.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_ledge_warp.frequency = 0.085
	_build_joints(grid_seed)

	# Семена берём с запасом за краем: у крайних ячеек нет всех соседей,
	# их не удаётся замкнуть, и мы их отбрасываем.
	var margin := spacing * 2.0
	_scatter(_play_radius + margin, _play_high + margin, _play_low - margin, rng)
	_build_seed_hash()
	_build_neighbours()
	_build_slope_basis()
	_build_cells()
	# `top` сюда больше не идёт: рельеф считается в метрах сам по себе, а не
	# долей от макушки острова — см. `_land_height`. Макушка осталась тем, чем
	# и была: подошвой запаса по высоте (`_play_high`).
	_fill_terrain(radius, bottom, shape)


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

func _scatter(radius: float, top_edge: float, bottom: float,
		rng: RandomNumberGenerator) -> void:
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


# Соседи раз и навсегда — см. `nb_table`.
func _build_neighbours() -> void:
	nb_table.resize(seeds.size() * 6)
	for i in range(seeds.size()):
		var node: Vector3i = node_of(i)
		for k in range(6):
			nb_table[i * 6 + k] = int(_node_index.get(node + NEIGHBOURS[k], -1))


# РАМА ДЛЯ НАКЛОНА. Наклон поля у семени мы раньше СКЛАДЫВАЛИ: брали по
# соседям `d·Δf/|d|²` и суммировали. На РОВНОЙ решётке это точно. На
# разбросанной — нет: сумма даёт не наклон, а наклон, умноженный на матрицу
# `Σ d̂·d̂ᵀ` из направлений к соседям. У ровной решётки эта матрица — просто
# удвоенная единичная, и она не мешает. У разбросанной она у каждого семени
# своя и кривая.
#
# ЧЕГО ЭТО СТОИЛО. Я положил на настоящие семена идеально ровный склон — ни
# бугра, ни впадины — и спросил мерку, куда он наклонён. Она ошибалась на 8.85°
# в среднем и на 26.8° в худшем случае. Восемь градусов дрожи освещения на
# месте, где дрожать нечему: земля читалась мятой бумагой.
#
# ЛЕЧЕНИЕ. Ту самую матрицу и обращаем, а потом умножаем на неё сумму. Ошибка
# на ровном склоне становится ровно нулевой — не «меньше», а нулевой, потому
# что решение точное.
#
# СЧИТАЕМ ОДИН РАЗ. Матрица зависит только от того, где стоят семена, а они
# после постройки мира не двигаются никогда. В горячем месте отрисовки остаётся
# умножение матрицы на вектор — дешевле шести делений, которые были раньше.
func _build_slope_basis() -> void:
	slope_basis.resize(seeds.size() * 6)
	for i in range(seeds.size()):
		var here: Vector3 = seeds[i]
		var m := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		var count := 0
		for k in range(6):
			var s: int = nb_table[i * 6 + k]
			if s < 0:
				continue
			var d: Vector3 = seeds[s] - here
			var len2: float = d.length_squared()
			if len2 < EPS:
				continue
			var w: float = 1.0 / len2
			m.x += d * (d.x * w)
			m.y += d * (d.y * w)
			m.z += d * (d.z * w)
			count += 1
		var at := i * 6
		# У края мира соседей не хватает, и матрица вырождается: обратить её
		# нельзя. Там оставляем единичную — то есть прежнее сложение. Это семена
		# за играбельным объёмом, поверхности у них не бывает.
		var scale: float = (m.x.x + m.y.y + m.z.z) / 3.0
		if count < 4 or scale < EPS or absf(m.determinant()) < 0.02 * scale * scale * scale:
			slope_basis[at] = 1.0
			slope_basis[at + 1] = 1.0
			slope_basis[at + 2] = 1.0
			slope_basis[at + 3] = 0.0
			slope_basis[at + 4] = 0.0
			slope_basis[at + 5] = 0.0
			continue
		var inv: Basis = m.inverse()
		# Матрица симметричная, поэтому хватает шести чисел вместо девяти.
		slope_basis[at] = inv.x.x
		slope_basis[at + 1] = inv.y.y
		slope_basis[at + 2] = inv.z.z
		slope_basis[at + 3] = inv.x.y
		slope_basis[at + 4] = inv.x.z
		slope_basis[at + 5] = inv.y.z


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

# =============================================================================
#  РЕЛЬЕФ ОСТРОВА — по её референсу 02.09.2026 (альпийский луг с озером):
#  «более крупные холмы с пологими склонами, кластерами скал, долинами,
#  оврагами и обрывами».
#
#  ЧТО БЫЛО. Одна волна ±2 м на 22 метра длины — на острове в 26 метров это
#  ровно один бугор и одна ложбина. Всё остальное — холмы, ямы, скалы —
#  досыпала уже стартовая сцена мазками кисти, то есть сам остров был почти
#  пустым, и «генерация острова» этого имени не заслуживала.
#
#  Теперь четыре слоя, по одному на каждое слово задания. Порядок их НЕ
#  произволен: обрывы ступенями ложатся на готовые холмы, а овраги режут уже
#  ступенчатый склон — как в жизни, где промоина позже скалы.
# =============================================================================

# 1. ЗЫБЬ — пологая волна под всем, чтобы луг не был столом. Прежняя единственная
#    волна и стала ею, только тише и мельче.
const SWELL: float = 1.15         # ±м
const SWELL_WAVE: float = 0.085   # 1/0.085 = 11.8 м

# 2. ХОЛМЫ. РАСТУТ ВВЕРХ, А НЕ ВНИЗ, и это не украшение, а необходимость: волна
#    ±3.4 м опустила бы ложбины ниже подошвы острова (−3.5 м), поверхность
#    встретилась бы сама с собой и остров вышел бы дырявым. Берём только верхнюю
#    половину волны — холмы поднимаются ОТ ЛУГА, а не выедают его.
#
#    По референсу так и есть: там луг, из которого встают холмы, а не яма среди
#    холмов. Долины при этом получаются сами — это луг между двумя холмами.
#
#    СКЛОНЫ ПОЛОГИЕ ПО ПОСТРОЕНИЮ: подъём 3.4 м на половину волны (12.5 м) —
#    это 15°. Со зыбью вместе местами до 25°, и круче нигде, если не считать
#    обрывов, которым круто и положено.
#    ЗАМЕР ПОПРАВИЛ ОБА ЧИСЛА. При подъёме 3.4 м и волне 25 м размах вышел 3.5 м
#    — почти прежний, потому что шум до единицы почти не доходит (обычный его
#    предел около 0.75), а верхняя половина волны отрезает и того больше. Подъём
#    поднят, а волна удлинена ВМЕСТЕ с ним: подними одну — и склон стал бы круче
#    ровно во столько же раз, а «пологие склоны» стоят в задании первыми.
#    ВЫШЕ 3.4 М РЕШЁТКА НЕ ДЕРЖИТ — это стена, а не осторожность. Замер
#    02.09.2026 на эталонном острове: при 3.4 м поверхность замкнута начисто,
#    при 4.0 м — три незамкнутых места, при 4.8 м — шесть, и все в одной точке
#    склона. Ни обрывы, ни овраги тут ни при чём: с выключенными выходило столько
#    же. Хук перед пушем незамкнутую поверхность не выпускает, так что 3.4 — это
#    не «пока хватит», а потолок при ячейке 0.67 м. Выше можно будет, только если
#    измельчить решётку (а это семена квадратом) или растянуть остров — вторым
#    занимается `_land_k` ниже.
const HILL_RISE: float = 3.4      # м
const HILL_WAVE: float = 0.031    # 32 м — шире острова
const HILL_KNEE: float = 0.30     # насколько мягко подошва сходит на луг

# 3. ОБРЫВЫ — ЭТО СТУПЕНИ, А НЕ ПРОСТО КРУТИЗНА. Крутой склон и обрыв на кадре
#    читаются по-разному: у обрыва есть полка сверху и полка снизу, а между ними
#    стенка. Поэтому высота прижимается к полкам: внутри полосы она стоит на
#    месте, а последнюю седьмую долю полосы отыгрывает разом.
#
#    Стенка выходит около 65° — обрыв, но не отвес: отвес решётка держит только
#    у камня, у земли он оплыл бы всё равно.
#
#    И НЕ ВЕЗДЕ. Ступени по всему острову — это разлиновка, а не рельеф;
#    маска пускает их пятнами шириной 18 м, между которыми склон обычный.
const BENCH: float = 1.30         # высота полки, м
const BENCH_LO: float = 0.86      # с какой доли полосы начинается стенка
const BENCH_HI: float = 0.99
const CLIFF_WAVE: float = 0.055   # 18 м

# 4. ОВРАГИ. Промоина идёт ЛИНИЕЙ, а линия в шуме одна — та, где он переходит
#    через ноль. Берём модуль шума: у самой линии он ноль, в стороне растёт, и
#    полоса `GULLY_WIDE` вокруг неё и есть овраг. Русло получается извилистым
#    само собой.
#
#    ШИРЕ ДВУХ ЯЧЕЕК ПО ДНУ (1.6 м при пределе 1.33) — уже решётка не держит,
#    и вместо оврага вышла бы рябь по ячейкам.
#
#    ТОЛЬКО НА СКЛОНАХ, а не по всему острову. Овраг на дне луга — это канава;
#    и он же проел бы остров насквозь, потому что низины и без него у подошвы.
const GULLY_WAVE: float = 0.05    # 20 м
const GULLY_WIDE: float = 0.16    # около 1.6 м по дну
const GULLY_DEEP: float = 0.85    # м
const GULLY_FROM: float = 0.35    # с какой высоты режет

# Ниже этого рельеф не опускается: подошва острова на −3.5, и земле надо
# остаться землёй, а не плёнкой. Прижим мягкий — жёсткий дал бы плоское дно
# ровно там, где его видно.
const EDGE_WAVE: float = 0.055   # очертание острова: 18 м

const LAND_LOW: float = -1.9

# РЕЛЬЕФ СОРАЗМЕРЕН ОСТРОВУ. Все числа выше подобраны на обычном острове радиуса
# 13 м; оставь их как есть — и на острове вдвое шире те же холмы читались бы
# кочками, а ключ `--island` потерял бы смысл.
#
# Растягиваем ВМЕСТЕ высоты и длины волн, а не что-то одно: тогда крутизна
# склонов от размера не зависит вовсе, и предел, за которым поверхность рвётся,
# остаётся тем же на любом острове. Разведи их — и на маленьком острове рельеф
# стал бы круче предела молча.
const LAND_TUNED_AT: float = 13.0
var _land_k: float = 1.0


func _land_height(x: float, z: float, shape: FastNoiseLite) -> float:
	var h: float = shape.get_noise_2d(x, z) * SWELL * _land_k
	# ХОЛМ НЕ ДОХОДИТ ДО КРОМКИ, И ЭТО НЕ УКРАШЕНИЕ, А ПОЧИНКА.
	#
	# ЗАМЕР: с холмами, обрезанными краем острова, поверхность переставала
	# замыкаться в трёх десятках мест («незамкнутых — 31» против нуля), и хук
	# перед пушем такого не пропускает. Причина простая: холм, дошедший до
	# кромки, обрывается там стенкой в три метра — а кромка и без него самое
	# тонкое место в мире, там сходятся сразу три ограничения.
	#
	# И ОБЛИКУ ТАК ЖЕ ВЕРНЕЕ. У острова, обрубленного посреди холма, край
	# читается срезом торта; у настоящего склон к воде сходит на нет.
	var rim: float = clampf((_land_span - Vector2(x, z).length())
		/ maxf(0.001, _land_span * 0.22), 0.0, 1.0)
	# ПОДОШВА ХОЛМА СХОДИТ НА ЛУГ МЯГКО, а не изломом. Отрезая нижнюю половину
	# волны напрямую (`maxf`), мы получаем по всей линии её перехода через ноль
	# ИЗЛОМ — угол в поле. Решётка держит его хуже крутизны: замер 02.09.2026
	# поймал на нём семь незамкнутых мест при холме в 4.8 м (при 2.0 их не было
	# вовсе, оттого и казалось, что виновата высота).
	h += -_smin(-_land_hill.get_noise_2d(x, z), 0.0, HILL_KNEE) \
		* HILL_RISE * _land_k * smoothstep(0.0, 1.0, rim)
	# Обрывы. Маска решает ГДЕ, полка — насколько высоко.
	var mask: float = smoothstep(0.05, 0.40, _land_cliff.get_noise_2d(x, z))
	if mask > 0.001:
		var bench: float = BENCH * _land_k
		var step: float = floor(h / bench)
		var part: float = h / bench - step
		h = lerpf(h, (step + smoothstep(BENCH_LO, BENCH_HI, part)) * bench, mask)
	# Овраги.
	var side: float = absf(_land_gully.get_noise_2d(x, z))
	if side < GULLY_WIDE:
		var deep: float = 1.0 - side / GULLY_WIDE
		# В квадрате: дно узкое, стенки круче — так промоина и режет.
		h -= deep * deep * GULLY_DEEP * _land_k * clampf(
			(h - GULLY_FROM * _land_k) / (1.1 * _land_k), 0.0, 1.0)
	# Мягкий пол.
	return -_smin(-h, -LAND_LOW, 0.5)


func _fill_terrain(radius: float, bottom: float,
		shape: FastNoiseLite) -> void:
	_land_span = radius
	solid = {}
	fill = PackedFloat32Array()
	fill.resize(seeds.size())
	# СЧИТАЕМ ВСЕМ СЕМЕНАМ, включая запасное кольцо за играбельным объёмом.
	# Раньше кольцо пропускалось и оставалось с заполнением 0. Ноль — это тоже
	# «воздух», поэтому дыр не было, но всякий счёт по соседям у кромки острова
	# получал эту ложь вместо настоящих ±11: наклон, впадина и крутизна у края
	# считались по выдуманному обрыву. Заодно остров переставал быть островом и
	# обрезался отвесной стенкой по цилиндру играбельного объёма.
	# ВЫСОТУ СЧИТАЕМ ПО СТОЛБЦАМ РЕШЁТКИ, А НЕ ПО КАЖДОМУ СЕМЕНИ, и это не только
	# ради скорости. Семян 52 тысячи, а столбцов полторы — рельеф стал стоить
	# вчетверо больше волн, и на семя это выходило две лишних секунды на запуске.
	#
	# ТОЧНОСТИ НЕ ТЕРЯЕТСЯ, а прибавляется. Семя отходит от своего узла не дальше
	# 0.27 шага (18 см), и на склоне это давало высоте разброс в считанные
	# сантиметры — ту самую дрожь по ячейкам, из-за которой в этом же файле уже
	# отказались мерить породу по разбросанному семени: соседи случайно попадали
	# по разные стороны поверхности, и она шла бородавками. Неправильность земле
	# даёт разброс семян ПО ВЫСОТЕ, он остаётся весь.
	#
	# Край острова считается там же и по той же причине.
	var column: Dictionary = {}
	for i in range(seeds.size()):
		var s: Vector3 = seeds[i]
		var node: Vector3i = node_of(i)
		var key := Vector2i(node.x, node.z)
		if not column.has(key):
			var g: Vector3 = lattice[i]
			column[key] = Vector2(_land_height(g.x, g.z, shape),
				radius * (1.0 + 0.10 * _land_edge.get_noise_2d(g.x, g.z)))
		var land: Vector2 = column[key]
		# Поверхность острова, его край и дно — три плавных ограничения.
		# Берём самое строгое; ничего не округляем по ячейкам, в этом весь смысл.
		var height: float = land.x
		var edge: float = land.y
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
	fill_soft.resize(seeds.size())
	shade_slope.resize(seeds.size())
	# Породы в мире пока нет ни крупицы, поэтому оба — нули. Заполнятся сами,
	# как только по месту пройдёт мазок камня.
	stone_mid.resize(seeds.size())
	stone_soft.resize(seeds.size())
	crack_cut.resize(seeds.size())
	seam.resize(seeds.size())
	for i in range(seeds.size()):
		_refresh_cavity(i)
	_smooth_cavity()
	for i in range(seeds.size()):
		_refresh_shade(i)


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
# Множитель подобран ПОД ЧЕСТНУЮ МЕРКУ и потому вырос. Прежняя разница со
# средним по соседям упиралась в потолок ±1 просто от разброса семян: на ровной
# земле, где щелей нет вовсе, она давала в среднем 0.335 и доходила до единицы,
# а на глыбе — 0.573 и сплошную единицу. Порогам шейдера предъявлялся шум,
# прижатый к потолку, и «зелень в трещинах» сыпалась где попало.
#
# Выпуклость честная и оттого мелкая: на ровной земле 0.05, на глыбе 0.171 при
# прежнем множителе. Разделение стало втрое лучше (было 1.7 раза, стало 3.4),
# но в пороги шейдера такой сигнал уже не доставал — трещины молча погасли.
# Возвращаем размах: на настоящих щелях выходит около 0.9, на ровном месте
# меньше 0.2.
const CAVITY_GAIN: float = 4.5

# Насколько поле для света отходит от настоящего. Единица — вся кривизна снята
# начисто; тогда свет на вылепленном холме успокаивается сильнее всего, а форму
# это не трогает вовсе, потому что режется поверхность по-прежнему по `fill`.
const SHADE_SOFT: float = 1.0

func _refresh_cavity(index: int) -> void:
	if index < 0 or index >= cavity.size():
		return
	# Впадина — это ВЫПУКЛОСТЬ со знаком минус, и считать её надо честно.
	# Прежде здесь стояла разница со средним по соседям, а у неё на ровном
	# склоне ложный вклад 0.126 × 2.6 = 0.33 при полном размахе 1.0: треть
	# шкалы, по которой шейдер темнит стыки и пускает зелень в трещины, была
	# чистым шумом от разброса семян.
	#
	# Выпуклость считаем ОДИН раз на два дела: по ней же разглаживается поле
	# для света. Второй проход стоил бы ровно столько же, сколько первый.
	var bulge: float = bulge_at(index)
	cavity[index] = clampf(bulge * CAVITY_GAIN, -1.0, 1.0)
	fill_soft[index] = fill[index] + bulge * SHADE_SOFT


# Наклон поля для света у семени. Считать ПОСЛЕ того, как поле для света готово
# У СОСЕДЕЙ ТОЖЕ: наклон смотрит на них, и по недосчитанному соседу выйдет
# неверная нормаль. Отсюда и лишнее кольцо при обновлении после мазка.
# Обновляем наклон для света ШИРЕ, чем менялось поле: он смотрит на соседей, а
# у них поле для света только что пересчиталось. Кольцо ровно одно — дальше уже
# ничего не изменилось.
# ПАЧКА МАЗКОВ: считаем последствия ОДИН РАЗ В КОНЦЕ, а не после каждого.
#
# Годится только там, где между мазками никто не смотрит на мир, — то есть при
# расстановке острова. У руки игрока так нельзя: она видит каждый мазок.
var _batching: bool = false
var _batch: Dictionary = {}

func begin_batch() -> void:
	_batching = true
	_batch = {}


# ОДИНОЧНОЕ СЕМЯ — ЭТО ШИП, а не форма (её кадр 2026-09-02: тонкий зелёный
# клинок, торчащий из макушки скалы).
#
# Поверхность режется по уровню 0.5. Семя, поднявшееся над уровнем в одиночку —
# когда все шесть его соседей ниже, — даёт не бугор, а КЛИН: тетраэдры вокруг
# него срезаются у самой вершины, и выходит тонкая игла или лезвие. Формы в этом
# нет никакой: ни один мазок такого не задумывал, это остаток на хвосте юбки.
#
# Правим самым слабым лекарством — опускаем такое семя чуть ниже уровня. Соседей
# это не трогает, и всё, что стоит хотя бы на паре семян, остаётся как было.
#
# `SOLO_KEEP` — сколько соседей выше уровня всё же считается формой. Один сосед
# оставляем: это уже не игла, а гребешок в одно ребро, и на кромке скалы он к
# месту.
const SOLO_KEEP: int = 1

func solo_spikes(fix: bool) -> int:
	var many := 0
	for j in range(fill.size()):
		if fill[j] <= SOLID_AT:
			continue
		var up := 0
		var at: int = j * 6
		for k in range(6):
			var s: int = nb_table[at + k]
			if s >= 0 and fill[s] > SOLID_AT:
				up += 1
		if up > SOLO_KEEP:
			continue
		many += 1
		if fix:
			fill[j] = SOLID_AT - 0.02
	return many


func end_batch() -> void:
	_batching = false
	for j in _batch:
		_refresh_cavity(j)
	_smooth_cavity(_batch.keys())
	_refresh_shade_round(_batch)
	_batch = {}


func _refresh_shade_round(seen: Dictionary) -> void:
	for j in _grown(seen):
		_refresh_shade(j)


# Набор плюс кольцо прямых соседей. Всё, что считается по округе, меняется на
# кольцо дальше самой правки, и это кольцо приходилось выписывать заново в
# каждом таком месте.
func _grown(seen: Dictionary) -> Dictionary:
	var wide: Dictionary = seen.duplicate()
	for j in seen:
		var at: int = int(j) * 6
		for k in range(6):
			var n: int = nb_table[at + k]
			if n >= 0:
				wide[n] = true
	return wide


# ОБЁРТКА ДЛЯ СКЛАДОК — каменистость, разглаженная по соседям. Зачем она нужна
# складкам, написано у `_facet`; здесь — как считается.
#
# Два прохода по шестерым соседям с половинным весом. Один растягивает обёртку
# примерно на ячейку, два — на две с половиной: складка успевает погаснуть к
# краю глыбы медленнее, чем решётка теряет форму.
#
# КОЛЬЦА РАЗНОЙ ШИРИНЫ, и порядок обязателен. Первый проход смотрит на
# каменистость соседей, поэтому меняется на кольцо дальше неё; второй смотрит
# на готовый первый — значит, ещё на кольцо. Сложить их в один обход нельзя:
# второму нужен посчитанный первый У СОСЕДЕЙ ТОЖЕ, а не только у себя.
#
# Приходит сюда не весь мазок, а только те ячейки, где доля породы сдвинулась.
# Разница не в красоте: мазок ЗЕМЛИ по чистой земле не двигает её нигде, и без
# этого отбора каждый такой мазок платил бы за пересчёт складок, которых на
# земле нет. Замерено на широкой кисти: 49 мс против 40.
func _refresh_stone_soft_round(hot: Dictionary) -> void:
	var one: Dictionary = _grown(hot)
	for j in one:
		_refresh_stone_mid(int(j))
	for j in _grown(one):
		_refresh_stone_soft(int(j))


func _refresh_stone_mid(index: int) -> void:
	var sum: float = stone_of(index)
	var w: float = 1.0
	var at: int = index * 6
	for k in range(6):
		var s: int = nb_table[at + k]
		if s < 0:
			continue
		sum += stone_of(s) * 0.5
		w += 0.5
	stone_mid[index] = sum / w


func _refresh_stone_soft(index: int) -> void:
	var sum: float = stone_mid[index]
	var w: float = 1.0
	var at: int = index * 6
	for k in range(6):
		var s: int = nb_table[at + k]
		if s < 0:
			continue
		sum += stone_mid[s] * 0.5
		w += 0.5
	stone_soft[index] = sum / w


# ТОЛЩА ПОД ТОЧКОЙ УБРАНА ЦЕЛИКОМ (2026-09-01).
#
# Она считалась на каждый мазок и клалась во ВСЯКУЮ вершину земли вторым
# набором разметки — а шейдер земли её не читал вовсе. Смысл у неё был «есть ли
# куда осесть наносу», и его давно взял на себя наклон поверхности: толща
# ступенчата (скачок на три четверти между соседями), и порог по ней давал
# прямые отрезки поперёк треугольников — те самые «треугольные выносы травы».
# Замена записана в `Terrain.gdshader` рядом с `rest`.
#
# Держалась она последние дни только тем, что её никто не вычёркивал. Мазок от
# неё стал дешевле, а мазок — это отклик на руку.


# РАЗГЛАЖИВАНИЕ ТОЛЩИ УБРАНО, И ЭТО ЗАМЕР, А НЕ ВКУС.
#
# Толща под точкой ступенчата, и по ней в шейдере стоял порог — оттого на камне
# лезли треугольные выносы травы. Я попробовал её разгладить по соседям, как
# разглажена каменистость. Не вышло: наибольший скачок между соседями упал с
# 0.75 всего до 0.615 за один проход и до 0.536 за два. У обрыва она меняется не
# на четверть, а сразу на три четверти — это не шум, а настоящая форма, и
# усреднением семи точек её не убрать.
#
# Лечило другое: величину убрали из решения о зелени совсем и заменили наклоном
# поверхности, гладким по построению. См. `Terrain.gdshader`, «ТОЛЩУ ПОД ТОЧКОЙ
# ИЗ РЕШЕНИЯ О ЗЕЛЕНИ УБРАЛИ СОВСЕМ».


func _refresh_shade(index: int) -> void:
	if index < 0 or index >= shade_slope.size():
		return
	var here: Vector3 = seeds[index]
	var f0: float = fill_soft[index]
	var g := Vector3.ZERO
	var at := index * 6
	for k in range(6):
		var s: int = nb_table[at + k]
		if s < 0:
			continue
		var d: Vector3 = seeds[s] - here
		var len2: float = d.length_squared()
		if len2 > 0.000001:
			g += d * ((fill_soft[s] - f0) / len2)
	shade_slope[index] = straighten(index, g)


# Разворачиваем сложенную по соседям сумму в настоящий наклон — умножением на
# заранее обращённую раму. См. `_build_slope_basis`.
func straighten(index: int, raw: Vector3) -> Vector3:
	var at := index * 6
	var xx: float = slope_basis[at]
	var yy: float = slope_basis[at + 1]
	var zz: float = slope_basis[at + 2]
	var xy: float = slope_basis[at + 3]
	var xz: float = slope_basis[at + 4]
	var yz: float = slope_basis[at + 5]
	return Vector3(
		xx * raw.x + xy * raw.y + xz * raw.z,
		xy * raw.x + yy * raw.y + yz * raw.z,
		xz * raw.x + yz * raw.y + zz * raw.z)


# Наклон поля у семени. Та же величина, по которой `Surface.gd` берёт нормаль,
# — там она посчитана своей копией нарочно: это самое горячее место отрисовки,
# и вызов через ссылку стоил бы кадра. ПРАВИТЬ ОБЕ.
func field_slope(index: int, calm: bool = false) -> Vector3:
	var here: Vector3 = seeds[index]
	var f0: float = _fv(index, calm)
	var g := Vector3.ZERO
	var at := index * 6
	for k in range(6):
		var s: int = nb_table[at + k]
		if s < 0:
			continue
		var d: Vector3 = seeds[s] - here
		var len2: float = d.length_squared()
		if len2 > 0.000001:
			g += d * ((_fv(s, calm) - f0) / len2)
	return straighten(index, g)


# =============================================================================
#  СПОКОЙНАЯ ПОВЕРХНОСТЬ — ОТМЕНЕНА, И ВОТ ПОЧЕМУ
# =============================================================================
#
#  Заводилась она по решению пользователя: «если трещины узкие, то растения
#  должны игнорировать их и действовать так, как если бы это был монолит».
#  Спокойное поле — это настоящее ПЛЮС то, что отняла трещина, и растения ходили
#  по нему.
#
#  ОТСЮДА РАСТЕНИЯ И ПОЛЕТЕЛИ. Трещина ВЫЧИТАЕТ из поля, значит спокойное поле
#  ВЫШЕ настоящего, и его половинный уровень проходит СНАРУЖИ камня. Растение
#  садилось на него и висело над скалой ровно на глубину трещины — замерено, 32
#  см в среднем и до 92. Пока трещины были мелкими, этого не было видно; стоило
#  углубить их вдвое, и мох повис в воздухе (кадр пользователя 31.08.2026).
#
#  Беда неисправима по устройству: любая поверхность, кроме настоящей, будет
#  где-то снаружи камня. Поэтому растения снова ходят по настоящей — а трещины
#  теперь и не те, из-за которых всё затевалось: тогда они были ложбинами в два
#  с половиной метра, куда лоза ныряла целиком, а сейчас редкие и пологие.
#
#  Ход оставлен на месте (`calm: bool` в запросах, `crack_cut` в сетке): если
#  трещины когда-нибудь снова станут глубокими щелями, спокойное поле понадобится
#  — но брать с него надо будет РЕШЕНИЕ, а не место.
func _fv(index: int, calm: bool) -> float:
	if not calm or index >= crack_cut.size():
		return fill[index]
	return fill[index] + crack_cut[index]


# Поверхность для растений. Ход через отдельное имя оставлен нарочно: место, где
# решается, по какой поверхности ходят растения, должно быть ОДНО.
func calm_surface_near(p: Vector3) -> Dictionary:
	return surface_near(p, false)


func calm_surface_gap(p: Vector3) -> float:
	return surface_gap(p, false)


# ВЫПУКЛОСТЬ: насколько ячейка выпирает над тем, что предсказывают соседи
# ВМЕСТЕ С НАКЛОНОМ. Плюс — сидит в ямке, минус — торчит бугром.
#
# «Разница со средним по соседям» для этого НЕ ГОДИТСЯ, хотя её и просит
# здравый смысл. Семена разбросаны, шесть соседей стоят вокруг несимметрично, и
# на ИДЕАЛЬНО РОВНОМ склоне их среднее не равно самой ячейке. Замерено: промах
# 0.126 доли поля в среднем и 0.43 в худшем случае — это 8 см поверхности, а
# худшее 29 см при ячейке 67 см.
#
# Хуже всего, что промах у каждого семени СВОЙ И ВСЕГДА ОДИН И ТОТ ЖЕ: он не
# размазывается повторами, а копится, пока не упрётся. Кисть сглаживания от
# этого скатывалась не к гладкости, а к постоянной мятости: восемь проходов ещё
# помогали, тридцать уже нет, девяносто возвращали хуже, чем было.
#
# Вычитая наклон, оставляем ровно кривизну — то, что кисть и должна снимать, а
# впадина показывать. На ровном склоне выходит ноль, как и положено.
#
# `from_edits` — считать по правкам игрока (растушёвка мазка) или по всему полю.
func bulge_at(index: int, from_edits: bool = false) -> float:
	var here: Vector3 = seeds[index]
	var f0: float = float(edits.get(index, 0.0)) if from_edits else fill[index]
	var raw := Vector3.ZERO
	var away := Vector3.ZERO      # куда в среднем смещены соседи
	var sum := 0.0
	var count := 0
	var at := index * 6
	for k in range(6):
		var s: int = nb_table[at + k]
		if s < 0:
			continue
		var d: Vector3 = seeds[s] - here
		var len2: float = d.length_squared()
		if len2 < 0.000001:
			continue
		var df: float = (float(edits.get(s, 0.0)) if from_edits else fill[s]) - f0
		raw += d * (df / len2)
		away += d
		sum += df
		count += 1
	if count == 0:
		return 0.0
	return (sum - straighten(index, raw).dot(away)) / float(count)


# ГДЕ РЯДОМ С ТОЧКОЙ ПРОХОДИТ ЗЕМЛЯ. Нужно всему, что на земле живёт: растение
# садится не в ячейку, а в точку, и точку эту надо посадить ровно на уровень.
#
# Поле у семени продолжаем его наклоном: до половинного уровня по прямой
# остаётся ровно (заполнение − половина), делённое на крутизну. Шага хватает
# двух — после первого точка уже у поверхности, второе семя её уточняет.
#
# Считаем ПОЛЕМ, а не лучом по телу столкновений: луч можно пускать только в
# такт физики, а рост растений идёт своим ходом и в проверке — вообще без окна.
#
# ПОЧЕМУ НЕ НАШЛОСЬ — пишем в `near_why`. Отказ бывает по пяти разным причинам, и
# по одному числу отказов не видно, какая из них работает; а работать может
# ошибочно. Спрашивать сразу после отказа.
const NEAR_OK: int = 0
const NEAR_OUT: int = 1              # ячейки нет или она вне игры
const NEAR_FLAT: int = 2             # поле ровное, спускаться некуда
const NEAR_LEVEL: int = 3            # поле у семени далеко от уровня земли
const NEAR_FAR: int = 4              # ушли от точки дальше полутора ячеек
const NEAR_FACET: int = 5            # не села на срез
const NEAR_NAMES := ["село", "вне игры", "поле ровное", "поле не у уровня",
	"ушло далеко", "мимо среза"]
var near_why: int = 0

func surface_near(p: Vector3, calm: bool = false) -> Dictionary:
	var at := p
	var j: int = -1
	near_why = NEAR_OK
	for _step in range(3):
		j = cell_at(at)
		if j < 0 or not in_play(j):
			near_why = NEAR_OUT
			return {}
		var g: Vector3 = field_slope(j, calm)
		var mag2: float = g.length_squared()
		if mag2 < 0.0000001:
			near_why = NEAR_FLAT
			return {}
		var here: float = _fv(j, calm) + g.dot(at - seeds[j])
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
		near_why = NEAR_OUT
		return {}
	var n: Vector3 = field_slope(j)
	if n.length_squared() < 0.0000001:
		near_why = NEAR_FLAT
		return {}
	# ПРОВЕРЯЕМ, ЧТО ПРИШЛИ. Поле у семени продолжается прямой, и если точка
	# села далеко от него, значит прямую продолжили за пределы, где она верна:
	# такому месту верить нельзя, лучше признать, что земли рядом нет.
	#
	# МЕРИТЬ НАДО РАССТОЯНИЕМ, А НЕ САМИМ ПОЛЕМ. Прежде здесь стояло «доля поля у
	# семени не дальше половины от уровня» — и это порог по величине, поставленный
	# без оглядки на её размах, ровно те грабли, что уже записаны. Размах у поля
	# СВОЙ В КАЖДОМ МЕСТЕ: на ровной земле оно переходит от нуля к единице за пару
	# ячеек, а камень поднимает его больше чем на единицу за одну. Оттого у камня
	# ближайшее семя почти всегда оказывалось «далеко от уровня», и посадка
	# отказывала там, где земля прекрасно видна.
	#
	# Наклон переводит долю поля в метры: сколько до уровня идти. Полторы ячейки —
	# та же мерка, что и у ухода от точки ниже.
	if absf(_fv(j, calm) - SOLID_AT) / n.length() > _spacing * 1.5:
		near_why = NEAR_LEVEL
		return {}
	if at.distance_to(p) > _spacing * 1.5:
		near_why = NEAR_FAR
		return {}
	# И ТОЛЬКО ТЕПЕРЬ — НА САМУ ПОВЕРХНОСТЬ. Всё выше было приближением по
	# наклону; последний шаг сажает точку на срез того же поля, по которому
	# режется картинка. Без него растение сидело рядом с землёй, а не на ней.
	var exact: Dictionary = _snap_to_facet(at, j, calm)
	if exact.is_empty():
		near_why = NEAR_FACET
		return {}
	at = exact["pos"]
	j = exact["cell"]
	if at.distance_to(p) > _spacing * 1.5:
		near_why = NEAR_FAR
		return {}
	n = field_slope(j)
	if n.length_squared() < 0.0000001:
		near_why = NEAR_FLAT
		return {}
	return {"pos": at, "nrm": -n.normalized(), "cell": j}


# ТОЧНАЯ ПОСАДКА НА ТУ САМУЮ ПОВЕРХНОСТЬ, КОТОРУЮ ВИДНО.
#
# Выше поле продолжалось от семени ПРЯМОЙ. Рисуется поверхность иначе: восьмёрка
# семян делится на шесть тетраэдров, и внутри каждого поле считается линейным ПО
# ЧЕТЫРЁМ УГЛАМ. Это две разные поверхности. На ровном месте они совпадают, а на
# гребне расходятся: там наклон у семени усреднён по соседям с обеих сторон
# перегиба, и прямая проходит то выше среза, то ниже. На кадре это был мох,
# парящий над хребтом и тонущий в склоне.
#
# Здесь точка досаживается на срез ТОГО ЖЕ линейного поля, что режет картинку, —
# значит, ложится ровно на треугольник, а не рядом с ним.
#
# Кубик ищем среди восьми, что сходятся в узле ближайшего семени: дальше точка
# уйти не могла. Кубики БЕЗ СРЕЗА пропускаем — поверхности в них нет вовсе, и
# сесть там не на что. Если ни один не подошёл, земли рядом ПРОСТО НЕТ: пусть
# растения там не будет, чем оно повиснет в воздухе.
func _snap_to_facet(at: Vector3, home: int, calm: bool = false) -> Dictionary:
	var node: Vector3i = node_of(home)
	var idx := PackedInt32Array()
	idx.resize(8)
	var val := PackedFloat32Array()
	val.resize(8)
	var best_room: float = -INF
	var best: Vector3 = at
	var found := false
	for bx in range(-1, 1):
		for by in range(-1, 1):
			for bz in range(-1, 1):
				var base := node + Vector3i(bx, by, bz)
				var ok := true
				var below := 0
				for c in range(8):
					var s: int = node_seed(base + SurfaceGeo.CORNER[c])
					if s < 0:
						ok = false
						break
					idx[c] = s
					val[c] = _fv(s, calm)
					if val[c] <= SOLID_AT:
						below += 1
				if not ok or below == 0 or below == 8:
					continue
				for t in SurfaceGeo.TETS:
					var p0: Vector3 = seeds[idx[t[0]]]
					var e1: Vector3 = seeds[idx[t[1]]] - p0
					var e2: Vector3 = seeds[idx[t[2]]] - p0
					var e3: Vector3 = seeds[idx[t[3]]] - p0
					# Обратная тройка: одним набором считаем и «внутри ли точка»,
					# и наклон линейного поля. Определитель — шестикратный объём.
					var c1: Vector3 = e2.cross(e3)
					var det: float = e1.dot(c1)
					if absf(det) < 0.000001:
						continue
					var c2: Vector3 = e3.cross(e1)
					var c3: Vector3 = e1.cross(e2)
					var v: Vector3 = at - p0
					var l1: float = v.dot(c1) / det
					var l2: float = v.dot(c2) / det
					var l3: float = v.dot(c3) / det
					# Насколько точка ВНУТРИ: у своего тетраэдра все четыре доли
					# неотрицательны. Берём лучший — на границе годятся оба.
					var room: float = minf(minf(l1, l2), minf(l3, 1.0 - l1 - l2 - l3))
					if room <= best_room:
						continue
					var f0: float = val[t[0]]
					var g: Vector3 = (c1 * (val[t[1]] - f0) + c2 * (val[t[2]] - f0)
						+ c3 * (val[t[3]] - f0)) / det
					var mag2: float = g.length_squared()
					if mag2 < 0.0000001:
						continue
					best_room = room
					best = at - g * ((f0 + g.dot(v) - SOLID_AT) / mag2)
					found = true
	# Далеко за своим тетраэдром или далеко от точки — значит, попали не в тот
	# срез, а в чужой по соседству. Такому месту верить нельзя.
	if not found or best_room < -0.35 or best.distance_to(at) > _spacing * 0.6:
		return {}
	var cell: int = cell_at(best)
	if cell < 0 or not in_play(cell):
		return {}
	return {"pos": best, "cell": cell}


# НА СКОЛЬКО ТОЧКА ОТОРВАЛАСЬ ОТ ВИДИМОЙ ЗЕМЛИ, в метрах. Меньше нуля — земли
# рядом нет вовсе.
#
# Нужно самопроверке: парящий мох видно на кадре, а я кадров не сужу — значит,
# у этого должно быть число. Меряем тем же срезом, по которому режется картинка,
# поэтому промах здесь — это ровно тот зазор, который видит глаз.
func surface_gap(p: Vector3, calm: bool = false) -> float:
	var j: int = cell_at(p)
	if j < 0:
		return -1.0
	var snapped: Dictionary = _snap_to_facet(p, j, calm)
	if snapped.is_empty():
		return -1.0
	return p.distance_to(snapped["pos"])


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
		var sum: float = cavity[i]
		var count := 1
		for k in range(6):
			var s: int = nb_table[i * 6 + k]
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
# Насколько краска камня уже мазка ПОПЕРЁК. По высоте она идёт во всю ширину
# мазка: подкопавший игрок должен увидеть на срезе камень, а не землю.
const STONE_WAIST: float = 0.78


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
	# ПРАВКА, КОТОРУЮ МАЗОК И ПРАВДА ПОЛОЖИЛ — по массе и по каменистости порознь.
	#
	# Прежде отмена ПОВТОРЯЛА мазок с обратным знаком, и это связывало руки: всё,
	# что зависит от нынешнего состояния (а земля на камне и быстрая смена породы
	# зависят), при повторе считалось бы уже от ДРУГОГО состояния и не сходилось
	# бы. Замерено на первой же попытке: после отмены оставалось 0.967 поля и
	# 1.396 каменистости вместо нулей.
	#
	# Теперь мазок запоминает, что именно он прибавил, а отмена это вычитает —
	# ровно так, как давно сделано у размывания («заново их не вычислить»).
	last_edit_delta = {}
	last_stone_delta = {}
	# Где доля породы сдвинулась. По этому набору обновляется обёртка складок —
	# и только по нему: мазок земли по чистой земле не двигает её ни на волос.
	var hot: Dictionary = {}
	# МАЗОК КАМНЯ ЗАВОДИТ СВОЮ ГЛЫБУ — или прибавляется к той, что уже здесь.
	#
	# УСЛОВИЕ ИМЕННО ТАКОЕ, И ЭТО НЕ ПРИДИРКА. Сперва стояло «мазок трогает
	# каменистость», то есть `stone_push != 0`. Но её трогает и МАЗОК ЗЕМЛИ —
	# он уводит камень прочь, и знак у него минус при положительной прибавке.
	# Выходило, что земляной мазок заводил каменную глыбу, а снятие её не
	# уносило (снятие ничего не красит, у него знак ноль). Проверка отмены это
	# и поймала: после трёх мазков и трёх отмен оставалась живая глыба.
	#
	# Произведение знаков отвечает на верный вопрос — «этот мазок КЛАДЁТ камень
	# или УНОСИТ ранее положенный»: плюс у мазка камня и у отмены такого мазка,
	# минус у мазка земли и у его отмены.
	var cut := PackedVector3Array()
	if stone_push * amount > 0.0:
		var lump: int = _claim_lump(point, radius, amount)
		if lump >= 0 and use_blocks:
			cut = lumps[lump]["cut"]
	var span := int(ceil(radius / _cell_size)) + 1
	var base := _key_of(point)
	for dx in range(-span, span + 1):
		for dy in range(-span, span + 1):
			for dz in range(-span, span + 1):
				var key := base + Vector3i(dx, dy, dz)
				if not _seed_hash.has(key):
					continue
				for j in _seed_hash[key]:
					var off: Vector3 = seeds[j] - point
					# У КАМНЯ УРОВНИ МНОГОГРАННЫЕ, У ЗЕМЛИ ШАРОВЫЕ. Насыпь и
					# должна быть круглой; гранёной должна быть глыба. См.
					# `_block_planes` — там же, почему это единственный способ
					# получить настоящие грани, а не рябь поверх купола.
					var d: float = off.length() / radius
					if not cut.is_empty():
						# ГЛЫБА ОБРЕЗАНА КРУГОМ КИСТИ. У многогранника вершина
						# отстоит от середины много дальше грани, и замер это
						# поймал: масса доходила до 1.0 радиуса, а краска камня
						# — до 2.14. То есть мазок выходил за свои границы вдвое,
						# и вокруг глыбы ложилось серое там, где камня не клали.
						#
						# Берём наибольшее из двух: где торчит вершина, её
						# срезает круг; грани при этом целы, потому что они и так
						# внутри круга. Кисть снова обещает ровно то, что делает.
						d = maxf(_block_dist(off, cut), d)
					if d >= 1.0:
						continue
					# ПРОФИЛЬ МАЗКА — ПЛОСКОЕ ЯДРО И ДЛИННАЯ ЮБКА, и это не вкус.
					#
					# Клинья у подошвы глыбы делает НЕ огранка: выключи и складки,
					# и пласты — в поясе, где клин сидит, резких рёбер остаётся
					# столько же. Их делает сама масса, и ровно на КРАЮ КИСТИ:
					# самые острые рёбра сидят в 2.5–3.5 м от середины мазка при
					# радиусе 3.27.
					#
					# Почему. Там масса мазка сходит на нет и стыкуется с
					# нетронутой землёй. У прежнего профиля `(1−d²)²` она у края
					# набирает высоту быстрее, чем земля успевает повернуть:
					# двенадцать мазков в одно место дают 0.4 поля на 0.33 м —
					# круче собственного наклона земли. Стык укладывается в
					# полметра, то есть МЕНЬШЕ ЯЧЕЙКИ, и решётка отдаёт его
					# ребром. Та же болезнь, что была у обёртки складок и у
					# ступеньки пластов: крупная форма с мелким краем.
					#
					# Замерено на глыбе из кадра, по ВЫПУКЛЫМ рёбрам круче 45° —
					# это и есть клинья:
					#   (1−d²)²   — 0.79%, худшее 65.8°, p99 50.4°
					#   юбка^0.75 — 0.53%, худшее 55.2°
					#   юбка^0.5  — 0.28%, худшее 57.0°, p99 40.9°
					# На голой массе, без складок и пластов, — 0.33% против
					# 0.14%: профиль чинит именно то, чего огранка не касалась.
					#
					# МНОЖИТЕЛЬ 0.616 — НЕ ПОДГОНКА, А РАВЕНСТВО МАССЫ. Юбка
					# шире, и без него мазок клал бы в полтора раза больше
					# породы: сравнивать пришлось бы разные глыбы. С ним глыба
					# из тех же мазков выходит той же — 488 ячеек против 486.
					#
					# `stroke_reach` УКОРАЧИВАЕТ ЮБКУ, не меняя её вида: мазок
					# кончается раньше края кисти. Просили именно этого — чтобы
					# мазок не выходил так сильно за свои границы. Плата
					# известна и записана выше: стык с нетронутой землёй
					# укладывается в меньшее расстояние, и клинья возвращаются.
					# Сколько именно — меряет стенд (`--rockbench --skirt=`).
					var t: float = d / stroke_reach
					if t >= 1.0:
						continue
					var w: float = sqrt(1.0 - smoothstep(0.0, 1.0, t)) * 0.616
					# ЗЕМЛЯ НА КАМНЕ ЛОЖИТСЯ ТОНКИМ СЛОЕМ, А НЕ КУЧЕЙ — решение
					# пользователя: «впадина камня заполняется слоем земли
					# небольшой толщины».
					#
					# Так оно и в природе: в трещину и в чашу на скале наносит
					# горсть земли, и она там держится, а насыпать на камне
					# холм неоткуда. Без этого правила земля на глыбе росла
					# теми же мазками, что и на лугу, и вместо кармана с
					# почвой выходил ком, налепленный сверху.
					#
					# Убавляем только МАССУ. Краска идёт полной силой, чтобы
					# смена породы была видна сразу.
					if stone_push < 0.0:
						w *= 1.0 - 0.75 * stone_of(j)
					var add: float = amount * w
					edits[j] = float(edits.get(j, 0.0)) + add
					last_edit_delta[j] = float(last_edit_delta.get(j, 0.0)) + add
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
						# КРАСКА ЖМЁТСЯ ВБОК, НО НЕ ВГЛУБЬ. Мазок — шар, и до
						# сих пор каменистость расходилась в нём одинаково во
						# все стороны. Вбок это мажет породой ровное место
						# вокруг глыбы, и она перестаёт читаться отдельным
						# телом; вглубь наоборот нужно, иначе подкопавший
						# игрок увидит на срезе землю.
						#
						# Считаем расстояние сплюснутым: поперёк туже, по
						# высоте как было.
						#
						# У ГЛЫБЫ ЖЕ КРАСКА ИДЁТ ПО САМОЙ ГЛЫБЕ. Пояс тут не
						# нужен вовсе: тело и так кончается гранью, а не сходит
						# на нет во все стороны, и красить надо ровно его.
						var sw: float = 0.0
						if not cut.is_empty():
							sw = 1.0 - minf(d * d, 1.0)
						else:
							var flat: float = (off.x * off.x + off.z * off.z) \
								/ (radius * radius * STONE_WAIST * STONE_WAIST)
							var tall: float = off.y * off.y / (radius * radius)
							sw = 1.0 - minf(flat + tall, 1.0)
						# ОХВАТ ТОТ ЖЕ, СЕРДЦЕВИНА ПЛОТНЕЕ. Раньше каменистость
						# шла ровно тем же профилем, что и масса (`w*w`), — и
						# это правильно по охвату: шире массы она ложилась серым
						# на ровное место вокруг глыбы, «покрашено камнем»
						# вместо «лежит камень».
						#
						# Но у того же профиля тонкий низ: у подошвы мазка
						# каменистость выходила около половины, ровно на пороге,
						# по которому шейдер отличает породу от земли. Подкопав
						# глыбу, игрок видел на срезе землю. Здесь профиль
						# по-прежнему обращается в ноль на самом краю мазка —
						# наружу не расползается ничего, — но внутри набирает
						# полную силу заметно раньше.
						var was: float = stone_of(j)
						var had: float = float(stone.get(j, 0.0))
						var step_s: float = absf(amount) \
							* smoothstep(0.0, 0.45, sw) * 1.9
						# СМЕНА ПОРОДЫ ВИДНА СРАЗУ — решение пользователя: «когда
						# меняется кисть и используется на другой породе, то
						# результат виден сразу же».
						#
						# ОТЧЕГО НЕ БЫЛО ВИДНО. Каменистость — это НЕОБРЕЗАННЫЙ
						# счёт положенного, и запас у него большой (24) ради
						# точной отмены. Полепив камень, игрок загонял счёт к
						# шести-восьми, а один мазок земли отнимал около двух:
						# чтобы перевалить за половину, по которой шейдер и
						# отличает породу, требовалось три-четыре мазка. Первый
						# не делал ВИДИМО ничего, и рука не понимала, работает
						# ли кисть.
						#
						# Лечим так: пока счёт по ТУ сторону от нуля, чем мы
						# красим, — гасим его быстро, вдвое против обычного шага
						# и без оглядки на то, сколько там накопилось. Как
						# только знак сошёлся с кистью, всё идёт как прежде.
						# Отмена при этом точна по-прежнему: в правку кладётся
						# ровно та величина, что применилась.
						# Накопленное ПРОТИВОПОЛОЖНОЙ кистью не спорит с нынешней,
						# а сбрасывается: один мазок земли по камню сразу даёт
						# землю, а не «на два меньше камня».
						#
						# ГРАБЛИ, СВОИ ЖЕ. Сперва я гасил счёт вдвое быстрым
						# шагом, но с упором в ноль — и первый мазок только
						# стирал прежнее, не кладя своего. Смена породы от этого
						# стала не быстрее, а на шаг МЕДЛЕННЕЕ, и в самопроверке
						# мох осел с 98 кочек до 19: массив набирался иначе, мох
						# сеялся теснее, и один снос убивал впятеро больше.
						# БЫСТРОЙ СМЕНЫ ПОРОДЫ ЗДЕСЬ НЕТ, И ЭТО РЕШЕНИЕ ПО ЗАМЕРУ.
						#
						# Просили, чтобы смена кисти была видна сразу (кадр
						# 31.08.2026), и я сделал: накопленное противоположной
						# кистью сбрасывалось в ноль, чтобы один мазок земли по
						# камню сразу давал землю. Работало — и ломало мир.
						#
						# Сброс срабатывал не только под курсором, но и на ЮБКЕ
						# мазка, где чужой краски десятые доли. Массив от этого
						# набирал камень шире и быстрее, мху оставалось меньше
						# земли, и в самопроверке он осел с 98 кочек до 13.
						# Изолировано опытом порознь: выключишь сброс — 98
						# возвращаются; выключишь тонкий слой земли — остаётся 13.
						# Порог «сбрасывать только там, где чужое видно» (|had| >
						# 0.5) не помог: 13.
						#
						# ЧТО ДЕЛАТЬ ВМЕСТО. Беда не в самой мысли, а в том, что
						# счёт каменистости копится без предела (запас 24) — он и
						# был велик ради точной отмены. Теперь отмена идёт по
						# ЗАПИСАННОЙ правке и предела больше не боится, значит
						# счёт можно честно ограничить парой единиц. Тогда смена
						# породы уложится в один-два мазка сама собой, без
						# особого правила. Это следующий заход, и мерить его надо
						# тем же мхом.
						var from_s: float = had
						stone[j] = clampf(from_s + step_s * stone_push,
							-STONE_ROOM, STONE_ROOM)
						last_stone_delta[j] = float(last_stone_delta.get(j, 0.0)) \
							+ (float(stone[j]) - had)
						# Запоминаем только ТЕ ячейки, где доля породы и правда
						# сдвинулась. Величина хранится необрезанной, и на
						# насыщенной сердцевине глыбы (или на чистой земле,
						# куда мазок земли уводит камень «ещё дальше в минус»)
						# счёт растёт, а доля стоит на месте. Обёртке складок
						# от такого мазка ничего не грозит.
						if absf(stone_of(j) - was) > 0.0001:
							hot[j] = true
					touched[j] = true

	# Сглаживаем не только сам мазок, но и КОЛЬЦО вокруг него. Пока сглаживание
	# шло лишь по задетым ячейкам, соседи за краем мазка не менялись никогда:
	# на границе копился уступ, и от повторных наращиваний холм набирал
	# угловатость. С кольцом мазок растушёвывается в окружающий рельеф.
	# Кольцо берём узкое — только шесть прямых соседей. По всем двадцати шести
	# диффузия расползалась заметно дальше мазка и подъедала соседние формы.
	var zone: Dictionary = touched.duplicate()
	for j in touched:
		for k in range(6):
			var n: int = nb_table[int(j) * 6 + k]
			if n >= 0:
				zone[n] = true

	# Растушёвка идёт ПО ВЫПУКЛОСТИ, а не к среднему по соседям. Со средним она
	# на всяком склоне подсыпала каждому семени свой постоянный промах — и чем
	# дольше держали кисть, тем угловатее выходила насыпь. По выпуклости на
	# ровном склоне не делается ничего, а острия снимаются.
	var mixed: Dictionary = {}
	for j in zone:
		# Камень ДЕРЖИТ ФОРМУ: к соседям он подтягивается впятеро слабее земли,
		# поэтому граница глыбы с травой остаётся чёткой, а не расплывается,
		# как насыпь.
		var soft: float = lerpf(RELAX, RELAX * 0.2, stone_of(j))
		mixed[j] = float(edits.get(j, 0.0)) + bulge_at(j, true) * soft
	for j in mixed:
		edits[j] = mixed[j]

	# Обёртку складок пересчитываем ДО поля: поле её и спрашивает.
	if not hot.is_empty():
		_refresh_stone_soft_round(hot)
	# И швы между глыбами — тоже ДО поля, и по той же причине. Ширим на кольцо:
	# обёртка только что изменилась и у соседей за краем мазка.
	var edge: Dictionary = _grown(zone)
	for j in edge:
		_refresh_seam(int(j))

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
	# Кольцо уже посчитано выше, для швов, — второй раз его не строим.
	var seen: Dictionary = edge
	if _batching:
		# ОБСТАНОВКА ОСТРОВА КЛАДЁТ ДЕСЯТКИ МАЗКОВ ДРУГ НА ДРУГА, и каждый из них
		# заново пересчитывал впадину, разглаживание и затенение по всей своей
		# округе — по той же самой округе, что и предыдущий. Игроку это нужно
		# сразу (он смотрит на результат), а расстановке — один раз в конце.
		for j in seen:
			_batch[j] = true
		return zone.keys()
	for j in seen:
		_refresh_cavity(j)
	_smooth_cavity(seen.keys())
	_refresh_shade_round(seen)
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

	# Считаем ПО ИСХОДНОМУ полю, до правок: если менять на ходу, ячейки в начале
	# списка сглаживаются по уже сглаженным соседям, и кисть тянет рельеф в
	# сторону обхода.
	var delta: Dictionary = {}
	for j in inside:
		var add: float = bulge_at(j) * strength * float(inside[j])
		if absf(add) > 0.0005:
			delta[j] = add

	apply_delta(delta, 1.0)
	return delta


# Прибавляет к правкам готовый список — им ходят и размывание, и его отмена
# (с обратным знаком).
# `stone_delta` — что мазок сделал с каменистостью. У размывания его нет, оно
# породы не трогает; у мазка есть всегда.
func apply_delta(delta: Dictionary, sign: float,
		stone_delta: Dictionary = {}) -> Array:
	var zone: Dictionary = {}
	for j in delta:
		edits[j] = float(edits.get(j, 0.0)) + float(delta[j]) * sign
		# Порог выброса ЗДЕСЬ МЕЛЬЧЕ, чем у лепки, и это не придирка. Кисть
		# размывания обязана отменяться в точности — иначе за отменой нечем
		# восстановить, сколько она сняла. А выброс несимметричен: ячейку с
		# 0.001 мы забываем, и обратный проход вычитает свою прибавку уже не из
		# 0.001, а из нуля. При пороге лепки (0.002) прибавки кисти как раз в
		# него и попадали: после отмены оставалось 0.0023.
		if absf(float(edits[j])) < 0.0002:
			edits.erase(j)
		zone[j] = true
	# КАМЕНИСТОСТЬ ВОЗВРАЩАЕМ ТОЧНО ТАК ЖЕ. Порог выброса тот же и по той же
	# причине: забудь ячейку с ничтожным остатком — и обратный проход вычтет
	# свою прибавку уже не из него, а из нуля.
	var hot: Dictionary = {}
	for j in stone_delta:
		var left: float = float(stone.get(j, 0.0)) + float(stone_delta[j]) * sign
		if absf(left) < 0.0002:
			stone.erase(j)
		else:
			stone[j] = left
		hot[int(j)] = true
		zone[j] = true
	if not hot.is_empty():
		_refresh_stone_soft_round(hot)
	# ПОЛЕ ПЕРЕСЧИТЫВАЕМ ПО КОЛЬЦУ, А НЕ ТОЛЬКО ПО ПРАВКЕ.
	#
	# ГРАБЛИ, свои же и дорогие. Сперва я обновлял поле лишь у тех ячеек, что
	# попали в правку. Но `_facet` считается от РАЗГЛАЖЕННОЙ каменистости, а она
	# меняется и у соседей — у них поле оставалось несвежим, и мир после отмены
	# тихо расходился с миром до мазка. Мазок так не делает: он пересчитывает
	# поле по кольцу вокруг задетого.
	#
	# Видно это было не по камню (там всё сходилось), а по мху: в самопроверке
	# он осел с 98 кочек до 13, потому что снос земли под кочкой попадал на
	# чуть другую поверхность и убивал впятеро больше соседок.
	var seen: Dictionary = zone.duplicate()
	for j in zone:
		for k in range(6):
			var n: int = nb_table[int(j) * 6 + k]
			if n >= 0:
				seen[n] = true
	for j in seen:
		fill[j] = base_fill[j] + _edit_of(j) + _facet(j)
	for j in seen:
		_refresh_cavity(j)
	_smooth_cavity(seen.keys())
	_refresh_shade_round(seen)
	return zone.keys()


# ВОССТАНОВЛЕНИЕ СОХРАНЁННОГО САДА. Снимок — это три вещи, которых не
# пересчитать из зерна: правки поля, каменистость и глыбы. Всё производное
# (обёртка складок, швы, поле, впадина, тени) пересчитывается здесь же, тем же
# порядком, каким идёт живой мазок: обёртка → швы → поле → впадина. Порядок не
# вкусовой — поле спрашивает и обёртку, и швы, посчитай его раньше — мир
# тихо разойдётся с тем, что сохраняли.
func restore_state(ed: Dictionary, st: Dictionary, lu: Array) -> Array:
	edits = ed.duplicate()
	stone = st.duplicate()
	lumps = lu.duplicate(true)
	_lump_hash.clear()
	for i in range(lumps.size()):
		var key: Vector3i = _lump_key(lumps[i]["pos"])
		if not _lump_hash.has(key):
			_lump_hash[key] = []
		_lump_hash[key].append(i)
	var zone: Dictionary = {}
	for j in edits:
		zone[int(j)] = true
	for j in stone:
		zone[int(j)] = true
	if zone.is_empty():
		return []
	# Обёртка складок разглаживается на ДВА кольца от правки — значит, и поле
	# надо освежить настолько же широко, иначе на дальнем кольце оно остаётся
	# со старой огранкой (та самая грабля из `apply_delta`, только шире).
	var edge: Dictionary = _grown(_grown(_grown(zone)))
	_refresh_stone_soft_round(zone)
	for j in edge:
		_refresh_seam(int(j))
	for j in edge:
		fill[j] = base_fill[j] + _edit_of(j) + _facet(j)
	for j in edge:
		_refresh_cavity(j)
	_smooth_cavity(edge.keys())
	_refresh_shade_round(edge)
	return edge.keys()


# ОГРАНЁННОСТЬ КАМНЯ. К полю возле камня добавляется крупный шум: поверхность
# набирает широкие плосковатые грани и складки, как у окатанных глыб на
# снимках. Шипов от этого быть не может — это плавная величина, а не отдельные
# тела; резкость даёт только частота, и она нарочно низкая.
#
# И ЭТО БЫЛО НЕПРАВДОЙ, ПОКА СКЛАДКИ УМНОЖАЛИСЬ НА СЫРУЮ КАМЕНИСТОСТЬ. Частота
# у волны и правда низкая — доли 9.4 и 5.4 ячейки. Но волну умножают на
# ОБЁРТКУ, а сырая каменистость падает с единицы до нуля меньше чем за полторы
# ячейки: краска кладётся мазком и обрезается в единицу, оттого кайма выходит
# совсем узкой. Медленная волна на быстрой обёртке — быстрый сигнал, и решётка
# отдаёт его шипами. Отсюда и брались чёрные клинья у подошвы: грань,
# смотрящая вниз, света не получает.
#
# Замерено на глыбе из кадра (4 колонны по 4 уровня, 48 мазков широкой кистью),
# по доле рёбер круче 45°:
#   доля породы 0.8…1.0, тело глыбы  — 0.7%  (без складок вовсе 0.0%)
#   доля породы 0.4…0.6, кайма       — 14.0% (без складок вовсе 2.2%)
# На теле складки почти безвредны. Они сходят с ума ровно в кайме, где камень
# переходит в землю, и там вшестеро умножают резкость.
#
# ПОЭТОМУ ОБЁРТКУ БЕРЁМ РАЗГЛАЖЕННУЮ (`stone_soft`), а не сырую. Сила складок
# на теле глыбы при этом не меняется вовсе — там каменистость и так единица;
# меняется только то, как быстро они гаснут к краю. По всей глыбе: резких рёбер
# 2.76% → 1.40%, худшее ребро 89.7° → 74.5°, граней, смотрящих вниз, 40 → 9.
#
# ЦВЕТ ПО-ПРЕЖНЕМУ БЕРЁТ СЫРУЮ. Резкий край породы нужен и сделан нарочно —
# разглаживать надо было не границу камня, а обёртку складок.
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
# СИЛУ ПРИШЛОСЬ УБАВИТЬ ПОСЛЕ ТОГО, КАК ОКРЕПЛА КАМЕНИСТОСТЬ. Огранка считается
# от неё В КВАДРАТЕ, и когда каменистость на глыбе поднялась с 0.87 до 1.0, всё
# здесь усилилось в 1.3 раза само собой — а замер безопасности делался до того.
# Пользователь увидела на кадре ножевые рёбра.
#
# Замерено на связке из четырёх глыб (доля рёбер круче 45° и худшее ребро):
#   голая масса, без огранки — 0.6%, худшее 71.9°
#   2.4 и 0.40 (было)        — 1.6%, худшее 78.3°
#   1.8 и 0.32               — 1.3%, худшее 73.0°
#   1.5 и 0.26 (стало)       — 0.9%, худшее 69.1°
# На 1.5 и 0.26 худшее ребро становится ДАЖЕ МЯГЧЕ, чем у голой массы: огранка
# перестаёт добавлять лезвия и только лепит форму. Если слои читаются слабо,
# следующая ступень вверх — 1.8 и 0.32, её числа тоже известны.
# НЕ `const` ТОЛЬКО ПОТОМУ, что стенд камня (`--rockbench`) крутит эти числа с
# ключа: подбор идёт десятками прогонов, и править ради каждого файл — мука.
# В игре они всегда те, что написаны здесь.
# СИЛА УБАВЛЕНА В ВОСЕМЬ РАЗ ПОСЛЕ ТОГО, КАК МАЗОК СТАЛ КЛАСТЬ МНОГОГРАННИК.
# Все числа выше добыты, когда камень клался ШАРОМ: тогда шум был единственным,
# что хоть как-то ломало гладкий купол, и его тянули до предела. Теперь грани у
# глыбы настоящие и плоские, а шум их ГНЁТ. Замерено на пробном массиве:
#   шум 0.6 с трещинами — 12 рёбер круче 90°, худшее 124°
#   шум 0.3 без трещин  — 0 шипов, плоских рёбер 41.4%
# Оставлено ровно столько, чтобы грань не была мёртво-ровной.
var facet_amp: float = 0.3

func _facet(index: int) -> float:
	var s: float = stone_soft[index]
	if s < 0.02 or _rock_noise == null:
		# Обнуляем и здесь: иначе у ячейки, с которой камень сняли, остался бы
		# старый вычет, и спокойная поверхность помнила бы трещину, которой нет.
		if index < crack_cut.size():
			crack_cut[index] = 0.0
		return 0.0
	var p: Vector3 = seeds[index]
	var high: float = clampf((p.y + 3.0) / 6.0, 0.0, 1.0)
	# ГЛЫБА СЛОЖЕНА ИЗ ДОЛЕЙ — крупных и средних. Крупная 6.25 м (9.4 ячейки),
	# средняя 3.6 м (5.4 ячейки). Обе КРУПНЕЕ четырёх ячеек, и это не запас
	# вкуса: мельче решётка не держит ничего, шум вырождается в дрожь по
	# ячейкам, то есть в шипы. Прежние доли были 1.2 и 2.7 ячейки — отсюда и
	# лезли острые пирамидальные грани у подножия глыб, где огранка сильнее
	# всего.
	var n1: float = _rock_noise.get_noise_3d(p.x, p.y, p.z)
	var n2: float = _rock_noise.get_noise_3d(p.x * 1.75, p.y * 1.75, p.z * 1.75)
	var n: float = n1 * 0.66 + n2 * 0.34
	# СТУПЕНЕК БОЛЬШЕ НЕТ. Они подтягивали значение к плато ради широких плоских
	# граней — но плато в ПОЛЕ не даёт плоскости на ПОВЕРХНОСТИ: срез идёт там,
	# где поле равно половине, и важно не плато, а наклон возле этого уровня.
	# Замерено: усиление огранки со ступеньками поднимало не складчатость, а
	# общую мятость, а худший угол между гранями доходил до 152°.
	#
	# Гладкий шум крупной доли даёт то, что просили: округлые доли, сросшиеся
	# боками, — глыба читается сложенной из камней. А ложбины между долями
	# ловит впадина, и по ним же садится зелень.
	var steep: float = _steepness(index)
	var out: float = n * s * s * (0.55 + 0.75 * high) * (0.6 + 0.6 * steep) * facet_amp
	out += _joints(p, s, base_fill[index] + _edit_of(index))
	if index < crack_cut.size():
		crack_cut[index] = _cut_here
	# ШОВ МЕЖДУ ГЛЫБАМИ, положенными разными мазками. Вычитание, а не прибавка:
	# выемка в пустоте ничего не создаёт, и её не нужно сторожить.
	out -= seam[index] * seam_deep * s * s
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


# СЛОИСТОСТЬ — ПЕРВОЕ ИЗ ТРЁХ СЕМЕЙСТВ ТРЕЩИН. Числа ниже добыты, когда
# семейство было одно и строго горизонтальное; они и остались за пластами. Как
# из одного семейства стало три и почему это не шум, написано у `_build_joints`.
#
# ПОЧЕМУ ЭТО РАБОТАЕТ, А СТУПЕНЬКИ ПО ШУМУ НЕ РАБОТАЛИ. Уровень — это
# ПЛОСКОСТЬ, а плоскость решётка держит ТОЧНО при любом разбросе семян: внутри
# тетраэдра поле линейно, и у линейного поля срез идеально плоский. Ступеньки
# же тянули к плато сам ШУМ, а плато в поле не даёт плоскости на поверхности —
# срез идёт по уровню половины, и важно не плато, а наклон возле него.
#
# ЧИСЛА ПО ЗАМЕРУ, не на глаз. Доля площади, севшей у полок, против мятости:
#   сила 0     — 39.6% у полок, излом 8.2°, шипов 2, худший угол 94°
#   сила 0.25  — 42.9%,         излом 7.8°, шипов 0, худший 83°
#   сила 0.40  — 47.3%,         излом 8.3°, шипов 0, худший 73°
#   сила 0.55  — 52.3%,         излом 9.2°, шипов 1, худший 93°
# На 0.40 колено: слои набраны, а мятости не прибавилось вовсе — поверхность
# даже чище исходной. Дальше начинает платить.
# ПЕРЕХОД МЕЖДУ ПОЛКАМИ — ТОЖЕ ЧАСТОТА, И ЕЁ ТОЖЕ НАДО ДЕРЖАТЬ НИЖЕ ПОРОГА.
# Занимал он 40% высоты пласта, то есть 1.3 м — две ячейки. Сам пласт крупный
# (3.3 м, 4.9 ячейки), а вот СТУПЕНЬКА между пластами укладывалась в две, и
# решётка отдавала её прорезями. Та же болезнь, что была у обёртки складок:
# крупная форма с мелким краем.
#
# Растянут вдвое, до 80% высоты (2.6 м, 4 ячейки — ровно порог), а сила поднята
# во столько же, чтобы слои не ослабли: тянет теперь так же сильно, но полого.
# Замерено на глыбе из кадра, по ВОГНУТЫМ рёбрам круче 45° — это и есть зубцы,
# выпуклые складки камню идут:
#   40% и 0.40 (было)   — 0.53% вогнутых, слоистость 0.31
#   0% (без пластов)    — 0.41%,          слоистость 0
#   80% и 0.40          — 0.40%,          слоистость 0.18 — слои осели вдвое
#   80% и 0.72 (стало)  — 0.26%,          слоистость 0.32
# Растянутый переход с поднятой силой ЛУЧШЕ, чем пласты вовсе убрать, и при
# этом слоистость на месте. Пик прибавки при этом даже ниже прежнего (0.36
# против 0.59): та же тяга, размазанная вдвое шире.
# Числа выше добыты при силе тяги 0.72 — она стояла, пока камень клался ШАРОМ.
# Теперь тяга живёт в `bed_pull` и убавлена до 0.3: см. там, почему.
const LEDGE_STEP: float = 3.3     # высота пласта, м — 4.9 ячейки
# Доля шага, за которую полка переходит в полку: по десятой с каждого края,
# значит сам переход занимает 80% шага. При шаге 3.3 м это 2.6 м — четыре
# ячейки, ровно порог, ниже которого решётка форму уже не держит.
const JOINT_EDGE: float = 0.10
# ШОВ. Полуширина в метрах. Уже ОДНОЙ ячейки решётка не удержит — вместо
# ложбины выйдет дрожь; это нижний предел, а не осторожность.
# Насколько шов утапливает поле. Единица поля двигает поверхность примерно на
# шаг решётки (0.67 м), значит 0.9 — это ложбина сантиметров в шестьдесят.
#
# ЧИСЛА ПО ЗАМЕРУ, на пробном массиве (доля рёбер круче 20° — выпуклых/вогнутых,
# худшее ребро того и другого знака, наибольшая впадина):
#   0    — 5.7/10.0, худш 39.6/63.3, впад 0.412  ← голая масса
#   0.9  — 10.0/14.8, худш 60.0/60.5, впад 0.535 ← стало
#   1.1  — 10.9/17.3, худш 81.8/60.4, впад 0.488
#   1.3  — 13.1/18.3, худш 129.8/69.2 — за 90°, поверхность выворачивается
# На 0.9 колено: заломы почти вдвое против голой массы, а худшее ВОГНУТОЕ ребро
# даже мягче исходного (60.5° против 63.3°) — новых зубцов не появилось вовсе.
#
# ВЫКЛЮЧЕНО ПОСЛЕ ПЕРЕХОДА НА МНОГОГРАННИК. Швы по трещинам делили гладкий
# купол — за неимением у него настоящих граней. Теперь грани настоящие, а шов
# режет их поперёк: замерено, с ним 17 рёбер круче 90° против нуля без него, и
# плоских рёбер 31.6% против 41.4%. Числа выше сохранены: они верны для шара и
# понадобятся, если многогранник когда-нибудь отменят.
# НАСКОЛЬКО ГЛУБОКО РЕЖЕТ ТРЕЩИНА. Величина большая нарочно: чтобы порода
# честно распадалась на тела, поле в щели должно уходить НИЖЕ половины, а не
# слегка проседать. Мелкие трещины берут от неё свою долю (см. `_crack_rank`).
# Замерено на массиве из кадра (глубина трещины против облика):
#   0    — заломов 7.7%, худш 78.7/69.2, шипов 0,  впадина 0.73
#   0.8  — 9.2%,  94.8/75.5,  шипов 1,  впадина 0.69
#   1.2  — 11.2%, 105.1/74.8, шипов 2,  впадина 0.77  ← стало
#   1.6  — 12.1%, 119.2/110.1, шипов 7
#   2.4  — 13.7%, 141.1/134.9, шипов 35 — поверхность выворачивается
# На 1.2 колено: заломов в полтора раза больше голой глыбы, а худшее ВОГНУТОЕ
# ребро даже мягче исходного (74.8° против 69.2° — в пределах разброса). Дальше
# идёт обвал: за 1.6 щели начинают резать сами себя.
var crack_deep: float = 2.2
# Полутолщина самой крупной трещины, м. Полторы ячейки: уже решётка не удержит,
# и вместо щели выйдет дрожь. Мелкие разряды тоньше во столько же раз.
# Замерено при шаге семейств 2.3 и 2.7 м (глубина 1.2):
#   0.55 — плоских 33.2%, заломов 11.9%, шипов 9,  впадина 0.77
#   0.70 — 36.1%,          12.3%,        шипов 4,  впадина 0.71  ← стало
#   0.85 — 36.3%,          11.0%,        шипов 4,  впадина 0.68
#   1.00 — 35.4%,          11.4%,        шипов 4,  впадина 0.66
# На 0.70 колено: заломов больше всего, впадина глубокая, а плоские грани ещё
# целы. Уже — трещина уходит под ячейку решётки, и шипы удваиваются.
# ДНО И СТЕНКА ТРЕЩИНЫ ПОРОЗНЬ. `crack_floor` — полуширина плоского дна
# (может быть сколь угодно узкой: решётка её не держит, но и не портит,
# потому что скат лежит снаружи); `crack_wall` — ширина ската, и вот она
# обязана быть не уже ячейки, иначе стенка вырождается в шип.
var crack_floor: float = 0.15
var crack_wall: float = 1.1
# Насквозь режущая трещина: своя полутолщина (просвет должен уложиться в две
# ячейки решётки) и своя сила. Ноль силы — крупные трещины ведут себя как
# прочие, то есть массив не расседается. См. `_joints`.
# ЗАМЕРЕНО И ВЫКЛЮЧЕНО. Чтобы прорезать шестиметровое тело, вычесть надо всё
# поле целиком (внутри оно доходит до шести), и на полутора метрах это наклон
# около 4 на метр при том, что решётка держит 1.5. Числа: при силе 1.0 массив
# ВСЁ РАВНО остаётся одним телом (653 ячейки против 723), зато шипов 43 против
# двух, а худшее вогнутое ребро 134° — поверхность выворачивается наизнанку.
#
# ВЫВОД, СТОИВШИЙ ДНЯ ЗАМЕРОВ: расколоть массив ПОЛЕМ нельзя вовсе. Просвет уже
# двух ячеек решётка не держит, а шире двух ячеек — это уже не трещина. Поэтому
# раскол показывают ЩЕЛИ С ТЕНЬЮ, а не настоящие просветы.
#
# Отдельные тела (файл `Rocks.gd`) тоже пробовались и УБРАНЫ по кадру
# пользователя: «вокруг него хаотично и на далёком расстоянии валяются
# инактивные тела камней». Разбросанный камень не помогал читать массив — он
# читался мусором рядом с ним. Вся работа теперь идёт по самой породе.
var crack_thru: float = 0.0
# Сила тяги к плоскости: порознь у пластов и у поперечных семейств.
#
# ПОТОЛОК ЗДЕСЬ НЕ ВКУСОВОЙ. Тяга у самой плоскости имеет наклон `сила/шаг
# решётки`, а у поля возле поверхности свой наклон — около 1.5 на метр.
# Сравняй одно с другим, и суммарный наклон обнулится, а перевали — и
# поверхность вывернется наизнанку. Отсюда и старое 0.72 у пластов: 0.72/0.667
# = 1.08, впритык под 1.5. Три семейства складываются не в лоб, а как вектора
# (направления-то разные), но запас всё равно невелик.
#
# И ТА И ДРУГАЯ УБАВЛЕНЫ ПО ТОЙ ЖЕ ПРИЧИНЕ, ЧТО И ШУМ. Тяга к плоскости искала
# граней там, где их не было; у многогранника они есть, и тянуть его к чужой
# сетке — значит гнуть готовую грань. Пласты оставлены слабыми: слоистость
# камню идёт, а стоит она недорого (плоских 41.4% против 42.1% вовсе без них).
# Поперечные семейства выключены: с ними плоских 38.4%, то есть заметно хуже.
var bed_pull: float = 0.30
var side_pull: float = 0.0
# Глубина шва МЕЖДУ ГЛЫБАМИ РАЗНЫХ МАЗКОВ — см. `_refresh_seam`. Это другой шов,
# не тот, что по трещинам: этот делит массив по руке, а не по природной сетке.
var seam_deep: float = 0.6
# ДОКУДА МАЗОК ДОТЯГИВАЕТСЯ, долей своего радиуса. Единица — как было: масса
# сходит на нет ровно на краю кисти. Меньше — мазок держится в своих границах
# туже, но и стык с нетронутой землёй укладывается в меньшее расстояние, а это
# ровно то, чем делались клинья у подошвы. См. профиль мазка в `stroke_at`.
var stroke_reach: float = 1.0
# Что положил последний мазок — по массе и по каменистости. Читает `SpaceMain`
# сразу после `stroke_at` и кладёт в историю; по ним же идёт отмена.
var last_edit_delta: Dictionary = {}
var last_stone_delta: Dictionary = {}
# Класть ли камень многогранником. Выключается только стендом — чтобы было с чем
# сравнивать; в игре всегда включено. См. `_block_planes`.
var use_blocks: bool = true
# Насколько обиты рёбра глыбы, долей её тела. Ноль — острое пересечение
# плоскостей, которое решётка не держит. См. `_block_dist`.
var block_round: float = 0.20
# СВОЙ УРОВЕНЬ У КАЖДОЙ ГЛЫБЫ — ПРОБОВАЛ, НЕ ОКУПИЛОСЬ. Замысел был такой: дать
# каждой глыбе своё смещение поля, постоянное внутри неё, — тогда соседние
# глыбы стоят на разной высоте, уступы выходят разной величины, и массив
# читается грудой камней, а не ровной кладкой. Считалось по восьми соседним
# глыбам сразу, чтобы на рёбрах и в углах уровень не скакал дважды и трижды.
#
# Замерено на обоих массивах, ±0.15 … ±1.0 поля: заломы, резкие рёбра и впадина
# не сдвинулись НИ НА ЧТО (на крупном массиве 8.9/13.8 при любом уровне,
# впадина 0.74 → 0.72), а на ±1.0 худшее вогнутое ребро полезло с 75.7° до
# 87.8°. Причина простая: перелом размазан по ячейке, и уступ в 0.2 м выходит
# наклоном в 17° — тише порога, за который глаз цепляется.
#
# Разноразмерность камней придётся брать не отсюда, а отдельными телами.


# ТРИ СЕМЕЙСТВА ТРЕЩИН — ТО, ЧЕМ ПОРОДА РАСКОЛОТА НА ГЛЫБЫ.
#
# Настоящая порода разбита не как попало. Её режут ОТДЕЛЬНОСТИ — семейства
# почти параллельных трещин: пласты (лежат полого, часто с наклоном) и два
# набора поперечных, стоящих почти отвесно и почти перпендикулярно друг другу.
# Их пересечения и дают глыбы разной формы и размера — ровно то, что видно на
# снимках обнажений.
#
# ПОЧЕМУ ЭТО МОЖНО, А ШУМ БЫЛО НЕЛЬЗЯ. Трещина — это ПЛОСКОСТЬ, а плоскость
# решётка держит ТОЧНО при любом разбросе семян: поле внутри тетраэдра линейно,
# и у линейного поля срез идеально плоский. Тем же и жили пласты, когда
# ступеньки по шуму провалились. Здесь ровно тот же приём, только семейство не
# одно и не обязательно горизонтальное.
#
# ЗАЛЕГАНИЕ ОДНО НА ВЕСЬ ОСТРОВ. Оно берётся от семени мира и дальше не
# меняется: один холм — одно залегание, так оно и в природе. Если когда-нибудь
# понадобится, чтобы разные обнажения лежали по-разному, крутить надо здесь.
#
# ШАГИ У СЕМЕЙСТВ РАЗНЫЕ НАРОЧНО. Возьми три одинаковых — и глыбы выйдут
# кубиками. Все три при этом крупнее четырёх ячеек (2.7 м): мельче решётка не
# держит, и вместо глыб полезут шипы.
func _build_joints(grid_seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = grid_seed + 7717
	# Пласты: не строго горизонтальны, а с наклоном в полтора-два десятка
	# градусов. Строго горизонтальные читаются слоёным пирогом, а не породой.
	var tilt: float = deg_to_rad(rng.randf_range(12.0, 24.0))
	var az: float = rng.randf_range(0.0, TAU)
	var bed := Vector3(sin(tilt) * cos(az), cos(tilt), sin(tilt) * sin(az)).normalized()
	# Рама поперёк пластов: в ней и лежат оба отвесных семейства.
	var side: Vector3 = Vector3.UP.cross(bed)
	if side.length() < 0.05:
		side = Vector3.RIGHT.cross(bed)
	side = side.normalized()
	var other: Vector3 = bed.cross(side).normalized()
	# Между собой отвесные семейства стоят не под прямым углом, а под косым:
	# прямой даёт кирпичи, косой — ромбические глыбы, как на обнажениях.
	var turn: float = rng.randf_range(0.0, TAU)
	var skew: float = deg_to_rad(75.0)
	# ШАГ СЕМЕЙСТВА — это шаг МЕЛКИХ трещин, а не размер глыбы. Крупная выпадает
	# примерно каждая третья (см. `_crack_rank`), значит крупные тела выходят в
	# три с лишним раза больше шага, а изредка и куда больше — когда подряд
	# выпало несколько слабых плоскостей. Отсюда и «крупные, и даже очень
	# крупные» камни при шаге всего в три метра.
	_joint_sets = [
		{"dir": bed, "step": LEDGE_STEP * joint_span, "bed": true, "fam": 0, "off": 0.0},
		{"dir": (side * cos(turn) + other * sin(turn)).normalized(),
			"step": 3.4 * joint_span, "bed": false, "fam": 1, "off": 31.7},
		{"dir": (side * cos(turn + skew) + other * sin(turn + skew)).normalized(),
			"step": 4.0 * joint_span, "bed": false, "fam": 2, "off": 63.1},
	]


# Что семейства делают с полем — две вещи сразу.
#
# ПЕРВОЕ, ТЯГА К ПЛОСКОСТИ. Поле подтягивается к ближайшему уровню семейства,
# и поверхность набирает плоские грани, лежащие по этому семейству. Тяга мала —
# пик у семейства пластов 0.36 поля, у поперечных вдвое меньше, — она не
# двигает форму, а решает, ГДЕ поверхности удобнее лечь.
#
# ВТОРОЕ, ШОВ. У самой плоскости поле проседает, и между глыбами прорезается
# ложбина. Это и есть то, что заставляет читать массив множеством камней:
# плоские грани без шва дают гранёный ком, а не груду.
#
# ШВЫ СКЛАДЫВАЕМ ЧЕРЕЗ НАИБОЛЬШИЙ, А НЕ СУММОЙ. Там, где сходятся два-три
# семейства, сумма выкопала бы яму втрое глубже шва, а на месте угла глыбы —
# воронку. Наибольший даёт ровно один шов любой глубины, сколько бы семейств ни
# сошлось.
#
# ВЫЧИТАТЬ БЕЗОПАСНО ВЕЗДЕ, в отличие от прибавки: выемка в пустоте ничего не
# создаёт, а прибавка отращивает от тела висящие в воздухе плиты.
# =============================================================================
#  ГЛЫБЫ ПО МАЗКАМ
# =============================================================================
#
#  ТРЕЩИНЫ ДЕЛЯТ ПОРОДУ ПО СВОЕЙ СЕТКЕ, А НАДО — ПО РУКЕ. Три семейства выше
#  режут массив там, где им положено природой, и к тому, что человек лепил, это
#  отношения не имеет: положил он один мазок или семь, массив делится одинаково.
#  А просят обратного — чтобы **сколько мазков положено, на столько камней
#  массив и делился**.
#
#  Поэтому каждый мазок камня заводит СВОЮ ГЛЫБУ, и между глыбами прорезается
#  шов. Шов идёт ровно посередине между двумя ближайшими глыбами — по их общей
#  границе, — а внутри глыбы его нет вовсе.
#
#  МАЗОК В ТО ЖЕ МЕСТО НЕ ЗАВОДИТ ВТОРОЙ ГЛЫБЫ. Лепят повторами: пять щелчков в
#  одну точку — это один камень, который растёт, а не пять камней в одном месте.
#  Поэтому мазок прибивается к ближайшей глыбе, если она ближе `LUMP_MERGE`;
#  дальше — заводится новая.
#
#  РАССТОЯНИЕ АБСОЛЮТНОЕ, А НЕ ДОЛЯ РАДИУСА КИСТИ, и причина не в удобстве.
#  Шов — это ложбина, и решётка не удержит её, если два камня стоят ближе
#  полутора метров: вместо шва выйдет дрожь. Считай мы долей от радиуса — узкая
#  кисть заводила бы камни через полметра, и шов между ними был бы неразличим.
#
#  ОТМЕНА ТОЧНА. У глыбы копится масса, простая сумма положенного; отмена
#  повторяет мазок с обратным знаком и ту же массу вычитает. Ушла в ноль —
#  глыба гаснет. Никакой памяти о порядке мазков не нужно.
const LUMP_MERGE: float = 1.8     # ближе этого, в метрах, — тот же камень
const LUMP_CELL: float = 3.0      # сторона клетки поиска глыб, м
# Докуда от середины мазка глыба считается телом, долей радиуса кисти.
const LUMP_CORE: float = 0.8
# Полуширина шва между глыбами. Шире ячейки решётки — иначе вместо ложбины
# выйдет дрожь; см. тот же расчёт у швов по трещинам.
const SEAM_WIDE: float = 0.9

func _lump_key(p: Vector3) -> Vector3i:
	return Vector3i(int(floor(p.x / LUMP_CELL)), int(floor(p.y / LUMP_CELL)),
		int(floor(p.z / LUMP_CELL)))


# Какие глыбы могут дотянуться до этой точки. Клетка берётся с запасом в одну
# в каждую сторону: глыба сидит в своей клетке, а тянется за её край.
func _lumps_near(p: Vector3) -> Array:
	var out: Array = []
	var base: Vector3i = _lump_key(p)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var key: Vector3i = base + Vector3i(dx, dy, dz)
				if _lump_hash.has(key):
					out.append_array(_lump_hash[key])
	return out


# Мазок заявляет права на глыбу: находит свою или заводит новую.
# `mass` со знаком — отмена приходит сюда же с обратным.
func _claim_lump(point: Vector3, radius: float, mass: float) -> int:
	var best: int = -1
	var near: float = LUMP_MERGE
	for k in _lumps_near(point):
		var d: float = point.distance_to(lumps[k]["pos"])
		if d < near:
			near = d
			best = k
	if best < 0:
		if mass <= 0.0:
			return -1              # отменять нечего: этой глыбы уже нет
		best = lumps.size()
		lumps.append({"pos": point, "r": radius, "mass": 0.0,
			"cut": _block_planes(point, radius)})
		var key: Vector3i = _lump_key(point)
		if not _lump_hash.has(key):
			_lump_hash[key] = []
		_lump_hash[key].append(best)
	lumps[best]["mass"] = float(lumps[best]["mass"]) + mass
	lumps[best]["r"] = maxf(float(lumps[best]["r"]), radius)
	if float(lumps[best]["mass"]) <= 0.001:
		# Глыбу не выбрасываем из списка — номера в клетках сбились бы. Гасим
		# массу в ноль, и в счёт швов она больше не идёт.
		lumps[best]["mass"] = 0.0
	return best


# =============================================================================
#  МАЗОК КАМНЯ КЛАДЁТ ГЛЫБУ, А НЕ ШАР
# =============================================================================
#
#  ПОЧЕМУ ПРИШЛОСЬ ПЕРЕДЕЛЫВАТЬ. Пользователь прислала кадр: «весь массив
#  выглядит одной массой пластилина». Так и было, и вот отчего.
#
#  Мазок кладёт массу ШАРОМ — вес падает по расстоянию до середины. Значит, и
#  поверхность выходит шаром: гладкий купол без единой грани. Всё, что делалось
#  дальше — доли, пласты, трещины, швы, — это ПОПРАВКИ поверх купола, и потолок
#  у них измерен: сдвинуть поле сильнее чем на 0.6 нельзя, иначе поверхность
#  выворачивается. На глыбе в шесть метров это рябь в полметра, то есть
#  выделка, а не форма. Числа говорили то же: рёбер, гнущихся понемногу, — 90%,
#  а настоящих граней нет ни одной.
#
#  А на всех снимках у камня ПЛОСКИЕ ГРАНИ В МЕТРЫ ВЕЛИЧИНОЙ и резкие рёбра
#  между ними.
#
#  РЕШЕНИЕ БЫЛО ЗАПИСАНО В ЭТОМ ЖЕ ФАЙЛЕ: плоскость решётка держит ТОЧНО при
#  любом разбросе семян — внутри тетраэдра поле линейно, и у линейного поля срез
#  идеально плоский. Этим живут пласты. Значит, класть надо не шар, а
#  МНОГОГРАННИК: вес считать не по расстоянию до середины, а по расстоянию до
#  набора плоскостей. Тогда грани выходят плоскими ПО ПОСТРОЕНИЮ и в полную
#  величину, а не поправкой в пять процентов.
#
#  ВСЕ УРОВНИ ОДНОГО МНОГОГРАННИКА ПОДОБНЫ. Вес падает от середины к грани так
#  же, как падал у шара, — значит, лепка не изменилась: форма по-прежнему
#  набирается повторами, и с каждым мазком глыба растёт, оставаясь гранёной.
#
#  ГЛЫБА СТОИТ, А НЕ ЛЕЖИТ. На снимках камень чаще выше, чем шире; купол же
#  всегда лежит. Поэтому грани, смотрящие вверх и вниз, отодвинуты дальше
#  боковых — тело вытягивается по высоте.
#
#  ПЛОСКОСТИ ЗАВЕДЕНЫ ОТ МЕСТА ГЛЫБЫ, а не от счётчика: отмена повторяет мазок
#  в той же точке, попадает в ту же глыбу и получает те же плоскости — иначе она
#  вычитала бы не то, что прибавила.
# Не `const`: стенд крутит их с ключа, в игре всегда эти числа.
var block_faces: int = 9
# Ближняя и дальняя грань, долей радиуса кисти. Разброс делает глыбы
# неправильными; будь он мал — все выходили бы одинаковыми шайбами.
const BLOCK_NEAR: float = 0.52
const BLOCK_FAR: float = 0.86
# Насколько верх и низ отодвинуты дальше боков: этим глыба и встаёт.
var block_tall: float = 0.55

func _block_planes(point: Vector3, radius: float) -> PackedVector3Array:
	var rng := RandomNumberGenerator.new()
	# От МЕСТА, с шагом в четверть метра: два мазка в одну глыбу приходят с
	# чуть разных точек и обязаны получить одни и те же плоскости.
	rng.seed = hash(Vector3i((point * 4.0).round())) & 0x7FFFFFFF
	var out := PackedVector3Array()
	for i in range(block_faces):
		var n: Vector3
		if i < 2:
			# Две грани кладём полого: у камня, отколовшегося по пласту, верх и
			# низ плоские. Без них глыба выходит колючим кристаллом.
			n = Vector3(rng.randf_range(-0.4, 0.4), 1.0 if i == 0 else -1.0,
				rng.randf_range(-0.4, 0.4)).normalized()
		else:
			n = Vector3(rng.randfn(), rng.randfn() * 0.7, rng.randfn())
			if n.length() < 0.001:
				n = Vector3.RIGHT
			n = n.normalized()
		var far: float = radius * rng.randf_range(BLOCK_NEAR, BLOCK_FAR) \
			* (1.0 + block_tall * absf(n.y))
		# Храним нормаль, УЖЕ ПОДЕЛЁННУЮ на дальность грани: тогда расстояние до
		# многогранника — это просто наибольшее скалярное произведение, без
		# единого деления в горячем месте.
		out.append(n / maxf(far, 0.01))
	return _bevel(out)


# СКАШИВАЕМ ОСТРЫЕ УГЛЫ — решение пользователя: «если граней настолько мало, что
# фигура становится острой, то надо дополнительно скашивать такие острые углы».
#
# Откуда острота берётся. Тело — это пересечение полуплоскостей, и когда граней
# мало, две из них могут сойтись почти навстречу друг другу. Ребро между такими
# гранями выходит лезвием, а вершина — шипом; решётка их не держит, и вместо
# камня получается колючка. Чем меньше граней просят, тем чаще это случается —
# потому скос и нужен именно тут, а не в общей настройке.
#
# Как скашиваем. Ищем пары граней, сходящихся острее прямого угла, и на каждую
# такую пару ставим ТРЕТЬЮ грань поперёк — по биссектрисе, чуть ближе самого
# ребра. Лезвие срезается коротким скосом, а обе исходные грани остаются
# плоскими: у камня так и бывает — плоскости целы, кромка обита.
#
# Считается один раз на глыбу, поэтому перебор пар здесь ничего не стоит.
const BEVEL_SHARP: float = -0.15  # острее этого схождения граней — скашиваем
const BEVEL_KEEP: float = 0.86    # какую долю ребра оставляем

func _bevel(cut: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array(cut)
	for a in range(cut.size()):
		var ma: Vector3 = cut[a]
		var la: float = ma.length()
		if la < 0.000001:
			continue
		for b in range(a + 1, cut.size()):
			var mb: Vector3 = cut[b]
			var lb: float = mb.length()
			if lb < 0.000001:
				continue
			if (ma / la).dot(mb / lb) > BEVEL_SHARP:
				continue           # грани сходятся тупо, скашивать нечего
			var u: Vector3 = (ma / la + mb / lb)
			if u.length() < 0.05:
				continue           # грани смотрят ровно навстречу: биссектрисы нет
			u = u.normalized()
			# Докуда по биссектрисе достаёт само ребро: там обе грани равны своей
			# единице. Ставим скос чуть ближе — на него ребро и срежется.
			var reach: float = u.dot(ma)
			if reach < 0.000001:
				continue
			out.append(u / (BEVEL_KEEP / reach))
	return out


# Насколько точка далека от середины глыбы В ДОЛЯХ ЕЁ ТЕЛА: ноль в середине,
# единица на грани, больше единицы — снаружи. Та же величина, что у шара давало
# `|off| / radius`, только уровни у неё многогранные.
#
# РЁБРА СКРУГЛЯЕМ, И НЕ ИЗ ОСТОРОЖНОСТИ. Жёсткое пересечение плоскостей даёт
# рёбра любой остроты, а решётка их всё равно не удержит: замерено — на голом
# пересечении 16 рёбер круче 90°, худшее 155°, то есть вывернутая поверхность.
# Мягкий максимум скругляет ребро на заданную долю тела — грани при этом
# остаются плоскими, меняется только сама кромка. Ровно так и выглядит
# выветренный камень: плоскости целы, углы обиты.
func _block_dist(off: Vector3, cut: PackedVector3Array) -> float:
	var q: float = -1000000.0
	for m in cut:
		var v: float = off.dot(m)
		if block_round <= 0.0:
			q = maxf(q, v)
		else:
			q = -_smin(-q, -v, block_round)
	return q


# НАСКОЛЬКО ТОЧКА СИДИТ НА ШВЕ. Ноль в теле глыбы, единица ровно на границе с
# соседней. Считаем по двум ближайшим: разница расстояний до них — это удвоенное
# расстояние до их общей границы.
func _refresh_seam(index: int) -> void:
	if index < 0 or index >= seam.size():
		return
	if stone_soft[index] < 0.02 or lumps.size() < 2:
		seam[index] = 0.0
		return
	var p: Vector3 = seeds[index]
	var d1: float = 1000000.0
	var d2: float = 1000000.0
	for k in _lumps_near(p):
		if float(lumps[k]["mass"]) <= 0.0:
			continue
		var d: float = p.distance_to(lumps[k]["pos"])
		# ГЛЫБА ВЛИЯЕТ НА ШОВ НЕ ДАЛЬШЕ СВОЕЙ СЕРДЦЕВИНЫ, а не всего радиуса
		# кисти. Иначе шов уходит к самой кромке мазка и режет там, где породы
		# почти нет, — то есть выходит за границы мазка, чего и просили не
		# делать. Замерено: масса мазка кончается ровно на радиусе, сырая
		# краска на 0.92 его; берём 0.8 — заведомо внутри тела.
		if d > float(lumps[k]["r"]) * LUMP_CORE:
			continue
		if d < d1:
			d2 = d1
			d1 = d
		elif d < d2:
			d2 = d
	if d2 > 999999.0:
		seam[index] = 0.0
		return
	seam[index] = 1.0 - smoothstep(0.0, SEAM_WIDE, (d2 - d1) * 0.5)


func _joints(p: Vector3, s: float, body: float) -> float:


	if _ledge_warp == null or _joint_sets.is_empty():
		return 0.0
	var flat: float = 0.0
	var deep: float = 0.0
	for js in _joint_sets:
		var step: float = float(js["step"])
		var off: float = float(js["off"])
		# Волна, которой ведут плоскости, — 11.8 м, крупнее любой глыбы. Без неё
		# трещины одинаковы во всём мире и читаются разлиновкой.
		var lift: float = _ledge_warp.get_noise_3d(p.x + off, p.y + off, p.z + off) \
			* step * 0.35
		var t: float = p.dot(js["dir"]) + lift
		var q: float = t / step
		var base: float = floor(q)
		var frac: float = q - base
		var stair: float = base + smoothstep(JOINT_EDGE, 1.0 - JOINT_EDGE, frac)
		flat += (stair * step - t) * (bed_pull if js["bed"] else side_pull)
		# ШОВ КОПАЕТ ТОЛЬКО ВЫШЕ ПЛОСКОСТИ, а не по обе стороны от неё.
		#
		# ГРАБЛИ, И ДОРОГИЕ. Двусторонний шов дрался с тягой. Тяга у самой
		# плоскости устроена несимметрично: ВЫШЕ неё поле убавляется, НИЖЕ
		# прибавляется — этим и делается уступ. Двусторонний шов копал по обе
		# стороны, и ниже плоскости выемка тянула вниз ровно там, где тяга
		# тянула вверх. Две противоположные тяги на расстоянии полуметра — это
		# полячейки, то есть частота вчетверо выше той, что решётка держит.
		# Замерено: шов сам по себе давал худшее ребро 71.7°, тяга сама по себе
		# 43.8°, а вместе — 132.5°, то есть вывернутую наизнанку поверхность.
		#
		# Односторонний шов ложится ровно туда, где тяга и так убавляет поле:
		# они складываются, а не спорят. На камне это и правильно — под плитой
		# подмыв, над нею полка.
		# ТРЕЩИНА РЕЖЕТ НАСКВОЗЬ, А НЕ ЦАРАПАЕТ.
		#
		# Прежний шов был мелкой ложбиной по обе стороны плоскости, и от него
		# пришлось отказаться: он не делил массив, а только гнул готовые грани.
		# Настоящая трещина устроена иначе — она УЗКАЯ и ГЛУБОКАЯ. Там, где
		# порода тонка, поле проваливается ниже половины, и камень честно
		# распадается на два тела с просветом между ними; там, где толста,
		# остаётся глубокая щель, читающаяся чёрной чертой.
		#
		# И ЭТО САМО ОТВЕЧАЕТ НА МАССУ. Трещина вычитает из поля постоянную
		# величину, а мазок прибавляет: подсыпь породы — щель затянется, сними —
		# разойдётся. Ничего дополнительно считать не нужно.
		#
		# У дна щели, которая НЕ прорезала насквозь, решётка даёт вогнутое
		# ребро — это неизбежно и это правильно: чёрная черта в камне и есть
		# вогнутое ребро. Следить надо лишь за тем, чтобы оно не переваливало
		# за 90°, то есть чтобы поверхность не выворачивалась.
		var pi: float = round(q)
		var rank: float = _crack_rank(int(js["fam"]), int(pi))
		# ТОЛЩИНА ГУЛЯЕТ ПО ДЛИНЕ ТРЕЩИНЫ. Ровная по всей длине щель читается
		# пропилом, а не расколом.
		#
		# НО ТОЛЩИНОЙ РАЗРЯД ПРАВИТ ЧУТЬ-ЧУТЬ, А ГЛУБИНОЙ — ВПОЛНЕ. Сперва я
		# умножил на разряд саму толщину, и мелкие трещины вышли в 0.2 м при
		# ячейке в 0.67: решётка такого не держит вовсе, и вместо щелей пошли
		# шипы — 45 рёбер круче 90°. Любая трещина, какого бы разряда она ни
		# была, обязана быть шире ячейки; разнятся они глубиной.
		var vary: float = 0.85 + 0.45 * (0.5 + 0.5 * _ledge_warp.get_noise_3d(
			p.x * 2.3 + off, p.y * 2.3, p.z * 2.3 - off))
		# КРУПНАЯ ТРЕЩИНА РЕЖЕТ НАСКВОЗЬ, И ПОТОМУ ЕЁ ВЫЧЕТ СЧИТАЕТСЯ ОТ ТОЛЩИНЫ.
		#
		# Постоянный вычет насквозь не режет никогда, и это видно числами: при
		# любой глубине от 0 до 2.4 массив оставался ОДНИМ телом. Причина
		# простая — внутри породы поле доходит до шести, а вычитали мы полтора.
		# Щель выедалась только в тонкой кайме у самой поверхности.
		#
		# Чтобы порода расселась, в щели поле обязано уйти НИЖЕ ПОЛОВИНЫ, сколько
		# бы его тут ни было. Значит, вычитать надо не постоянную величину, а
		# ровно ту, что лежит: `body − половина` и немного сверху.
		#
		# И ЭТО ЖЕ ДАЁТ ОТВЕТ НА МАССУ. Мелкие трещины остались постоянными: они
		# затягиваются, когда породы подсыпают, и расходятся, когда снимают.
		# Крупные держатся всегда — как оно и бывает у настоящего раскола.
		#
		var take: float = crack_deep * rank
		var dist: float = absf(q - pi) * step
		# У ТРЕЩИНЫ ПЛОСКОЕ ДНО И ПОЛОГИЕ СТЕНКИ, а не форма буквы V.
		#
		# ЭТО И ЕСТЬ СПОСОБ СДЕЛАТЬ ЩЕЛЬ УЗКОЙ. Прежде вся трещина была одним
		# скатом от середины к краю, и её ширина была шириной этого ската: сделай
		# щель узкой — скат уходит под ячейку решётки, и вместо щели идут шипы
		# (замерено: полутолщина 0.55 м дала девять рёбер круче 90°).
		#
		# Стоит развести дно и стенку, и предел перестаёт держать ширину. Узким
		# должно быть ДНО, а стенке достаточно быть не круче ячейки — она своё
		# место найдёт. Получается щель с узким тёмным дном и разваленными
		# краями: ровно так выглядит настоящая трещина в камне, и ровно так её
		# может удержать решётка.
		var floor_r: float = crack_floor * (0.7 + 0.3 * rank) * vary
		var prof: float = 1.0 - smoothstep(floor_r, floor_r + crack_wall, dist)
		deep = maxf(deep, prof * take)
	# Запоминаем, сколько отняла трещина: по этому числу растения потом спросят
	# поверхность так, будто трещин нет вовсе. См. `calm_surface_near`.
	_cut_here = deep * s * s
	return flat / _spacing * s * s - _cut_here


# РАЗРЯД ТРЕЩИНЫ: насколько эта плоскость семейства крупная.
#
# «Порода разрезается не только на небольшие камни, но на крупные, и даже очень
# крупные» — решение пользователя. Одинаковые трещины через равный шаг дают
# одинаковые кирпичи, а на снимках размеры глыб разнятся в разы.
#
# Поэтому плоскости семейства НЕ РАВНОПРАВНЫ. Примерно каждая третья — крупная:
# режет насквозь и делит массив на большие тела. Остальные слабее и мельче, и
# порода через них не расходится, а лишь надламывается. Где подряд выпало
# несколько слабых, там и получается очень крупная глыба — сама собой, без
# отдельного правила на её счёт.
#
# Разряд берётся от НОМЕРА ПЛОСКОСТИ, а не от места: одна и та же трещина
# обязана быть одной и той же по всей своей длине.
#
# ДВА ВИДА ТРЕЩИН, А НЕ ТРИ РАЗРЯДА ОДНОЙ — решение пользователя: «пусть будет
# 2 типа трещин: очень широкие, в которых проглядывают осколки и камни поменьше,
# и узкие глубокие, которые разветвляются».
#
# Ветвящиеся узкие в поле не живут вовсе: рельефа у волосяной трещины нет, а
# ветвиться плоскость не умеет. Их целиком рисует шейдер своим рисунком.
#
# Здесь остаются ШИРОКИЕ. Их сделали заметно шире прежних крупных: осколкам на
# дне нужно место, а в полуметровой щели их не разглядеть. Зато и выпадают они
# реже — иначе широкие щели смыкаются и от камня ничего не остаётся.
func _crack_rank(fam: int, plane: int) -> float:
	var r: float = float(hash(Vector2i(fam, plane)) & 0xFFFF) / 65535.0
	if r < 0.20:
		return 1.0                 # очень широкая: в неё и лягут осколки
	if r < 0.50:
		return 0.50                # обычная щель
	return 0.24                    # надлом по грани


# Насколько круто стоит поверхность у этой ячейки: 0 — плоско, 1 — отвесно.
#
# Считаем по полю БЕЗ огранки. По готовому полю нельзя: огранка тогда кормит
# сама себя — где она задрала склон, наклон становится круче, огранка ещё
# сильнее, и камень идёт шипами.
func _steepness(index: int) -> float:
	var here: Vector3 = seeds[index]
	var f0: float = base_fill[index] + _edit_of(index)
	var g := Vector3.ZERO
	var at := index * 6
	for k in range(6):
		var s: int = nb_table[at + k]
		if s < 0:
			continue
		var d: Vector3 = seeds[s] - here
		var len2: float = d.length_squared()
		if len2 > 0.000001:
			g += d * ((base_fill[s] + _edit_of(s) - f0) / len2)
	g = straighten(index, g)
	var mag: float = g.length()
	if mag < 0.000001:
		return 0.0
	return clampf(1.0 - absf(g.y) / mag, 0.0, 1.0)


# Семя по узлу решётки — по этому строится разбиение на тетраэдры.
func node_seed(node: Vector3i) -> int:
	return int(_node_index.get(node, -1))


# ВЕСЬ УКАЗАТЕЛЬ УЗЛОВ ЦЕЛИКОМ — для сборки поверхности. Она спрашивает восемь
# углов у каждого кубика, кубиков в куске шестьдесят четыре, а вызов через
# нетипизированную ссылку тут самое дорогое: сборщик берёт словарь один раз и
# дальше читает его напрямую.
func node_index() -> Dictionary:
	return _node_index


func node_of(index: int) -> Vector3i:
	var p: Vector3 = lattice[index] / _spacing
	return Vector3i(int(round(p.x)), int(round(p.y)), int(round(p.z)))


func spacing() -> float:
	return _spacing


# --- Запросы наружу ----------------------------------------------------------
# Ближайшая ячейка к точке — нужна, чтобы понимать, куда указывает курсор.
# «ЯЧЕЙКИ В ШАРЕ» (`cells_near`) убраны 2026-09-01: их никто не звал. Тем же
# делом занят `seeds_near` — он же и остался.


#
# СВОЮ КЛЕТКУ СМОТРИМ ПЕРВОЙ, А СОСЕДНИЕ — ТОЛЬКО ЕСЛИ В НИХ МОЖЕТ БЫТЬ БЛИЖЕ.
#
# Это самое горячее место во всей игре: через него ходят и поиск земли, и рост,
# и посадка. Замерено 02.09.2026: одна опора вокруг нового звена лианы — это 128
# таких поисков, отсюда 3.4 мс на рождение звена; поиск места отростку — ещё 0.8
# мс. Вместе 93% всей цены роста.
#
# Клетка хеша в 1.4 шага решётки, значит в ней около трёх семян, а перебирались
# все двадцать семь клеток — под восемь десятков расстояний на каждый вызов.
# Теперь: сперва своя клетка (ближайшее семя почти всегда в ней), потом соседние
# с отсечением по КОРОБКЕ — если до ближайшего угла клетки дальше, чем до уже
# найденного семени, ничего лучшего там нет.
#
# Отсечение ТОЧНОЕ: то же самое семя, а не «примерно то же». Проверено стендом
# лианы — сад выходит звено в звено тот же.
func cell_at(p: Vector3) -> int:
	var base := _key_of(p)
	var best := -1
	var best_d := INF
	var mine = _seed_hash.get(base)
	if mine != null:
		for i in mine:
			var d: float = seeds[i].distance_squared_to(p)
			if d < best_d:
				best_d = d
				best = i
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var key := base + Vector3i(dx, dy, dz)
				var here = _seed_hash.get(key)
				if here == null:
					continue
				# Отсечение спрашиваем только когда есть с чем сравнивать: в
				# пустоте (своя клетка без семян) оно всё равно ничего не
				# отсекает, а вызов на каждую из двадцати шести клеток стоит.
				if best >= 0 and _box_away(p, key) >= best_d:
					continue
				for i in here:
					var d: float = seeds[i].distance_squared_to(p)
					if d < best_d:
						best_d = d
						best = i
	return best


# Квадрат расстояния от точки до коробки клетки хеша — мерка отсечения выше.
func _box_away(p: Vector3, key: Vector3i) -> float:
	var lo := Vector3(key) * _cell_size
	var ax: float = maxf(maxf(lo.x - p.x, 0.0), p.x - lo.x - _cell_size)
	var ay: float = maxf(maxf(lo.y - p.y, 0.0), p.y - lo.y - _cell_size)
	var az: float = maxf(maxf(lo.z - p.z, 0.0), p.z - lo.z - _cell_size)
	return ax * ax + ay * ay + az * az


func neighbors_of(index: int) -> Array:
	var out: Array = []
	for f in faces_of(index):
		out.append(f["nb"])
	return out
