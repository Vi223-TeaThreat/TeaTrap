extends Node3D
# =============================================================================
#  ПОГОДА
#
#  Её решения 15.09.2026 (README, «Погоды»): из трёх путей света первыми идут
#  погоды — ясно, облака, пасмурно, туман, дождь. Выбирает их ИГРОК строкой в
#  панели «Время»; погода держится, пока её не сменят; переход плавный. На рост
#  погода не влияет — только облик. Облаков на небе нет. Небо по умолчанию
#  ЯСНОЕ, а прежний северный пасмурный свет стал одной из погод.
#
#  ПОГОДА — ЭТО НАБОР ЧИСЕЛ, А НЕ КОД. У каждой свой набор (`WEATHERS`): небо,
#  солнце, рассеянный свет, дымка, тень зелени, дождь, облака, мокрость. Смена —
#  смесь двух наборов и ничего сверх: новая погода заводится строкой в списке, а
#  не веткой в коде. Тем же приёмом потом пойдёт время суток.
#
#  «ПАСМУРНО» — ПРЕЖНИЙ СВЕТ ДО ЗНАКА. Числа перенесены из `_setup_environment`
#  и `_setup_light` как были: кадры, снятые до 15.09.2026, с ним сравнимы
#  (`--weather=overcast`).
#
#  ЧТО ПОГОДА НЕ ТРОГАЕТ: направление солнца (это время суток), затенение щелей,
#  тонировку кадра, рост.
# =============================================================================

const DEFAULT_ID := "clear"

# =============================================================================
#  ВРЕМЯ СУТОК — ВТОРОЙ СЛОЙ ПОВЕРХ ПОГОДЫ (27–30.09.2026)
# =============================================================================
#
#  Её решения 15.09.2026: **солнце ставится ПОЛЗУНКОМ и само не идёт**; **ночь
#  светлая лунная** — синий приглушённый свет, сад читается, лепить можно.
#
#  ЧАС НЕ ЗАМЕНЯЕТ ПОГОДУ, А ЛЕЖИТ НАД НЕЙ. Погода говорит, какое небо и сколько
#  солнца в полдень; час говорит, куда солнце светит и во сколько раз оно слабее
#  и теплее полуденного. Потому час и погода складываются сами собой: ясный
#  рассвет и дождливый рассвет — это один и тот же час над разными погодами.
#
#  В ПОЛДЕНЬ СЛОЙ НИЧЕГО НЕ МЕНЯЕТ: все множители единицы, все оттенки белые.
#  Значит, кадры и числа, снятые до времени суток, сравнимы с полуденными до
#  знака — это и проверяет стенд.
#
#  СОЛНЦЕ ИДЁТ ПОЛНЫЙ КРУГ: 15° на час. Ночью светило — по другую сторону неба,
#  синее и слабое; это и есть луна. Отдельного светила ей не нужно, а ход выходит
#  непрерывным: в полночь ничего не перескакивает.
# =============================================================================

const NOON_ELEV: float = 48.0                  # высота солнца в полдень, градусы
const NOON_AZIM: float = -38.0                 # и его сторона — как было до часов
const ARC_PER_HOUR: float = 15.0               # полный круг за сутки

const DAY := [
	{"at": 0.0, "elev": 45.0, "sun_mul": 0.18, "sun_tint": Color(0.62, 0.72, 1.00),
		"sky_mul": 0.11, "sky_tint": Color(0.42, 0.54, 0.88), "amb_mul": 0.50,
		"fog_mul": 1.30, "fog_tint": Color(0.48, 0.58, 0.80), "sat_mul": 0.80},
	{"at": 4.0, "elev": 16.0, "sun_mul": 0.13, "sun_tint": Color(0.70, 0.78, 1.00),
		"sky_mul": 0.26, "sky_tint": Color(0.55, 0.64, 0.95), "amb_mul": 0.58,
		"fog_mul": 1.45, "fog_tint": Color(0.55, 0.62, 0.85), "sat_mul": 0.84},
	{"at": 6.0, "elev": 4.0, "sun_mul": 0.55, "sun_tint": Color(1.00, 0.72, 0.52),
		"sky_mul": 0.70, "sky_tint": Color(1.00, 0.84, 0.76), "amb_mul": 0.85,
		"fog_mul": 1.55, "fog_tint": Color(1.00, 0.86, 0.78), "sat_mul": 0.95},
	{"at": 8.5, "elev": 24.0, "sun_mul": 0.92, "sun_tint": Color(1.00, 0.93, 0.84),
		"sky_mul": 0.93, "sky_tint": Color(0.99, 0.98, 1.00), "amb_mul": 0.96,
		"fog_mul": 1.18, "fog_tint": Color(0.99, 0.96, 0.95), "sat_mul": 1.0},
	# ПОЛДЕНЬ — единица во всём: слой не трогает погоду вовсе.
	{"at": 12.0, "elev": NOON_ELEV, "sun_mul": 1.0, "sun_tint": Color(1, 1, 1),
		"sky_mul": 1.0, "sky_tint": Color(1, 1, 1), "amb_mul": 1.0,
		"fog_mul": 1.0, "fog_tint": Color(1, 1, 1), "sat_mul": 1.0},
	{"at": 16.0, "elev": 30.0, "sun_mul": 0.94, "sun_tint": Color(1.00, 0.95, 0.88),
		"sky_mul": 0.96, "sky_tint": Color(1.00, 0.99, 0.99), "amb_mul": 0.97,
		"fog_mul": 1.10, "fog_tint": Color(1.00, 0.98, 0.96), "sat_mul": 1.0},
	{"at": 19.0, "elev": 6.0, "sun_mul": 0.52, "sun_tint": Color(1.00, 0.66, 0.44),
		"sky_mul": 0.62, "sky_tint": Color(1.00, 0.78, 0.68), "amb_mul": 0.80,
		"fog_mul": 1.50, "fog_tint": Color(1.00, 0.80, 0.70), "sat_mul": 0.96},
	{"at": 21.5, "elev": 12.0, "sun_mul": 0.11, "sun_tint": Color(0.72, 0.78, 1.00),
		"sky_mul": 0.20, "sky_tint": Color(0.48, 0.58, 0.90), "amb_mul": 0.54,
		"fog_mul": 1.38, "fog_tint": Color(0.50, 0.58, 0.82), "sat_mul": 0.82},
]

const NOON: float = 12.0

const WEATHERS := [
	{"id": "clear", "label": "ясно", "look": {
		"sky_top": Color(0.33, 0.53, 0.80), "sky_horizon": Color(0.72, 0.80, 0.87),
		"ground_horizon": Color(0.62, 0.64, 0.62), "ground_bottom": Color(0.32, 0.36, 0.34),
		"sun_color": Color(1.0, 0.95, 0.86), "sun_energy": 1.60, "sun_soft": 0.5,
		"ambient": 0.42,
		"fog_color": Color(0.70, 0.78, 0.86), "fog_density": 0.0018, "fog_aerial": 0.30,
		"fog_sky": 0.0, "fog_low": 0.0, "fog_scatter": 0.05,
		"contrast": 1.16, "saturation": 1.02,
		"shade_tint": Color(0.40, 0.50, 0.50), "glow": Color(0.22, 0.32, 0.13),
		"rain": 0.0, "cover": 0.0, "wet": 0.0}},
	# Солнце то выходит, то прячется: по земле бегут тени облаков (`Clouds.gdshader`).
	{"id": "cloudy", "label": "облака", "look": {
		"sky_top": Color(0.45, 0.59, 0.77), "sky_horizon": Color(0.78, 0.83, 0.87),
		"ground_horizon": Color(0.62, 0.64, 0.62), "ground_bottom": Color(0.32, 0.36, 0.34),
		"sun_color": Color(1.0, 0.96, 0.89), "sun_energy": 1.55, "sun_soft": 0.7,
		"ambient": 0.46,
		"fog_color": Color(0.73, 0.79, 0.84), "fog_density": 0.0022, "fog_aerial": 0.28,
		"fog_sky": 0.0, "fog_low": 0.0, "fog_scatter": 0.03,
		"contrast": 1.16, "saturation": 1.0,
		"shade_tint": Color(0.41, 0.51, 0.47), "glow": Color(0.21, 0.31, 0.13),
		"rain": 0.0, "cover": 0.45, "wet": 0.0}},
	# Прежний свет игры, числа как были.
	{"id": "overcast", "label": "пасмурно", "look": {
		"sky_top": Color(0.60, 0.66, 0.72), "sky_horizon": Color(0.82, 0.85, 0.86),
		"ground_horizon": Color(0.62, 0.64, 0.62), "ground_bottom": Color(0.32, 0.36, 0.34),
		"sun_color": Color(1.0, 0.97, 0.91), "sun_energy": 1.20, "sun_soft": 1.0,
		"ambient": 0.50,
		"fog_color": Color(0.74, 0.78, 0.80), "fog_density": 0.0025, "fog_aerial": 0.25,
		"fog_sky": 0.0, "fog_low": 0.0, "fog_scatter": 0.0,
		"contrast": 1.16, "saturation": 0.98,
		"shade_tint": Color(0.42, 0.52, 0.44), "glow": Color(0.20, 0.30, 0.13),
		"rain": 0.0, "cover": 0.0, "wet": 0.0}},
	# Дымка на всю даль и гуще у земли — в низинах туман стоит, на скалах редеет.
	{"id": "fog", "label": "туман", "look": {
		"sky_top": Color(0.72, 0.75, 0.76), "sky_horizon": Color(0.83, 0.85, 0.85),
		"ground_horizon": Color(0.74, 0.76, 0.75), "ground_bottom": Color(0.60, 0.62, 0.61),
		"sun_color": Color(1.0, 0.98, 0.94), "sun_energy": 0.55, "sun_soft": 3.0,
		"ambient": 0.62,
		"fog_color": Color(0.80, 0.82, 0.82), "fog_density": 0.012, "fog_aerial": 0.55,
		"fog_sky": 1.0, "fog_low": 0.35, "fog_scatter": 0.12,
		"contrast": 1.06, "saturation": 0.86,
		"shade_tint": Color(0.46, 0.53, 0.50), "glow": Color(0.18, 0.26, 0.12),
		"rain": 0.0, "cover": 0.0, "wet": 0.25}},
	{"id": "rain", "label": "дождь", "look": {
		"sky_top": Color(0.40, 0.44, 0.49), "sky_horizon": Color(0.58, 0.61, 0.64),
		"ground_horizon": Color(0.50, 0.52, 0.51), "ground_bottom": Color(0.28, 0.31, 0.30),
		"sun_color": Color(0.92, 0.94, 0.98), "sun_energy": 0.45, "sun_soft": 3.0,
		"ambient": 0.56,
		"fog_color": Color(0.52, 0.56, 0.59), "fog_density": 0.006, "fog_aerial": 0.40,
		"fog_sky": 0.5, "fog_low": 0.0, "fog_scatter": 0.0,
		"contrast": 1.10, "saturation": 0.90,
		"shade_tint": Color(0.40, 0.49, 0.50), "glow": Color(0.16, 0.24, 0.11),
		"rain": 1.0, "cover": 0.0, "wet": 1.0}},
]

# СМЕНА ИДЁТ ЧЕТЫРЕ СЕКУНДЫ, по гладкой кривой: и начало, и конец без толчка.
const TURN_SECONDS: float = 4.0
# МОКРОСТЬ ЖИВЁТ СВОИМ ХОДОМ, А НЕ ХОДОМ СМЕНЫ: земля намокает за двадцать секунд
# дождя и сохнет минуту. Высохни она за те же четыре секунды, что гаснет дождь, —
# и ливень читался бы переключателем, а не погодой.
const SOAK_SECONDS: float = 20.0
const DRY_SECONDS: float = 60.0
# Туман гуще ниже этой высоты (`fog_low` — насколько).
const FOG_LOW_AT: float = 0.5

# ТЕНИ ОБЛАКОВ. Плоскость выше всего, что можно построить (остров 2.5 м и запас
# высоты 20 м), и шире острова с запасом на косое солнце.
const CLOUD_Y: float = 26.0
const CLOUD_SPAN: float = 220.0                # шире острова с запасом на косое солнце
const CLOUD_SIZE: float = 18.0                 # крупность узора, м
const CLOUD_DRIFT := Vector2(1.12, 0.84)       # ветер, м/с; им же косит дождь
const CLOUD_SAMPLES: int = 4096
const CLOUD_FIELD: float = 4000.0              # поле выборки, в долях узора
# Второй кусок узора, далеко от первого: по нему проверяется подобранный порог.
const CLOUD_PROBE_AT: float = 1000.0

const RAIN_DROPS: int = 9000
const RAIN_BOX := Vector3(44.0, 28.0, 44.0)   # короб дождя вокруг точки взгляда, м

# Кадрам (`--shot`) — один и тот же миг облаков и дождя.
const SHOT_CLOCK: float = 12.0

var main: Node3D
var env: Environment
var sky: ProceduralSkyMaterial
var sun: DirectionalLight3D
var rock_mat: ShaderMaterial
var blade_mat: ShaderMaterial

var weather_id: String = DEFAULT_ID          # выбранная погода — та, К КОТОРОЙ идём
var hour: float = NOON                       # час суток, 0…24; ставит ползунок
var wet: float = 0.0
var _day: Dictionary = {}                    # слой часа, посчитанный для `hour`
var _from: Dictionary = {}
var _to: Dictionary = {}
var _now: Dictionary = {}                     # что показано сейчас
var _turn: float = 1.0                        # доля пройденной смены; 1 — стоим
var _clock: float = 0.0                       # ход облаков и капель, настоящие секунды
var _frozen: bool = false

var _cloud_node: MeshInstance3D
var _cloud_mat: ShaderMaterial
var _cloud_values: PackedFloat32Array          # узор по возрастанию: доля земли -> порог
var _cloud_built_ms: float = 0.0
var _rain_node: MeshInstance3D
var _rain_mat: ShaderMaterial
var _rain_built_ms: float = 0.0


func setup(main_ref: Node3D, env_ref: Environment, sky_ref: ProceduralSkyMaterial,
		sun_ref: DirectionalLight3D, rock_ref: ShaderMaterial, first_id: String,
		first_hour: float = NOON) -> void:
	main = main_ref
	env = env_ref
	sky = sky_ref
	sun = sun_ref
	rock_mat = rock_ref
	env.fog_height = FOG_LOW_AT
	# Час считается ДО первой погоды: `_apply` уже смотрит на него.
	hour = fposmod(first_hour, 24.0)
	_day = _day_at(hour)
	_aim_sun()

	# ОБЛАКА — ПЛОСКОСТЬ, КОТОРУЮ ВИДИТ ТОЛЬКО СОЛНЦЕ. Камера её не рисует, а в
	# карту теней она ложится со своими прорезями-просветами. Тень от неё падает на
	# всё сразу — землю, камень, мох, лозу, мак — и гасит только прямой свет: там,
	# где и так тень, облако не темнит ничего. Ни один шейдер ради этого не правился.
	var t0: int = Time.get_ticks_usec()
	_cloud_values = _cloud_sample(0.0)
	_cloud_built_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	_cloud_mat = ShaderMaterial.new()
	_cloud_mat.shader = load("res://Clouds.gdshader")
	_cloud_mat.set_shader_parameter("cloud_size", CLOUD_SIZE)
	_cloud_mat.set_shader_parameter("drift", CLOUD_DRIFT)
	var plane := PlaneMesh.new()
	plane.size = Vector2(CLOUD_SPAN, CLOUD_SPAN)
	_cloud_node = MeshInstance3D.new()
	_cloud_node.mesh = plane
	_cloud_node.material_override = _cloud_mat
	_cloud_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	_cloud_node.visible = false
	add_child(_cloud_node)
	_place_clouds()

	# ДОЖДЬ СОБИРАЕТСЯ ПРИ ЗАПУСКЕ, А НЕ ПО НАЖАТИЮ. Меш капель стоит пару десятков
	# миллисекунд; собирай его первый выбор «дождя» — и рука игрока получила бы
	# рывок ровно в тот миг, когда нажала.
	t0 = Time.get_ticks_usec()
	_rain_mat = ShaderMaterial.new()
	_rain_mat.shader = load("res://Rain.gdshader")
	_rain_mat.set_shader_parameter("rain_box", RAIN_BOX)
	_rain_mat.set_shader_parameter("wind", CLOUD_DRIFT.normalized())
	_rain_node = MeshInstance3D.new()
	_rain_node.mesh = _rain_mesh()
	_rain_node.material_override = _rain_mat
	_rain_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Капли переставляет шейдер, и своих границ у меша нет: без короба на весь мир
	# движок отсекал бы дождь, едва единичный кубик у начала координат уйдёт из кадра.
	_rain_node.custom_aabb = AABB(Vector3(-5000.0, -5000.0, -5000.0),
		Vector3(10000.0, 10000.0, 10000.0))
	_rain_node.visible = false
	add_child(_rain_node)
	_rain_built_ms = float(Time.get_ticks_usec() - t0) / 1000.0

	set_now(first_id)


# Материал зелени появляется позже неба: растения заводятся после панели.
func attach_plants(mat: ShaderMaterial) -> void:
	blade_mat = mat
	_apply_blades(_now)
	_apply_wet()


# Ключ `--weather=rain`: разовая проба для кадров, как `--seed`.
func pick(args: PackedStringArray, fallback: String) -> String:
	for a in args:
		if a.begins_with("--weather="):
			return _known(a.substr("--weather=".length()))
	return fallback


# ЧАС СУТОК. Ставится ползунком и держится — сам не идёт (её решение). Смены,
# как у погоды, нет нарочно: рука ведёт ползунок, и свет обязан идти за рукой.
func set_hour(at: float) -> void:
	hour = fposmod(at, 24.0)
	_day = _day_at(hour)
	_aim_sun()
	if not _now.is_empty():
		_apply(_now)


# Слой часа — смесь двух соседних строк `DAY` по кругу суток.
func _day_at(at: float) -> Dictionary:
	var last: int = DAY.size() - 1
	var a: Dictionary = DAY[last]
	var b: Dictionary = DAY[0]
	# Сутки замкнуты: после последней строки идёт первая, но уже завтрашняя.
	var from_at: float = float(a["at"]) - 24.0
	var to_at: float = float(b["at"])
	for i in range(DAY.size()):
		var row: Dictionary = DAY[i]
		if at >= float(row["at"]):
			a = row
			from_at = float(row["at"])
			b = DAY[0] if i == last else DAY[i + 1]
			to_at = 24.0 if i == last else float(b["at"])
	var span: float = maxf(to_at - from_at, 0.000001)
	return _mix(a, b, clampf((at - from_at) / span, 0.0, 1.0))


# Куда смотрит светило. Круг за сутки, в полдень — та самая сторона, что стояла
# до времени суток.
func _aim_sun() -> void:
	if sun == null or _day.is_empty():
		return
	sun.rotation_degrees = Vector3(-float(_day["elev"]),
		NOON_AZIM + (hour - NOON) * ARC_PER_HOUR, 0.0)
	_place_clouds()


# Ключ `--hour=6.5`: разовая проба для кадров, как `--weather=`.
func pick_hour(args: PackedStringArray, fallback: float) -> float:
	for a in args:
		if a.begins_with("--hour="):
			var tail: String = a.substr("--hour=".length())
			if tail.is_valid_float():
				return fposmod(tail.to_float(), 24.0)
	return fallback


# Сразу, без смены: запуск, загрузка сада, кадры.
func set_now(id: String) -> void:
	weather_id = _known(id)
	_to = _look_of(weather_id)
	_from = _to
	_now = _to.duplicate()
	_turn = 1.0
	wet = float(_to["wet"])
	_apply(_now)
	_apply_wet()


# Выбор игрока: смена идёт от того, что показано СЕЙЧАС, — нажми посреди смены,
# и новая пойдёт без скачка от середины прежней.
func change(id: String) -> void:
	var next: String = _known(id)
	if next == weather_id:
		return
	weather_id = next
	_from = _now.duplicate()
	_to = _look_of(next)
	_turn = 0.0


# Кадрам (`--shot`) — погода доведена, облака и капли стоят в одном и том же миге.
func freeze(at: float) -> void:
	_frozen = true
	_clock = at
	if _turn < 1.0:
		_turn = 1.0
		_now = _to.duplicate()
		_apply(_now)
	wet = float(_to["wet"])
	_apply_wet()
	_move()


func _process(delta: float) -> void:
	if env == null:
		return
	if _turn < 1.0:
		_turn = minf(1.0, _turn + delta / TURN_SECONDS)
		_now = _mix(_from, _to, smoothstep(0.0, 1.0, _turn))
		_apply(_now)
	var goal: float = float(_to["wet"])
	if wet != goal:
		wet = move_toward(wet, goal, delta / (SOAK_SECONDS if goal > wet else DRY_SECONDS))
		_apply_wet()
	# Облака и капли идут по НАСТОЯЩИМ секундам: «стоп» останавливает рост, а не
	# ветер.
	if not _frozen:
		_clock += delta
	_move()


func _known(id: String) -> String:
	for w in WEATHERS:
		if String(w["id"]) == id:
			return id
	print("Погоды «", id, "» нет; беру ", DEFAULT_ID)
	return DEFAULT_ID


func _look_of(id: String) -> Dictionary:
	for w in WEATHERS:
		if String(w["id"]) == id:
			return w["look"]
	return WEATHERS[0]["look"]


func _label_of(id: String) -> String:
	for w in WEATHERS:
		if String(w["id"]) == id:
			return String(w["label"])
	return id


func _mix(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out: Dictionary = {}
	for key in b:
		if b[key] is Color:
			out[key] = (a[key] as Color).lerp(b[key], t)
		else:
			out[key] = lerpf(float(a[key]), float(b[key]), t)
	return out


func _apply(look: Dictionary) -> void:
	# ЧАС ЛЕЖИТ НАД ПОГОДОЙ: множители силы и оттенки. В полдень все множители
	# единицы, а оттенки белые — тогда это в точности набор погоды, число в число.
	var sky_mul: float = _day["sky_mul"]
	var sky_tint: Color = _day["sky_tint"]
	# ДЫМКА ТЕМНЕЕТ МЕДЛЕННЕЕ НЕБА. Она светится небом, но ночью небо в десятую
	# долю силы, и по нему дымка пропала бы вовсе; берём три четверти пути.
	var fog_mul: float = lerpf(1.0, sky_mul, 0.75)
	sky.sky_top_color = _tint(look["sky_top"], sky_tint, sky_mul)
	sky.sky_horizon_color = _tint(look["sky_horizon"], sky_tint, sky_mul)
	sky.ground_horizon_color = _tint(look["ground_horizon"], sky_tint, sky_mul)
	sky.ground_bottom_color = _tint(look["ground_bottom"], sky_tint, sky_mul)
	env.ambient_light_energy = float(look["ambient"]) * float(_day["amb_mul"])
	env.fog_light_color = _tint(look["fog_color"], _day["fog_tint"], fog_mul)
	env.fog_density = float(look["fog_density"]) * float(_day["fog_mul"])
	env.fog_aerial_perspective = look["fog_aerial"]
	env.fog_sky_affect = look["fog_sky"]
	env.fog_height_density = look["fog_low"]
	env.fog_sun_scatter = look["fog_scatter"]
	env.adjustment_contrast = look["contrast"]
	env.adjustment_saturation = float(look["saturation"]) * float(_day["sat_mul"])
	sun.light_color = _tint(look["sun_color"], _day["sun_tint"], 1.0)
	sun.light_energy = float(look["sun_energy"]) * float(_day["sun_mul"])
	sun.light_angular_distance = look["sun_soft"]
	_apply_blades(look)
	var cover: float = look["cover"]
	_cloud_node.visible = cover > 0.001
	_cloud_mat.set_shader_parameter("cut", _cloud_cut(cover))
	var rain: float = look["rain"]
	_rain_node.visible = rain > 0.001
	_rain_mat.set_shader_parameter("rain", rain)


func _apply_blades(look: Dictionary) -> void:
	if blade_mat == null or look.is_empty():
		return
	# Тень зелени тоже уходит в синеву вместе с небом — иначе ночью она осталась
	# бы дневной зеленоватой и выдавала бы себя.
	blade_mat.set_shader_parameter("shade_tint",
		_tint(look["shade_tint"], _day["sky_tint"], 1.0))
	blade_mat.set_shader_parameter("glow", look["glow"])


# Цвет под оттенок и силу часа. Прозрачность не трогаем: у неба и дымки она своя.
func _tint(base: Color, shade: Color, mul: float) -> Color:
	return Color(base.r * shade.r * mul, base.g * shade.g * mul,
		base.b * shade.b * mul, base.a)


func _apply_wet() -> void:
	rock_mat.set_shader_parameter("wet", wet)
	if blade_mat != null:
		blade_mat.set_shader_parameter("wet", wet)


# Ход облаков и капель — два-три числа на кадр, и только у той, что видна.
func _move() -> void:
	if _cloud_node.visible:
		_cloud_mat.set_shader_parameter("cloud_time", _clock)
	if _rain_node.visible:
		_rain_mat.set_shader_parameter("rain_time", _clock)
		_rain_mat.set_shader_parameter("rain_center",
			main.cur_pivot + Vector3(0.0, RAIN_BOX.y * 0.1, 0.0))


# Плоскость облаков сдвинута К СОЛНЦУ: тень от неё падает косо, и над островом
# должна стоять не она сама, а её тень.
func _place_clouds() -> void:
	if sun == null or _cloud_node == null:
		return
	var to_sun: Vector3 = sun.basis.z.normalized()
	# У НИЗКОГО СОЛНЦА ТЕНЬ УХОДИТ ЗА КРАЙ СВЕТА. Косое светило отодвигает
	# плоскость на `высота / синус`, и на рассвете это сотни метров — тень облаков
	# легла бы мимо острова. Держим отход в узде: ниже этого угла плоскость просто
	# не отъезжает дальше, а узор всё равно ползёт и ничего не выдаёт.
	_cloud_node.position = to_sun * (CLOUD_Y / maxf(to_sun.y, 0.30))


# =============================================================================
#  УЗОР ОБЛАКОВ — копия `cloud_field` из `Clouds.gdshader`
# =============================================================================
#
# ДОЛЯ ЗЕМЛИ В ТЕНИ ЗАДАЁТСЯ ЧИСЛОМ, А ПОРОГ ПОДБИРАЕТСЯ. Шум распределён не
# ровно — середина густо, края редко, — и порог 0.55 не значит «45% в тени».
# Поэтому узор снят выборкой и разложен по возрастанию: порог для заказанной
# доли — число из выборки на нужном месте.
#
# ТОЧКИ РАЗБРОСАНЫ ПО ОГРОМНОМУ ПОЛЮ, А НЕ ЛЕЖАТ СЕТКОЙ. Сперва выборка была
# плотной сеткой на двадцать облаков поперёк: соседние точки падали в одно облако,
# и порог, подобранный на одном куске узора, на другом промахивался на четыре-шесть
# процентов земли разом на всех долях (замер 15.09.2026). Разбросом по золотому
# сечению каждая точка попадает в своё облако. Точек 4096: при 1024 промах от самой
# выборки ещё доходил до пяти процентов.
func _cloud_sample(offset: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(CLOUD_SAMPLES)
	for i in range(CLOUD_SAMPLES):
		var u: float = fposmod(0.5 + float(i) * 0.7548776662, 1.0)
		var v: float = fposmod(0.5 + float(i) * 0.5698402910, 1.0)
		out[i] = cloud_field(offset + u * CLOUD_FIELD, offset + v * CLOUD_FIELD)
	out.sort()
	return out


func _cloud_cut(cover: float) -> float:
	if cover <= 0.001:
		return 2.0
	var last: int = _cloud_values.size() - 1
	return _cloud_values[clampi(int(round((1.0 - cover) * float(last))), 0, last)]


func cloud_field(x: float, y: float) -> float:
	return _vnoise(x, y) * 0.6 + _vnoise(x * 2.03 + 17.0, y * 2.03 + 17.0) * 0.28 \
		+ _vnoise(x * 4.11 + 41.0, y * 4.11 + 41.0) * 0.12


func _vnoise(x: float, y: float) -> float:
	var ix: float = floorf(x)
	var iy: float = floorf(y)
	var fx: float = x - ix
	var fy: float = y - iy
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	return lerpf(lerpf(_hash12(ix, iy), _hash12(ix + 1.0, iy), fx),
		lerpf(_hash12(ix, iy + 1.0), _hash12(ix + 1.0, iy + 1.0), fx), fy)


func _hash12(x: float, y: float) -> float:
	var a: float = x * 0.1031
	var b: float = y * 0.1031
	a -= floorf(a)
	b -= floorf(b)
	var c: float = a
	var d: float = a * (b + 33.33) + b * (c + 33.33) + c * (a + 33.33)
	a += d
	b += d
	c += d
	var h: float = (a + b) * c
	return h - floorf(h)


# =============================================================================
#  КАПЛИ
# =============================================================================
#
# Каждая капля — четыре точки в ОДНОМ месте короба (доли от 0 до 1), а вытянуть
# их в черту, уронить и завернуть в короб вокруг взгляда — дело шейдера
# (`Rain.gdshader`). Процессору после сборки дождь не стоит ничего.
func _rain_mesh() -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260915
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var marks := PackedColorArray()
	var index := PackedInt32Array()
	verts.resize(RAIN_DROPS * 4)
	uvs.resize(RAIN_DROPS * 4)
	marks.resize(RAIN_DROPS * 4)
	index.resize(RAIN_DROPS * 6)
	for d in range(RAIN_DROPS):
		var base := Vector3(rng.randf(), rng.randf(), rng.randf())
		# Красный — очередь капли, когда дождь густеет (не ноль: иначе капля была бы
		# видна и без дождя); зелёный — своя скорость; синий — своя длина черты.
		var mark := Color(lerpf(0.004, 1.0, rng.randf()), rng.randf(), rng.randf(), 1.0)
		var v: int = d * 4
		for c in range(4):
			verts[v + c] = base
			marks[v + c] = mark
		uvs[v] = Vector2(-1.0, 0.0)
		uvs[v + 1] = Vector2(1.0, 0.0)
		uvs[v + 2] = Vector2(1.0, 1.0)
		uvs[v + 3] = Vector2(-1.0, 1.0)
		var k: int = d * 6
		index[k] = v
		index[k + 1] = v + 1
		index[k + 2] = v + 2
		index[k + 3] = v
		index[k + 4] = v + 2
		index[k + 5] = v + 3
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = marks
	arrays[Mesh.ARRAY_INDEX] = index
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# =============================================================================
#  ПРОВЕРКА — строки для самопроверки и `--weatherbench`
# =============================================================================
#
# Облик погоды судит только кадр. Числами проверяется механизм: наборы ложатся
# точно, смена идёт без рывка, мокрость набегает и сходит в свой срок, облака
# закрывают заказанную долю земли, и сколько всё это стоит кадру.
func check() -> Array:
	var lines: Array = []
	var was_id: String = weather_id
	var was_clock: float = _clock
	var was_frozen: bool = _frozen
	var was_hour: float = hour
	_frozen = true
	# ПОЛДЕНЬ — ТОЧКА СРАВНЕНИЯ: слой часа в нём единичный, и набор погоды обязан
	# дойти до неба и солнца число в число, как было до времени суток.
	set_hour(NOON)

	var worst: float = 0.0
	for w in WEATHERS:
		set_now(String(w["id"]))
		worst = maxf(worst, _drift_from(w["look"]))
	# Мерка обязана ловить расхождение — проверяем на заведомо испорченном.
	set_now("overcast")
	env.fog_density += 0.001
	var caught: bool = _drift_from(_look_of("overcast")) >= 0.0009
	set_now("overcast")
	lines.append("Погода в полдень: %d наборов ложатся точно — наибольшее расхождение %s (мерка ловит дымку, подменённую на 0.001: %s)"
		% [WEATHERS.size(), "меньше миллионной" if worst < 0.000001 else str(worst),
		"да" if caught else "НЕТ"])

	# ВРЕМЯ СУТОК. Облик судит кадр; числами проверяем, что светило идёт кругом без
	# скачка, что в полдень слой часа единичный, и что ночью света хватает, чтобы
	# лепить (её условие «ночь светлая лунная»).
	set_now("clear")
	var day_line: Array = []
	var jump: float = 0.0
	var was_dir := Vector3.ZERO
	var step_h: float = 0.25
	var h: float = 0.0
	while h < 24.0:
		set_hour(h)
		var dir: Vector3 = sun.basis.z.normalized()
		if was_dir != Vector3.ZERO:
			jump = maxf(jump, rad_to_deg(was_dir.angle_to(dir)))
		was_dir = dir
		h += step_h
	for at in [0.0, 6.0, 12.0, 19.0, 21.5]:
		set_hour(at)
		day_line.append("%02d:%02d — солнце %s под %s°, рассеянный %s"
			% [int(at), int(round(fposmod(at, 1.0) * 60.0)),
			snappedf(sun.light_energy, 0.01), snappedf(-sun.rotation_degrees.x, 0.1),
			snappedf(env.ambient_light_energy, 0.01)])
	lines.append("Время суток (ясно): " + "; ".join(day_line))
	set_hour(0.0)
	var night_light: float = sun.light_energy + env.ambient_light_energy
	set_hour(NOON)
	lines.append("Ход светила: за четверть часа поворот не больше %s° — скачка нет (полный круг за сутки, 15° на час); ночью солнце с рассеянным дают %s против %s в полдень"
		% [snappedf(jump, 0.01), snappedf(night_light, 0.01),
		snappedf(sun.light_energy + env.ambient_light_energy, 0.01)])

	var t_hour: int = Time.get_ticks_usec()
	for i in range(200):
		set_hour(float(i) * 0.12)
	var hour_us: float = float(Time.get_ticks_usec() - t_hour) / 200.0
	set_hour(NOON)
	lines.append("Ползунок часа: одна подвижка стоит %s мкс — рука ведёт его кадрами, и свет обязан идти за рукой"
		% snappedf(hour_us, 0.1))

	var frame: float = 1.0 / 60.0
	set_now("clear")
	change("rain")
	var sun_span: float = absf(float(_to["sun_energy"]) - sun.light_energy)
	var last: float = sun.light_energy
	var biggest: float = 0.0
	var turn_frames: int = 0
	var cost_sum: int = 0
	var cost_worst: int = 0
	var elapsed: float = 0.0
	var soak_s: float = -1.0
	while elapsed < 120.0:
		var turning: bool = _turn < 1.0
		var t0: int = Time.get_ticks_usec()
		_process(frame)
		var took: int = Time.get_ticks_usec() - t0
		elapsed += frame
		if turning:
			turn_frames += 1
			cost_sum += took
			cost_worst = maxi(cost_worst, took)
			biggest = maxf(biggest, absf(sun.light_energy - last) / maxf(sun_span, 0.000001))
		last = sun.light_energy
		if wet >= 0.9:
			soak_s = elapsed
			break
	lines.append("Смена «ясно -> дождь»: доходит за %s с, самый крупный шаг за кадр %s%% пути (ровная смесь дала бы %s%%), кадр смены стоит в среднем %s мкс, худший %s мкс"
		% [snappedf(float(turn_frames) * frame, 0.01), snappedf(biggest * 100.0, 0.01),
		snappedf(frame / TURN_SECONDS * 100.0, 0.01),
		snappedf(float(cost_sum) / float(maxi(turn_frames, 1)), 1.0), cost_worst])

	change("clear")
	elapsed = 0.0
	var dry_s: float = -1.0
	while elapsed < 240.0:
		_process(frame)
		elapsed += frame
		if wet <= 0.1:
			dry_s = elapsed
			break
	lines.append("Мокрость: дождь намочил землю до 90%% за %s с, ясная погода высушила с 90%% до 10%% за %s с"
		% [snappedf(soak_s, 0.1), snappedf(dry_s, 0.1)])

	var idle: Array = []
	for id in ["clear", "cloudy", "rain"]:
		set_now(id)
		var sum: int = 0
		for _i in range(300):
			var t1: int = Time.get_ticks_usec()
			_process(frame)
			sum += Time.get_ticks_usec() - t1
		idle.append("%s %s" % [_label_of(id), snappedf(float(sum) / 300.0, 0.1)])
	lines.append("Кадр без смены погоды, мкс: " + ", ".join(idle))

	# Порог подобран по одному куску узора, а проверяется на другом, далёком.
	var probe: PackedFloat32Array = _cloud_sample(CLOUD_PROBE_AT)
	var shares: Array = []
	for cover in [0.2, 0.45, 0.7]:
		var above: int = probe.size() - probe.bsearch(_cloud_cut(cover))
		shares.append("%s%% -> %s%%" % [snappedf(cover * 100.0, 1.0),
			snappedf(float(above) / float(probe.size()) * 100.0, 0.1)])
	lines.append("Облака: заказанная доля земли в тени -> вышла на другом куске узора: "
		+ ", ".join(shares) + " (облака «облачной» погоды — %s%%)"
		% snappedf(float(_look_of("cloudy")["cover"]) * 100.0, 1.0))

	lines.append("Дождь: %d капель в коробе %s×%s×%s м вокруг точки взгляда; при запуске меш капель собран за %s мс, узор облаков — за %s мс"
		% [RAIN_DROPS, RAIN_BOX.x, RAIN_BOX.y, RAIN_BOX.z, snappedf(_rain_built_ms, 0.1),
		snappedf(_cloud_built_ms, 0.1)])

	set_hour(was_hour)
	set_now(was_id)
	_clock = was_clock
	_frozen = was_frozen
	_move()
	return lines


# Насколько показанное расходится с набором: небо, солнце, дымка, зелень, облака,
# дождь, мокрость — наибольшая разница по всем числам.
func _drift_from(look: Dictionary) -> float:
	var got: Dictionary = {
		"sky_top": sky.sky_top_color, "sky_horizon": sky.sky_horizon_color,
		"ground_horizon": sky.ground_horizon_color, "ground_bottom": sky.ground_bottom_color,
		"sun_color": sun.light_color, "sun_energy": sun.light_energy,
		"sun_soft": sun.light_angular_distance, "ambient": env.ambient_light_energy,
		"fog_color": env.fog_light_color, "fog_density": env.fog_density,
		"fog_aerial": env.fog_aerial_perspective, "fog_sky": env.fog_sky_affect,
		"fog_low": env.fog_height_density, "fog_scatter": env.fog_sun_scatter,
		"contrast": env.adjustment_contrast, "saturation": env.adjustment_saturation,
		"rain": _rain_mat.get_shader_parameter("rain"),
		"wet": rock_mat.get_shader_parameter("wet"),
	}
	if blade_mat != null:
		got["shade_tint"] = blade_mat.get_shader_parameter("shade_tint")
		got["glow"] = blade_mat.get_shader_parameter("glow")
	var worst: float = absf(float(_cloud_mat.get_shader_parameter("cut"))
		- _cloud_cut(float(look["cover"])))
	for key in got:
		var a = got[key]
		var b = look[key]
		if b is Color:
			var ca: Color = a
			var cb: Color = b
			worst = maxf(worst, maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b))))
		else:
			worst = maxf(worst, absf(float(a) - float(b)))
	return worst
