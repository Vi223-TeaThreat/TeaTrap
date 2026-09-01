extends Node3D
# ФАЙЛ ЖДЁТ ПЕРЕЕЗДА. Объекты — валун, обломки, коряга — жили на кусочках
# ГРАНЕЙ ячеек, а граней у поверхности больше нет: она идёт по уровню
# заполнения сквозь ячейки. Ничего здесь не находит и не создаёт, но и не
# падает — словарь граней остался пустым.
#
# Переезжать так же, как переехали растения: объект живёт В ТОЧКЕ поверхности,
# место и наклон берутся у `SpaceGrid.surface_near`.
# =============================================================================
#  ОБЪЕКТЫ — третий класс наряду с поверхностью и растениями.
#
#  Камни, коряги, обломки, постройки. В отличие от породы объект не занимает
#  ячейку целиком и не сливается с соседями; в отличие от растения он не растёт
#  и не расползается. Он просто СТОИТ на кусочке поверхности.
#
#  Но живёт не сам по себе: объект даёт тень соседним кусочкам и образует
#  у своего подножия стык — а мох как раз любит тень и стыки. Поэтому зелень
#  сама собой начинает лепиться к камням и стенам.
#
#  Заглушки нарочно гранёные и простые: подробную графику делаем позже.
# =============================================================================

const PlantsData = preload("res://Plants.gd")

var main: Node3D
var props: Dictionary = {}        # кусочек Vector3i -> {id, node}
var _material: StandardMaterial3D
var _stone_material: ShaderMaterial


func setup(main_ref: Node3D) -> void:
	main = main_ref
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 0.9

	# Камни живут по тем же законам, что и порода вокруг, — тот же шейдер.
	# Только камень светлее (гранит) и зарастает скупее: зелень цепляется
	# лишь за самую макушку валуна.
	_stone_material = ShaderMaterial.new()
	_stone_material.shader = load("res://Terrain.gdshader")
	_stone_material.set_shader_parameter("stone_override", 1.0)
	_stone_material.set_shader_parameter("rock_dark", Color(0.33, 0.33, 0.34))
	_stone_material.set_shader_parameter("rock_light", Color(0.74, 0.74, 0.71))
	_stone_material.set_shader_parameter("mantle_stone", 0.74)
	_stone_material.set_shader_parameter("mantle_rough", 0.42)
	_stone_material.set_shader_parameter("turf_lit", Color(0.42, 0.52, 0.20))
	_stone_material.set_shader_parameter("turf_deep", Color(0.22, 0.32, 0.15))
	_stone_material.set_shader_parameter("cavity_dark", 0.0)


# =============================================================================
#  Постановка и снятие
# =============================================================================
func place(key: Vector3i, id: String) -> bool:
	if props.has(key) or not main.plants.spot_exists(key):
		return false
	props[key] = {"id": id, "node": null}
	_rebuild(key)
	main.plants.spot_blocked(key)
	return true


func remove_at(key: Vector3i) -> bool:
	if not props.has(key):
		return false
	if props[key]["node"] != null:
		_drop(props[key]["node"])
	props.erase(key)
	return true


# Убрать узел со сцены СЕЙЧАС, а освободить память потом. Одно место на все
# случаи: пока узел висит в дереве, он рисуется, чем бы его ни заменили.
func _drop(node: Node) -> void:
	if node == null:
		return
	var parent: Node = node.get_parent()
	if parent != null:
		parent.remove_child(node)
	node.queue_free()


func has_prop(key: Vector3i) -> bool:
	return props.has(key)


func is_empty() -> bool:
	return props.is_empty()


# Сколько тени объект отбрасывает на этот кусочек: смотрим, нет ли объектов
# по соседству.
func shade_at(neighbours: Array) -> float:
	var sum := 0.0
	for k in neighbours:
		if props.has(k):
			sum += float(PlantsData.ITEMS[props[k]["id"]]["shade"])
	return clampf(sum, 0.0, 1.0)


func any_near(neighbours: Array) -> bool:
	for k in neighbours:
		if props.has(k):
			return true
	return false


# Поверхность перестроилась — убираем то, что повисло в пустоте, и заново
# ставим уцелевшее: кусочки могли сдвинуться вместе с оболочкой.
func surface_changed() -> void:
	var doomed: Array = []
	for key in props:
		if not main.plants.spot_exists(key):
			doomed.append(key)
	for key in doomed:
		if props[key]["node"] != null:
			_drop(props[key]["node"])
		props.erase(key)
	for key in props:
		_rebuild(key)


# =============================================================================
#  Отрисовка заглушек
# =============================================================================
func _rebuild(key: Vector3i) -> void:
	var entry: Dictionary = props[key]
	if entry["node"] != null:
		# СНИМАЕМ СО СЦЕНЫ СРАЗУ. `queue_free` откладывает удаление до конца
		# кадра, и всё это время старый кусочек рисуется рядом с новым. А
		# `surface_changed` зовётся на КАЖДЫЙ мазок и пересобирает все кусочки —
		# то есть при удержании кисти они двоились непрерывно. Кадр
		# пользователя 2026-09-01: «вылезают странные объекты».
		_drop(entry["node"])
		entry["node"] = null

	var poly: Array = main.plants.patch_outline(key)
	if poly.size() < 3:
		return
	var def: Dictionary = PlantsData.ITEMS[entry["id"]]
	var salt := key.x * 977 + key.y * 61 + key.z * 19

	var base := Vector3.ZERO
	for p in poly:
		base += p
	base /= float(poly.size())
	var reach := 0.0
	for p in poly:
		reach += base.distance_to(p)
	reach /= float(poly.size())

	# Ось объекта: между нормалью поверхности и строгой вертикалью.
	var normal: Vector3 = main.plants.patch_normal(key)
	var up: Vector3 = normal.lerp(Vector3.UP, float(def["upright"])).normalized()
	if up.length() < 0.01:
		up = Vector3.UP
	var side := up.cross(Vector3.RIGHT)
	if side.length() < 0.1:
		side = up.cross(Vector3.FORWARD)
	side = side.normalized()
	var fwd := up.cross(side).normalized()
	# Разворот вокруг своей оси — чтобы одинаковые объекты не были близнецами.
	var spin := _hash01(salt + 3) * TAU
	var ax := side * cos(spin) + fwd * sin(spin)
	var az := up.cross(ax).normalized()

	var size: float = reach * float(def["size"])
	var color: Color = Color(def["color"]).lightened(0.16 * _hash01(salt + 5))

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(color.srgb_to_linear())
	match str(def["shape"]):
		"rock":
			_emit_rock(st, base, ax, up, az, size, salt)
		"debris":
			_emit_debris(st, base, ax, up, az, size, salt, color)
		"snag":
			_emit_snag(st, base, ax, up, az, size, salt, color)
		"hut":
			_emit_hut(st, base, ax, up, az, size, salt, color)

	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	# Каменное — тем же шейдером, что и порода; дерево остаётся деревом.
	var shape := str(def["shape"])
	mi.material_override = _stone_material if shape == "rock" or shape == "debris" else _material
	add_child(mi)
	entry["node"] = mi


# Камень — гранёный валун: восьмигранник с поведёнными вершинами.
func _emit_rock(st: SurfaceTool, base: Vector3, ax: Vector3, up: Vector3,
		az: Vector3, size: float, salt: int) -> void:
	var dirs := [ax, -ax, az, -az, up, -up * 0.25]
	var v: Array = []
	for i in range(dirs.size()):
		var stretch := 0.55 + 0.75 * _hash01(salt + i * 31)
		v.append(base + dirs[i] * size * stretch + up * size * 0.35)
	# Грани восьмигранника: каждая тройка «бок — бок — верх/низ».
	var sides := [[0, 2], [2, 1], [1, 3], [3, 0]]
	for pair in sides:
		_tri(st, v[pair[0]], v[pair[1]], v[4], base)
		_tri(st, v[pair[1]], v[pair[0]], v[5], base)


# Обломки — несколько плоских угловатых осколков.
func _emit_debris(st: SurfaceTool, base: Vector3, ax: Vector3, up: Vector3,
		az: Vector3, size: float, salt: int, color: Color) -> void:
	for i in range(3):
		var spin := _hash01(salt + i * 17) * TAU
		var dir := (ax * cos(spin) + az * sin(spin)).normalized()
		var off := dir * size * (0.15 + 0.45 * _hash01(salt + i * 7))
		var len_i := size * (0.35 + 0.4 * _hash01(salt + i * 11))
		var wide := size * (0.2 + 0.3 * _hash01(salt + i * 13))
		var tall := size * (0.18 + 0.3 * _hash01(salt + i * 23))
		st.set_color(color.darkened(0.12 * _hash01(salt + i * 5)).srgb_to_linear())
		var a := base + off + dir * len_i
		var b := base + off - dir * len_i * 0.6 + az.cross(dir) * wide
		var c := base + off - dir * len_i * 0.6 - az.cross(dir) * wide
		var top := base + off + up * tall
		_tri(st, a, b, top, base)
		_tri(st, b, c, top, base)
		_tri(st, c, a, top, base)


# Коряга — несколько сучьев, расходящихся от корня.
func _emit_snag(st: SurfaceTool, base: Vector3, ax: Vector3, up: Vector3,
		az: Vector3, size: float, salt: int, color: Color) -> void:
	var count := 2 + int(_hash01(salt) * 2.0)
	for i in range(count + 1):
		var spin := _hash01(salt + i * 29) * TAU
		var lean := 0.25 + 0.55 * _hash01(salt + i * 37)
		var dir := (up + (ax * cos(spin) + az * sin(spin)) * lean).normalized()
		var length := size * (0.7 + 0.7 * _hash01(salt + i * 41))
		var thick := size * (0.10 + 0.07 * _hash01(salt + i * 43))
		st.set_color(color.lightened(0.10 * _hash01(salt + i * 3)).srgb_to_linear())
		_limb(st, base - up * size * 0.1, base + dir * length, thick, ax, az, base)


# Постройка — коробка со скатной крышей.
func _emit_hut(st: SurfaceTool, base: Vector3, ax: Vector3, up: Vector3,
		az: Vector3, size: float, salt: int, color: Color) -> void:
	var w := size * (0.5 + 0.2 * _hash01(salt + 2))
	var d := size * (0.5 + 0.2 * _hash01(salt + 4))
	var h := size * (0.7 + 0.5 * _hash01(salt + 6))
	var low: Array = [
		base + ax * w + az * d, base - ax * w + az * d,
		base - ax * w - az * d, base + ax * w - az * d,
	]
	var high: Array = []
	for p in low:
		high.append(p + up * h)
	for i in range(4):
		var j: int = (i + 1) % 4
		_quad(st, low[i], low[j], high[j], high[i], base)
	# Крыша — двускатная, конёк вдоль длинной стороны.
	var ridge_a := base + up * (h + size * 0.45) + ax * w * 0.55
	var ridge_b := base + up * (h + size * 0.45) - ax * w * 0.55
	st.set_color(color.darkened(0.32).srgb_to_linear())
	_tri(st, high[0], high[1], ridge_b, base)
	_tri(st, high[0], ridge_b, ridge_a, base)
	_tri(st, high[2], high[3], ridge_a, base)
	_tri(st, high[2], ridge_a, ridge_b, base)
	_quad(st, high[3], high[0], ridge_a, ridge_a, base)
	_quad(st, high[1], high[2], ridge_b, ridge_b, base)


# Сук: сужающийся четырёхгранник от одной точки к другой.
func _limb(st: SurfaceTool, from: Vector3, to: Vector3, thick: float,
		ax: Vector3, az: Vector3, inside: Vector3) -> void:
	var dir := (to - from).normalized()
	var u := dir.cross(ax)
	if u.length() < 0.1:
		u = dir.cross(az)
	u = u.normalized()
	var w := dir.cross(u).normalized()
	var low: Array = [
		from + u * thick + w * thick, from - u * thick + w * thick,
		from - u * thick - w * thick, from + u * thick - w * thick,
	]
	var tip := thick * 0.35
	var high: Array = [
		to + u * tip + w * tip, to - u * tip + w * tip,
		to - u * tip - w * tip, to + u * tip - w * tip,
	]
	for i in range(4):
		var j: int = (i + 1) % 4
		_quad(st, low[i], low[j], high[j], high[i], inside)
	_quad(st, high[0], high[1], high[2], high[3], inside)


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, inside: Vector3) -> void:
	main._emit_polygon(st, [a, b, c], ((a + b + c) / 3.0 - inside).normalized())


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		inside: Vector3) -> void:
	main._emit_polygon(st, [a, b, c, d], ((a + b + c + d) / 4.0 - inside).normalized())


func _hash01(n: int) -> float:
	var x := (n * 1103515245 + 12345) & 0x7fffffff
	return float(x % 10007) / 10007.0
