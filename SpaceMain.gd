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
const SpacePlantsScript = preload("res://SpacePlants.gd")
const SpacePropsScript = preload("res://SpaceProps.gd")
const SurfaceScript = preload("res://Surface.gd")
const PlantsData = preload("res://Plants.gd")

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
# Кусок поверхности — блок кубиков решётки. Швов между кусками не бывает по
# построению: точка на ребре считается по одной пропорции с обеих сторон.
const CHUNK_NODES: int = 4

var chunk_list: Dictionary = {}   # какие куски вообще есть
var chunk_nodes: Dictionary = {}  # кусок -> меш этого куска
var _dirty_chunks: Dictionary = {}
var _touched_cells: Dictionary = {}   # что задели мазки до ближайшей пересборки
var face_geo: Dictionary = {}     # Vector2i(ячейка, грань) -> её вид после сглаживания
var edge_faces: Dictionary = {}   # ребро -> какие грани его делят
var _buried_cache: Dictionary = {}
var paint: Dictionary = {}        # ячейка -> каким материалом её мазали
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
var frame_mat: ShaderMaterial
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

	# Здания и скальные плиты пока НЕ показываем. Их подошвы считаются по
	# многогранникам ячеек, а земля теперь идёт по уровню заполнения — плиты
	# ложились поперёк склона серыми осколками и читались как дыры в земле.
	# Переезжают на новую поверхность вместе с растениями.

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
	_hold_tick(delta)
	if fill_label != null:
		fill_label.visible = fill_done < 1.0
		if fill_done < 1.0:
			fill_label.text = "остров достраивается — %d%%" % int(fill_done * 100.0)
	if not _dirty_chunks.is_empty():
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
		_touch_chunks(i, false)
	print("Объёмная сетка: семян — ", grid.seeds.size(), ", породы — ", solid.size(),
		", кусков — ", chunk_list.size())
	print("Время: семена и заполнение ", Time.get_ticks_msec() - started, " мс")


# Кусок, которому принадлежит кубик решётки.
func _chunk_of_cube(c: Vector3i) -> Vector3i:
	return Vector3i(floori(float(c.x) / CHUNK_NODES), floori(float(c.y) / CHUNK_NODES),
		floori(float(c.z) / CHUNK_NODES))


# Ячейка входит углом в восемь кубиков — их куски и надо пересобрать.
func _touch_chunks(cell: int, dirty: bool = true) -> void:
	var n: Vector3i = grid.node_of(cell)
	for dx in range(-1, 1):
		for dy in range(-1, 1):
			for dz in range(-1, 1):
				var ch := _chunk_of_cube(n + Vector3i(dx, dy, dz))
				chunk_list[ch] = true
				if dirty:
					_dirty_chunks[ch] = true


# Мир достраивается КУСКАМИ, от середины наружу, отпуская кадр между ними.
#
# Вырезать многогранник дорого, а при мелкой сетке их тысячи — весь остров
# сразу не собрать. Но замирать на это время игра не должна: камера ходит,
# панель отвечает, остров прорастает на глазах от центра к краям.
func _fill_world() -> void:
	var started := Time.get_ticks_msec()
	var order: Array = chunk_list.keys()
	order.sort_custom(func(a, b):
		return Vector3(a).length_squared() < Vector3(b).length_squared())

	var budget := Time.get_ticks_msec() + FILL_BUDGET
	for n in range(order.size()):
		_rebuild_chunk(order[n])
		if Time.get_ticks_msec() > budget:
			fill_done = float(n + 1) / float(order.size())
			await get_tree().process_frame
			budget = Time.get_ticks_msec() + FILL_BUDGET

	fill_done = 1.0
	print("Достройка: ", Time.get_ticks_msec() - started, " мс, кусков — ",
		chunk_nodes.size(), ", вырезано ячеек — ", grid.built_count())
	if "--audit" in OS.get_cmdline_user_args():
		_audit_surface()


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
	# Считаем по 26 соседям ПО РЕШЁТКЕ: это дёшево и не требует вырезания
	# многогранников, которых у поверхности больше нет.
	var node: Vector3i = grid.node_of(cell)
	var deep := true
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var j: int = grid.node_seed(node + Vector3i(dx, dy, dz))
				if j >= 0 and not solid.has(j):
					deep = false
					break
			if not deep:
				break
		if not deep:
			break
	_buried_cache[cell] = deep
	return deep


func _forget_buried(cell: int) -> void:
	var node: Vector3i = grid.node_of(cell)
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			for dz in range(-2, 3):
				var j: int = grid.node_seed(node + Vector3i(dx, dy, dz))
				if j >= 0:
					_buried_cache.erase(j)


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


func _flush_chunks() -> void:
	for ch in _dirty_chunks:
		_rebuild_chunk(ch)
	_dirty_chunks.clear()
	# Постройки и скальные выходы строятся по группе целиком: добавили одну
	# ячейку — меняется вся группа, поэтому пересобираем их разом.
	if buildings != null:
		buildings.rebuild_all()
	if rocks != null:
		rocks.rebuild_all()
	# Растениям отдаём СПИСОК задетых ячеек. Без него пришлось бы на каждый
	# мазок пересаживать весь сад: заросшая карта — это тысячи кочек, а мазок
	# трогает три десятка ячеек.
	if plants != null and not _touched_cells.is_empty():
		plants.surface_changed(_touched_cells.keys())
	_touched_cells.clear()
	if props != null:
		props.surface_changed()


# Кусок поверхности: блок кубиков решётки, по каждому — свои тетраэдры.
# Ни ореола, ни сглаживания больше не нужно: точка на ребре считается по одной
# и той же пропорции с обеих сторон границы куска, а нормаль берётся от наклона
# поля, поэтому и геометрия, и освещение сходятся сами.
#
# Коллизия — тот же меш. Это заодно чинит давнюю занозу: раньше по клику
# ловилась нескруглённая ячейка, лежавшая снаружи видимой поверхности.
func _rebuild_chunk(chunk: Vector3i) -> void:
	if chunk_nodes.has(chunk):
		chunk_nodes[chunk].queue_free()
		chunk_nodes.erase(chunk)
	var lo: Vector3i = chunk * CHUNK_NODES
	var hi: Vector3i = lo + Vector3i(CHUNK_NODES, CHUNK_NODES, CHUNK_NODES)
	var mesh: ArrayMesh = SurfaceScript.build(grid, lo, hi)
	if mesh == null:
		return

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = rock_mat
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	col.shape = mesh.create_trimesh_shape()
	body.add_child(col)
	mi.add_child(body)
	add_child(mi)
	chunk_nodes[chunk] = mi


# Постановка — это ЛЕПКА. Один мазок прибавляет земли понемногу, форма
# набирается несколькими; поверхность идёт по уровню половинного заполнения,
# поэтому прибавка выходит плавным наплывом, а не глыбой с углами.
const STROKE: float = 0.75        # сколько добавляет один мазок
# Насколько один проход кисти размывания подтягивает ячейку к соседям. Держим
# небольшим: размывание должно набираться повторами, как и лепка, — иначе один
# щелчок слизывает форму начисто и вернуть её можно только отменой.
const BLUR: float = 0.34

func _brush_radius() -> float:
	return CELL_SPACING * (0.8 + 0.55 * float(brush))


func _stroke(at: Vector3, radius: float, amount: float, material: String,
		stone_push: float = 0.0) -> void:
	var touched: Array = grid.stroke_at(at, radius, amount, stone_push)
	if amount > 0.0:
		for c in touched:
			paint[c] = material
	_after_field_change(touched)


# Поле в этих ячейках изменилось — разбираемся с последствиями. Порода у ячейки
# появляется и исчезает САМА, по уровню заполнения; куски метим на пересборку.
# Общее для лепки и размывания: и то и другое двигает одно и то же поле.
func _after_field_change(touched: Array) -> void:
	for c in touched:
		_touched_cells[c] = true
		var full: bool = grid.fill_of(c) > 0.5
		if full and not solid.has(c):
			solid[c] = paint.get(c, "ground")
			_forget_buried(c)
		elif not full and solid.has(c):
			solid.erase(c)
			_forget_buried(c)
		_touch_chunks(c)


func _place(cell: int, material: String = "ground", record: bool = true) -> void:
	if cell < 0 or not grid.in_play(cell):
		return
	_dab(grid.seeds[cell], STROKE, material, record)


func _remove(cell: int, record: bool = true) -> void:
	if cell < 0 or not grid.in_play(cell):
		return
	_dab(grid.seeds[cell], -STROKE, "", record)


# Один мазок в точке: и постановка, и снятие, и отмена ходят через него.
func _dab(at: Vector3, amount: float, material: String, record: bool = true) -> void:
	# Размывание — не мазок: оно ничего не кладёт, а тянет поверхность к среднему
	# по соседям. Отменить его вычислением нельзя (сколько снялось, зависит от
	# того, что было вокруг), поэтому в память кладётся сам список прибавок.
	if material == "smooth" and amount > 0.0:
		var delta: Dictionary = grid.blur_at(at, _brush_radius() * 1.15, BLUR)
		if delta.is_empty():
			return
		_after_field_change(delta.keys())
		if record:
			history.append({"blur": delta, "group": _group})
		return

	# Камень кладём ТЕСНЕЕ земли: глыба должна быть плотным телом, а не
	# расплывшейся насыпью того же охвата.
	var tight: float = 0.78 if material == "cliff" else 1.0
	var rad := _brush_radius() * tight
	_stroke(at, rad, amount, material, _stone_push(amount, material))
	if record:
		history.append({"at": at, "rad": rad, "amount": amount, "mat": material,
			"group": _group})


# Куда мазок ведёт каменистость: кладём камень — к камню, кладём землю — от
# камня, снимаем — тоже от камня, потому что камень уходит вместе с массой.
func _stone_push(amount: float, material: String) -> float:
	if amount < 0.0:
		return -1.0
	var card: Dictionary = PlantsData.ITEMS.get(material, PlantsData.ITEMS["ground"])
	return float(card.get("stone", 0.0)) * 2.0 - 1.0


# Мазок ложится ровно туда, куда наведён курсор.
func _paint(pick: Dictionary, material: String) -> void:
	if pick.has("pos"):
		_dab(pick["pos"], STROKE, material)


func _erase(pick: Dictionary) -> void:
	if pick.has("pos"):
		_dab(pick["pos"], -STROKE, "")


# Отменяем ВСЁ ОДНО ПРОВЕДЕНИЕ кистью, а не последний мазок. Пока кнопка
# держалась, мазки шли десятками, и снимать их поодиночке — мука.
func _undo() -> void:
	if history.is_empty():
		return
	var mark: int = int(history[history.size() - 1].get("group", 0))
	_undo_one()
	if mark == 0:
		return
	while not history.is_empty() \
			and int(history[history.size() - 1].get("group", 0)) == mark:
		_undo_one()


func _undo_one() -> void:
	var a = history.pop_back()
	# Мазок снимается вычитанием ровно того, что прибавил, в том же месте —
	# и по массе, и по каменистости. Поэтому отмена повторяет мазок с обратным
	# знаком по обеим величинам, а не «снимает землю»: снятие увело бы камень
	# прочь и там, где мазок его прибавил.
	if a.has("blur"):
		# Размывание снимается вычитанием ровно тех прибавок, которые оно
		# положило: заново их не вычислить — они зависели от прежнего рельефа.
		_after_field_change(grid.apply_delta(a["blur"], -1.0))
	elif a.has("at"):
		_stroke(a["at"], float(a["rad"]), -float(a["amount"]), "",
			-_stone_push(float(a["amount"]), String(a["mat"])))
	elif a.has("plant"):
		plants.remove_at(int(a["plant"]))
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
	if result.is_empty():
		# Опереться не на что — целимся в плоскость земли. Так можно начать
		# заново, если на карте не осталось ни одной глыбы.
		if absf(dir.y) < 0.001:
			return {}
		var t := -from.y / dir.y
		if t <= 0.0:
			return {}
		var ground: int = grid.cell_at(from + dir * t)
		if ground < 0 or not grid.in_play(ground):
			return {}
		return {"hit": -1, "target": ground}

	# Луч попал в саму видимую поверхность, а не в подложенное тело ячейки.
	# Отступив от точки попадания по нормали в обе стороны, находим ближайшие
	# семена: снаружи — куда ставить, внутри — что убирать.
	var pos: Vector3 = result.position
	var nrm: Vector3 = result.normal
	var step: float = CELL_SPACING * 0.55
	return {"hit": grid.cell_at(pos - nrm * step), "target": grid.cell_at(pos + nrm * step),
		"pos": pos, "normal": nrm}


# --- Подсветка грани ---------------------------------------------------------
# Курсор — мягкое светящееся пятно там, куда придётся мазок. Линии контура
# на крутых местах видны с ребра и читались криво; пятно понятно с любой
# стороны и не спорит с самой формой земли.
#
# Пятно посадки ярче и желтее пятна лепки, и вдвое меньше: по одному взгляду
# видно, что сейчас произойдёт — ляжет земля или сядет росток.
const DIG_TONE := Color(0.42, 0.72, 0.34)
const PLANT_TONE := Color(0.62, 0.98, 0.26)

func _setup_frame() -> void:
	frame_mat = ShaderMaterial.new()
	frame_mat.shader = load("res://Cursor.gdshader")
	frame_node = MeshInstance3D.new()
	frame_node.material_override = frame_mat
	frame_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	frame_node.visible = false
	add_child(frame_node)


# Показываем тонкий контур того, что появится по клику: глыбы или пятачка.
func _update_frame() -> void:
	if _hide_cursor:
		frame_node.visible = false
		return
	if PlantsData.is_plant(current_tool) or PlantsData.is_prop(current_tool):
		_update_frame_spot()
		return
	var pick := _pick(get_viewport().get_mouse_position())
	var target: int = -1 if pick.is_empty() else int(pick["target"])
	if target < 0 or not grid.in_play(target) or solid.has(target):
		frame_node.visible = false
		frame_id = ""
		return

	if not pick.has("pos"):
		frame_node.visible = false
		return
	frame_node.visible = true

	# Точка прицела ходит непрерывно, поэтому её передаём каждый кадр, а вот
	# накладку по форме земли пересобираем только при смене ячейки — иначе
	# считали бы её по шестьдесят раз в секунду впустую.
	var rad: float = CELL_SPACING * (0.75 + 0.55 * float(brush))
	frame_mat.set_shader_parameter("spot", pick["pos"])
	frame_mat.set_shader_parameter("reach", rad)
	frame_mat.set_shader_parameter("tone", DIG_TONE)
	frame_mat.set_shader_parameter("strength", 0.55)

	var id := "%d:%d" % [target, brush]
	if id == frame_id:
		return
	frame_id = id
	var node: Vector3i = grid.node_of(target)
	var span := 1 + brush
	var edge := Vector3i(span, span, span)
	frame_node.mesh = SurfaceScript.build(grid, node - edge, node + edge)
	if frame_node.mesh == null:
		frame_node.visible = false


# Куда указывает курсор на земле: сама точка и наклон под ней. Луч ловит
# видимую поверхность, а наклон берём у поля — у луча он скачет на кромках.
func _pick_spot(screen_pos: Vector2) -> Dictionary:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 2000.0)
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return {}
	var on: Dictionary = grid.surface_near(result.position)
	if on.is_empty():
		return {}
	return on


func _try_put(screen_pos: Vector2) -> void:
	var spot := _pick_spot(screen_pos)
	if spot.is_empty():
		return
	if PlantsData.is_prop(current_tool):
		return                       # объекты ждут своего переезда
	var pid: int = plants.plant_at(spot["pos"], current_tool)
	if pid >= 0:
		history.append({"plant": pid, "group": _group})


# Убрать то, что растёт под прицелом.
func _try_clear(screen_pos: Vector2) -> void:
	var spot := _pick_spot(screen_pos)
	if spot.is_empty():
		return
	var pid: int = plants.nearest_to(spot["pos"], CELL_SPACING * 0.6)
	if pid >= 0:
		plants.remove_at(pid)


# --- Панели ------------------------------------------------------------------
# Панель слева отдана ТОЛЬКО выбору: что кладём и какой ширины кисть. Время
# уехало в свою панель справа — оно к выбору породы отношения не имеет, а две
# строки наверху отодвигали список вниз и мешали читать его как одно целое.
#
# Список ужат: мельче шрифт, теснее строки, подписи без отступов пробелами.
# Подсказки к ярусам («самые высокие») ушли во всплывающие — они длиннее самих
# названий и вдвое расширяли панель.
const UI_FONT: int = 13
const UI_FONT_SMALL: int = 11

func _panel_box(round_right: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.06, 0.08, 0.07, 0.55)
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 6
	box.content_margin_bottom = 6
	if round_right:
		box.corner_radius_top_right = 10
		box.corner_radius_bottom_right = 10
	else:
		box.corner_radius_top_left = 10
		box.corner_radius_bottom_left = 10
	return box


# Кнопка списка: плоская, без рамки фокуса, с мелким шрифтом и тесными полями.
func _list_button(size: int = UI_FONT) -> Button:
	var b := Button.new()
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_constant_override("h_separation", 0)
	# Поля у кнопки по умолчанию щедрые — из них и набегает высота списка.
	# Подменяем их пустой рамкой с узкими полями, иначе шрифт мельче, а строки
	# всё те же.
	var tight := StyleBoxEmpty.new()
	tight.content_margin_left = 2
	tight.content_margin_right = 4
	tight.content_margin_top = 1
	tight.content_margin_bottom = 1
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(state, tight)
	return b


func _setup_toolbar() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_box(true))
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 12
	panel.offset_bottom = -12
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.grow_horizontal = Control.GROW_DIRECTION_END
	layer.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	panel.add_child(column)

	# Три пункта верхнего уровня. Ярусы растительности вложены внутрь одного
	# из них — иначе список занимал бы полэкрана.
	for group in PlantsData.GROUPS:
		var g: int = group["key"]
		var head := _list_button()
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
				var sub := _list_button(UI_FONT_SMALL)
				sub.pressed.connect(_toggle_branch.bind(t))
				sub.tooltip_text = String(PlantsData.tier_info(t)["hint"])
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
				var button := _list_button()
				button.pressed.connect(_select_tool.bind(id))
				items.add_child(button)
				tool_buttons[id] = button
			if ids.is_empty():
				var empty := Label.new()
				empty.text = "   пока пусто"
				empty.modulate = Color(1, 1, 1, 0.35)
				empty.add_theme_font_size_override("font_size", UI_FONT_SMALL)
				items.add_child(empty)

		group_headers[g] = head
		group_boxes[g] = body
		group_open[g] = true

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	column.add_child(gap)

	# Ширина кисти — внизу, одной строкой: она относится к выбранному, а не
	# наоборот, и наверху отталкивала список от глаза.
	var brush_row := HBoxContainer.new()
	brush_row.add_theme_constant_override("separation", 0)
	column.add_child(brush_row)
	var brush_title := Label.new()
	brush_title.text = "кисть "
	brush_title.modulate = Color(1, 1, 1, 0.5)
	brush_title.add_theme_font_size_override("font_size", UI_FONT_SMALL)
	brush_row.add_child(brush_title)
	for w in BRUSHES:
		var bb := _list_button(UI_FONT_SMALL)
		bb.pressed.connect(_set_brush.bind(int(w["width"])))
		brush_row.add_child(bb)
		brush_buttons.append(bb)

	_setup_time_panel(layer)
	_refresh_toolbar()


# Время — своя панель у правого края, на той же высоте, что и список слева.
func _setup_time_panel(layer: CanvasLayer) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_box(false))
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_right = -12
	panel.offset_bottom = -12
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	layer.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	panel.add_child(column)

	var title := Label.new()
	title.text = "Время"
	title.modulate = Color(1, 1, 1, 0.5)
	title.add_theme_font_size_override("font_size", UI_FONT_SMALL)
	column.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	column.add_child(row)
	for i in range(SPEEDS.size()):
		var sb := _list_button()
		sb.pressed.connect(_set_time_scale.bind(i))
		row.add_child(sb)
		speed_buttons.append(sb)


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
	# Отступы задаём НЕ пробелами, а самой строкой из знака и названия: пробелы
	# считаются по ширине шрифта и на мелком кегле разъезжаются.
	for group in PlantsData.GROUPS:
		var g: int = group["key"]
		var open: bool = group_open[g]
		# Номер оставляем: по нему раздел сворачивается с клавиатуры.
		group_headers[g].text = "%s %d %s" % ["▾" if open else "▸", g, group["name"]]
		group_boxes[g].visible = open
		for t in group["tiers"]:
			var info := PlantsData.tier_info(t)
			if branch_headers.has(t):
				branch_headers[t].text = "  %s %s" % [
					"▾" if branch_open[t] else "▸", info["name"]]
			branch_boxes[t].visible = branch_open[t] or not branch_headers.has(t)
	for id in tool_buttons:
		var mark := "●" if id == current_tool else "○"
		tool_buttons[id].text = "   %s %s" % [mark, PlantsData.ITEMS[id]["name"]]


# В режиме посадки подсвечиваем ТО ЖЕ ПЯТНО, что и при лепке, только мельче и
# зеленее. Прежде тут рисовалось кольцо из отрезков — на крутом месте его видно
# с ребра, и понять, куда сядет росток, было нельзя. Пятно лежит по форме земли
# и читается с любой стороны.
func _update_frame_spot() -> void:
	var spot := _pick_spot(get_viewport().get_mouse_position())
	if spot.is_empty():
		frame_node.visible = false
		frame_id = ""
		return
	var pos: Vector3 = spot["pos"]
	var cell: int = int(spot["cell"])
	frame_node.visible = true

	# Пятно размером с молодую кочку — столько места растение и займёт.
	frame_mat.set_shader_parameter("spot", pos)
	frame_mat.set_shader_parameter("reach", CELL_SPACING * 0.42)
	frame_mat.set_shader_parameter("tone", PLANT_TONE)
	frame_mat.set_shader_parameter("strength", 0.75)

	# Накладку по форме земли пересобираем только при смене ячейки: точка
	# прицела ходит непрерывно, а форма под ней — нет.
	var id := "p%d" % cell
	if id == frame_id:
		return
	frame_id = id
	var node: Vector3i = grid.node_of(cell)
	var edge := Vector3i(2, 2, 2)
	frame_node.mesh = SurfaceScript.build(grid, node - edge, node + edge)
	if frame_node.mesh == null:
		frame_node.visible = false


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
# Кисть ведут удержанием. Первый мазок ложится сразу по нажатию, дальше они идут
# через `HOLD_STEP` — пауза перед вторым чуть длиннее, чтобы одиночный щелчок не
# превращался в два мазка от дрожи руки.
const HOLD_FIRST: float = 0.22
const HOLD_STEP: float = 0.07

var held: bool = false
var held_erase: bool = false
var _hold_wait: float = 0.0
var _group: int = 0            # каким числом помечены мазки одного проведения
var _group_next: int = 1


# Один мазок в точке экрана — тем, что сейчас выбрано в панели.
func _apply_at(screen_pos: Vector2, erase: bool) -> void:
	if PlantsData.is_plant(current_tool) or PlantsData.is_prop(current_tool):
		if erase:
			_try_clear(screen_pos)
		else:
			_try_put(screen_pos)
		return
	var pick := _pick(screen_pos)
	if pick.is_empty():
		return
	if erase:
		_erase(pick)
	else:
		_paint(pick, current_tool)


# Одно проведение кистью — ОДНА отмена. Иначе, проведя по склону, пришлось бы
# щёлкать отмену столько же раз, сколько легло мазков.
func _open_group() -> void:
	_group = _group_next
	_group_next += 1


func _close_group() -> void:
	_group = 0


func _hold_tick(delta: float) -> void:
	if not held:
		return
	_hold_wait -= delta
	if _hold_wait > 0.0:
		return
	_hold_wait = HOLD_STEP
	_apply_at(get_viewport().get_mouse_position(), held_erase)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			panning = event.pressed
		elif event.button_index == MOUSE_BUTTON_LEFT:
			# Кисть ведут НАЖАТИЕМ И УДЕРЖАНИЕМ. Пока кнопка держится, мазок
			# повторяется сам — иначе насыпать холм значит долбить по кнопке
			# три десятка раз, и рука устаёт раньше, чем появляется форма.
			held = event.pressed
			held_erase = event.shift_pressed
			if event.pressed:
				_open_group()
				_apply_at(event.position, event.shift_pressed)
				_hold_wait = HOLD_FIRST
			else:
				_close_group()
		elif event.button_index == MOUSE_BUTTON_XBUTTON1 and event.pressed:
			_undo()                                    # 1-я боковая — отмена
		elif event.button_index == MOUSE_BUTTON_XBUTTON2 and event.pressed:
			var kill := _pick(event.position)          # 2-я боковая — удалить
			if not kill.is_empty():
				_erase(kill)
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
# Считаем незамкнутые рёбра по всему миру: сколько их и где.
func _audit_surface() -> void:
	var edges: Dictionary = {}
	var stats: Dictionary = {}
	for ch in chunk_list:
		var lo: Vector3i = ch * CHUNK_NODES
		SurfaceScript.audit(grid, lo,
			lo + Vector3i(CHUNK_NODES, CHUNK_NODES, CHUNK_NODES), edges, stats)
	# Рёбра НАПРАВЛЕННЫЕ. У согласованной замкнутой поверхности каждое
	# направленное ребро встречается ровно один раз, и у каждого есть обратное.
	# Встретилось дважды — рядом вывернутый треугольник. Нет обратного — дыра.
	var flipped := 0
	var holes := 0
	var shown := 0
	for k in edges:
		if int(edges[k]) > 1:
			flipped += 1
			if shown < 4:
				shown += 1
				print("   вывернуто у ребра ", k)
			continue
		var parts: Array = String(k).split(">")
		if not edges.has("%s>%s" % [parts[1], parts[0]]):
			holes += 1
	print("Рёбер поверхности ", edges.size(), ", вывернутых — ", flipped,
		", незамкнутых — ", holes,
		"; вывернутых тетраэдров на поверхности — ", int(stats.get("inverted", 0)))


# СТОРОЖ НАГРУЗКИ. Все замеры ниже врут, если машина занята чем-то ещё. За одну
# сессию это случалось трижды: открытый редактор Godot и запущенная из него игра
# забирали столько, что отклик показывал десять миллисекунд вместо трёх, — и
# несуществующий регресс чуть не пошли чинить.
#
# Мерим НЕ «кто запущен», а сколько машина отдаёт: считаем известный объём
# работы и сравниваем со временем, за которое он проходит на свободной. Так
# сторож ловит любую помеху — редактор, браузер, проверку диска, — а не только
# ту, о которой мы догадались спросить.
#
# ЧЕГО ОН НЕ ЛОВИТ. Счёт идёт в одном потоке, а ядер много: один сосед, занявший
# другое ядро, замедлит его слабо. Проверено — вторая копия игры дала 0.95×.
# Сторож поднимает голос, когда машина ЗАГРУЖЕНА по-настоящему, а это и был тот
# случай, ради которого он заведён: редактор с запущенной из него игрой давали
# втрое. Если надо узнать, КТО именно мешает, это смотрят снаружи:
#   Get-CimInstance Win32_Process -Filter "Name like '%Godot%'"
# Сколько эта работа занимает на свободной машине. Замерено 2026-08-13, когда
# ни редактор, ни игра не были запущены. Число привязано к машине: на другой
# его надо перемерить, иначе сторож будет врать в обе стороны.
const LOAD_REFERENCE_USEC: float = 8300.0
const LOAD_ALARM: float = 1.4

func _load_factor() -> float:
	var t0 := Time.get_ticks_usec()
	var acc := 0.0
	for i in range(200000):
		acc += sqrt(float(i) + 1.0)
	var took: float = float(Time.get_ticks_usec() - t0)
	# Ссылку на `acc` оставляем: без неё цикл может показаться ненужным.
	if acc < 0.0:
		return 0.0
	return took / LOAD_REFERENCE_USEC


func _selftest() -> void:
	var load: float = _load_factor()
	if load > LOAD_ALARM:
		print("НАГРУЗКА ", snappedf(load, 0.01), "× — ЗАМЕРАМ НИЖЕ НЕ ВЕРИТЬ.",
			" Машина занята чем-то ещё (редактор Godot? запущенная игра?)")
	else:
		print("Нагрузка машины: ", snappedf(load, 0.01), "× — замерам можно верить")

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
			_dab(grid.seeds[grid.cell_at(Vector3(0, 6, 0))], STROKE, "ground")
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

	_blur_report()
	_stone_report()

	# Снос настоящей ячейки породы: поверхность обязана перестроиться.
	var victim := -1
	for c in solid:
		if not _buried(c):
			victim = c
			break
	var before := chunk_nodes.size()
	_remove(victim)
	_flush_chunks()
	print("Снос породы: ячейка ", victim, ", убрана — ", not solid.has(victim),
		", заполнение ", grid.fill_of(victim), ", кусков было ", before,
		" стало ", chunk_nodes.size())
	_seed_moss(6)
	_flush_chunks()
	print("Посев мха: кочек — ", plants.patches.size())
	# Мох не должен пережить снос земли, на которой рос.
	var host := -1
	for pid in plants.patches:
		host = int(plants.patches[pid]["cell"])
		break
	var moss_before: int = plants.patches.size()
	# Сносим то место несколько раз подряд: одного мазка мало, чтобы земля ушла
	# из-под кочки дальше половины ячейки.
	for _i in range(4):
		_remove(host)
	_flush_chunks()
	print("Мох на снесённой земле: было ", moss_before,
		", осталось ", plants.patches.size())

	var t1 := Time.get_ticks_usec()
	for _i in range(300):
		plants._tick(0.15)
	var grow := (Time.get_ticks_usec() - t1) / 1000.0
	print("Растения: кочек — ", plants.patches.size(),
		", 45 секунд роста за ", snappedf(grow, 0.1), " мс")

	# СИДИТ ЛИ МОХ НА ЗЕМЛЕ. Промах считаем до того самого среза, по которому
	# режется картинка: сколько тут метров — столько глаз и видит просвета под
	# кочкой. Норма — нули; оторвавшихся быть не должно вовсе.
	var gap_max := 0.0
	var gap_sum := 0.0
	var lost := 0
	for pid in plants.patches:
		var gap: float = grid.surface_gap(plants.patches[pid]["pos"])
		if gap < 0.0:
			lost += 1
			continue
		gap_sum += gap
		gap_max = maxf(gap_max, gap)
	var sat: int = plants.patches.size() - lost
	print("Мох на земле: оторвалось — ", lost, ", промах в среднем ",
		snappedf(gap_sum / maxf(1.0, float(sat)), 0.001), " м, наибольший ",
		snappedf(gap_max, 0.001), " м")

	# ЧЕМ КОЧКА ОБХОДИТСЯ. Объём у неё теперь настоящий — тело куполом, — и это
	# та цена, которую надо держать на виду: мох должен выглядеть пушистым, но
	# заросший остров — это тысячи кочек.
	var tris := 0
	for cell in plants.cell_nodes:
		var mesh: ArrayMesh = plants.cell_nodes[cell].mesh
		for si in range(mesh.get_surface_count()):
			var indexed: int = mesh.surface_get_array_index_len(si)
			tris += (indexed if indexed > 0 else mesh.surface_get_array_len(si)) / 3
	print("Кочка: треугольников всего — ", tris, ", на кочку — ",
		snappedf(float(tris) / maxf(1.0, float(plants.patches.size())), 0.1),
		", кусков меша — ", plants.cell_nodes.size())
	var sheet: Vector2i = plants.see_through()
	print("Разметка тела: просвечивающих точек — ", sheet.x,
		", самая тесная клетка — ", sheet.y, " точек")
	var merged: Vector2 = plants.merge_stats()
	print("Слияние: соседей внахлёст на кочку — ", snappedf(merged.x, 0.1),
		", обода под чужим куполом — ", snappedf(merged.y * 100.0, 0.1), "%")

	await get_tree().physics_frame
	await get_tree().physics_frame
	var pick := _pick(get_viewport().get_visible_rect().size * 0.5)
	print("Самопроверка: прицел — ", "мимо" if pick.is_empty() else str(pick["hit"]))


# РАЗМЫВАНИЕ ГЛАЗАМИ ЧИСЕЛ. Кисть обязана делать ровно две вещи: уменьшать
# перепад между соседями и отменяться начисто. Первое меряем разбросом поля по
# округе до и после, второе — сравнением с тем, что было.
func _blur_report() -> void:
	var at: Vector3 = grid.seeds[grid.cell_at(Vector3(0, 6, 0))]
	var was_brush := brush
	brush = 3
	# Сначала лепим уступ: ровное место размывать бессмысленно, там и так гладко.
	for _i in range(3):
		_dab(at, STROKE, "ground")
	_flush_chunks()

	var near: Array = grid.seeds_near(at, CELL_SPACING * 2.5)
	var before: Dictionary = {}
	for c in near:
		before[c] = grid.fill_of(c)
	var rough_before: float = _roughness(near)

	var t0 := Time.get_ticks_usec()
	_dab(at, STROKE, "smooth")
	_flush_chunks()
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var rough_after: float = _roughness(near)

	_undo()
	_flush_chunks()
	var left := 0.0
	for c in near:
		left = maxf(left, absf(grid.fill_of(c) - float(before[c])))
	print("Размывание: перепад ", snappedf(rough_before, 0.001), " → ",
		snappedf(rough_after, 0.001), ", за ", snappedf(ms, 0.1),
		" мс, после отмены осталось ", snappedf(left, 0.0001))
	for _i in range(3):
		_undo()
	_flush_chunks()
	brush = was_brush


# Насколько поле ИЗЛОМАНО: разница ячейки со средним по её соседям. Не разница
# с соседями напрямую — та велика и у ровного склона, а склон размывать нечего.
# Излом же есть ровно там, где кисти и место работы.
func _roughness(cells: Array) -> float:
	var sum := 0.0
	var count := 0
	for c in cells:
		var node: Vector3i = grid.node_of(c)
		var near := 0.0
		var near_n := 0
		for step in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
				Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			var n: int = grid.node_seed(node + step)
			if n < 0:
				continue
			near += grid.fill_of(n)
			near_n += 1
		if near_n == 0:
			continue
		sum += absf(near / float(near_n) - grid.fill_of(c))
		count += 1
	return 0.0 if count == 0 else sum / float(count)


# КАМЕНЬ ГЛАЗАМИ ЧИСЕЛ. На картинке не видно, отчего глыба вышла плоской:
# мало ли положено массы, слаба ли огранка, съела ли её пологость. Меряем всё
# по отдельности — и заодно проверяем, что отмена уносит и камень тоже.
func _stone_report() -> void:
	var at: Vector3 = grid.seeds[grid.cell_at(Vector3(0, 6, 0))]
	var was_brush := brush
	brush = 3
	# Что было ДО мазков: место уже потоптано прежними проверками, и сравнивать
	# отмену с нулём нельзя — чужой след легко принять за свой непорядок.
	var near: Array = grid.seeds_near(at, CELL_SPACING * 3.0)
	var before_fill: Dictionary = {}
	var before_stone: Dictionary = {}
	for c in near:
		before_fill[c] = grid.fill_of(c)
		before_stone[c] = float(grid.stone.get(c, 0.0))

	for _i in range(3):
		_dab(at, STROKE, "cliff")
	_flush_chunks()

	var stone_max := 0.0
	var lift_max := 0.0
	var facet_lo := 0.0
	var facet_hi := 0.0
	var steep_max := 0.0
	var stony := 0
	for c in near:
		var raw: float = float(grid.stone.get(c, 0.0))
		stone_max = maxf(stone_max, raw)
		if grid.stone_of(c) > 0.02:
			stony += 1
			var f: float = grid.facet_of(c)
			facet_lo = minf(facet_lo, f)
			facet_hi = maxf(facet_hi, f)
			steep_max = maxf(steep_max, grid.steepness_of(c))
		lift_max = maxf(lift_max, absf(grid.fill_of(c) - float(before_fill[c])))
	print("Камень: ячеек с породой — ", stony, ", каменистость до ",
		snappedf(stone_max, 0.01), ", подъём поля до ", snappedf(lift_max, 0.01),
		", огранка ", snappedf(facet_lo, 0.01), "…", snappedf(facet_hi, 0.01),
		", крутизна до ", snappedf(steep_max, 0.01))

	for _i in range(3):
		_undo()
	_flush_chunks()
	var left_fill := 0.0
	var left_stone := 0.0
	for c in near:
		left_fill = maxf(left_fill, absf(grid.fill_of(c) - float(before_fill[c])))
		left_stone = maxf(left_stone,
			absf(float(grid.stone.get(c, 0.0)) - float(before_stone[c])))
	print("Отмена камня: осталось поля ", snappedf(left_fill, 0.001),
		", каменистости ", snappedf(left_stone, 0.001))
	brush = was_brush


# Засеваем поверхность мхом — для проверки и для наглядного кадра.
var _macro_focus: Vector3 = Vector3.ZERO
var _cliff_focus: Vector3 = Vector3.ZERO
var _structure_gap: Vector3 = Vector3.ZERO
var _hide_cursor: bool = false

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
		# Лепим холм так, как это делал бы игрок: несколько мазков подряд по
		# одному месту, каждый следующий чуть выше. Именно здесь раньше
		# вылезали летающие лоскуты, поэтому проверять надо этим.
		# Первая куча — земляной холм, вторая — каменная глыба: в кадре сразу
		# видно, чем камень отличается по форме от насыпи.
		var kind := "ground" if placed == 0 else "cliff"
		var head: Vector3 = s
		# Камень лепим ШИРЕ земляного холма: столбик в один мазок — это валун
		# метров шести, а на нём при шаге решётки в 1.8 м умещается одна грань.
		# Судить облик камня по такому невозможно; массив из нескольких колонн
		# — то, что игрок и построит, если захочет скалу.
		var feet: Array = [Vector3.ZERO] if kind == "ground" else [
			Vector3.ZERO, Vector3(CELL_SPACING * 1.3, 0, 0),
			Vector3(-CELL_SPACING * 0.9, 0, CELL_SPACING * 1.1),
			Vector3(CELL_SPACING * 0.4, 0, -CELL_SPACING * 1.4)]
		for foot in feet:
			head = s + foot
			for level in range(4):
				var up_cell: int = grid.cell_at(head + Vector3(0, CELL_SPACING * 0.6, 0))
				if up_cell < 0 or not grid.in_play(up_cell):
					break
				head = grid.seeds[up_cell]
				for _again in range(3):
					_stroke(head, _brush_radius(), STROKE, kind,
						_stone_push(STROKE, kind))
		if kind == "cliff":
			_cliff_focus = s + Vector3(0, CELL_SPACING * 1.2, 0)
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

# Сеем на самых высоких местах у середины острова — чтобы попало в кадр.
# Порог по высоте брать нельзя: он зависит от размера ячейки, и на мелкой сетке
# макушки до него уже не дотягиваются — проверка молча оказывалась пустой.
func _seed_moss(count: int) -> void:
	var tops: Array = []
	for cell in solid:
		var s: Vector3 = grid.seeds[cell]
		# Не на камне: там уже сидят лианы, и в макро-кадре мха за ними не видно.
		if Vector2(s.x, s.z).length() > 5.0 or _buried(cell) \
				or grid.stone_of(cell) > 0.15:
			continue
		tops.append([s.y, cell])
	tops.sort_custom(func(a, b): return a[0] > b[0])

	var planted := 0
	for item in tops:
		if planted >= count:
			break
		var pid: int = plants.plant_at(grid.seeds[int(item[1])], "moss")
		if pid >= 0:
			if planted == 0:
				_macro_focus = plants.patches[pid]["pos"]
			planted += 1


# Лианы заводим у камня — там, где у них есть опора.
func _seed_vines(count: int) -> void:
	var planted := 0
	for cell in solid:
		if planted >= count:
			break
		if _buried(cell) or grid.stone_of(cell) < 0.3:
			continue
		if plants.plant_at(grid.seeds[cell], "vine") >= 0:
			planted += 1


func _shot_mode() -> void:
	frame_node.visible = false
	_seed_moss(8)
	_seed_props()
	_seed_structures()
	_seed_vines(14)
	# Отпускаем кадр по ходу роста. Здесь сорок пять секунд жизни сада
	# проматываются подряд, без единого кадра, — а видеокарта освобождает
	# отпущенное как раз на границе кадра. В самой игре такого не бывает: там
	# между толчками роста кадры идут своим чередом.
	for _i in range(260):
		plants._tick(0.15)
		if _i % 15 == 14:
			await get_tree().process_frame
	for _i in range(12):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://space.png")

	cur_zoom = 14.0
	target_zoom = 14.0
	cur_pitch = -22.0
	_apply_camera()
	# Показываем подсветку места посадки: выбираем мох и целимся в центр.
	_select_tool("ground")
	frame_node.visible = true
	Input.warp_mouse(get_viewport().get_visible_rect().size * 0.5)
	for _i in range(6):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://space_close.png")
	# Макро-кадр: подлетаем вплотную к кочке мха — но выбираем ту, что ПОДАЛЬШЕ
	# ОТ КАМНЯ. У камня сидят лианы, они крупнее мха, и вблизи кадр упирался в
	# их плети: мха за ними было не разглядеть.
	var pick_best: float = 1e9
	for pid in plants.patches:
		var pp: Dictionary = plants.patches[pid]
		if String(pp["id"]) != "moss":
			continue
		var here: Vector3 = pp["pos"]
		# Ближе к середине острова и подальше от камня. У кромки камера
		# оказывалась НИЖЕ уровня земли и смотрела вдоль обрыва в море.
		var from_edge: float = Vector2(here.x, here.z).length()
		var from_rock: float = 99.0 if _cliff_focus == Vector3.ZERO \
			else here.distance_to(_cliff_focus)
		var score: float = from_edge - minf(from_rock, 8.0)
		if score < pick_best:
			pick_best = score
			_macro_focus = here
	if _macro_focus != Vector3.ZERO:
		# Подсветку прицела прячем: вблизи её накладка ложится поперёк кадра
		# зелёной плоскостью — она не пишет глубину и рисуется поверх всего.
		_hide_cursor = true
		frame_node.visible = false
		cur_pivot = _macro_focus
		target_pivot = cur_pivot
		# Не ближе четырёх метров: кочка меньше полуметра, и с полутора метров
		# камера оказывалась ВНУТРИ неё — дощечки шли поперёк кадра полосами.
		cur_zoom = 4.0
		target_zoom = 4.0
		cur_pitch = -42.0
		_apply_camera()
		for _i in range(4):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://space_macro.png")

	# Кадр на обрыв: по нему видно слоистость породы и край зелени на кромке.
	# Надписи убираем — тут смотрят на породу, а не на управление.
	if _cliff_focus != Vector3.ZERO:
		_hide_cursor = true          # курсор светит ровно на глыбу и мешает судить
		frame_node.visible = false
		for child in get_children():
			if child is CanvasLayer:
				child.visible = false
		cur_pivot = _cliff_focus
		target_pivot = cur_pivot
		# Вплотную: с семи с половиной саженей глыба занимала пятую часть кадра,
		# и судить по ней облик породы было нельзя — ни трещины, ни край зелени
		# на таком удалении не разобрать.
		cur_zoom = 3.4
		target_zoom = 3.4
		cur_pitch = -8.0
		cur_yaw = 25.0
		_apply_camera()
		for _i in range(4):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://space_cliff.png")

	print("Кадры сохранены в: ", ProjectSettings.globalize_path("user://"))
	get_tree().quit()
