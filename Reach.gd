extends SceneTree
# =============================================================================
#  ПРОВЕРКА ДОСТИЖИМОСТИ. Что написано, но никем не вызывается.
#
#  За одну сессию в проекте нашлось ТРИ таких места, и каждое обнаружилось
#  случайно, спустя дни:
#
#    огранка камня — вызывалась только из пересчёта поля, а тот только из
#      `stroke_many`, которого не звал никто. Камень отличался от земли одним
#      цветом, и это выглядело как «так и задумано»;
#    впадины — считались, но в поверхность клалась постоянная, и треть облика
#      камня молча умножалась на ноль;
#    растения — целиком, вместе с половиной игры.
#
#  Такое не ловится ни проверкой целостности, ни глазами: код есть, ошибок нет,
#  просто он никогда не выполняется. Обход «кто кого зовёт» находит это за
#  секунду.
#
#  Запуск:
#    godot --headless --path E:\vi\pilot --script res://Reach.gd
#
#  ЧЕГО ЖДАТЬ. Пустой список — норма. Всё, что нашлось, надо либо подключить,
#  либо удалить: третьего не бывает. Ложные срабатывания возможны там, где имя
#  собирается из строк (`call("имя")`) — таких мест в проекте нет.
#
#  ЕСЛИ НЕДОСТИЖИМОСТЬ НАМЕРЕННА, это помечается В САМОМ КОДЕ, а не списком
#  исключений здесь: список исключений живёт отдельно от кода и врёт первым.
#
#    `ФАЙЛ ЖДЁТ ПЕРЕЕЗДА` в шапке файла — весь файл пока не подключён;
#    `ЖДЁТ ПОДКЛЮЧЕНИЯ` в комментарии над функцией — эта функция написана
#      заранее и ещё не позвана.
#
#  Обе пометки должны нести объяснение рядом: чего именно ждёт и почему.
# =============================================================================

# Обработчики движка: их зовёт он сам, по имени, и в коде их не найти.
const ENGINE_CALLS := [
	"_init", "_ready", "_enter_tree", "_exit_tree", "_process",
	"_physics_process", "_input", "_unhandled_input", "_unhandled_key_input",
	"_shortcut_input", "_notification", "_draw", "_gui_input", "_to_string",
	"_get", "_set", "_get_property_list", "_validate_property",
]
# Точки входа шейдера: их тоже зовёт движок.
const SHADER_ENTRIES := ["vertex", "fragment", "light", "start", "process", "sky", "fog"]

const PARKED_FILE := "ФАЙЛ ЖДЁТ ПЕРЕЕЗДА"
const PARKED_FUNC := "ЖДЁТ ПОДКЛЮЧЕНИЯ"


# Файл целиком отложен — его содержимое не разбираем.
func _parked(text: String) -> bool:
	var lines: PackedStringArray = text.split("\n")
	for i in range(mini(40, lines.size())):
		if lines[i].contains(PARKED_FILE):
			return true
	return false


# Над объявлением стоит пометка «ждёт подключения». Смотрим ВЕСЬ комментарий
# над ним, сколько бы строк тот ни занимал: пометка требует объяснения, а
# объяснение в три строки не всегда влезает — и считать строки было бы правилом
# на пустом месте.
func _marked(lines: PackedStringArray, at: int) -> bool:
	var i: int = at - 1
	while i >= 0:
		var bare: String = lines[i].strip_edges()
		if bare.is_empty() or bare.begins_with("#"):
			if bare.contains(PARKED_FUNC):
				return true
			i -= 1
			continue
		return false
	return false


func _init() -> void:
	var scripts: Array = _files("res://", ".gd")
	var shaders: Array = _files("res://", ".gdshader")
	# Сам себя из обхода исключаем: этот файл запускают руками, и его `_init`
	# в коде проекта, разумеется, никто не зовёт.
	scripts.erase("res://Reach.gd")

	var body: Dictionary = {}
	for f in scripts + shaders:
		body[f] = FileAccess.get_file_as_string(f)

	var lost_funcs: Array = _unused_functions(scripts, body)
	var lost_shader: Array = _unused_shader_functions(shaders, body)
	var lost_consts: Array = _unused_constants(scripts, body)

	print("Проверка достижимости: файлов ", scripts.size(), " + шейдеров ",
		shaders.size())
	_report("Функции, которых никто не зовёт", lost_funcs)
	_report("Функции шейдеров, которых никто не зовёт", lost_shader)
	_report("Постоянные, которых никто не читает", lost_consts)
	var total: int = lost_funcs.size() + lost_shader.size() + lost_consts.size()
	print("Всего недостижимого: ", total)
	quit(0 if total == 0 else 1)


func _report(title: String, found: Array) -> void:
	if found.is_empty():
		print("  ", title, " — нет")
		return
	print("  ", title, ":")
	for item in found:
		print("      ", item)


# --- Разбор -------------------------------------------------------------------
func _files(dir: String, suffix: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for name in d.get_files():
		if name.ends_with(suffix):
			out.append(dir.path_join(name))
	for sub in d.get_directories():
		if sub.begins_with("."):
			continue
		out += _files(dir.path_join(sub), suffix)
	return out


# Имя считается достижимым, если встречается ГДЕ-ТО ЕЩЁ, кроме своей строки
# объявления. Ищем по границам слова, иначе `_facet` нашёлся бы внутри
# `_facet_amp` и всё выглядело бы благополучно.
func _mentions_outside(word: String, body: Dictionary, own_file: String,
		own_line: int) -> int:
	var re := RegEx.new()
	re.compile("\\b" + word + "\\b")
	var count := 0
	for f in body:
		var lines: PackedStringArray = String(body[f]).split("\n")
		for i in range(lines.size()):
			if f == own_file and i == own_line:
				continue
			var line: String = lines[i]
			# Упоминание в комментарии — не вызов. Иначе описание в шапке файла
			# выдавало бы мёртвую функцию за живую.
			var bare: String = line.strip_edges()
			if bare.begins_with("#") or bare.begins_with("//"):
				continue
			count += re.search_all(line).size()
	return count


func _unused_functions(scripts: Array, body: Dictionary) -> Array:
	var out: Array = []
	var re := RegEx.new()
	re.compile("^\\s*(static\\s+)?func\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
	for f in scripts:
		if _parked(String(body[f])):
			continue
		var lines: PackedStringArray = String(body[f]).split("\n")
		for i in range(lines.size()):
			var m := re.search(lines[i])
			if m == null:
				continue
			var name: String = m.get_string(2)
			if name in ENGINE_CALLS or _marked(lines, i):
				continue
			if _mentions_outside(name, body, f, i) == 0:
				out.append("%s:%d  %s()" % [f.get_file(), i + 1, name])
	return out


func _unused_shader_functions(shaders: Array, body: Dictionary) -> Array:
	var out: Array = []
	var re := RegEx.new()
	# `float имя(`, `vec3 имя(` и прочее в начале строки.
	re.compile("^(void|bool|int|uint|float|vec2|vec3|vec4|mat2|mat3|mat4)\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
	for f in shaders:
		var lines: PackedStringArray = String(body[f]).split("\n")
		for i in range(lines.size()):
			var m := re.search(lines[i])
			if m == null:
				continue
			var name: String = m.get_string(2)
			if name in SHADER_ENTRIES:
				continue
			if _mentions_outside(name, body, f, i) == 0:
				out.append("%s:%d  %s()" % [f.get_file(), i + 1, name])
	return out


func _unused_constants(scripts: Array, body: Dictionary) -> Array:
	var out: Array = []
	var re := RegEx.new()
	re.compile("^const\\s+([A-Za-z_][A-Za-z0-9_]*)")
	for f in scripts:
		if _parked(String(body[f])):
			continue
		var lines: PackedStringArray = String(body[f]).split("\n")
		for i in range(lines.size()):
			var m := re.search(lines[i])
			if m == null:
				continue
			var name: String = m.get_string(1)
			if _marked(lines, i):
				continue
			if _mentions_outside(name, body, f, i) == 0:
				out.append("%s:%d  %s" % [f.get_file(), i + 1, name])
	return out
