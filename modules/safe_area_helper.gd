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
##   var vp := get_viewport().get_visible_rect().size
##   var insets := AuroraSafeArea.insets(vp)
##   var ui_scale := AuroraSafeArea.ui_scale(vp)  # base size from project settings
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
##     sane range for 4K desktops and low-DPI phones;
##   * the base size defaults to the project's design resolution
##     (`display/window/size/viewport_width` / `viewport_height`) and only falls
##     back to 1280x800 when those settings are missing or invalid;
##   * with `display/window/stretch/mode = "canvas_items"` the engine already
##     scales the whole canvas, so `touch_target()` does not apply the layout
##     scale a second time.

const BASE_TOUCH_DP := 48.0
const DEFAULT_BASE_SIZE := Vector2(1280.0, 800.0)
## Project setting that decides whether the engine scales the canvas itself.
const STRETCH_MODE_SETTING := "display/window/stretch/mode"
## Relative tolerance before a surface counts as a desktop window (5 % per side).
const WINDOW_SLACK_RATIO := 0.05
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
## is not mistaken for a window. A side only counts as "smaller" when it is
## shorter by more than 5 % of the screen side (at least 2 px): the few pixels
## taken by a device status bar must not switch safe-area handling off entirely.
## Any non-positive size reports "not windowed".
static func looks_windowed(window_size: Vector2i, screen_size: Vector2i) -> bool:
	if window_size.x <= 0 or window_size.y <= 0:
		return false
	if screen_size.x <= 0 or screen_size.y <= 0:
		return false
	var win_short := mini(window_size.x, window_size.y)
	var win_long := maxi(window_size.x, window_size.y)
	var scr_short := mini(screen_size.x, screen_size.y)
	var scr_long := maxi(screen_size.x, screen_size.y)
	return (
		win_short < scr_short - _window_slack(scr_short)
		or win_long < scr_long - _window_slack(scr_long)
	)


## Allowed difference for one screen side before the surface counts as a window.
static func _window_slack(screen_side: int) -> int:
	return maxi(2, int(round(float(screen_side) * WINDOW_SLACK_RATIO)))


## Layout scale derived from the viewport, clamped to a sane range.
## `minf` keeps the whole layout inside the shorter axis (a `maxf` scale makes
## HUD elements overflow on screens with a different aspect ratio).
## `base_size` defaults to `base_viewport_size()` (the project's design
## resolution); pass `Vector2.ZERO` (or any non-positive size) for the default.
static func ui_scale(
	viewport_size: Vector2,
	base_size: Vector2 = Vector2.ZERO,
	min_scale: float = DEFAULT_MIN_SCALE,
	max_scale: float = DEFAULT_MAX_SCALE,
) -> float:
	var base := base_size
	if base.x <= 0.0 or base.y <= 0.0:
		base = base_viewport_size()
	if base.x <= 0.0 or base.y <= 0.0:
		return 1.0
	var raw := minf(viewport_size.x / base.x, viewport_size.y / base.y)
	return clampf(raw, min_scale, max_scale)


## Design resolution the UI is built for: `display/window/size/viewport_width`
## and `viewport_height`, falling back to `DEFAULT_BASE_SIZE` (1280x800) when the
## project does not define them or they are not positive numbers.
static func base_viewport_size() -> Vector2:
	var width := _positive_int_setting(
		"display/window/size/viewport_width", int(DEFAULT_BASE_SIZE.x)
	)
	var height := _positive_int_setting(
		"display/window/size/viewport_height", int(DEFAULT_BASE_SIZE.y)
	)
	return Vector2(float(width), float(height))


## True when `display/window/stretch/mode` is `canvas_items`: the engine scales
## the canvas itself (via `content_scale_factor`), so the layout works in
## base-size coordinates.
static func uses_canvas_stretch() -> bool:
	return str(ProjectSettings.get_setting(STRETCH_MODE_SETTING, "disabled")) == "canvas_items"


## Reads an integer project setting, falling back when it is missing, not a
## number or not positive.
static func _positive_int_setting(name: String, fallback: int) -> int:
	var value: Variant = ProjectSettings.get_setting(name, fallback)
	if not (value is int or value is float):
		return fallback
	var number := int(value)
	return number if number > 0 else fallback


## Touch target in viewport pixels for `dp` device-independent pixels.
##
## 48 dp are physical dp, not base-viewport pixels: the result is multiplied by
## the display density factor (`display_dp_factor()`), clamped to a sane range.
## Pass an explicit `dp_factor > 0` for tests or custom scaling.
## The layout `scale` is applied only when the engine does NOT scale the canvas:
## with `display/window/stretch/mode = "canvas_items"` the viewport is already
## scaled and a second factor would make every touch target too large.
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
	if uses_canvas_stretch():
		return dp * factor
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
