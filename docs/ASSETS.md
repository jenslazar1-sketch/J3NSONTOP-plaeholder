# Assets: credits, licences and pipeline

Every image, icon, splash screen, ASCII drawing and sound in this repository is
either **original work made for J3NSONTOP BIGGEST MULTITOOL MADE** or a font
under the SIL Open Font License. No third-party images, icon packs, clip art,
stock art or templates were used, traced or adapted.

| Asset | Origin | Licence |
| --- | --- | --- |
| App icons, adaptive/themed icons, splash screens, in-app skull logos | Original, this project (`tool/art/`) | Project's own terms |
| ASCII skull (intro, rail logo, easter egg) | Original, this project (`tool/skull/`) | Project's own terms |
| Intro sound | Original, this project (`tool/sound/`) | Project's own terms |
| Chakra Petch (UI font) | © 2018 The Chakra Petch Project Authors | SIL OFL 1.1 |
| JetBrains Mono (monospace font) | © 2020 The JetBrains Mono Project Authors | SIL OFL 1.1 |

When you add an asset, add it to this file with its origin and licence. Only
original work or assets under a licence that allows redistribution inside an
app (OFL, CC0, CC-BY with credit here, MIT...) are allowed.

## App icon and splash artwork

**Design.** A laughing neon skull on a black terminal screen. It is an original
vector drawing that echoes the ASCII skull in
`lib/features/intro/skull_art.dart` rather than copying any existing skull:

* a round dome with straight temples and a cheek "shelf" (`'-.___.-'`) that is
  wider than the teeth, like the ASCII cranium;
* angular, angry eye sockets whose top edge slants down toward the nose, with
  white-hot glowing red eyes inside;
* the inverted-V nose with its little notch (`/_^_\`);
* a hairline crack zig-zagging down the upper right of the dome
  (`, \ / \_ \` in the ASCII);
* a row of upper teeth between two pillars (`| |_|_|_| |`) and a separate jaw
  with lower teeth and a rounded chin, hanging open with a gap as if mid-laugh.

Style: neon tubes (`#FF163B`) with a soft pink hot core and a restrained glow,
a dark red bone fill with faint CRT scanlines, on a near-black (`#050507`)
rounded tile with a barely visible neon grid, scanlines, a dark red (`#750C20`)
bloom and a vignette. Below 48 px the outline style turns to mush, so a
simplified bold silhouette is used for 32 px and smaller: solid neon skull, two
white-hot eyes in black sockets, three upper and three lower teeth, the open
jaw and the crack, drawn on a 32 unit pixel grid so 16 and 32 px stay crisp.

### Sources (`tool/art/`)

| File | What it is |
| --- | --- |
| `skull_foreground.svg` | The detailed skull on a transparent 1024 canvas. Master geometry. |
| `icon_background.svg` | Full-bleed terminal background (grid, scanlines, bloom, vignette). |
| `skull_icon.svg` | Master icon: background + foreground on a rounded tile with a faint neon rim. Rendered as is (rounded) and with `class="full-bleed"` (opaque square for iOS). |
| `skull_small.svg` | Bold small skull, 32 unit grid, transparent. |
| `skull_icon_small.svg` | Small icon tile around `skull_small.svg` (also has `full-bleed`). |
| `skull_monochrome.svg` | White silhouette with cut-out sockets, nose, teeth gaps and crack (Android 13+ themed icon). Same geometry as the foreground. |
| `render_icons.py` | Renders the SVGs and writes every platform asset (below), then verifies them. |

The SVGs are hand-editable (Inkscape, a text editor, a browser). The composite
files reference the others with relative `<image href>`, so keep them together.

### Regenerating

```sh
pip install pillow numpy playwright        # no `playwright install` needed if a Chromium exists
python3 tool/art/render_icons.py           # render every asset + verify
python3 tool/art/render_icons.py --preview /tmp/icon-review   # + review sheets
python3 tool/art/render_icons.py --verify-only                # checks only, no browser
```

The script finds Chromium through `CHROMIUM=/path/to/chrome`, then
`$PLAYWRIGHT_BROWSERS_PATH` (`/opt/pw-browsers`, `~/.cache/ms-playwright`),
then Playwright's default; it never downloads a browser. Headless Chromium
rasterises each SVG once at 2048 px (1536 px for the 32 unit small art); all
resizing, placement, glow fading, flattening and ICO packing is then done with
Pillow and numpy using fixed filters (area averaging for the pixel-grid small
art, Lanczos otherwise), so two runs with the same Chromium produce
byte-identical files. The preview sheets show the 1024 master, 16-48 px
renders magnified on dark and light desktops, the adaptive icon under circle /
squircle / rounded masks plus the themed icon, mock launch screens and the
in-app logos.

The XML wiring (adaptive icon XML, colours, launch backgrounds, styles,
`LaunchScreen.storyboard`) is static and hand-written; the script only checks
that it parses and references the generated files.

### Generated files

| Platform | Files | Sizes | Notes |
| --- | --- | --- | --- |
| Android launcher (legacy, API < 26) | `res/mipmap-*/ic_launcher.png` | 48/72/96/144/192 | Rounded tile. The manifest has no `roundIcon`, so there is no `ic_launcher_round`. |
| Android adaptive (API 26+) | `res/mipmap-anydpi-v26/ic_launcher.xml`, `res/mipmap-*/ic_launcher_foreground.png` | 108 dp = 108/162/216/324/432 | Background `@color/ic_launcher_background` (#050507). The skull fits a 60 dp circle (inside the 66 dp safe circle); its glow fades out before the 72 dp viewport so no mask cuts it hard. |
| Android 13+ themed icon | `res/mipmap-*/ic_launcher_monochrome.png` | 108 dp | White + alpha, same placement as the foreground. |
| Android launch screen (< 12) | `res/drawable*/launch_background.xml`, `res/drawable-*/splash_skull.png` | 200 dp canvas (200-800 px) | #050507 + centred skull, 150 dp tall. |
| Android 12+ splash | `res/values-v31/styles.xml`, `res/values-night-v31/styles.xml`, `res/drawable-*/splash_icon.png` | 288 dp canvas (288-1152 px) | Skull 150 dp tall; skull and glow stay inside the 192 dp circle. Icon background colour = window background (#050507). |
| Android themes | `res/values/styles.xml`, `res/values-night/styles.xml`, `res/values/colors.xml` | | `LaunchTheme` shows `@drawable/launch_background`; `NormalTheme` window background is #050507 so there is no white flash behind Flutter. |
| iOS app icon | `ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png` | every entry of its `Contents.json` (20-1024 px) | Full-bleed, **opaque RGB (no alpha)**; iOS applies its own mask. 20 and 29 px use the small art. |
| iOS launch screen | `LaunchImage.imageset/LaunchImage{,@2x,@3x}.png`, `Base.lproj/LaunchScreen.storyboard` | 200 pt (200/400/600 px) | Transparent skull (150 pt tall) centred on a #050507 view. |
| Windows | `windows/runner/resources/app_icon.ico` | 16, 24, 32, 48, 64, 128, 256 | 32-bit DIB entries + PNG for 256. 16-32 px use the small art. |
| In-app | `assets/images/skull_logo.png` | 512 | Detailed glowing skull, transparent. |
| In-app | `assets/images/skull_logo_128.png` | 128 | Detailed skull, transparent. |
| In-app | `assets/images/skull_logo_64.png` | 64 | Bold small skull (crisp for the sidebar / header). |

## ASCII skull

The ASCII skull (`lib/features/intro/skull_art.dart`: cranium, animated jaw and
the compact mini skull) is original. It was drawn from scratch with the
mirror/placement helper `tool/skull/skull_design.py` (+ `dsl.py`; preview with
`tool/skull/render_preview.py`). An ascii.co.uk skull page was considered as a
reference, but it could not be reached to verify its reuse terms, so no
third-party ASCII art was used.

## Fonts

Both font families are bundled as TTF files in `assets/fonts/` and declared in
`pubspec.yaml`. The TTFs were taken from the npm packages
`@expo-google-fonts/chakra-petch@0.4.1` and
`@expo-google-fonts/jetbrains-mono@0.4.1`, which mirror the Google Fonts
releases. The full licence texts ship with the app in `assets/licenses/`.

| Family | Files | Copyright | Licence |
| --- | --- | --- | --- |
| Chakra Petch (UI) | `ChakraPetch_{400Regular,500Medium,600SemiBold,700Bold}.ttf` | © 2018 The Chakra Petch Project Authors | SIL OFL 1.1, `assets/licenses/OFL-ChakraPetch.txt` |
| JetBrains Mono (ASCII art, code) | `JetBrainsMono_{400Regular,400Regular_Italic,500Medium,700Bold}.ttf` | © 2020 The JetBrains Mono Project Authors | SIL OFL 1.1, `assets/licenses/OFL-JetBrainsMono.txt` |

The OFL allows bundling the fonts in the app; the font files must not be sold
on their own and the licence text must accompany them (it does).

## Sounds

The intro sound in `assets/sounds/` is original: it is synthesised from
scratch by `tool/sound/generate_intro_sound.py` (added by another
contributor), with no samples or third-party recordings. Regenerate it with
that script; see its header for parameters.
