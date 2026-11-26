extends Node
## Atomic JSON save service for Aurora OS / Sailjail (autoload).
##
## Canonical install path — copy `modules/save_service.gd` into the game at
## `res://scripts/aurora/save_service.gd` and register the autoload:
##
##   [autoload]
##   SaveService="*res://scripts/aurora/save_service.gd"
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
##     is killed mid-write, so data goes to `<slot>.json.tmp`, is flushed,
##     closed and then renamed over the target with
##     `DirAccess.rename_absolute()`. On POSIX `rename()` replaces the target
##     atomically, so a reader never sees a half-written file. If the rename
##     fails the write is reported as failed — there is deliberately no
##     non-atomic fallback;
##   * `load_slot()` restores a slot from a leftover `.json.tmp` when the main
##     file is missing or corrupted, using the same atomic rename;
##   * the JSON envelope is versioned, so a format change can migrate old saves
##     instead of silently misreading them.
##
## JSON caveats (Godot 4):
##   * every JSON number is a float, so an `int` written to a save comes back as
##     `float`: use `int(data["level"])` before arithmetic or comparisons with
##     integers;
##   * `Vector2`, `Vector2i`, `Color`, `Rect2` are not JSON types: they are
##     written as strings by `JSON.stringify()` and are NOT restored as typed
##     values. Store them as arrays/dictionaries (`[x, y]`, `"#rrggbb"`) or use
##     `var_to_str()` / `str_to_var()` for whole values;
##   * dictionary keys must be strings, and key order is whatever the source
##     dictionary had — do not rely on it;
##   * `null`, `true`, `false`, nested dictionaries and arrays round-trip fine.
##
## The service avoids autoload/global identifiers, so it is safe in
## `--headless --script` test runs.

const DEFAULT_SAVE_DIR := "user://saves"
const FORMAT_VERSION := 1
## Maximum length of the generated slot file name (slug + hash suffix).
const MAX_SLOT_LENGTH := 48
## Length of the deterministic hash suffix that keeps slug collisions apart.
const SLOT_HASH_LENGTH := 8

## Cyrillic -> Latin table used by `normalize_slot()` (ru + uk + be).
const _TRANSLIT := {
	"а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
	"ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
	"н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
	"ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
	"ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
	"і": "i", "ї": "yi", "є": "ye", "ґ": "g", "ў": "u",
}

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
	return _write_envelope(normalized, data, format_version, slot)


## Loads the payload for `slot`; returns an empty Dictionary when absent,
## invalid or of an unmigrated version. Inspect `last_error` to distinguish
## the cases.
##
## When the version stored in the file differs from `expected_version` and a
## valid `migrate` callable is given, `migrate.call(saved_version, raw_data)` is
## invoked. If it returns a Dictionary, that value is written back as
## `expected_version` and returned; otherwise the load fails like before.
func load_slot(
	slot: String = "default",
	expected_version: int = FORMAT_VERSION,
	migrate: Callable = Callable(),
) -> Dictionary:
	last_error = ""
	var normalized := normalize_slot(slot)
	var path := _slot_file(normalized)
	var envelope: Variant = null
	if FileAccess.file_exists(path):
		envelope = _parse_file(path)
		if envelope == null:
			last_error = "invalid JSON in %s" % path
	if envelope == null:
		envelope = _restore_from_tmp(path, normalized)
	if not (envelope is Dictionary):
		return {}
	return _unwrap(envelope as Dictionary, normalized, expected_version, migrate)


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
	if dir.file_exists(file):
		var err := dir.remove(file)
		if err != OK:
			last_error = "remove failed (%d)" % err
			return false
	var tmp := file + ".tmp"
	if dir.file_exists(tmp):
		dir.remove(tmp)
	return true


## All known slot names. For saves written by this version, the original name is
## returned and can be passed back to `load_slot()`/`has_slot()`/`erase_slot()`.
## Old or corrupt files fall back to the normalized file stem.
func list_slots() -> PackedStringArray:
	var result := PackedStringArray()
	if not _ensure_dir():
		return result
	for file in DirAccess.get_files_at(save_dir):
		if not file.ends_with(".json"):
			continue
		var parsed: Variant = _parse_file(save_dir.path_join(file))
		if parsed is Dictionary:
			var stored := str((parsed as Dictionary).get("slot", ""))
			if not stored.is_empty():
				result.append(stored)
				continue
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


## Normalizes a slot name into a safe file name.
##
## * empty names become "default" (unhashed, so the classic
##   `user://saves/default.json` keeps working);
## * Cyrillic is transliterated to Latin, everything outside `[a-z0-9_]`
##   collapses into a single `_`, giving a readable slug;
## * a deterministic 8-character `sha256_text()` prefix of the original name is
##   appended, so names with the same slug (for example "слот" and "slot") never
##   collide and never overwrite each other.
func normalize_slot(slot: String) -> String:
	var source := slot.strip_edges()
	if source.is_empty() or source.to_lower() == "default":
		return "default"
	var slug := ""
	for i in source.length():
		slug += _slug_char(source[i].to_lower())
	# Collapse separator runs so "a  b", "a--b" and "a__b" read the same.
	while slug.contains("__"):
		slug = slug.replace("__", "_")
	slug = slug.trim_prefix("_").trim_suffix("_")
	if slug.is_empty():
		slug = "slot"
	var room := maxi(1, MAX_SLOT_LENGTH - SLOT_HASH_LENGTH - 1)
	slug = slug.substr(0, room).trim_suffix("_")
	return "%s_%s" % [slug, source.sha256_text().substr(0, SLOT_HASH_LENGTH)]


func _slug_char(ch: String) -> String:
	if _TRANSLIT.has(ch):
		return _TRANSLIT[ch]
	if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
		return ch
	return "_"


func _slot_file(slot: String) -> String:
	return "%s/%s.json" % [save_dir.trim_suffix("/"), slot]


## Ensures the save directory exists. Never clears `last_error` on success so a
## previous operation error is not lost.
func _ensure_dir() -> bool:
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


func _write_envelope(normalized: String, data: Dictionary, version: int, source_slot: String = "") -> bool:
	var slot_name := source_slot.strip_edges()
	if slot_name.is_empty():
		slot_name = normalized
	var envelope := {
		"version": version,
		"slot": slot_name,
		"saved_at": Time.get_datetime_string_from_system(true),
		"data": data.duplicate(true),
	}
	return _write_json(_slot_file(normalized), envelope)


## Writes `envelope` to `path` through `path + ".tmp"` and an atomic rename.
## Returns false (without touching the previous file) when the rename fails.
func _write_json(path: String, envelope: Dictionary) -> bool:
	if not _ensure_dir():
		return false
	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		last_error = "cannot write %s (error %d)" % [tmp_path, FileAccess.get_open_error()]
		return false
	file.store_string(JSON.stringify(envelope, "\t"))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(tmp_path)
		last_error = "write failed for %s (error %d)" % [tmp_path, write_error]
		return false

	# POSIX rename() replaces the target atomically, so no remove first.
	var err := DirAccess.rename_absolute(tmp_path, path)
	if err != OK:
		# Keep the .tmp: `load_slot()` can still recover it.
		last_error = "atomic rename %s -> %s failed (error %d)" % [tmp_path, path, err]
		return false
	return true


## Tries to restore the main file from a leftover `.json.tmp` (valid JSON only).
func _restore_from_tmp(path: String, normalized: String) -> Variant:
	var main_error := last_error
	var tmp_path := path + ".tmp"
	if not FileAccess.file_exists(tmp_path):
		if main_error.is_empty():
			last_error = "no save in slot '%s'" % normalized
		return null
	var parsed: Variant = _parse_file(tmp_path)
	if not (parsed is Dictionary):
		if main_error.is_empty():
			last_error = "invalid temporary save for slot '%s'" % normalized
		else:
			last_error = "%s; temporary copy is invalid too" % main_error
		return null
	var err := DirAccess.rename_absolute(tmp_path, path)
	if err != OK:
		last_error = "cannot restore slot '%s' (rename error %d)" % [normalized, err]
		return null
	last_error = ""
	return parsed


## Validates the envelope and applies version migration.
func _unwrap(
	envelope: Dictionary,
	normalized: String,
	expected_version: int,
	migrate: Callable,
) -> Dictionary:
	var saved_version := int(envelope.get("version", 0))
	var raw: Variant = envelope.get("data", {})
	if saved_version != expected_version:
		if not migrate.is_valid():
			last_error = "unsupported save version %s in '%s'" % [
				str(envelope.get("version", "?")), normalized
			]
			return {}
		var payload: Variant = raw
		if raw is Dictionary:
			payload = (raw as Dictionary).duplicate(true)
		var migrated: Variant = migrate.call(saved_version, payload)
		if not (migrated is Dictionary):
			last_error = "migration of slot '%s' returned no Dictionary" % normalized
			return {}
		var migrated_data := migrated as Dictionary
		if not _write_envelope(normalized, migrated_data, expected_version, str(envelope.get("slot", ""))):
			return {}
		return migrated_data.duplicate(true)
	if not (raw is Dictionary):
		last_error = "save '%s' has no data dictionary" % normalized
		return {}
	return (raw as Dictionary).duplicate(true)


## Reads and parses a JSON file. Returns null when it is missing or invalid.
func _parse_file(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	file.close()
	if text.strip_edges().is_empty():
		return null
	return JSON.parse_string(text)
