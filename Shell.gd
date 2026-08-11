extends RefCounted
# =============================================================================
#  ОБОЛОЧКА — сглаживание поверхности мира.
#
#  Берём границу породы (грани между заполненной ячейкой и пустой) и
#  СГЛАЖИВАЕМ её целиком по схеме Катмулла — Кларка:
#
#    1) у каждой грани находим её середину;
#    2) у каждого ребра — точку между его концами и серединами двух соседних
#       граней;
#    3) старые вершины подтягиваем к окружающим серединам.
#    4) каждая грань распадается на четырёхугольники: угол — ребро — середина.
#
#  Один такой проход уже заметно оплавляет форму, два превращают гранёные
#  глыбы в текучую массу. Поверхность замкнута, поэтому особых случаев с
#  краями нет.
#
#  ПЕРЕПЛАВ (`MELT`). Чистая схема Катмулла — Кларка держится близко к
#  исходным глыбам. Пока ячейка была крупной, это давало плавные формы; когда
#  ячейка стала мелкой, каждая глыба превратилась в отдельный бугорок, а между
#  ними легли ямки — поверхность стала похожа на дырявый сыр. Поэтому вершину
#  дополнительно тянем к средней точке её окружения: бугры оседают, ямки
#  затягиваются, крупная форма остаётся. Второй проход дробления дал бы то же,
#  но вчетверо дороже, а пересборка куска обязана оставаться быстрой.
# =============================================================================

const MELT: float = 0.62          # насколько сильнее обычного оплывает форма


# Вход: вершины, грани (петли номеров вершин, обход наружу) и цвет каждой грани.
# Выход: то же самое после одного прохода сглаживания.
# `hold` — насколько грань сопротивляется сглаживанию: 0 оплывает полностью,
# 1 остаётся плоской и острой. Так скалы держат грани, а земля рядом с ними
# сглаживается лишь наполовину — получается переходный стык, а не рубленый.
static func subdivide(verts: PackedVector3Array, faces: Array,
		colors: PackedColorArray, hold: PackedFloat32Array) -> Dictionary:
	var face_count := faces.size()

	# 1) середины граней
	var face_pt := PackedVector3Array()
	face_pt.resize(face_count)
	for i in range(face_count):
		var loop: PackedInt32Array = faces[i]
		var sum := Vector3.ZERO
		for v in loop:
			sum += verts[v]
		face_pt[i] = sum / float(loop.size())

	# рёбра и какие грани к ним примыкают
	var edge_id: Dictionary = {}
	var edge_ends: Array = []
	var edge_faces: Array = []
	for i in range(face_count):
		var loop: PackedInt32Array = faces[i]
		var n := loop.size()
		for k in range(n):
			var a: int = loop[k]
			var b: int = loop[(k + 1) % n]
			var key := Vector2i(mini(a, b), maxi(a, b))
			if not edge_id.has(key):
				edge_id[key] = edge_ends.size()
				edge_ends.append(key)
				edge_faces.append([])
			edge_faces[edge_id[key]].append(i)

	# 2) точки рёбер (с учётом того, насколько ребро держит форму)
	var edge_pt := PackedVector3Array()
	edge_pt.resize(edge_ends.size())
	for e in range(edge_ends.size()):
		var ends: Vector2i = edge_ends[e]
		var plain: Vector3 = (verts[ends.x] + verts[ends.y]) * 0.5
		var sum: Vector3 = verts[ends.x] + verts[ends.y]
		var count := 2.0
		var stiff := 0.0
		for fi in edge_faces[e]:
			sum += face_pt[fi]
			count += 1.0
			stiff = maxf(stiff, hold[fi] if fi < hold.size() else 0.0)
		edge_pt[e] = (sum / count).lerp(plain, stiff)

	# 3) новые места старых вершин
	var v_face_sum := PackedVector3Array()
	var v_edge_sum := PackedVector3Array()
	var v_valence := PackedInt32Array()
	v_face_sum.resize(verts.size())
	v_edge_sum.resize(verts.size())
	v_valence.resize(verts.size())
	for i in range(face_count):
		var loop: PackedInt32Array = faces[i]
		for v in loop:
			v_face_sum[v] = v_face_sum[v] + face_pt[i]
	var v_edge_count := PackedInt32Array()
	v_edge_count.resize(verts.size())
	for e in range(edge_ends.size()):
		var ends: Vector2i = edge_ends[e]
		var mid: Vector3 = (verts[ends.x] + verts[ends.y]) * 0.5
		v_edge_sum[ends.x] = v_edge_sum[ends.x] + mid
		v_edge_sum[ends.y] = v_edge_sum[ends.y] + mid
		v_edge_count[ends.x] = v_edge_count[ends.x] + 1
		v_edge_count[ends.y] = v_edge_count[ends.y] + 1
	for i in range(face_count):
		for v in faces[i]:
			v_valence[v] = v_valence[v] + 1

	# Насколько каждая вершина держит форму — НАИБОЛЬШЕЕ по её граням.
	# Средним было бы мягче, но тогда скала на стыке с землёй расплывается, и
	# граница между ними размазывается на пол-ячейки. С наибольшим кромка
	# обрыва остаётся кромкой: земля рядом гладкая, скала — гранёная, а между
	# ними отчётливый край.
	var v_hold := PackedFloat32Array()
	v_hold.resize(verts.size())
	for i in range(face_count):
		var h: float = hold[i] if i < hold.size() else 0.0
		for v in faces[i]:
			v_hold[v] = maxf(v_hold[v], h)

	var moved := PackedVector3Array()
	moved.resize(verts.size())
	for v in range(verts.size()):
		var n := v_valence[v]
		if n == 0:
			moved[v] = verts[v]
			continue
		var q: Vector3 = v_face_sum[v] / float(n)
		var r: Vector3 = v_edge_sum[v] / float(maxi(v_edge_count[v], 1))
		var cc: Vector3 = (q + r * 2.0 + verts[v] * float(n - 3)) / float(n)
		var soft: Vector3 = cc.lerp((q + r) * 0.5, MELT)
		moved[v] = soft.lerp(verts[v], v_hold[v])

	# 4) собираем новые вершины и четырёхугольники
	var out_verts := PackedVector3Array(moved)
	var face_base := out_verts.size()
	out_verts.append_array(face_pt)
	var edge_base := out_verts.size()
	out_verts.append_array(edge_pt)

	var out_faces: Array = []
	var out_colors := PackedColorArray()
	var out_owners := PackedInt32Array()
	var out_hold := PackedFloat32Array()
	for i in range(face_count):
		var loop: PackedInt32Array = faces[i]
		var n := loop.size()
		for k in range(n):
			out_owners.append(i)
			out_hold.append(hold[i] if i < hold.size() else 0.0)
			var prev: int = loop[(k - 1 + n) % n]
			var cur: int = loop[k]
			var next: int = loop[(k + 1) % n]
			var e_next: int = edge_base + int(edge_id[Vector2i(mini(cur, next), maxi(cur, next))])
			var e_prev: int = edge_base + int(edge_id[Vector2i(mini(prev, cur), maxi(prev, cur))])
			out_faces.append(PackedInt32Array([cur, e_next, face_base + i, e_prev]))
			out_colors.append(colors[i])

	# Вместе с результатом отдаём внутренние точки: по ним растения кладутся
	# ровно на видимую поверхность, а не на исходные плоские грани.
	return {"verts": out_verts, "faces": out_faces, "colors": out_colors,
		"owners": out_owners, "hold": out_hold,
		"moved": moved, "face_pt": face_pt, "edge_pt": edge_pt, "edge_id": edge_id}


# Собирает готовый меш: треугольники с общими вершинами, поэтому нормали
# усредняются и поверхность выглядит гладкой, а не гранёной.
# `emit` — какие грани рисовать. Нормали и цвет копятся по ВСЕМ граням,
# включая соседний ореол: иначе на стыке кусков освещение разошлось бы и
# появился бы видимый шов.
#
# В UV кладём то, что шейдер сам посчитать не может:
#   x — из чего сложено (0 земля, 1 скала);
#   y — насколько вершина сидит во ВПАДИНЕ (0.5 — ровное место, больше —
#       щель, меньше — бугор). Считаем дёшево: смотрим, куда смещены
#       середины соседних граней относительно касательной плоскости.
#       По этому числу шейдер затемняет стыки между глыбами.
# Оба значения непрерывны через границу куска — их считает и ореол тоже,
# поэтому шва не появляется.
static func build_mesh(verts: PackedVector3Array, faces: Array,
		colors: PackedColorArray, emit: PackedByteArray,
		stone: PackedFloat32Array = PackedFloat32Array()) -> ArrayMesh:
	var normals := PackedVector3Array()
	var tint := PackedColorArray()
	var hits := PackedInt32Array()
	var v_stone := PackedFloat32Array()
	var around := PackedVector3Array()
	normals.resize(verts.size())
	tint.resize(verts.size())
	hits.resize(verts.size())
	v_stone.resize(verts.size())
	around.resize(verts.size())
	for i in range(faces.size()):
		var loop: PackedInt32Array = faces[i]
		var fn := _newell(verts, loop)
		var centre := Vector3.ZERO
		for v in loop:
			centre += verts[v]
		centre /= float(loop.size())
		var s: float = stone[i] if i < stone.size() else 0.0
		for v in loop:
			normals[v] = normals[v] + fn
			tint[v] = tint[v] + colors[i]
			around[v] = around[v] + centre
			v_stone[v] = v_stone[v] + s
			hits[v] = hits[v] + 1

	var cavity := PackedFloat32Array()
	cavity.resize(verts.size())
	for v in range(verts.size()):
		cavity[v] = 0.5
		if hits[v] == 0:
			continue
		tint[v] = tint[v] / float(hits[v])
		v_stone[v] = v_stone[v] / float(hits[v])
		normals[v] = normals[v].normalized() if normals[v].length() > 0.000001 else Vector3.UP
		var dir: Vector3 = around[v] / float(hits[v]) - verts[v]
		if dir.length() > 0.000001:
			# Соседи «впереди» по нормали — вершина в ложбине; позади — на бугре.
			cavity[v] = clampf(0.5 + 0.5 * dir.normalized().dot(normals[v]), 0.0, 1.0)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var remap: Dictionary = {}
	var any := false

	# Грани приходят обходом ПРОТИВ часовой стрелки снаружи, а в Godot лицевой
	# считается сторона с обходом ПО часовой — поэтому разворачиваем.
	for i in range(faces.size()):
		if i < emit.size() and emit[i] == 0:
			continue
		var loop: PackedInt32Array = faces[i]
		var n := loop.size()
		if n < 3:
			continue
		for v in loop:
			if not remap.has(v):
				remap[v] = remap.size()
				st.set_color(tint[v])
				st.set_normal(normals[v])
				st.set_uv(Vector2(v_stone[v], cavity[v]))
				st.add_vertex(verts[v])
		for k in range(1, n - 1):
			st.add_index(remap[loop[0]])
			st.add_index(remap[loop[k + 1]])
			st.add_index(remap[loop[k]])
		any = true

	if not any:
		return null
	return st.commit()


static func _newell(verts: PackedVector3Array, loop: PackedInt32Array) -> Vector3:
	var n := Vector3.ZERO
	var m := loop.size()
	for i in range(m):
		var a: Vector3 = verts[loop[i]]
		var b: Vector3 = verts[loop[(i + 1) % m]]
		n.x += (a.y - b.y) * (a.z + b.z)
		n.y += (a.z - b.z) * (a.x + b.x)
		n.z += (a.x - b.x) * (a.y + b.y)
	return n.normalized() if n.length() > 0.000001 else Vector3.UP
