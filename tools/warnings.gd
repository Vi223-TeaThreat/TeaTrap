extends SceneTree
# =============================================================================
#  СПИСОК ПРЕДУПРЕЖДЕНИЙ GODOT — спрашиваем у открытого редактора.
#
#  ЗАЧЕМ ОТДЕЛЬНЫЙ ПРИБОР. Предупреждения (затенённые имена, деление нацело,
#  никем не читаемая переменная) рождаются только у разборщика в редакторе и
#  уходят прямо в его отладчик. Ни `--check-only`, ни запущенная игра о них не
#  говорят ни слова: первый показывает только ОШИБКИ разбора, вторая молчит.
#  Оттого они и копятся незамеченными, пока панель отладчика не встретит запуск
#  списком в полсотни строк.
#
#  КАК СПРАШИВАЕМ. У редактора есть служебный порт 6005 — языковой сервер, тот
#  же, каким пользуются внешние редакторы кода. Подключаемся, отдаём каждый файл
#  и слушаем ответ. Файл отдаётся ДВАЖДЫ (`didOpen`, следом `didChange` тем же
#  текстом): на первый редактор может ответить по своей памяти, а она бывает
#  старее того, что лежит на диске.
#
#  Запуск — при ОТКРЫТОМ редакторе с этим проектом:
#    godot --headless --path E:\vi\pilot --script res://tools/warnings.gd
#
#  Пусто — значит, предупреждений нет ни одного.
# =============================================================================

const PORT: int = 6005

var _peer := StreamPeerTCP.new()
var _buf := PackedByteArray()
var _root := ""
var _seen := {}


func _init() -> void:
	_root = ProjectSettings.globalize_path("res://").rstrip("/")
	var files := _scripts()
	if files.is_empty():
		print("Скриптов не нашлось — проверять нечего")
		quit()
		return
	if _peer.connect_to_host("127.0.0.1", PORT) != OK:
		print("Не выходит подключиться к редактору (порт ", PORT, ")")
		quit()
		return
	var began := Time.get_ticks_msec()
	while _peer.get_status() == StreamPeerTCP.STATUS_CONNECTING \
			and Time.get_ticks_msec() - began < 3000:
		_peer.poll()
		OS.delay_msec(20)
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		print("Редактор не отвечает на порту ", PORT,
			" — открыт ли он с этим проектом?")
		quit()
		return

	_send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
		"processId": null, "rootUri": "file:///" + _root, "capabilities": {}}})
	_pump(1500)
	_send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
	_pump(300)
	for f in files:
		var uri := "file:///" + _root + "/" + f
		var text := FileAccess.get_file_as_string("res://" + f)
		_send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
			"textDocument": {"uri": uri, "languageId": "gdscript",
				"version": 1, "text": text}}})
		_pump(400)
		_send({"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {
			"textDocument": {"uri": uri, "version": 2},
			"contentChanges": [{"text": text}]}})
		_pump(1000)
	_pump(2000)
	print("Всего: ", _seen.size(), " (проверено файлов: ", files.size(), ")")
	quit()


# Все скрипты проекта, включая эти же инструменты.
func _scripts() -> PackedStringArray:
	var out := PackedStringArray()
	for name in DirAccess.get_files_at("res://"):
		if name.ends_with(".gd"):
			out.append(name)
	for name in DirAccess.get_files_at("res://tools"):
		if name.ends_with(".gd"):
			out.append("tools/" + name)
	return out


func _send(obj: Dictionary) -> void:
	var body := JSON.stringify(obj).to_utf8_buffer()
	_peer.put_data(("Content-Length: %d\r\n\r\n" % body.size()).to_utf8_buffer())
	_peer.put_data(body)


func _pump(ms: int) -> void:
	var began := Time.get_ticks_msec()
	while Time.get_ticks_msec() - began < ms:
		_peer.poll()
		var waiting := _peer.get_available_bytes()
		if waiting > 0:
			var got: Array = _peer.get_data(waiting)
			if int(got[0]) == OK:
				_buf.append_array(got[1])
		_drain()
		OS.delay_msec(20)


# Ответы идут потоком: сперва заголовок с длиной, за ним столько же байт тела.
func _drain() -> void:
	while true:
		var head_end := _buf.get_string_from_utf8().find("\r\n\r\n")
		if head_end < 0:
			return
		var head := _buf.get_string_from_utf8().substr(0, head_end)
		var length := -1
		for row in head.split("\r\n"):
			if row.to_lower().begins_with("content-length:"):
				length = int(row.split(":")[1].strip_edges())
		if length < 0:
			return
		var skip := (head + "\r\n\r\n").to_utf8_buffer().size()
		if _buf.size() < skip + length:
			return
		_report(_buf.slice(skip, skip + length).get_string_from_utf8())
		_buf = _buf.slice(skip + length)


func _report(body: String) -> void:
	var msg = JSON.parse_string(body)
	if typeof(msg) != TYPE_DICTIONARY:
		return
	if msg.get("method", "") != "textDocument/publishDiagnostics":
		return
	var params: Dictionary = msg["params"]
	var file := String(params.get("uri", "")).get_file()
	for d in params.get("diagnostics", []):
		var row := int(d["range"]["start"]["line"]) + 1
		var kind := "ОШИБКА" if int(d.get("severity", 1)) == 1 else "предупреждение"
		var say := "%s:%d\t%s\t%s" % [file, row, kind,
			String(d.get("message", "")).replace("\n", " ")]
		# Один и тот же файл редактор присылает не единожды — говорим о каждом
		# месте по разу.
		if not _seen.has(say):
			_seen[say] = true
			print(say)
