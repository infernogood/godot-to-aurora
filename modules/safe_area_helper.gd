class_name AuroraSafeArea
extends RefCounted
## Safe-area / UI-scale helper for Aurora OS ports.
##
## Aurora devices are full-screen Wayland surfaces with notches and rounded
## corners, while desktop Linux reports a "safe area" for the whole monitor even
## for a small window (and often an empty Rect2). Using the raw values either
## pushes the HUD off-screen (32 px GNOME panel) or collapses it to a point
## (a zero-size safe area makes `window - safe.end` equal to the full screen).
##
## This helper is deliberately pure and headless-safe:
##
##   const B := Vector2(1280, 800)
##   var insets := AuroraSafeArea.insets(get_viewport().get_visible_rect().size)
##   var scale := AuroraSafeArea.ui_scale(get_viewport().get_visible_rect().size, B)
##   label.offset_left = insets["l"] + 24.0 * scale
##
## Rules implemented here:
##   * empty / invalid safe areas are ignored (desktop, headless, emulator);
##   * safe insets are ignored while the window is smaller than the screen
##     (desktop windowed mode, where the area belongs to the monitor);
##   * insets are converted to viewport coordinates and clamped so they can
##     never exceed the viewport;
##   * the UI scale is clamped so a 4K desktop and a low-DPI phone both get a
##     usable layout.

const BASE_TOUCH_DP := 48.0
const DEFAULT_BASE_SIZE := Vector2(1280.0, 800.0)
const DEFAULT_MIN_SCALE := 0.85
const DEFAULT_MAX_SCALE := 1.5


## Insets for the current window in viewport coordinates.
## Returns {"l": float, "t": float, "r": float, "b": float, "valid": bool}.
static func insets(viewport_size: Vector2) -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return _empty()
	return compute_insets(
		viewport_size,
		DisplayServer.window_get_size(),
		DisplayServer.get_display_safe_area(),
		DisplayServer.screen_get_size(),
	)


## Pure variant used by unit tests and by callers that already have the values.
static func compute_insets(
	viewport_size: Vector2,
	window_size: Vector2i,
	safe_area: Rect2i,
	screen_size: Vector2i,
) -> Dictionary:
	if viewport_size.x < 1.0 or viewport_size.y < 1.0:
		return _empty()
	if window_size.x <= 0 or window_size.y <= 0:
		return _empty()
	if safe_area.size.x <= 0 or safe_area.size.y <= 0:
		return _empty()
	# Windowed desktop: the safe area describes the monitor, not the window.
	if screen_size.x > 0 and screen_size.y > 0:
		if window_size.x < screen_size.x - 2 or window_size.y < screen_size.y - 2:
			return _empty()

	var sx := viewport_size.x / maxf(1.0, float(window_size.x))
	var sy := viewport_size.y / maxf(1.0, float(window_size.y))
	var left := clampf(float(safe_area.position.x) * sx, 0.0, viewport_size.x)
	var top := clampf(float(safe_area.position.y) * sy, 0.0, viewport_size.y)
	var right := clampf(float(window_size.x - safe_area.end.x) * sx, 0.0, viewport_size.x)
	var bottom := clampf(float(window_size.y - safe_area.end.y) * sy, 0.0, viewport_size.y)
	return {
		"l": left,
		"t": top,
		"r": right,
		"b": bottom,
		"valid": true,
	}


## Layout scale derived from the viewport, clamped to a sane range.
static func ui_scale(
	viewport_size: Vector2,
	base_size: Vector2 = DEFAULT_BASE_SIZE,
	min_scale: float = DEFAULT_MIN_SCALE,
	max_scale: float = DEFAULT_MAX_SCALE,
) -> float:
	if base_size.x <= 0.0 or base_size.y <= 0.0:
		return 1.0
	var raw := maxf(viewport_size.x / base_size.x, viewport_size.y / base_size.y)
	return clampf(raw, min_scale, max_scale)


## Minimum touch target in viewport pixels (48 dp by default).
static func touch_target(scale: float = 1.0, dp: float = BASE_TOUCH_DP) -> float:
	return dp * maxf(1.0, scale)


## Usable rectangle between the safe-area insets.
static func usable_rect(viewport_size: Vector2, margin: float = 0.0) -> Rect2:
	var i := insets(viewport_size)
	var left: float = float(i["l"]) + margin
	var top: float = float(i["t"]) + margin
	var right: float = float(i["r"]) + margin
	var bottom: float = float(i["b"]) + margin
	return Rect2(
		Vector2(left, top),
		Vector2(
			maxf(0.0, viewport_size.x - left - right),
			maxf(0.0, viewport_size.y - top - bottom),
		),
	)


## True when the OS reports the application as windowed (desktop) rather than
## full-screen (Aurora). Useful for showing keyboard hints only on desktop.
static func is_windowed() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	var win := DisplayServer.window_get_size()
	var screen := DisplayServer.screen_get_size()
	if win.x <= 0 or screen.x <= 0:
		return false
	return win.x < screen.x - 2 or win.y < screen.y - 2


static func _empty() -> Dictionary:
	return {"l": 0.0, "t": 0.0, "r": 0.0, "b": 0.0, "valid": false}
