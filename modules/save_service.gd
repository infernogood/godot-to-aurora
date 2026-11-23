extends Node
## Atomic JSON save service for Aurora OS / Sailjail (autoload candidate).
##
## Register it in project.godot:
##
##   [autoload]
##   SaveService="*res://godot-to-aurora/modules/save_service.gd"
##
## Then:
##
##   SaveService.save("default", {"level": 3, "score": 1200})
##   var data := SaveService.load_slot("default")
##   SaveService.erase_slot("default")
##
## Why this module exists:
##   * under Sailjail only `user://` is writable; `res://` lives in
##     `/usr/share/<package>/` and is read-only;
##   * on the device `user://` resolves to
##     `~/.local/share/<organization>/<application>/`, so saves need no
##     additional Permissions entry in the .desktop file;
##   * writing straight to the final file can leave a truncated JSON if the app
##     is killed mid-write, so data is written to `<slot>.json.tmp`, flushed and
##     renamed over the target, with a direct-write fallback for filesystems
##     that do not support rename;
##   * the JSON envelope is versioned, so a future format change can migrate
##     instead of silently misreading old saves.
##
## The service avoids autoload/global identifiers, so it is safe in
## `--headless --script` test runs.

const DEFAULT_SAVE_DIR := "user://saves"
const FORMAT_VERSION := 1
const MAX_SLOT_LENGTH := 48

## Directory for all slots. Must stay under `user://` for Aurora OS.
@export var save_dir: String = DEFAULT_SAVE_DIR
## Envelope version; bump when the payload schema changes incompatibly.
@export var format_version: int = FORMAT_VERSION

var last_error: String = ""


func _ready() -> void:
	_ensure_dir()


## Writes `data` to `slot` atomically. Returns true on success.
func save(slot: String, data: Dictionary) -> bool:
	last_error = ""
	var normalized := normalize_slot(slot)
	if not _ensure_dir():
		return false
	var envelope := {
		"version": format_version,
		"slot": normalized,
		"saved_at": Time.get_datetime_string_from_system(true),
		"data": data.duplicate(true),
	}
	return _write_json(_slot_file(normalized), envelope)


## Loads the payload for `slot`; returns an empty Dictionary when absent or
## invalid. Inspect `last_error` to distinguish the two.
func load_slot(slot: String) -> Dictionary:
	last_error = ""
	var normalized := normalize_slot(slot)
	var path := _slot_file(normalized)
	if not FileAccess.file_exists(path):
		last_error = "no save in slot '%s'" % normalized
		return {}
	var envelope := _read_json(path)
	if envelope.is_empty():
		return {}
	if int(envelope.get("version", 0)) != format_version:
		last_error = "unsupported save version %s in '%s'" % [
			str(envelope.get("version", "?")), normalized
		]
		return {}
	var data: Variant = envelope.get("data", {})
	if not (data is Dictionary):
		last_error = "save '%s' has no data dictionary" % normalized
		return {}
	return (data as Dictionary).duplicate(true)


func has_slot(slot: String) -> bool:
	return FileAccess.file_exists(_slot_file(normalize_slot(slot)))


## Removes one slot. Returns true if a file was removed (or nothing existed).
func erase_slot(slot: String) -> bool:
	last_error = ""
	var normalized := normalize_slot(slot)
	if not _ensure_dir():
		return false
	var dir := DirAccess.open(save_dir)
	if dir == null:
		last_error = "cannot open %s" % save_dir
		return false
	var file := normalized + ".json"
	var tmp := file + ".tmp"
	if dir.file_exists(file):
		var err := dir.remove(file)
		if err != OK:
			last_error = "remove failed (%d)" % err
			return false
	if dir.file_exists(tmp):
		dir.remove(tmp)
	return true


## All known slot names, sorted.
func list_slots() -> PackedStringArray:
	var result := PackedStringArray()
	if not _ensure_dir():
		return result
	for file in DirAccess.get_files_at(save_dir):
		if file.ends_with(".json"):
			result.append(file.trim_suffix(".json"))
	result.sort()
	return result


## Removes every slot and temporary file.
func clear_all() -> void:
	if not _ensure_dir():
		return
	var dir := DirAccess.open(save_dir)
	if dir == null:
		return
	for file in dir.get_files():
		if file.ends_with(".json") or file.ends_with(".json.tmp"):
			dir.remove(file)
	last_error = ""


## Absolute path of a slot, for logs and tests.
func slot_path(slot: String) -> String:
	return ProjectSettings.globalize_path(_slot_file(normalize_slot(slot)))


## Normalizes a slot name into a safe file name; empty names become "default".
func normalize_slot(slot: String) -> String:
	var source := slot.strip_edges().to_lower()
	var out := ""
	for i in source.length():
		var ch := source[i]
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-":
			out += ch
		elif ch == " " or ch == "." or ch == "/":
			if not out.ends_with("_"):
				out += "_"
	if out.is_empty():
		return "default"
	return out.substr(0, MAX_SLOT_LENGTH).trim_suffix("_")


func _slot_file(slot: String) -> String:
	return "%s/%s.json" % [save_dir.trim_suffix("/"), slot]


func _ensure_dir() -> bool:
	last_error = ""
	if not save_dir.begins_with("user://"):
		last_error = "save_dir must be under user:// (Sailjail allows only user:// writes)"
		return false
	var relative := save_dir.trim_prefix("user://").trim_suffix("/")
	var root := DirAccess.open("user://")
	if root == null:
		last_error = "cannot open user://"
		return false
	if relative.is_empty() or root.dir_exists(relative):
		return true
	var err := root.make_dir_recursive(relative)
	if err != OK:
		last_error = "cannot create %s (error %d)" % [save_dir, err]
		return false
	return true


func _write_json(path: String, envelope: Dictionary) -> bool:
	if not _ensure_dir():
		return false
	var file_name := path.get_file()
	var tmp_name := file_name + ".tmp"
	var tmp_path := "%s/%s" % [save_dir.trim_suffix("/"), tmp_name]
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		last_error = "cannot write %s (error %d)" % [tmp_path, FileAccess.get_open_error()]
		return false
	file.store_string(JSON.stringify(envelope, "\t"))
	file.flush()
	file.close()

	var dir := DirAccess.open(save_dir)
	if dir == null:
		last_error = "cannot open %s" % save_dir
		return false
	if dir.file_exists(file_name):
		dir.remove(file_name)
	var err := dir.rename(tmp_name, file_name)
	if err == OK:
		return true

	# Fallback for filesystems where rename across handles is unsupported.
	var direct := FileAccess.open(path, FileAccess.WRITE)
	if direct == null:
		last_error = "rename failed (%d) and direct write failed" % err
		return false
	direct.store_string(JSON.stringify(envelope, "\t"))
	direct.flush()
	direct.close()
	if dir.file_exists(tmp_name):
		dir.remove(tmp_name)
	return true


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		last_error = "cannot read %s (error %d)" % [path, FileAccess.get_open_error()]
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		last_error = "invalid JSON in %s" % path
		return {}
	return parsed as Dictionary
