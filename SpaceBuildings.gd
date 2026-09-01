extends Node3D
# ФАЙЛ ЖДЁТ ПЕРЕЕЗДА. Здания не создаются вовсе: они стояли на гранях ячеек,
# которых у новой поверхности нет. Переезд отдельным заходом.
# =============================================================================
#  ЗДАНИЯ — строятся по СВЯЗНОЙ ГРУППЕ ячеек, а не по каждой отдельно.
#
#  При мелкой сетке одна ячейка размером с ведро: дом из неё выходит не домом,
#  а кубиком, и два таких кубика друг над другом не стыкуются — у каждого своя
#  подошва, свой отступ, своя крыша. Поэтому вся группа соседних «зданий»
#  считается одной постройкой: общий план, общая высота, одна крыша.
#  Мазок кистью 3×3 сразу даёт нормальный дом.
#
#  ПРЕВРАЩЕНИЕ ПО КОНТЕКСТУ, как в плоской версии. Считаем этажи по высоте
#  группы:
#     один          -> низкий домик, острая крыша
#     два           -> дом повыше, плоская крыша
#     три и больше  -> башня, высокая острая крыша
#
#  ПРОЁМЫ. На первом этаже стены иногда получают дверь, выше — ряды окон.
#  Проёмы сделаны утопленными панелями, а не дырами: так проще, а зацепка для
#  растений уже есть — положение окна известно, и лиана может в него врасти.
# =============================================================================

const PlantsData = preload("res://Plants.gd")

const INSET: float = 0.16         # насколько стены отступают внутрь группы
const STOREY: float = 1.15        # высота одного этажа в единицах мира
const SINK: float = 0.22          # какая доля высоты утоплена в землю
const OPENING: float = 0.02       # насколько утоплены окна и двери

var main: Node3D
var nodes: Dictionary = {}        # ключ группы -> меш постройки
var openings: Dictionary = {}     # ключ группы -> список проёмов {pos, normal, door}
var _material: StandardMaterial3D


func setup(main_ref: Node3D) -> void:
	main = main_ref
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 0.85


func clear_all() -> void:
	# СНИМАЕМ СО СЦЕНЫ СРАЗУ: `rebuild_all` зовёт `clear_all` и тут же строит
	# заново, а отложенное удаление оставило бы старую постройку рисоваться
	# поверх новой целый кадр. Та же беда, что была у кусков земли.
	for key in nodes:
		var gone: Node = nodes[key]
		var parent: Node = gone.get_parent()
		if parent != null:
			parent.remove_child(gone)
		gone.queue_free()
	nodes.clear()
	openings.clear()


# Все проёмы мира — по ним растения ищут, куда врасти.
func all_openings() -> Array:
	var out: Array = []
	for key in openings:
		out.append_array(openings[key])
	return out


# Пересобираем сразу все постройки: групп немного, а от появления соседней
# ячейки меняется вся группа целиком, а не одна глыба.
func rebuild_all() -> void:
	clear_all()
	for members in main.components_of("building"):
		_build(members)


func _build(members: Array) -> void:
	var shape := _group_shape(members)
	if shape.is_empty():
		return
	var base: Array = shape["ring"]
	var centre: Vector3 = shape["centre"]
	var reach: float = shape["reach"]
	var height: float = shape["height"]

	var storeys := clampi(int(round(height / STOREY)), 1, 8)
	var salt: int = int(members[0]) * 887

	var card: Dictionary = PlantsData.ITEMS["building"]
	var wall_color := Color(card["color"]).lightened(0.14 * _hash01(salt))
	var roof_color := wall_color.darkened(0.34)
	var hole_color := wall_color.darkened(0.60)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var top_ring: Array = []
	for p in base:
		top_ring.append(p + Vector3.UP * height)

	var n := base.size()
	var found: Array = []
	for i in range(n):
		var j: int = (i + 1) % n
		st.set_color(wall_color.srgb_to_linear())
		_quad(st, base[i], base[j], top_ring[j], top_ring[i], centre)
		_add_openings(st, base[i], base[j], height, centre, storeys,
			salt + i * 13, hole_color, found)

	st.set_color(roof_color.srgb_to_linear())
	if storeys == 2:
		_flat_roof(st, top_ring, centre, reach * 0.12)
	else:
		_peaked_roof(st, top_ring, centre, reach * (0.55 if storeys == 1 else 0.95))

	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _material
	add_child(mi)
	var key: int = int(members[0])
	nodes[key] = mi
	openings[key] = found


# План и высота ВСЕЙ группы: выпуклая оболочка вершин всех её ячеек, отступ
# внутрь, низ утоплен в землю.
func _group_shape(members: Array) -> Dictionary:
	var flat := PackedVector2Array()
	var low := INF
	var high := -INF
	for cell in members:
		for f in main.grid.faces_of(cell):
			for idx in f["loop"]:
				var v: Vector3 = main.grid.verts[idx]
				flat.append(Vector2(v.x, v.z))
				low = minf(low, v.y)
				high = maxf(high, v.y)
	if flat.size() < 3:
		return {}
	var hull := Geometry2D.convex_hull(flat)
	if hull.size() < 3:
		return {}
	if hull[0].distance_squared_to(hull[hull.size() - 1]) < 0.000001:
		hull.remove_at(hull.size() - 1)

	var mid := Vector2.ZERO
	for p in hull:
		mid += p
	mid /= float(hull.size())

	var span: float = high - low
	var floor_y: float = low + span * SINK
	var ring: Array = []
	var reach := 0.0
	for p in hull:
		var inset_p := mid + (p - mid) * (1.0 - INSET)
		ring.append(Vector3(inset_p.x, floor_y, inset_p.y))
		reach += mid.distance_to(inset_p)
	reach /= float(hull.size())

	return {"ring": ring, "centre": Vector3(mid.x, floor_y, mid.y),
		"reach": reach, "height": maxf(high - floor_y, 0.3)}


# --- Крыши -------------------------------------------------------------------
func _flat_roof(st: SurfaceTool, ring: Array, centre: Vector3, lip: float) -> void:
	var top: Array = []
	for p in ring:
		top.append(p + Vector3.UP * lip)
	var n := ring.size()
	for i in range(n):
		_quad(st, ring[i], ring[(i + 1) % n], top[(i + 1) % n], top[i], centre)
	var mid := Vector3.ZERO
	for p in top:
		mid += p
	mid /= float(top.size())
	for i in range(n):
		_tri(st, top[i], top[(i + 1) % n], mid, centre - Vector3.UP * 10.0)


func _peaked_roof(st: SurfaceTool, ring: Array, centre: Vector3, rise: float) -> void:
	var mid := Vector3.ZERO
	for p in ring:
		mid += p
	mid /= float(ring.size())
	var apex := mid + Vector3.UP * rise
	var n := ring.size()
	for i in range(n):
		_tri(st, ring[i], ring[(i + 1) % n], apex, mid - Vector3.UP * 10.0)


# --- Проёмы ------------------------------------------------------------------
func _add_openings(st: SurfaceTool, a: Vector3, b: Vector3, height: float,
		inside: Vector3, storeys: int, salt: int, color: Color, found: Array) -> void:
	var width := a.distance_to(b)
	if width < 0.35:
		return
	var along := (b - a) / width
	var normal := ((a + b) * 0.5 - inside)
	normal.y = 0.0
	if normal.length() < 0.001:
		return
	normal = normal.normalized()
	st.set_color(color.srgb_to_linear())

	var floor_h: float = height / float(storeys)
	for level in range(storeys):
		var foot: float = float(level) * floor_h
		# Дверь бывает только внизу и не на каждой стене.
		if level == 0 and _hash01(salt) < 0.40:
			var w := minf(width * 0.22, floor_h * 0.30)
			var h := floor_h * 0.62
			var mid: Vector3 = (a + b) * 0.5 + Vector3.UP * foot
			_panel(st, mid, along, w, 0.0, h, normal, inside)
			found.append({"pos": mid + normal * 0.05 + Vector3.UP * h * 0.5,
				"normal": normal, "door": true})
			continue
		var count := clampi(int(width / 0.9), 1, 4)
		var w2 := minf(width / float(count) * 0.34, floor_h * 0.22)
		var h2 := w2 * 1.25
		for i in range(count):
			var u := (float(i) + 0.5) / float(count)
			var mid2: Vector3 = a.lerp(b, u)
			var lift: float = foot + floor_h * (0.34 + 0.16 * _hash01(salt + i * 7 + level * 3))
			_panel(st, mid2, along, w2, lift, h2, normal, inside)
			found.append({"pos": mid2 + normal * 0.05 + Vector3.UP * (lift + h2 * 0.5),
				"normal": normal, "door": false})


# Утопленная панель на стене — окно или дверь.
func _panel(st: SurfaceTool, mid: Vector3, along: Vector3, half: float,
		lift: float, height: float, normal: Vector3, inside: Vector3) -> void:
	var low := mid + Vector3.UP * lift
	var pts: Array = [
		low - along * half, low + along * half,
		low + along * half + Vector3.UP * height, low - along * half + Vector3.UP * height,
	]
	var sunk: Array = []
	for p in pts:
		sunk.append(p - normal * OPENING)
	_quad(st, sunk[0], sunk[1], sunk[2], sunk[3], inside)
	for i in range(4):
		var j: int = (i + 1) % 4
		_quad(st, pts[i], pts[j], sunk[j], sunk[i], inside)


# --- Мелочи ------------------------------------------------------------------
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, inside: Vector3) -> void:
	main._emit_polygon(st, [a, b, c], ((a + b + c) / 3.0 - inside).normalized())


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		inside: Vector3) -> void:
	main._emit_polygon(st, [a, b, c, d], ((a + b + c + d) / 4.0 - inside).normalized())


func _hash01(n: int) -> float:
	var x := (n * 1103515245 + 12345) & 0x7fffffff
	return float(x % 10007) / 10007.0
