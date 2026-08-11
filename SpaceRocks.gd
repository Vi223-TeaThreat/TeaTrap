extends Node3D
# =============================================================================
#  СКАЛЬНЫЕ ВЫХОДЫ — угловатые плиты, торчащие из дёрна.
#
#  На снимках скала никогда не замещает собой склон целиком: трава лежит
#  сплошным ковром, а сквозь неё под одним и тем же наклоном прорезаются
#  острые плиты сланца. Поэтому ячейка «скала» НЕ вырезается из земли:
#  поверхность мира идёт через неё как обычно (и остаётся гладкой), а сверху
#  ставятся плиты.
#
#  ПЛИТЫ ГРУППЫ СМОТРЯТ В ОДНУ СТОРОНУ. Это и есть главный признак настоящего
#  выхода породы: пласты залегают под общим углом. Направление и наклон берутся
#  один раз на всю связную группу.
#
#  ПРЕВРАЩЕНИЕ ПО КОНТЕКСТУ:
#     одна ячейка   -> одиночный валун, едва выступает
#     низкая группа -> гряда плит вдоль общего простирания
#     высокая группа-> зубец: плиты вытягиваются вверх тем сильнее,
#                      чем выше сама группа
# =============================================================================

const PlantsData = preload("res://Plants.gd")

const RISE: float = 0.42          # насколько плита торчит над поверхностью
const DEPTH: float = 0.9          # насколько уходит вниз (чтобы не парила)
const THIN: float = 0.30          # толщина плиты от размера ячейки
const DIP: float = 0.30           # наклон пласта от вертикали

var main: Node3D
var nodes: Dictionary = {}        # ключ группы -> меш
var _material: ShaderMaterial


func setup(main_ref: Node3D) -> void:
	main = main_ref
	# Тот же шейдер, что и у породы: камень светлеет кверху, зелень цепляется
	# только за пологие полки — ровно как на снимках.
	_material = ShaderMaterial.new()
	_material.shader = load("res://Terrain.gdshader")
	_material.set_shader_parameter("stone_override", 1.0)
	_material.set_shader_parameter("rock_dark", Color(0.17, 0.17, 0.17))
	_material.set_shader_parameter("rock_light", Color(0.44, 0.44, 0.42))
	_material.set_shader_parameter("mantle_stone", 0.80)
	_material.set_shader_parameter("mantle_rough", 0.35)
	_material.set_shader_parameter("cavity_dark", 0.0)


func clear_all() -> void:
	for key in nodes:
		nodes[key].queue_free()
	nodes.clear()


func rebuild_all() -> void:
	clear_all()
	for members in main.components_of("cliff"):
		_build(members)


func _build(members: Array) -> void:
	var salt: int = int(members[0]) * 613
	# Простирание пласта — одно на всю группу.
	var strike: float = _hash01(salt) * TAU
	var axis := Vector3(cos(strike), 0.0, sin(strike))
	var side := Vector3(-axis.z, 0.0, axis.x)
	var lean: float = (_hash01(salt + 5) * 2.0 - 1.0) * DIP

	var low := INF
	var high := -INF
	for cell in members:
		var s: Vector3 = main.grid.seeds[cell]
		low = minf(low, s.y)
		high = maxf(high, s.y)
	# Чем выше группа, тем более зубчатой она становится.
	var tall: float = clampf((high - low) / maxf(main.CELL_SPACING, 0.01), 0.0, 6.0)
	var grow: float = 1.0 + tall * 0.28

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var made := false
	for cell in members:
		# Плиту ставим только там, где ячейка выходит наружу: внутри массива
		# камня она всё равно никому не видна.
		if main._buried(cell):
			continue
		if _emit_slab(st, cell, axis, side, lean, grow, salt):
			made = true
	if not made:
		return

	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _material
	add_child(mi)
	nodes[int(members[0])] = mi


# Одна плита: вытянутый вдоль простирания клин, наклонённый и срезанный
# сверху под углом — отсюда острая кромка.
func _emit_slab(st: SurfaceTool, cell: int, axis: Vector3, side: Vector3,
		lean: float, grow: float, group_salt: int) -> bool:
	var faces: Array = main.grid.faces_of(cell)
	if faces.is_empty():
		return false
	var top := -INF
	var base := INF
	for f in faces:
		for idx in f["loop"]:
			var v: Vector3 = main.grid.verts[idx]
			top = maxf(top, v.y)
			base = minf(base, v.y)
	var seed_pos: Vector3 = main.grid.seeds[cell]
	var salt := group_salt + cell * 37
	var size: float = main.CELL_SPACING

	var half_long: float = size * (0.42 + 0.26 * _hash01(salt))
	var half_thin: float = size * THIN * (0.7 + 0.6 * _hash01(salt + 3))
	var rise: float = size * RISE * grow * (0.6 + 0.8 * _hash01(salt + 7))
	var foot: Vector3 = Vector3(seed_pos.x, base - size * DEPTH, seed_pos.z)
	# Наклон пласта: макушка сдвинута поперёк простирания.
	var tip: Vector3 = Vector3(seed_pos.x, top + rise, seed_pos.z) + side * (rise * lean)

	# Четыре угла подошвы и четыре — макушки; макушка уже и срезана наискось.
	var low_ring: Array = [
		foot + axis * half_long + side * half_thin,
		foot + axis * half_long - side * half_thin,
		foot - axis * half_long - side * half_thin,
		foot - axis * half_long + side * half_thin,
	]
	var narrow: float = 0.35 + 0.3 * _hash01(salt + 11)
	var skew: float = half_long * (0.3 + 0.5 * _hash01(salt + 13))
	var high_ring: Array = [
		tip + axis * (half_long * narrow + skew) + side * (half_thin * narrow),
		tip + axis * (half_long * narrow + skew) - side * (half_thin * narrow),
		tip - axis * (half_long * narrow - skew) - side * (half_thin * narrow),
		tip - axis * (half_long * narrow - skew) + side * (half_thin * narrow),
	]
	# Одну сторону макушки опускаем — получается скол, а не аккуратный столбик.
	var chip: float = rise * (0.25 + 0.4 * _hash01(salt + 17))
	high_ring[2] -= Vector3.UP * chip
	high_ring[3] -= Vector3.UP * chip

	var centre: Vector3 = (foot + tip) * 0.5
	for i in range(4):
		var j: int = (i + 1) % 4
		_quad(st, low_ring[i], low_ring[j], high_ring[j], high_ring[i], centre)
	_quad(st, high_ring[0], high_ring[1], high_ring[2], high_ring[3], centre)
	return true


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		inside: Vector3) -> void:
	main._emit_polygon(st, [a, b, c, d], ((a + b + c + d) * 0.25 - inside).normalized())


func _hash01(n: int) -> float:
	var x := (n * 1103515245 + 12345) & 0x7fffffff
	return float(x % 10007) / 10007.0
