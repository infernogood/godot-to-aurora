extends SceneTree
## Headless-тесты модулей кита godot-to-aurora.
##
## Запускается через tests/run_modules.sh, который собирает временный
## Godot-проект с каноническими путями (`res://scripts/aurora/*.gd`) и
## вызывает:
##
##   "$GODOT_BIN" --headless --path <fixture> --script res://test_modules.gd
##
## Проверяется только публичное поведение модулей; автозагрузки не создаются,
## скрипты инстанцируются напрямую. Все созданные Node освобождаются, чтобы
## не было утечек ObjectDB. Код возврата 1, если есть провалы.

const SafeArea := preload("res://scripts/aurora/safe_area_helper.gd")
const SaveServiceScript := preload("res://scripts/aurora/save_service.gd")
const LifecycleScript := preload("res://scripts/aurora/aurora_lifecycle.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	print("godot-to-aurora: headless-тесты модулей")
	_test_safe_area()
	_test_save_service()
	_test_lifecycle()
	_test_regressions_111()
	print("")
	print("проверок: %d, провалов: %d" % [_checks, _failures])
	if _failures > 0:
		print("РЕЗУЛЬТАТ: FAIL")
	else:
		print("РЕЗУЛЬТАТ: OK")
	quit(1 if _failures > 0 else 0)


# ---------------------------------------------------------------------------
# Мини-фреймворк
# ---------------------------------------------------------------------------
func _section(title: String) -> void:
	print("")
	print("[%s]" % title)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("  PASS  %s" % message)
	else:
		_failures += 1
		print("  FAIL  %s" % message)


func _check_eq(actual: Variant, expected: Variant, message: String) -> void:
	if actual == expected:
		_check(true, message)
	else:
		_check(false, "%s (ожидалось %s, получено %s)" % [message, str(expected), str(actual)])


func _check_approx(actual: float, expected: float, message: String) -> void:
	if is_equal_approx(actual, expected):
		_check(true, message)
	else:
		_check(false, "%s (ожидалось %f, получено %f)" % [message, expected, actual])


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_check(false, "не удалось открыть на запись %s" % path)
		return
	file.store_string(text)
	file.close()


func _envelope(version: int, slot_name: String, data: Dictionary) -> String:
	return JSON.stringify({"version": version, "slot": slot_name, "data": data}, "\t")


# ---------------------------------------------------------------------------
# AuroraSafeArea
# ---------------------------------------------------------------------------
func _test_safe_area() -> void:
	_section("AuroraSafeArea")

	var fullscreen := SafeArea.compute_insets(
		Vector2(1280.0, 800.0),
		Vector2i(1280, 800),
		Rect2i(0, 40, 1280, 720),
		Vector2i(1280, 800),
	)
	_check(bool(fullscreen.get("valid", false)), "fullscreen: safe area распознана")
	_check_approx(float(fullscreen.get("t", -1.0)), 40.0, "fullscreen: верхний отступ 40")
	_check_approx(float(fullscreen.get("b", -1.0)), 40.0, "fullscreen: нижний отступ 40")
	_check_approx(float(fullscreen.get("l", -1.0)), 0.0, "fullscreen: левый отступ 0")
	_check_approx(float(fullscreen.get("r", -1.0)), 0.0, "fullscreen: правый отступ 0")

	var empty := SafeArea.compute_insets(
		Vector2(1280.0, 800.0),
		Vector2i(1280, 800),
		Rect2i(),
		Vector2i(1280, 800),
	)
	_check(not bool(empty.get("valid", true)), "пустая safe area игнорируется (valid=false)")

	var windowed := SafeArea.compute_insets(
		Vector2(900.0, 700.0),
		Vector2i(900, 700),
		Rect2i(0, 40, 1280, 720),
		Vector2i(1280, 800),
	)
	_check(not bool(windowed.get("valid", true)), "окно 900x700 при экране 1280x800 — windowed (valid=false)")

	_check(
		not SafeArea.looks_windowed(Vector2i(800, 1280), Vector2i(1280, 800)),
		"повёрнутое окно 800x1280 при экране 1280x800 не считается windowed",
	)

	_check_approx(
		SafeArea.ui_scale(Vector2(1280.0, 600.0), Vector2(1280.0, 800.0), 0.0, 10.0),
		0.75,
		"ui_scale берёт minf по осям (0.75, а не 1.0)",
	)
	_check(
		SafeArea.touch_target(1.0, 48.0, 2.0) >= 96.0,
		"touch_target с dp_factor=2.0 даёт не меньше 96 px",
	)


# ---------------------------------------------------------------------------
# SaveService
# ---------------------------------------------------------------------------
func _test_save_service() -> void:
	_section("SaveService")

	var svc := SaveServiceScript.new()
	svc.save_dir = "user://test_saves"
	svc.clear_all()

	# save/load и отсутствие .tmp после успеха.
	_check(svc.save("alpha", {"level": 3, "name": "тест"}), "save() пишет слот")
	var loaded: Dictionary = svc.load_slot("alpha")
	_check_eq(typeof(loaded.get("level", null)), TYPE_FLOAT, "int в JSON читается как float")
	_check_eq(int(loaded.get("level", 0)), 3, "числовое поле сохраняется")
	_check_eq(str(loaded.get("name", "")), "тест", "кириллическая строка сохраняется")
	var alpha_path: String = svc.slot_path("alpha")
	_check(FileAccess.file_exists(alpha_path), "основной файл слота создан")
	_check(not FileAccess.file_exists(alpha_path + ".tmp"), "после успешной записи .tmp нет")
	var listed: PackedStringArray = svc.list_slots()
	_check(listed.has("alpha"), "list_slots возвращает исходное имя слота")
	if listed.has("alpha"):
		var by_listed: Dictionary = svc.load_slot(listed[listed.find("alpha")])
		_check_eq(int(by_listed.get("level", 0)), 3, "имя из list_slots принимается load_slot")

	# Атомарный rename без предварительного remove: цель-каталог не трогаем.
	var dir_slot := "atomic_target"
	var dir_path: String = svc.slot_path(dir_slot)
	_check_eq(
		DirAccess.make_dir_recursive_absolute(dir_path),
		OK,
		"на месте целевого файла создан каталог",
	)
	_check(not svc.save(dir_slot, {"x": 1}), "save() = false, если цель rename — каталог")
	_check(DirAccess.dir_exists_absolute(dir_path), "каталог-цель не удалён перед rename")
	_check(not svc.last_error.is_empty(), "last_error описывает ошибку rename")
	DirAccess.remove_absolute(dir_path)

	# Восстановление из .tmp при отсутствующем основном файле.
	var missing_slot := "recover_missing"
	var missing_main: String = svc.slot_path(missing_slot)
	_write_text(missing_main + ".tmp", _envelope(1, svc.normalize_slot(missing_slot), {"hp": 7}))
	var recovered: Dictionary = svc.load_slot(missing_slot)
	_check_eq(int(recovered.get("hp", 0)), 7, "load_slot восстанавливает слот из .tmp при отсутствии файла")
	_check(FileAccess.file_exists(missing_main), "после восстановления основной файл существует")
	_check(not FileAccess.file_exists(missing_main + ".tmp"), "после восстановления .tmp удалён")

	# Восстановление из .tmp при повреждённом основном файле.
	# Повреждённый JSON печатает ERROR: Parse JSON failed в stderr — это норма.
	var corrupt_slot := "recover_corrupt"
	var corrupt_main: String = svc.slot_path(corrupt_slot)
	_write_text(corrupt_main, "{ это не JSON")
	_write_text(corrupt_main + ".tmp", _envelope(1, svc.normalize_slot(corrupt_slot), {"hp": 9}))
	var restored: Dictionary = svc.load_slot(corrupt_slot)
	_check_eq(int(restored.get("hp", 0)), 9, "load_slot восстанавливает слот из .tmp при повреждённом JSON")
	_check(FileAccess.file_exists(corrupt_main), "после восстановления повреждённый файл заменён")
	_check(not FileAccess.file_exists(corrupt_main + ".tmp"), "после восстановления .tmp удалён")

	# Кириллические и «мусорные» имена слотов не коллизируют.
	var names := ["Игрок", "игрок", "слот", "slot", "!!!", "???"]
	var normalized_seen := {}
	for i in names.size():
		var slot_name: String = names[i]
		_check(svc.save(slot_name, {"index": i, "label": slot_name}), "save() слота '%s'" % slot_name)
		var normalized: String = svc.normalize_slot(slot_name)
		_check(
			not normalized_seen.has(normalized),
			"normalize_slot('%s') уникален (%s)" % [slot_name, normalized],
		)
		normalized_seen[normalized] = true
	for i in names.size():
		var slot_name: String = names[i]
		var data: Dictionary = svc.load_slot(slot_name)
		_check_eq(int(data.get("index", -1)), i, "load_slot('%s') вернул свои данные" % slot_name)
		_check_eq(str(data.get("label", "")), slot_name, "load_slot('%s') не перепутал слоты" % slot_name)

	# Хук миграции: version=0 в файле, миграция до version=1 и перезапись.
	var migration_slot := "migrate_me"
	var migration_main: String = svc.slot_path(migration_slot)
	_write_text(migration_main, _envelope(0, svc.normalize_slot(migration_slot), {"score": 5}))
	var migrator := func(saved_version: int, raw: Dictionary) -> Dictionary:
		_check_eq(saved_version, 0, "migrate получил сохранённую версию 0")
		return {"score": int(raw.get("score", 0)) + 100}
	var migrated: Dictionary = svc.load_slot(migration_slot, 1, migrator)
	_check_eq(int(migrated.get("score", -1)), 105, "migrate вернул мигрированные данные")
	var on_disk := FileAccess.get_file_as_string(migration_main)
	_check(on_disk.contains("\"version\": 1"), "файл перезаписан версией 1")
	var plain: Dictionary = svc.load_slot(migration_slot)
	_check_eq(int(plain.get("score", -1)), 105, "повторный load без migrate читает version=1")

	svc.clear_all()
	svc.free()


# ---------------------------------------------------------------------------
# AuroraLifecycle
# ---------------------------------------------------------------------------
func _test_lifecycle() -> void:
	_section("AuroraLifecycle")

	var life := LifecycleScript.new()
	life.pause_tree_on_suspend = false
	life.mute_audio_on_suspend = false
	_check(not life.pause_on_desktop_focus_loss, "по умолчанию pause_on_desktop_focus_loss=false")

	var events: Array = []
	life.suspended.connect(func(reason: String) -> void: events.append("suspended:" + reason))
	life.resumed.connect(func(reason: String) -> void: events.append("resumed:" + reason))
	life.autosave_requested.connect(func(reason: String) -> void: events.append("autosave:" + reason))
	life.focus_changed.connect(func(focused: bool) -> void: events.append("focus:%s" % focused))

	life._notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_IN)
	_check(life.has_focus, "focus_in выставляет has_focus")
	_check_eq(events.count("focus:true"), 1, "сигнал focus_changed(true)")
	life._notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_check(not life.is_suspended, "потеря фокуса окна не усыпляет игру по умолчанию")
	_check_eq(events.count("focus:false"), 1, "сигнал focus_changed(false)")

	life.suspend("test")
	_check(life.is_suspended, "suspend() выставляет is_suspended")
	_check(events.has("suspended:test"), "сигнал suspended(reason)")
	_check(events.has("autosave:test"), "autosave_requested при request_autosave")
	life.resume_game()
	_check(not life.is_suspended, "resume_game() снимает is_suspended")
	_check(events.has("resumed:manual"), "сигнал resumed")

	# Энергосбережение: Engine.max_fps и OS.low_processor_usage_mode
	# сохраняются на suspend и восстанавливаются на resume.
	Engine.max_fps = 60
	OS.low_processor_usage_mode = false
	life.suspend("power")
	_check_eq(Engine.max_fps, 10, "на suspend Engine.max_fps = 10")
	_check(OS.low_processor_usage_mode, "на suspend низкое энергопотребление включено")
	life.resume_game()
	_check_eq(Engine.max_fps, 60, "на resume Engine.max_fps восстановлен")
	_check(not OS.low_processor_usage_mode, "на resume режим энергосбережения снят")

	# pause_on_desktop_focus_loss=true: потеря фокуса окна усыпляет игру.
	var pausing := LifecycleScript.new()
	pausing.pause_tree_on_suspend = false
	pausing.mute_audio_on_suspend = false
	pausing.pause_on_desktop_focus_loss = true
	pausing._notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_IN)
	pausing._notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_check(pausing.is_suspended, "pause_on_desktop_focus_loss=true усыпляет при потере фокуса")
	pausing.resume_game()
	_check(not pausing.is_suspended, "resume_game() после фокус-аута")
	pausing.free()

	life.free()


# ---------------------------------------------------------------------------
# Регрессии 1.1.1: поведение, добавленное/изменённое код-ревью.
# ---------------------------------------------------------------------------
func _test_regressions_111() -> void:
	_section("SaveService: регрессии 1.1.1")
	var svc := SaveServiceScript.new()
	svc.save_dir = "user://test_saves"

	# load_slot() без аргумента берёт ожидаемую версию из format_version.
	svc.format_version = 2
	_check(svc.save("ver2slot", {"a": 1}), "save() при format_version=2")
	var loaded := svc.load_slot("ver2slot")
	_check_eq(loaded.get("a", 0.0), 1.0, "load_slot() без аргумента читает версию format_version=2")
	var mismatched := svc.load_slot("ver2slot", 1)
	_check(mismatched.is_empty(), "load_slot(expected_version=1) при записи версии 2 — пустой результат")
	_check(svc.last_error != "", "last_error заполнен при несовпадении версии без migrate")
	svc.format_version = 1

	# has_slot() учитывает временный файл слота.
	var tpath: String = svc.slot_path("tmponly") + ".tmp"
	_write_text(tpath, _envelope(1, "tmponly", {"x": 2}))
	_check(svc.has_slot("tmponly"), "has_slot() true при наличии только .json.tmp")
	_check(not FileAccess.file_exists(svc.slot_path("tmponly")), "основной файл слота не создаётся")
	DirAccess.remove_absolute(tpath)

	# Устаревший .tmp не перебивает валидный основной файл.
	_check(svc.save("mainwins", {"a": 1}), "save() слота с основным файлом")
	_write_text(svc.slot_path("mainwins") + ".tmp", _envelope(1, "mainwins", {"a": "stale"}))
	var from_main := svc.load_slot("mainwins")
	_check_eq(from_main.get("a", "stale"), 1.0, "валидный основной файл выигрывает у устаревшего .tmp")
	svc.erase_slot("mainwins")
	DirAccess.remove_absolute(svc.slot_path("mainwins") + ".tmp")

	svc.free()

	_section("AuroraLifecycle: регрессии 1.1.1")
	# В headless нет признаков mobile/auroraos — включается десктопная ветка.
	_check(not OS.has_feature("mobile") and not OS.has_feature("auroraos"), "headless считается десктопом")

	var events := {}
	var life := LifecycleScript.new()
	life.pause_tree_on_suspend = false
	life.mute_audio_on_suspend = false
	life.focus_changed.connect(func(focused: bool) -> void: events["focus"] = focused)
	life._notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	life._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(events.get("focus", true) == false, "APPLICATION_FOCUS_OUT эмитит focus_changed(false)")
	_check(not life.is_suspended, "pause_on_desktop_focus_loss=false: десктоп не паузит APPLICATION_FOCUS_OUT")
	life.free()

	var pausing := LifecycleScript.new()
	pausing.pause_tree_on_suspend = false
	pausing.mute_audio_on_suspend = false
	pausing.pause_on_desktop_focus_loss = true
	pausing._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(pausing.is_suspended, "pause_on_desktop_focus_loss=true: десктоп паузит APPLICATION_FOCUS_OUT")
	pausing.resume_game()
	pausing.free()

	_section("AuroraSafeArea: регрессии 1.1.1")
	var stretch := "display/window/stretch/mode"
	var prev_mode := str(ProjectSettings.get_setting(stretch, "disabled"))

	ProjectSettings.set_setting(stretch, "canvas_items")
	_check_eq(SafeArea.touch_target(2.0, 48.0, 2.0), 96.0, "canvas_items: масштаб применяется канвасом, scale не удваивает (96)")
	ProjectSettings.set_setting(stretch, "disabled")
	_check_eq(SafeArea.touch_target(2.0, 48.0, 2.0), 192.0, "disabled: scale=2 умножает (192)")
	ProjectSettings.set_setting(stretch, prev_mode)

	_check(
		not SafeArea.looks_windowed(Vector2i(800, 1280), Vector2i(800, 1304)),
		"статус-бар 24px не отключает safe area (не «окно»)",
	)
	_check(
		SafeArea.looks_windowed(Vector2i(700, 1280), Vector2i(800, 1280)),
		"заметно меньшее окно — «оконное»",
	)
	var size_w := "display/window/size/viewport_width"
	var size_h := "display/window/size/viewport_height"
	var prev_w: int = ProjectSettings.get_setting(size_w, 1152)
	var prev_h: int = ProjectSettings.get_setting(size_h, 648)
	ProjectSettings.set_setting(size_w, 1280)
	ProjectSettings.set_setting(size_h, 720)
	_check_eq(
		SafeArea.base_viewport_size(),
		Vector2(1280.0, 720.0),
		"base_viewport_size(): читает viewport_width/height из ProjectSettings",
	)
	ProjectSettings.set_setting(size_w, 0)
	ProjectSettings.set_setting(size_h, -5)
	_check_eq(
		SafeArea.base_viewport_size(),
		Vector2(1280.0, 800.0),
		"base_viewport_size(): невалидные значения дают fallback 1280x800",
	)
	ProjectSettings.set_setting(size_w, prev_w)
	ProjectSettings.set_setting(size_h, prev_h)
