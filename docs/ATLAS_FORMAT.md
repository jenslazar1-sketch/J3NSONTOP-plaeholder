# `j3atlas` texture atlas format (version 1)

The Atlas Packer (`assets.atlas`) writes two files with the same base name:

```
<name>.png    RGBA atlas image (transparent where no sprite is drawn)
<name>.json   index of every sprite rectangle (this document)
```

The JSON is UTF-8, pretty-printed with two-space indentation.

## Example

Actual output for a 16x16 `coin` and a 32x32 `potion` packed with padding 2
and extrusion 1:

```json
{
  "meta": {
    "app": "J3NSONTOP Multitool",
    "format": "j3atlas",
    "version": 1,
    "image": "items.png",
    "size": {
      "w": 38,
      "h": 58
    },
    "padding": 2,
    "extrude": 1
  },
  "frames": {
    "coin": {
      "x": 3,
      "y": 39,
      "w": 16,
      "h": 16,
      "sourceW": 16,
      "sourceH": 16
    },
    "potion": {
      "x": 3,
      "y": 3,
      "w": 32,
      "h": 32,
      "sourceW": 32,
      "sourceH": 32
    }
  }
}
```

(`potion` reserves x 2..38 and y 2..38; `coin` starts at y 39 - 1 = 38, so the
two extruded sprites are exactly 2 px apart and 2 px from every border.)

## Fields

| Field | Type | Meaning |
| --- | --- | --- |
| `meta.app` | string | Always `"J3NSONTOP Multitool"`. |
| `meta.format` | string | Always `"j3atlas"`. Readers must reject other values. |
| `meta.version` | integer | `1`. A reader for version 1 must reject higher versions. |
| `meta.image` | string | File name of the atlas PNG, relative to the JSON file. When a save had to pick a free name (`atlas (2).png`) this field names the file actually written. |
| `meta.size.w`, `meta.size.h` | integer | Atlas width and height in pixels. |
| `meta.padding` | integer | Padding `P` in pixels (0..64), see geometry. |
| `meta.extrude` | integer | Extrusion `E` in pixels (0 or 1). Added to the base layout; readers that do not know it may ignore it. |
| `frames` | object | One entry per sprite, keyed by the sprite name (unique, non-empty, no control characters). Keys are written in ascending name order. |
| `frames.<name>.x`, `.y` | integer | Top-left corner of the sprite's own pixels in the atlas. |
| `frames.<name>.w`, `.h` | integer | Size of the sprite's pixels in the atlas. |
| `frames.<name>.sourceW`, `.sourceH` | integer | Size of the original image. Version 1 never trims or scales, so these always equal `w` and `h`. |

Readers must ignore unknown fields so later minor additions stay compatible.

## Geometry

* Sprites are **never rotated**. There is no rotation flag; `w`/`h` are the
  upright size.
* **Extrusion** (`E` = 0 or 1): the sprite's outermost row/column of pixels
  is copied `E` pixels outward on every side (corners included). The frame
  rectangle excludes the extrusion, so sampling inside `(x, y, w, h)` gives
  the original pixels while linear filtering at the edges does not bleed in
  transparent or neighbouring pixels.
* **Padding** (`P`): at least `P` fully transparent pixels separate any two
  extruded sprites, and every extruded sprite is at least `P` pixels away
  from each atlas border.

Formally, for each frame define the reserved box

```
K = [x - E, x + w + E + P) x [y - E, y + h + E + P)
```

A valid atlas satisfies, for every frame, `x - E >= P`, `y - E >= P`,
`x + w + E + P <= size.w` and `y + h + E + P <= size.h`, and no two reserved
boxes intersect. The packer's independent validator checks exactly these
rules (with a sweep over x, then pairwise checks within the sweep window) on
every pack and the result is shown in the tool.

## Packing algorithm

* Each sprite reserves `(w + 2E + P) x (h + 2E + P)`; boxes are packed into a
  bin of `(W - P) x (H - P)` and shifted by `(P, P)`.
* Primary heuristic: **MaxRects best-short-side-fit** (Jylänki, "A Thousand
  Ways to Pack the Bin"), sprites ordered by longest side, then area, then
  name.
* Documented fallback, only used when the primary heuristic cannot fit every
  sprite within the maximum size: MaxRects **best-area-fit** (same order),
  then MaxRects **bottom-left** with a height-first order. The heuristic used
  is shown in the result.
* Size search: several candidate widths (all powers of two when the
  power-of-two option is on, otherwise a geometric series around
  `sqrt(total area)`) are packed into a tall bin. The result with the lowest
  cost wins, where cost = area x (1 + 0.05 x (long side / short side - 1)):
  smaller atlases first, with a mild preference for square-ish ones when the
  areas are close (ties: shorter longest side, then narrower). Without the
  power-of-two option the atlas is trimmed to the used width/height plus the
  padding border.
* The packer is deterministic: the same sprites and options always give the
  same layout and byte-identical JSON.
* Maximum atlas size: 256, 512, 1024, 2048, 4096 or 8192. When sprites do not
  fit, the error names the largest sprite and, by probing up to 16384 px, the
  size the set would actually need.

## Reading an atlas (pseudo code)

```
atlas = json.decode(read("<name>.json"))
assert atlas.meta.format == "j3atlas" and atlas.meta.version == 1
texture = loadImage(dirname(json) / atlas.meta.image)
for name, f in atlas.frames:
    uv = (f.x / meta.size.w, f.y / meta.size.h, (f.x + f.w) / meta.size.w, (f.y + f.h) / meta.size.h)
```
