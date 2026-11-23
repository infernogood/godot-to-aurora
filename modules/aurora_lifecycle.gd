extends Node
## Aurora OS application-lifecycle helper (autoload candidate).
##
## Register it in project.godot:
##
##   [autoload]
##   AuroraLifecycle="*res://godot-to-aurora/modules/aurora_lifecycle.gd"
##
##   # somewhere in your main scene:
##   func _ready() -> void:
##       AuroraLifecycle.suspended.connect(_on_suspended)
##       AuroraLifecycle.resumed.connect(_on_resumed)
##       AuroraLifecycle.autosave_requested.connect(_save_game)
##
## What it does:
##   * pins the screen orientation from `display/window/handheld/orientation`
##     so the emulator (no accelerometer) and sensor-based settings agree;
##   * pauses the scene tree and mutes the Master bus when the app is
##     backgrounded (notification focus loss / APPLICATION_PAUSED);
##   * ignores FOCUS_OUT that arrives before the first FOCUS_IN, otherwise a
##     game started in the background (or under `--headless --script`) pauses
##     itself immediately;
##   * never unpauses automatically: the player resumes through the game's own
##     "Continue" button, which should call `resume_game()`;
##   * emits `autosave_requested` before the tree is frozen so saving is safe.
##
## The module is self-contained: no autoload lookups at parse time, so it also
## works in headless tests.

signal suspended(reason: String)
signal resumed(reason: String)
signal focus_changed(focused: bool)
signal autosave_requested(reason: String)

## Pause the scene tree while the application is in the background.
@export var pause_tree_on_suspend := true
## Mute the Master audio bus while the application is in the background.
@export var mute_audio_on_suspend := true
## Apply `display/window/handheld/orientation` on startup.
@export var apply_orientation := true
## Emit `autosave_requested` on suspend and on close requests.
@export var request_autosave := true

var is_suspended := false
var has_focus := false

var _seen_focus := false
var _master_was_muted := false
var _orientation := 0


func _ready() -> void:
	# Notifications must still be processed while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_orientation = int(ProjectSettings.get_setting("display/window/handheld/orientation", 0))
	if apply_orientation:
		_apply_orientation()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_WM_WINDOW_FOCUS_IN:
			_on_focus_in()
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			# A window created in the background receives FOCUS_OUT before any
			# FOCUS_IN; pausing there breaks headless runs and background starts.
			if _seen_focus:
				_on_focus_out()
		NOTIFICATION_APPLICATION_PAUSED:
			suspend("app_paused")
		NOTIFICATION_APPLICATION_RESUMED:
			_on_focus_in()
		NOTIFICATION_WM_CLOSE_REQUEST:
			if request_autosave:
				autosave_requested.emit("close_request")


## Puts the game into the suspended state: mute, pause, autosave.
func suspend(reason: String = "manual") -> void:
	if is_suspended:
		return
	is_suspended = true
	if mute_audio_on_suspend:
		_set_master_muted(true)
	# Emit the autosave request before freezing the tree, so listeners can read
	# the live game state synchronously.
	if request_autosave:
		autosave_requested.emit(reason)
	if pause_tree_on_suspend:
		var tree := get_tree()
		if tree != null:
			tree.paused = true
	suspended.emit(reason)


## Leaves the suspended state and unpauses the tree. Call this from the game's
## "Continue" button after the player returns to the app.
func resume_game() -> void:
	var tree := get_tree()
	if tree != null:
		tree.paused = false
	_resume("manual")


## Current orientation value (DisplayServer.ScreenOrientation as int).
func get_orientation() -> int:
	return _orientation


## Re-applies the configured orientation at runtime (emulator rotations, tests).
func apply_project_orientation() -> void:
	_orientation = int(ProjectSettings.get_setting("display/window/handheld/orientation", 0))
	_apply_orientation()


func _on_focus_in() -> void:
	_seen_focus = true
	if not has_focus:
		has_focus = true
		focus_changed.emit(true)
	if is_suspended:
		_resume("focus_in")


func _on_focus_out() -> void:
	if has_focus:
		has_focus = false
		focus_changed.emit(false)
	suspend("focus_out")


func _resume(reason: String) -> void:
	if not is_suspended:
		return
	is_suspended = false
	if mute_audio_on_suspend:
		_set_master_muted(false)
	resumed.emit(reason)


func _apply_orientation() -> void:
	if DisplayServer.get_name() == "headless":
		return
	# `call` keeps this module compilable on builds where the method/enum is
	# unavailable; the engine coerces the int to ScreenOrientation.
	if DisplayServer.has_method("screen_set_orientation"):
		DisplayServer.call("screen_set_orientation", _orientation)


func _set_master_muted(muted: bool) -> void:
	var bus := AudioServer.get_bus_index("Master")
	if bus < 0:
		return
	if muted:
		_master_was_muted = AudioServer.is_bus_mute(bus)
		if not _master_was_muted:
			AudioServer.set_bus_mute(bus, true)
	elif not _master_was_muted:
		AudioServer.set_bus_mute(bus, false)
