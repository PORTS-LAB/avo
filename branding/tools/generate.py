#!/usr/bin/env python3
"""Generate every Avo brand asset from one geometry definition.

The mark is "Monogram a" (direction C of the logo exploration): a lowercase
"a" whose bowl is an avocado half (dark skin ring, light flesh, brown pit)
with a rounded stem on the right.

Geometry is expressed in glyph units where the outer radius of the bowl is 1
and the bowl is centred on the origin. The proportions were measured from the
approved 540 px artwork and rounded to clean ratios:

    outer radius 128.5 px  -> 1.000
    hole radius   75.0 px  -> 0.585  (ring thickness == stem width)
    pit radius    38.6 px  -> 0.300
    stem width    53.0 px  -> 0.415  (right edge flush with the bowl)
    stem cap centres at y = -0.770 (top) and +0.607 (bottom)

Run from the repository root:

    python3 -I branding/tools/generate.py

Requires `rsvg-convert` (librsvg) and `iconutil` (macOS) for raster output.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SVG_DIR = ROOT / "branding" / "svg"
PNG_DIR = ROOT / "branding" / "png"
ICON_COMPOSER_DIR = ROOT / "host" / "Avo" / "AppIcon.icon"
ASSETS_DIR = ROOT / "host" / "Avo" / "Assets.xcassets"

# Palette ---------------------------------------------------------------------

SKIN = "#2F4A1F"    # avocado skin, primary dark green
FLESH = "#D8E8A7"   # avocado flesh, primary light lime
PIT = "#7B4A2A"     # pit brown
DEEP = "#223519"    # wordmark / text on light backgrounds
CREAM = "#FBF8F1"   # page background

# Glyph geometry (glyph units, bowl centred at origin, outer radius 1) --------

R_OUT = 1.0
R_HOLE = 0.585
R_PIT = 0.300
STEM_W = R_OUT - R_HOLE            # 0.415, same as ring thickness
STEM_X0 = R_OUT - STEM_W           # 0.585, tangent to the hole
STEM_X1 = R_OUT                    # 1.000, flush with the bowl
STEM_TOP = -0.770                  # centre of the top cap
STEM_BOTTOM = 0.607                # centre of the bottom cap
CAP_R = STEM_W / 2

# Ratio of bowl radius to the square it sits on, from the approved tile.
BOWL_TO_TILE = 128.5 / 540.0


def fmt(v: float) -> str:
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


class Glyph:
    """The mark placed at centre (cx, cy) with bowl radius `scale`."""

    def __init__(self, cx: float, cy: float, scale: float) -> None:
        self.cx, self.cy, self.s = cx, cy, scale

    def x(self, gx: float) -> float:
        return self.cx + gx * self.s

    def y(self, gy: float) -> float:
        return self.cy + gy * self.s

    def circle(self, r: float, clockwise: bool) -> str:
        rr = r * self.s
        sweep = 1 if clockwise else 0
        x0, x1, y = self.cx + rr, self.cx - rr, self.cy
        return (f"M{fmt(x0)} {fmt(y)}"
                f"A{fmt(rr)} {fmt(rr)} 0 1 {sweep} {fmt(x1)} {fmt(y)}"
                f"A{fmt(rr)} {fmt(rr)} 0 1 {sweep} {fmt(x0)} {fmt(y)}Z")

    def stem(self) -> str:
        # Clockwise on screen so it adds to the bowl under the nonzero rule.
        x0, x1 = self.x(STEM_X0), self.x(STEM_X1)
        yt, yb = self.y(STEM_TOP), self.y(STEM_BOTTOM)
        r = CAP_R * self.s
        return (f"M{fmt(x0)} {fmt(yt)}"
                f"A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x1)} {fmt(yt)}"
                f"L{fmt(x1)} {fmt(yb)}"
                f"A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x0)} {fmt(yb)}Z")

    def body(self) -> str:
        """Skin: bowl ring plus stem, with the hole cut out (nonzero rule)."""
        return self.circle(R_OUT, True) + self.stem() + self.circle(R_HOLE, False)

    def flesh(self) -> str:
        return self.circle(R_HOLE, True)

    def pit(self) -> str:
        return self.circle(R_PIT, True)

    def bounds(self) -> tuple[float, float, float, float]:
        top = min(-R_OUT, STEM_TOP - CAP_R)
        bottom = max(R_OUT, STEM_BOTTOM + CAP_R)
        return self.x(-R_OUT), self.y(top), self.x(R_OUT), self.y(bottom)


def continuous_rounded_rect(x: float, y: float, w: float, h: float, r: float) -> str:
    """Apple's continuous-corner rounded rectangle (the macOS icon squircle).

    Constants match SwiftUI's RoundedRectangle(style: .continuous), verified
    against its CGPath output for the 824 pt icon body.
    """
    r = min(r, min(w, h) / 2 / 1.52866483)
    a, b, c, d, e, f, g = (1.52866483, 1.08849323, 0.86840689, 0.63149399,
                           0.07491100, 0.37282401, 0.16905899)
    X, Y = x + w, y + h

    def p(px: float, py: float) -> str:
        return f"{fmt(px)} {fmt(py)}"

    return "".join([
        f"M{p(x + a * r, y)}",
        f"L{p(X - a * r, y)}",
        f"C{p(X - b * r, y)} {p(X - c * r, y)} {p(X - d * r, y + e * r)}",
        f"C{p(X - f * r, y + g * r)} {p(X - g * r, y + f * r)} {p(X - e * r, y + d * r)}",
        f"C{p(X, y + c * r)} {p(X, y + b * r)} {p(X, y + a * r)}",
        f"L{p(X, Y - a * r)}",
        f"C{p(X, Y - b * r)} {p(X, Y - c * r)} {p(X - e * r, Y - d * r)}",
        f"C{p(X - g * r, Y - f * r)} {p(X - f * r, Y - g * r)} {p(X - d * r, Y - e * r)}",
        f"C{p(X - c * r, Y)} {p(X - b * r, Y)} {p(X - a * r, Y)}",
        f"L{p(x + a * r, Y)}",
        f"C{p(x + b * r, Y)} {p(x + c * r, Y)} {p(x + d * r, Y - e * r)}",
        f"C{p(x + f * r, Y - g * r)} {p(x + g * r, Y - f * r)} {p(x + e * r, Y - d * r)}",
        f"C{p(x, Y - c * r)} {p(x, Y - b * r)} {p(x, Y - a * r)}",
        f"L{p(x, y + a * r)}",
        f"C{p(x, y + b * r)} {p(x, y + c * r)} {p(x + e * r, y + d * r)}",
        f"C{p(x + g * r, y + f * r)} {p(x + f * r, y + g * r)} {p(x + d * r, y + e * r)}",
        f"C{p(x + c * r, y)} {p(x + b * r, y)} {p(x + a * r, y)}Z",
    ])


def svg(width: float, height: float, body: str, title: str) -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{fmt(width)}" '
            f'height="{fmt(height)}" viewBox="0 0 {fmt(width)} {fmt(height)}">'
            f"<title>{title}</title>{body}</svg>\n")


def colored_mark(g: Glyph) -> str:
    return (f'<path fill="{SKIN}" fill-rule="nonzero" d="{g.body()}"/>'
            f'<path fill="{FLESH}" d="{g.flesh()}"/>'
            f'<path fill="{PIT}" d="{g.pit()}"/>')


def mono_mark(g: Glyph, color: str) -> str:
    return (f'<path fill="{color}" fill-rule="nonzero" d="{g.body()}"/>'
            f'<path fill="{color}" d="{g.pit()}"/>')


# Asset builders ---------------------------------------------------------------

def mark_svg(mono: str | None = None) -> str:
    pad = 0.08
    g = Glyph(0, 0, 100)
    x0, y0, x1, y1 = g.bounds()
    w, h = x1 - x0, y1 - y0
    size = max(w, h) * (1 + 2 * pad)
    g = Glyph(size / 2, size / 2, 100)
    body = mono_mark(g, mono) if mono else colored_mark(g)
    return svg(size, size, body, "Avo")


def tile_svg(size: float, radius_ratio: float, bowl_ratio: float) -> str:
    g = Glyph(size / 2, size / 2, size * bowl_ratio)
    r = size * radius_ratio
    bg = f'<rect width="{fmt(size)}" height="{fmt(size)}" rx="{fmt(r)}" fill="{FLESH}"/>'
    return svg(size, size, bg + colored_mark(g), "Avo")


def macos_icon_svg() -> str:
    """Pre-Tahoe macOS app icon: 824 pt continuous squircle on a 1024 canvas."""
    body_rect = (100, 100, 824, 824)
    g = Glyph(512, 512, 824 * BOWL_TO_TILE)
    shape = continuous_rounded_rect(*body_rect, 185.4)
    defs = ('<defs><filter id="s" x="-10%" y="-10%" width="120%" height="125%">'
            '<feGaussianBlur in="SourceAlpha" stdDeviation="10"/>'
            '<feOffset dy="10"/><feComponentTransfer><feFuncA type="linear" slope="0.3"/>'
            '</feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/>'
            '</feMerge></filter></defs>')
    body = (f'{defs}<path filter="url(#s)" fill="{FLESH}" d="{shape}"/>'
            f"{colored_mark(g)}")
    return svg(1024, 1024, body, "Avo")


def menubar_svg() -> str:
    # 18x18 pt template image; the glyph is 16 pt tall.
    size = 18.0
    g = Glyph(0, 0, 1)
    x0, y0, x1, y1 = g.bounds()
    scale = 16.0 / (y1 - y0)
    g = Glyph(size / 2, size / 2, scale)
    return svg(size, size, mono_mark(g, "#000000"), "Avo")


def icon_composer(out: Path) -> None:
    """Icon Composer document for macOS 26+ (Liquid Glass, dark and tinted)."""
    canvas = 1024.0
    g = Glyph(canvas / 2, canvas / 2, canvas * BOWL_TO_TILE)
    assets = out / "Assets"
    if out.exists():
        shutil.rmtree(out)
    assets.mkdir(parents=True)
    layers = {
        "Skin": f'<path fill="{SKIN}" fill-rule="nonzero" d="{g.body()}"/>',
        "Flesh": f'<path fill="{FLESH}" d="{g.flesh()}"/>',
        "Pit": f'<path fill="{PIT}" d="{g.pit()}"/>',
    }
    for name, body in layers.items():
        (assets / f"{name}.svg").write_text(svg(canvas, canvas, body, name))

    def srgb(hex_color: str) -> str:
        r, gg, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
        return f"srgb:{r:.5f},{gg:.5f},{b:.5f},1.00000"

    doc = {
        "fill": {"solid": srgb(FLESH)},
        "groups": [{
            # Front to back: pit above flesh above skin.
            "layers": [
                {"image-name": "Pit.svg", "name": "Pit"},
                {"image-name": "Flesh.svg", "name": "Flesh"},
                {"image-name": "Skin.svg", "name": "Skin"},
            ],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0.5},
        }],
        "supported-platforms": {"squares": ["macOS"]},
    }
    (out / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")


def menubar_imageset(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    (out / "MenuBarIcon.svg").write_text(menubar_svg())
    contents = {
        "images": [{"filename": "MenuBarIcon.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True,
                       "template-rendering-intent": "template"},
    }
    (out / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def brand_colorsets(root: Path) -> None:
    for name, hex_color in (("AvoSkin", SKIN), ("AvoFlesh", FLESH),
                            ("AvoPit", PIT), ("AvoDeep", DEEP)):
        r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
        d = root / f"{name}.colorset"
        d.mkdir(parents=True, exist_ok=True)
        contents = {
            "colors": [{"color": {"color-space": "srgb", "components": {
                "alpha": "1.000", "red": f"{r:.3f}", "green": f"{g:.3f}", "blue": f"{b:.3f}"}},
                "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
        }
        (d / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


# Raster output ----------------------------------------------------------------

def render(svg_path: Path, png_path: Path, size: int) -> None:
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size),
                    "-o", str(png_path), str(svg_path)], check=True)


def build_icns(svg_path: Path, icns_path: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "Avo.iconset"
        iconset.mkdir()
        for pt in (16, 32, 128, 256, 512):
            render(svg_path, iconset / f"icon_{pt}x{pt}.png", pt)
            render(svg_path, iconset / f"icon_{pt}x{pt}@2x.png", pt * 2)
        subprocess.run(["iconutil", "-c", "icns", "-o", str(icns_path), str(iconset)], check=True)


def main() -> int:
    SVG_DIR.mkdir(parents=True, exist_ok=True)
    PNG_DIR.mkdir(parents=True, exist_ok=True)

    files = {
        "avo-mark.svg": mark_svg(),
        "avo-mark-mono.svg": mark_svg(mono=SKIN),
        "avo-mark-white.svg": mark_svg(mono="#FFFFFF"),
        # Square tile as approved (corner radius 21.3 %), used for docs.
        "avo-tile.svg": tile_svg(540, 115 / 540, BOWL_TO_TILE),
        # Full-bleed square for repository and social avatars (cropped to a circle).
        "avo-avatar.svg": tile_svg(1024, 0, BOWL_TO_TILE),
        # Favicon: tighter crop so the pit survives at 16 px.
        "avo-favicon.svg": tile_svg(64, 0.22, 0.31),
        "avo-icon-macos.svg": macos_icon_svg(),
        "avo-menubar-template.svg": menubar_svg(),
    }
    for name, content in files.items():
        (SVG_DIR / name).write_text(content)

    icon_composer(ICON_COMPOSER_DIR)
    menubar_imageset(ASSETS_DIR / "MenuBarIcon.imageset")
    brand_colorsets(ASSETS_DIR)
    (ASSETS_DIR / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

    if shutil.which("rsvg-convert") is None:
        print("rsvg-convert not found; skipped raster output", file=sys.stderr)
        return 0

    render(SVG_DIR / "avo-avatar.svg", PNG_DIR / "avo-avatar-1024.png", 1024)
    render(SVG_DIR / "avo-avatar.svg", PNG_DIR / "avo-avatar-512.png", 512)
    render(SVG_DIR / "avo-tile.svg", PNG_DIR / "avo-tile-512.png", 512)
    render(SVG_DIR / "avo-icon-macos.svg", PNG_DIR / "avo-icon-macos-1024.png", 1024)
    render(SVG_DIR / "avo-mark.svg", PNG_DIR / "avo-mark-512.png", 512)
    for px in (16, 32, 48, 180, 192, 512):
        render(SVG_DIR / "avo-favicon.svg", PNG_DIR / f"favicon-{px}.png", px)
    if shutil.which("magick"):
        subprocess.run(["magick", *(str(PNG_DIR / f"favicon-{px}.png") for px in (16, 32, 48)),
                        str(PNG_DIR / "favicon.ico")], check=True)
    if shutil.which("iconutil"):
        build_icns(SVG_DIR / "avo-icon-macos.svg", PNG_DIR / "Avo.icns")
    print("brand assets written to", SVG_DIR.relative_to(ROOT), "and", PNG_DIR.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
