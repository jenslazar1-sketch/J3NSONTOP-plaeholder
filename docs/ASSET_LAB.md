# Asset Lab

Five local, offline tools for preparing images for your own projects and
mod-friendly games. All pixel work uses the pure-Dart `image` package
(4.10.1), so results are identical on Android, iOS, Windows and Linux.
Decoding, transforms, encoding, ZIP creation and file writes run in a
background isolate per task (`IsolateAssetWorker`, built on `runBounded`),
which is killed when an operation is cancelled or superseded.

| Tool | Id | What it does |
| --- | --- | --- |
| Image Studio | `assets.image` | Metadata, non-destructive resize/crop/rotate/flip pipeline with undo/redo, export to any encodable format |
| Sprite Sheet | `assets.sprites` | Grid slicing with margin/spacing, animation preview, PNG frames (ZIP or workspace folder), animated GIF |
| Atlas Packer | `assets.atlas` | MaxRects texture atlas + `j3atlas` JSON ([format](ATLAS_FORMAT.md)), validated on every pack |
| Color Lab | `assets.color` | HSV picker, HEX/RGB/HSL/HSV, WCAG contrast, eyedropper, saved palette with exports |
| App Icon Export | `assets.icons` | Android (legacy + adaptive), Google Play, iOS asset catalog and Windows ICO, each output re-decoded and verified |

Terminal commands: `wcag <fg> <bg>`, `colorfmt <colour> [--argb]`,
`imginfo <workspace-relative path>`.

## Supported formats

Verified against `package:image` 4.10.1 (`lib/src/formats/`) and by the
round-trip tests in `test/features/asset_lab/image_ops_test.dart`.

| Format | Extensions | Decode | Encode (package) | Offered for export | Notes |
| --- | --- | --- | --- | --- | --- |
| PNG | png | yes (incl. 16-bit, palette, APNG first frame) | yes | yes | alpha kept |
| JPEG | jpg, jpeg | yes (EXIF read) | yes | yes | no alpha: flattened onto a chosen colour, with a warning; quality 1-100 |
| WebP | webp | yes (lossy, lossless, animated first frame) | yes: lossless VP8L and lossy VP8 (new in 4.10) | yes | alpha kept; lossless by default, quality for lossy |
| GIF | gif | yes (animated: first frame; frame count shown) | yes (256-colour palette) | yes | the encoder writes opaque palettes, so alpha is flattened like JPEG |
| BMP | bmp | yes | yes (32-bit with alpha) | yes | alpha kept |
| TGA | tga | yes | yes | yes | alpha kept; TGA has no magic number, so it is recognised by extension only |
| TIFF | tif, tiff | yes | yes | yes | alpha kept |
| ICO | ico | yes (largest entry is used) | yes (PNG-compressed entries, max 256 px) | yes (<= 256 px) | multi-size ICO is produced by App Icon Export |
| CUR | cur | no | yes | no | the package cannot decode its own CUR output, so it is not offered |
| PSD | psd | yes (flattened composite) | no | - | |
| OpenEXR | exr | yes (HDR, converted to 8 bit) | no | - | |
| PVR | pvr | yes | PVRTC only (square, power of two) | no | the probe showed the package could not decode its own PVR output, so it is not offered |
| PNM | pnm, pbm, pgm, ppm | yes | no | - | |

Processing model:

* Every source is converted to an 8-bit RGB or RGBA raster (palette, grey,
  16-bit and float sources included). Sources above 8 bits per channel are
  exported at 8 bits; the metadata panel says so.
* Multi-frame sources (GIF, APNG, animated WebP) are edited as their first
  frame; ICO uses its largest entry.
* EXIF orientation is applied when decoding, so previews and outputs are
  upright. EXIF is shown (camera, date, exposure, "GPS present") but never
  copied into exports.
* Limits: 256 MB input files, 64 megapixels per image, 16384 px per side.
  Oversized or damaged inputs are refused with a readable reason.
* Previews are downscaled (Image Studio 1600 px, Sprite Sheet 4096 px, Atlas
  2048 px) and drawn over a checkerboard; exports always use full
  resolution. Zooming uses nearest-neighbour sampling and shows a pixel grid
  from 8x.

Outputs never replace originals: the default name is `<name>_edited.<ext>`,
saving goes through the platform export flow (workspace folder, system save
dialog, or share sheet on mobile), and writes into a workspace use a new
name (`name (2).png`) when the target exists.

## Image Studio operations

| Operation | Parameters | Output size | Notes |
| --- | --- | --- | --- |
| Resize | width, height (1-16384, <= 64 MP), aspect lock, percent, interpolation nearest / linear / cubic / average | as entered | nearest for pixel art, average for downscaling |
| Crop | x, y, width, height; interactive rectangle with 8 handles, arrow keys move it (Shift = 10 px); aspect presets free / 1:1 / 4:3 / 16:9 | width x height | validated against the size at that step |
| Rotate | 90 / 180 / 270 (lossless) or any angle | swapped for 90/270; expanded bounding box otherwise | arbitrary angles convert to RGBA; new corners are transparent |
| Flip | horizontal / vertical | unchanged | |

The pipeline is a list of steps with reorder, remove, undo/redo (100 levels)
and reset (itself undoable). Each step is validated against the output of
the previous one; the first invalid step is marked, later steps are skipped,
and export is blocked until it is fixed. The export panel shows the final
dimensions, the encoded byte size and whether alpha was kept or flattened
before anything is saved. Workspace files can also be saved next to the
original under a new name.

## Sprite Sheet

* Grid by frame size (columns/rows automatic or overridden) or by
  columns x rows (frame size derived; leftover pixels reported), plus margin
  (offset of the first frame) and spacing (gap between frames).
* The frame count defaults to every cell and can be lowered to exclude
  trailing cells; "Trim empty trailing cells" does it automatically for fully
  transparent cells.
* A grid that does not fit the sheet is an error naming the needed size and
  the overflow per axis.
* Preview: frame indices over the sheet, animation at 1-60 FPS with play /
  pause / step / loop and 1-16x nearest-neighbour zoom. With reduced motion
  the animation never autoplays; play and stepping still work.
* Frames export as `<base>_000.png`, `<base>_001.png`, ... (at least three
  digits, more for 1000+ frames) in a ZIP or into a workspace folder.
* Animated GIF: one frame per sprite, delay `round(100 / fps)` hundredths of a
  second (minimum 2), loops forever, per-frame octree palette without
  dithering (exact colours for sprites with up to 256 colours per frame),
  flattened onto a chosen background because the encoder has no alpha.

## Color Lab

* HEX input: `#RGB`, `#RGBA`, `#RRGGBB`, and 8 digits in the selected order:
  `#RRGGBBAA` (CSS Color 4, default) or `#AARRGGBB` (Android resources /
  Flutter). `0xAARRGGBB` is always alpha-first. The `#` is optional.
* RGB(A): `rgb(255, 22, 59)`, `rgba(255, 22, 59, 0.5)`, `rgb(255 22 59 / 50%)`
  or a bare `255, 22, 59`; channels 0-255 or percentages.
* HSL(A) and HSV(A)/HSB: `hsl(350, 100%, 54%)`; values without `%` above 1 are
  read as percentages, 0-1 as fractions.
* Contrast: WCAG 2.x relative luminance, ratio `(L1 + 0.05) / (L2 + 0.05)`. A
  translucent foreground is blended over the (opaque) background first.
  Badges: AA normal 4.5, AA large 3, AAA normal 7, AAA large 4.5, UI
  components 3. Example: `#FF163B` on `#050507` = 5.27:1.
* Eyedropper: tap or drag on a loaded image; the full-resolution pixel
  (alpha included) is picked even when the preview is downscaled.
* Palette: stored in `features.json` under `asset_lab.palette` as
  `{"v": 1, "swatches": [{"id", "name", "hex": "#RRGGBBAA"}]}` (damaged entries
  are skipped on load, at most 256 colours). Exports: JSON
  (`{"format": "j3palette", "version": 1, ...}`), GIMP `.gpl` (RGB only,
  alpha noted in comments), plain HEX list, CSS custom properties on `:root`.

## App icon sizes

Output paths mirror a Flutter project, so the ZIP can be unpacked onto a
project root deliberately (saving into a workspace never overwrites).

| Target | Path | Size (px) | Rules |
| --- | --- | --- | --- |
| Android legacy | `android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` | 48, 72, 96, 144, 192 | alpha allowed |
| Android adaptive foreground | `.../mipmap-*/ic_launcher_foreground.png` | 108, 162, 216, 324, 432 (108 dp) | artwork scaled into the centred 72 dp safe zone (2/3 of the layer), transparent outside |
| Android adaptive icon | `.../mipmap-anydpi-v26/ic_launcher.xml` | - | background `@color/ic_launcher_background`, foreground `@mipmap/ic_launcher_foreground` |
| Android background colour | `.../values/ic_launcher_background.xml` | - | the chosen opaque background |
| Google Play | `store/google_play_icon_512.png` | 512 | 32-bit PNG, fully opaque (flattened onto the background) |
| iOS | `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-<pt>x<pt>@<n>x.png` | iPhone 20@2x/3x, 29@1x/2x/3x, 40@2x/3x, 60@2x/3x; iPad 20@1x/2x, 29@1x/2x, 40@1x/2x, 76@1x/2x, 83.5@2x; App Store 1024 | no alpha channel at all (flattened); 19 catalog slots in 15 files (iPhone and iPad share identical sizes, as in Flutter's template) |
| iOS catalog | `.../AppIcon.appiconset/Contents.json` | - | lists every slot with size, idiom, scale and file |
| Windows | `windows/runner/resources/app_icon.ico` | 16, 24, 32, 48, 64, 128, 256 | one ICO with seven PNG-compressed entries |

Non-square artwork is padded (with a chosen, possibly transparent colour) or
centre-cropped. Downscaling uses area averaging, upscaling cubic
interpolation (a note appears when the source is below 1024 px).

Verification decodes every generated file again: PNG size, iOS "no alpha
channel", Play "32-bit and opaque", ICO directory and every ICO frame, both
XML resources, and that `Contents.json` references existing files whose pixel
size equals `points x scale`. The table shows PASS/FAIL with icon and text.

The generator (`lib/features/asset_lab/domain/icon_export.dart`) has no
Flutter imports and can regenerate icons from a Dart script:

```dart
import 'dart:io';
import 'package:j3nsontop_multitool/features/asset_lab/domain/icon_export.dart';

void main() {
  final result = generateAppIcons(File('icon_1024.png').readAsBytesSync(), const IconExportOptions());
  for (final f in result.files) {
    File(f.path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(f.bytes);
  }
  final failed = verifyAppIcons(result.files).where((c) => !c.ok).toList();
  if (failed.isNotEmpty) throw StateError('${failed.length} icons failed verification');
}
```

## Atlas format

See [ATLAS_FORMAT.md](ATLAS_FORMAT.md) for the JSON layout, the padding and
extrusion geometry, the validator rules and the packing algorithm.
