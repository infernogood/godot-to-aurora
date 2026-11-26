# Fonts for Aurora OS ports

The Aurora export templates are built with `fontconfig=no`, so `SystemFont` cannot
find host fonts on the device. Ship these files inside the game instead.

Canonical install path — copy the `.ttf` files (and the single `LICENSE`) into the
project at `res://assets/fonts/`:

| Source (`modules/fonts/`) | Destination (`assets/fonts/`) | Use |
|---|---|---|
| `LiberationSans-Regular.ttf` | `assets/fonts/LiberationSans-Regular.ttf` | body text, dialogs, long descriptions |
| `LiberationSans-Bold.ttf` | `assets/fonts/LiberationSans-Bold.ttf` | headings and modal titles |
| `LiberationMono-Regular.ttf` | `assets/fonts/LiberationMono-Regular.ttf` | monospaced UI: HUD readouts, code, `Label3D` fallback |
| `LICENSE` | `assets/fonts/LICENSE` | SIL Open Font License 1.1, covers all three files |

```bash
mkdir -p assets/fonts
cp godot-to-aurora/modules/fonts/*.ttf assets/fonts/
cp godot-to-aurora/modules/fonts/LICENSE assets/fonts/
```

There is exactly one license file (`LICENSE`). Do not add a per-family copy.

Then:

1. add a base font for UI controls in `project.godot`:
   `[gui] theme/custom_font="res://assets/fonts/LiberationSans-Regular.ttf"`;
2. load fonts by path in scripts (`load("res://assets/fonts/...")`) and keep
   `SystemFont` only as a fallback;
3. assign the font explicitly to `Label3D`/`RichTextLabel` nodes — the global theme
   does not apply to 3D labels.

Coverage checked: Cyrillic (ru/uk), `«»`, em dash, `№`, `→`.

License: SIL Open Font License 1.1. See `LICENSE` (single file, covers all fonts).
