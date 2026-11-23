# Fonts for Aurora OS ports

The Aurora export templates are built with `fontconfig=no`, so `SystemFont` cannot
find host fonts on the device. Ship these files inside the game instead.

| File | Use |
|---|---|
| `LiberationMono-Regular.ttf` | HUD, terminal/CRT screens, number plates, `Label3D` fallback |
| `LiberationSans-Regular.ttf` | body text, dialogs, long descriptions |
| `LiberationSans-Bold.ttf` | headings and modal titles |

Copy them into the project (suggested path `assets/fonts/`) together with the two
license files:

```bash
mkdir -p assets/fonts
cp godot-to-aurora/modules/fonts/*.ttf assets/fonts/
cp godot-to-aurora/modules/fonts/LICENSE* assets/fonts/
```

Then:

1. add a base font for UI controls in `project.godot`:
   `[gui] theme/custom_font="res://assets/fonts/LiberationSans-Regular.ttf"`;
2. load fonts by path in scripts (`load("res://assets/fonts/...")`) and keep
   `SystemFont` only as a fallback;
3. assign the font explicitly to `Label3D`/`RichTextLabel` nodes — the global theme
   does not apply to 3D labels.

Coverage checked: Cyrillic (ru/uk), `«»`, em dash, `№`, `→`.

License: SIL Open Font License 1.1. See `LICENSE` and `LICENSE-LiberationSans`.
