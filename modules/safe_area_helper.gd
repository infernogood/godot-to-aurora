class_name AuroraSafeArea
extends RefCounted
## Safe-area / UI-scale helper for Aurora OS ports.
##
## Canonical install path — copy `modules/safe_area_helper.gd` into the game at
## `res://scripts/aurora/safe_area_helper.gd` (the `class_name` makes it
## available everywhere, no autoload needed).
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
##   var vp := get_viewport().get_visible_rect().size
##   var insets := AuroraSafeArea.insets(vp)
##   var ui_scale := AuroraSafeArea.ui_scale(vp, B)
##   label.offset_left = float(insets["l"]) + 24.0 * ui_scale
##
## Rules implemented here:
##   * empty / invalid safe areas are ignored (desktop, headless, emulator);
##   * safe insets are ignored while the window is smaller than the screen
##     (desktop windowed mode, where the area belongs to the monitor); sides are
##     compared by length, so a landscape window on a portrait monitor (or a
##     rotated fullscreen surface) is still handled;
##   * a safe area reported in the other orientation is transposed into window
##     axes before use;
##   * insets are converted to viewport coordinates and clamped so they can
##     never exceed the viewport;
##   * the UI scale uses the smaller axis (`minf`), so a layout built for the
##     base size always fits a narrower or shorter screen, and is clamped to a
##     sane range for 4K desktops and low-DPI phones.

const BASE_TOUCH_DP := 48.0
const DEFAULT_BASE_SIZE := Vector2(1280.0, 800.0)
const DEFAULT_MIN_SCALE := 0.85
const DEFAULT_MAX_SCALE := 1.5
## DPI of a "1x" display; 48 dp are 48 physical px at this density.
const BASELINE_DPI := 96.0
## Sane bounds for the DPI-derived touch-target factor.
const MIN_DP_FACTOR := 1.0
const MAX_DP_FACTOR := 3.0


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
	if looks_windowed(window_size, screen_size):
		return _empty()

	var area := _into_window_axes(safe_area, window_size)
	var sx := viewport_size.x / float(window_size.x)
	var sy := viewport_size.y / float(window_size.y)
	var left := clampf(float(area.position.x) * sx, 0.0, viewport_size.x)
	var top := clampf(float(area.position.y) * sy, 0.0, viewport_size.y)
	var right := clampf(float(window_size.x - area.end.x) * sx, 0.0, viewport_size.x)
	var bottom := clampf(float(window_size.y - area.end.y) * sy, 0.0, viewport_size.y)
	return {
		"l": left,
		"t": top,
		"r": right,
		"b": bottom,
		"valid": true,
	}


## True when the window is smaller than the screen, i.e. a desktop windowed
## mode where the OS safe area belongs to the monitor and must be ignored.
##
## The comparison uses short side vs short side and long side vs long side, so
## a landscape window on a portrait monitor (and a rotated fullscreen surface)
## is not mistaken for a window. Any non-positive size reports "not windowed".
static func looks_windowed(window_size: Vector2i, screen_size: Vector2i) -> bool:
	if window_size.x <= 0 or window_size.y <= 0:
		return false
	if screen_size.x <= 0 or screen_size.y <= 0:
		return false
	var win_short := mini(window_size.x, window_size.y)
	var win_long := maxi(window_size.x, window_size.y)
	var scr_short := mini(screen_size.x, screen_size.y)
	var scr_long := maxi(screen_size.x, screen_size.y)
	return win_short < scr_short - 2 or win_long < scr_long - 2


## Layout scale derived from the viewport, clamped to a sane range.
## `minf` keeps the whole layout inside the shorter axis (a `maxf` scale makes
## HUD elements overflow on screens with a different aspect ratio).
static func ui_scale(
	viewport_size: Vector2,
	base_size: Vector2 = DEFAULT_BASE_SIZE,
	min_scale: float = DEFAULT_MIN_SCALE,
	max_scale: float = DEFAULT_MAX_SCALE,
) -> float:
	if base_size.x <= 0.0 or base_size.y <= 0.0:
		return 1.0
	var raw := minf(viewport_size.x / base_size.x, viewport_size.y / base_size.y)
	return clampf(raw, min_scale, max_scale)


## Touch target in viewport pixels for `dp` device-independent pixels.
##
## 48 dp are physical dp, not base-viewport pixels: the result is multiplied by
## the display density factor (`display_dp_factor()`), clamped to a sane range.
## Pass an explicit `dp_factor > 0` for tests or custom scaling.
static func touch_target(
	scale: float = 1.0,
	dp: float = BASE_TOUCH_DP,
	dp_factor: float = 0.0,
) -> float:
	var factor := dp_factor
	if factor <= 0.0:
		factor = display_dp_factor()
	else:
		factor = clampf(factor, MIN_DP_FACTOR, MAX_DP_FACTOR)
	return dp * maxf(1.0, scale) * factor


## Display density factor: DPI relative to 96 dpi, falling back to the window
## scale reported by the display server. 1.0 on headless / unknown displays.
static func display_dp_factor() -> float:
	if DisplayServer.get_name() == "headless":
		return 1.0
	var factor := 1.0
	var dpi := float(DisplayServer.screen_get_dpi())
	if dpi > 0.0:
		factor = dpi / BASELINE_DPI
	else:
		var screen_scale := float(DisplayServer.screen_get_scale())
		if screen_scale > 0.0:
			factor = screen_scale
	return clampf(factor, MIN_DP_FACTOR, MAX_DP_FACTOR)


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
	return looks_windowed(DisplayServer.window_get_size(), DisplayServer.screen_get_size())


## Brings a safe area reported in screen axes into window axes.
## When the OS reports the screen rotated relative to the window (portrait
## monitor, landscape window) the rect does not fit and its axes are swapped.
static func _into_window_axes(area: Rect2i, window_size: Vector2i) -> Rect2i:
	var fits := (
		area.position.x + area.size.x <= window_size.x + 2
		and area.position.y + area.size.y <= window_size.y + 2
	)
	if fits:
		return area
	return Rect2i(area.position.y, area.position.x, area.size.y, area.size.x)


static func _empty() -> Dictionary:
	return {"l": 0.0, "t": 0.0, "r": 0.0, "b": 0.0, "valid": false}
