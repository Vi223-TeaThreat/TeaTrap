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
# ЗАПАС ВЫСОТЫ — ВВЕРХ И ВНИЗ (решение пользователя 2026-08-28: «увеличь
# доступную комнату в высоту, количество изначальной земли оставь прежним»).
# Земли это не прибавляет: остров лепится по `ISLAND_TOP` и `ISLAND_BOTTOM`, а
# запас лишь расширяет объём, в котором игроку позволено класть и копать.
#
# Платим семенами: объём мира вырос вдвое, и с ним постройка и память.
const HEADROOM: float = 10.0         # запас высоты над островом
const UNDERROOM: float = 4.0         # ... и под ним, чтобы было куда копать
const CELL_SPACING: float = 0.6667   # втрое мельче прежнего — детальнее рельеф
# ПИКСЕЛЬ ЗЕМЛИ, в метрах: сторона клетки, которой красится поверхность.
#
# Крупнее мохового (9 мм), и не из упрямства. Во-первых, у мха и рисунок мелкий —
# куски по четыре точки, — а у земли самый мелкий слой шума в 11 см: клетка
# мельче него дробила бы то, что и так гладко, и пиксель бы не читался. Во-вторых,
# земли в кадре во много раз больше, и слишком мелкая клетка издали мельче
# экранной точки — это уже не рисунок, а рябь.
#
# Около двадцати клеток на грань решётки. Подробности — в `Terrain.gdshader`.
const TERRAIN_PIXEL: float = 0.03
const WORLD_SEED: int = 20260811
# Зерно ЭТОГО запуска. По умолчанию — прежнее, чтобы все кадры и замеры
# оставались сравнимыми; другой остров той же породы даёт ключ `--seed=N`.
# Стендов это касается тоже — кто передал ключ, тот сам выбрал другой мир.
var world_seed: int = WORLD_SEED

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

# Солнце и то, на какую даль у него сейчас растянуты тени (см. `_fit_shadow`).
var sun: DirectionalLight3D
var _shadow_far: float = -1.0

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
var erase_brush: int = 1          # ... и своя ширина у снятия
# И СВОЯ ШИРИНА У РОСТА (решение пользователя 2026-08-29: «добавь размеры для
# кисти роста»). Своя она по той же причине, по какой своя у снятия: лепят и
# растят по-разному, и переключать одну ширину на каждом шаге — мука. Начинает
# со средней: рост тычком в одну кочку — редкий случай, обычно ведут по куртине.
var grow_brush: int = 2
# И СВОЯ ШИРИНА У РАЗМЫВАНИЯ (решение пользователя 2026-09-01: «вынеси
# „размыть“ в отдельную кисть»). Причина та же, что у снятия и роста, и для
# размывания она даже острее: заглаживают им УЗКОЕ место — уступ, стык двух
# насыпей, слишком крутой край, — а лепят широким. Пока ширина была общая с
# лепкой, всякий переход к размыванию стоил двух лишних нажатий.
var blur_brush: int = 1
# РЕЖИМ СНЯТИЯ как состояние, а не как зажатая клавиша. На телефоне нет ни
# Shift, ни боковых кнопок — там снятие нечем позвать, кроме переключателя.
# На мыши он не мешает: Shift по-прежнему снимает поверх любого режима.
var erase_mode: bool = false
const FILL_BUDGET: int = 24       # мс на достройку мира за кадр
var fill_done: float = 0.0        # насколько мир достроен
var plants: Node3D
var props: Node3D
var buildings: Node3D
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
var erase_buttons: Array = []
var grow_buttons: Array = []
var blur_buttons: Array = []
var mode_buttons: Array = []
var time_scale: float = 1.0

const BRUSHES := [
	{"width": 1, "label": "1"},
	{"width": 2, "label": "2×2"},
	{"width": 3, "label": "3×3"},
]

const MODES := [
	{"erase": false, "label": "класть"},
	{"erase": true, "label": "снять"},
]

# РАЗДЕЛЫ, СКРЫТЫЕ ИЗ ПАНЕЛИ. Валуны, обломки и коряги пока рисуются
# заглушками и в демо только сбивают с толку: друг тычет в них, получает
# непонятное и решает, что игра сломана. Сам раздел и все его карточки в
# `Plants.gd` целы — чтобы вернуть, достаточно опустошить этот список.
const HIDDEN_GROUPS: Array = [3]     # 3 — «Объекты»

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

var _plain: bool = false          # `--plain`: голая форма, без покраски
var flat_moss: bool = false       # `--flatmoss`: тело кочки без рельефа
var rock_mat: ShaderMaterial
var grass_mat: ShaderMaterial


func _ready() -> void:
	# ГОЛАЯ ФОРМА — режим для ОДНОГО дела: понять, что кривит камень, сама
	# поверхность или то, чем её красят. На обычном кадре их не различить, и
	# по нему одинаково убедительно виноваты и складки поля, и порог дёрна,
	# который даёт прямую линию поперёк треугольника, и ступени тона.
	#
	# Снимает всё, что не форма: дёрн, ступени тона, затемнение щелей, цвет
	# породы, свет по граням. Остаётся серая поверхность под обычным светом —
	# на ней видно ровно то, что есть в геометрии, и ничего сверх.
	#
	# Читаем ДО постройки мира: свет по граням запекается в нормали при сборке
	# куска, после неё его уже не снять.
	_plain = "--plain" in OS.get_cmdline_user_args()
	if _plain:
		SurfaceScript.face_light = 0.0

	# ТЕЛО КОЧКИ БЕЗ РЕЛЬЕФА — то же самое, но для мха: холмики на образце
	# остаются нарисованными, светом их не лепит. Читаем здесь, а не в
	# растениях, потому что от этого зависит и имя кадра: два прогона не должны
	# затирать друг друга, их и сравнивают.
	flat_moss = "--flatmoss" in OS.get_cmdline_user_args()

	# ПРОБА, А НЕ ПЕРЕЕЗД. Читаем ДО подгонки панели: та считает своё место от
	# размера кадра, а кадр мы сейчас и меняем.
	_try_pixel_frame()

	# Первая прикидка — от плотности экрана. Подсказка строится по ней и такой
	# и останется; панель потом ещё ужмётся, если перебрала долю экрана.
	ui_scale = _screen_ui_scale()
	# ОКНО МЕНЯЕТ РАЗМЕР — МЕНЮ ПЕРЕСЧИТЫВАЕТСЯ ЗАНОВО. Правило «не больше
	# седьмой части» меряет по окну, и мерка живёт ровно до первого растягивания
	# или сжатия окна: без пересчёта панель оставалась той, что была скроена
	# под прежний размер. Масштаб при этом каждый раз берётся исходный — иначе
	# ужатое единожды меню оставалось бы мелким навсегда.
	get_viewport().size_changed.connect(func():
		if _resize_wait:
			return
		_resize_wait = true
		get_tree().create_timer(0.4).timeout.connect(func():
			_resize_wait = false
			ui_scale = _screen_ui_scale()
			_clear_toolbar()
			_setup_toolbar()
			_fit_menu()))
	_setup_materials()
	_setup_environment()
	_setup_light()
	_setup_camera()
	_setup_frame()
	_setup_hint()
	# Зерно этого мака живёт в user://world.cfg — его пишет кнопка «новый
	# остров». Ключ --seed=N сильнее файла, но файл не переписывает: ключ —
	# разовая проба, а не переезд.
	#
	# СТЕНДЫ ФАЙЛ НЕ ЧИТАЮТ, и это не мелочь: свои же грабли. Нажатая однажды
	# кнопка «новый остров» оставляет зерно на диске, и самопроверка молча
	# уходит на другой мир — сад в ней падает вдвое, а причину ищешь в правках.
	# Все записанные числа сняты на эталонном зерне, стенды обязаны идти по нему.
	var bench: bool = false
	for key in ["--selftest", "--shot", "--vinebench", "--growbench",
			"--meetbench", "--rockbench", "--scenebench"]:
		if key in OS.get_cmdline_user_args():
			bench = true
	if not bench and FileAccess.file_exists(SEED_PATH):
		var sf := FileAccess.open(SEED_PATH, FileAccess.READ)
		if sf != null:
			var kept: int = int(sf.get_line().strip_edges().to_int())
			sf.close()
			if kept != 0:
				world_seed = kept
	world_seed = int(_arg_num(OS.get_cmdline_user_args(), "--seed", float(world_seed)))
	_build_world()
	_setup_toolbar()
	# БЕЗ await: подгонка ждёт кадров вёрстки, а остальному запуску ждать её
	# незачем — мир и растения поднимаются своим чередом.
	_fit_menu()

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
	elif "--vinebench" in args:
		await _fill_world()
		_vine_bench()
	elif "--growbench" in args:
		# Одна лоза двумя путями: временем и кистью. См. `_grow_bench`.
		await _fill_world()
		_grow_bench()
		get_tree().quit()
	elif "--meetbench" in args:
		# Один стенд встречи, без остальной самопроверки: она идёт пять минут, а
		# крутить числа встречи приходится по многу раз подряд.
		await _fill_world()
		_meet_stand()
		get_tree().quit()
	elif "--scenebench" in args:
		# Новый остров: сколько он стоит и насколько разный. Сад не грузим и не
		# пишем — стенд не должен трогать её сохранение.
		await _fill_world()
		await _scene_bench(args)
		get_tree().quit()
	elif "--rockbench" in args:
		# Только камень, без растений: подбор облика идёт десятками прогонов.
		await _fill_world()
		_rock_bench(args)
		# `--stay` оставляет мир стоять. Нужно оно ровно за одним: вхолостую
		# (`--headless`) шейдеры не собираются вовсе, и поломка в покраске
		# молчит до самого запуска игры. С `--stay` и `--quit-after` мир
		# рисуется по-настоящему, и сборка шейдеров идёт в отчёт.
		if not "--stay" in args:
			get_tree().quit()
	else:
		# СЦЕНУ СТАВИМ ПОСЛЕ ТОГО, КАК МИР ДОСТРОЕН. Она лепит скалы мазками, а
		# мазок спрашивает у сетки поверхность: по недостроенному миру он положил
		# бы камень в пустоту.
		scene_id = _arg_word(args, "--scene", scene_id)
		await _fill_world()
		# СОХРАНЁННЫЙ САД — ВМЕСТО СЦЕНЫ: его поле уже содержит её мазки.
		# Загружается и пишется он ТОЛЬКО в игровой ветке — стенды и съёмка
		# идут по нетронутому миру, иначе ни одно записанное число не сравнить.
		if _load_garden():
			print("Сад загружен: ", plants.patches.size(), " растений")
		else:
			_seed_scene()
		_game_on = true
		# СВЕЖИЙ ОСТРОВ ТОЖЕ НЕ ЗАПИСЫВАЕТСЯ САМ. Значит, пока она не нажала
		# «сохранить», следующий запуск построит остров заново — по тому же
		# зерну и с той же обстановкой, но без её сада. Это и есть её правило.


# =============================================================================
#  СОХРАНЕНИЕ САДА
# =============================================================================
#
# Сад переживает закрытие игры. Снимок — то, чего не пересчитать из зерна:
# правки поля, каменистость, глыбы, краска и растения со всеми их записями.
# Всё производное пересчитывает `grid.restore_state` тем же порядком, каким
# идёт живой мазок.
#
# Пишется сам, раз в полминуты, и при закрытии окна (в браузере сигнала о
# закрытии нет — там спасает таймер). Файл живёт в user://, у веба это
# хранилище браузера. Сейв с чужим зерном молча не подкладываем: мир другой,
# и сад повис бы в воздухе.
var save_path := "user://garden.save"   # самопроверка подменяет на свой файл
const SEED_PATH := "user://world.cfg"


# НОВЫЙ ОСТРОВ: случайное зерно записывается в user://world.cfg, сад стирается,
# сцена перечитывается. Зерно остаётся и на следующие запуски — остров не
# прыгает от каждого открытия игры. Вернуть исходный остров: удалить файл или
# запуститься с --seed=20260811.
func _new_island() -> void:
	_game_on = false
	var sf := FileAccess.open(SEED_PATH, FileAccess.WRITE)
	if sf != null:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		sf.store_line(str(rng.randi_range(1, 2147483646)))
		sf.close()
	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(save_path)
	get_tree().reload_current_scene()
var _game_on: bool = false

func _save_garden() -> void:
	if not _game_on:
		return
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_var({
		"v": 1,
		"seed": world_seed,
		"edits": grid.edits,
		"stone": grid.stone,
		"lumps": grid.lumps,
		"paint": paint,
		"garden": plants.export_garden(),
	})
	f.close()


func _load_garden() -> bool:
	if not FileAccess.file_exists(save_path):
		return false
	var f := FileAccess.open(save_path, FileAccess.READ)
	if f == null:
		return false
	var data = f.get_var()
	f.close()
	if not (data is Dictionary) or int(data.get("v", 0)) != 1 \
			or int(data.get("seed", 0)) != world_seed:
		return false
	grid.restore_state(data["edits"], data["stone"], data["lumps"])
	paint = data["paint"]
	# Порода пересобирается по восстановленному полю: у ячейки выше половины
	# заполнения — краска из снимка, у прочих ничего.
	solid = {}
	grid.solid = {}
	for j in range(grid.fill.size()):
		if grid.fill[j] > 0.5:
			solid[j] = paint.get(j, "ground")
			grid.solid[j] = true
	for j in solid:
		_touch_chunks(j)
	_flush_chunks()
	plants.import_garden(data["garden"])
	return true


# Сад начинается заново: снимок стирается, игра перечитывает сцену. Кнопка
# спрашивает подтверждение сама (см. панель времени) — сюда приходят уже
# решившиеся.
func _reset_garden() -> void:
	_game_on = false
	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(save_path)
	get_tree().reload_current_scene()


# ПРИ ЗАКРЫТИИ ОКНА САД ТОЖЕ НЕ ПИШЕТСЯ. Здесь стояло сохранение; убрано
# 2026-09-01 по её решению — «если кнопка не нажата, не сохраняй». Правило одно
# на все случаи: половинчатое («по кнопке, но ещё и при выходе») было бы хуже
# любого из двух — на него нельзя положиться ни в ту, ни в другую сторону.
func _notification(_what: int) -> void:
	pass


# =============================================================================
#  ПРОБА: ВЕСЬ КАДР РИСУЕТСЯ МЕЛКИМ  (`--pixel`, `--pixel3`, `--pixel4`)
# =============================================================================
#
# Другой способ сделать картинку пиксельной, и в корне другой. Клетка в шейдере
# дробит только КРАСКУ, а кромка глыбы — не краска, её рисует форма, и она
# остаётся гладкой дугой: внутри клетки, снаружи плавный обвод. Здесь же мелким
# считается ВЕСЬ кадр и потом растягивается на окно — и отдельной кромки просто
# нечем нарисовать, у движка на неё те же точки, что и на всё прочее. Пикселем
# становится и краска, и силуэт разом.
#
# ЭТО ПОКА ТОЛЬКО ПРОБА, и держится она нарочно на отшибе: один ключ, одна
# функция, вокруг не тронуто ничего. Без ключа игра идёт ровно как прежде —
# откатывать нечего, а надоест насовсем — убрать эти двадцать строк.
#
# КАДР МЕРИМ ДОЛЕЙ ОКНА, а не числом точек. Растягивание идёт ЦЕЛЫМ множителем
# (иначе одни точки выходят шире других, и рябь возвращается с другой стороны), а
# при жёстком размере кадра в маленьком окне целый множитель оказался бы единицей
# — то есть проба не показала бы ничего.
#
# ЧЕГО ЖДАТЬ. Панель и подсказки рисуются внутри того же кадра, поэтому буквы
# пойдут ступеньками, а сама панель займёт большую долю картинки: разрешения-то
# стало вдвое меньше, а панель считает своё место в точках. Это плата ИМЕННО за
# простоту пробы; вариант с чётким интерфейсом делается отдельно и стоит дороже.
var pixel_zoom: int = 0                # 0 — проба выключена

func _try_pixel_frame() -> void:
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--pixel"):
			continue
		var tail: String = arg.substr(7)
		pixel_zoom = clampi(int(tail) if tail.is_valid_int() else 2, 2, 6)
		break
	if pixel_zoom <= 0:
		return
	var win := get_window()
	var small := Vector2i(maxi(win.size.x / pixel_zoom, 160),
		maxi(win.size.y / pixel_zoom, 90))
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_INTEGER
	win.content_scale_size = small
	# Сглаживание краёв тут ВРЕДНО: оно замывает ровно те ступеньки, ради которых
	# всё и затевалось.
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	print("Проба пикселя: кадр ", small.x, "×", small.y, " (окно ", win.size.x,
		"×", win.size.y, "), сглаживание снято, клетка в шейдере снята")


func _setup_materials() -> void:
	# Облик поверхности считает шейдер: дёрн ложится по наклону, порода
	# пятнистая, щели темнеют. Красить гранями нельзя — сквозь такую заливку
	# проступают сами ячейки.
	rock_mat = ShaderMaterial.new()
	rock_mat.shader = load("res://Terrain.gdshader")
	grass_mat = rock_mat
	if _plain:
		# Один серый цвет на всё, и ни одного порога сверху. Дёрн не растёт
		# нигде (наклон выше единицы недостижим), щели не темнеют, ступеней
		# тона нет. См. `--plain` в `_ready`.
		var grey := Color(0.55, 0.55, 0.55)
		for name in ["rock_dark", "rock_light", "soil_dark", "soil_light",
				"turf_deep", "turf_lit", "turf_dry"]:
			rock_mat.set_shader_parameter(name, grey)
		rock_mat.set_shader_parameter("mantle_soil", 9.0)
		rock_mat.set_shader_parameter("mantle_stone", 9.0)
		rock_mat.set_shader_parameter("moss_crack", 0.0)
		rock_mat.set_shader_parameter("moss_damp", 0.0)
		rock_mat.set_shader_parameter("bald", 0.0)
		rock_mat.set_shader_parameter("cavity_dark", 0.0)
		rock_mat.set_shader_parameter("posterize", 0.0)
		# И пиксель тоже: голая форма — режим для одного дела, и дробление
		# поверхности на клетки в нём такая же покраска, как всё остальное.
		rock_mat.set_shader_parameter("pixel", 0.0)
	else:
		# При мелком кадре клетку в шейдере СНИМАЕМ. Два дробления поверх друг
		# друга — это уже не проба способа, а смесь двух: непонятно, чем вышло то,
		# что видно. Пусть кадр покажет, что даёт он один.
		rock_mat.set_shader_parameter("pixel",
			0.0 if pixel_zoom > 0 else TERRAIN_PIXEL)


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
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -38, 0)
	sun.light_color = Color(1.0, 0.97, 0.91)
	sun.light_energy = 1.20
	sun.shadow_enabled = true

	# ОДНА СТУПЕНЬ ТЕНИ, А НЕ ЧЕТЫРЕ. Движок по умолчанию делит карту теней на
	# четыре ступени: ближняя мелкая и подробная, дальние крупные и грубые. Это
	# правильно для мира, который уходит за горизонт, и ЗРЯ у нас.
	#
	# Камера здесь всегда кружит ВОКРУГ острова и смотрит на него издали: на
	# обычном отдалении (42 м) остров лежит в 29–55 метрах, а первые ступени
	# накрывают пустой воздух перед камерой. То есть три четверти карты теней
	# уходили в никуда, и остров доставалась самая грубая ступень.
	#
	# Одна ступень — вся карта на него, вчетверо больше точности по площади, и
	# рисовать её вчетверо дешевле: один проход теней вместо четырёх.
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL

	# СМЕЩЕНИЯ ПОД ТОНКОЕ. Оба сдвигают тень прочь от предмета, чтобы он не
	# затенял сам себя рябью; движок меряет их в клетках карты теней, а не в
	# метрах, — и настроены они по умолчанию под стены и ящики.
	#
	# У нас же лист 13 см толщиной в лист бумаги и стебель в 3 мм: при клетке
	# в пару сантиметров смещение по умолчанию (2 клетки) отрывает тень от того,
	# что её отбрасывает, а у стебля съедает её целиком. Убавлено вдвое — этого
	# хватает, потому что карта стала втрое подробнее (см. `_fit_shadow`).
	sun.shadow_normal_bias = 1.0
	sun.shadow_bias = 0.05

	# КРАЙ ТЕНИ РАЗМЫТ, И ЭТО НЕ УКРАШЕНИЕ. Свет здесь северный пасмурный —
	# у такого солнца край тени мягкий, а не бритвенный. Число — угловой размер
	# светила: у настоящего солнца полградуса, у затянутого облаками неба
	# больше. Взят градус: тень мягчает с удалением от предмета, как в жизни,
	# и не рассыпается в шум.
	#
	# ЭТОГО НЕ БУДЕТ В БРАУЗЕРНОЙ ДЕМКЕ: там рисует упрощённый движок, мягких
	# теней он не умеет вовсе — как не умеет и затенения щелей (`ssao`).
	sun.light_angular_distance = 1.0

	# ГАШЕНИЕ ТЕНИ У ДАЛЬНЕГО КРАЯ — СНЯТО, и без этого вся подгонка вышла бы
	# боком. Движок по умолчанию плавно гасит тени на последней пятой части
	# дали, чтобы они не обрывались чертой посреди открытого мира. Но даль у нас
	# теперь подогнана вплотную к острову: на обычном отдалении она 60 м, пятая
	# часть — это всё, что дальше 48 м, а дальний край острова лежит в 55. То
	# есть задняя половина сада осталась бы без теней вовсе.
	#
	# Гасить больше нечего: за подогнанной далью пусто, обрываться нечему.
	sun.directional_shadow_fade_start = 1.0
	add_child(sun)
	_fit_shadow()


# НА КАКУЮ ДАЛЬ РАСТЯНУТЫ ТЕНИ. Одно число, и от него зависит вся их резкость:
# карта теней постоянного размера растягивается на эту даль, и чем даль больше,
# тем крупнее клетка тени.
#
# ПО УМОЛЧАНИЮ ОНА СТО МЕТРОВ, А ОСТРОВ — ДВАДЦАТЬ ШЕСТЬ ПОПЕРЁК. Четыре пятых
# дали приходились на пустоту вокруг него, и тень ложилась клетками впятеро
# крупнее нужного. А стоило отъехать камерой дальше сотни метров (колесо пускает
# до ста сорока), и тени пропадали ВОВСЕ — остров оказывался за той далью.
#
# Поэтому даль считается от камеры каждый раз, как камера двинулась: до дальнего
# края острова и ни метром больше.
#
# СТУПЕНЯМИ ПО ЧЕТЫРЕ МЕТРА, а не плавно. Тень перестраивается под новую даль
# целиком, и плавно ползущая граница дала бы кипение по всей картинке при каждом
# повороте колеса. Ступень — это редкий и незаметный скачок вместо постоянной
# ряби.
func _fit_shadow() -> void:
	if sun == null or camera == null:
		return
	# Остров стоит в начале координат, камера — где угодно вокруг. Запас в
	# четыре метра на то, что торчит выше земли: скалы, лоза, свисающие плети.
	var far: float = camera.global_position.length() + ISLAND_RADIUS + 4.0
	far = clampf(ceilf(far / 4.0) * 4.0, 28.0, 240.0)
	if is_equal_approx(far, _shadow_far):
		return
	_shadow_far = far
	sun.directional_shadow_max_distance = far


func _setup_camera() -> void:
	cam_pivot = Node3D.new()
	add_child(cam_pivot)
	camera = Camera3D.new()
	camera.near = 0.02        # чтобы вплотную ничего не срезалось
	cam_pivot.add_child(camera)
	camera.current = true
	_apply_camera()


func _process(delta: float) -> void:
	# Жест разбираем РАЗ В КАДР и до сглаживания камеры: к этому мигу оба
	# пальца уже на своих местах, и замер выходит честным.
	if _gesture_dirty:
		_gesture_dirty = false
		# Пальцы могли оторваться в том же кадре, в котором ещё двигались —
		# без этой проверки пересчёт полез бы в несуществующую пару.
		if _gesture_on and _touches.size() >= 2:
			_gesture_update()
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
		_flush_chunks_some()
	# САМ ПО СЕБЕ САД БОЛЬШЕ НЕ ПИШЕТСЯ. Здесь стоял таймер на полминуты; убран
	# 2026-09-01 по её решению — «если кнопка не нажата, не сохраняй».


func _apply_camera() -> void:
	cam_pivot.position = cur_pivot
	cam_pivot.rotation_degrees = Vector3(cur_pitch, cur_yaw, 0)
	camera.position = Vector3(0, 0, cur_zoom)
	camera.rotation_degrees = Vector3.ZERO
	# Тени подгоняются под новое место камеры — здесь, а не в `_process`: камеру
	# двигает и колесо, и рука, и стенды, а сходятся все пути сюда.
	_fit_shadow()


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
	grid.generate(ISLAND_RADIUS, ISLAND_TOP, ISLAND_BOTTOM, HEADROOM, UNDERROOM,
		CELL_SPACING, world_seed)
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


# ПЕРЕСБОРКА ЗЕМЛИ — С ЗАПАСОМ НА КАДР, как уже сделано у сада. Мазок широкой
# кистью метит с десяток кусков, и собранные разом они стоили кадру 48–111 мс —
# рывок на каждом движении руки. Теперь кадр собирает, сколько успевает, а
# остальное догоняет в следующих.
#
# КУСОК ПОД РУКОЙ СОБИРАЕТСЯ ПЕРВЫМ. У земли есть тонкость, которой не было у
# растений: курсор целится по коллизии меша, и пока кусок под кистью не
# пересобран, кисть рисует по вчерашнему рельефу. Мазок оставляет своё место в
# `_flush_focus`, и очередь начинается с ближайших к нему кусков.
const CHUNK_MS: float = 6.0
var _flush_focus: Vector3 = Vector3.INF

func _flush_chunks_some() -> void:
	var order: Array = _dirty_chunks.keys()
	if _flush_focus.is_finite():
		var at: Vector3 = _flush_focus / (CELL_SPACING * float(CHUNK_NODES))
		order.sort_custom(func(a, b):
			return Vector3(a).distance_squared_to(at) < Vector3(b).distance_squared_to(at))
	var deadline: int = Time.get_ticks_usec() + int(CHUNK_MS * 1000.0)
	for ch in order:
		_rebuild_chunk(ch)
		_dirty_chunks.erase(ch)
		if Time.get_ticks_usec() >= deadline:
			break
	# Растения пересаживаются сразу, не дожидаясь мешей: они ходят по полю, а
	# поле уже изменено в момент мазка. Постройки же строятся группой целиком —
	# их дёргаем один раз, когда очередь опустела.
	if plants != null and not _touched_cells.is_empty():
		plants.surface_changed(_touched_cells.keys())
	_touched_cells.clear()
	if _dirty_chunks.is_empty():
		if buildings != null:
			buildings.rebuild_all()
		if props != null:
			props.surface_changed()


func _flush_chunks() -> void:
	for ch in _dirty_chunks:
		_rebuild_chunk(ch)
	_dirty_chunks.clear()
	# Постройки и скальные выходы строятся по группе целиком: добавили одну
	# ячейку — меняется вся группа, поэтому пересобираем их разом.
	if buildings != null:
		buildings.rebuild_all()
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
#
# УЗЕЛ ПЕРЕИСПОЛЬЗУЕТСЯ, А НЕ СОЗДАЁТСЯ ЗАНОВО. Кадр пользователя 2026-09-01:
# «во время мазка просвечивает текстура, вылезают странные объекты, длится
# крайне малое время».
#
# Причина была ровно здесь. `queue_free()` не убирает узел со сцены, а лишь
# ставит его в очередь на конец кадра — и всё это время старый меш ПРОДОЛЖАЕТ
# рисоваться. Новый добавлялся тут же, рядом. То есть один кадр в сцене висели
# две почти совпадающие шкуры куска: где старая оказывалась снаружи новой, она
# и вылезала, а где они совпадали в точности — дрались за глубину и мерцали.
#
# Один кадр на кусок; при удержании кисти куски пересобираются непрерывно, и
# мерцание идёт всё время мазка. Лечится тем же приёмом, каким это давно
# сделано у кочек: узел и тело остаются свои, меняется только меш.
func _rebuild_chunk(chunk: Vector3i) -> void:
	var lo: Vector3i = chunk * CHUNK_NODES
	var hi: Vector3i = lo + Vector3i(CHUNK_NODES, CHUNK_NODES, CHUNK_NODES)
	var mesh: ArrayMesh = SurfaceScript.build(grid, lo, hi)
	if mesh == null:
		# Кусок опустел — убираем его СРАЗУ, а не в очередь: иначе он проживёт
		# лишний кадр там, где земли уже нет.
		if chunk_nodes.has(chunk):
			var gone: Node = chunk_nodes[chunk]
			remove_child(gone)
			gone.queue_free()
			chunk_nodes.erase(chunk)
		return

	if chunk_nodes.has(chunk):
		var mi_old: MeshInstance3D = chunk_nodes[chunk]
		mi_old.mesh = mesh
		var col_old: CollisionShape3D = mi_old.get_child(0).get_child(0)
		col_old.shape = mesh.create_trimesh_shape()
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
const STROKE: float = 0.75        # сколько добавляет один мазок узкой кистью


# СИЛА МАЗКА ОБРАТНА ШИРИНЕ КИСТИ. Широкая кисть за один мазок и так трогает
# в восемь раз больше земли; прибавляй она при этом столько же по высоте,
# середина упиралась бы в предел правок за те же полсекунды, что и узкая, — а
# у предела насыпь набирает угловатость. Замерено на широкой кисти при 140
# мазках в одно место: полная сила — излом 10.2°, шесть десятых — 8.5°,
# четыре десятых — 7.3°.
#
# Считаем от узкой кисти: ей достаётся полная сила, широким — тем меньше, чем
# они шире. Узкая осталась ровно такой, какой была.
# Сила одного мазка. `stroke_gain` — только для стенда: укорачивая мазок, силу
# приходится убавлять в ту же меру, иначе край его становится круче. В игре
# всегда единица.
var stroke_gain: float = 1.0

func _stroke_amount(erase: bool = false) -> float:
	return STROKE * stroke_gain * (CELL_SPACING * 2.4) / _brush_radius(erase)
# Насколько один проход кисти размывания подтягивает ячейку к соседям. Держим
# небольшим: размывание должно набираться повторами, как и лепка, — иначе один
# щелчок слизывает форму начисто и вернуть её можно только отменой.
const BLUR: float = 0.34

# ШИРИНА КИСТИ СЧИТАЕТСЯ В ЯЧЕЙКАХ, и это главное число во всей лепке.
#
# Было 1.35 / 1.9 / 2.45 ячейки. Любая форма такой кистью выходит шириной в
# пять граней — многогранник по построению, и никакое сглаживание этого не
# исправит: сглаживать нечего, поле-то гладкое. Замерено на одном и том же
# холме: 2.45 ячейки — излом 19.9°, 3.9 — 9.9°, 4.9 — 7.3°, 6.1 — 5.6°
# (нетронутая земля 3.9°).
#
# Набор РАСТЯНУТ, а не сдвинут: узкая кисть осталась быстрой, для мелочей, а
# широкая стала настоящей широкой. Цена мазка растёт почти как куб радиуса,
# поэтому платить за неё должен тот, кто сам выбрал широкую.
#
# 2.4 / 3.65 / 4.9 ячейки.
# У СНЯТИЯ СВОЯ ШИРИНА. Насыпают и снимают по-разному: холм набирают широкой
# кистью, а выедают в нём ложбину или подравнивают край — узкой. Пока ширина
# была одна на оба дела, её приходилось переключать туда-обратно на каждом
# шаге лепки.
# КАКОЙ ШИРИНОЙ СЕЙЧАС РАБОТАЮТ. Их три, и все три свои: класть, снимать и
# растить. Спрашивают отсюда все — и сам мазок, и круг подсветки, и шаг
# удержания, — поэтому кисть роста слушается своей ширины везде разом.
func _active_brush(erase: bool) -> int:
	if PlantsData.is_care(current_tool):
		return grow_brush
	if current_tool == "smooth":
		return blur_brush
	return erase_brush if erase else brush


# КИСТЬ РОСТА УЖЕ ПРОЧИХ В ПОЛТОРА РАЗА (решение пользователя 2026-08-29:
# «сделай все кисти роста меньше в полтора раза»). Делим здесь, а не в самом
# мазке, чтобы круг подсветки ужался вместе с ним: врущая подсветка хуже
# неудобной кисти. Все три ширины при этом остаются на своих местах — уже
# становятся все разом.
# ЕЩЁ УЖЕ 2026-09-01, по её слову «немного уменьши радиус действия кисти
# роста»: 1.5 → 1.9, то есть радиус меньше ещё на пятую часть. Самая узкая
# кисть роста стала 0.9 м вместо 1.1, самая широкая — 1.7 м вместо 2.2.
const GROW_SMALLER: float = 1.9

func _brush_radius(erase: bool = false) -> float:
	var r: float = CELL_SPACING * (1.15 + 1.25 * float(_active_brush(erase)))
	return r / GROW_SMALLER if PlantsData.is_care(current_tool) else r


func _stroke(at: Vector3, radius: float, amount: float, material: String,
		stone_push: float = 0.0) -> void:
	_flush_focus = at
	var touched: Array = grid.stroke_at(at, radius, amount, stone_push)
	if amount > 0.0:
		for c in touched:
			paint[c] = material
	_after_field_change(touched)


# Поле в этих ячейках изменилось — разбираемся с последствиями. Порода у ячейки
# появляется и исчезает САМА, по уровню заполнения; куски метим на пересборку.
# Общее для лепки и размывания: и то и другое двигает одно и то же поле.
func _after_field_change(touched: Array) -> void:
	# ПОДСВЕТКА УСТАРЕВАЕТ ВМЕСТЕ С ЗЕМЛЁЙ. Накладка под курсором — это КОПИЯ
	# поверхности, собранная отдельным мешем и нарисованная просвечивающей. Она
	# пересобиралась только при смене ЯЧЕЙКИ под прицелом, а при удержании кисти
	# ячейка та же самая: земля под накладкой росла, а накладка оставалась от
	# прежней формы — и торчала сквозь новую землю просвечивающими полотнищами.
	#
	# Это и есть «баги при мазке»: не двойной меш куска (тот вылечен), а вот эта
	# застывшая копия. Помечаем её на пересборку всякий раз, когда поле тронуто.
	frame_id = ""
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
	_dab(grid.seeds[cell], _stroke_amount(), material, record)


func _remove(cell: int, record: bool = true) -> void:
	if cell < 0 or not grid.in_play(cell):
		return
	_dab(grid.seeds[cell], -_stroke_amount(true), "", record)


# Один мазок в точке: и постановка, и снятие, и отмена ходят через него.
func _dab(at: Vector3, amount: float, material: String, record: bool = true) -> void:
	# Размывание — не мазок: оно ничего не кладёт, а тянет поверхность к среднему
	# по соседям. Отменить его вычислением нельзя (сколько снялось, зависит от
	# того, что было вокруг), поэтому в память кладётся сам список прибавок.
	if material == "smooth" and amount > 0.0:
		_flush_focus = at
		var delta: Dictionary = grid.blur_at(at, _brush_radius() * 1.15, BLUR)
		if delta.is_empty():
			return
		_after_field_change(delta.keys())
		if record:
			history.append({"blur": delta, "group": _group})
		return

	# КАМЕНЬ БОЛЬШЕ НЕ ЖМЁТСЯ. Прежде он клался теснее земли — «глыба должна
	# быть плотным телом, а не расплывшейся насыпью». Мысль верная, но она
	# столкнулась с другой: складки у камня заданы в МЕТРАХ (доли 6.25 и 3.6 м,
	# пласт 3.3 м), а глыба выходила 5.1 м поперёк. Складка крупнее глыбы режет
	# её целиком — и вместо слоя выходит лезвие через всё тело. Это и было на
	# кадре у пользователя.
	#
	# Замерено на одной и той же массе (доля рёбер круче 45° и излом):
	#   ×0.78 — глыба 5.1 м, 1.5 пласта, излом 9.1°, резких 1.4%, мазок 12 мс
	#   ×1.0  — глыба 6.5 м, 2.0 пласта, излом 7.3°, резких 1.1%, мазок 21 мс
	#   ×1.25 — глыба 8.2 м, 2.5 пласта, излом 6.6°, резких 1.0%, мазок 36 мс
	#   ×1.5  — глыба 9.8 м, 3.0 пласта, излом 5.9°, резких 0.9%, мазок 59 мс
	# Главный выигрыш даёт первый шаг; дальше кривая выполаживается, а цена
	# растёт кубом радиуса.
	#
	# «Плотное тело» при этом не потеряно: его теперь держит не узкий мазок, а
	# поясок краски (`STONE_WAIST`) — порода жмётся вбок внутри тела, и глыба
	# читается отдельным предметом, а не расплывшейся насыпью.
	# Снятие узнаём по знаку: у него своя ширина кисти.
	var rad := _brush_radius(amount < 0.0)
	_stroke(at, rad, amount, material, _stone_push(amount, material))
	if record:
		# КЛАДЁМ В ИСТОРИЮ САМУ ПРАВКУ, а не приказ повторить мазок. Повтор с
		# обратным знаком не годится с тех пор, как мазок стал смотреть на то,
		# что под ним: земля на камне ложится тоньше, а смена породы идёт
		# быстро — при повторе обе величины считались бы уже от другого
		# состояния. Так же давно устроено размывание.
		history.append({"field": grid.last_edit_delta,
			"stone": grid.last_stone_delta, "at": at, "rad": rad,
			"amount": amount, "mat": material, "group": _group})


# Куда мазок ведёт каменистость: кладём камень — к камню, кладём землю — от
# камня, снимаем — тоже от камня, потому что камень уходит вместе с массой.
func _stone_push(amount: float, material: String) -> float:
	# СНЯТИЕ НИЧЕГО НЕ КРАСИТ. Прежде оно уводило каменистость прочь у всего, до
	# чего дотянулось, — «камень уходит вместе с массой». Но уходит только та
	# масса, что стала пустотой; та, что осталась стоять, камнем быть не
	# перестаёт. Подкопав глыбу, игрок получал у неё землю на срезе: замерено —
	# каменистость низа падала с 0.48 до нуля, а шейдер зовёт породой то, что
	# выше половины.
	#
	# Забытая в опустевших ячейках каменистость не мешает: их не видно, а
	# насыпав туда землю, игрок сам её и сотрёт — у земли `stone` равен нулю,
	# и её мазок уводит камень прочь.
	if amount < 0.0:
		return 0.0
	var card: Dictionary = PlantsData.ITEMS.get(material, PlantsData.ITEMS["ground"])
	return float(card.get("stone", 0.0)) * 2.0 - 1.0


# НАСКОЛЬКО ШИРЕ САМОЙ КИСТИ БУДИТ ЗЕЛЕНЬ РУКА. Ровно по кисти было бы мало:
# растение сидит в точке, а видит игрок круг подсветки — отозваться должно всё,
# что в нём, иначе кочка у самого края круга стоит неподвижно, пока соседка в
# пяди от неё тянется.
const BURST_REACH: float = 1.8

# Мазок ложится ровно туда, куда наведён курсор.
func _paint(pick: Dictionary, material: String) -> void:
	if pick.has("pos"):
		_dab(pick["pos"], _stroke_amount(), material)


func _erase(pick: Dictionary) -> void:
	if pick.has("pos"):
		_dab(pick["pos"], -_stroke_amount(true), "")


# КИСТЬ СТИМУЛЯЦИИ РОСТА (решение пользователя 2026-08-28). Обычная кисть: своя
# ширина, удержание, круг подсветки. Всё, что попало в круг И ЯВЛЯЕТСЯ ТОЧКОЙ
# РОСТА, трогается в рост — не растение целиком, а именно точка (разбор точек —
# в `_growth_point`).
#
# РАБОТАЕТ ТОЛЬКО ПРИ ОСТАНОВЛЕННОМ ВРЕМЕНИ, по её решению: «в будущем режим
# времени будет вырезан, поэтому кисть стимуляции должна работать только при
# остановленном времени». Пока время идёт, пункт в панели притушен — иначе
# молчащая кисть читается поломкой.
#
# ПРЕЖДЕ ЗЕЛЕНЬ БУДИЛ ЛЮБОЙ МАЗОК ЗЕМЛЁЙ, и это тоже была её задача. Теперь
# снято по её же решению «только новая кисть»: лепить рельеф можно, не боясь
# разогнать сад, а рост стал отдельным осознанным действием.
func _stimulate_at(screen_pos: Vector2) -> void:
	if plants == null or not is_zero_approx(time_scale):
		return
	var pick := _pick(screen_pos)
	if not pick.has("pos"):
		return
	_wake_plants(pick["pos"], _brush_radius())


func _wake_plants(at: Vector3, radius: float) -> void:
	if plants != null:
		plants.burst_at(at, radius * BURST_REACH)


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
	elif a.has("field"):
		# ГЛЫБУ РАЗМАТЫВАЕМ ОТДЕЛЬНО. Она не поле и не краска: это счёт масс по
		# мазкам, из которого считается шов между глыбами, а шов входит в поле.
		# Забудь про неё — и после отмены остаётся живая глыба с массой, а вместе
		# с нею и остаток поля (замерено: 0.014 при норме ноль).
		var back: float = -_stone_push(float(a["amount"]), String(a["mat"]))
		if back * -float(a["amount"]) > 0.0:
			grid._claim_lump(a["at"], float(a["rad"]), -float(a["amount"]))
		_after_field_change(grid.apply_delta(a["field"], -1.0, a["stone"]))
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
	# ПОДСВЕТКА ПОКАЗЫВАЕТ ТО, ЧТО СДЕЛАЕТ КИСТЬ, — и ничего сверх того. Кисть
	# кладёт мазок ПО ТОЧКЕ под курсором (`_paint`) и про соседние ячейки не
	# знает вовсе. А подсветка пряталась, если ячейка СНАРУЖИ поверхности
	# оказывалась породой: это осталось от прежнего инструмента, который ставил
	# блок в ячейку, и с нынешней кистью не связано ничем.
	#
	# Наружу шагают на полшага решётки (`_pick`), и в узкой щели или под
	# нависшим краем этот шаг упирается в камень напротив. Выходило хуже всего
	# там, где игрок как раз и хочет подровнять: кисть работает, а курсор
	# погас — и место выглядит неприкасаемым.
	var pick := _pick(get_viewport().get_mouse_position())
	if not pick.has("pos"):
		frame_node.visible = false
		frame_id = ""
		return
	# Накладку ведём от ячейки ПОД поверхностью, а не от той, что снаружи:
	# именно её видно, и она есть всегда, пока луч во что-то попал.
	var here: int = int(pick["hit"])
	if here < 0 or not grid.in_play(here):
		frame_node.visible = false
		frame_id = ""
		return
	frame_node.visible = true

	# Точка прицела ходит непрерывно, поэтому её передаём каждый кадр, а вот
	# накладку по форме земли пересобираем только при смене ячейки — иначе
	# считали бы её по шестьдесят раз в секунду впустую.
	# Показываем ТУ кисть, которой сейчас будут работать: у снятия она своя.
	# Пока кнопка не нажата, о намерении говорит только Shift — у боковой
	# кнопки состояния «наведено» не бывает.
	var erasing: bool = held_erase if held else (erase_mode or Input.is_key_pressed(KEY_SHIFT))
	# Подсветка чуть уже самого мазка — чтобы контур не заезжал за то, что
	# кисть на самом деле тронет. Ходит вместе с шириной кисти.
	var rad: float = _brush_radius(erasing) * 0.94
	frame_mat.set_shader_parameter("spot", pick["pos"])
	frame_mat.set_shader_parameter("reach", rad)
	frame_mat.set_shader_parameter("tone", DIG_TONE)
	frame_mat.set_shader_parameter("strength", 0.55)

	var id := "%d:%d" % [here, _active_brush(erasing)]
	if id == frame_id:
		return
	frame_id = id
	var node: Vector3i = grid.node_of(here)
	# Накладка должна вмещать весь круг подсветки, иначе контур обрезается
	# квадратом. Считаем от настоящего радиуса, а не от номера кисти.
	var span := int(ceil(_brush_radius(erasing) / CELL_SPACING)) + 1
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

# ПАНЕЛЬ НА СТЕКЛЕ ВДВОЕ КРУПНЕЕ. Палец толще курсора: строка в одиннадцать
# пунктов пальцем не выбирается — промахи идут один за другим. На мыши всё
# остаётся как было: там мелкий плотный список выверен и менять его незачем.
var ui_scale: int = 1

# ВО СКОЛЬКО РАЗ ПАНЕЛЬ КРУПНЕЕ НА СТЕКЛЕ, считая от плотности экрана.
#
# Godot рисует в НАСТОЯЩИХ пикселях экрана, а у телефона их два-три на каждый
# условный. Поэтому постоянный множитель врёт: одно и то же число даёт разный
# размер под пальцем на разных телефонах, и чем экран плотнее, тем панель
# мельче. Берём плотность и умножаем на два — палец толще курсора, и вдвое
# крупнее мышиной вёрстки это как раз его размер.
const TOUCH_GAIN: float = 2.0      # во сколько раз крупнее мышиного при той же плотности


func _screen_ui_scale() -> int:
	var density: float = DisplayServer.screen_get_scale()
	if density <= 0.0:
		# Не всякая платформа умеет отдавать плотность напрямую — тогда считаем
		# её из числа точек на дюйм, где 96 на дюйм это обычный экран.
		var dpi: int = DisplayServer.screen_get_dpi()
		density = float(dpi) / 96.0 if dpi > 0 else 1.0
	if DisplayServer.is_touchscreen_available():
		return clampi(int(round(density * TOUCH_GAIN)), 2, 6)
	# НА МЫШИ РАЗМЕР МЕНЮ РЕШАЕТ ДОЛЯ ОКНА, А НЕ ПЛОТНОСТЬ. Жёсткая база тут
	# не живёт: под маленькое окно её просили поднять, под растянутое — она же
	# оказывалась «слишком крупной» (два решения пользователя 2026-08-31 за
	# один вечер, в разные стороны). Поэтому старт — с потолка, а правило доли
	# (`_fit_menu`) ужимает панель, пока она не уместится в свою часть окна:
	# большое окно — крупное меню, маленькое — мелкое, само.
	return 8


# Сенсорность и размер — разные вещи: крупный интерфейс бывает и на мыши
# (плотный экран), а тач-повадки — двойное нажатие посадки, кнопки отмены и
# наклона — только там, где есть стекло.
func _touch_ui() -> bool:
	return DisplayServer.is_touchscreen_available()


# МЕНЮ НЕ ЗАНИМАЕТ БОЛЬШЕ СЕДЬМОЙ ЧАСТИ ЭКРАНА.
#
# Множитель от плотности даёт панель одного размера под пальцем на любом
# телефоне — но на небольшом экране этот размер съедает пол-вида, и играть
# становится не во что. Поэтому после вёрстки меряем, что вышло, и если панель
# перебрала долю — СОБИРАЕМ ЗАНОВО с меньшим множителем.
#
# Готовую панель не сжимаем намеренно: сжатая рисует шрифт из чужого кегля и
# мылит его, а список мы только что делали читаемым.
const MENU_SHARE: float = 1.0 / 7.0
# НА ПЛОТНЫХ ЭКРАНАХ БЕЗ СТЕКЛА ДОЛЯ ВТРОЕ СТРОЖЕ (решение пользователя
# 2026-08-31): 1/7 писалась под телефон, где панель должна быть под пальцем;
# на большом мониторе высокого разрешения та же доля раздувает меню на
# пол-вида, стоит растянуть окно.
const MENU_SHARE_DENSE: float = 1.0 / 21.0

func _screen_density() -> float:
	var density: float = DisplayServer.screen_get_scale()
	if density <= 0.0:
		var dpi: int = DisplayServer.screen_get_dpi()
		density = float(dpi) / 96.0 if dpi > 0 else 1.0
	return density


func _menu_share() -> float:
	if _touch_ui():
		return MENU_SHARE
	return MENU_SHARE_DENSE if _screen_density() >= 1.5 else MENU_SHARE

var _resize_wait: bool = false
var toolbar_layer: CanvasLayer
var toolbar_panel: PanelContainer


func _fit_menu() -> void:
	# Ужимаем шагами: множитель целый, и одного пересчёта хватает почти всегда,
	# но запас на случай, если доля окажется совсем тесной.
	for _step in range(4):
		if ui_scale <= 1:
			return
		# Контейнеры считают свой размер не сразу — ждём, пока вёрстка осядет.
		await get_tree().process_frame
		await get_tree().process_frame
		if toolbar_panel == null:
			return
		var screen: Vector2 = get_viewport().get_visible_rect().size
		var budget: float = screen.x * screen.y * _menu_share()
		var taken: float = toolbar_panel.size.x * toolbar_panel.size.y
		if taken <= 0.0 or taken <= budget:
			return
		# Площадь растёт как квадрат множителя, поэтому нужную долю берём
		# корнем. Округляем ВНИЗ: лучше чуть мельче доли, чем чуть крупнее.
		var want: int = int(floor(float(ui_scale) * sqrt(budget / taken)))
		ui_scale = clampi(want, 1, ui_scale - 1)
		_clear_toolbar()
		_setup_toolbar()
		_setup_hint()


func _clear_toolbar() -> void:
	if toolbar_layer != null:
		toolbar_layer.visible = false      # чтобы старая не мелькнула поверх новой
		toolbar_layer.queue_free()
	toolbar_layer = null
	toolbar_panel = null
	group_headers.clear()
	group_boxes.clear()
	group_open.clear()
	branch_headers.clear()
	branch_boxes.clear()
	branch_open.clear()
	tool_buttons.clear()
	speed_buttons.clear()
	brush_buttons.clear()
	erase_buttons.clear()
	grow_buttons.clear()
	blur_buttons.clear()
	mode_buttons.clear()


# Просвет между переключателями. На мыши его нет — там они читаются как одна
# строка; на стекле подложки без просвета слиплись бы в сплошную плашку.
func _chip_gap() -> int:
	return 4 * ui_scale if _touch_ui() else 0


func _panel_box(round_right: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.06, 0.08, 0.07, 0.55)
	box.content_margin_left = 8 * ui_scale
	box.content_margin_right = 8 * ui_scale
	box.content_margin_top = 6 * ui_scale
	box.content_margin_bottom = 6 * ui_scale
	if round_right:
		box.corner_radius_top_right = 10
		box.corner_radius_bottom_right = 10
	else:
		box.corner_radius_top_left = 10
		box.corner_radius_bottom_left = 10
	return box


# Кнопка списка: плоская, без рамки фокуса, с мелким шрифтом и тесными полями.
#
# `chip` — для коротких переключателей (режим, ширина, время). На стекле они
# получают подложку: у слов «класть» и «снять», набранных просто текстом, нет
# ничего, что говорило бы «сюда можно ткнуть». В списке пород подложки НЕ
# ставим — там строки идут подряд, и десяток плашек читался бы рябью.
func _list_button(size: int = -1, chip: bool = false) -> Button:
	var b := Button.new()
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", (UI_FONT if size < 0 else size) * ui_scale)
	b.add_theme_constant_override("h_separation", 0)
	# Поля у кнопки по умолчанию щедрые — из них и набегает высота списка.
	# Подменяем их пустой рамкой с узкими полями, иначе шрифт мельче, а строки
	# всё те же.
	var tight := StyleBoxEmpty.new()
	tight.content_margin_left = 2 * ui_scale
	tight.content_margin_right = 4 * ui_scale
	tight.content_margin_top = 1 * ui_scale
	tight.content_margin_bottom = 1 * ui_scale
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(state, tight)
	if chip and _touch_ui():
		b.alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_theme_stylebox_override("normal", _chip_box(0.10))
		b.add_theme_stylebox_override("hover", _chip_box(0.20))
		b.add_theme_stylebox_override("pressed", _chip_box(0.26))
	return b


# Подложка переключателя: чуть светлее панели, со скруглением и полями под
# палец. Яркость передаём снаружи — ею и отличаются нажатое и спокойное.
func _chip_box(alpha: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(1, 1, 1, alpha)
	box.content_margin_left = 7 * ui_scale
	box.content_margin_right = 7 * ui_scale
	box.content_margin_top = 4 * ui_scale
	box.content_margin_bottom = 4 * ui_scale
	box.corner_radius_top_left = 4 * ui_scale
	box.corner_radius_top_right = 4 * ui_scale
	box.corner_radius_bottom_left = 4 * ui_scale
	box.corner_radius_bottom_right = 4 * ui_scale
	return box


func _setup_toolbar() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	toolbar_layer = layer

	var panel := PanelContainer.new()
	toolbar_panel = panel
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
		if g in HIDDEN_GROUPS:
			continue
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
				empty.add_theme_font_size_override("font_size", UI_FONT_SMALL * ui_scale)
				items.add_child(empty)

		group_headers[g] = head
		group_boxes[g] = body
		group_open[g] = true

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	column.add_child(gap)

	# Режим — над шириной: он решает, что вообще делает мазок, а ширина лишь
	# уточняет размах. С пальца иначе никак — Shift на стекле не нажмёшь.
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", _chip_gap())
	column.add_child(mode_row)
	var mode_title := Label.new()
	mode_title.text = "режим "
	mode_title.modulate = Color(1, 1, 1, 0.5)
	mode_title.add_theme_font_size_override("font_size", UI_FONT_SMALL * ui_scale)
	mode_row.add_child(mode_title)
	for m in MODES:
		var mb := _list_button(UI_FONT_SMALL, true)
		mb.pressed.connect(_set_erase_mode.bind(bool(m["erase"])))
		mode_row.add_child(mb)
		mode_buttons.append(mb)

	# Ширина кисти — внизу, одной строкой: она относится к выбранному, а не
	# наоборот, и наверху отталкивала список от глаза.
	var brush_row := HBoxContainer.new()
	brush_row.add_theme_constant_override("separation", _chip_gap())
	column.add_child(brush_row)
	var brush_title := Label.new()
	brush_title.text = "кисть "
	brush_title.modulate = Color(1, 1, 1, 0.5)
	brush_title.add_theme_font_size_override("font_size", UI_FONT_SMALL * ui_scale)
	brush_row.add_child(brush_title)
	for w in BRUSHES:
		var bb := _list_button(UI_FONT_SMALL, true)
		bb.pressed.connect(_set_brush.bind(int(w["width"])))
		brush_row.add_child(bb)
		brush_buttons.append(bb)

	# У СНЯТИЯ СВОЯ СТРОКА. Насыпают и снимают по-разному: холм набирают
	# широкой кистью, а выедают ложбину или подравнивают край — узкой. С одной
	# шириной на оба дела её приходилось переключать на каждом шаге лепки.
	var erase_row := HBoxContainer.new()
	erase_row.add_theme_constant_override("separation", _chip_gap())
	column.add_child(erase_row)
	var erase_title := Label.new()
	erase_title.text = "снять "
	erase_title.modulate = Color(1, 1, 1, 0.5)
	erase_title.add_theme_font_size_override("font_size", UI_FONT_SMALL * ui_scale)
	erase_row.add_child(erase_title)
	for w in BRUSHES:
		var eb := _list_button(UI_FONT_SMALL, true)
		eb.pressed.connect(_set_erase_brush.bind(int(w["width"])))
		erase_row.add_child(eb)
		erase_buttons.append(eb)

	# И У РОСТА СВОЯ СТРОКА (решение пользователя 2026-08-29). Рост — не лепка:
	# им ведут по куртине, а не подравнивают край, и ширина ему нужна другая.
	var grow_row := HBoxContainer.new()
	grow_row.add_theme_constant_override("separation", _chip_gap())
	column.add_child(grow_row)
	var grow_title := Label.new()
	grow_title.text = "рост "
	grow_title.modulate = Color(1, 1, 1, 0.5)
	grow_title.add_theme_font_size_override("font_size", UI_FONT_SMALL * ui_scale)
	grow_row.add_child(grow_title)
	for w in BRUSHES:
		var gb := _list_button(UI_FONT_SMALL, true)
		gb.pressed.connect(_set_grow_brush.bind(int(w["width"])))
		grow_row.add_child(gb)
		grow_buttons.append(gb)

	# И У РАЗМЫВАНИЯ СВОЯ (решение пользователя 2026-09-01). Заглаживают узкое
	# место, а лепят широким — общая ширина стоила двух нажатий на каждый переход.
	var blur_row := HBoxContainer.new()
	blur_row.add_theme_constant_override("separation", _chip_gap())
	column.add_child(blur_row)
	var blur_title := Label.new()
	blur_title.text = "размыть "
	blur_title.modulate = Color(1, 1, 1, 0.5)
	blur_title.add_theme_font_size_override("font_size", UI_FONT_SMALL * ui_scale)
	blur_row.add_child(blur_title)
	for w in BRUSHES:
		var lb := _list_button(UI_FONT_SMALL, true)
		lb.pressed.connect(_set_blur_brush.bind(int(w["width"])))
		blur_row.add_child(lb)
		blur_buttons.append(lb)

	_setup_time_panel(layer)
	_refresh_toolbar()


# =============================================================================
#  СНИМОК ЭКРАНА
# =============================================================================
#
# Кадр сохраняется В ПАПКУ «ИЗОБРАЖЕНИЯ» пользователя. Не в `user://` — оттуда
# его в собранной демке никто не достанет, а снимок нужен ровно затем, чтобы им
# поделиться.
#
# ПАНЕЛИ НА КАДР НЕ ПОПАДАЮТ. Для демо нужен сад, а не список инструментов;
# прячем все слои поверх мира и подсветку курсора ровно на один кадр. Ждать
# приходится `frame_post_draw`: снимок берётся с уже нарисованного кадра, и без
# ожидания в него попало бы то, что мы только что спрятали.
#
# Имя со временем — чтобы снимки не затирали друг друга: за минуту их делают
# десяток.
func _save_shot() -> String:
	var hidden: Array = []
	for node in get_children():
		if node is CanvasLayer and node.visible:
			node.visible = false
			hidden.append(node)
	var cursor_was: bool = frame_node.visible
	frame_node.visible = false
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	for node in hidden:
		node.visible = true
	frame_node.visible = cursor_was
	if img == null:
		return "не вышло"
	var t: Dictionary = Time.get_datetime_dict_from_system()
	var shot_name := "сад_%04d-%02d-%02d_%02d%02d%02d.png" % [t["year"], t["month"],
		t["day"], t["hour"], t["minute"], t["second"]]
	# Папка изображений есть не всегда (в вебе её нет вовсе) — тогда кладём
	# рядом с сохранением сада, и это лучше, чем не сохранить ничего.
	var dir: String = OS.get_system_dir(OS.SYSTEM_DIR_PICTURES)
	var path: String = (dir + "/" + shot_name) if dir != "" else ("user://" + shot_name)
	if img.save_png(path) != OK:
		path = "user://" + shot_name
		if img.save_png(path) != OK:
			return "не вышло"
	print("Снимок: ", path)
	return "сохранён"


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
	title.add_theme_font_size_override("font_size", UI_FONT_SMALL * ui_scale)
	column.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", _chip_gap())
	column.add_child(row)
	for i in range(SPEEDS.size()):
		var sb := _list_button(-1, true)     # -1 — оставить кегль по умолчанию
		sb.pressed.connect(_set_time_scale.bind(i))
		row.add_child(sb)
		speed_buttons.append(sb)

	# СОХРАНИТЬ ПРОГРЕСС — РУКОЙ, И ТОЛЬКО РУКОЙ (решение пользователя
	# 2026-09-01: «добавь кнопку „сохранить прогресс“; если она не нажата — не
	# сохраняй»). Сам по себе сад больше не пишется ни разу: ни по таймеру, ни
	# после мазка, ни при закрытии окна. Зато и не портится: пробуешь что
	# угодно, а вернуться всегда есть куда.
	var save_btn := _list_button(-1, true)
	save_btn.text = " сохранить "
	save_btn.tooltip_text = "Записать сад на диск. Само по себе не сохраняется"
	save_btn.pressed.connect(func():
		var was: bool = _game_on
		_game_on = true
		_save_garden()
		_game_on = was
		save_btn.text = " записано "
		get_tree().create_timer(2.0).timeout.connect(func():
			if is_instance_valid(save_btn):
				save_btn.text = " сохранить "))
	row.add_child(save_btn)

	# СНИМОК ЭКРАНА — отдельной кнопкой (решение пользователя 2026-09-01,
	# «критически важно для демо»). Кадр кладётся В ПАПКУ ИЗОБРАЖЕНИЙ
	# пользователя, а не в user:// — из user:// его в демо никто не достанет.
	var shot_btn := _list_button(-1, true)
	shot_btn.text = " снимок "
	shot_btn.tooltip_text = "Сохранить кадр в папку «Изображения»"
	shot_btn.pressed.connect(func():
		var mark: String = await _save_shot()
		shot_btn.text = " %s " % mark
		get_tree().create_timer(2.5).timeout.connect(func():
			if is_instance_valid(shot_btn):
				shot_btn.text = " снимок "))
	row.add_child(shot_btn)

	# НАЧАТЬ ЗАНОВО. Стирает сохранённый сад и перечитывает сцену. Действие
	# необратимое, поэтому кнопка переспрашивает сама: первое нажатие меняет
	# подпись на «точно?», второе в ближайшие три секунды — выполняет.
	var rb := _list_button(-1, true)
	rb.text = " заново "
	rb.tooltip_text = "Стереть сад и начать остров заново"
	var armed: Array = [0.0]
	rb.pressed.connect(func():
		var now: float = float(Time.get_ticks_msec()) / 1000.0
		if now - armed[0] < 3.0:
			_reset_garden()
		else:
			armed[0] = now
			rb.text = " точно? "
			get_tree().create_timer(3.0).timeout.connect(func():
				if is_instance_valid(rb):
					rb.text = " заново "))
	row.add_child(rb)

	var nb := _list_button(-1, true)
	nb.text = " новый остров "
	nb.tooltip_text = "Случайное зерно: другой остров той же породы. Сад стирается"
	var armed_n: Array = [0.0]
	nb.pressed.connect(func():
		var now: float = float(Time.get_ticks_msec()) / 1000.0
		if now - armed_n[0] < 3.0:
			_new_island()
		else:
			armed_n[0] = now
			nb.text = " точно? "
			get_tree().create_timer(3.0).timeout.connect(func():
				if is_instance_valid(nb):
					nb.text = " новый остров "))
	row.add_child(nb)

	# С ПАЛЬЦА НЕТ НИ ОТМЕНЫ, НИ НАКЛОНА: Ctrl+Z на стекле не нажать, а тангаж
	# живёт на вертикали ПКМ. Свободных жестов не осталось (см. README,
	# «Управление с пальца») — поэтому кнопки, и только на сенсорном стекле:
	# мыши они лишь загораживали бы вид.
	if _touch_ui():
		var extra := HBoxContainer.new()
		extra.add_theme_constant_override("separation", _chip_gap())
		column.add_child(extra)
		var ub := _list_button(-1, true)
		ub.text = " ⟲ отмена "
		ub.pressed.connect(_undo)
		extra.add_child(ub)
		var tilt_up := _list_button(-1, true)
		tilt_up.text = " ⤒ "
		tilt_up.tooltip_text = "Взгляд ниже к земле"
		tilt_up.pressed.connect(func():
			target_pitch = clampf(target_pitch + 15.0, -85.0, -5.0))
		extra.add_child(tilt_up)
		var tilt_down := _list_button(-1, true)
		tilt_down.text = " ⤓ "
		tilt_down.tooltip_text = "Взгляд круче сверху"
		tilt_down.pressed.connect(func():
			target_pitch = clampf(target_pitch - 15.0, -85.0, -5.0))
		extra.add_child(tilt_down)


func _toggle_group(group: int) -> void:
	# Скрытый раздел не сворачивается: клавиша с его номером осталась, а самой
	# строки в панели нет — без этой проверки цифра 3 роняла бы игру.
	if not group_open.has(group):
		return
	group_open[group] = not group_open[group]
	_refresh_toolbar()


func _toggle_branch(tier: int) -> void:
	branch_open[tier] = not branch_open[tier]
	_refresh_toolbar()


func _select_tool(id: String) -> void:
	current_tool = id
	frame_id = ""
	# КИСТЬ УХОДА САМА ОСТАНАВЛИВАЕТ ВРЕМЯ. Она работает только при стоящем
	# времени (её решение), а время по умолчанию идёт — и выбравший «Рост»
	# игрок вёл кистью по мху, не получая НИЧЕГО и без единого объяснения.
	# Молчащая кисть читается поломкой; пусть выбор инструмента сам приводит
	# мир в то состояние, в котором инструмент работает.
	if PlantsData.is_care(id) and not is_zero_approx(time_scale):
		time_scale = 0.0
		if plants != null:
			plants.time_scale = 0.0
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


func _set_erase_brush(width: int) -> void:
	erase_brush = width
	frame_id = ""
	_refresh_toolbar()


func _set_grow_brush(width: int) -> void:
	grow_brush = width
	frame_id = ""
	_refresh_toolbar()


func _set_blur_brush(width: int) -> void:
	blur_brush = width
	frame_id = ""
	_refresh_toolbar()


func _set_erase_mode(on: bool) -> void:
	erase_mode = on
	frame_id = ""            # подсветка показывает ту кисть, которой сейчас работают
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
		var taken: bool = erase_brush == int(BRUSHES[i]["width"])
		erase_buttons[i].text = "[%s]" % BRUSHES[i]["label"] if taken else " %s " % BRUSHES[i]["label"]
		erase_buttons[i].modulate = Color(1, 1, 1, 1.0 if taken else 0.5)
		var growing: bool = grow_brush == int(BRUSHES[i]["width"])
		grow_buttons[i].text = "[%s]" % BRUSHES[i]["label"] if growing else " %s " % BRUSHES[i]["label"]
		grow_buttons[i].modulate = Color(1, 1, 1, 1.0 if growing else 0.5)
		var blurring: bool = blur_brush == int(BRUSHES[i]["width"])
		blur_buttons[i].text = "[%s]" % BRUSHES[i]["label"] if blurring else " %s " % BRUSHES[i]["label"]
		blur_buttons[i].modulate = Color(1, 1, 1, 1.0 if blurring else 0.5)
	for i in range(MODES.size()):
		var now: bool = erase_mode == bool(MODES[i]["erase"])
		mode_buttons[i].text = "[%s]" % MODES[i]["label"] if now else " %s " % MODES[i]["label"]
		mode_buttons[i].modulate = Color(1, 1, 1, 1.0 if now else 0.5)
	# Отступы задаём НЕ пробелами, а самой строкой из знака и названия: пробелы
	# считаются по ширине шрифта и на мелком кегле разъезжаются.
	for group in PlantsData.GROUPS:
		var g: int = group["key"]
		if g in HIDDEN_GROUPS:
			continue
		var open: bool = group_open[g]
		# Номер оставляем: по нему раздел сворачивается с клавиатуры.
		group_headers[g].text = "%s %d %s" % ["-" if open else "+", g, group["name"]]
		group_boxes[g].visible = open
		for t in group["tiers"]:
			var info := PlantsData.tier_info(t)
			if branch_headers.has(t):
				branch_headers[t].text = "  %s %s" % [
					"-" if branch_open[t] else "+", info["name"]]
			branch_boxes[t].visible = branch_open[t] or not branch_headers.has(t)
	# ЗНАЧКИ СПИСКА — ТОЛЬКО ИЗ ASCII. Прежде тут стояли ▾ ▸ ● ○, и встроенный
	# шрифт Godot их не знает: вместо значка он рисует рамку с кодом буквы
	# внутри — те самые «прямоугольники с двумя цифрами и двумя буквами». Свой
	# шрифт ради четырёх значков в демо тащить незачем.
	for id in tool_buttons:
		var mark := "*" if id == current_tool else " "
		tool_buttons[id].text = "   %s %s" % [mark, PlantsData.ITEMS[id]["name"]]
		# УХОД ПРИТУШЕН, ПОКА ИДЁТ ВРЕМЯ. Кисть стимуляции работает только при
		# «стоп» (решение пользователя), а молчащий без объяснения пункт читается
		# поломкой: игрок водит кистью и не понимает, почему ничего нет.
		if PlantsData.is_care(id):
			tool_buttons[id].modulate = Color(1, 1, 1,
				1.0 if is_zero_approx(time_scale) else 0.35)


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


var hint_layer: CanvasLayer

func _setup_hint() -> void:
	if hint_layer != null:
		hint_layer.queue_free()
	hint_layer = CanvasLayer.new()
	add_child(hint_layer)
	var layer := hint_layer
	var label := Label.new()
	# На стекле подсказка ДРУГАЯ, а не та же вдвое крупнее: четыре мышиные
	# строки там не только занимают пол-экрана, но и врут — ни Shift, ни
	# колеса, ни боковых кнопок на телефоне нет.
	if _touch_ui():
		label.text = "Палец ведёт кисть · растения — двойным нажатием\nДва пальца двигают вид · что класть — в панели слева"
		# Кегль тоже от плотности: 11 на условный пиксель читается с вытянутой
		# руки и на редком, и на плотном экране одинаково.
		label.add_theme_font_size_override("font_size", 11 * ui_scale)
	else:
		label.text = "ЛКМ — поставить · Shift + ЛКМ или 2-я боковая — убрать (обе держатся)\n1-я боковая / Ctrl+Z — отменить (мазок кистью снимается целиком)\nПКМ — вращать · средняя — двигать · колесо — приближение\nЦифры 1-3 — свернуть раздел · режим, ширина кисти и снятия — в панели слева"
		# КЕГЛЬ ПОДСКАЗКИ — ТОТ ЖЕ, ЧТО У ПАНЕЛИ. Плотность экрана тут не
		# угадываем (на внешних мониторах она врёт): подсказка пересобирается
		# после ужатия меню и берёт готовый `ui_scale` — один размер на весь
		# интерфейс.
		label.add_theme_font_size_override("font_size", UI_FONT * ui_scale)
	var hint_px: int = ui_scale
	label.position = Vector2(16 * hint_px, 16 * hint_px)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	layer.add_child(label)

	# Пока остров достраивается, честно показываем, сколько уже готово.
	fill_label = Label.new()
	# Под подсказкой: на стекле она в две строки, и место под неё считаем от
	# того же кегля, иначе на плотном экране надпись уезжала бы на середину.
	fill_label.position = Vector2(16 * hint_px, 52 * hint_px if _touch_ui() else 76 * hint_px)
	fill_label.add_theme_font_size_override("font_size",
		11 * ui_scale if _touch_ui() else UI_FONT * ui_scale)
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


# ЧЕМ ШИРЕ КИСТЬ, ТЕМ РЕЖЕ ПОВТОР. Цена мазка растёт почти как куб радиуса:
# узкая стоит 5.9 мс, широкая — 36.6. Повторяй широкая четырнадцать раз в
# секунду, как узкая, — половину времени игра проводила бы в лепке, и камера
# начала бы дёргаться. Реже она и не нужна: за один мазок широкая трогает
# земли в восемь раз больше.
#
# Считаем от узкой: ей прежние 0.07 с, широким — во столько раз реже, во
# сколько они шире.
# Начало и конец проведения кистью, общее для всех кнопок, которыми её ведут.
#
# Держим В ПАМЯТИ, КАКАЯ кнопка ведёт. Иначе отпускание боковой обрывало бы
# проведение, начатое левой, и наоборот: у обеих одно и то же `held`.
func _hold_start(button: int, event: InputEventMouseButton, erase: bool) -> void:
	if event.pressed:
		_hold_button = button
		held = true
		held_erase = erase
		_open_group()
		_apply_at(event.position, erase)
		_hold_wait = HOLD_FIRST
	elif _hold_button == button:
		_hold_button = -1
		held = false
		_close_group()


func _hold_step() -> float:
	# КИСТЬ РОСТА ПОВТОРЯЕТСЯ РЕЖЕ ПРОЧИХ, и это не экономия, а её устройство.
	# Лепка обязана частить: каждый мазок кладёт землю, и от частоты зависит
	# форма. А подарок роста НАКОПИТЕЛЬНЫЙ и льётся по своим часам — под кистью
	# всё упирается в потолок за пару мазков, и дальше повторы перебирают сотни
	# растений, чтобы не изменить ничего. Полный потолок выливается за две
	# секунды, так что четыре мазка в секунду держат кисть непрерывной с запасом.
	if PlantsData.is_care(current_tool):
		return GROW_STEP
	return HOLD_STEP * _brush_radius(held_erase) / (CELL_SPACING * 2.4)


const GROW_STEP: float = 0.25

var held: bool = false
var held_erase: bool = false
var _hold_button: int = -1     # какая кнопка сейчас ведёт кисть
var _hold_wait: float = 0.0
var _group: int = 0            # каким числом помечены мазки одного проведения
var _group_next: int = 1


# Один мазок в точке экрана — тем, что сейчас выбрано в панели.
func _apply_at(screen_pos: Vector2, erase: bool) -> void:
	if PlantsData.is_care(current_tool):
		_stimulate_at(screen_pos)
		return
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
	# ЗДЕСЬ СТОЯЛО СОХРАНЕНИЕ ПОСЛЕ КАЖДОГО МАЗКА. Убрано 2026-09-01: сад
	# пишется только кнопкой «сохранить».


func _hold_tick(delta: float) -> void:
	if not held:
		return
	_hold_wait -= delta
	if _hold_wait > 0.0:
		return
	_hold_wait = _hold_step()
	# Пока палец на стекле, ведём кисть ПО ПАЛЬЦУ, а не по подставному курсору:
	# курсор идёт за касанием сам, но у него своя жизнь — после отрыва он
	# остаётся там, где был, и повторный мазок уходил бы в старое место.
	var at: Vector2 = _touch_pos if not _touches.is_empty() \
		else get_viewport().get_mouse_position()
	_apply_at(at, held_erase)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			panning = event.pressed
		elif event.button_index == MOUSE_BUTTON_LEFT and _plant_tap(event):
			pass                # растение на стекле сажают двойным нажатием
		elif event.button_index == MOUSE_BUTTON_LEFT:
			# Кисть ведут НАЖАТИЕМ И УДЕРЖАНИЕМ. Пока кнопка держится, мазок
			# повторяется сам — иначе насыпать холм значит долбить по кнопке
			# три десятка раз, и рука устаёт раньше, чем появляется форма.
			_hold_start(MOUSE_BUTTON_LEFT, event, event.shift_pressed or erase_mode)
		elif event.button_index == MOUSE_BUTTON_XBUTTON1 and event.pressed:
			_undo()                                    # 1-я боковая — отмена
		elif event.button_index == MOUSE_BUTTON_XBUTTON2:
			# 2-я боковая — СНЯТИЕ, и тоже удержанием. Прежде она была одиночным
			# щелчком: насыпать можно было ведя кисть, а выедать — только
			# долбя по кнопке. Работа одна и та же, значит и рука должна
			# работать одинаково.
			_hold_start(MOUSE_BUTTON_XBUTTON2, event, true)
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
	elif event is InputEventScreenTouch or event is InputEventScreenDrag:
		_touch_input(event)
	elif event is InputEventKey and event.pressed:
		if event.keycode == KEY_Z and event.ctrl_pressed:
			_undo()
		elif event.keycode >= KEY_1 and event.keycode <= KEY_4:
			_toggle_group(event.keycode - KEY_1 + 1)


# --- Сенсорный экран ---------------------------------------------------------
#
# Демо открывают и с телефона, а там нет ни колеса, ни правой кнопки, ни Shift.
# Жесты разведены ПО ЧИСЛУ ПАЛЬЦЕВ: один ведёт кисть, два двигают камеру.
#
# Godot сам подставляет мышь под первое касание, и это НЕ отключено намеренно:
# на подставной мыши держатся и одиночный мазок, и нажатия по списку слева —
# без неё панель на телефоне перестала бы отзываться. Сюда приходит лишь то,
# чего мышью не изобразить: второй палец и всё, что он приносит.
const TOUCH_PAN: float = 0.0022    # палец грубее мыши — шаг панорамы крупнее
const TWIST_DEAD: float = 0.35     # градусы: дрожание пальцев — ещё не поворот
const TOUCH_EASE: float = 0.35     # насколько замер идёт за пальцем, а не за шумом

const TAP_AGAIN: float = 0.45      # секунд между нажатиями, чтобы счесть их двойным
const TAP_NEAR: float = 44.0       # ...и насколько близко второе к первому, в точках

var _touches: Dictionary = {}      # палец -> где он сейчас
var _touch_pos: Vector2 = Vector2.ZERO   # где палец, ведущий кисть
var _tap_time: float = -10.0
var _tap_pos: Vector2 = Vector2.ZERO
var _gesture_on: bool = false
var _gesture_dirty: bool = false   # пальцы сдвинулись — пересчитать в начале кадра
var _pinch_span: float = 0.0       # расстояние между пальцами
var _pinch_mid: Vector2 = Vector2.ZERO
var _pinch_turn: float = 0.0       # наклон линии между пальцами, радианы


# РАСТЕНИЯ НА СТЕКЛЕ САЖАЮТ ДВОЙНЫМ НАЖАТИЕМ, а не одиночным.
#
# Землю и камень ведут удержанием, и палец на них лежит подолгу. Если тем же
# движением сажать, то каждое касание при лепке роняло бы кочку — а на стекле
# касание случается и когда просто примеряешься, куда ткнуть.
#
# Возвращает true, если событие разобрано здесь и обычному удержанию его
# отдавать не нужно. На мыши всегда false: там ничего не меняется.
func _plant_tap(event: InputEventMouseButton) -> bool:
	if not _touch_ui() or not PlantsData.is_plant(current_tool):
		return false
	if erase_mode or event.shift_pressed:
		return false             # снятие оставляем одиночным: убирать — не сажать
	if not event.pressed:
		return true              # отпускание гасим: проведения тут нет
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var near: bool = event.position.distance_to(_tap_pos) < TAP_NEAR * float(ui_scale)
	if now - _tap_time < TAP_AGAIN and near:
		_open_group()            # посадка — одна отмена, как и мазок
		_apply_at(event.position, false)
		_close_group()
		_tap_time = -10.0        # третье нажатие подряд — уже не двойное
	else:
		_tap_time = now
		_tap_pos = event.position
	return true


func _touch_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
			if _touches.size() == 1:
				_touch_pos = event.position
			if _touches.size() == 2:
				# Второй палец означает «я двигаю камеру, а не леплю».
				# Мазок, успевший лечь под первым пальцем, снимаем: щипок,
				# оставляющий за собой бугор, — это ловушка, а не управление.
				_cancel_stroke()
				_gesture_begin()
		else:
			_touches.erase(event.index)
			if _touches.size() >= 2:
				_gesture_begin()   # пальцев ещё хватает — мерим заново
			else:
				_gesture_on = false
	elif event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _gesture_on and _touches.size() >= 2:
			# НЕ считаем прямо здесь. События приходят по одному на палец и по
			# нескольку за кадр, и тогда новое положение одного пальца
			# считалось бы против СТАРОГО положения второго — из этого
			# рождались поворот и зум, которых рука не делала.
			_gesture_dirty = true
		elif _touches.size() == 1:
			_touch_pos = event.position


# Считаем по ДВУМ ПЕРВЫМ пальцам. Третий и дальше игнорируем: ладонь, легшая
# на край стекла, иначе уводила бы вид рывком.
func _touch_pair() -> Array:
	var keys: Array = _touches.keys()
	keys.sort()
	return [_touches[keys[0]], _touches[keys[1]]]


func _gesture_begin() -> void:
	if _touches.size() < 2:
		return
	var p := _touch_pair()
	var a: Vector2 = p[0]
	var b: Vector2 = p[1]
	_pinch_span = maxf(a.distance_to(b), 1.0)
	_pinch_mid = (a + b) * 0.5
	_pinch_turn = (b - a).angle()
	_gesture_on = true


func _gesture_update() -> void:
	var p := _touch_pair()
	var a: Vector2 = p[0]
	var b: Vector2 = p[1]
	var span: float = maxf(a.distance_to(b), 1.0)
	var mid: Vector2 = (a + b) * 0.5
	var turn: float = (b - a).angle()

	# Палец на стекле дрожит, и его положение приходит с шумом. Ведём замеры
	# СГЛАЖЕННО: без этого дрожь уходит прямо в поворот и зум, и вид трясётся
	# даже когда рука лежит неподвижно. Движение при этом не теряется —
	# сглаженный замер догоняет настоящий, просто на кадр позже.
	span = lerpf(_pinch_span, span, TOUCH_EASE)
	mid = _pinch_mid.lerp(mid, TOUCH_EASE)
	turn = _pinch_turn + wrapf(turn - _pinch_turn, -PI, PI) * TOUCH_EASE

	# Щипок — приближение. Берём ОТНОШЕНИЕ, а не разность: иначе у самого лица
	# и на общем плане одно и то же движение пальцев меняло бы вид по-разному.
	target_zoom = clampf(target_zoom * (_pinch_span / span), 0.8, 140.0)

	# Перенос пары — панорама, тем же законом, что и средняя кнопка мыши:
	# земля идёт ЗА пальцами, а не против них.
	var shift: Vector2 = mid - _pinch_mid
	var flat := _camera_flat_axes()
	var scale: float = cur_zoom * TOUCH_PAN
	target_pivot += (-flat.right * shift.x + flat.forward * shift.y) * scale

	# Скручивание пары — поворот вокруг вертикали. Мёртвая зона тут не
	# придирка: при панораме пальцы всегда чуть перекашиваются, и без неё
	# вид расползался бы вбок на каждом движении.
	var twist: float = rad_to_deg(wrapf(turn - _pinch_turn, -PI, PI))
	if absf(twist) > TWIST_DEAD:
		# Мёртвую зону ВЫЧИТАЕМ, а не перешагиваем. Прежде поворот, едва
		# перевалив порог, применялся целиком — вид трогался рывком на её
		# величину, а у самого порога дёргался туда-сюда.
		target_yaw += twist - signf(twist) * TWIST_DEAD

	_pinch_span = span
	_pinch_mid = mid
	_pinch_turn = turn


# Оборвать начатое проведение, не оставив следа. Отменяем ТОЛЬКО если этот
# мазок успел попасть в историю: иначе палец, опущенный мимо земли, стирал бы
# предыдущее проведение — чужую работу.
func _cancel_stroke() -> void:
	if not held:
		return
	var mark: int = _group
	_hold_button = -1
	held = false
	_close_group()
	if mark != 0 and not history.is_empty() \
			and int(history[history.size() - 1].get("group", 0)) == mark:
		_undo()


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

	# ПОДОГНАНЫ ЛИ ТЕНИ ПОД ОСТРОВ (`_fit_shadow`). Саму резкость числом не
	# померить — её судит кадр, — а вот ДАЛЬ, на которую тень растянута, померить
	# можно, и резкость идёт именно от неё: карта теней постоянного размера, и
	# чем даль больше, тем крупнее клетка.
	#
	# Три отдаления: вплотную, обычное и самое дальнее, какое пускает колесо.
	# Клетка — ОЦЕНКА по углу обзора, а не замер: сколько именно карты движок
	# отдаст острову, изнутри игры не спросишь.
	var was_zoom: float = cur_zoom
	var was_pivot: Vector3 = cur_pivot
	var map: float = maxf(1.0, float(ProjectSettings.get_setting(
		"rendering/lights_and_shadows/directional_shadow/size", 4096)))
	cur_pivot = Vector3.ZERO
	var shadow_line: Array = []
	for z in [0.8, 42.0, 140.0]:
		cur_zoom = float(z)
		_apply_camera()
		var far: float = sun.directional_shadow_max_distance
		var span: float = 2.0 * far * tan(deg_to_rad(camera.fov) * 0.5)
		shadow_line.append("с %s м камеры — тень до %s м, клетка около %s см"
			% [snappedf(float(z), 0.1), snappedf(far, 0.1),
			snappedf(span / map * 100.0, 0.1)])
	cur_zoom = was_zoom
	cur_pivot = was_pivot
	_apply_camera()
	print("Тени подогнаны под остров: ", "; ".join(shadow_line),
		" — прежде даль была ровно 100 м на любом отдалении: с 67 м камеры",
		" дальний край острова начинал терять тень (движок гасил её с 80 м),",
		" а за 113 м её не оставалось нигде")

	var start: int = grid.cell_at(_test_spot())
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
			_dab(_test_spot(), _stroke_amount(), "ground")
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
	# СНАЧАЛА СТАВИМ ГЛЫБУ, ПОТОМ СПРАШИВАЕМ ПРО КАМЕНЬ. Без неё проверка
	# осматривала на камне ноль мест и уверенно докладывала, что там всё хорошо, —
	# те же грабли, что уже записаны: проверка должна трогать то, что проверяет.
	_seed_structures()
	_flush_chunks()
	# Теперь, и только теперь, есть что мерить: настоящий массив из четырёх
	# колонн стоит в мире, и облик камня судят по нему.
	_stone_surface_check(_cliff_focus, 4.5)
	_reach_check()
	_seed_vine()
	_seed_vine_on_rock()
	_seed_moss(6)
	_flush_chunks()
	print("Посев мха: кочек — ", _moss_count())
	# Мох не должен пережить снос земли, на которой рос.
	# БЕРЁМ ИМЕННО МОХ, а не первого встречного. С появлением лианы первой в
	# списке оказалась она, и проверка сносила землю под ней — то есть убивала
	# лиану и мерила совсем не то, что написано в её названии.
	var host := -1
	for pid in plants.patches:
		if String(plants.patches[pid]["id"]) != "moss":
			continue
		host = int(plants.patches[pid]["cell"])
		break
	var moss_before: int = _moss_count()
	# Сносим то место несколько раз подряд: одного мазка мало, чтобы земля ушла
	# из-под кочки дальше половины ячейки.
	for _i in range(4):
		_remove(host)
	_flush_chunks()
	print("Мох на снесённой земле: было ", moss_before,
		", осталось ", _moss_count())

	# СРОК ЗДЕСЬ ОТМЕРЕН НЕ ВРЕМЕНЕМ, А САДОМ. Растения ускорены вдвое (решение
	# пользователя 2026-08-21), и прежние сорок пять секунд дают теперь впятеро
	# больше кочек: рост складывается сам с собой, и вдвое быстрее по времени —
	# это куда больше, чем вдвое по числу. Ждём вдвое меньше, чтобы сад выходил
	# ТОТ ЖЕ, что и во всех прежних замерах, — иначе ни одно записанное число
	# не с чем будет сравнить.
	var t1 := Time.get_ticks_usec()
	for _i in range(150):
		plants._tick(0.15)
	var grow := (Time.get_ticks_usec() - t1) / 1000.0
	# ПЕРЕСБОРКУ МЕРЯЕМ ОТДЕЛЬНО ОТ РОСТА. Рост её больше не делает — только
	# помечает, — а собирает кадр с запасом. Это две разные цены, и лечатся они
	# разным: рост дешевеет правилами, пересборка — размером кусков.
	var t2 := Time.get_ticks_usec()
	plants.flush_now()
	var draw := (Time.get_ticks_usec() - t2) / 1000.0
	var built: Vector2 = plants.rebuild_stats()
	print("Растения: кочек — ", _moss_count(),
		", 22 секунды роста за ", snappedf(grow, 0.1), " мс")
	print("Пересборка сада: ", snappedf(draw, 0.1), " мс на ", int(built.x),
		" кусков, самый дорогой — ", snappedf(built.y, 0.1),
		" мс; запас на кадр ", snappedf(plants.REBUILD_MS, 0.1),
		" мс — дорогой кусок его не делится и перебирает в одиночку")
	# ЧЕГО СТОИТ ТЕНЬ ОТ РАСТЕНИЙ. Сам расход на видеокарте отсюда не померить —
	# в безоконном прогоне никто ничего не рисует, — а вот ЧИСЛО МЕШЕЙ померить
	# можно, и цена идёт от него: каждый рисуется второй раз, в карту теней.
	# В ячейке меш один на все её растения, поэтому их сотни, а не тысячи.
	print("Тень от растений: мешей в саду — ", plants.cell_nodes.size(),
		" при ", _moss_count(), " кочках — столько же вызовов и прибавится",
		" на тень; расход на видеокарте судит только живой кадр")

	# СИДИТ ЛИ МОХ НА ЗЕМЛЕ. Промах считаем до того самого среза, по которому
	# режется картинка: сколько тут метров — столько глаз и видит просвета под
	# кочкой. Норма — нули; оторвавшихся быть не должно вовсе.
	var gap_max := 0.0
	var gap_sum := 0.0
	var lost := 0
	# И ОТДЕЛЬНО — ПО КРАЮ. Середина кочки садится на землю поиском, а край
	# набирается из своих точек, и висеть над склоном может именно он: середина
	# при этом сидит как влитая, и по ней ничего не видно.
	var edge_max := 0.0
	var edge_lost := 0
	for pid in plants.patches:
		if String(plants.patches[pid]["id"]) != "moss":
			continue                 # у лианы нет обода, и мерить у неё нечего
		var gap: float = grid.surface_gap(plants.patches[pid]["pos"])
		var rim: Array = plants.patches[pid]["body"]["rim"]
		for s in range(rim.size()):
			var out: float = grid.surface_gap(Vector3(plants.patches[pid]["pos"])
				+ Vector3(rim[s]["off"]))
			if out < 0.0:
				edge_lost += 1
			else:
				edge_max = maxf(edge_max, out)
		if gap < 0.0:
			lost += 1
			continue
		gap_sum += gap
		gap_max = maxf(gap_max, gap)
	var sat: int = _moss_count() - lost
	print("Мох на земле: оторвалось — ", lost, ", промах в среднем ",
		snappedf(gap_sum / maxf(1.0, float(sat)), 0.001), " м, наибольший ",
		snappedf(gap_max, 0.001), " м")
	print("Край кочки: над землёй до ", snappedf(edge_max, 0.001),
		" м, повисших краёв — ", edge_lost, ", поджато секторов — ",
		plants.stub_count())
	# КОРОБОЧКИ СО СПОРАМИ. Ноль на молодом саду — норма: они начинаются с
	# седьмой ступени из девяти, а за двадцать две секунды столько успевают
	# немногие. Ноль на СТАРОМ саду значил бы, что порог не срабатывает вовсе.
	var pods: Vector2i = plants.spore_stats("moss")
	print("Коробочки со спорами: на ", pods.x, " кочках из ", _moss_count(),
		", всего ", pods.y, " — растут с седьмой ступени из девяти")
	_meet_report()

	# ЧЕМ КОЧКА ОБХОДИТСЯ. Объём у неё теперь настоящий — тело куполом, — и это
	# та цена, которую надо держать на виду: мох должен выглядеть пушистым, но
	# заросший остров — это тысячи кочек.
	plants.flush_now()          # меши собираются с запасом на кадр — здесь ждать нечего
	var tris := 0
	for cell in plants.cell_nodes:
		var mesh: ArrayMesh = plants.cell_nodes[cell].mesh
		for si in range(mesh.get_surface_count()):
			var indexed: int = mesh.surface_get_array_index_len(si)
			tris += (indexed if indexed > 0 else mesh.surface_get_array_len(si)) / 3
	print("Растения: треугольников всего — ", tris, ", на растение — ",
		snappedf(float(tris) / maxf(1.0, float(plants.patches.size())), 0.1),
		", кусков меша — ", plants.cell_nodes.size())
	var sheet: Vector2i = plants.see_through()
	print("Разметка тела: просвечивающих точек — ", sheet.x,
		", самая тесная клетка — ", sheet.y, " точек")
	var vine: Dictionary = plants.vine_stats()
	if int(vine["links"]) > 0:
		var links: float = maxf(1.0, float(vine["links"]))
		print("Лиана: звеньев — ", vine["links"], ", корней — ", vine["roots"],
			", развилок — ", vine["forks"], ", самая длинная плеть — ",
			vine["deep"], " звеньев, дальний порядок ветви — ", vine["order"],
			", вширь по земле ", snappedf(float(vine["wide"]) * 100.0, 0.1), " см")
		print("Лиана у опоры: НА КАМНЕ ", vine["rock"], " звеньев из ",
			vine["links"], "; крутизна под ней ",
			snappedf(float(vine["steep"]) / links, 0.001), " против ",
			snappedf(_land_steep, 0.001), " по острову — во столько раз круче: ",
			snappedf(float(vine["steep"]) / links / maxf(_land_steep, 0.001), 0.01))
		print("Лиана: поднялась над корнем на ",
			snappedf(float(vine["tall"]) * 100.0, 0.1), " см; шаг звена ",
			snappedf(float(vine["run"]) / links * 100.0, 0.1),
			" см, самое длинное колено ", snappedf(float(vine["long"]) * 100.0, 0.1),
			" см при пределе ", snappedf(float(vine["cap"]) * 100.0, 0.1), " см")
	var bump: Vector2 = plants.bump_stats()
	print("Рельеф тела: уклон образца — ", snappedf(bump.x, 0.0001),
		" яркости на точку, наклон до ", snappedf(bump.y, 0.1), "°",
		" — снят" if flat_moss else "")
	var tilt: Vector2 = plants.tilt_stats()
	print("Наклон кочки: ось до ", snappedf(tilt.x, 0.1), "°, земля под ней до ",
		snappedf(tilt.y, 0.1), "° — числа должны совпадать")
	var sizes: Vector3 = plants.size_stats()
	print("Размер кочек: от ", snappedf(sizes.x, 0.01), " до ",
		snappedf(sizes.y, 0.01), ", у соседей разнится на ",
		snappedf(sizes.z, 0.01))
	var merged: Vector2 = plants.merge_stats()
	print("Срастание: соседей у кочки — ", snappedf(merged.x, 0.1),
		", перемычка до ближнего — ", snappedf(merged.y * 100.0, 0.1),
		"% своей высоты")

	# ЛИАНА — В САМОМ КОНЦЕ. Долгий прогон для неё убирает мох (тот тикает дороже
	# всех и к делу не относится), а значит все проверки мха должны быть уже
	# напечатаны: иначе они считают по пустому месту и врут не глядя.
	if plants.vine_stats()["links"] > 0:
		_vine_grown_check()
		_grow_limit_check()
		_vine_brake_check()
		_burst_check()
		_plant_gift_check()
		_vine_reshape_check()
		_vine_tip_check()
		_vine_hang_check()          # он сносит все лианы — только последним
	# СТЕНД ВСТРЕЧИ — ПОСЛЕ ВСЕГО. Он сносит сад и растит свой, поэтому мерить
	# после него уже нечего; зато и мешать ему некому.

	# САД ПЕРЕЖИВАЕТ СОХРАНЕНИЕ. Каноном считается второй круг: снимок,
	# снятый с уже восстановленного мира, обязан восстановиться В НОЛЬ — это и
	# есть проверка сериализации и пересчёта. Первый круг сравнивается с живым
	# миром и сходится лишь ПОЧТИ: у мазка есть записанная грабля — огранка
	# зависит от разглаженной каменистости, а та меняется дальше, чем мазок
	# освежает поле. Восстановление считает честно, поэтому у кромок камня
	# остаётся хвост порядка сотых — он печатается справкой, а не приговором.
	var keep_path: String = save_path
	save_path = "user://selftest_garden.save"
	var was_fill: PackedFloat32Array = grid.fill.duplicate()
	var was_plants: int = plants.patches.size()
	_game_on = true
	_save_garden()
	_game_on = false
	var ok_load: bool = _load_garden()
	var live_drift: float = 0.0
	for j in range(grid.fill.size()):
		live_drift = maxf(live_drift, absf(grid.fill[j] - was_fill[j]))
	var canon_fill: PackedFloat32Array = grid.fill.duplicate()
	var canon_plants: int = plants.patches.size()
	_game_on = true
	_save_garden()
	_game_on = false
	var ok_again: bool = _load_garden()
	var drift: float = 0.0
	for j in range(grid.fill.size()):
		drift = maxf(drift, absf(grid.fill[j] - canon_fill[j]))
	print("Сохранение сада: загрузилось — ", ok_load, " и повторно — ", ok_again,
		", растений ", plants.patches.size(), " из ", was_plants,
		" (после первого круга ", canon_plants, ")",
		", сдвиг поля во втором круге ", snappedf(drift, 0.0001),
		" — норма ноль; расхождение с живым миром ", snappedf(live_drift, 0.0001),
		" — хвосты мазка у кромок камня, беды нет до 0.02")
	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(save_path)
	save_path = keep_path

	_meet_stand()

	await get_tree().physics_frame
	await get_tree().physics_frame
	var pick := _pick(get_viewport().get_visible_rect().size * 0.5)
	print("Самопроверка: прицел — ", "мимо" if pick.is_empty() else str(pick["hit"]))


# ЦЕЛА ЛИ ПОВЕРХНОСТЬ ТАМ, ГДЕ ЛЕЖИТ КАМЕНЬ.
#
# Общая проверка целостности идёт по нетронутому миру, сразу после постройки. А
# у камня своя добавка к полю — доли и слои, — и её она не видела НИ РАЗУ:
# пользователь показала на кадре ножевые рёбра там, где числа молчали.
#
# Считаем ровно тем же прибором, но по кусочку вокруг глыбы. Незамкнутые рёбра
# тут не годятся: у любой вырезанной области край даёт их тысячами. Годятся
# ВЫВЕРНУТЫЕ — они от границы области не зависят. И отдельно самое острое ребро:
# за 90° — это уже шип, а не грань.
# ГДЕ ЗЕМЛЯ ВИДНА, А ПОСАДИТЬ НЕЛЬЗЯ.
#
# Проверка ровно того, на что жалуется рука: наводишь мох на глыбу — а курсор
# посадки не загорается, и поставить некуда. Курсор спрашивает у сетки
# `surface_near`, и если та отвечает «земли рядом нет» там, где земля ВИДНА, —
# это её ошибка, а не особенность места.
#
# Меряем по видимому срезу: `surface_gap` находит его тем же способом, каким
# режется картинка. Есть срез — место на кадре есть, и посадка обязана его
# найти. Считаем порознь по камню и по земле: у камня поле круче, и подозрение
# именно на него.
var _land_steep: float = 0.0      # средняя крутизна видимой земли — мерка для лианы

func _reach_check() -> void:
	var seen := [0, 0]
	var lost := [0, 0]
	var why := [0, 0, 0, 0, 0, 0]
	var steep_sum := 0.0
	var steep_kind := [0.0, 0.0]
	var steep_top := [0.0, 0.0]
	for cell in range(grid.seeds.size()):
		if not grid.in_play(cell):
			continue
		var p: Vector3 = grid.seeds[cell]
		if grid.surface_gap(p) < 0.0:
			continue                 # эта ячейка не у поверхности — не о ней речь
		var kind: int = 1 if grid.stone_of(cell) > 0.02 else 0
		seen[kind] += 1
		var st: float = grid.steepness_of(cell)
		steep_sum += st
		steep_kind[kind] += st
		steep_top[kind] = maxf(steep_top[kind], st)
		if grid.surface_near(p).is_empty():
			lost[kind] += 1
			why[grid.near_why] += 1
	var blame := ""
	for i in range(why.size()):
		if why[i] > 0:
			blame += ", %s — %d" % [grid.NEAR_NAMES[i], why[i]]
	_land_steep = steep_sum / maxf(1.0, float(seen[0] + seen[1]))
	print("Посадка: видимых мест на земле — ", seen[0], ", недоступных ", lost[0],
		"; на камне — ", seen[1], ", недоступных ", lost[1], blame)
	# ЕСТЬ ЛИ ЛИАНЕ К ЧЕМУ СТРЕМИТЬСЯ. Если камень по крутизне не отличается от
	# земли, то искать опору не только не получается — её и нет: чинить надо не
	# поиск, а саму мерку опоры.
	print("Крутизна видимой земли: на земле в среднем ",
		snappedf(steep_kind[0] / maxf(1.0, float(seen[0])), 0.001), ", до ",
		snappedf(steep_top[0], 0.001), "; на камне в среднем ",
		snappedf(steep_kind[1] / maxf(1.0, float(seen[1])), 0.001), ", до ",
		snappedf(steep_top[1], 0.001), " — по этой мерке и судят лиану")


# ПРОВЕРКА МЕРЯЕТ НАСТОЯЩИЙ МАССИВ, а не временный блин.
#
# ГРАБЛИ, СВОИ ЖЕ. Она лепила три мазка на ровном месте — выходил низкий блин, —
# и по нему докладывала «самое острое ребро 34.4°». Успокаивающая неправда: та
# глыба, что видна в кадре (`_seed_structures` — четыре колонны по четыре
# уровня), даёт числа заметно хуже. Пока проверка мерила блин, беда была на
# виду, а числа молчали.
#
# `reach` — сколько метров вокруг точки осматриваем. Массив из четырёх колонн
# шириной с широкую кисть занимает около четырёх метров от середины.
func _stone_surface_check(at: Vector3, reach: float) -> void:
	var home: int = grid.cell_at(at)
	if home < 0:
		print("Поверхность камня: мерить нечего — глыбы в этом месте нет")
		return
	var node: Vector3i = grid.node_of(home)
	var span := int(ceil(reach / CELL_SPACING)) + 2
	var edge := Vector3i(span, span, span)
	var edges: Dictionary = {}
	var stats: Dictionary = {}
	SurfaceScript.audit(grid, node - edge, node + edge, edges, stats)
	var twice := 0
	for k in edges:
		if int(edges[k]) > 1:
			twice += 1
	var e: Dictionary = _edge_stats(node - edge, node + edge)
	var total: float = maxf(1.0, float(e["edges"]))
	var alive := 0
	for l in grid.lumps:
		if float(l["mass"]) > 0.0:
			alive += 1
	print("Глыб в массиве: ", alive, " — столько же, сколько было мазков камня",
		" врозь (ближе ", grid.LUMP_MERGE, " м мазки лепят одну и ту же)")
	_bodies_report(at, reach)
	print("Поверхность камня: вывернутых рёбер ", twice, ", вывернутых тетраэдров ",
		int(stats.get("inverted", 0)), ", рёбер по камню — ", int(e["edges"]))
	print("Грани камня: плоских рёбер (тише 5°) ",
		snappedf(100.0 * float(e["flat"]) / total, 0.1), "%, заломов круче 20°: выпуклых ",
		snappedf(100.0 * float(e["ridge_bend"]) / total, 0.1), "%, вогнутых ",
		snappedf(100.0 * float(e["cave_bend"]) / total, 0.1),
		"% — у гладкого кома плоских мало, а заломов нет вовсе")
	print("Рёбра камня: вогнутых круче 45° — ",
		snappedf(100.0 * float(e["cave_sharp"]) / total, 0.01),
		"% (щели и зубцы), худшее ", snappedf(float(e["cave_worst"]), 0.1),
		"°; выпуклых — ", snappedf(100.0 * float(e["ridge_sharp"]) / total, 0.01),
		"% (гребни, камню идут), худшее ", snappedf(float(e["ridge_worst"]), 0.1),
		"° — за 90° шип с любым знаком")
	print("Шипы: за 90° всего ", int(e["spike"]), ", из них на швах между глыбами ",
		int(e["spike_seam"]), "; резких за 45° всего ", int(e["sharp"]),
		", на швах ", int(e["sharp_seam"]),
		" — шов и край мазка лечатся разным")
	# ГДЕ СИДЯТ РЕЗКИЕ РЁБРА: на нависании или на том, что смотрит вверх. Общая
	# доля их прячет: одна и та же сотая доля на кровле незаметна, а на кромке
	# нависания читается пилой.
	var over: float = maxf(1.0, float(e["over_edges"]))
	var up: float = maxf(1.0, float(e["up_edges"]))
	print("Нависание камня: рёбер ", int(e["over_edges"]), ", резких за 45° — ",
		snappedf(100.0 * float(e["over_sharp"]) / over, 0.01), "%, худшее ",
		snappedf(float(e["over_worst"]), 0.1), "°; для сравнения на кровле ",
		int(e["up_edges"]), " рёбер и ",
		snappedf(100.0 * float(e["up_sharp"]) / up, 0.01),
		"% резких — пильчатый край это перекос в пользу нависания")
	# ПЛОСКИЕ ПЛИТЫ. Кадр: «образуются ромбовидные грубые структуры». Ромб — это
	# не ребро, а СЛИПШАЯСЯ ПЛИТА: десятки треугольников, легших в одну
	# плоскость. Ребро о ней не скажет ничего, поэтому меряем площадью.
	print("Плиты камня: цельных ", int(e["plates"]), " на ",
		snappedf(float(e["skin"]), 0.1), " кв.м шкуры; самая крупная ",
		snappedf(float(e["plate_top"]), 0.01), " кв.м, а всё, что крупнее",
		" квадратного метра, занимает ",
		snappedf(100.0 * float(e["plate_big"]), 0.1),
		"% камня — крупная плита и читается ромбом")


# РЁБРА КАМНЯ, ПОРОЗНЬ ПО ЗНАКУ. Общая мерка «излом круче 45°» валит в одну кучу
# две разные вещи, и по ней не видно, что чинить:
#
#   ВОГНУТОЕ ребро — прорезь, зубец, щель. Грань в такой щели смотрит вниз,
#     света не получает и читается чёрным клином. Глаз цепляется за него.
#   ВЫПУКЛОЕ ребро — гребень, кромка, скол. Камню оно ИДЁТ: без выпуклых рёбер
#     глыба остаётся гладким комом.
#
# Мерка нужна именно теперь: швы между глыбами вогнуты по своей природе, и
# судить их надо не по общему числу изломов, а следя, чтобы среди них не
# завелось настоящих шипов.
#
# ЗНАК БЕРЁМ ПО ЦЕНТРАМ ДВУХ ГРАНЕЙ: ушёл сосед в ту сторону, куда СМОТРИТ
# первая грань, — поверхность заворачивается внутрь, это щель; ушёл против —
# гребень. Грани для этого уже развёрнуты лицом наружу, иначе знак был бы
# случайным.
func _edge_stats(lo: Vector3i, hi: Vector3i) -> Dictionary:
	var faces: Dictionary = {}
	# ПЛОЩАДЬ КАЖДОГО ТРЕУГОЛЬНИКА И ЕГО НОМЕР — для мерки плоских ПЛИТ (см.
	# `_plate_stats`). Ребро говорит только «тут гладко», а ромб на кадре — это
	# не ребро, а слипшаяся из многих треугольников плоская плита.
	var tri_area := PackedFloat32Array()
	var tri_up := PackedFloat32Array()
	var idx := PackedInt32Array()
	idx.resize(8)
	var val := PackedFloat32Array()
	val.resize(8)
	var seeds: PackedVector3Array = grid.seeds
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
					var s: int = grid.node_seed(here + SurfaceScript.CORNER[c])
					if s < 0:
						ok = false
						break
					idx[c] = s
					val[c] = grid.fill_of(s)
					if val[c] <= 0.5:
						below += 1
				if not ok or below == 0 or below == 8 or grid.stone_of(idx[0]) <= 0.02:
					continue
				for t in SurfaceScript.TETS:
					var cnt: int = SurfaceScript.tet_polygon(seeds, idx, val, t,
						cpos, ca, cb, cw)
					if cnt == 0:
						continue
					# РАЗВОРАЧИВАЕМ ЛИЦОМ НАРУЖУ, как это делает отрисовка. Без
					# этого у соседних треугольников обход случайный, нормали
					# смотрят врозь, и ровное место показывает 180°.
					var want: Vector3 = SurfaceScript._outward(seeds, idx, val, t)
					for f in range(1, cnt - 1):
						var turn: int = SurfaceScript.wound_order(cpos[0],
							cpos[f], cpos[f + 1], want)
						if turn < 0:
							continue
						var tri: Array = [0, f, f + 1]
						if turn == 1:
							tri = [f + 1, f, 0]
						var n: Vector3 = (cpos[tri[1]] - cpos[tri[0]]).cross(
							cpos[tri[2]] - cpos[tri[0]])
						if n.length() < 0.0000001:
							continue
						var tid: int = tri_area.size()
						tri_area.append(n.length() * 0.5)
						# НОРМАЛЬ ЗДЕСЬ СМОТРЕЛА ВНУТРЬ, И ЗНАК РЁБЕР БЫЛ
						# ПЕРЕВЁРНУТ. `wound` разворачивает треугольник под
						# правило Godot — обход ПО ЧАСОВОЙ снаружи, — а у такого
						# обхода векторное произведение смотрит ВНУТРЬ тела.
						# Проверка же считала его наружным: «сосед ушёл туда,
						# куда смотрит грань, — значит щель». С внутренней
						# нормалью это правило меняет знак на обратный, и все
						# годы вогнутые рёбра числились выпуклыми, а выпуклые
						# вогнутыми.
						#
						# Разворачиваем один раз здесь — тогда и знак рёбер, и
						# нависание считаются по одному честному наружу.
						n = -n.normalized()
						tri_up.append(n.y)
						var mid: Vector3 = (cpos[tri[0]] + cpos[tri[1]]
							+ cpos[tri[2]]) / 3.0
						# НА ШВЕ ЛИ ЭТОТ ТРЕУГОЛЬНИК. Без этого не отличить
						# шипы, которые делает шов, от шипов, которые делает
						# край мазка, — а лечатся они разным.
						var on_seam: float = 0.0
						for v in range(3):
							on_seam = maxf(on_seam,
								maxf(grid.seam[ca[tri[v]]],
									grid.seam[cb[tri[v]]]))
						for pair in [[0, 1], [1, 2], [2, 0]]:
							var a: int = mini(ca[tri[pair[0]]], cb[tri[pair[0]]])
							var b: int = maxi(ca[tri[pair[0]]], cb[tri[pair[0]]])
							var c2: int = mini(ca[tri[pair[1]]], cb[tri[pair[1]]])
							var d: int = maxi(ca[tri[pair[1]]], cb[tri[pair[1]]])
							var key := "%d.%d|%d.%d" % [mini(a, c2), mini(b, d),
								maxi(a, c2), maxi(b, d)]
							if faces.has(key):
								faces[key].append({"n": n, "c": mid, "s": on_seam, "t": tid})
							else:
								faces[key] = [{"n": n, "c": mid, "s": on_seam, "t": tid}]
	var out := {"edges": 0, "flat": 0, "cave_worst": 0.0, "ridge_worst": 0.0,
		"cave_sharp": 0, "ridge_sharp": 0, "cave_bend": 0, "ridge_bend": 0,
		"sharp": 0, "sharp_seam": 0, "spike": 0, "spike_seam": 0,
		"over_edges": 0, "over_sharp": 0, "over_worst": 0.0,
		"up_edges": 0, "up_sharp": 0}
	# СЛИПАНИЕ ПЛОСКИХ ТРЕУГОЛЬНИКОВ В ПЛИТЫ. Каждый сам себе плита, гладкое
	# ребро их сливает. Обычный поиск с объединением.
	var boss := PackedInt32Array()
	boss.resize(tri_area.size())
	for i in range(boss.size()):
		boss[i] = i
	for key in faces:
		var list: Array = faces[key]
		if list.size() != 2:
			continue
		var n0: Vector3 = list[0]["n"]
		var n1: Vector3 = list[1]["n"]
		var bend: float = rad_to_deg(n0.angle_to(n1))
		out["edges"] = int(out["edges"]) + 1
		# ГЛАДКИЙ КОМ И ГРАНЁНАЯ ГЛЫБА РАЗЛИЧАЮТСЯ НЕ ТОЛЬКО ШИПАМИ. У кома все
		# рёбра гнутся понемногу и одинаково; у гранёной глыбы середина грани
		# ПЛОСКАЯ (ребро круче 5° там взяться неоткуда), а весь излом собран в
		# считаных рёбрах между гранями. Поэтому меряем оба конца: сколько
		# рёбер плоских и сколько заломлено круче 20°.
		if bend < 5.0:
			out["flat"] = int(out["flat"]) + 1
			_plate_join(boss, int(list[0]["t"]), int(list[1]["t"]))
		# НАВИСАЮЩИЙ КРАЙ — ПОРОЗНЬ. Кадр пользователя: «слишком заострённый и
		# пильчатый край нависающего над землёй камня». Общее число резких рёбер
		# об этом молчит: их и так процент с небольшим, а весь вопрос в том, где
		# они сидят. Нависанием считаем грань, смотрящую вниз.
		var lean: float = (tri_up[int(list[0]["t"])] + tri_up[int(list[1]["t"])]) * 0.5
		if lean < -0.15:
			out["over_edges"] = int(out["over_edges"]) + 1
			if bend > 45.0:
				out["over_sharp"] = int(out["over_sharp"]) + 1
			out["over_worst"] = maxf(float(out["over_worst"]), bend)
		elif lean > 0.15:
			out["up_edges"] = int(out["up_edges"]) + 1
			if bend > 45.0:
				out["up_sharp"] = int(out["up_sharp"]) + 1
		# Резкие рёбра порознь: сколько их сидит НА ШВЕ между глыбами, а сколько
		# в другом месте. Шов и край мазка лечатся разным, и валить их в одну
		# кучу — значит крутить не тот винт.
		if bend > 45.0:
			var seamy: bool = maxf(float(list[0]["s"]), float(list[1]["s"])) > 0.4
			out["sharp"] = int(out["sharp"]) + 1
			if seamy:
				out["sharp_seam"] = int(out["sharp_seam"]) + 1
			if bend > 90.0:
				out["spike"] = int(out["spike"]) + 1
				if seamy:
					out["spike_seam"] = int(out["spike_seam"]) + 1
		if (Vector3(list[1]["c"]) - Vector3(list[0]["c"])).dot(n0) > 0.0:
			out["cave_worst"] = maxf(float(out["cave_worst"]), bend)
			if bend > 20.0:
				out["cave_bend"] = int(out["cave_bend"]) + 1
			if bend > 45.0:
				out["cave_sharp"] = int(out["cave_sharp"]) + 1
		else:
			out["ridge_worst"] = maxf(float(out["ridge_worst"]), bend)
			if bend > 20.0:
				out["ridge_bend"] = int(out["ridge_bend"]) + 1
			if bend > 45.0:
				out["ridge_sharp"] = int(out["ridge_sharp"]) + 1
	# ПЛИТЫ. Складываем площадь по хозяину и смотрим на самые крупные: «ромб на
	# камне» — это одна плоская плита в несколько метров, а не резкое ребро.
	var plate: Dictionary = {}
	var whole := 0.0
	for t in range(boss.size()):
		var r: int = _plate_boss(boss, t)
		plate[r] = float(plate.get(r, 0.0)) + tri_area[t]
		whole += tri_area[t]
	var sizes := PackedFloat32Array()
	for r in plate:
		sizes.append(float(plate[r]))
	sizes.sort()
	sizes.reverse()
	var big_share := 0.0
	for s in sizes:
		if s < 1.0:
			break
		big_share += s
	out["plates"] = sizes.size()
	out["plate_top"] = 0.0 if sizes.is_empty() else sizes[0]
	out["plate_big"] = big_share / maxf(whole, 0.0001)
	out["skin"] = whole
	return out


# Поиск с объединением: у каждой плиты один хозяин.
func _plate_boss(boss: PackedInt32Array, t: int) -> int:
	var r: int = t
	while boss[r] != r:
		r = boss[r]
	while boss[t] != r:
		var up: int = boss[t]
		boss[t] = r
		t = up
	return r


func _plate_join(boss: PackedInt32Array, a: int, b: int) -> void:
	var ra: int = _plate_boss(boss, a)
	var rb: int = _plate_boss(boss, b)
	if ra != rb:
		boss[rb] = ra


# =============================================================================
#  СТЕНД КАМНЯ  (`--rockbench`)
# =============================================================================
#
#  Ставит настоящий массив и меряет его облик — и только. Без растений, без
#  остальной самопроверки: та идёт четыре минуты, а облик камня приходится
#  крутить десятками прогонов подряд, меняя по одному числу.
#
#  Числа берутся С КЛЮЧА, чтобы не править файл ради каждой пробы:
#    --facet=  сила шума огранки (доли камня)
#    --bed=    тяга к плоскостям ПЛАСТОВ
#    --side=   тяга к плоскостям ПОПЕРЕЧНЫХ семейств
#    --deep=   глубина шва между глыбами
#    --wide=   полуширина шва, м
#  В игре все они те, что записаны в `SpaceGrid`; ключ действует только здесь.
# НА СКОЛЬКО ОТДЕЛЬНЫХ ТЕЛ РАСПАЛСЯ МАССИВ.
#
# Это и есть та самая мерка, ради которой всё затевалось: «чтобы в массивах
# читались целые крупные камни». Все прочие числа — про качество поверхности, а
# это про то, разделилась ли порода вообще.
#
# Считаем по-честному: ходим по ячейкам породы через шестерых соседей и смотрим,
# сколько вышло не связанных между собой кусков. Прорезала трещина насквозь —
# кусков стало больше; осталась щелью — кусок один.
#
# Печатаем и РАЗМЕРЫ: три десятка одинаковых камешков — это не то, о чём
# просили. Просили крупные и очень крупные, то есть размах.
func _bodies_report(at: Vector3, reach: float) -> void:
	var mine: Dictionary = {}
	for c in grid.seeds_near(at, reach):
		var j := int(c)
		if grid.stone_of(j) > 0.02 and grid.fill_of(j) > 0.5:
			mine[j] = true
	var seen: Dictionary = {}
	var sizes: Array = []
	for start in mine:
		if seen.has(start):
			continue
		var queue: Array = [start]
		seen[start] = true
		var size := 0
		while not queue.is_empty():
			var j: int = queue.pop_back()
			size += 1
			for s in grid.neighbors_of(j):
				var n := int(s)
				if mine.has(n) and not seen.has(n):
					seen[n] = true
					queue.append(n)
		sizes.append(size)
	sizes.sort()
	sizes.reverse()
	var big: Array = []
	for i in range(mini(5, sizes.size())):
		big.append(sizes[i])
	print("Тел в породе: ", sizes.size(), ", ячеек в них по убыванию ", big,
		" — одно тело значит, что массив не раскололся вовсе")


func _rock_bench(args: PackedStringArray) -> void:
	grid.facet_amp = _arg_num(args, "--facet", grid.facet_amp)
	grid.bed_pull = _arg_num(args, "--bed", grid.bed_pull)
	grid.side_pull = _arg_num(args, "--side", grid.side_pull)
	grid.crack_deep = _arg_num(args, "--deep", grid.crack_deep)
	grid.crack_floor = _arg_num(args, "--floor", grid.crack_floor)
	grid.crack_wall = _arg_num(args, "--wall", grid.crack_wall)
	grid.joint_span = _arg_num(args, "--span", grid.joint_span)
	# Семейства заведены при постройке мира, до того как стенд прочёл ключи, —
	# значит, при смене шага их надо завести заново, иначе ключ ничего не сделает.
	grid._build_joints(world_seed)
	grid.crack_thru = _arg_num(args, "--thru", grid.crack_thru)
	grid.seam_deep = _arg_num(args, "--seam", grid.seam_deep)
	grid.stroke_reach = _arg_num(args, "--skirt", grid.stroke_reach)
	stroke_gain = _arg_num(args, "--gain", stroke_gain)
	grid.use_blocks = not "--noblock" in args
	grid.block_round = _arg_num(args, "--round", grid.block_round)
	grid.block_faces = int(_arg_num(args, "--faces", float(grid.block_faces)))
	grid.block_tall = _arg_num(args, "--tall", grid.block_tall)
	print("Стенд камня: огранка ", grid.facet_amp, ", тяга пластов ",
		grid.bed_pull, ", тяга поперечных ", grid.side_pull, ", шов трещин ",
		grid.crack_deep, ", дно ", grid.crack_floor, " м, стенка ",
		grid.crack_wall, " м, шов между глыбами ",
		grid.seam_deep, ", вылет мазка ", grid.stroke_reach)
	_stroke_spread_report()
	# МАССИВ БЫВАЕТ КРУПНЕЕ ПРОБНОГО. У пробного 6.5 м, а глыбы 3–3.6 м: по оси
	# их умещается ДВЕ, и всему, что работает на стыках глыб, негде себя
	# показать. Ключ `--big` кладёт массив вдвое шире — такой игрок и построит,
	# если захочет скалу, а не валун.
	var reach: float = 4.5
	if "--big" in args:
		reach = 7.5
		_seed_massif(_test_spot(), 3, 5)
	else:
		_seed_structures()
	_flush_chunks()
	_stone_surface_check(_cliff_focus, reach)
	_rock_cavity_report(reach)


# Массив из колонн: `wide`×`wide` подошв, каждая на `levels` уровней вверх.
# Лепим ровно так, как это делал бы игрок, — той же кистью и теми же мазками.
# =============================================================================
#  СТАРТОВЫЕ СЦЕНЫ
# =============================================================================
#
#  Мир строится всегда одинаково — голое поле, — и до сих пор игрок начинал с
#  чистого листа. Сцена это то, что стоит на поле К НАЧАЛУ ИГРЫ: не другой мир,
#  а другая обстановка в том же мире.
#
#  Заводится сцена одной строкой в `SCENES` и одной веткой в `_seed_scene`.
#  Порядок в списке — это и порядок в игре: первая идёт по умолчанию.
#
#  СТЕНДЫ СЦЕНУ НЕ СТАВЯТ. Все они (`--selftest`, `--rockbench` и прочие) идут
#  своими ветками и получают голое поле, как и раньше: иначе всякое число,
#  замеренное за полгода, пришлось бы перезамерять из-за скал, которых там
#  никогда не было.
const SCENES := [
	{"id": "rocks", "name": "Поле со скалами"},
	{"id": "bare", "name": "Чистое поле"},
]

var scene_id: String = String(SCENES[0]["id"])


# Что стоит на поле к началу игры. Зовётся ТОЛЬКО из игровой ветки запуска.
func _seed_scene() -> void:
	if scene_id == "bare":
		print("Сцена: чистое поле")
		return
	var started := Time.get_ticks_msec()
	# МАЗКИ ОБСТАНОВКИ ИДУТ ПАЧКОЙ: последствия считаются один раз в конце.
	# Между ними на мир никто не смотрит, а ложатся они друг на друга десятками.
	grid.begin_batch()
	if scene_id == "rocks":
		_scene_rocks()
	# ШИПЫ СНИМАЕМ ДО ТОГО, КАК СЧИТАТЬ ПОСЛЕДСТВИЯ: одиночное семя над уровнем
	# даёт не форму, а тонкий клин — см. `solo_spikes`. Её кадр 02.09.2026.
	var spikes: int = grid.solo_spikes(true)
	grid.end_batch()
	var dabbed := Time.get_ticks_msec() - started
	var flushed := Time.get_ticks_msec()
	_flush_chunks()
	flushed = Time.get_ticks_msec() - flushed
	# Считаем ячейки с породой: ноль значил бы, что мазки легли мимо земли, а по
	# кадру это не отличить от «скалы просто мелкие».
	var stony := 0
	# ВЫСОТА — то, ради чего скалы и подняты: лозе нужна отвесная стена. Меряем
	# от земли под скалой, а не от нуля мира: остров и сам неровный, и высота
	# «над уровнем моря» ничего не сказала бы про то, есть ли куда лезть.
	var top: float = -1000.0
	var foot: float = 1000.0
	var steep := 0
	for c in solid:
		if grid.stone_of(c) <= 0.5:
			continue
		stony += 1
		var y: float = grid.seeds[c].y
		top = maxf(top, y)
		foot = minf(foot, y)
		if grid.steepness_of(c) > 0.75:
			steep += 1
	if stony == 0:
		print("Сцена: ", scene_id, " — породы не встало вовсе")
		return
	print("Сцена: снято одиночных семян (тонких клиньев) — ", spikes,
		", осталось ", grid.solo_spikes(false), " — норма ноль")
	print("Сцена: ", scene_id, ", ячеек с породой — ", stony, ", высота скал ",
		snappedf(top - foot, 0.1), " м, отвесных мест ",
		snappedf(100.0 * float(steep) / float(stony), 0.1),
		"% — по ним и лазает лоза; поставлена за ",
		Time.get_ticks_msec() - started, " мс, из них мазки ", dabbed,
		" мс и пересборка мешей ", flushed, " мс")


# =============================================================================
#  СТЕНД ОСТРОВА  (`--scenebench`)
# =============================================================================
#
#  Кнопка «новый остров» перечитывает сцену целиком: мир строится заново, потом
#  на нём ставится обстановка. Её жалоба 2026-09-01 — «генерируется очень
#  долго», и без разбивки по частям чинить тут нечего: непонятно, что дольше —
#  сами семена, достройка мешей или расстановка скал.
#
#  Стенд строит НЕСКОЛЬКО островов подряд на разных зёрнах и печатает по
#  каждому и время, и облик. Разные зёрна нужны не для красоты: она просила
#  РАЗНООБРАЗИЯ, а разнообразие — это разброс между островами, и одним прогоном
#  его не увидеть, как и у лозы.
func _scene_bench(args: PackedStringArray) -> void:
	var many: int = int(_arg_num(args, "--islands", 3.0))
	var seed0: int = int(_arg_num(args, "--seed", float(WORLD_SEED + 1)))
	scene_id = "rocks"
	var total := 0
	for n in range(many):
		if n > 0:
			world_seed = seed0 + n * 7919
			for ch in chunk_nodes.keys():
				var gone: Node = chunk_nodes[ch]
				remove_child(gone)
				gone.queue_free()
			chunk_nodes.clear()
			chunk_list.clear()
			_dirty_chunks.clear()
			_build_world()
			await _fill_world()
		var t0 := Time.get_ticks_msec()
		_seed_scene()
		total += Time.get_ticks_msec() - t0
		_relief_report()
		# ОБЛИК НАСТОЯЩИХ СКАЛ, а не пробной глыбы. Стенд камня лепит ком на
		# ровном месте, и нависания у него ровно два ребра — а её кадр с
		# пильчатым краем снят как раз с нависающей скалы. Здесь скалы те же,
		# что в игре, и мерить их надо здесь.
		var high := Vector3.ZERO
		for c in solid:
			if grid.stone_of(c) > 0.5 and grid.seeds[c].y > high.y:
				high = grid.seeds[c]
		if high != Vector3.ZERO:
			_stone_surface_check(high, 5.0)
	print("Стенд острова: ", many, " островов, обстановка в среднем ",
		total / maxi(1, many), " мс — к ней прибавьте семена и достройку выше,",
		" их платит всякий «новый остров»")


# ОБЛИК САМОЙ ЗЕМЛИ, а не скал. Её слова: «пусть будут холмы (не пупырки, а
# логичные холмы), ямы и так далее». Значит, мерить надо не «неровно ли», а
# КРУПНАЯ ли неровность: пупырка от холма отличается размером, а не наличием.
#
# Меряем по видимой земле БЕЗ породы: высоту над средней и то, на скольких
# метрах она набирается. Холм — это подъём, растянутый на метры; пупырка —
# тот же подъём на одной ячейке.
#
# МЕРИМ КАРТУ ВЫСОТ ПО СТОЛБЦАМ, а не все видимые семена подряд. Семена ловят и
# исподнюю сторону острова, и стенки — от них размах в шесть метров выходит
# всегда, есть на острове холмы или нет. Столбец даёт ровно то, о чём речь:
# какая высота у земли в этом месте.
const RELIEF_STEP: float = 0.8    # шаг сетки замера, м

func _relief_report() -> void:
	var h: Dictionary = {}        # (i,j) -> высота земли
	var ys := PackedFloat32Array()
	var edge: float = ISLAND_RADIUS - 2.0
	var wide: int = int(edge / RELIEF_STEP)
	for i in range(-wide, wide + 1):
		for j in range(-wide, wide + 1):
			var x: float = float(i) * RELIEF_STEP
			var z: float = float(j) * RELIEF_STEP
			if Vector2(x, z).length() > edge:
				continue
			var at: Vector3 = _ground_at(x, z, ISLAND_BOTTOM)
			if at == Vector3.ZERO:
				continue
			# Камень не земля: холмы мерим по земле, скалы уже сосчитаны выше.
			var c: int = grid.cell_at(at)
			if c >= 0 and grid.stone_of(c) > 0.02:
				continue
			h[Vector2i(i, j)] = at.y
			ys.append(at.y)
	if ys.size() < 16:
		print("Земля: мерить нечего")
		return
	var mid := 0.0
	for y in ys:
		mid += y
	mid /= float(ys.size())
	var sorted := PackedFloat32Array(ys)
	sorted.sort()
	# ХОЛМ И ЯМА — ЭТО ПЛОЩАДЬ, А НЕ ВЫСШАЯ ТОЧКА. Одна кочка поднимет
	# наибольшее и не сделает остров разнообразнее; холм — это заметная доля
	# земли, поднятая над средней.
	var up := 0
	var down := 0
	for y in ys:
		if y > mid + 0.5:
			up += 1
		elif y < mid - 0.5:
			down += 1
	# КРУПНОСТЬ: на скольких метрах земля успевает подняться на полметра.
	# Считаем по соседним столбцам — уклон, а не разброс.
	var runs := PackedFloat32Array()
	for key in h:
		var k: Vector2i = key
		var nb := Vector2i(k.x + 1, k.y)
		if not h.has(nb):
			continue
		var dy: float = absf(float(h[nb]) - float(h[k]))
		if dy < 0.02:
			continue
		runs.append(0.5 * RELIEF_STEP / dy)
	runs.sort()
	print("Земля: столбцов ", ys.size(), ", высота от ", snappedf(sorted[0], 0.01),
		" до ", snappedf(sorted[sorted.size() - 1], 0.01), " м при средней ",
		snappedf(mid, 0.01), "; выше средней на полметра — ",
		snappedf(100.0 * float(up) / float(ys.size()), 0.1), "% земли (холмы),",
		" ниже — ", snappedf(100.0 * float(down) / float(ys.size()), 0.1),
		"% (ямы); на полметра подъёма приходится ",
		snappedf(0.0 if runs.is_empty() else runs[runs.size() / 2], 0.01),
		" м вширь — у холма это метры, у пупырки доли метра")


# ПОЛЕ СО СКАЛАМИ. Несколько обнажений разной величины, разнесённых по острову.
#
# ГЛЫБУ ДЕЛАЕТ ОДИН МАЗОК, А НЕ СОТНЯ. С тех пор как камень кладётся
# многогранником, одного мазка широкой кистью хватает на гранёный валун метров в
# шесть. Стенд (`_seed_massif`) лепит колоннами по три повтора на уровень —
# ему нужна заведомо крупная глыба со швами, — но для обстановки это лишние
# сотни мазков и лишние секунды на запуске.
#
# Разнос по острову НЕ СЛУЧАЙНЫЙ ПОЛНОСТЬЮ: скалы ставятся по кругу с разбросом,
# иначе они сходятся в кучу или лезут за край. Середина острова оставлена
# свободной — игроку надо где-то начать.
const SCENE_ROCKS: int = 4        # сколько обнажений
const SCENE_NEAR: float = 4.5     # ближе этого к середине не ставим, м
const SCENE_FAR: float = 9.5      # и дальше этого тоже, м
# Насколько высоки обнажения, в уровнях подъёма (уровень — 0.6 ячейки, то есть
# 40 см). Разброс нужен: скалы одной высоты читаются забором.
const SCENE_LOW: int = 2
const SCENE_HIGH: int = 4
# КЛАССИЧЕСКАЯ ПОСТАНОВКА ОСТАЁТСЯ НА ПРЕЖНИХ ЧИСЛАХ, слово в слово: на ней
# стоят все воспроизводимые кадры и записанные числа. Ускорение выше — только
# для новых островов.
const SCENE_RISE_OLD: float = 0.9
const SCENE_LOW_OLD: int = 3
const SCENE_HIGH_OLD: int = 6
# На сколько ячеек поднимается каждый уровень.
#
# БЫЛО 0.9 (60 см), СТАЛО 2.4 (1.6 м) — 2026-09-01, её жалоба «новый остров
# генерируется очень долго». Кисть сцены смотрит на 3.27 м, а шаг был 0.6 м: на
# один свой поперечник ложилось ОДИННАДЦАТЬ мазков подряд. Столб набирался
# честно, но десятикратно поверх самого себя, и вся цена острова уходила туда —
# замер показал, что мазки это 95% времени обстановки.
#
# Больше 1.8 м шагать нельзя: мазки дальше `LUMP_MERGE` лепят РАЗНЫЕ глыбы, и
# столб распался бы на висящие друг над другом камни. 1.6 м — под этим пределом.
const SCENE_RISE: float = 2.4
# Во сколько раз мазок сцены сильнее обычного: ей нужен готовый камень сразу.
const SCENE_FORCE: float = 9.0

# ЗАПАС МАЗКОВ НА ОСТРОВ — ЯВНЫЙ, А НЕ СЛУЧАЙНЫЙ (2026-09-01).
#
# Прежде цену обстановки держала географическая случайность: гряда упиралась в
# край макушки и обрывалась на полпути. Стоило починить поиск земли — и гряды
# пошли во всю длину, а остров стал ставиться семь секунд вместо полутора.
# Замерено: один мазок сцены стоит около 20 мс, и всё время обстановки — это
# он, помноженный на своё число.
#
# Поэтому число мазков ограничено прямо. Разнообразие от этого не страдает: что
# именно поставить в этот запас — по-прежнему решает случай, а вот сколько
# ждать игроку, больше не решает никто.
#
# ПОДНЯТО 14 → 18 (02.09.2026, её просьба «пусть генерация острова будет более
# комплексной»). На четырнадцати мазках гнездо из трёх форм съедало весь запас,
# и второму гнезду не оставалось ничего.
#
# ЦЕНА ЗАМЕРЕНА И ОНА ПРЯМАЯ: один мазок сцены стоит около 70 мс, и обстановка
# растёт ровно на столько за каждый прибавленный. 14 мазков — 1.13 с, 18 — около
# 1.4 с, 22 — 1.6 с. Это то самое число, которым и торгуются «богаче» против
# «быстрее»; прочее в постановке острова не решает почти ничего.
const SCENE_DABS: int = 18
var _scene_dabs: int = 0

func _scene_rocks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed + 31337
	var was_brush := brush
	brush = 3
	# НА ПРЕЖНЕМ ЗЕРНЕ — ПРЕЖНЯЯ ПОСТАНОВКА, слово в слово: на ней стоят все
	# воспроизводимые кадры, и сравнение «до/после» живо, пока эта ветка цела.
	if world_seed == WORLD_SEED:
		_scene_rocks_classic(rng)
		brush = was_brush
		return
	# НОВЫЙ ОСТРОВ СТАВИТСЯ РАЗНООБРАЗНО (решение пользователя 2026-08-31:
	# «4 глыбы и масса земли — не нерушимое правило»). Формы произвольные, но
	# два правила держатся всегда:
	#   1. Скала не появляется в воздухе — всякий столб растёт от найденной
	#      земли вверх, мазок прибавляет к живому полю.
	#   2. В скалах и земле бывают ямы, арки и гроты — их выедает мазок
	#      снятия, тот же, что у руки; решётка держит проём шириной кисти.
	# СПЕРВА ЗЕМЛЯ, ПОТОМ КАМЕНЬ: скалы встают на найденную землю, и лепить её
	# после них значило бы поднимать холмы прямо сквозь скалу.
	_scene_dabs = 0
	_scene_relief(rng)
	# СКАЛЫ СТОЯТ КУЧАМИ, А НЕ ПОРОВНУ ПО КРУГУ (решение пользователя 2026-09-02
	# по её референсам). На снимках камень выходит НА ПОВЕРХНОСТЬ ГНЕЗДАМИ:
	# крупный кусок, а вокруг него мельче, и между гнёздами чистый луг. Ровная
	# раскладка по кругу — это ровно те «2-3 круглых прыщика», на которые она и
	# жаловалась: каждый сам по себе, и ни одного скопления.
	#
	# Гнёзд одно-два, в каждом две-три формы. Внутри гнезда формы стоят ближе
	# расстояния слияния плюс шаг — то есть местами срастаются в одно тело, а
	# местами оставляют щель, и это и есть обломочность.
	var nests: int = rng.randi_range(1, 2)
	var forms: int = nests * rng.randi_range(2, 3)
	var turn: float = rng.randf_range(0.0, TAU)
	var nest_at: Array = []
	for n in range(nests):
		nest_at.append(turn + TAU * float(n) / float(nests)
			+ rng.randf_range(-0.4, 0.4))
	for i in range(forms):
		if _scene_dabs >= SCENE_DABS:
			break
		# СКАЛА ВСТАЁТ НА ВОЗВЫШЕНИИ, А НЕ В ЯМЕ. Теперь, когда в земле есть
		# настоящие ямы, случайная точка запросто попадает на дно одной из них —
		# и мазки камня просто засыпают яму, не давая ни высоты, ни стены.
		# Замер поймал это на острове с 43% ям: 80 ячеек породы и НИ ОДНОГО
		# отвесного места. Пробуем три точки и берём самую высокую.
		var at := Vector3.ZERO
		var home: float = float(nest_at[i % nests])
		for _try in range(3):
			# Разброс внутри гнезда узкий: это одно обнажение, разбитое на куски,
			# а не три скалы в разных концах острова.
			var ang: float = home + rng.randf_range(-0.22, 0.22)
			var far: float = rng.randf_range(SCENE_NEAR, SCENE_FAR)
			var spot: Vector3 = _ground_at(cos(ang) * far, sin(ang) * far)
			if spot != Vector3.ZERO and (at == Vector3.ZERO or spot.y > at.y):
				at = spot
		if at == Vector3.ZERO:
			continue
		# ПЛИТА — САМАЯ ЧАСТАЯ ФОРМА: именно её не хватало на кадре. Столб
		# оставлен как обломок помельче рядом с крупным, гряда — как связка.
		var kind: float = rng.randf()
		if kind < 0.40:
			_scene_slab(rng, at)
		elif kind < 0.60:
			_scene_column(rng, at)
		elif kind < 0.85:
			_scene_ridge(rng, at, false)
		else:
			_scene_ridge(rng, at, true)
	# Ямы в земле — отдельно от скал, на свободных местах.
	for i in range(rng.randi_range(0, 2)):
		var ang: float = rng.randf_range(0.0, TAU)
		var far: float = rng.randf_range(SCENE_NEAR * 0.5, SCENE_FAR * 0.8)
		var at: Vector3 = _ground_at(cos(ang) * far, sin(ang) * far)
		if at != Vector3.ZERO:
			_carve(at + Vector3(0, CELL_SPACING, 0), rng.randf_range(1.0, 1.8))
	brush = was_brush


# ХОЛМЫ И ЯМЫ В САМОЙ ЗЕМЛЕ (её слова 2026-09-01: «поиграйся не только с
# камнями, но и с землёй; пусть будут холмы — не пупырки, а логичные холмы, —
# ямы и так далее»).
#
# ХОЛМ ОТ ПУПЫРКИ ОТЛИЧАЕТ ШИРИНА, А НЕ ВЫСОТА. Игровая кисть широка на 3.27 м,
# и сколько ею ни води, выходит бугор в кисть шириной. Поэтому холм кладётся
# ОДНИМ мазком заведомо большего радиуса — 4.5…7 м, вдвое шире самой широкой
# кисти и в половину острова. Сила при этом убавляется обратно радиусу, тем же
# правилом, что у руки (`_stroke_amount`): иначе широкий мазок упирается в
# предел правок и холм угловатеет.
#
# ЯМА — ТОТ ЖЕ МАЗОК СО ЗНАКОМ МИНУС, и она тоже обязана быть широкой: узкая
# яма в земле — это колодец, а решётка при ячейке 0.67 м держит только пологое.
const SCENE_HILLS_LOW: int = 2    # сколько неровностей кладём, от и до
const SCENE_HILLS_HIGH: int = 4
const SCENE_HILL_NEAR: float = 3.5   # полуширина холма, м
const SCENE_HILL_FAR: float = 5.5
const SCENE_HILL_FORCE: float = 24.0 # во сколько раз сильнее обычного мазка
const SCENE_HILL_UP: float = 0.70    # доля холмов; остальное — ямы

func _scene_relief(rng: RandomNumberGenerator) -> void:
	var many: int = rng.randi_range(SCENE_HILLS_LOW, SCENE_HILLS_HIGH)
	for i in range(many):
		var ang: float = rng.randf_range(0.0, TAU)
		var far: float = rng.randf_range(1.5, ISLAND_RADIUS - 5.0)
		var at: Vector3 = _ground_at(cos(ang) * far, sin(ang) * far, ISLAND_BOTTOM)
		if at == Vector3.ZERO:
			continue
		var wide: float = rng.randf_range(SCENE_HILL_NEAR, SCENE_HILL_FAR)
		# Сила обратна ширине — то же правило, что у руки.
		var mass: float = STROKE * (CELL_SPACING * 2.4) / wide * SCENE_HILL_FORCE
		# СЕРЕДИНА МАЗКА ЛЕЖИТ ВЫШЕ ЗЕМЛИ — И У ХОЛМА, И У ЯМЫ. Мазок правит поле
		# в шаре своего радиуса, а радиус тут 4…7 м: посади середину на землю —
		# и яма выйдет в полострова глубиной, а холм наполовину уйдёт внутрь.
		# Подняв середину, мы оставляем земле только НИЖНИЙ КРАЙ шара, и глубина
		# ямы получается той, на сколько он в неё вошёл.
		#
		# ХОЛМЫ ИДУТ ВНЕ ЗАПАСА НА СКАЛЫ: иначе на одном острове они съедали его
		# целиком, и остров выходил без камня вовсе (замер: 80 ячеек породы).
		var lift: float = wide * (0.45 if rng.randf() < SCENE_HILL_UP else 0.62)
		if lift < wide * 0.5:
			_stroke(at + Vector3(0, lift, 0), wide, mass, "ground", 0.0)
		else:
			_stroke(at + Vector3(0, lift, 0), wide, -mass, "", 0.0)


# Одиночное обнажение: кучка столбов, как в классической постановке.
func _scene_column(rng: RandomNumberGenerator, at: Vector3) -> void:
	var dabs: int = rng.randi_range(1, 3)
	for k in range(dabs):
		# СТОЛБЫ ОДНОГО ОБНАЖЕНИЯ ДОЛЖНЫ СЛИВАТЬСЯ. Разброс ±1.6 м разводил два
		# столба на 3.2 м — вдвое дальше расстояния слияния, — и внутри одной
		# скалы вырастал шов. Швы нужны между РАЗНЫМИ обнажениями, а не внутри
		# одного: см. кадр про пильчатый край.
		var off := Vector3(rng.randf_range(-0.8, 0.8), 0.0,
			rng.randf_range(-0.8, 0.8))
		_scene_tower(at + off, rng.randi_range(SCENE_LOW, SCENE_HIGH))


# ПЛИТА: наклонный клин, а не купол (решение пользователя 2026-09-02 по её
# референсам — «скалы не должны быть шаровидными; придавай им форму, близкую к
# референсам»).
#
# На её снимках у камня две черты, которых у нас не было ни одной: он СЛОИСТ
# (плиты стоят наклонно, параллельными плоскостями) и он ОБЛОМОЧЕН (крупный
# кусок, рядом с ним мельче). Купол не даёт ни того, ни другого: мазок кладёт
# округлое пятно, и столб из таких пятен всегда выходит пупыркой.
#
# Плиту строим двумя приёмами разом:
#   1. КАЖДЫЙ ЯРУС СДВИНУТ ВБОК (`lean`) — столб не стоит отвесно, а валится в
#      одну сторону. С одной стороны выходит нависающий склон, с другой отвес:
#      это и читается наклонной плитой, а не шаром.
#   2. ВЫСОТА УБЫВАЕТ ВДОЛЬ ХОДА — от высокого края к низкому. Ровная высота
#      даёт хребет-колбасу; убывающая — клин, у которого есть верх и подошва.
func _scene_slab(rng: RandomNumberGenerator, at: Vector3) -> void:
	var links: int = rng.randi_range(3, 4)
	var dir: float = rng.randf_range(0.0, TAU)
	var way := Vector3(cos(dir), 0.0, sin(dir))
	# Валится плита ПОПЕРЁК своего хода: тогда наклон один на всю плиту, а не
	# разный у каждого столба, и плоскости выходят параллельными.
	var lean: Vector3 = Vector3(-way.z, 0.0, way.x) \
		* (CELL_SPACING * rng.randf_range(0.25, 0.5))
	var tall: int = rng.randi_range(SCENE_LOW + 1, SCENE_HIGH)
	var head: Vector3 = at
	for k in range(links):
		var ground: Vector3 = _ground_at(head.x, head.z)
		if ground == Vector3.ZERO:
			break
		_scene_tower(ground, maxi(1, tall - k), SCENE_RISE, lean)
		head = ground + way * rng.randf_range(1.15, 1.6)


# ГРЯДА: цепочка столбов, идущая ломаной с инерцией, — крупный скальный массив
# произвольной формы. С аркой или гротом: в готовое тело бьёт мазок снятия —
# насквозь понизу выходит арка, вбок на средней высоте — грот.
func _scene_ridge(rng: RandomNumberGenerator, at: Vector3, hollow: bool) -> void:
	var links: int = rng.randi_range(2, 3)
	var dir: float = rng.randf_range(0.0, TAU)
	var head: Vector3 = at
	var spine: Array = []
	for k in range(links):
		var ground: Vector3 = _ground_at(head.x, head.z)
		if ground == Vector3.ZERO:
			break
		spine.append(ground)
		_scene_tower(ground, rng.randi_range(SCENE_LOW, SCENE_HIGH))
		dir += rng.randf_range(-0.7, 0.7)
		# ШАГ ГРЯДЫ ДЕРЖИМ ПОД РАССТОЯНИЕМ СЛИЯНИЯ (1.8 м), и это её кадр 2:
		# «слишком заострённый и пильчатый край нависающего камня».
		#
		# Замер на настоящих скалах: 79 резких рёбер из 116 сидят НА ШВАХ между
		# глыбами, а под нависанием резких вчетверо больше, чем на кровле
		# (13.6% против 5.6%). Шов между глыбами вогнут по своей природе — на
		# кровле он читается складкой, а под нависающим краем свет туда не
		# доходит вовсе, и складка становится чёрным зубцом.
		#
		# Прежний шаг 1.8…2.6 м перешагивал расстояние слияния, и гряда выходила
		# ЦЕПОЧКОЙ ОТДЕЛЬНЫХ ГЛЫБ со швом между каждой парой. Теперь она одно
		# тело, и швов в ней нет вовсе.
		head = ground + Vector3(cos(dir), 0.0, sin(dir)) * rng.randf_range(1.15, 1.7)
	if not hollow or spine.size() < 2:
		return
	var mid: Vector3 = spine[spine.size() / 2]
	if rng.randf() < 0.5:
		# АРКА: проём выедается насквозь у подножия, двумя ударами в одно
		# место, — камень над ним остаётся висеть сводом. Это не «скала в
		# воздухе»: свод держится телом гряды по обе стороны.
		var spot: Vector3 = mid + Vector3(0, CELL_SPACING * 1.2, 0)
		_carve(spot, 2.2)
		_carve(spot, 2.2)
	else:
		# ГРОТ: ниша в боку, не насквозь — один удар послабее, смещённый от
		# оси гряды.
		var side := Vector3(cos(dir + PI * 0.5), 0.0, sin(dir + PI * 0.5))
		_carve(mid + side * 1.4 + Vector3(0, CELL_SPACING * 1.6, 0), 1.5)


# Столб камня от земли вверх — только от найденной земли: скала не появляется
# в воздухе по построению.
func _scene_tower(at: Vector3, up: int, rise: float = SCENE_RISE,
		lean: Vector3 = Vector3.ZERO) -> void:
	var head: Vector3 = at
	for level in range(up + 1):
		if _scene_dabs >= SCENE_DABS:
			return
		var cell: int = grid.cell_at(head + lean
			+ Vector3(0, CELL_SPACING * rise, 0))
		if cell < 0 or not grid.in_play(cell):
			break
		head = grid.seeds[cell]
		var mass: float = _stroke_amount() * SCENE_FORCE
		_scene_dabs += 1
		_stroke(head, _brush_radius(), mass, "cliff",
			_stone_push(mass, "cliff"))


# Мазок снятия — тот же, каким копает рука. Снятие ничего не красит.
func _carve(at: Vector3, force: float) -> void:
	_stroke(at, _brush_radius(), -_stroke_amount() * SCENE_FORCE * force, "", 0.0)


# Классическая постановка: четыре обнажения по кругу. Не трогать — на ней
# стоят все записанные кадры и строка сцены в отчётах.
func _scene_rocks_classic(rng: RandomNumberGenerator) -> void:
	var turn: float = rng.randf_range(0.0, TAU)
	for i in range(SCENE_ROCKS):
		# По кругу с разбросом: доля оборота своя у каждого, плюс качание.
		var ang: float = turn + TAU * float(i) / float(SCENE_ROCKS) \
			+ rng.randf_range(-0.5, 0.5)
		var far: float = rng.randf_range(SCENE_NEAR, SCENE_FAR)
		var at: Vector3 = _ground_at(cos(ang) * far, sin(ang) * far)
		if at == Vector3.ZERO:
			continue
		var dabs: int = rng.randi_range(1, 3)
		for k in range(dabs):
			var off := Vector3(rng.randf_range(-1.6, 1.6), 0.0,
				rng.randf_range(-1.6, 1.6))
			_scene_tower(at + off, rng.randi_range(SCENE_LOW_OLD, SCENE_HIGH_OLD),
				SCENE_RISE_OLD)


# Точка на видимой земле над заданным местом. Ноль значит «там земли нет».
#
# ИЩЕМ В СТОЛБЦЕ, А НЕ ПО ВСЕМУ ОСТРОВУ (2026-09-01, её кадр «новый остров
# генерируется очень долго»).
#
# Прежде эта строка перебирала ВСЕ семена мира — их пятьдесят две тысячи, — и
# делала это на каждое звено гряды, на каждый столб и на каждую яму. Полсотни
# вызовов на остров, и каждый обходит весь мир.
#
# Сетка и так умеет искать рядом (`seeds_near` идёт по пространственной
# разбивке). Спускаемся по столбцу сверху вниз шагами в ячейку и берём первое
# же поверхностное семя — это заодно ВЕРНЕЕ прежнего: прежний брал ближайшее по
# горизонтали и мог сесть на дно ямы вместо её кромки.
#
# ИЩЕМ ВЕРХНЮЮ ЗАПОЛНЕННУЮ ЯЧЕЙКУ, А НЕ «ПОЧТИ РОВНО ПОЛОВИНУ». Прежнее условие
# «заполнение отличается от половины не больше чем на 0.08» — это узкая щёлка, и
# в столбце такого семени может не оказаться вовсе: семена разбросаны, уровень
# 0.5 проходит между ними. По всему острову оно всегда находилось, а в столбце —
# нет, и остров тогда выходил БЕЗ СКАЛ ВООБЩЕ. Верхняя заполненная ячейка есть
# в каждом столбце, где есть земля.
func _ground_at(x: float, z: float, floor_y: float = -0.8) -> Vector3:
	# `floor_y` — НИЖЕ ЭТОГО ЗЕМЛЮ НЕ БЕРЁМ, и у двух дел оно разное.
	#
	# СКАЛЫ стоят на макушке острова: floor_y = 0. Так было всегда, и это не
	# случайность — остров идёт от −3.5 до +2.5, выше нуля у него одна макушка, а
	# скала у самой кромки читается вылезшей из-под воды. Замер: сними отсечку —
	# и обстановка дорожает вчетверо (1.0 с против 4.6 с), потому что гряды
	# перестают упираться в край и растут во всю длину.
	#
	# ХОЛМЫ И ЯМЫ, наоборот, идут по ВСЕМУ острову: им скатов бояться нечего, а
	# на одной макушке они выходят кучей в середине.
	var step: float = CELL_SPACING
	var y: float = ISLAND_TOP + HEADROOM
	while y > ISLAND_BOTTOM - step:
		var best := INF
		var at := Vector3.ZERO
		for i in grid.seeds_near(Vector3(x, y, z), step * 1.2):
			if not grid.in_play(i) or grid.fill_of(i) < 0.5:
				continue
			var p: Vector3 = grid.seeds[i]
			if p.y < floor_y:
				continue
			var d: float = Vector2(p.x - x, p.z - z).length_squared()
			if d < best:
				best = d
				at = p
		if at != Vector3.ZERO:
			return at
		y -= step
	# НЕ НАШЛИ ВЫШЕ ПОРОГА — ИЩЕМ БЕЗ НЕГО. Порог это предпочтение, а не запрет:
	# скалам лучше стоять на макушке, но если холмы и ямы срезали её в этом
	# месте, лучше поставить скалу ниже, чем не поставить вовсе. Замер поймал
	# ровно это: остров с большими ямами выходил с 80 ячейками породы и без
	# единого отвесного места. Цену держит запас мазков (`SCENE_DABS`), а не
	# география.
	if floor_y > ISLAND_BOTTOM:
		return _ground_at(x, z, ISLAND_BOTTOM)
	return Vector3.ZERO


func _seed_massif(at: Vector3, wide: int, levels: int) -> void:
	var was_brush := brush
	brush = 3
	# ПОДОШВЫ РАЗНОСИМ ПО-НАСТОЯЩЕМУ. При тесном шаге все мазки сливаются в одну
	# глыбу — и правильно делают, — но тогда стенду нечего показать по швам
	# между глыбами. Здесь шаг заведомо больше расстояния слияния.
	var pitch: float = CELL_SPACING * 3.6
	for ix in range(wide):
		for iz in range(wide):
			var foot: Vector3 = at + Vector3(
				(float(ix) - float(wide - 1) * 0.5) * pitch, 0.0,
				(float(iz) - float(wide - 1) * 0.5) * pitch)
			var head: Vector3 = foot
			for level in range(levels):
				var up: int = grid.cell_at(head + Vector3(0, CELL_SPACING * 0.6, 0))
				if up < 0 or not grid.in_play(up):
					break
				head = grid.seeds[up]
				for _again in range(3):
					_stroke(head, _brush_radius(), _stroke_amount(), "cliff",
						_stone_push(_stroke_amount(), "cliff"))
	_cliff_focus = at + Vector3(0, CELL_SPACING * 1.8, 0)
	brush = was_brush


# ДОКУДА НА САМОМ ДЕЛЕ ДОТЯГИВАЕТСЯ ОДИН МАЗОК.
#
# Жалоба с кадра — «мазок выходит за свои границы» — до сих пор ничем не
# мерилась. Меряем прямо: кладём один мазок на нетронутое место и смотрим, на
# каком расстоянии от середины прибавка поля падает до сотой доли от своей
# наибольшей. Это и есть настоящий край мазка, в отличие от радиуса кисти,
# который лишь говорит, докуда кисть смотрит.
#
# ВАЖНО, ЧТО МЕРИМ ПОСЛЕ РАСТУШЁВКИ. Мазок не только кладёт массу, но и
# растушёвывает её в кольцо соседей, а кольцо лежит уже ЗА краем кисти. Мерка,
# считающая один профиль, этого не увидит.
func _stroke_spread_report() -> void:
	var at: Vector3 = _test_spot()
	var was_brush := brush
	brush = 3
	var r: float = _brush_radius()
	var near: Array = grid.seeds_near(at, r * 2.2)
	var before: Dictionary = {}
	for c in near:
		before[c] = grid.fill_of(c)
	_dab(at, _stroke_amount(), "ground")
	var top := 0.0
	for c in near:
		top = maxf(top, absf(grid.fill_of(c) - float(before[c])))
	var far := 0.0
	for c in near:
		if absf(grid.fill_of(c) - float(before[c])) > top * 0.01:
			far = maxf(far, grid.seeds[c].distance_to(at))
	_undo()
	_flush_chunks()
	print("Вылет мазка: кисть смотрит на ", snappedf(r, 0.01),
		" м, а масса доходит до ", snappedf(far, 0.01), " м — это ",
		snappedf(far / maxf(r, 0.01), 0.01),
		" радиуса; наибольшая прибавка поля ", snappedf(top, 0.01))

	# И ОТДЕЛЬНО — ДОКУДА ДОХОДИТ КРАСКА КАМНЯ. Она кладётся тем же мазком, но
	# живёт своей жизнью: цвет берёт сырую долю породы, а складки, трещины и швы
	# — разглаженную по соседям, и та расходится ЗАМЕТНО ШИРЕ. Если камнем
	# мажется место, куда не наводили, спрашивать надо здесь, а не с профиля.
	var stone_far := 0.0
	var soft_far := 0.0
	_dab(at, _stroke_amount(), "cliff")
	for c in near:
		var d: float = grid.seeds[c].distance_to(at)
		if grid.stone_of(c) > 0.02:
			stone_far = maxf(stone_far, d)
		if grid.stone_soft[c] > 0.02:
			soft_far = maxf(soft_far, d)
	_undo()
	_flush_chunks()
	brush = was_brush
	print("Вылет краски камня: сырая доходит до ", snappedf(stone_far, 0.01),
		" м (", snappedf(stone_far / maxf(r, 0.01), 0.01),
		" радиуса), разглаженная — до ", snappedf(soft_far, 0.01), " м (",
		snappedf(soft_far / maxf(r, 0.01), 0.01),
		" радиуса) — по разглаженной работают складки, трещины и швы")


func _arg_num(args: PackedStringArray, name: String, fallback: float) -> float:
	for a in args:
		if a.begins_with(name + "="):
			var tail: String = a.substr(name.length() + 1)
			if tail.is_valid_float():
				return tail.to_float()
	return fallback


# То же для слова, а не числа: `--scene=rocks`. Незнакомое имя не молчит —
# иначе опечатка в ключе тихо давала бы сцену по умолчанию.
func _arg_word(args: PackedStringArray, name: String, fallback: String) -> String:
	for a in args:
		if a.begins_with(name + "="):
			var tail: String = a.substr(name.length() + 1)
			for s in SCENES:
				if String(s["id"]) == tail:
					return tail
			print("Сцены «", tail, "» нет; беру ", fallback)
			return fallback
	return fallback


# НАСКОЛЬКО ГЛУБОКИ ШВЫ — глазами той величины, которой их видит ПОКРАСКА.
#
# Форма и краска судят швы порознь, и одного без другого мало. Шейдер темнит
# стык и пускает в него зелень по «впадине», а пороги у него 0.12…0.36. Пока
# впадина на камне ниже, швов на кадре не будет, сколько бы их ни было в форме:
# они останутся серой ложбиной на сером теле.
func _rock_cavity_report(reach: float) -> void:
	var vals := PackedFloat32Array()
	var turf := PackedFloat32Array()
	for c in grid.seeds_near(_cliff_focus, reach):
		if grid.surface_gap(grid.seeds[c]) < 0.0:
			continue
		if grid.stone_of(c) > 0.5:
			vals.append(grid.cavity_of(c))
		else:
			turf.append(grid.cavity_of(c))
	if vals.is_empty():
		print("Впадина на камне: мерить нечего")
		return
	vals.sort()
	print("Впадина на камне: мест ", vals.size(), ", середина ",
		snappedf(vals[vals.size() / 2], 0.001), ", девять из десяти до ",
		snappedf(vals[int(vals.size() * 0.9)], 0.001), ", наибольшая ",
		snappedf(vals[vals.size() - 1], 0.001),
		" — покраска ждёт 0.12…0.36, ниже швов на кадре не увидеть")
	_turf_cavity_report(turf)
	_crack_depth_report(reach)


# ТА ЖЕ ВПАДИНА, НО У ПОДОШВЫ — НА ЗЕМЛЕ, А НЕ НА КАМНЕ.
#
# Кадр пользователя 2026-09-01: «слишком тёмный переход между камнем и землёй».
# Стык камня с землёй ВОГНУТ по построению, а затенение щели (`hollow`, `slot` в
# `Terrain.gdshader`) идёт по одной впадине и про породу не спрашивает вовсе —
# то есть самое глубокое затенение, до трети яркости, ложится на ТРАВУ.
#
# Ровно эти грабли уже записаны в шейдере рядом: «всё, что касается камня,
# обязано спрашивать `stone`». Здесь они повторились в другом месте.
#
# Мерка честная: спрашиваем впадину у видимых мест БЕЗ породы в округе глыбы и
# считаем, сколько из них переваливает пороги затенения. Шейдер вдобавок сыплет
# на впадину шум ±0.085, так что до порога дотягивается и то, что чуть ниже.
func _turf_cavity_report(turf: PackedFloat32Array) -> void:
	if turf.is_empty():
		print("Впадина у подошвы: мерить нечего")
		return
	turf.sort()
	var dim := 0        # переваливших порог складки (0.08)
	var dark := 0       # ... и порог щели (0.30) — самое глубокое затенение
	for v in turf:
		if v > 0.08:
			dim += 1
		if v > 0.30:
			dark += 1
	print("Впадина у подошвы (земля, не камень): мест ", turf.size(),
		", середина ", snappedf(turf[turf.size() / 2], 0.001),
		", наибольшая ", snappedf(turf[turf.size() - 1], 0.001),
		"; за порог складки (0.08) вышло ", dim, " мест (",
		snappedf(float(dim) / float(turf.size()) * 100.0, 0.1),
		"%), за порог щели (0.30) — ", dark, " (",
		snappedf(float(dark) / float(turf.size()) * 100.0, 0.1),
		"%) — щель на траве это и есть тёмная кайма у подошвы")


# ЧЕРТА ТРЕЩИНЫ ГЛАЗАМИ ЧИСЕЛ. Сама черта рисуется краской, и на кадре её видно,
# а вот в числах — только здесь. Спрашиваем две вещи.
#
# ПЕРВОЕ, ДОХОДИТ ЛИ ЧЕРТА ДО КАМНЯ ВООБЩЕ. Ноль мест под чертой значит, что она
# не появится ни при какой настройке краски, и крутить `crack_ink` бесполезно.
#
# ВТОРОЕ, НЕ СЛИШКОМ ЛИ ЕЁ МНОГО. Если под чертой окажется половина камня, это
# уже не трещины, а сетка поверх глыбы. По снимкам обнажений на трещины
# приходится малая доля площади — считаные проценты.
# НАСКОЛЬКО ГЛУБОКА ТРЕЩИНА — В САНТИМЕТРАХ, а не в долях поля.
#
# Все прежние мерки говорили о поле: глубина вычета, впадина, доля резких рёбер.
# По ним выходило, что трещины глубоки, — а на кадре камень оставался гладким.
# Сила поля и глубина ямы это РАЗНЫЕ вещи: вычет из поля превращается в
# сантиметры через наклон поля, а он у камня крутой, и та же сила даёт вмятину
# втрое меньше, чем на земле.
#
# Меряем честно и прямо: у нас есть ДВЕ поверхности — настоящая и спокойная (та
# же порода без трещин, по ней ходят растения). Спрашиваем обе в одной точке и
# смотрим, насколько разошлись ответы. Это и есть глубина ямы в метрах.
func _crack_depth_report(reach: float) -> void:
	var deep := PackedFloat32Array()
	for c in grid.seeds_near(_cliff_focus, reach):
		var j := int(c)
		if grid.stone_of(j) <= 0.5 or grid.surface_gap(grid.seeds[j]) < 0.0:
			continue
		var here: Dictionary = grid.surface_near(grid.seeds[j])
		# СПРАШИВАЕМ СЕТКУ НАПРЯМУЮ, а не через `calm_surface_near`. Та нарочно
		# отдаёт настоящую поверхность — растения ходят по ней (см. «Растения
		# летали»), — и сравнение с самой собой давало ровный ноль. Мерка молча
		# перестала мерить, и на кадре это было не видно никак.
		var calm: Dictionary = grid.surface_near(grid.seeds[j], true)
		if here.is_empty() or calm.is_empty():
			continue
		deep.append(Vector3(here["pos"]).distance_to(Vector3(calm["pos"])))
	if deep.is_empty():
		print("Глубина трещин: мерить нечего")
		return
	deep.sort()
	var sum := 0.0
	for d in deep:
		sum += d
	print("Глубина трещин: мест ", deep.size(), ", в среднем ",
		snappedf(sum / float(deep.size()) * 100.0, 0.1), " см, у девяти из десяти до ",
		snappedf(deep[int(deep.size() * 0.9)] * 100.0, 0.1), " см, наибольшая ",
		snappedf(deep[deep.size() - 1] * 100.0, 0.1),
		" см — при глыбе в 6.5 м яма мельче десяти сантиметров на кадре не видна")


# МЕСТО ДЛЯ ПРОВЕРОК — НА ЗЕМЛЕ, а не в воздухе над островом.
#
# Все проверки лепили в точке (0, 6, 0). Вершина острова — 2.5 м, то есть мазок
# ложился в пустоту метрах в трёх над землёй. Оттуда и «0 ячеек» у кисти в
# отчёте: мазок в воздухе не рождает породы, потому что до половинного уровня
# ему не хватает. И оттуда же огранка камня с верхним пределом ровно ноль:
# прибавлять породу можно только там, где она уже есть, и в воздухе от неё
# оставалась одна выемка. Проверка камня ни разу не смотрела на глыбу.
func _test_spot() -> Vector3:
	var best := INF
	var at := Vector3.ZERO
	for i in range(grid.seeds.size()):
		if not grid.in_play(i) or absf(grid.fill_of(i) - 0.5) > 0.08:
			continue
		var p: Vector3 = grid.seeds[i]
		if p.y < 0.0:
			continue
		var d: float = Vector2(p.x, p.z).length()
		if d < best:
			best = d
			at = p
	return at


# РАЗМЫВАНИЕ ГЛАЗАМИ ЧИСЕЛ. Кисть обязана делать ровно две вещи: уменьшать
# перепад между соседями и отменяться начисто. Первое меряем разбросом поля по
# округе до и после, второе — сравнением с тем, что было.
func _blur_report() -> void:
	var at: Vector3 = _test_spot()
	var was_brush := brush
	brush = 3
	# Сначала лепим уступ: ровное место размывать бессмысленно, там и так гладко.
	for _i in range(3):
		_dab(at, _stroke_amount(), "ground")
	_flush_chunks()

	var near: Array = grid.seeds_near(at, CELL_SPACING * 2.5)
	var before: Dictionary = {}
	for c in near:
		before[c] = grid.fill_of(c)
	var rough_before: float = _roughness(near)

	var t0 := Time.get_ticks_usec()
	_dab(at, _stroke_amount(), "smooth")
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


# Насколько поле ИЗЛОМАНО: выпуклость ячейки, то есть насколько она выпирает
# над тем, что предсказывают соседи ВМЕСТЕ С НАКЛОНОМ. Не разница с соседями
# напрямую — та велика и у ровного склона, а склон размывать нечего.
#
# И НЕ РАЗНИЦА СО СРЕДНИМ ПО СОСЕДЯМ, как было здесь раньше. Та мерка на ровном
# склоне сама показывала 0.126 на пустом месте — ровно тот промах, который
# кисть сглаживания и вносила. Тест мерил то же, что инструмент портил, и
# потому годами говорил «работает», пока глаз видел обратное. Мерку и
# инструмент нельзя строить на одной формуле: ошибка в ней становится
# невидимой.
func _roughness(cells: Array) -> float:
	var sum := 0.0
	var count := 0
	for c in cells:
		sum += absf(grid.bulge_at(c))
		count += 1
	return 0.0 if count == 0 else sum / float(count)


# КАМЕНЬ ГЛАЗАМИ ЧИСЕЛ. На картинке не видно, отчего глыба вышла плоской:
# мало ли положено массы, слаба ли огранка, съела ли её пологость. Меряем всё
# по отдельности — и заодно проверяем, что отмена уносит и камень тоже.
func _stone_report() -> void:
	var at: Vector3 = _test_spot()
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
		_dab(at, _stroke_amount(), "cliff")
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
	# Про ПОВЕРХНОСТЬ камня здесь не спрашиваем: три мазка на ровном месте дают
	# низкий блин, и судить по нему облик глыбы нельзя. Настоящий массив ставит
	# `_seed_structures`, и проверка поверхности идёт после него.

	for _i in range(3):
		_undo()
	_flush_chunks()
	var left_fill := 0.0
	var left_stone := 0.0
	for c in near:
		left_fill = maxf(left_fill, absf(grid.fill_of(c) - float(before_fill[c])))
		left_stone = maxf(left_stone,
			absf(float(grid.stone.get(c, 0.0)) - float(before_stone[c])))
	# ГЛЫБЫ ТОЖЕ ОБЯЗАНЫ ОТМЕНЯТЬСЯ. У каждой копится масса, простая сумма
	# положенного; отмена вычитает ту же самую и гасит глыбу в ноль. Собьётся
	# это — и на отменённом месте останется шов, режущий пустое место.
	var alive := 0
	var mass := 0.0
	for l in grid.lumps:
		mass += absf(float(l["mass"]))
		if float(l["mass"]) > 0.0:
			alive += 1
	print("Отмена камня: осталось поля ", snappedf(left_fill, 0.001),
		", каменистости ", snappedf(left_stone, 0.001), ", живых глыб ", alive,
		", массы в них ", snappedf(mass, 0.001), " — всё должно быть нулями")
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
					_stroke(head, _brush_radius(), _stroke_amount(), kind,
						_stone_push(_stroke_amount(), kind))
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
# Сажаем лиану У ПОДОШВЫ глыбы, а НЕ на ней. Посади её сразу на круче — и
# проверка ничего не проверит: лиане велено самой доходить до опоры, и весь
# вопрос в том, дойдёт ли она с ровного места.
# ВЗРОСЛАЯ ЛИАНА — отдельный, долгий прогон.
#
# На сорока пяти секундах у неё два десятка звеньев, а метлой она читается на
# сотне: короткая проверка про эту беду не скажет ничего, сколько её ни смотри.
# Метлу делает не число развилок само по себе, а их КУЧНОСТЬ и то, насколько
# ветви дальних порядков жмутся к главной плети, — потому и меряем «одна развилка
# на столько-то звеньев» и ширину заросли.
#
# МОХ ПЕРЕД ЭТИМ УБИРАЕМ. Он тут ни при чём, а тикает дороже всех: с ним прогон
# втрое дольше растёт сам и вдесятеро — по числу кочек.
# =============================================================================
#  СТЕНД ЛИАНЫ  (`--vinebench`)
# =============================================================================
#
# ЗАЧЕМ ОН НУЖЕН. У лианы разброс огромный: две лозы в одном и том же прогоне
# самопроверки дают 215 и 407 звеньев, а в иной день 438 и 1339. Это не поломка,
# а её устройство: лоза растёт одной нитью, и судьба её решается несколькими
# ранними поворотами — нашла глыбу и полезла вверх, ветвясь, или пошла мимо и
# стелется по лугу.
#
# Отсюда правило, купленное дорого: ОДНО ЧИСЛО О СКОРОСТИ РОСТА НЕ ГОВОРИТ
# НИЧЕГО. Хуже того, всякая правка роста сдвигает общий поток случайности — и
# даже мох, которого правка не касалась, выходит в самопроверке другим. Сравнив
# «до» и «после» по одному прогону, читаешь шум и принимаешь его за работу.
#
# Стенд растит лозу на одном и том же месте по нескольким посевам подряд.
# СРАВНИВАТЬ НАДО СЕРЕДИНЫ, а не лучшее и не худшее.
const BENCH_SEEDS := [20260811, 7, 1234, 99991, 424242, 31337, 8080]

func _vine_bench() -> void:
	_seed_structures()
	_flush_chunks()
	print("Стенд лианы: посевов ", BENCH_SEEDS.size(), ", по полторы минуты роста")
	var got: Array = []
	for s in BENCH_SEEDS:
		plants.clear_all()
		plants._rng.seed = int(s)
		plants._sprout_why = PackedInt32Array()
		plants._sprout_why.resize(SpacePlantsScript.WHY_NAMES.size())
		_seed_vine()
		for _i in range(600):
			plants._tick(0.15)
		var out: Dictionary = plants.vine_stats()
		got.append(int(out["links"]))
		# ОТКАЗЫ — САМОЕ ВАЖНОЕ ЗДЕСЬ. Застрявшая лоза от бодрой отличается не
		# числом звеньев, а тем, обо что она упёрлась: кончик пробует расти
		# каждую секунду и получает отказ по одной и той же причине.
		var why: PackedInt32Array = plants.sprout_why()
		var parts: Array = []
		for k in range(why.size()):
			if why[k] > 0:
				parts.append(String(SpacePlantsScript.WHY_NAMES[k]) + " "
					+ str(why[k]))
		print("  посев ", s, ": звеньев ", out["links"], ", развилок ",
			out["forks"], ", кончиков ", out["tips"], ", метёлок ",
			out["sprays"], " с ", out["flowers"], " цветками (две самые близкие в ",
			snappedf(float(out["spray_gap"]) * 100.0, 0.1), " см); вросло ",
			out["buried"], ", колено под землёй до ",
			snappedf(float(out["sunk"]) * 100.0, 0.1), " см; отказы — ",
			", ".join(parts) if not parts.is_empty() else "нет")
		# ПОКОЛЕНИЯ — разнобой в счёте ловится разбросом по посевам, а не одним
		# прогоном: первое поколение выходит то в 49 звеньев, то в два.
		var gens: Array = []
		for k in range(out["by_order"].size()):
			gens.append("%d: %d зв. в %d местах" % [k + 1,
				int(out["by_order"][k]), int(out["gen_starts"][k])])
		print("    поколения — ", ", ".join(gens),
			"; звеньев с двумя детьми своего поколения ", out["gen_twins"],
			"; дерево лежит ", out["wood_runs"], " кусками, дальний край в ",
			snappedf(float(out["wood_far"]) * 100.0, 0.1), " см от посадки")
		# ЧТО С КОНЧИКОМ У ЗАСТРЯВШЕЙ ЛОЗЫ. Разбираем только бедные: у бодрой
		# кончиков десятки, и смотреть там не на что.
		if int(out["links"]) < 40:
			for pid in plants.patches:
				var p: Dictionary = plants.patches[pid]
				if String(p["id"]) != "vine" or int(p.get("kids", 0)) != 0:
					continue
				var was: int = int(p.get("from", -1))
				var came := Vector3.ZERO
				if plants.patches.has(was):
					var went: Vector3 = Vector3(p["pos"]) \
						- Vector3(plants.patches[was]["pos"])
					if went.length_squared() > 0.000001:
						came = went.normalized()
				print("    кончик: в воздухе ", p.get("air", false),
					", перелез ", p.get("rode", false), ", свесилось ",
					p.get("hangs", 0), " из ", p.get("hang_max", 0),
					", зрелость ", snappedf(float(p["m"]), 0.01), ", опора ",
					snappedf(float(p.get("prop", 0.0)), 0.01), "; шли под ",
					snappedf(rad_to_deg(came.angle_to(Vector3(p["nrm"]))), 1.0),
					"° к нормали земли — 90° это вдоль земли, 0° прямо от неё")
	got.sort()
	print("Стенд лианы: середина ", got[got.size() / 2], ", от ", got[0],
		" до ", got[got.size() - 1])
	get_tree().quit()


# ВСТАЁТ ЛИ РОСТ НА СВОЁМ СРОКЕ (`GROW_SPAN`, решение пользователя 2026-09-02;
# сперва три минуты, в тот же день укорочено до двух).
#
# Проверить это в обычных проверках нельзя: они растят по полторы минуты, то есть
# до предела не доходят вовсе, и правило стояло бы непроверенным. Здесь лозу
# доводят ЗА предел и смотрят, прибавилось ли после него хоть одно звено.
#
# Меряем ТРИЖДЫ: сколько было на девяноста секундах, сколько стало ровно на
# пределе и сколько — минутой позже. Первые два числа обязаны различаться (иначе
# лоза встала раньше срока и предел ни при чём), вторые два — совпасть.
func _grow_limit_check() -> void:
	var was: int = int(plants.vine_stats()["links"])
	# Досчитываем до самого предела: полторы минуты уже прожиты в проверке выше.
	var left: int = int(ceil((plants.GROW_SPAN - 90.0) / plants.TICK))
	for _i in range(left):
		plants._tick(plants.TICK)
	var at_edge: int = int(plants.vine_stats()["links"])
	# И ещё минута сверх предела — за неё не должно прибавиться ничего.
	var t0 := Time.get_ticks_usec()
	for _i in range(int(60.0 / plants.TICK)):
		plants._tick(plants.TICK)
	var idle := (Time.get_ticks_usec() - t0) / 1000.0
	var after: int = int(plants.vine_stats()["links"])
	print("Предел роста (", snappedf(plants.GROW_SPAN, 0.1), " с): звеньев на",
		" полутора минутах — ", was, ", на самом пределе — ", at_edge,
		", минутой позже — ", after,
		"; последние два обязаны совпасть, а первые два — различаться")
	# ЧТО ДОРОСШИЙ САД СТОИТ КАДРУ. Ради этого предел и заводился: пока роста
	# не было конца, удар сердца обходил ВЕСЬ сад до скончания века.
	print("Доросший сад: минута тиканья на ", after, " звеньях — ",
		snappedf(idle, 0.1), " мс, то есть ", snappedf(idle / (60.0 / plants.TICK), 0.001),
		" мс на удар; в живых осталось ", plants.live_count(), " растений")



func _vine_grown_check() -> void:
	# УБИРАЕМ ВСЁ, ЧТО НЕ ЛИАНА, а не один только мох: с появлением третьего вида
	# «не мох» перестало значить «лиана». Оставь его расти полторы минуты рядом —
	# и он тикал бы наравне с лозой, а числа ниже мерили бы заодно и его.
	for pid in plants.patches.keys():
		if String(plants.patches[pid]["id"]) != "vine":
			plants.remove_at(pid)
	# Срок вдвое короче прежнего: растения ускорены вдвое, и сад выходит тот же —
	# см. про это у проверки мха выше.
	for _i in range(600):
		plants._tick(0.15)
	var big: Dictionary = plants.vine_stats()
	var links: float = maxf(1.0, float(big["links"]))
	print("Лиана взрослая (полторы минуты): звеньев — ", big["links"],
		", развилок — ", big["forks"], ", то есть одна на ",
		snappedf(links / maxf(1.0, float(big["forks"])), 0.1), " звеньев")
	print("Лиана взрослая: толщина от ",
		snappedf(float(big["thin"]) * 200.0, 0.1), " до ",
		snappedf(float(big["fat"]) * 200.0, 0.1), " см в поперечнике — это в ",
		snappedf(float(big["fat"]) / maxf(float(big["thin"]), 0.0001), 0.1),
		" раза; глубже всего колено ушло под землю на ",
		snappedf(float(big["sunk"]) * 100.0, 0.1),
		" см — меньше нуля значит, что не ушло нигде; в самом тесном месте ",
		big["knot"], " звеньев в шаре 30 см; самый крутой излом ",
		snappedf(float(big["sharp"]), 0.1), "°; самая длинная плеть пряма на ",
		snappedf(float(big["straight"]) * 100.0, 0.1),
		"% — около нуля значило бы клубок")
	# МЕТЛА — И НЕ КЛУБОК, И НЕ МОТОК. Клубок ловится теснотой звеньев, метла —
	# теснотой НАЧАЛ ПОБЕГОВ: пять плетей из одного места дальше идут врозь и
	# просторно, и по числу звеньев в шаре их не видно вовсе.
	print("Лиана взрослая: метла — начал побегов ", big["starts"],
		", в самом густом месте ", big["broom"], " в шаре 30 см",
		" — на кадре метла читается с четырёх-пяти")
	# МОТОК — это не клубок. Клубок ловится теснотой (много звеньев в одном шаре),
	# а моток — побег, который поворачивает всё время в одну сторону; звенья при
	# этом могут лежать просторно. Пользователь показала такой на кадре, когда все
	# прежние числа молчали.
	print("Лиана взрослая: закрутка — двенадцать звеньев подряд дают до ",
		snappedf(float(big["coil"]), 1.0), "°, участков круче трёхсот — ",
		big["coiled"], " (360° — это виток спирали)")
	print("Лиана взрослая: кончиков — ", big["tips"], ", разброс между ними ",
		snappedf(float(big["tips_wide"]) * 100.0, 0.1), " см при ширине заросли ",
		snappedf(float(big["wide"]) * 100.0, 0.1),
		" см — сходятся в одну точку, если первое много меньше второго")
	print("Лиана взрослая: перелезло через старшие ветви ", big["rode"],
		" звеньев — ноль значил бы, что молодые побеги по-прежнему ныряют сквозь")
	print("Лиана взрослая: висящих в воздухе звеньев — ", big["air"], " из ",
		big["links"], " (", snappedf(float(big["air"]) / links * 100.0, 0.1),
		"%) — вольные ветви, отлипшие от камня")
	# ЛИСТЬЯ. Первое число говорит, облиствена ли лиана вообще; второе — гуще ли
	# к кончику (у молодого прироста их два-три, у старой древесины изредка один,
	# значит в среднем на звено должно выйти заметно меньше двух); третье —
	# сторож: лист отходит от опоры вслепую, и на вогнутом месте он может уйти
	# кончиком в камень.
	print("Лиана взрослая: листьев — ", big["leaves"], " на ", big["links"],
		" звеньев, то есть ", snappedf(float(big["leaves"]) / links, 0.01),
		" на звено; ушло в породу глубже половины листа ", big["leaf_in"],
		" — норма ноль; лёгкие касания камня не считаются и не беда")
	# ЦВЕТЕНИЕ. Ноль метёлок значил бы, что цветоносы не заводятся вовсе — а
	# завестись им положено с третьего поколения ветвей, и на взрослой лозе таких
	# ветвей сотни. Свес меньше длины — это норма: метёлка сперва отходит наружу.
	# ВРОСШИЕ В ЗЕМЛЮ ЗВЕНЬЯ — сторож по кадру пользователя «лоза потерялась и
	# вросла в текстуру». Норма ноль: звену положено лежать НА земле, а висящему
	# — над ней. Не ноль — значит, либо побег ушёл под поверхность, либо игрок
	# засыпал висящую ветвь и та не заметила.
	print("Лиана взрослая: вросло в землю звеньев — ", big["buried"],
		" из ", big["links"], " — норма ноль")
	print("Лиана взрослая: метёлок — ", big["sprays"], ", цветков на них ",
		big["flowers"], ", самая длинная ", big["spray_len"],
		" звеньев и свесилась на ",
		snappedf(float(big["spray_drop"]) * 100.0, 0.1),
		" см; ушло цветком в породу глубже половины ", big["flower_in"],
		" — норма ноль; касание камня не в счёт")
	# ЧЕМ ЛИСТВА ОБХОДИТСЯ. Дощечка листа — восемь треугольников, а листьев у
	# взрослой лианы больше, чем звеньев: это самая дорогая её часть, и держать
	# её цену на виду стоит с самого начала.
	plants.flush_now()          # меши собираются с запасом на кадр — здесь ждать нечего
	var tris := 0
	for cell in plants.cell_nodes:
		var mesh: ArrayMesh = plants.cell_nodes[cell].mesh
		for si in range(mesh.get_surface_count()):
			var indexed: int = mesh.surface_get_array_index_len(si)
			tris += (indexed if indexed > 0 else mesh.surface_get_array_len(si)) / 3
	print("Лиана взрослая: треугольников — ", tris, ", то есть ",
		snappedf(float(tris) / links, 0.1), " на звено")
	print("Лиана взрослая: свисающих плетей — ", big["plaits"], ", звеньев в них ",
		big["hangs"], ", самая длинная ", big["plait"],
		" звеньев и свесилась на ", snappedf(float(big["drop"]) * 100.0, 0.1),
		" см")
	# ПОЧЕМУ ПЛЕТЕЙ СТОЛЬКО. Ноль бывает по двум разным причинам: кончик до
	# верхней кромки не дошёл — тогда и попыток ноль, — или дошёл, а падать под
	# кромкой некуда: рядом с округлой глыбой отвес идёт прямо в её же бок.
	print("Лиана: попыток перевалить через кромку ", big["hang_try"],
		", шаг за кромку вышел в воздух у ", big["hang_edge"],
		", и падать было куда у ", big["hang_win"],
		"; места под кромкой хватило на столько звеньев (от нуля и выше): ",
		big["hang_deep"])
	# И ТОТ ЖЕ ВОПРОС — К САМОЙ ЗЕМЛЕ, а не к лиане: есть ли в мире вообще где
	# свеситься. Иначе «плетей ноль» не разобрать: то ли лиана не дошла до кромки,
	# то ли кромок нет.
	var spots: Dictionary = plants.hang_spots("vine")
	_hang_at = spots["at"]
	print("Кромки в мире: видимых мест ", spots["seen"],
		", шаг вниз по склону вышел в воздух у ", spots["off"],
		", и места хватило на столько звеньев (от нуля и выше): ", spots["room"])
	# ЗАПРЕТ ВИСЕТЬ ЗА КРАЕМ САДА мерим отдельно: в кадре с глыбой он не
	# срабатывает вовсе, а у кромки острова решает всё — и «плетей столько-то»
	# об этом не скажет ничего.
	print("Кромки в мире: отсеяно как «за краем сада» — ", spots["void"],
		" мест: под ними пусто на всю высоту мира, и плеть ушла бы под поверхность")
	print("Лиана взрослая: дальний порядок ветви — ", big["order"], ", вширь ",
		snappedf(float(big["wide"]) * 100.0, 0.1), " см, подъём ",
		snappedf(float(big["tall"]) * 100.0, 0.1), " см, на камне ",
		snappedf(float(big["rock"]) / links * 100.0, 0.1), "% звеньев")
	# ПОТОЛОК ПОКОЛЕНИЙ (`GEN_MAX`, её решение 2026-09-02: «максимальное количество
	# поколений побегов — 7»). Одного «дальнего порядка» тут мало: он скажет, что
	# восьмого поколения нет, но не скажет, УПЁРЛАСЬ ли лоза в предел или просто
	# не доросла до него. Печатаем ещё и сколько звеньев стоит в последнем: их
	# должно быть много — это плети, которым ветвиться запрещено, а расти в длину
	# нет.
	var gen_count: int = int(big["by_order"].size())
	var gen_last: int = int(big["by_order"][gen_count - 1]) if gen_count > 0 else 0
	print("Лиана взрослая: поколений — ", gen_count, " при пределе ",
		plants.GEN_MAX, "; в последнем ", gen_last, " звеньев — если их сотни,",
		" лоза в предел упёрлась, если единицы, она до него просто не доросла")
	# КОНЦЫ ВЕТОК НЕ ВЫЗРЕВАЮТ ДО КОНЦА (`_ripe_cap`, её решение 2026-09-02).
	# Мерка прямая: зрелость САМИХ КОНЧИКОВ против зрелости прочих звеньев. У
	# кончика она обязана не дойти до единицы, у середины плети — дойти.
	var tip_sum: float = 0.0
	var tip_top: float = 0.0
	var tips_n: int = 0
	var mid_n: int = 0
	var mid_full: int = 0
	for pid in plants.patches:
		var q: Dictionary = plants.patches[pid]
		if String(q["id"]) != "vine" or int(q.get("bloom", 0)) > 0:
			continue
		if int(q.get("kids", 0)) <= 0:
			tips_n += 1
			tip_sum += float(q["m"])
			tip_top = maxf(tip_top, float(q["m"]))
		else:
			mid_n += 1
			if float(q["m"]) >= 0.999:
				mid_full += 1
	print("Лиана взрослая: кончиков ", tips_n, ", зрелость у них в среднем ",
		snappedf(tip_sum / maxf(1.0, float(tips_n)), 0.01), ", у самого зрелого ",
		snappedf(tip_top, 0.01), " — до единицы не доходит ни один (потолок у",
		" голого конца ", plants.TIP_RIPE, "); а из прочих звеньев дозрело",
		" дочиста ", mid_full, " из ", mid_n)
	# ОДРЕВЕСНЕНИЕ ПО ПОКОЛЕНИЯМ — правило пользователя «дочерна деревенеют
	# только первые поколения». Печатаем звенья и одревесневшие ПОРОЗНЬ по
	# поколениям: одно общее число тут ничего не скажет, вся суть в том, где
	# волна остановилась.
	var wood_line := ""
	for k in range(big["by_order"].size()):
		var was: int = int(big["by_order"][k])
		var got: int = int(big["wood_order"][k])
		wood_line += "%s%d: %d из %d" % ["; " if k > 0 else "", k + 1, got, was]
	print("Лиана взрослая: одревеснело дочерна по поколениям — ", wood_line,
		" — деревенеть должны только первые, дальше зелёный облиственный побег")
	# А СЧИТАЮТСЯ ЛИ ПОКОЛЕНИЯ ОТ ТОЧКИ ПОСАДКИ (правило 2026-09-02). Числом
	# звеньев это не мерится: печатаем НАЧАЛА — в скольких разных местах
	# поколение заводится.
	var gen_line := ""
	for k in range(big["gen_starts"].size()):
		gen_line += "%s%d: %d" % ["; " if k > 0 else "", k + 1,
			int(big["gen_starts"][k])]
	print("Лиана взрослая: поколение начинается в стольких местах — ", gen_line,
		"; у первого их должно быть ровно столько, сколько корней (сейчас ",
		big["roots"], ") — это сами точки посадки, у прочих это число ветвей;",
		" звеньев с двумя детьми своего же поколения — ", big["gen_twins"],
		" (норма 0)")
	# И ЧТО ИЗ ЭТОГО ВИДНО НА КАДРЕ: номер поколения глазом не читается, читается
	# бурая древесина.
	print("Лиана взрослая: одревесневшее дерево лежит ", big["wood_runs"],
		" кусками — норма по куску на корень, то есть ", big["roots"],
		"; дальний его край в ", snappedf(float(big["wood_far"]) * 100.0, 0.1),
		" см от СВОЕЙ точки посадки")
	# ЗАСТРЯЛА ЛИ ХОТЬ ОДНА. Средние числа прячут беду: одна плеть в полсотни
	# звеньев и три по пять дают то же «в среднем четырнадцать».
	print("Лианы порознь: корней — ", big["roots"], ", у самой бедной ",
		big["least"], " звеньев, у самой богатой ", big["most"],
		"; попыток отростка ", big["tries"], ", из них нашли место ",
		big["wins"], " (", snappedf(float(big["wins"])
			/ maxf(1.0, float(big["tries"])) * 100.0, 0.1), "%)")


# ОЖИВЁТ ЛИ ЛИАНА, ПОТЕРЯВ КОНЧИК.
#
# Свободно растёт только кончик, а гибнет он то и дело: правка земли под ним,
# снос, обрыв цепи. Если после этого плеть не заводит нового кончика, она встаёт
# НАВСЕГДА — и на кадре это короткий обрубок, который не растёт, сколько ни жди.
# Ровно на это и жаловалась рука.
#
# Снимаем ВСЕ кончики разом: случай самый суровый, и ответ на нём однозначный.
# А ВЫРАСТЕТ ЛИ ПЛЕТЬ НА САМОМ ДЕЛЕ.
#
# Проверка кромок спрашивает ЗЕМЛЮ: есть ли в мире места, откуда плеть прошла бы.
# Это не то же самое, что «плеть выросла»: у растущей лозы к перевалу свои
# условия — побег должен идти вниз или поперёк, звено дозреть, кончик не уйти в
# сторону. Без этой проверки перевал через кромку остаётся непроверенным, сколько
# бы кромок ни насчитала предыдущая: у взрослой лианы в кадре их может не
# оказаться просто потому, что она туда не доросла.
#
# Сажаем ОДНУ лиану прямо на найденную кромку и растим минуту. Прежние снимаем:
# полторы тысячи звеньев тикают дорого, а к делу здесь не относятся. Поэтому
# проверка и идёт последней.
var _hang_at: Vector3 = Vector3.ZERO

func _vine_hang_check() -> void:
	if _hang_at.y < -1e8:
		print("Лиана у кромки: годной кромки в мире не нашлось — сажать некуда")
		return
	plants.clear_all()
	if plants.plant_at(_hang_at, "vine") < 0:
		print("Лиана у кромки: на самой кромке лиана не села — там ей не место")
		return
	for _i in range(400):
		plants._tick(0.15)
	var out: Dictionary = plants.vine_stats()
	print("Лиана у кромки (минута): звеньев — ", out["links"],
		", свисающих плетей — ", out["plaits"], ", звеньев в них ", out["hangs"],
		", самая длинная ", out["plait"], " звеньев и свесилась на ",
		snappedf(float(out["drop"]) * 100.0, 0.1),
		" см — ноль значит, что с кромки лоза предпочла ЛЕЗТЬ ВВЕРХ; сама кромка"
		+ " годна, её проверила строка выше")


func _vine_tip_check() -> void:
	var before: int = int(plants.vine_stats()["links"])
	var killed := 0
	for pid in plants.patches.keys():
		if not plants.patches.has(pid):
			continue
		var p: Dictionary = plants.patches[pid]
		if String(p["id"]) != "vine" or int(p.get("kids", 0)) != 0:
			continue
		plants.remove_at(pid)
		killed += 1
	for _i in range(200):
		plants._tick(0.15)
	var after: int = int(plants.vine_stats()["links"])
	print("Лиана без кончиков: снято ", killed, " из ", before,
		" звеньев, за полминуты отросло ", after - (before - killed),
		" — ноль значил бы, что плеть встала навсегда")


# ЧТО СТАНЕТ С ЛИАНОЙ, ЕСЛИ ПРАВИТЬ ЗЕМЛЮ ПОД НЕЙ.
#
# Проверка ровно того, на что жалуется рука: игрок поднимал холм под выросшей
# лианой, и её растягивало толстыми прямыми палками через весь склон. Причина в
# том, что при правке КАЖДОЕ ЗВЕНО пересаживается само по себе — цепочка про себя
# ничего не знает, — и соседи разъезжаются.
#
# Мерим самое длинное колено: при росте оно не может выйти за шаг отростка, а
# значит всё, что длиннее предела, и есть та самая палка.
func _vine_reshape_check() -> void:
	var at := Vector3.ZERO
	for pid in plants.patches:
		if String(plants.patches[pid]["id"]) == "vine":
			at = plants.patches[pid]["pos"]
			break
	if at == Vector3.ZERO:
		return
	var was_brush := brush
	brush = 2
	for _i in range(3):
		_dab(at, _stroke_amount(), "ground")
	_flush_chunks()
	brush = was_brush
	var after: Dictionary = plants.vine_stats()
	print("Лиана после правки земли под ней: звеньев — ", after["links"],
		", самое длинное колено ", snappedf(float(after["long"]) * 100.0, 0.1),
		" см при пределе ", snappedf(float(after["cap"]) * 100.0, 0.1),
		" см — за предел выходить нечему")


# Сколько кочек мха. Раньше сходило за это общее число растений — пока растение
# было одно.
func _moss_count() -> int:
	var n := 0
	for pid in plants.patches:
		if String(plants.patches[pid]["id"]) == "moss":
			n += 1
	return n


func _vine_count() -> int:
	var n := 0
	for pid in plants.patches:
		if String(plants.patches[pid]["id"]) == "vine":
			n += 1
	return n


func _plant_count(id: String) -> int:
	var n := 0
	for pid in plants.patches:
		if String(plants.patches[pid]["id"]) == id:
			n += 1
	return n


# ВСТРЕЧА ВИДОВ — ЧТО ВЫШЛО В ОБЫЧНОМ САДУ.
#
# Читать так: касания и рождения — разные вещи, и это нарочно. Касаний много
# всегда (лоза, идущая по ковру, касается его каждым своим звеном), рождений
# мало: на стыке заводится ОДНО пятно, а не кайма. Все нули значат «не сошлись» —
# мох сеется подальше от камня, лоза сидит у камня, и за двадцать две секунды они
# могут не встретиться вовсе. Работает ли механизм, отвечает стенд встречи ниже.
func _meet_report() -> void:
	var met: Vector3i = plants.meet_stats()
	var born: int = _plant_count("liamoss")
	var line := "Встречи видов: касаний — %d, родилось на стыках — %d," \
		% [met.x, met.y] + " сорвалось после броска — %d; лиамоха — %d" \
		% [met.z, born]
	if born > 0:
		var pods: Vector2i = plants.spore_stats("liamoss")
		line += ", метёлок на %d кочках, спорангиев %d" % [pods.x, pods.y]
	print(line)


# СТЕНД ВСТРЕЧИ: НАРОЧНО СВОДИМ ЛОЗУ С МХОМ.
#
# Зачем он есть. В обычном саду стык — дело случая, и по нулям в строке выше не
# отличить «не сошлись» от «не работает». Стенд сводит их силой: растит ковёр
# мха, сажает в его середину лозу и смотрит, что вышло на стыках.
#
# ИДЁТ ПОСЛЕДНИМ, когда все прочие замеры сняты: он сносит сад, растит свой и
# сдвигает поток случайности — после него мерить уже нечего.
func _meet_stand() -> void:
	# ПОСЕВ СЛУЧАЙНОСТИ ЗАДАЁМ, как и на стенде лианы: числа встречи надо
	# сравнивать «до» и «после» правки, а на плавающем посеве читаешь шум.
	plants._rng.seed = 20260829
	for pid in plants.patches.keys():
		plants.remove_at(pid)
	# ПЕРВЫМ ДЕЛОМ — ПОРОЗНЬ, ОТ ОДНОГО СЕМЕНИ КАЖДЫЙ. «Хаотичнее» не должно
	# незаметно обернуться «быстрее»: у лиамоха и шаг длиннее, и локоть
	# гуляет вдвое сильнее, и к чужому виду он подсаживается вплотную — а всё это
	# снимает препятствия, из-за которых ковёр мха растёт медленнее, чем мог бы.
	# Пара скоростей у обоих одна и та же, значит и пятна должны выйти
	# сопоставимыми; сильно разошлись — крутить надо `spread_rate` третьего вида.
	#
	# ЗАОДНО ТУТ ЖЕ И ЦЕНА В ТРЕУГОЛЬНИКАХ — по тому же прогону. Сравнивать её
	# можно только на РОВЕСНИКАХ: в общем саду кочки разного возраста, а метёлка
	# у молодой ещё не выросла, и «на кочку» вышло бы число ни о чём.
	var solo_moss: Vector2i = _solo_grow("moss", 300)
	var solo_lia: Vector2i = _solo_grow("liamoss", 300)
	print("Стенд встречи, порознь: от одного семени за 45 секунд мха — ",
		solo_moss.x, " кочек, лиамоха — ", solo_lia.x,
		"; числа должны быть одного порядка")
	print("Стенд встречи, порознь: треугольников на кочку у мха ",
		snappedf(float(solo_moss.y) / maxf(1.0, float(solo_moss.x)), 0.1),
		", у лиамоха ",
		snappedf(float(solo_lia.y) / maxf(1.0, float(solo_lia.x)), 0.1),
		" — метёлка стоит дороже одиночной коробочки, и это надо видеть")
	# ЧИСТИМ ЗА СОБОЙ ПЕРЕД САМОЙ ВСТРЕЧЕЙ. Грабли, замеренные тут же: после
	# прогона порознь на месте оставались две с половиной сотни кочек, и лозу в
	# них уже не воткнуть — стенд доложил «лоза НЕ ПОСАЖЕНА», а встреч ноль.
	for pid in plants.patches.keys():
		plants.remove_at(pid)
	plants.flush_now()
	var was: Vector3i = plants.meet_stats()
	var at: Vector3 = _test_spot()
	# ЛОЗУ САЖАЕМ ПЕРВОЙ, А МОХ ВОКРУГ НЕЁ, и порядок тут не мелочь: в готовый
	# ковёр лозу уже не воткнуть — запрет на тесноту не пустит (замерено, стенд
	# докладывал «лоза НЕ ПОСАЖЕНА»). Растут дальше вместе: ковёр доходит до
	# мерки зрелости примерно тогда же, когда плети выбираются с середины наружу.
	var vines: int = 1 if plants.plant_at(at, "vine") >= 0 else 0
	var seeded := 0
	for i in range(8):
		var a: float = TAU * float(i) / 8.0
		if plants.plant_at(at + Vector3(cos(a), 0.0, sin(a)) * 0.45, "moss") >= 0:
			seeded += 1
	for _i in range(460):
		plants._tick(0.15)
	var carpet: int = _plant_count("moss")
	var met: Vector3i = plants.meet_stats() - was
	print("Стенд встречи: посеяно мха ", seeded, ", ковёр дорос до ", carpet,
		" кочек, лоза ", "посажена" if vines > 0 else "НЕ ПОСАЖЕНА", " — ",
		_vine_count(), " звеньев")
	print("Стенд встречи: касаний — ", met.x, ", родилось — ", met.y,
		", сорвалось — ", met.z, " (это `apart`: на стыке заводится одно пятно,",
		" а не кайма); лиамоха ", _plant_count("liamoss"), " кочек")
	# А РАСТЁТ ЛИ ОН ДАЛЬШЕ САМ И НЕ СЪЕДАЕТ ЛИ РОДИТЕЛЕЙ. Родившееся на стыке —
	# это одно пятно; всё остальное третий вид должен нажить сам, не убавляя мха.
	var was_born: int = _plant_count("liamoss")
	var was_moss: int = _plant_count("moss")
	for _i in range(300):
		plants._tick(0.15)
	# ЦЕНА КИСТИ РОСТА НА ГУСТОМ САДЕ. Мерить её надо именно здесь: в обычной
	# самопроверке сада полторы сотни растений, и любая цена там кажется нулевой.
	# Кисть при удержании повторяется четырнадцать раз в секунду, поэтому важна
	# не сумма, а цена ОДНОГО мазка — она не должна расти вместе с садом.
	var brush_r: float = _brush_radius() * BURST_REACH
	var live: int = _plant_count("moss") + _plant_count("liamoss")
	# ДВА ЗАМЕРА, И ВТОРОЙ ВАЖНЕЕ. В самой куртине кисть честно накрывает почти
	# весь сад — там от указателя толку нет, работа упирается в число растений
	# под кистью. А вот в стороне от куртины видно, чего он стоит: обход не
	# должен зависеть от того, сколько всего насажено на острове.
	for pass_i in range(2):
		var spot: Vector3 = _ground_at(0.0, 0.0) if pass_i == 0 \
			else _ground_at(9.0, 9.0)
		if spot == Vector3.ZERO:
			continue
		var t_burst: int = Time.get_ticks_usec()
		for _i in range(50):
			plants.burst_at(spot, brush_r)
		print("Кисть роста, ", "в куртине" if pass_i == 0 else "в стороне",
			": сад ", live, " растений, просмотрено ", plants._burst_seen,
			", один мазок ",
			snappedf(float(Time.get_ticks_usec() - t_burst) / 50000.0, 0.001),
			" мс")
	print("Стенд встречи: за 45 секунд лиамоха стало ",
		_plant_count("liamoss"), " кочек (было ", was_born, "), мха ",
		_plant_count("moss"), " (было ", was_moss,
		") — мох убывать не должен вовсе")
	var pods: Vector2i = plants.spore_stats("liamoss")
	print("Стенд встречи: метёлки со спорангиями — на ", pods.x,
		" кочках лиамоха, спорангиев ", pods.y,
		"; ноль значил бы, что кисть не собирается вовсе")
	# СТЕНД ЗА СОБОЙ УБИРАЕТ. Он идёт последним, а сад после него остаётся
	# расти в каждом кадре: с полутысячей звеньев и сотнями кочек выход из игры
	# растягивался на минуты.
	for pid in plants.patches.keys():
		plants.remove_at(pid)
	plants.flush_now()


# ВЫРАСТИТЬ ОДИН ВИД НА ЧИСТОМ МЕСТЕ и вернуть, сколько его стало и во сколько
# треугольников он обошёлся. Пересобрать сад тут необходимо: рост меши не
# строит, только помечает, — а без сборки не проверить и саму геометрию.
func _solo_grow(id: String, ticks: int) -> Vector2i:
	for pid in plants.patches.keys():
		plants.remove_at(pid)
	plants.flush_now()
	if plants.plant_at(_test_spot(), id) < 0:
		return Vector2i.ZERO
	for _i in range(ticks):
		plants._tick(0.15)
	plants.flush_now()
	var tris := 0
	for cell in plants.cell_nodes:
		var mesh: ArrayMesh = plants.cell_nodes[cell].mesh
		for si in range(mesh.get_surface_count()):
			var indexed: int = mesh.surface_get_array_index_len(si)
			tris += (indexed if indexed > 0 else mesh.surface_get_array_len(si)) / 3
	return Vector2i(_plant_count(id), tris)


# ЧТО ТОРМОЗИТ ЛИАНУ. Ей записано «на ровном растёт вдвое медленнее», и вопрос
# один: отличает ли мерка ровное место от опоры. Печатаем обе — нынешнюю (по
# опоре) и прежнюю (по наклону земли), — потому что прежняя выглядела разумно и
# врала молча: наклон это та же крутизна, а крутизна на камне 0.214 против 0.186
# на земле, то есть глыбы от луга не видит вовсе.
#
# ЧИТАТЬ ТАК: у мерки должен быть РАЗМАХ. Если оба края близки, растение всюду
# растёт одинаково, как его ни зови.
func _vine_brake_check() -> void:
	var flat_slow: float = float(PlantsData.ITEMS["vine"].get("flat_slow", 1.0))
	var n := 0
	var prop_sum := 0.0
	var slow_sum := 0.0
	var old_sum := 0.0
	var prop_low := 1.0
	var prop_high := 0.0
	for pid in plants.patches:
		var p: Dictionary = plants.patches[pid]
		if String(p["id"]) != "vine":
			continue
		n += 1
		var prop: float = clampf(float(p.get("prop", 0.0)), 0.0, 1.0)
		prop_sum += prop
		prop_low = minf(prop_low, prop)
		prop_high = maxf(prop_high, prop)
		slow_sum += lerpf(flat_slow, 1.0, prop)
		old_sum += lerpf(flat_slow, 1.0,
			1.0 - clampf(Vector3(p["nrm"]).y, 0.0, 1.0))
	if n == 0:
		return
	print("Тормоз лианы: опора под звеном от ", snappedf(prop_low, 0.01), " до ",
		snappedf(prop_high, 0.01), ", в среднем ", snappedf(prop_sum / n, 0.01),
		" — отсюда рост идёт в ", snappedf(slow_sum / n, 0.01),
		" силы; прежней меркой по наклону вышло бы ", snappedf(old_sum / n, 0.01),
		" (предел замедления ", flat_slow, ")")


# ВСПЛЕСК РОСТА ОТ РУКИ — ПРИ ОСТАНОВЛЕННОМ ВРЕМЕНИ.
#
# Проверяем ровно то, ради чего он делался (решение пользователя 2026-08-28):
# мир стоит, игрок трогает землю у лианы — и она всё равно тянется, а НЕ ОДНИМ
# КАДРОМ. Требование «плавно» тут не про красоту: скачок в один кадр увидеть
# нельзя, а увиденное и есть весь смысл отклика на действие.
#
# ТРИ ЧИСЛА, И КАЖДОЕ ЛОВИТ СВОЮ БЕДУ: сколько наросло при стоящем времени без
# всякого мазка (норма ноль — иначе «стоп» не останавливает), сколько от одного
# мазка (ноль значил бы, что всплеск не работает вовсе) и за сколько разных
# кадров это набралось (единица значила бы тот самый рывок).
func _burst_check() -> void:
	var at := Vector3.ZERO
	for pid in plants.patches:
		var p: Dictionary = plants.patches[pid]
		if String(p["id"]) == "vine" and int(p.get("kids", 0)) == 0:
			at = p["pos"]
			break
	if at == Vector3.ZERO:
		return
	var was_time: float = plants.time_scale
	plants.time_scale = 0.0
	var start: int = _vine_count()
	for _i in range(60):
		plants._process(1.0 / 60.0)
	var idle: int = _vine_count() - start
	_wake_plants(at, _brush_radius())
	var seen: int = _vine_count()
	var frames := 0
	for _i in range(240):
		plants._process(1.0 / 60.0)
		var now: int = _vine_count()
		if now != seen:
			seen = now
			frames += 1
	plants.time_scale = was_time
	print("Всплеск от руки: при стоящем времени само наросло ", idle,
		" звеньев (норма ноль), от одного мазка — ", seen - start,
		" за ", frames, " разных кадров из 240 — единица значила бы рывок")


# ТОЛЧОК ПРИ ПОСАДКЕ (решение пользователя 2026-08-29). Меряем при СТОЯЩЕМ
# времени, и в этом вся сила проверки: мир не идёт, значит всё, что кочка
# набрала, пришло из подарка. Без толчка зрелость осталась бы ровно такой, какой
# её посадили, — спорить тут не о чем.
#
# ЧЕРЕЗ `_process`, А НЕ ЧЕРЕЗ `_tick`. Подарок проливается своим сердцем, по
# настоящим секундам; прямой вызов `_tick(0.15)` (каким растят сад все прочие
# проверки) подаренного не берёт ВОВСЕ — оттого их числа толчок и не сдвинул.
func _plant_gift_check() -> void:
	var was_time: float = plants.time_scale
	plants.time_scale = 0.0
	var pid: int = plants.plant_at(_test_spot(), "moss")
	if pid < 0:
		plants.time_scale = was_time
		print("Толчок при посадке: посадить не вышло — мерить нечего")
		return
	var born: float = float(plants.patches[pid]["m"])
	for _i in range(180):
		plants._process(1.0 / 60.0)
	var grown: float = born
	if plants.patches.has(pid):
		grown = float(plants.patches[pid]["m"])
	plants.time_scale = was_time
	print("Толчок при посадке: зрелость ", snappedf(born, 0.01), " → ",
		snappedf(grown, 0.01), ", ступень ", int(born * 9.0) + 1, " → ",
		int(grown * 9.0) + 1, " из девяти. Время стояло: без толчка осталась бы",
		" прежней")
	if plants.patches.has(pid):
		plants.remove_at(pid)


# =============================================================================
#  СТЕНД РОСТА КИСТЬЮ  (`--growbench`)
# =============================================================================
#
# ЗАЧЕМ ОН ЕСТЬ. Сад растёт двумя путями — временем и рукой, — и кисть роста
# задумана ГЛАВНЫМ из них: бегущее время доживает своё. Значит, выращенная кистью
# лоза обязана выходить такой же, как выращенная временем. Все прежние проверки
# растили её `_tick`-ом, то есть ВРЕМЕНЕМ, и разницы между путями не видели вовсе.
#
# А разница была, и крупная: по жалобе пользователя 2026-08-29 «лианы поломались,
# почти не ветвятся, листья аномально мелкие». Стенд растит одну и ту же лозу
# обоими путями и печатает числа рядом.
#
# ЧИТАТЬ ТАК: развилок на звено и листьев на звено должно быть ОДНОГО ПОРЯДКА в
# обеих строках. Ноль развилок во второй строке — это и есть та поломка.
# РАСТИМ У ГЛЫБЫ, А НЕ НА ЛУГУ, и это не мелочь. Арки родятся ТАМ, ГДЕ ЕСТЬ
# ОПОРА: на ровном месте вольной ветви и отрываться реже (`air_flat`), и вверх
# ходу нет вовсе (`air_rise_prop`). Кадры пользователя — лоза на камне, туда же
# ставим и стенд.
func _grow_bench() -> void:
	plants._rng.seed = 20260829
	_seed_structures()
	_flush_chunks()
	for pid in plants.patches.keys():
		plants.remove_at(pid)
	_seed_vine()
	var at := Vector3.ZERO
	for pid in plants.patches:
		if String(plants.patches[pid]["id"]) == "vine":
			at = plants.patches[pid]["pos"]
			break
	for _i in range(600):
		plants._tick(0.15)
	var by_time: Dictionary = plants.vine_stats()
	var arch_time: Dictionary = plants.arch_stats()

	# КИСТЬЮ — ПО ТРЁМ ПОСЕВАМ, И ЭТО НЕ ПРИДИРКА. У лозы разброс огромный, а
	# всякая правка роста ещё и сдвигает общий поток случайности: сравнив «до» и
	# «после» по одному прогону, читаешь шум и принимаешь его за работу. На арках
	# я на это и наступил — 1.27 против 1.09 оказались одним и тем же.
	var was_tool: String = current_tool
	var was_time: float = plants.time_scale
	var by_hand: Dictionary = {}
	var arch_hand: Dictionary = {}
	for s in [20260829, 7, 424242]:
		for pid in plants.patches.keys():
			plants.remove_at(pid)
		plants._rng.seed = int(s)
		# Кисть роста работает только при стоящем времени — так же и меряем.
		current_tool = "grow"
		plants.time_scale = 0.0
		plants.plant_at(at, "vine")
		# Мазок ДЕРЖАТ: в игре он повторяется десятками раз в секунду, пока
		# кнопка нажата. Раз в шесть кадров — примерно то же, потолок подарка
		# всё равно не даёт скопить больше своего.
		for i in range(2400):
			if i % 6 == 0:
				_wake_plants(at, _brush_radius())
			plants._process(1.0 / 60.0)
		plants.time_scale = was_time
		current_tool = was_tool
		var one: Dictionary = plants.vine_stats()
		var arcs_one: Dictionary = plants.arch_stats()
		for k in one:
			if one[k] is int or one[k] is float:
				by_hand[k] = (by_hand.get(k, 0) if by_hand.has(k) else 0) + one[k]
		for k in arcs_one:
			arch_hand[k] = int(arch_hand.get(k, 0)) + int(arcs_one[k])

	for row in [["временем", by_time, arch_time], ["кистью  ", by_hand, arch_hand]]:
		var out: Dictionary = row[1]
		var arcs: Dictionary = row[2]
		var links: float = maxf(1.0, float(out["links"]))
		print("Стенд роста ", row[0], ": звеньев ", out["links"],
			", развилок ", out["forks"], " (", snappedf(float(out["forks"]) / links, 0.001),
			" на звено), листьев ", out["leaves"], " (",
			snappedf(float(out["leaves"]) / links, 0.01),
			" на звено), дальний порядок ветви ", out["order"])
		# АРКИ — на сотню звеньев, иначе два прогона разной величины не сравнить.
		# И ПОРОЗНЬ: при спуске (их и просили убавить) и всего.
		print("Стенд роста ", row[0], ": арок ПРИ СПУСКЕ ", arcs["falling"],
			" — ", snappedf(float(arcs["falling"]) / links * 100.0, 0.01),
			" на сто звеньев; из них перелазов ", arcs["fall_rode"],
			", плетей ", arcs["fall_hang"], " (вольных ",
			arcs["fall_hang_free"], ")",
			"; всего арок ", arcs["arches"], " (перелазов ", arcs["rode"],
			", плетей ", arcs["hang"], ") из ", arcs["runs"], " пробегов")
		# ПЛЕТИ РЯДОМ С АРКАМИ — чтобы видеть цену: арки-то делают они, и убавить
		# арки, потеряв заодно все занавесы, было бы не починкой, а разменом.
		print("Стенд роста ", row[0], ": свисающих плетей ", out["plaits"],
			", звеньев в них ", out["hangs"], ", самая длинная ", out["plait"],
			" звеньев и свесилась на ", snappedf(float(out["drop"]) * 100.0, 0.1),
			" см")
	for pid in plants.patches.keys():
		plants.remove_at(pid)
	plants.flush_now()


func _seed_vine() -> void:
	if _cliff_focus == Vector3.ZERO:
		return
	# ИЩЕМ ПО ЯЧЕЙКАМ, А НЕ ПО КОЛЬЦУ ВОКРУГ. Кольцо на высоте самой глыбы висит
	# в воздухе: земля вокруг неё ниже, и поиск поверхности оттуда не достаёт.
	# Ячейка же сама лежит там, где лежит.
	var near: Array = []
	var in_band := 0
	var flat_enough := 0
	var on_face := 0
	for cell in range(grid.seeds.size()):
		if not grid.in_play(cell):
			continue
		var s: Vector3 = grid.seeds[cell]
		var flat: float = Vector2(s.x - _cliff_focus.x, s.z - _cliff_focus.z).length()
		# ПОЯС ОТОДВИНУТ. Глыба сложена из четырёх колонн и вширь идёт метра на
		# три: в поясе 1.2–2.6 м от середины лежат её же бока, а не ровная земля,
		# и лиане неоткуда было бы к ней идти. Замерено: годных мест там ноль.
		if flat < 2.4 or flat > 4.5:
			continue
		in_band += 1
		# СПРАШИВАЕМ ТУ ЖЕ ЗЕМЛЮ, ЧТО И ПОСАДКА, и требуем, чтобы она смотрела
		# ВВЕРХ. Остров — замкнутая оболочка, у него есть и низ; рядом с глыбой
		# ближайшей поверхностью к ячейке нередко оказывается исподняя сторона, и
		# посадка такие места отвергает — правильно, но молча.
		var spot: Dictionary = grid.surface_near(s)
		if spot.is_empty() or spot["nrm"].y < 0.6:
			continue
		flat_enough += 1
		# НЕ НА КАМНЕ — вот и всё условие. По крутизне глыбу от острова не
		# отличить (замерено: на камне 0.214, на земле 0.186, а местами земля и
		# круче), а порода у ячейки либо есть, либо нет.
		#
		# ГРАБЛИ: сперва порода спрашивалась у ячейки-СЕМЕНИ, а посадка съезжает
		# на поверхность и садится в соседнюю. Лиана оказывалась на глыбе с самого
		# начала, и проверка бодро рапортовала «на камне 42 звена из 42», ничего
		# при этом не проверив.
		if grid.stone_of(int(spot["cell"])) > 0.02:
			continue
		on_face += 1
		near.append([flat, cell])
	# ПРОБУЕМ ВСЕ, а не только ближайшую: посадка отказывает по своим причинам —
	# наклон не тот, место занято, — и одной попытки мало, чтобы отличить «не
	# нашлось места» от «отказали на первой же».
	near.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	for item in near:
		var root: Vector3 = grid.seeds[int(item[1])]
		if plants.plant_at(root, "vine") >= 0:
			# ВИДИТ ЛИ ОНА ГЛЫБУ С ТОГО МЕСТА, КУДА СЕЛА. Без этого числа
			# «на круче ноль звеньев» ни о чём не говорит: то ли лиана не умеет
			# выбирать сторону, то ли ей и выбирать было не из чего.
			print("Посев лианы: у подошвы глыбы, в ", snappedf(float(item[0]), 0.1),
				" м от её середины; опора вокруг, на всю даль её",
				" взгляда — ", snappedf(plants.support_around(root,
					CELL_SPACING * 5.0), 0.01))
			return
	var why := ""
	if not near.is_empty():
		var spot: Dictionary = grid.surface_near(grid.seeds[int(near[0][1])])
		why = "; у ближайшей земля " + ("не найдена" if spot.is_empty()
			else "с наклоном " + str(snappedf(spot["nrm"].y, 0.01)))
	print("Посев лианы: места не нашлось — в поясе ", in_band, " ячеек, из них ",
		flat_enough, " пологих, из них ", on_face, " у поверхности", why)


# ВТОРАЯ ЛИАНА — ПРЯМО НА БОКУ ГЛЫБЫ.
#
# Первая проверяет, дойдёт ли лиана до опоры с ровного места. А рука сажает её и
# просто на камень, и жалуется, что там она застревает. Это другой случай: у
# такой лианы под ногами не ровная земля, а гранёный бок, и находить место
# отростку может быть попросту негде. Проверка должна трогать то, что проверяет.
func _seed_vine_on_rock() -> void:
	if _cliff_focus == Vector3.ZERO:
		return
	for cell in range(grid.seeds.size()):
		if not grid.in_play(cell) or grid.stone_of(cell) <= 0.02:
			continue
		var s: Vector3 = grid.seeds[cell]
		if s.y < _cliff_focus.y - 0.5:
			continue                 # берём повыше, чтобы было куда лезть
		var spot: Dictionary = grid.surface_near(s)
		if spot.is_empty():
			continue
		# Именно БОК: не макушка и не подошва.
		if spot["nrm"].y > 0.65 or spot["nrm"].y < 0.15:
			continue
		if plants.plant_at(spot["pos"], "vine") >= 0:
			print("Посев лианы на боку глыбы: наклон земли ",
				snappedf(spot["nrm"].y, 0.01))
			return
	print("Посев лианы на боку глыбы: подходящего бока не нашлось")


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


# Голые кадры кладём ПОД ДРУГИМ ИМЕНЕМ. Оба прогона нужны рядом — их и
# сравнивают, — а второй прогон затирал бы файлы первого, и сравнивать было бы
# не с чем. Перекладывать их руками между прогонами — лишний повод ошибиться.
func _shot_name(base: String) -> String:
	return "user://" + base + ("_plain" if _plain else "") \
		+ ("_flat" if flat_moss else "") \
		+ ("_pix" if pixel_zoom > 0 else "") + ".png"


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
	get_viewport().get_texture().get_image().save_png(_shot_name("space"))

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
	get_viewport().get_texture().get_image().save_png(_shot_name("space_close"))
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
		get_viewport().get_texture().get_image().save_png(_shot_name("space_macro"))

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
		# ТРИ ПОВОРОТА, А НЕ ОДИН. Кадр с одной стороны — это лотерея: беда у
		# подошвы глыбы вылезает с той стороны, с какой легли складки, и с
		# другой её просто не видно. Углы разнесены на треть оборота, мир и
		# камера заданы жёстко — значит, эти же три кадра, снятые с `--plain`,
		# ложатся на прежние точка в точку и сравниваются напрямую.
		var shots := [[25.0, "space_cliff"], [145.0, "space_cliff_b"],
			[265.0, "space_cliff_c"]]
		for shot in shots:
			cur_yaw = float(shot[0])
			_apply_camera()
			for _i in range(4):
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(_shot_name(String(shot[1])))

	print("Кадры сохранены в: ", ProjectSettings.globalize_path("user://"))
	get_tree().quit()
