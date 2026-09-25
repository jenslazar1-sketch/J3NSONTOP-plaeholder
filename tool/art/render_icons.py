#!/usr/bin/env python3
"""Render the J3NSONTOP skull artwork to every platform icon and splash asset.

Pipeline
--------
1. The SVG sources in tool/art/ are rasterised once, at high resolution, by
   headless Chromium (driven through Playwright):

     skull_icon.svg         rounded tile (as is) and opaque square ("full-bleed")
     skull_icon_small.svg   the same two shapes for <= 32 px
     skull_foreground.svg   the skull alone on a transparent canvas
     skull_small.svg        the bold small skull on a transparent canvas
     skull_monochrome.svg   white silhouette for Android 13+ themed icons

2. Every platform asset is then derived from those masters with Pillow only
   (fixed resampling filters, fixed placement maths, no timestamps), so the
   output is deterministic for a given Chromium build.

3. A verification pass checks sizes, alpha rules, the ICO directory, the XML
   and JSON wiring and the storyboard.

Usage
-----
    pip install pillow numpy playwright
    python3 tool/art/render_icons.py                  # render + verify
    python3 tool/art/render_icons.py --preview DIR    # also write review sheets
    python3 tool/art/render_icons.py --verify-only    # no browser needed

Chromium: set CHROMIUM=/path/to/chrome (or headless_shell). Otherwise the
script looks in $PLAYWRIGHT_BROWSERS_PATH (default /opt/pw-browsers and
~/.cache/ms-playwright) and finally falls back to Playwright's own default.
It never downloads a browser.

The Android/iOS XML wiring (adaptive icon XML, colors, launch_background,
styles, LaunchScreen.storyboard) is static, hand-written and only verified
here; see docs/ASSETS.md.
"""
from __future__ import annotations

import argparse
import glob
import io
import json
import os
import re
import struct
import sys
import xml.dom.minidom
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / 'tool' / 'art'
RES = ROOT / 'android' / 'app' / 'src' / 'main' / 'res'
IOS = ROOT / 'ios' / 'Runner'
APPICON = IOS / 'Assets.xcassets' / 'AppIcon.appiconset'
LAUNCH = IOS / 'Assets.xcassets' / 'LaunchImage.imageset'
STORYBOARD = IOS / 'Base.lproj' / 'LaunchScreen.storyboard'
ICO = ROOT / 'windows' / 'runner' / 'resources' / 'app_icon.ico'
IMAGES = ROOT / 'assets' / 'images'

BACKGROUND = (0x05, 0x05, 0x07)
DENSITIES = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0}
ICO_SIZES = (16, 24, 32, 48, 64, 128, 256)
SMALL_MAX = 32  # sizes <= this use the simplified small artwork

# Placement (all in dp / pt; see docs/ASSETS.md).
ADAPTIVE_CANVAS_DP = 108  # adaptive icon layer
ADAPTIVE_SAFE_RADIUS_DP = 30  # skull stays inside the 66 dp safe circle (3 dp margin)
ADAPTIVE_FADE_DP = 36  # its glow fades out inside the 72 dp visible viewport
SPLASH_SKULL_DP = 150  # visible skull height on every launch screen
SPLASH12_CANVAS_DP = 288  # Android 12+ windowSplashScreenAnimatedIcon canvas
SPLASH12_CIRCLE_DP = 192  # ... whose content (glow included) must fit this circle
SPLASH_CANVAS_DP = 200  # pre-Android 12 launch bitmap and iOS LaunchImage (1x)
MASTER = 2048  # master raster size for the 1024-unit SVGs
SMALL_MASTER = 1536  # master raster size for the 32-unit SVGs (48x)
SOLID = 128  # alpha threshold that separates the skull from its glow


# --------------------------------------------------------------------------
# Rendering with headless Chromium
# --------------------------------------------------------------------------

def find_chromium() -> str | None:
    env = os.environ.get('CHROMIUM')
    if env:
        return env
    roots = [os.environ.get('PLAYWRIGHT_BROWSERS_PATH', ''), '/opt/pw-browsers',
             str(Path.home() / '.cache' / 'ms-playwright')]
    patterns = ['chromium_headless_shell-*/chrome-linux/headless_shell',
                'chromium-*/chrome-linux/chrome',
                'chromium_headless_shell-*/chrome-mac/headless_shell',
                'chromium-*/chrome-win/chrome.exe']
    for root in filter(None, roots):
        for pattern in patterns:
            hits = sorted(glob.glob(os.path.join(root, pattern)))
            if hits:
                return hits[-1]
    return None


class Renderer:
    """Rasterises SVG files by opening them as documents in headless Chromium."""

    def __enter__(self) -> 'Renderer':
        from playwright.sync_api import sync_playwright  # imported lazily
        self._pw = sync_playwright().start()
        exe = find_chromium()
        self._browser = self._pw.chromium.launch(executable_path=exe) if exe else self._pw.chromium.launch()
        self._page = self._browser.new_page(device_scale_factor=1)
        return self

    def __exit__(self, *exc) -> None:
        self._browser.close()
        self._pw.stop()

    def render(self, svg: Path, size: int, classes: tuple[str, ...] = ()) -> Image.Image:
        page = self._page
        page.set_viewport_size({'width': size, 'height': size})
        page.goto(svg.resolve().as_uri(), wait_until='load')
        page.evaluate(
            """([size, classes]) => {
                const svg = document.documentElement;
                svg.setAttribute('width', size);
                svg.setAttribute('height', size);
                for (const c of classes) svg.classList.add(c);
            }""",
            [size, list(classes)],
        )
        # Nested <image> SVGs re-rasterise after the resize; give them a frame.
        page.wait_for_timeout(250)
        png = page.screenshot(omit_background=True, clip={'x': 0, 'y': 0, 'width': size, 'height': size})
        img = Image.open(io.BytesIO(png)).convert('RGBA')
        assert img.size == (size, size), (svg, img.size)
        return img


# --------------------------------------------------------------------------
# Pillow helpers (deterministic)
# --------------------------------------------------------------------------

def resize(img: Image.Image, px: int, small: bool = False) -> Image.Image:
    """Downscale a square master. Small pixel-grid art uses area averaging
    (crisp), the detailed art Lanczos (sharp). Pillow premultiplies alpha."""
    return img.resize((px, px), Image.Resampling.BOX if small else Image.Resampling.LANCZOS)


def opaque(img: Image.Image) -> Image.Image:
    """Flatten onto the background colour and drop the alpha channel."""
    base = Image.new('RGBA', img.size, BACKGROUND + (255,))
    base.alpha_composite(img)
    return base.convert('RGB')


def solid_geometry(img: Image.Image) -> tuple[tuple[float, float], float, float]:
    """(centre, height, max radius) of the solid part of the artwork
    (alpha >= SOLID), i.e. the skull without its glow, in master pixels."""
    a = np.asarray(img.getchannel('A'))
    ys, xs = np.nonzero(a >= SOLID)
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    rmax = float(np.sqrt((xs + 0.5 - cx) ** 2 + (ys + 0.5 - cy) ** 2).max())
    return (cx, cy), float(y1 - y0), rmax


def place(master: Image.Image, geo, canvas: int, scale: float,
          fade_to: float | None = None) -> Image.Image:
    """Scale `master` by `scale` and centre its solid part on a transparent
    `canvas` x `canvas` image. With `fade_to` (px from the centre) the glow is
    faded out radially, starting just outside the solid skull, so nothing is
    cut off hard by a launcher mask, a splash circle or the canvas edge."""
    (cx, cy), _, rmax = geo
    half = canvas / scale / 2  # canvas half-size in master pixels
    # Integer crop (Pillow zero-fills outside the master), then an exact
    # fractional box for the resample.
    x0, y0 = int(np.floor(cx - half)) - 1, int(np.floor(cy - half)) - 1
    x1, y1 = int(np.ceil(cx + half)) + 1, int(np.ceil(cy + half)) + 1
    region = master.crop((x0, y0, x1, y1))
    box = (cx - half - x0, cy - half - y0, cx + half - x0, cy + half - y0)
    out = region.resize((canvas, canvas), Image.Resampling.LANCZOS, box=box)
    if fade_to:
        r0 = rmax * scale + canvas * 0.01
        assert r0 < fade_to, f'skull (r={rmax * scale:.1f}px) does not fit inside r={fade_to:.1f}px'
        out = radial_fade(out, r0, fade_to)
    return out


def radial_fade(img: Image.Image, r0: float, r1: float) -> Image.Image:
    n = img.width
    yy, xx = np.mgrid[0:n, 0:n] + 0.5
    r = np.hypot(xx - n / 2, yy - n / 2)
    t = np.clip((r - r0) / (r1 - r0), 0, 1)
    k = 1 - t * t * (3 - 2 * t)  # smoothstep
    arr = np.asarray(img).astype(np.float64)
    arr[..., 3] *= k
    return Image.fromarray(np.round(arr).astype(np.uint8), 'RGBA')


def save_png(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, 'PNG', optimize=True)


def write_ico(images: dict[int, Image.Image], path: Path) -> None:
    """Classic ICO: 32-bit BGRA DIB entries (+ AND mask) up to 128 px and a
    PNG entry for 256 px, like the Visual Studio / Flutter template icon."""
    entries = []
    for size in sorted(images):
        img = images[size].convert('RGBA')
        assert img.size == (size, size)
        if size >= 256:
            buf = io.BytesIO()
            img.save(buf, 'PNG', optimize=True)
            data = buf.getvalue()
        else:
            rgba = np.asarray(img)
            bgra = rgba[::-1, :, [2, 1, 0, 3]].tobytes()  # bottom-up rows
            row_bytes = ((size + 31) // 32) * 4
            mask_bits = np.packbits((rgba[::-1, :, 3] == 0).astype(np.uint8), axis=1)
            mask = b''.join(r.tobytes().ljust(row_bytes, b'\0') for r in mask_bits)
            header = struct.pack('<IiiHHIIiiII', 40, size, size * 2, 1, 32, 0,
                                 len(bgra) + len(mask), 0, 0, 0, 0)
            data = header + bgra + mask
        entries.append((size, data))
    out = io.BytesIO()
    out.write(struct.pack('<HHH', 0, 1, len(entries)))
    offset = 6 + 16 * len(entries)
    for size, data in entries:
        dim = 0 if size >= 256 else size
        out.write(struct.pack('<BBBBHHII', dim, dim, 0, 0, 1, 32, len(data), offset))
        offset += len(data)
    for _, data in entries:
        out.write(data)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(out.getvalue())


def read_ico_sizes(path: Path) -> list[tuple[int, int, str]]:
    data = path.read_bytes()
    reserved, kind, count = struct.unpack('<HHH', data[:6])
    assert reserved == 0 and kind == 1, 'not an ICO file'
    out = []
    for i in range(count):
        w, h, _, _, _, bpp, size, off = struct.unpack('<BBBBHHII', data[6 + 16 * i:22 + 16 * i])
        blob = data[off:off + size]
        fmt = 'png' if blob[:8] == b'\x89PNG\r\n\x1a\n' else 'dib'
        img = Image.open(io.BytesIO(blob)) if fmt == 'png' else None
        if img is not None:
            assert img.size == (w or 256, h or 256)
        out.append((w or 256, bpp, fmt))
    return out


# --------------------------------------------------------------------------
# Asset generation
# --------------------------------------------------------------------------

def render_masters() -> dict[str, Image.Image]:
    with Renderer() as r:
        return {
            'icon': r.render(ART / 'skull_icon.svg', MASTER),
            'icon_square': r.render(ART / 'skull_icon.svg', MASTER, ('full-bleed',)),
            'small': r.render(ART / 'skull_icon_small.svg', SMALL_MASTER),
            'small_square': r.render(ART / 'skull_icon_small.svg', SMALL_MASTER, ('full-bleed',)),
            'fg': r.render(ART / 'skull_foreground.svg', MASTER),
            'fg_small': r.render(ART / 'skull_small.svg', SMALL_MASTER),
            'mono': r.render(ART / 'skull_monochrome.svg', MASTER),
        }


def icon_at(m: dict[str, Image.Image], px: int, square: bool = False) -> Image.Image:
    if px <= SMALL_MAX:
        return resize(m['small_square' if square else 'small'], px, small=True)
    return resize(m['icon_square' if square else 'icon'], px)


def generate(m: dict[str, Image.Image]) -> list[Path]:
    written: list[Path] = []

    def out(img: Image.Image, path: Path) -> None:
        save_png(img, path)
        if path not in written:  # iPhone and iPad share some iOS files
            written.append(path)

    fg_geo = solid_geometry(m['fg'])
    _, fg_h, fg_r = fg_geo

    # ---- Android launcher icons ------------------------------------------
    for name, d in DENSITIES.items():
        out(icon_at(m, round(48 * d)), RES / f'mipmap-{name}' / 'ic_launcher.png')
        canvas = round(ADAPTIVE_CANVAS_DP * d)
        scale = ADAPTIVE_SAFE_RADIUS_DP * d / fg_r
        out(place(m['fg'], fg_geo, canvas, scale, ADAPTIVE_FADE_DP * d),
            RES / f'mipmap-{name}' / 'ic_launcher_foreground.png')
        mono = place(m['mono'], fg_geo, canvas, scale)
        white = Image.new('RGBA', mono.size, (255, 255, 255, 0))
        white.putalpha(mono.getchannel('A'))
        out(white, RES / f'mipmap-{name}' / 'ic_launcher_monochrome.png')

    # ---- Android launch screens --------------------------------------------
    splash_scale_dp = SPLASH_SKULL_DP / fg_h  # master px -> dp
    for name, d in DENSITIES.items():
        # Pre-Android 12: bitmap centred on the launch_background layer list.
        c = round(SPLASH_CANVAS_DP * d)
        out(place(m['fg'], fg_geo, c, splash_scale_dp * d, c / 2),
            RES / f'drawable-{name}' / 'splash_skull.png')
        # Android 12+: 288 dp canvas, everything inside the 192 dp circle.
        c = round(SPLASH12_CANVAS_DP * d)
        out(place(m['fg'], fg_geo, c, splash_scale_dp * d, SPLASH12_CIRCLE_DP / 2 * d),
            RES / f'drawable-{name}' / 'splash_icon.png')

    # ---- iOS app icons (opaque, full bleed) ------------------------------
    contents = json.loads((APPICON / 'Contents.json').read_text())
    for entry in contents['images']:
        pt = float(entry['size'].split('x')[0])
        px = round(pt * int(entry['scale'].rstrip('x')))
        out(opaque(icon_at(m, px, square=True)), APPICON / entry['filename'])

    # ---- iOS launch image (transparent, centred by the storyboard) -------
    for suffix, d in (('', 1), ('@2x', 2), ('@3x', 3)):
        c = SPLASH_CANVAS_DP * d
        out(place(m['fg'], fg_geo, c, splash_scale_dp * d, c / 2), LAUNCH / f'LaunchImage{suffix}.png')

    # ---- Windows ---------------------------------------------------------
    write_ico({s: icon_at(m, s) for s in ICO_SIZES}, ICO)
    written.append(ICO)

    # ---- In-app images ---------------------------------------------------
    out(place(m['fg'], fg_geo, 512, 384 / fg_h, 256), IMAGES / 'skull_logo.png')
    out(place(m['fg'], fg_geo, 128, 100 / fg_h, 64), IMAGES / 'skull_logo_128.png')
    out(resize(m['fg_small'], 64, small=True), IMAGES / 'skull_logo_64.png')
    return written


# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------

def verify() -> list[str]:
    problems: list[str] = []

    def check(cond: bool, msg: str) -> None:
        if not cond:
            problems.append(msg)

    def png(path: Path, size: int, mode: str | None = None) -> None:
        if not path.exists():
            problems.append(f'missing {path.relative_to(ROOT)}')
            return
        with Image.open(path) as im:
            check(im.size == (size, size), f'{path.relative_to(ROOT)}: {im.size} != {size}')
            if mode:
                check(im.mode == mode, f'{path.relative_to(ROOT)}: mode {im.mode} != {mode}')

    for name, d in DENSITIES.items():
        png(RES / f'mipmap-{name}' / 'ic_launcher.png', round(48 * d), 'RGBA')
        png(RES / f'mipmap-{name}' / 'ic_launcher_foreground.png', round(108 * d), 'RGBA')
        png(RES / f'mipmap-{name}' / 'ic_launcher_monochrome.png', round(108 * d), 'RGBA')
        png(RES / f'drawable-{name}' / 'splash_skull.png', round(SPLASH_CANVAS_DP * d), 'RGBA')
        png(RES / f'drawable-{name}' / 'splash_icon.png', round(SPLASH12_CANVAS_DP * d), 'RGBA')

    contents = json.loads((APPICON / 'Contents.json').read_text())
    for entry in contents['images']:
        pt = float(entry['size'].split('x')[0])
        png(APPICON / entry['filename'], round(pt * int(entry['scale'].rstrip('x'))), 'RGB')
    launch = json.loads((LAUNCH / 'Contents.json').read_text())
    for entry, d in zip(launch['images'], (1, 2, 3)):
        png(LAUNCH / entry['filename'], SPLASH_CANVAS_DP * d, 'RGBA')

    sizes = read_ico_sizes(ICO)
    check([s for s, _, _ in sizes] == list(ICO_SIZES), f'ICO sizes {sizes}')
    check(all(bpp == 32 for _, bpp, _ in sizes), 'ICO entries must be 32 bpp')

    png(IMAGES / 'skull_logo.png', 512, 'RGBA')
    png(IMAGES / 'skull_logo_128.png', 128, 'RGBA')
    png(IMAGES / 'skull_logo_64.png', 64, 'RGBA')

    # XML wiring.
    xml_files = sorted(RES.glob('*/*.xml')) + [STORYBOARD]
    for path in xml_files:
        try:
            xml.dom.minidom.parse(str(path))
        except Exception as e:  # noqa: BLE001
            problems.append(f'{path.relative_to(ROOT)}: XML error {e}')
    adaptive = (RES / 'mipmap-anydpi-v26' / 'ic_launcher.xml').read_text()
    for ref in ('@color/ic_launcher_background', '@mipmap/ic_launcher_foreground', '@mipmap/ic_launcher_monochrome'):
        check(ref in adaptive, f'adaptive icon misses {ref}')
    colors = (RES / 'values' / 'colors.xml').read_text()
    check('name="ic_launcher_background">#050507<' in colors, 'colors.xml: ic_launcher_background')
    for folder in ('drawable', 'drawable-v21'):
        text = (RES / folder / 'launch_background.xml').read_text()
        check('@drawable/splash_skull' in text, f'{folder}/launch_background.xml misses splash_skull')
    for folder in ('values', 'values-night', 'values-v31', 'values-night-v31'):
        text = (RES / folder / 'styles.xml').read_text()
        check('name="LaunchTheme"' in text and '@drawable/launch_background' in text, f'{folder}/styles.xml LaunchTheme')
        if folder.endswith('v31'):
            for item in ('windowSplashScreenBackground', 'windowSplashScreenAnimatedIcon',
                         'windowSplashScreenIconBackgroundColor', '@drawable/splash_icon'):
                check(item in text, f'{folder}/styles.xml misses {item}')
        else:
            check('name="NormalTheme"' in text, f'{folder}/styles.xml NormalTheme')

    board = STORYBOARD.read_text()
    m = re.search(r'<image name="LaunchImage" width="([\d.]+)" height="([\d.]+)"', board)
    check(bool(m) and float(m.group(1)) == SPLASH_CANVAS_DP == float(m.group(2)),
          'storyboard LaunchImage size must match LaunchImage.png')
    check('image="LaunchImage"' in board, 'storyboard must show LaunchImage')
    check('red="0.0196' in board, 'storyboard background must be #050507')
    return problems


# --------------------------------------------------------------------------
# Review sheets
# --------------------------------------------------------------------------

def previews(m: dict[str, Image.Image], out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    opaque(m['icon_square']).resize((1024, 1024), Image.Resampling.LANCZOS).save(out_dir / 'master_1024.png')

    def zoom(img: Image.Image, k: int) -> Image.Image:
        return img.resize((img.width * k, img.height * k), Image.Resampling.NEAREST)

    # Small sizes on a dark and a light desktop, magnified 8x.
    for bg_name, bg in (('dark', (32, 32, 36)), ('light', (236, 236, 240))):
        sizes = (16, 24, 32, 48)
        sheet = Image.new('RGBA', (sum(s * 8 + 24 for s in sizes) + 24, 48 * 8 + 48), bg + (255,))
        x = 24
        for s in sizes:
            sheet.alpha_composite(zoom(icon_at(m, s), 8), (x, 24))
            x += s * 8 + 24
        sheet.save(out_dir / f'icons_small_x8_{bg_name}.png')
    strip_sizes = (16, 24, 32, 48, 64, 96, 128, 180, 256)
    strip = Image.new('RGBA', (sum(s + 16 for s in strip_sizes) + 16, 256 + 32), (32, 32, 36, 255))
    x = 16
    for s in strip_sizes:
        strip.alpha_composite(icon_at(m, s), (x, 16))
        x += s + 16
    strip.save(out_dir / 'icons_strip.png')

    # Adaptive icon under circle / squircle / rounded-square masks.
    fg = Image.open(RES / 'mipmap-xxxhdpi' / 'ic_launcher_foreground.png').convert('RGBA')
    mono = Image.open(RES / 'mipmap-xxxhdpi' / 'ic_launcher_monochrome.png').convert('RGBA')
    n = fg.width  # 432 = 108 dp
    view = round(n * 72 / 108)
    off = (n - view) // 2
    sheet = Image.new('RGBA', (4 * (view + 32) + 32, view + 64), (40, 44, 52, 255))
    for i, shape in enumerate(('circle', 'squircle', 'rounded', 'themed')):
        layer = Image.new('RGBA', (n, n), BACKGROUND + (255,))
        if shape == 'themed':
            layer = Image.new('RGBA', (n, n), (0x3b, 0x2f, 0x36, 255))
            tint = Image.new('RGBA', (n, n), (0xff, 0xd9, 0xe0, 255))
            tint.putalpha(mono.getchannel('A'))
            layer.alpha_composite(tint)
        else:
            layer.alpha_composite(fg)
        layer = layer.crop((off, off, off + view, off + view))
        mask = Image.new('L', (view * 4, view * 4), 0)
        d = ImageDraw.Draw(mask)
        if shape in ('circle', 'themed'):
            d.ellipse((0, 0, view * 4 - 1, view * 4 - 1), fill=255)
        elif shape == 'squircle':
            d.rounded_rectangle((0, 0, view * 4 - 1, view * 4 - 1), radius=view * 4 * 0.38, fill=255)
        else:
            d.rounded_rectangle((0, 0, view * 4 - 1, view * 4 - 1), radius=view * 4 * 0.16, fill=255)
        mask = mask.resize((view, view), Image.Resampling.LANCZOS)
        tile = Image.new('RGBA', (view, view), (0, 0, 0, 0))
        tile.paste(layer, (0, 0), mask)
        # 66 dp safe circle guide
        g = ImageDraw.Draw(tile)
        rr = n * 33 / 108
        c = view / 2
        g.ellipse((c - rr, c - rr, c + rr, c + rr), outline=(80, 200, 255, 90), width=1)
        sheet.alpha_composite(tile, (32 + i * (view + 32), 32))
    sheet.save(out_dir / 'adaptive_masks.png')

    # Mock launch screens: Android 12 (icon), pre-12 (bitmap) and iOS.
    phone = (412, 892)
    shots = []
    for label, path, scale in (
            ('android12', RES / 'drawable-xxhdpi' / 'splash_icon.png', 3),
            ('android', RES / 'drawable-xxhdpi' / 'splash_skull.png', 3),
            ('ios', LAUNCH / 'LaunchImage@3x.png', 3)):
        w, h = phone[0] * scale, phone[1] * scale
        screen = Image.new('RGBA', (w, h), BACKGROUND + (255,))
        img = Image.open(path).convert('RGBA')
        screen.alpha_composite(img, ((w - img.width) // 2, (h - img.height) // 2))
        if label == 'android12':
            g = ImageDraw.Draw(screen)
            r = SPLASH12_CIRCLE_DP / 2 * scale
            g.ellipse((w / 2 - r, h / 2 - r, w / 2 + r, h / 2 + r), outline=(80, 200, 255, 70), width=2)
        shots.append(screen.resize((phone[0], phone[1]), Image.Resampling.LANCZOS))
    sheet = Image.new('RGBA', (3 * (phone[0] + 24) + 24, phone[1] + 48), (40, 44, 52, 255))
    for i, s in enumerate(shots):
        sheet.alpha_composite(s, (24 + i * (phone[0] + 24), 24))
    sheet.save(out_dir / 'splash_mock.png')

    # In-app logos over the app surfaces.
    sheet = Image.new('RGBA', (512 + 128 + 64 + 4 * 32, 512 + 64), (0x10, 0x10, 0x15, 255))
    x = 32
    for name in ('skull_logo.png', 'skull_logo_128.png', 'skull_logo_64.png'):
        img = Image.open(IMAGES / name).convert('RGBA')
        sheet.alpha_composite(img, (x, 32))
        x += img.width + 32
    sheet.save(out_dir / 'in_app_logos.png')


# --------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--verify-only', action='store_true', help='only run the checks')
    ap.add_argument('--preview', type=Path, help='write review sheets into this directory')
    args = ap.parse_args()

    if not args.verify_only:
        masters = render_masters()
        written = generate(masters)
        for path in written:
            if path.suffix == '.ico':
                desc = ', '.join(f'{s}px/{fmt}' for s, _, fmt in read_ico_sizes(path))
            else:
                with Image.open(path) as im:
                    desc = f'{im.width}x{im.height} {im.mode}'
            print(f'{path.relative_to(ROOT)}  {desc}  {path.stat().st_size} B')
        if args.preview:
            previews(masters, args.preview)
            print(f'previews -> {args.preview}')
    problems = verify()
    for p in problems:
        print('PROBLEM:', p, file=sys.stderr)
    print('verify:', 'OK' if not problems else f'{len(problems)} problem(s)')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
