extends Node

const LevelsData = preload("res://Levels.gd")
const PlantsData = preload("res://Plants.gd")

const PROGRESS_PATH := "user://story.cfg"
const META_KEY := "story_level"
const CHECK_EVERY: float = 0.5
const NOTE_SECS: float = 2.5
const ARM_SECS: float = 3.0

enum {IDLE, TALK, PLAY, WON, LOST}

var main: Node3D
var level: Dictionary = {}
var stock: Dictionary = {}
var state: int = IDLE
var focus: Vector3 = Vector3.ZERO
var testing: bool = false
var _touch_start: int = 0
var _check_in: float = 0.0
var _passed: Dictionary = {}
var _note: String = ""
var _note_left: float = 0.0
var _armed: Dictionary = {}
var _panel: PanelContainer
var _status: Label
var _stock_label: Label
var _note_label: Label
var _talk_layer: CanvasLayer
var _talk_panel: PanelContainer
var _talk_lines: Array = []
var _talk_page: int = 0
var _talk_end: Array = []


func setup(main_ref: Node3D, bench: bool, args: PackedStringArray) -> void:
	main = main_ref
	_load_progress()
	var id: String = ""
	if "--storybench" in args:
		testing = true
		id = _level_arg(args, String(LevelsData.LEVELS[0]["id"]))
	elif not bench:
		# ИГРА НАЧИНАЕТСЯ С СЮЖЕТНОГО УРОВНЯ, А НЕ С ПЕСОЧНИЦЫ (её решение
		# 02.10.2026). Прежде по умолчанию стоял свободный остров, и в сюжет
		# надо было входить ключом.
		#
		# ЧЕМ «ЗАПУСК ИГРЫ» ОТЛИЧАЕТСЯ ОТ «ПЕРЕЗАПУСКА СЦЕНЫ»: уровень
		# перезапускает сцену (`restart`, `leave`, `start_level`), и выбор надо
		# пронести через перезапуск, иначе «на свободный остров» тут же вернуло
		# бы в уровень. Проносится он пометкой у движка, и ПУСТАЯ ПОМЕТКА — тоже
		# выбор: это и значит «игрок ушёл на свободный остров». Поэтому
		# спрашиваем не значение, а ЕСТЬ ЛИ ПОМЕТКА ВООБЩЕ.
		var kept: String = String(Engine.get_meta(META_KEY, "")) \
			if Engine.has_meta(META_KEY) else _first_unpassed()
		id = _level_arg(args, kept)
		Engine.set_meta(META_KEY, id)
	level = LevelsData.find(id)


# С КАКОГО УРОВНЯ НАЧИНАТЬ. Первый непройденный; пройдены все — снова первый:
# свободный остров рядом, в него уводит кнопка из разговора, а вот забыть, чем
# игра начинается, нельзя.
func _first_unpassed() -> String:
	for item in LevelsData.LEVELS:
		if goal_exists(item) and not _passed.has(String(item["id"])):
			return String(item["id"])
	return String(LevelsData.LEVELS[0]["id"])


func goal_exists(lv: Dictionary) -> bool:
	var born: String = String(lv.get("goal", {}).get("born", ""))
	if not PlantsData.ITEMS.has(born):
		return false
	for rule in PlantsData.MEETS:
		if String(rule["born"]) == born:
			return true
	return false


func goal_name() -> String:
	if level.has("goal_name"):
		return String(level["goal_name"])
	return String(PlantsData.ITEMS[String(level["goal"]["born"])]["name"]).to_lower()


func _level_arg(args: PackedStringArray, fallback: String) -> String:
	for a in args:
		if a.begins_with("--level="):
			var tail: String = a.substr(8)
			if LevelsData.index_of(tail) >= 0:
				return tail
			print("Острова «", tail, "» нет; беру ", "свободный остров" if fallback == "" else fallback)
	return fallback


func active() -> bool:
	return not level.is_empty()


func allows(id: String) -> bool:
	return active() and (level.get("tools", []) as Array).has(id)


func island_seed() -> int:
	return int(level.get("seed", main.WORLD_SEED))


# РАДИУС ОСТРОВА ЭТОГО УРОВНЯ (её решение 02.10.2026). Нет в карточке — остров
# обычный, как на свободном.
func island_radius() -> float:
	return float(level.get("island", main.ISLAND_RADIUS))


func number() -> int:
	return LevelsData.index_of(String(level.get("id", ""))) + 1


func begin() -> void:
	stock = (level.get("stock", {}) as Dictionary).duplicate()
	_touch_start = main.plants.meet_stats().x
	var view: Dictionary = level.get("view", {})
	main.target_pivot = focus + Vector3(0.0, float(view.get("lift", 1.5)), 0.0)
	main.target_yaw = float(view.get("yaw", main.target_yaw))
	main.target_pitch = float(view.get("pitch", main.target_pitch))
	main.target_zoom = float(view.get("zoom", main.target_zoom))
	if level.has("weather"):
		main.weather.set_now(String(level["weather"]))
	if level.has("hour"):
		main.weather.set_hour(float(level["hour"]))
	for i in range(main.SPEEDS.size()):
		if is_equal_approx(float(main.SPEEDS[i]["value"]), 1.0):
			main._set_time_scale(i)
	for id in level.get("tools", []):
		if PlantsData.is_plant(String(id)):
			main._select_tool(String(id))
			break
	state = TALK
	var lines: Array = (level["talk"]["start"] as Array).duplicate()
	if not goal_exists(level):
		lines.append_array(level["talk"].get("draft", []))
	_talk(lines, [["начать", _play]])


func can_plant(id: String) -> bool:
	if state == IDLE or state == TALK:
		note("сначала дослушай")
		return false
	if state == LOST:
		return false
	if int(stock.get(id, 0)) <= 0:
		note("семена «%s» кончились" % String(PlantsData.ITEMS[id]["name"]))
		return false
	return true


func planted(id: String) -> void:
	stock[id] = int(stock.get(id, 0)) - 1
	main._refresh_toolbar()


func refused() -> void:
	note("сюда не сесть — тесно или круто")


func may_undo() -> bool:
	return state == PLAY


# ИДЁТ ЛИ РАЗГОВОР ПРЯМО СЕЙЧАС. Спрашивает метка находки (`_update_find` в
# `SpaceMain`): её часы стоят, пока спутник говорит, — иначе метка догорала бы
# за чтением победного разговора и гасла ровно к тому мигу, когда игрок наконец
# поднимет глаза на остров.
func talking() -> bool:
	return _talk_layer != null


func unplant(pid: int, id: String) -> void:
	main.plants.remove_organism(pid)
	stock[id] = int(stock.get(id, 0)) + 1
	main._refresh_toolbar()


func note(text: String) -> void:
	_note = text
	_note_left = NOTE_SECS
	refresh()


func check() -> void:
	if state != PLAY or main.plants == null:
		return
	if not goal_exists(level):
		refresh()
	elif _goal_met():
		_win()
	elif _stock_left() == 0 and main.plants.live_count() == 0:
		_lose()
	else:
		refresh()


func _process(delta: float) -> void:
	if _note_left > 0.0:
		_note_left -= delta
		if _note_left <= 0.0:
			_note = ""
			refresh()
	if state != PLAY:
		return
	_check_in -= delta
	if _check_in > 0.0:
		return
	_check_in = CHECK_EVERY
	check()


func _goal_count() -> int:
	return main._plant_count(String(level["goal"]["born"]))


func _goal_met() -> bool:
	return _goal_count() >= int(level["goal"].get("count", 1))


func _stock_left() -> int:
	var left := 0
	for id in stock:
		left += maxi(0, int(stock[id]))
	return left


func _win() -> void:
	state = WON
	_passed[String(level["id"])] = true
	if not testing:
		_save_progress()
	refresh()
	_talk(level["talk"]["win"], [["остаться", _talk_close],
		["на свободный остров", leave]])


func _lose() -> void:
	state = LOST
	var touched: bool = main.plants.meet_stats().x > _touch_start
	refresh()
	_talk(level["talk"]["lose_luck" if touched else "lose_apart"],
		[["заново", restart], ["на свободный остров", leave]])


func _play() -> void:
	_talk_close()
	state = PLAY
	_check_in = CHECK_EVERY
	refresh()


func lost_by_luck() -> bool:
	return state == LOST and main.plants.meet_stats().x > _touch_start


func start_level(id: String) -> void:
	Engine.set_meta(META_KEY, id)
	get_tree().reload_current_scene()


func restart() -> void:
	get_tree().reload_current_scene()


func leave() -> void:
	# ПОМЕТКУ НЕ СНИМАЕМ, А ОЧИЩАЕМ. Снятая пометка значит «игра только
	# запущена», и перезапуск сцены тут же вернул бы игрока в уровень; пустая —
	# «он сам ушёл на свободный остров». См. `setup`.
	Engine.set_meta(META_KEY, "")
	get_tree().reload_current_scene()


func _load_progress() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PROGRESS_PATH) != OK or not cfg.has_section("passed"):
		return
	for key in cfg.get_section_keys("passed"):
		_passed[key] = true


func _save_progress() -> void:
	var cfg := ConfigFile.new()
	for key in _passed:
		cfg.set_value("passed", key, true)
	cfg.save(PROGRESS_PATH)


func _label(text: String, size: int, alpha: float) -> Label:
	var label := Label.new()
	label.text = text
	label.modulate = Color(1, 1, 1, alpha)
	label.add_theme_font_size_override("font_size", size * main.ui_scale)
	return label


func build_panel(layer: CanvasLayer) -> void:
	var ui: int = main.ui_scale
	var open: bool = bool(main.menu_open.get("story", true))
	var panel := PanelContainer.new()
	_panel = panel
	panel.add_theme_stylebox_override("panel", main._panel_box(false))
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_right = -12
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	layer.add_child(panel)
	place()
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	panel.add_child(column)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4 * ui)
	column.add_child(head)
	head.add_child(main._icon_button("story"))
	var title_text: String = "Сюжетный режим"
	if active():
		title_text = "Остров %d · %s" % [number(), String(level["name"])]
	var title := _label(title_text, main.UI_FONT_SMALL, 0.5 if not active() else 0.85)
	title.visible = open
	head.add_child(title)
	main.menu_titles["story"] = title
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 0)
	body.visible = open
	column.add_child(body)
	main.menu_bodies["story"] = body
	if active():
		_build_hud(body)
	else:
		_build_list(body)
	refresh()


func _build_list(body: VBoxContainer) -> void:
	for i in range(LevelsData.LEVELS.size()):
		var lv: Dictionary = LevelsData.LEVELS[i]
		var id: String = String(lv["id"])
		var b: Button = main._list_button()
		var text: String = "%d. %s" % [i + 1, String(lv["name"])]
		if not goal_exists(lv):
			text += " — заготовка"
			b.modulate = Color(1, 1, 1, 0.6)
		elif _passed.has(id):
			text += " — пройден"
		b.text = text
		b.tooltip_text = "Начать остров. Несохранённый сад пропадёт" if goal_exists(lv) \
			else "Остров-заготовка: нужного гибрида ещё нет в игре. Посмотреть можно, пройти нельзя"
		b.pressed.connect(_pick_level.bind(id, b, text))
		body.add_child(b)


func _pick_level(id: String, b: Button, text: String) -> void:
	if _armed_again(id, b, text):
		start_level(id)


func _armed_again(key: String, b: Button, text: String) -> bool:
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if now - float(_armed.get(key, -10.0)) < ARM_SECS:
		return true
	_armed[key] = now
	b.text = text + " — точно?" if not text.begins_with(" ") else " точно? "
	get_tree().create_timer(ARM_SECS).timeout.connect(b.set_text.bind(text))
	return false


func _build_hud(body: VBoxContainer) -> void:
	body.add_child(_label("цель: " + String(level.get("goal_text", "")),
		main.UI_FONT_SMALL, 0.9))
	_status = _label("", main.UI_FONT_SMALL, 0.7)
	body.add_child(_status)
	_stock_label = _label("", main.UI_FONT_SMALL, 0.7)
	body.add_child(_stock_label)
	_note_label = _label("", main.UI_FONT_SMALL, 1.0)
	_note_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.55))
	body.add_child(_note_label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", main._chip_gap())
	body.add_child(row)
	var again: Button = main._list_button(main.UI_FONT_SMALL, true)
	again.text = " заново "
	again.tooltip_text = "Начать этот остров сначала"
	again.pressed.connect(func():
		if _armed_again("again", again, " заново "):
			restart())
	row.add_child(again)
	var out: Button = main._list_button(main.UI_FONT_SMALL, true)
	out.text = " выйти "
	out.tooltip_text = "Вернуться на свободный остров"
	out.pressed.connect(func():
		if _armed_again("out", out, " выйти "):
			leave())
	row.add_child(out)


func place() -> void:
	if _panel != null:
		_panel.offset_top = main.head_bottom + 8 * main.ui_scale


func use_level(id: String) -> void:
	level = LevelsData.find(id)


func panel_cleared() -> void:
	_panel = null
	_status = null
	_stock_label = null
	_note_label = null


func refresh() -> void:
	if not active():
		return
	if _status != null:
		_status.text = _status_text()
	if _stock_label != null:
		_stock_label.text = _stock_text()
	if _note_label != null:
		_note_label.text = _note
		_note_label.visible = _note != ""


func _status_text() -> String:
	var born: String = goal_name()
	if not goal_exists(level):
		return "%s ещё нет в игре — остров-заготовка" % born
	if state == WON:
		return "%s есть — остров пройден" % born
	if state == LOST:
		return "сад замер, а %s не родился" % born
	if main.plants != null and state == PLAY and _stock_left() == 0:
		return "%s пока нет · сад растёт" % born
	return "%s пока нет" % born


func _stock_text() -> String:
	var parts: Array = []
	for id in level.get("stock", {}):
		parts.append("%s ×%d" % [String(PlantsData.ITEMS[id]["name"]).to_lower(),
			int(stock.get(id, level["stock"][id]))])
	return "семена: " + " · ".join(parts)


func _talk(lines: Array, end: Array) -> void:
	_talk_lines = lines
	_talk_page = 0
	_talk_end = end
	if testing:
		return
	_talk_build()


func _talk_build() -> void:
	_talk_drop()
	var ui: int = main.ui_scale
	_talk_layer = CanvasLayer.new()
	_talk_layer.layer = 2
	main.add_child(_talk_layer)
	var screen: Vector2 = main.get_viewport().get_visible_rect().size
	var gap: float = 12.0 * float(ui)
	var left: float = 12.0
	var right: float = screen.x - 12.0
	var under: float = 0.0
	if main.toolbar_panel != null:
		var tools: Vector2 = main.toolbar_panel.get_combined_minimum_size()
		left += tools.x
		under = maxf(under, tools.y)
	if main.time_panel != null:
		var clock: Vector2 = main.time_panel.get_combined_minimum_size()
		right -= clock.x
		under = maxf(under, clock.y)
	var wide: float = minf(36.0 * float(main.UI_FONT * ui), screen.x - 24.0)
	var room: float = right - left - 2.0 * gap
	var centre: float = screen.x * 0.5
	var lift: float = 12.0
	if room >= minf(wide, 22.0 * float(main.UI_FONT * ui)):
		wide = minf(wide, room)
		centre = (left + right) * 0.5
	else:
		lift += under + gap
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.06, 0.08, 0.07, 0.82)
	box.content_margin_left = 12 * ui
	box.content_margin_right = 12 * ui
	box.content_margin_top = 9 * ui
	box.content_margin_bottom = 9 * ui
	box.corner_radius_top_left = 10
	box.corner_radius_top_right = 10
	box.corner_radius_bottom_left = 10
	box.corner_radius_bottom_right = 10
	var panel := PanelContainer.new()
	_talk_panel = panel
	panel.add_theme_stylebox_override("panel", box)
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = centre - wide * 0.5
	panel.offset_right = centre + wide * 0.5
	panel.offset_bottom = -lift
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_talk_layer.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6 * ui)
	panel.add_child(column)
	var who := _label(LevelsData.COMPANION, main.UI_FONT_SMALL, 1.0)
	who.add_theme_color_override("font_color", Color(0.72, 0.92, 0.55))
	column.add_child(who)
	var text := _label(String(_talk_lines[_talk_page]), main.UI_FONT + 1, 1.0)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.custom_minimum_size = Vector2(wide - 24.0 * float(ui), 0.0)
	column.add_child(text)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 6 * ui)
	column.add_child(row)
	if _talk_page < _talk_lines.size() - 1:
		row.add_child(_talk_button("дальше", _talk_next))
	else:
		for pair in _talk_end:
			row.add_child(_talk_button(String(pair[0]), pair[1]))


func _talk_button(text: String, act: Callable) -> Button:
	var b: Button = main._list_button(main.UI_FONT, false)
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.add_theme_stylebox_override("normal", main._chip_box(0.10))
	b.add_theme_stylebox_override("hover", main._chip_box(0.20))
	b.add_theme_stylebox_override("pressed", main._chip_box(0.26))
	b.text = " %s " % text
	b.pressed.connect(act)
	return b


func _talk_next() -> void:
	_talk_page = mini(_talk_page + 1, _talk_lines.size() - 1)
	_talk_build()


func _talk_close() -> void:
	_talk_drop()


func _talk_drop() -> void:
	if _talk_layer != null:
		_talk_layer.visible = false
		_talk_layer.queue_free()
	_talk_layer = null
	_talk_panel = null


func talk_rect() -> Rect2:
	return _talk_panel.get_global_rect() if _talk_panel != null else Rect2()


func panel_rect() -> Rect2:
	return _panel.get_global_rect() if _panel != null else Rect2()


func refit() -> void:
	if _talk_layer != null:
		_talk_build()
