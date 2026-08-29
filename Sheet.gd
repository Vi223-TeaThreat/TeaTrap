extends SceneTree
# =============================================================================
#  ВЫЛОЖИТЬ ЛИСТ С КАРТИНКАМИ — ТО, ЧТО РИСУЕТ КОД СЕЙЧАС.
#
#  Заглушки всех особых столбцов (тело мха, кора и листья лианы) рисует код, и
#  рисует их каждый запуск заново, в память. Художнику это без толку: рисовать
#  надо ПОВЕРХ, в Aseprite, а для этого картинка нужна файлом.
#
#  Здесь она и выкладывается. Три файла, все в `art/`:
#
#    moss_base.png ... сам лист, точка в точку как в игре. По нему и рисовать.
#    moss_grid.png ... одни линии клеток, прозрачный фон. Втягивается в Aseprite
#                      отдельным слоем и выключается глазом.
#    moss_zoom.png ... тот же лист, увеличенный впятеро. ТОЛЬКО СМОТРЕТЬ:
#                      рисовать по нему нельзя, в игру он не идёт.
#
#  ПОЧЕМУ ОТДЕЛЬНЫЙ СКРИПТ, А НЕ КЛЮЧ У ИГРЫ. Дело разовое и к игре отношения не
#  имеет: ей эти файлы не нужны вовсе, их читает только человек. Заводить ради
#  этого ветку в запуске игры — значит держать в горячем месте код, который
#  сработает раз в месяц.
#
#  Запуск:
#    godot --headless --path E:\vi\pilot --script res://Sheet.gd
#
#  ЛИСТ БЕРЁТСЯ РОВНО ТОТ, ЧТО ПОЙДЁТ В ИГРУ: если `art/moss.png` уже нарисован,
#  недостающие столбцы дорисуются к нему — то есть в `moss_base.png` окажется
#  своя работа плюс заглушки. Так и надо: рисовать дальше удобнее по своему же.
# =============================================================================

const Plants = preload("res://SpacePlants.gd")

const ZOOM: int = 5
const GRID_LINE := Color(1.0, 0.3, 0.3, 0.55)


func _init() -> void:
	var plants := Plants.new()
	var sheet: Texture2D = plants._blade_texture()
	var img: Image = sheet.get_image()
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var wide: int = img.get_width()
	var high: int = img.get_height()
	_save(img, "res://art/moss_base.png")

	# Линии клеток — отдельным слоем, чтобы не мешали рисовать.
	var grid := Image.create(wide, high, false, Image.FORMAT_RGBA8)
	grid.fill(Color(0, 0, 0, 0))
	for x in range(0, wide, Plants.TILE):
		for y in range(high):
			grid.set_pixel(x, y, GRID_LINE)
	for y in range(0, high, Plants.TILE):
		for x in range(wide):
			grid.set_pixel(x, y, GRID_LINE)
	_save(grid, "res://art/moss_grid.png")

	# Увеличенный — просто чтобы разглядеть, что вышло у кода.
	var zoom := Image.create(wide * ZOOM, high * ZOOM, false, Image.FORMAT_RGBA8)
	for y in range(high * ZOOM):
		for x in range(wide * ZOOM):
			zoom.set_pixel(x, y, img.get_pixel(x / ZOOM, y / ZOOM))
	_save(zoom, "res://art/moss_zoom.png")

	print("Лист: ", wide, "×", high, " точек — ", Plants.COLS, " столбцов на ",
		Plants.STAGES, " возрастов, клетка ", Plants.TILE)
	print("Столбцы слева направо: ", Plants.KINDS,
		" разновидности куртинки мха, тело мха, кора лианы, лист лианы ×",
		Plants.LEAF_KINDS, ", ЛЕПЕСТОК цветка лианы ×", Plants.BLOOM_KINDS,
		" (цветок складывается из шести таких), тело лиамоха, ворсинка лиамоха")
	plants.free()
	quit()


func _save(img: Image, path: String) -> void:
	var err: int = img.save_png(ProjectSettings.globalize_path(path))
	print(path, " — ", "выложен" if err == OK else "НЕ ВЫЛОЖЕН, ошибка %d" % err)
