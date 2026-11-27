extends Node
## Aurora OS application-lifecycle helper (autoload).
##
## Canonical install path — copy `modules/aurora_lifecycle.gd` into the game at
## `res://scripts/aurora/aurora_lifecycle.gd` and register the autoload:
##
##   [autoload]
##   AuroraLifecycle="*res://scripts/aurora/aurora_lifecycle.gd"
##
##   # somewhere in your main scene:
##   func _ready() -> void:
##       AuroraLifecycle.suspended.connect(_on_suspended)
##       AuroraLifecycle.resumed.connect(_on_resumed)
##       AuroraLifecycle.focus_changed.connect(_on_focus_changed)
##       AuroraLifecycle.autosave_requested.connect(_save_game)
##
## Signals:
##   * `suspended(reason)` — the tree was paused and the app went to the
##     background; the reason is "app_paused", "focus_out", "window_focus_out"
##     or "manual";
##   * `resumed(reason)` — the power-saving state and audio bus were restored
##     (the tree stays paused until the game calls `resume_game()`);
##   * `focus_changed(focused)` — window/application focus changed; emitted even
##     when the change does not pause the game;
##   * `autosave_requested(reason)` — emitted before the tree is frozen, so
##     listeners can read the live game state synchronously.
##
## Behaviour:
##   * `APPLICATION_PAUSED` always suspends the game;
##   * on mobile builds (Aurora OS, Android, iOS) `APPLICATION_FOCUS_OUT` always
##     suspends the game: there the application loses focus only when it goes to
##     the background;
##   * on desktop both `APPLICATION_FOCUS_OUT` and `WM_WINDOW_FOCUS_OUT` suspend
##     only when `pause_on_desktop_focus_loss` is `true` — clicking a second
##     monitor or a system popup does not pause a desktop build by default. The
##     `focus_changed(false)` signal is emitted either way, so the game can react
##     to the focus change without freezing the tree;
##   * a `WM_WINDOW_FOCUS_OUT` that arrives before the first `FOCUS_IN` is
##     ignored, otherwise a game started in the background (or under
##     `--headless --script`) pauses itself immediately;
##   * on suspend the previous `OS.low_processor_usage_mode` and
##     `Engine.max_fps` are saved, then set to `true` / `10`; on resume the
##     previous values are restored;
##   * the tree is never unpaused automatically: the player resumes through the
##     game's own "Continue" button, which should call `resume_game()`;
##   * `display/window/handheld/orientation` is pinned on startup so the
##     emulator (no accelerometer) and sensor-based settings agree.
##
## The module is self-contained: no autoload lookups at parse time, so it also
## works in headless tests.

signal suspended(reason: String)
signal resumed(reason: String)
signal focus_changed(focused: bool)
signal autosave_requested(reason: String)

## `Engine.max_fps` used while the application is in the background.
const SUSPENDED_MAX_FPS := 10

## Pause the scene tree while the application is in the background.
@export var pause_tree_on_suspend := true
## Mute the Master audio bus while the application is in the background.
@export var mute_audio_on_suspend := true
## Apply `display/window/handheld/orientation` on startup.
@export var apply_orientation := true
## Emit `autosave_requested` on suspend and on close requests.
@export var request_autosave := true
## Pause on focus loss in a desktop build (`WM_WINDOW_FOCUS_OUT` and
## `APPLICATION_FOCUS_OUT`). Mobile builds pause on `APPLICATION_PAUSED` and
## `APPLICATION_FOCUS_OUT` anyway; on desktop this is usually unwanted.
@export var pause_on_desktop_focus_loss := false
## Throttle the process while suspended (`OS.low_processor_usage_mode` and
## `Engine.max_fps`), restoring the previous values on resume.
@export var power_save_on_suspend := true

var is_suspended := false
var has_focus := false

var _seen_focus := false
var _master_was_muted := false
var _orientation := 0
var _power_state_saved := false
var _previous_low_processor := false
var _previous_max_fps := 0


func _ready() -> void:
	# Notifications must still be processed while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_orientation = int(ProjectSettings.get_setting("display/window/handheld/orientation", 0))
	if apply_orientation:
		_apply_orientation()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_WINDOW_FOCUS_IN:
			_seen_focus = true
			_handle_focus_in()
		NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			# A window created in the background receives FOCUS_OUT before any
			# FOCUS_IN; pausing there breaks headless runs and background starts.
			if _seen_focus:
				_handle_focus_out(pause_on_desktop_focus_loss, "window_focus_out")
		NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_APPLICATION_RESUMED:
			_seen_focus = true
			_handle_focus_in()
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			# Mobile builds are backgrounded on focus loss, so they always pause;
			# on desktop the same notification fires when another window grabs
			# the focus, so `pause_on_desktop_focus_loss` decides.
			_handle_focus_out(is_mobile_platform() or pause_on_desktop_focus_loss, "focus_out")
		NOTIFICATION_APPLICATION_PAUSED:
			suspend("app_paused")
		NOTIFICATION_WM_CLOSE_REQUEST:
			if request_autosave:
				autosave_requested.emit("close_request")


## Puts the game into the suspended state: power saving, mute, pause, autosave.
func suspend(reason: String = "manual") -> void:
	if is_suspended:
		return
	is_suspended = true
	_enter_power_saving()
	if mute_audio_on_suspend:
		_set_master_muted(true)
	# Emit the autosave request before freezing the tree, so listeners can read
	# the live game state synchronously.
	if request_autosave:
		autosave_requested.emit(reason)
	if pause_tree_on_suspend and is_inside_tree():
		get_tree().paused = true
	suspended.emit(reason)


## Leaves the suspended state and unpauses the tree. Call this from the game's
## "Continue" button after the player returns to the app.
func resume_game() -> void:
	if is_inside_tree():
		get_tree().paused = false
	_resume("manual")


## Current orientation value (DisplayServer.ScreenOrientation as int).
func get_orientation() -> int:
	return _orientation


## True on mobile-like platforms (Aurora OS, Android, iOS), where losing the
## application focus means the app is going to the background.
static func is_mobile_platform() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("auroraos")


## Re-applies the configured orientation at runtime (emulator rotations, tests).
func apply_project_orientation() -> void:
	_orientation = int(ProjectSettings.get_setting("display/window/handheld/orientation", 0))
	_apply_orientation()


func _handle_focus_in() -> void:
	if not has_focus:
		has_focus = true
		focus_changed.emit(true)
	if is_suspended:
		_resume("focus_in")


## `pause` is false for desktop window focus loss unless
## `pause_on_desktop_focus_loss` is enabled: the focus signal is still emitted.
func _handle_focus_out(pause: bool, reason: String) -> void:
	if has_focus:
		has_focus = false
		focus_changed.emit(false)
	if pause:
		suspend(reason)


func _resume(reason: String) -> void:
	if not is_suspended:
		return
	is_suspended = false
	_leave_power_saving()
	if mute_audio_on_suspend:
		_set_master_muted(false)
	resumed.emit(reason)


## Saves the current power settings and throttles the process. The values are
## captured even when `power_save_on_suspend` is off, so `_leave_power_saving()`
## always has something consistent to restore.
func _enter_power_saving() -> void:
	if _power_state_saved:
		return
	_power_state_saved = true
	_previous_low_processor = OS.low_processor_usage_mode
	_previous_max_fps = Engine.max_fps
	if not power_save_on_suspend:
		return
	OS.low_processor_usage_mode = true
	Engine.max_fps = SUSPENDED_MAX_FPS


func _leave_power_saving() -> void:
	if not _power_state_saved:
		return
	_power_state_saved = false
	OS.low_processor_usage_mode = _previous_low_processor
	Engine.max_fps = _previous_max_fps


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
