# advect

Flow-field wallpaper generator. Particles march through a Perlin/fBm noise field
and leave glowing lightning-like filaments on a dark ground. Every render is
unique (or pass `--seed` to reproduce one). Stdlib-only for the `py`/`c` backends;
writes real PNGs and macOS Dynamic `.heic` wallpapers.

```
advect                    # render to ~/Pictures/advect/, print path
advect --set              # render AND set as desktop wallpaper
advect --palette ember    # harbor | ember | moss | dune
advect --seed 7 --size 2016x1310
advect --sharp 0.7 --glow 0.9 --softness 1.5
advect --dynamic --set    # a Dynamic .heic that shifts with the time of day
advect --backend c        # compiled march via cc + ctypes, ~25x faster
advect --backend gpu      # MLX on Apple Silicon (best at --dynamic scale)
advect --out ~/wall.png   # write somewhere other than ~/Pictures/advect/
```

## The menu bar app

`menubar/` wraps all of the above in **Advect.app**, a menu bar app with no
Dock icon. Build and install it with:

```
./menubar/build.sh --install     # → ~/Applications/Advect.app, then launches it
./menubar/build.sh               # build only, into menubar/build/
```

No Xcode project, no package manager — `swiftc` compiles the sources straight
into a hand-laid bundle, and the renderer is copied inside it, so the app keeps
working wherever this repo ends up. Rebuild to pick up renderer changes.

From the menu you get **New Wallpaper** and **New Day Cycle**, pickers for
palette / backend / size / frame count, **Auto-Rotate** (30 min through daily),
a **Recent** submenu of thumbnails you can re-apply (⌥-click to reveal in
Finder), and **Launch at Login**.

While it paints, a floating panel shows the picture arriving — the renderer
writes a downscaled snapshot roughly once a second and the app reloads it — with
a progress bar and a Cancel button. The same live thumbnail sits at the top of
the menu, and the status item counts up a percentage. Wallpapers are applied
through `NSWorkspace`, so the app never asks for Automation permission.

Renders can also be triggered from outside — handy for a hotkey, a Shortcut or a
macro pad:

```
open advect://new
open advect://daycycle
```

## The day cycle

`--dynamic` packs 32 frames sharing one seed into a macOS Dynamic wallpaper — the
geometry is frozen and only colour and light drift, so the wallpaper changes
subtly and continuously through the day. Every palette is glowing filaments on a
dark background; only the hue shifts by hour:

| time | palette | colour |
|------|---------|--------|
| night | `harbor` | red |
| dawn / dusk | `ember` | orange |
| morning / midday | `dune` | teal |
| afternoon | `moss` | green |

## Palettes

| | |
|---|---|
| ![harbor](previews/harbor.png) **harbor** — red | ![ember](previews/ember.png) **ember** — orange |
| ![moss](previews/moss.png) **moss** — green | ![dune](previews/dune.png) **dune** — teal |

`day-cycle.heic` is a rendered dynamic wallpaper you can set directly — 32 frames
at 1024×662, small enough to keep in the repo. Render your own at display
resolution with `advect --dynamic --set`.
