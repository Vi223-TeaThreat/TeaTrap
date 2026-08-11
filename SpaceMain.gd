extends Node3D
# =============================================================================
#  ТРЁХМЕРНЫЙ МИР — ячейки-глыбы вместо плоских плиток.
#
#  Мир состоит из объёмных ячеек Вороного (см. SpaceGrid.gd). Часть из них
#  заполнена породой, остальные пусты. Игрок добавляет и убирает ячейки.
#
#  Рисуем только ГРАНИЦУ: грани между заполненной ячейкой и пустой. Грани
#  внутри массива не рисуются — поэтому соседние глыбы сливаются в одно тело.
#  Скругление рёбер будет следующим шагом; пока грани плоские.
# =============================================================================

const SpaceGridScript = preload("res://SpaceGrid.gd")
const ShellScript = preload("res://Shell.gd")
const SpacePlantsScript = preload("res://SpacePlants.gd")
const SpacePropsScript = preload("res://SpaceProps.gd")
const SpaceBuildingsScript = preload("res://SpaceBuildings.gd")
const SpaceRocksScript = preload("res://SpaceRocks.gd")
const PlantsData = preload("res://Plants.gd")
const SMOOTH_PASSES: int = 1         # сколько раз сглаживать оболочку

# --- Параметры мира ---
const ISLAND_RADIUS: float = 13.0
const ISLAND_TOP: float = 2.5
const ISLAND_BOTTOM: float = -3.5
const HEADROOM: float = 6.0          # запас высоты для построек
const CELL_SPACING: float = 0.6667   # втрое мельче прежнего — детальнее рельеф
const WORLD_SEED: int = 20260811

# --- Камера ---
const SMOOTH: float = 12.8
const ORBIT_SENS: float = 0.25
const MOUSE_PAN: float = 0.0016

var target_yaw: float = -30.0
var target_pitch: float = -30.0
var target_zoom: float = 42.0
var target_pivot: Vector3 = Vector3.ZERO
var cur_yaw: float = -30.0
var cur_pitch: float = -30.0
var cur_zoom: float = 42.0
var cur_pivot: Vector3 = Vector3.ZERO
var orbiting: bool = false
var panning: bool = false

var cam_pivot: Node3D
var camera: Camera3D

# --- Мир ---
var grid
var solid: Dictionary = {}
var nodes: Dictionary = {}        # ячейка -> невидимое тело для кликов
# Кусок держим примерно в три ячейки поперёк: тогда пересборка одного куска
# стоит столько же, сколько при крупной сетке, и отклик на клик не падает.
const CHUNK: float = 2.0          # размер куска оболочки

var chunk_cells: Dictionary = {}  # кусок -> {ячейка: true}
var chunk_nodes: Dictionary = {}  # кусок -> меш этого куска
var _dirty_chunks: Dictionary = {}
var face_geo: Dictionary = {}     # Vector2i(ячейка, грань) -> её вид после сглаживания
var edge_faces: Dictionary = {}   # ребро -> какие грани его делят
var cell_edges: Dictionary = {}   # ячейка -> её рёбра (чтобы снимать точечно)
var _dirty_edges: Dictionary = {} # у каких ячеек пересчитать рёбра
var _dirty_bodies: Dictionary = {}
var _buried_cache: Dictionary = {}
var brush: int = 1                # ширина кисти в ячейках: 1, 2 или 3
const FILL_BUDGET: int = 24       # мс на достройку мира за кадр
var fill_done: float = 0.0        # насколько мир достроен
var plants: Node3D
var props: Node3D
var buildings: Node3D
var rocks: Node3D
var current_tool: String = "block"
var branch_open: Dictionary = {}
var branch_headers: Dictionary = {}
var branch_boxes: Dictionary = {}
var group_open: Dictionary = {}
var group_headers: Dictionary = {}
var group_boxes: Dictionary = {}
var tool_buttons: Dictionary = {}
var speed_buttons: Array = []
var brush_buttons: Array = []
var time_scale: float = 1.0

const BRUSHES := [
	{"width": 1, "label": "1"},
	{"width": 2, "label": "2×2"},
	{"width": 3, "label": "3×3"},
]

const SPEEDS := [
	{"value": 0.0, "label": "стоп"},
	{"value": 0.5, "label": "½×"},
	{"value": 1.0, "label": "1×"},
	{"value": 2.0, "label": "2×"},
]
var history: Array = []

var frame_node: MeshInstance3D
var frame_id: String = ""
var fill_label: Label

var rock_mat: ShaderMaterial
var grass_mat: ShaderMaterial


func _ready() -> void:
	_setup_materials()
	_setup_environment()
	_setup_light()
	_setup_camera()
	_setup_frame()
	_setup_hint()
	_build_world()
	_setup_toolbar()

	plants = SpacePlantsScript.new()
	add_child(plants)
	plants.setup(self)

	props = SpacePropsScript.new()
	add_child(props)
	props.setup(self)

	buildings = SpaceBuildingsScript.new()
	add_child(buildings)
	buildings.setup(self)

	rocks = SpaceRocksScript.new()
	add_child(rocks)
	rocks.setup(self)

	var args := OS.get_cmdline_user_args()
	if "--selftest" in args:
		await _fill_world()
		_selftest()
	elif "--shot" in args:
		await _fill_world()
		_shot_mode()
	else:
		# Без ожидания: мир достраивается сам, а игра уже отвечает.
		_fill_world()


func _setup_materials() -> void:
	# Облик поверхности считает шейдер: дёрн ложится по наклону, порода
	# пятнистая, щели темнеют. Красить гранями нельзя — сквозь такую заливку
	# проступают сами ячейки.
	rock_mat = ShaderMaterial.new()
	rock_mat.shader = load("res://Terrain.gdshader")
	grass_mat = rock_mat


func _setup_environment() -> void:
	# Свет северный, пасмурный: солнце приглушено, зато небо светит со всех
	# сторон. Именно так выглядят мокрые мшистые склоны — без резких теней,
	# но с глубоким затемнением в щелях.
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.60, 0.66, 0.72)
	sky_mat.sky_horizon_color = Color(0.82, 0.85, 0.86)
	sky_mat.ground_horizon_color = Color(0.62, 0.64, 0.62)
	sky_mat.ground_bottom_color = Color(0.32, 0.36, 0.34)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.50

	# Затенение щелей: то, что на снимках даёт почти чёрные провалы между
	# валунами. Это расход на кадр, а не на действие игрока — отклик не страдает.
	env.ssao_enabled = true
	env.ssao_radius = 0.65
	env.ssao_intensity = 1.3
	env.ssao_power = 1.8
	env.ssao_detail = 0.6
	env.ssao_light_affect = 0.15

	# Лёгкая дымка: дальние обрывы бледнеют, глубина читается.
	env.fog_enabled = true
	env.fog_light_color = Color(0.74, 0.78, 0.80)
	env.fog_density = 0.0025
	env.fog_aerial_perspective = 0.25
	env.fog_sky_affect = 0.0

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.16
	env.adjustment_saturation = 0.98

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


func _setup_light() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-48, -38, 0)
	light.light_color = Color(1.0, 0.97, 0.91)
	light.light_energy = 1.20
	light.shadow_enabled = true
	light.directional_shadow_blend_splits = true
	add_child(light)


func _setup_camera() -> void:
	cam_pivot = Node3D.new()
	add_child(cam_pivot)
	camera = Camera3D.new()
	camera.near = 0.02        # чтобы вплотную ничего не срезалось
	cam_pivot.add_child(camera)
	camera.current = true
	_apply_camera()


func _process(delta: float) -> void:
	var t: float = 1.0 - exp(-delta * SMOOTH)
	cur_yaw = lerpf(cur_yaw, target_yaw, t)
	cur_pitch = lerpf(cur_pitch, target_pitch, t)
	cur_zoom = lerpf(cur_zoom, target_zoom, t)
	cur_pivot = cur_pivot.lerp(target_pivot, t)
	_apply_camera()
	_update_frame()
	if fill_label != null:
		fill_label.visible = fill_done < 1.0
		if fill_done < 1.0:
			fill_label.text = "остров достраивается — %d%%" % int(fill_done * 100.0)
	if not _dirty_chunks.is_empty() or not _dirty_bodies.is_empty():
		_flush_chunks()


func _apply_camera() -> void:
	cam_pivot.position = cur_pivot
	cam_pivot.rotation_degrees = Vector3(cur_pitch, cur_yaw, 0)
	camera.position = Vector3(0, 0, cur_zoom)
	camera.rotation_degrees = Vector3.ZERO


func _camera_flat_axes() -> Dictionary:
	var b := camera.global_transform.basis
	var forward := -b.z
	forward.y = 0.0
	var right := b.x
	right.y = 0.0
	return {"forward": forward.normalized(), "right": right.normalized()}


# --- Мир ---------------------------------------------------------------------
func _build_world() -> void:
	var started := Time.get_ticks_msec()
	grid = SpaceGridScript.new()
	grid.generate(ISLAND_RADIUS, ISLAND_TOP, ISLAND_BOTTOM, HEADROOM, CELL_SPACING, WORLD_SEED)
	solid = {}
	for i in grid.solid:
		solid[i] = "ground"
	var built := Time.get_ticks_msec()

	for i in solid:
		_track_chunk(i, true)
	print("Объёмная сетка: семян — ", grid.seeds.size(), ", породы — ", solid.size(),
		", кусков — ", chunk_cells.size())
	print("Время: семена и порода ", Time.get_ticks_msec() - started, " мс")


# Мир достраивается КУСКАМИ, от середины наружу, отпуская кадр между ними.
#
# Вырезать многогранник дорого, а при мелкой сетке их тысячи — весь остров
# сразу не собрать. Но замирать на это время игра не должна: камера ходит,
# панель отвечает, остров прорастает на глазах от центра к краям.
func _fill_world() -> void:
	var started := Time.get_ticks_msec()
	var order: Array = chunk_cells.keys()
	order.sort_custom(func(a, b):
		return Vector3(a).length_squared() < Vector3(b).length_squared())

	var budget := Time.get_ticks_msec() + FILL_BUDGET
	for n in range(order.size()):
		var ch = order[n]
		for c in chunk_cells[ch]:
			if not _buried(c):
				_rebuild_body(c)
		_rebuild_chunk(ch)
		if Time.get_ticks_msec() > budget:
			fill_done = float(n + 1) / float(order.size())
			await get_tree().process_frame
			budget = Time.get_ticks_msec() + FILL_BUDGET

	_rebuild_edge_map()
	fill_done = 1.0
	print("Достройка: ", Time.get_ticks_msec() - started, " мс, вырезано ячеек — ",
		grid.built_count(), ", из них вырезание ", grid.carve_usec / 1000, " мс")
	print("Граней у ячейки — ", grid.face_histogram())
	if "--reach" in OS.get_cmdline_user_args():
		_measure_reach()


func _occupied(cell: int) -> bool:
	return cell >= 0 and solid.has(cell)


# Земля и скала образуют ландшафт, здание — нет. Дом занимает объём ячейки
# сам, поэтому под ним не должно вырастать бугра породы.
func _is_terrain(cell: int) -> bool:
	if cell < 0 or not solid.has(cell):
		return false
	return material_of(cell) != "building"


# Погребена ли ячейка целиком в породе. Проверяем ПО СЕМЕНАМ, без вырезания:
# соседи ячейки заведомо лежат внутри радиуса отсечения, поэтому если там всё
# заполнено — наружу эта ячейка не выходит ничем. Такие не режем совсем:
# внутренность острова никогда не видна, а это большая часть его объёма.
# Дыр от этой проверки быть не может: отсечение при вырезании ячейки вообще
# не смотрит дальше `neighbour_reach()`, поэтому все соседи ячейки заведомо
# лежат внутри этого радиуса — тот же радиус проверяем и здесь.
#
# Ответ запоминаем: без этого проверка стоила бы дороже самой пересборки.
# Забывается она только вокруг места правки — глубже погребённость не меняется.
func _buried(cell: int) -> bool:
	if not solid.has(cell):
		return false
	if _buried_cache.has(cell):
		return _buried_cache[cell]
	# Условие обязано ТОЧНО повторять то, по которому кусок рисует грань:
	# грань появляется всюду, где сосед не ландшафт. Стоит смягчить проверку —
	# и в оболочке возникает дыра. Так и вышло: пустой сосед за границей мира
	# и сосед-здание считались «не в счёт», и грани к ним пропадали.
	var deep := true
	for j in grid.seeds_near(grid.seeds[cell], grid.neighbour_reach()):
		if not _is_terrain(j):
			deep = false
			break
	_buried_cache[cell] = deep
	return deep


func _forget_buried(cell: int) -> void:
	for j in grid.seeds_near(grid.seeds[cell], grid.neighbour_reach()):
		_buried_cache.erase(j)
	_buried_cache.erase(cell)


# Связные группы ячеек одного материала. И дом, и скальный выход строятся по
# ГРУППЕ целиком: при мелкой сетке одна ячейка размером с ведро, и постройка
# из одной ячейки — не постройка. Заодно отсюда берётся преобразование по
# контексту: чем группа больше и выше, тем другой у неё облик.
func components_of(material: String) -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	for cell in solid:
		if material_of(cell) != material or seen.has(cell):
			continue
		seen[cell] = true
		var stack: Array = [cell]
		var members: Array = []
		while not stack.is_empty():
			var c: int = stack.pop_back()
			members.append(c)
			for nb in grid.neighbors_of(c):
				if nb >= 0 and not seen.has(nb) and material_of(nb) == material:
					seen[nb] = true
					stack.append(nb)
		out.append(members)
	return out


# Из чего сложена ячейка: земля, скала или здание.
func material_of(cell: int) -> String:
	if not solid.has(cell):
		return ""
	var m = solid[cell]
	return m if m is String else "ground"


# Невидимое тело: по нему работают клики. Нужно только у ячеек, у которых
# есть выход наружу — до внутренних всё равно не дотянуться.
func _rebuild_body(cell: int) -> void:
	if nodes.has(cell):
		nodes[cell].queue_free()
		nodes.erase(cell)
	if not solid.has(cell) or _buried(cell):
		return

	var faces: Array = grid.faces_of(cell)
	var open := false
	for f in faces:
		if not _occupied(int(f["nb"])):
			open = true
			break
	if not open:
		return

	var hull := PackedVector3Array()
	var seen: Dictionary = {}
	for f in faces:
		for idx in f["loop"]:
			if not seen.has(idx):
				seen[idx] = true
				hull.append(grid.verts[idx])
	var shape := ConvexPolygonShape3D.new()
	shape.points = hull

	var body := StaticBody3D.new()
	body.set_meta("cell", cell)
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	add_child(body)
	nodes[cell] = body


func _chunk_of(cell: int) -> Vector3i:
	var p: Vector3 = grid.seeds[cell]
	return Vector3i(int(floor(p.x / CHUNK)), int(floor(p.y / CHUNK)),
		int(floor(p.z / CHUNK)))


func _track_chunk(cell: int, add: bool) -> void:
	var ch := _chunk_of(cell)
	if add:
		if not chunk_cells.has(ch):
			chunk_cells[ch] = {}
		chunk_cells[ch][cell] = true
	elif chunk_cells.has(ch):
		chunk_cells[ch].erase(cell)


# Изменилась одна ячейка — перестроить надо куски, которых это коснулось.
# Берём два кольца соседей: сглаживание тянется дальше самой ячейки.
func _mark_dirty_around(cell: int) -> void:
	var near: Dictionary = {cell: true}
	for nb in grid.neighbors_of(cell):
		if nb >= 0:
			near[nb] = true
	var reach: Dictionary = {}
	for c in near:
		reach[c] = true
		for nb in grid.neighbors_of(c):
			if nb >= 0:
				reach[nb] = true
	for c in reach:
		_dirty_chunks[_chunk_of(c)] = true
		_dirty_edges[c] = true


func _flush_chunks() -> void:
	for c in _dirty_bodies:
		_rebuild_body(c)
	_dirty_bodies.clear()
	for c in _dirty_edges:
		_drop_cell_edges(c)
	for c in _dirty_edges:
		_add_cell_edges(c)
	_dirty_edges.clear()
	for ch in _dirty_chunks:
		_rebuild_chunk(ch)
	_dirty_chunks.clear()
	# Постройки и скальные выходы строятся по группе целиком: добавили одну
	# ячейку — меняется вся группа, поэтому пересобираем их разом.
	if buildings != null:
		buildings.rebuild_all()
	if rocks != null:
		rocks.rebuild_all()
	if plants != null:
		plants.surface_changed()
	if props != null:
		props.surface_changed()


# Кто с кем граничит по ребру — по этому растения переползают с грани на грань.
#
# Пересобираем ТОЧЕЧНО, только вокруг правки. Полный обход всех ячеек породы
# при мелкой сетке стоил бы десятки миллисекунд на каждый клик — а рывок на
# действие игрока для этой игры недопустим.
func _rebuild_edge_map() -> void:
	edge_faces = {}
	cell_edges = {}
	for cell in solid:
		_add_cell_edges(cell)


func _drop_cell_edges(cell: int) -> void:
	if not cell_edges.has(cell):
		return
	for ek in cell_edges[cell]:
		if not edge_faces.has(ek):
			continue
		var list: Array = edge_faces[ek]
		for i in range(list.size() - 1, -1, -1):
			if list[i].x == cell:
				list.remove_at(i)
		if list.is_empty():
			edge_faces.erase(ek)
	cell_edges.erase(cell)


func _add_cell_edges(cell: int) -> void:
	if not _is_terrain(cell) or _buried(cell):
		return
	var cell_faces: Array = grid.faces_of(cell)
	var mine: Array = []
	for fi in range(cell_faces.size()):
		if _is_terrain(int(cell_faces[fi]["nb"])):
			continue
		var loop: PackedInt32Array = cell_faces[fi]["loop"]
		var n := loop.size()
		var key := Vector2i(cell, fi)
		for k in range(n):
			var ek := Vector2i(mini(loop[k], loop[(k + 1) % n]),
				maxi(loop[k], loop[(k + 1) % n]))
			if not edge_faces.has(ek):
				edge_faces[ek] = []
			edge_faces[ek].append(key)
			mine.append(ek)
	cell_edges[cell] = mine


# Оболочка режется на куски. Считаем кусок вместе с ОРЕОЛОМ соседних граней —
# сглаживание тянется через границу куска, и без ореола на стыках был бы шов.
# А рисуем только свои грани.
func _rebuild_chunk(chunk: Vector3i) -> void:
	if chunk_nodes.has(chunk):
		chunk_nodes[chunk].queue_free()
		chunk_nodes.erase(chunk)
	if not chunk_cells.has(chunk) or chunk_cells[chunk].is_empty():
		return
	var own: Dictionary = chunk_cells[chunk]

	# Погребённые ячейки пропускаем: у них нет ни одной грани наружу, так что
	# ни в картинку, ни в ореол сглаживания они всё равно не попадают.
	var halo: Dictionary = {}
	for c in own:
		if not _is_terrain(c) or _buried(c):
			continue
		halo[c] = true
		for nb in grid.neighbors_of(c):
			if _is_terrain(nb) and not _buried(nb):
				halo[nb] = true

	# Прежние записи о гранях этого куска снимаем целиком: грань могла
	# перестать быть границей — например, к ней пристроили соседа. Ниже
	# заново запомнятся только те, что и правда смотрят наружу.
	for c in own:
		_forget_faces(c)

	var used: Dictionary = {}
	var faces: Array = []
	var keys: Array = []          # чья это грань: Vector2i(ячейка, номер грани)
	var colors := PackedColorArray()
	var mine := PackedByteArray()

	var holds := PackedFloat32Array()
	var stones := PackedFloat32Array()
	for cell in halo:
		var card: Dictionary = PlantsData.ITEMS.get(material_of(cell), PlantsData.ITEMS["ground"])
		var stiff: float = card["hold"]
		var stone: float = float(card.get("stone", 0.0))
		# Цвет здесь только запасной: облик поверхности целиком решает шейдер
		# (`Terrain.gdshader`) — по наклону и высоте, попиксельно. Раскрашивать
		# гранями нельзя, иначе сквозь картинку проступают сами ячейки.
		var base := Color(card["color"]).srgb_to_linear()
		var cell_faces: Array = grid.faces_of(cell)
		for fi in range(cell_faces.size()):
			var f: Dictionary = cell_faces[fi]
			if _is_terrain(int(f["nb"])):
				continue
			var loop: PackedInt32Array = f["loop"]
			for idx in loop:
				used[idx] = true
			faces.append(loop)
			keys.append(Vector2i(cell, fi))
			colors.append(base)
			mine.append(1 if own.has(cell) else 0)
			holds.append(stiff)
			stones.append(stone)

	if faces.is_empty():
		return

	# Берём только те вершины, что участвуют в границе, и перенумеровываем.
	var remap: Dictionary = {}
	var verts := PackedVector3Array()
	for idx in used:
		remap[idx] = verts.size()
		verts.append(grid.verts[idx])
	var packed: Array = []
	for loop in faces:
		var out := PackedInt32Array()
		for idx in loop:
			out.append(remap[idx])
		packed.append(out)

	var emit := mine
	for pass_i in range(SMOOTH_PASSES):
		var step := ShellScript.subdivide(verts, packed, colors, holds)
		if pass_i == 0:
			_store_face_geometry(step, keys, packed, own)
		# Метка «своё / ореол» и порода передаются потомкам каждой грани.
		var owners: PackedInt32Array = step["owners"]
		var next_emit := PackedByteArray()
		var next_stone := PackedFloat32Array()
		next_emit.resize(owners.size())
		next_stone.resize(owners.size())
		for i in range(owners.size()):
			next_emit[i] = emit[owners[i]]
			next_stone[i] = stones[owners[i]]
		emit = next_emit
		stones = next_stone
		verts = step["verts"]
		packed = step["faces"]
		colors = step["colors"]
		holds = step["hold"]

	var mesh := ShellScript.build_mesh(verts, packed, colors, emit, stones)
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = rock_mat
	add_child(mi)
	chunk_nodes[chunk] = mi


# Забыть, во что превращались грани этой ячейки. Обязательно звать, когда
# грань перестала быть границей: растения живут ИМЕННО по этим записям, и
# оставшаяся запись про исчезнувшую грань — это мох, висящий в воздухе.
func _forget_faces(cell: int) -> void:
	if not grid.is_built(cell):
		return                        # не вырезана — записей о ней и нет
	for fi in range(grid.faces_of(cell).size()):
		face_geo.erase(Vector2i(cell, fi))


# Запоминаем, во что превратилась каждая грань после сглаживания: углы,
# точки рёбер и середину. На этих кусочках и живут растения.
func _store_face_geometry(step: Dictionary, keys: Array, source: Array,
		own: Dictionary) -> void:
	var moved: PackedVector3Array = step["moved"]
	var face_pt: PackedVector3Array = step["face_pt"]
	var edge_pt: PackedVector3Array = step["edge_pt"]
	var edge_id: Dictionary = step["edge_id"]
	for i in range(source.size()):
		var key: Vector2i = keys[i]
		if not own.has(key.x):
			continue                  # ореол чужой — его геометрию не запоминаем
		var loop: PackedInt32Array = source[i]
		var n := loop.size()
		var corners := PackedVector3Array()
		var mids := PackedVector3Array()
		for k in range(n):
			corners.append(moved[loop[k]])
			var a: int = loop[k]
			var b: int = loop[(k + 1) % n]
			mids.append(edge_pt[int(edge_id[Vector2i(mini(a, b), maxi(a, b))])])
		face_geo[key] = {"corners": corners, "mids": mids, "mid": face_pt[i]}


# Ни тела для кликов, ни куски оболочки не трогаем прямо сейчас — только
# помечаем. Всё делается один раз за кадр: мазок кистью в три ячейки шириной
# меняет три десятка глыб, и пересобирать каждую по отдельности значило бы
# сделать то же самое двадцать раз подряд.
func _refresh(cell: int) -> void:
	_dirty_bodies[cell] = true
	for nb in grid.neighbors_of(cell):
		if nb >= 0:
			_dirty_bodies[nb] = true
	_mark_dirty_around(cell)


func _place(cell: int, material: String = "ground", record: bool = true) -> void:
	if cell < 0 or solid.has(cell) or not grid.is_valid(cell):
		return
	solid[cell] = material
	_forget_buried(cell)
	_track_chunk(cell, true)
	if record:
		history.append({"cell": cell, "added": true})
	_refresh(cell)


func _remove(cell: int, record: bool = true) -> void:
	if not solid.has(cell):
		return
	var was := material_of(cell)
	solid.erase(cell)
	_forget_buried(cell)
	# Ячейка выбывает из куска, и пересборка про неё уже не вспомнит —
	# значит, прибираем её грани прямо сейчас, иначе мох останется висеть.
	_forget_faces(cell)
	_track_chunk(cell, false)
	if record:
		history.append({"cell": cell, "added": false, "was": was})
	_refresh(cell)


# --- Кисть -------------------------------------------------------------------
# Ширина 1 — одна ячейка, 2 и 3 — кустик соседних. Мир не решётчатый, поэтому
# «2×2» и «3×3» означают не квадрат, а всё, что попало в круг такой ширины.
func _brush_cells(centre: int) -> Array:
	if centre < 0:
		return []
	if brush <= 1:
		return [centre]
	var out: Array = [centre]
	for j in grid.seeds_near(grid.seeds[centre], CELL_SPACING * float(brush) * 0.5):
		if j != centre:
			out.append(j)
	return out


# Весь мазок — одно действие: отмена снимает его целиком.
func _paint(target: int, material: String) -> void:
	var group: Array = []
	for c in _brush_cells(target):
		if c < 0 or solid.has(c) or not grid.is_valid(c):
			continue
		_place(c, material, false)
		group.append({"cell": c, "added": true})
	if not group.is_empty():
		history.append({"group": group})


func _erase(hit: int) -> void:
	var group: Array = []
	for c in _brush_cells(hit):
		if not solid.has(c):
			continue
		group.append({"cell": c, "added": false, "was": material_of(c)})
		_remove(c, false)
	if not group.is_empty():
		history.append({"group": group})


func _undo() -> void:
	if history.is_empty():
		return
	var a = history.pop_back()
	if a.has("group"):
		var g: Array = a["group"]
		for i in range(g.size() - 1, -1, -1):
			var e: Dictionary = g[i]
			if bool(e["added"]):
				_remove(e["cell"], false)
			else:
				_place(e["cell"], e.get("was", "ground"), false)
	elif a.has("prop"):
		props.remove_at(a["prop"])
	elif a.has("spot"):
		plants.remove_at(a["spot"])
	elif a["added"]:
		_remove(a["cell"], false)
	else:
		_place(a["cell"], a.get("was", "ground"), false)


# --- Что под курсором --------------------------------------------------------
func _pick(screen_pos: Vector2) -> Dictionary:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 2000.0)
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	var body = null if result.is_empty() else result.collider
	if body == null or not body.has_meta("cell"):
		# Опереться не на что — целимся в плоскость земли. Так можно начать
		# заново, если на карте не осталось ни одной глыбы.
		if absf(dir.y) < 0.001:
			return {}
		var t := -from.y / dir.y
		if t <= 0.0:
			return {}
		var ground: int = grid.cell_at(from + dir * t)
		if ground < 0 or not grid.is_valid(ground):
			return {}
		return {"hit": -1, "target": ground}

	var hit: int = body.get_meta("cell")
	# Ставим в соседа за той гранью, в которую попали.
	var best := -1
	var best_dot := -2.0
	for f in grid.faces_of(hit):
		var pts: Array = []
		for idx in f["loop"]:
			pts.append(grid.verts[idx])
		var nrm := _face_normal(pts, grid.seeds[hit])
		var d := nrm.dot(result.normal)
		if d > best_dot:
			best_dot = d
			best = int(f["nb"])
	return {"hit": hit, "target": best}


# --- Подсветка грани ---------------------------------------------------------
func _setup_frame() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 1, 1)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	frame_node = MeshInstance3D.new()
	frame_node.material_override = mat
	frame_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	frame_node.visible = false
	add_child(frame_node)


# Показываем тонкий контур того, что появится по клику: глыбы или пятачка.
func _update_frame() -> void:
	if PlantsData.is_plant(current_tool) or PlantsData.is_prop(current_tool):
		_update_frame_spot()
		return
	var pick := _pick(get_viewport().get_mouse_position())
	var target: int = -1 if pick.is_empty() else int(pick["target"])
	if target < 0 or not grid.is_valid(target) or solid.has(target):
		frame_node.visible = false
		frame_id = ""
		return

	frame_node.visible = true
	var id := "%d:%d" % [target, brush]
	if id == frame_id:
		return
	frame_id = id

	# Обводим весь мазок целиком: рисуем только те грани, что смотрят наружу
	# кисти. Иначе внутренние перегородки превратили бы контур в кашу.
	var inside: Dictionary = {}
	for c in _brush_cells(target):
		if c >= 0 and grid.is_valid(c) and not solid.has(c):
			inside[c] = true

	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, frame_node.material_override)
	var drawn: Dictionary = {}
	for c in inside:
		var centre: Vector3 = grid.seeds[c]
		for f in grid.faces_of(c):
			if inside.has(int(f["nb"])):
				continue
			var loop: PackedInt32Array = f["loop"]
			var n := loop.size()
			for k in range(n):
				var a: int = loop[k]
				var b: int = loop[(k + 1) % n]
				var key := Vector2i(mini(a, b), maxi(a, b))
				if drawn.has(key):
					continue
				drawn[key] = true
				# Чуть подтягиваем к центру, чтобы линия не тонула в соседях.
				mesh.surface_add_vertex(centre + (grid.verts[a] - centre) * 0.97)
				mesh.surface_add_vertex(centre + (grid.verts[b] - centre) * 0.97)
	mesh.surface_end()
	frame_node.mesh = mesh


# Куда указывает курсор на поверхности: ячейка, грань и её угол.
func _pick_spot(screen_pos: Vector2) -> Dictionary:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 2000.0)
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return {}
	var body = result.collider
	if body == null or not body.has_meta("cell"):
		return {}
	var cell: int = body.get_meta("cell")

	# Ищем среди кусочков этой глыбы и её соседей — тогда у края выбирается
	# именно тот кусочек, на который смотрит курсор.
	var around: Array = [cell]
	for nb in grid.neighbors_of(cell):
		if nb >= 0:
			around.append(nb)
	var key: Vector3i = plants.spot_under_ray(from, dir, around)
	if key.x < 0:
		return {}
	return {"key": key}


func _try_put(screen_pos: Vector2) -> void:
	var spot := _pick_spot(screen_pos)
	if spot.is_empty():
		return
	var key: Vector3i = spot["key"]
	if PlantsData.is_prop(current_tool):
		if props.place(key, current_tool):
			history.append({"prop": key})
	elif plants.plant_at(key, current_tool):
		history.append({"spot": key})


# Убрать с кусочка то, что на нём стоит или растёт.
func _try_clear(screen_pos: Vector2) -> void:
	var spot := _pick_spot(screen_pos)
	if spot.is_empty():
		return
	var key: Vector3i = spot["key"]
	if not props.remove_at(key):
		plants.remove_at(key)


# --- Панель ярусов -----------------------------------------------------------
func _setup_toolbar() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var panel := PanelContainer.new()
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.06, 0.08, 0.07, 0.55)
	box.content_margin_left = 10
	box.content_margin_right = 18
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	box.corner_radius_top_right = 10
	box.corner_radius_bottom_right = 10
	panel.add_theme_stylebox_override("panel", box)
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 12
	panel.offset_bottom = -12
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.grow_horizontal = Control.GROW_DIRECTION_END
	layer.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 1)
	panel.add_child(column)

	var speed_title := Label.new()
	speed_title.text = "Время"
	speed_title.modulate = Color(1, 1, 1, 0.55)
	column.add_child(speed_title)

	var speed_row := HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 2)
	column.add_child(speed_row)
	for i in range(SPEEDS.size()):
		var sb := Button.new()
		sb.flat = true
		sb.focus_mode = Control.FOCUS_NONE
		sb.pressed.connect(_set_time_scale.bind(i))
		speed_row.add_child(sb)
		speed_buttons.append(sb)

	var brush_title := Label.new()
	brush_title.text = "Кисть"
	brush_title.modulate = Color(1, 1, 1, 0.55)
	column.add_child(brush_title)

	var brush_row := HBoxContainer.new()
	brush_row.add_theme_constant_override("separation", 2)
	column.add_child(brush_row)
	for w in BRUSHES:
		var bb := Button.new()
		bb.flat = true
		bb.focus_mode = Control.FOCUS_NONE
		bb.pressed.connect(_set_brush.bind(int(w["width"])))
		brush_row.add_child(bb)
		brush_buttons.append(bb)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 8)
	column.add_child(gap)

	# Три пункта верхнего уровня. Ярусы растительности вложены внутрь одного
	# из них — иначе список занимал бы полэкрана.
	for group in PlantsData.GROUPS:
		var g: int = group["key"]
		var head := Button.new()
		head.flat = true
		head.alignment = HORIZONTAL_ALIGNMENT_LEFT
		head.focus_mode = Control.FOCUS_NONE
		head.pressed.connect(_toggle_group.bind(g))
		column.add_child(head)

		var body := VBoxContainer.new()
		body.add_theme_constant_override("separation", 0)
		column.add_child(body)

		var tiers: Array = group["tiers"]
		var single: bool = tiers.size() == 1
		for t in tiers:
			if not single:
				# Внутри «Растений» ярусы остаются отдельными подпунктами.
				var sub := Button.new()
				sub.flat = true
				sub.alignment = HORIZONTAL_ALIGNMENT_LEFT
				sub.focus_mode = Control.FOCUS_NONE
				sub.pressed.connect(_toggle_branch.bind(t))
				body.add_child(sub)
				branch_headers[t] = sub

			var items := VBoxContainer.new()
			items.add_theme_constant_override("separation", 0)
			body.add_child(items)
			branch_boxes[t] = items
			# Развёрнуты те ветки, где уже что-то есть — пустые не мозолят глаз.
			branch_open[t] = single or not PlantsData.of_tier(t).is_empty()

			var ids := PlantsData.of_tier(t)
			for id in ids:
				var button := Button.new()
				button.flat = true
				button.alignment = HORIZONTAL_ALIGNMENT_LEFT
				button.focus_mode = Control.FOCUS_NONE
				button.pressed.connect(_select_tool.bind(id))
				items.add_child(button)
				tool_buttons[id] = button
			if ids.is_empty():
				var empty := Label.new()
				empty.text = "           пока пусто"
				empty.modulate = Color(1, 1, 1, 0.35)
				items.add_child(empty)

		group_headers[g] = head
		group_boxes[g] = body
		group_open[g] = true

	_refresh_toolbar()


func _toggle_group(group: int) -> void:
	group_open[group] = not group_open[group]
	_refresh_toolbar()


func _toggle_branch(tier: int) -> void:
	branch_open[tier] = not branch_open[tier]
	_refresh_toolbar()


func _select_tool(id: String) -> void:
	current_tool = id
	frame_id = ""
	_refresh_toolbar()


func _set_time_scale(index: int) -> void:
	time_scale = SPEEDS[index]["value"]
	if plants != null:
		plants.time_scale = time_scale
	_refresh_toolbar()


func _set_brush(width: int) -> void:
	brush = width
	frame_id = ""            # контур показывает мазок целиком — пересобрать
	_refresh_toolbar()


func _refresh_toolbar() -> void:
	for i in range(SPEEDS.size()):
		var chosen: bool = is_equal_approx(time_scale, SPEEDS[i]["value"])
		speed_buttons[i].text = "[%s]" % SPEEDS[i]["label"] if chosen else " %s " % SPEEDS[i]["label"]
		speed_buttons[i].modulate = Color(1, 1, 1, 1.0 if chosen else 0.5)
	for i in range(BRUSHES.size()):
		var picked: bool = brush == int(BRUSHES[i]["width"])
		brush_buttons[i].text = "[%s]" % BRUSHES[i]["label"] if picked else " %s " % BRUSHES[i]["label"]
		brush_buttons[i].modulate = Color(1, 1, 1, 1.0 if picked else 0.5)
	for group in PlantsData.GROUPS:
		var g: int = group["key"]
		var open: bool = group_open[g]
		group_headers[g].text = "%s  %d · %s" % ["▾" if open else "▸", g, group["name"]]
		group_boxes[g].visible = open
		for t in group["tiers"]:
			var info := PlantsData.tier_info(t)
			if branch_headers.has(t):
				var hint: String = info["hint"]
				var suffix := "" if hint == "" else "  (%s)" % hint
				branch_headers[t].text = "    %s  %s%s" % [
					"▾" if branch_open[t] else "▸", info["name"], suffix]
			branch_boxes[t].visible = branch_open[t] or not branch_headers.has(t)
	for id in tool_buttons:
		var mark := "●" if id == current_tool else "○"
		tool_buttons[id].text = "     %s  %s" % [mark, PlantsData.ITEMS[id]["name"]]


# В режиме посадки обводим сам кусочек поверхности, куда ляжет растение.
func _update_frame_spot() -> void:
	var spot := _pick_spot(get_viewport().get_mouse_position())
	if spot.is_empty():
		frame_node.visible = false
		frame_id = ""
		return
	var key: Vector3i = spot["key"]
	frame_node.visible = true
	var id := "s%d_%d_%d" % [key.x, key.y, key.z]
	if id == frame_id:
		return
	frame_id = id

	var poly: Array = plants.patch_outline(key)
	if poly.size() < 3:
		frame_node.visible = false
		return
	var lift: Vector3 = plants._patch_normal(key) * 0.015
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, frame_node.material_override)
	for i in range(poly.size()):
		mesh.surface_add_vertex(poly[i] + lift)
		mesh.surface_add_vertex(poly[(i + 1) % poly.size()] + lift)
	mesh.surface_end()
	frame_node.mesh = mesh


func _setup_hint() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var label := Label.new()
	label.text = "ЛКМ — поставить · Shift + ЛКМ — убрать · 2-я боковая — убрать\n1-я боковая / Ctrl+Z — отменить (мазок кистью снимается целиком)\nПКМ — вращать · средняя — двигать · колесо — приближение\nЦифры 1-3 — свернуть раздел · ширина кисти — в панели слева"
	label.position = Vector2(16, 16)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	layer.add_child(label)

	# Пока остров достраивается, честно показываем, сколько уже готово.
	fill_label = Label.new()
	fill_label.position = Vector2(16, 112)
	fill_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	fill_label.add_theme_color_override("font_outline_color", Color.BLACK)
	fill_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(fill_label)


# --- Ввод --------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			panning = event.pressed
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if PlantsData.is_plant(current_tool) or PlantsData.is_prop(current_tool):
				if event.shift_pressed:
					_try_clear(event.position)
				else:
					_try_put(event.position)
			else:
				var pick := _pick(event.position)
				if not pick.is_empty():
					if event.shift_pressed:
						_erase(int(pick["hit"]))
					else:
						_paint(int(pick["target"]), current_tool)
		elif event.button_index == MOUSE_BUTTON_XBUTTON1 and event.pressed:
			_undo()                                    # 1-я боковая — отмена
		elif event.button_index == MOUSE_BUTTON_XBUTTON2 and event.pressed:
			var kill := _pick(event.position)          # 2-я боковая — удалить
			if not kill.is_empty():
				_erase(int(kill["hit"]))
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			target_zoom = clampf(target_zoom * 0.9, 0.8, 140.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			target_zoom = clampf(target_zoom * 1.1, 0.8, 140.0)
	elif event is InputEventMouseMotion:
		if orbiting:
			target_yaw -= event.relative.x * ORBIT_SENS
			target_pitch = clampf(target_pitch - event.relative.y * ORBIT_SENS, -85.0, -5.0)
		elif panning:
			var flat := _camera_flat_axes()
			var scale := cur_zoom * MOUSE_PAN
			target_pivot += (-flat.right * event.relative.x + flat.forward * event.relative.y) * scale
	elif event is InputEventKey and event.pressed:
		if event.keycode == KEY_Z and event.ctrl_pressed:
			_undo()
		elif event.keycode >= KEY_1 and event.keycode <= KEY_3:
			_toggle_group(event.keycode - KEY_1 + 1)


# --- Геометрия ---------------------------------------------------------------
func _hash01(n: int) -> float:
	var x := (n * 1103515245 + 12345) & 0x7fffffff
	return float(x % 10007) / 10007.0


func _face_normal(pts: Array, inside: Vector3) -> Vector3:
	var n := Vector3.ZERO
	var m := pts.size()
	for i in range(m):
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[(i + 1) % m]
		n.x += (a.y - b.y) * (a.z + b.z)
		n.y += (a.z - b.z) * (a.x + b.x)
		n.z += (a.x - b.x) * (a.y + b.y)
	if n.length() < 0.000001:
		return Vector3.UP
	n = n.normalized()
	var mid := Vector3.ZERO
	for p in pts:
		mid += p
	mid /= float(m)
	return -n if n.dot(mid - inside) < 0.0 else n


# В Godot лицевая сторона грани — обход ПО ЧАСОВОЙ стрелке снаружи.
func _emit_polygon(st: SurfaceTool, pts: Array, want: Vector3) -> void:
	var seq: Array = pts.duplicate()
	var n := Vector3.ZERO
	var m := seq.size()
	for i in range(m):
		var a: Vector3 = seq[i]
		var b: Vector3 = seq[(i + 1) % m]
		n.x += (a.y - b.y) * (a.z + b.z)
		n.y += (a.z - b.z) * (a.x + b.x)
		n.z += (a.x - b.x) * (a.y + b.y)
	if n.length() < 0.000001:
		return
	n = n.normalized()
	var outward: Vector3
	if n.dot(want) > 0.0:
		outward = n
		seq.reverse()
	else:
		outward = -n
	for i in range(1, seq.size() - 1):
		st.set_normal(outward)
		st.add_vertex(seq[0])
		st.set_normal(outward)
		st.add_vertex(seq[i])
		st.set_normal(outward)
		st.add_vertex(seq[i + 1])


# =============================================================================
#  Служебные режимы
# =============================================================================
# Как далеко на самом деле лежат соседи ячейки. По этому числу выставляется
# радиус проверки погребённости: меньше — быстрее старт, но появятся дыры.
func _measure_reach() -> void:
	var worst := 0.0
	var bins: Dictionary = {}
	for cell in solid:
		if not grid.is_valid(cell):
			continue
		var here: Vector3 = grid.seeds[cell]
		for nb in grid.neighbors_of(cell):
			if nb < 0:
				continue
			var d: float = here.distance_to(grid.seeds[nb]) / CELL_SPACING
			worst = maxf(worst, d)
			var b: int = int(d * 10.0)
			bins[b] = int(bins.get(b, 0)) + 1
	var keys := bins.keys()
	keys.sort()
	var total := 0
	for k in keys:
		total += bins[k]
	var seen := 0
	var p999 := 0.0
	for k in keys:
		seen += bins[k]
		if float(seen) / float(total) >= 0.999 and p999 == 0.0:
			p999 = float(k) / 10.0
	print("Соседи: самый дальний ", snappedf(worst, 0.01), " шага, 99.9% ближе ",
		p999, " шага, всего связей ", total)


func _selftest() -> void:
	var start: int = grid.cell_at(Vector3(0, 6, 0))
	# Меряем полный отклик на клик: изменение мира плюс пересборка кусков.
	var t0 := Time.get_ticks_usec()
	_place(start)
	_flush_chunks()
	var place_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var t_del := Time.get_ticks_usec()
	_remove(start)
	_flush_chunks()
	var remove_ms := (Time.get_ticks_usec() - t_del) / 1000.0
	print("Отклик на клик: поставить ", snappedf(place_ms, 0.1),
		" мс, убрать ", snappedf(remove_ms, 0.1), " мс, кусков — ", chunk_nodes.size())

	# Кисть: мазок должен ставить куст ячеек и сниматься ОДНОЙ отменой.
	# Меряем дважды: на нетронутом месте (ячейки ещё не вырезаны) и на том же
	# месте повторно. В игре между наведением и щелчком проходит время, и
	# подсветка контура успевает прогреть место заранее — то есть настоящий
	# щелчок ближе ко второму числу.
	for width in [2, 3]:
		brush = width
		var was := solid.size()
		var added := 0
		var cold := 0.0
		var warm := 0.0
		for pass_i in range(2):
			var t_brush := Time.get_ticks_usec()
			_paint(grid.cell_at(Vector3(0, 6, 0)), "ground")
			_flush_chunks()
			var ms := (Time.get_ticks_usec() - t_brush) / 1000.0
			if pass_i == 0:
				cold = ms
				added = solid.size() - was
			else:
				warm = ms
			_undo()
			_flush_chunks()
		print("Кисть ", width, "×", width, ": ", added, " ячеек, вхолодную ",
			snappedf(cold, 0.1), " мс, по прогретому ", snappedf(warm, 0.1),
			" мс, после отмены осталось ", solid.size() - was)
	brush = 1

	# Удаление настоящей ячейки породы, у которой есть видимый меш.
	var victim := -1
	for c in nodes:
		victim = c
		break
	var before := nodes.size()
	_remove(victim)
	_flush_chunks()
	print("Удаление породы: ячейка ", victim, ", была в породе — ", not solid.has(victim),
		", узлов было ", before, " стало ", nodes.size())
	# Дыра в оболочке: у погребённой ячейки не должно быть ни одной грани
	# наружу — такую грань никто не нарисует.
	var buried_n := 0
	var leaky := 0
	for cell in solid:
		if not _buried(cell):
			continue
		buried_n += 1
		for f in grid.faces_of(cell):
			if not _is_terrain(int(f["nb"])):
				leaky += 1
				break
	print("Погребённых ячеек ", buried_n, ", из них с гранью наружу — ", leaky)

	_seed_moss(6)
	_flush_chunks()
	# Мох не должен пережить снос глыбы, на которой рос.
	var host := -1
	for key in plants.patches:
		host = key.x
		break
	var moss_before := 0
	for key in plants.patches:
		if key.x == host:
			moss_before += 1
	_remove(host)
	_flush_chunks()
	var moss_after := 0
	for key in plants.patches:
		if key.x == host:
			moss_after += 1
	print("Мох на снесённой глыбе: было ", moss_before, ", осталось ", moss_after)

	var t1 := Time.get_ticks_usec()
	for _i in range(300):
		plants._tick(0.15)
	var grow := (Time.get_ticks_usec() - t1) / 1000.0
	print("Растения: кусочков — ", plants.patches.size(),
		", 45 секунд роста за ", snappedf(grow, 0.1), " мс")

	await get_tree().physics_frame
	await get_tree().physics_frame
	var pick := _pick(get_viewport().get_visible_rect().size * 0.5)
	print("Самопроверка: прицел — ", "мимо" if pick.is_empty() else str(pick["hit"]))


# Засеваем поверхность мхом — для проверки и для наглядного кадра.
var _macro_focus: Vector3 = Vector3.ZERO
var _cliff_focus: Vector3 = Vector3.ZERO
var _structure_gap: Vector3 = Vector3.ZERO

# Для кадра: пара скал и башня из зданий рядом с центром.
# Строим так же, как строил бы игрок: широкой кистью, слоями вверх. На одной
# мелкой ячейке ни дом, ни скальный выход не читаются.
func _seed_structures() -> void:
	var was_brush := brush
	brush = 3
	var placed := 0
	for cell in range(grid.cells.size()):
		if placed >= 2:
			break
		if not solid.has(cell):
			continue
		var s: Vector3 = grid.seeds[cell]
		var dist: float = Vector2(s.x, s.z).length()
		if dist < 2.0 or dist > 6.0 or s.y < ISLAND_TOP - 2.2:
			continue
		if _structure_gap != Vector3.ZERO and s.distance_to(_structure_gap) < 5.0:
			continue
		var kind := "cliff" if placed == 0 else "building"
		var storeys := 4 if placed == 0 else 3
		var head: Vector3 = s
		for level in range(storeys):
			head += Vector3(0, CELL_SPACING, 0)
			var up_cell: int = grid.cell_at(head)
			if up_cell < 0 or not grid.is_valid(up_cell):
				break
			head = grid.seeds[up_cell]
			for c in _brush_cells(up_cell):
				_place(c, kind, false)
		if kind == "cliff":
			_cliff_focus = s + Vector3(0, CELL_SPACING, 0)
		placed += 1
		# Второй объект ставим подальше, чтобы группы не слились в одну.
		if placed == 1:
			_structure_gap = s
	brush = was_brush
	_flush_chunks()

# Расставляем по одному объекту каждого вида рядом с мхом — для кадра.
func _seed_props() -> void:
	var kinds := ["rock", "debris", "snag"]
	var placed := 0
	for key in face_geo:
		if placed >= kinds.size():
			break
		var mid: Vector3 = face_geo[key]["mid"]
		if Vector2(mid.x, mid.z).length() > 6.0 or mid.y < ISLAND_TOP - 1.5:
			continue
		var spot := Vector3i(key.x, key.y, 0)
		if props.place(spot, kinds[placed]):
			placed += 1

# Сеем на самых высоких площадках у центра — чтобы попало в кадр. Порог по
# высоте брать нельзя: он зависит от размера ячейки, и на мелкой сетке макушки
# до него уже не дотягиваются — проверка молча оказывалась пустой.
func _seed_moss(count: int) -> void:
	var tops: Array = []
	for key in face_geo:
		var mid: Vector3 = face_geo[key]["mid"]
		if Vector2(mid.x, mid.z).length() > 5.0:
			continue
		tops.append([mid.y, key])
	tops.sort_custom(func(a, b): return a[0] > b[0])

	var planted := 0
	for item in tops:
		if planted >= count:
			break
		var key: Vector2i = item[1]
		if plants.plant(Vector3i(key.x, key.y, 0), "moss"):
			if planted == 0:
				_macro_focus = face_geo[key]["mid"]
			planted += 1


# Лианы заводим у подножия построек — там, где у них есть опора.
func _seed_vines(count: int) -> void:
	var planted := 0
	for key in face_geo:
		if planted >= count:
			break
		var mid: Vector3 = face_geo[key]["mid"]
		var near := false
		for nb in grid.neighbors_of(key.x):
			if nb >= 0 and (material_of(nb) == "building" or material_of(nb) == "cliff"):
				near = true
				break
		if not near:
			continue
		if plants.plant(Vector3i(key.x, key.y, 0), "vine"):
			planted += 1


func _shot_mode() -> void:
	frame_node.visible = false
	_seed_moss(8)
	_seed_props()
	_seed_structures()
	_seed_vines(14)
	for _i in range(260):
		plants._tick(0.15)
	for _i in range(12):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://space.png")

	cur_zoom = 14.0
	target_zoom = 14.0
	cur_pitch = -22.0
	_apply_camera()
	# Показываем подсветку места посадки: выбираем мох и целимся в центр.
	_select_tool("moss")
	frame_node.visible = true
	Input.warp_mouse(get_viewport().get_visible_rect().size * 0.5)
	for _i in range(6):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://space_close.png")
	# Макро-кадр: подлетаем вплотную к первой посаженной кочке.
	if _macro_focus != Vector3.ZERO:
		cur_pivot = _macro_focus
		target_pivot = cur_pivot
		cur_zoom = 1.6
		target_zoom = 1.6
		cur_pitch = -32.0
		_apply_camera()
		for _i in range(4):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://space_macro.png")

	# Кадр на обрыв: по нему видно слоистость породы и край зелени на кромке.
	# Надписи убираем — тут смотрят на породу, а не на управление.
	if _cliff_focus != Vector3.ZERO:
		frame_node.visible = false
		for child in get_children():
			if child is CanvasLayer:
				child.visible = false
		cur_pivot = _cliff_focus
		target_pivot = cur_pivot
		cur_zoom = 7.5
		target_zoom = 7.5
		cur_pitch = -8.0
		cur_yaw = 25.0
		_apply_camera()
		for _i in range(4):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://space_cliff.png")

	print("Кадры сохранены в: ", ProjectSettings.globalize_path("user://"))
	get_tree().quit()
