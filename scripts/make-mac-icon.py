# Mac app icon: the iPad icon's blue gradient, a white cloud with a blue play symbol,
# on the macOS rounded-square shape with its soft shadow. Needs Pillow.
#   python3 scripts/make-mac-icon.py icon.png
#   then make an AppIcon.iconset from it with sips and run: iconutil -c icns AppIcon.iconset
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4                      # drawn 4x larger, then reduced: smooth edges
N = 1024 * S
out = sys.argv[1]

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

top, bottom = (0x25, 0x6c, 0xe8), (0x14, 0x29, 0x7a)
gradient = Image.new("RGB", (N, N))
g = ImageDraw.Draw(gradient)
for y in range(N):
    g.line([(0, y), (N, y)], fill=lerp(top, bottom, y / N))

# macOS icon grid: an 824 pt rounded square in a 1024 pt canvas.
inset, size, radius = 100 * S, 824 * S, 185 * S
mask = Image.new("L", (N, N), 0)
ImageDraw.Draw(mask).rounded_rectangle([inset, inset, inset + size, inset + size], radius, fill=255)

canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + 12 * S, inset + size, inset + size + 12 * S],
                                         radius, fill=(0, 0, 0, 90))
canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(18 * S)))
body = Image.new("RGBA", (N, N), (0, 0, 0, 0))
body.paste(gradient, (0, 0), mask)
canvas = Image.alpha_composite(canvas, body)

# The cloud: circles on a rounded base.
d = ImageDraw.Draw(canvas)
white = (0xf5, 0xf7, 0xfc, 255)
cx, base = 512 * S, 640 * S
d.rounded_rectangle([cx - 270 * S, base - 150 * S, cx + 275 * S, base + 30 * S], 90 * S, fill=white)
for x, y, r in [(-155, -100, 115), (25, -195, 165), (170, -95, 105)]:
    d.ellipse([cx + (x - r) * S, base + (y - r) * S, cx + (x + r) * S, base + (y + r) * S], fill=white)

# The play symbol, a little below the middle of the cloud.
px, py, h = cx + 10 * S, base - 105 * S, 150 * S
d.polygon([(px - 0.42 * h, py - h / 2), (px - 0.42 * h, py + h / 2), (px + 0.5 * h, py)],
          fill=(0x26, 0x6e, 0xeb, 255))

canvas.resize((1024, 1024), Image.LANCZOS).save(out)
