#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
#
# Makes PatchPrimeMac's app icon: packaging/icon/icon.svg, icon.png (1024 px) and
# AppIcon.icns. The style is SimpleHPSDR's and SimpleDream's: a dark slate tile with
# a faint grid, blue, cyan and yellow. The picture is a mixing console: four channel
# strips, each a fader at its own height beside a segmented level meter.
#
#   scripts/make-icon.py
#
# Needs rsvg-convert (brew install librsvg), ImageMagick and iconutil (macOS).

import os
import shutil
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "packaging", "icon")

TILE = (100, 100, 824, 185)  # x, y, size, corner radius: as SimpleHPSDR's
STRIPS = [  # (fader position 0 bottom..1 top, meter level 0..1)
    (0.62, 0.78),
    (0.38, 0.52),
    (0.74, 0.90),
    (0.50, 0.64),
]
SEGMENTS = 11
SEG_COLOURS = ["#123a8c", "#123a8c", "#106BD8", "#106BD8", "#106BD8", "#2ED3C8",
               "#2ED3C8", "#2ED3C8", "#F5D03B", "#F5D03B", "#F9DF83"]


def svg():
    x0, y0, size, r = TILE
    parts = [f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
<linearGradient id="tile" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1F2633"/><stop offset="1" stop-color="#0B0D11"/></linearGradient>
<linearGradient id="cap" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F4F7FC"/><stop offset="1" stop-color="#AEB8C8"/></linearGradient>
<linearGradient id="glow" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3B82F6" stop-opacity="0.0"/><stop offset="1" stop-color="#3B82F6" stop-opacity="0.18"/></linearGradient>
<clipPath id="c"><rect x="{x0}" y="{y0}" width="{size}" height="{size}" rx="{r}"/></clipPath>
</defs>
<rect x="{x0}" y="{y0}" width="{size}" height="{size}" rx="{r}" fill="url(#tile)"/>
<g clip-path="url(#c)">
<rect x="{x0}" y="{y0 + size // 2}" width="{size}" height="{size // 2}" fill="url(#glow)"/>
<g stroke="#FFFFFF" stroke-opacity="0.06" stroke-width="3">''']
    for y in (300, 512, 724):  # the faint grid, as on SimpleHPSDR's
        parts.append(f'<line x1="{x0}" y1="{y}" x2="{x0 + size}" y2="{y}"/>')
    parts.append("</g>")
    top, bottom = 230, 800             # the travel of the faders and meters
    pitch = 168                        # one strip to the next
    first = 512 - pitch * (len(STRIPS) - 1) / 2 - 24
    for i, (fader, level) in enumerate(STRIPS):
        cx = first + i * pitch         # the fader's slot
        mx = cx + 52                   # its meter
        # The slot, and the part of it below the cap lit in blue.
        cap_y = bottom - fader * (bottom - top)
        parts.append(f'<rect x="{cx - 7}" y="{top}" width="14" height="{bottom - top}" rx="7" fill="#05070A" stroke="#FFFFFF" stroke-opacity="0.08" stroke-width="2"/>')
        parts.append(f'<rect x="{cx - 5}" y="{cap_y}" width="10" height="{bottom - cap_y}" rx="5" fill="#3B82F6" opacity="0.85"/>')
        # The meter: segments up to its level, the rest dark.
        seg_h = (bottom - top) / SEGMENTS
        lit = round(level * SEGMENTS)
        for s in range(SEGMENTS):
            y = bottom - (s + 1) * seg_h + 4
            colour = SEG_COLOURS[s] if s < lit else "#1A2130"
            opacity = 0.95 if s < lit else 0.9
            parts.append(f'<rect x="{mx - 13}" y="{y:.1f}" width="26" height="{seg_h - 8:.1f}" rx="5" fill="{colour}" opacity="{opacity}"/>')
        # The cap: a light block with a groove across it.
        parts.append(f'<rect x="{cx - 38}" y="{cap_y - 30:.1f}" width="76" height="60" rx="12" fill="url(#cap)" stroke="#0B0D11" stroke-opacity="0.6" stroke-width="3"/>')
        parts.append(f'<rect x="{cx - 30}" y="{cap_y - 3:.1f}" width="60" height="6" rx="3" fill="#3B82F6"/>')
    parts.append("</g>")
    parts.append(f'<rect x="{x0 + 0.5}" y="{y0 + 0.5}" width="{size - 1}" height="{size - 1}" rx="{r}" fill="none" stroke="#FFFFFF" stroke-opacity="0.09" stroke-width="2"/>')
    parts.append("</svg>\n")
    return "\n".join(parts)


def run(args):
    subprocess.run(args, check=True, capture_output=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    svg_path = os.path.join(OUT, "icon.svg")
    with open(svg_path, "w") as f:
        f.write(svg())
    png = os.path.join(OUT, "icon.png")
    # librsvg, not ImageMagick's own SVG reader, which drops gradients.
    run(["rsvg-convert", "-w", "1024", "-h", "1024", "-o", png, svg_path])
    run(["magick", png, "-strip", png])
    work = tempfile.mkdtemp()
    iconset = os.path.join(work, "AppIcon.iconset")
    os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            run(["magick", png, "-resize", f"{px}x{px}", "-strip", os.path.join(iconset, name)])
    run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(OUT, "AppIcon.icns")])
    shutil.rmtree(work)
    print("made", svg_path, png, os.path.join(OUT, "AppIcon.icns"))


if __name__ == "__main__":
    main()
