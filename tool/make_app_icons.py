"""Generate every platform's app icon from branding/app_icon.png.

usage (from the repo root):  python tool/make_app_icons.py

The master is a square, full-bleed render on the logo's dark violet
background. Each platform gets the shape it expects: iOS full-bleed squares
without transparency (iOS rounds them), Android legacy rounded squares plus an
adaptive icon, macOS's inset rounded tile, a Windows .ico, and web icons.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
MASTER = Image.open(ROOT / "branding/app_icon.png").convert("RGB")
BG = (20, 1, 33)  # the logo's background, #140121


def square(size):
    return MASTER.resize((size, size), Image.LANCZOS)


def rounded(size, radius=0.225, inset=0.0):
    """The logo as a rounded tile on a transparent canvas."""
    body = int(size * (1 - 2 * inset))
    k = 4  # supersample the mask for smooth corners
    mask = Image.new("L", (body * k, body * k), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, body * k - 1, body * k - 1), radius=int(body * k * radius), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - body) // 2
    out.paste(square(body), (off, off), mask.resize((body, body), Image.LANCZOS))
    return out


def save(img, rel):
    path = ROOT / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path)
    print(rel, img.size, img.mode)


# iOS: full-bleed squares, no alpha.
ios = "ios/Runner/Assets.xcassets/AppIcon.appiconset"
for pt, scales in [(20, (1, 2, 3)), (29, (1, 2, 3)), (40, (1, 2, 3)),
                   (60, (2, 3)), (76, (1, 2)), (83.5, (2,)), (1024, (1,))]:
    for s in scales:
        name = f"{pt:g}x{pt:g}@{s}x"
        save(square(round(pt * s)), f"{ios}/Icon-App-{name}.png")

# Android: legacy rounded squares, plus an adaptive icon (Android 8+) whose
# foreground keeps the glyph inside the mask's safe zone over a matching
# background colour.
for dpi, scale in [("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2),
                   ("xxhdpi", 3), ("xxxhdpi", 4)]:
    res = f"android/app/src/main/res/mipmap-{dpi}"
    save(rounded(round(48 * scale), radius=0.2, inset=0.04), f"{res}/ic_launcher.png")
    canvas = round(108 * scale)
    fg = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    inner = round(70 * scale)
    fg.paste(square(inner), ((canvas - inner) // 2,) * 2)
    save(fg, f"{res}/ic_launcher_foreground.png")
(ROOT / "android/app/src/main/res/mipmap-anydpi-v26").mkdir(parents=True, exist_ok=True)
(ROOT / "android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml").write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '    <background android:drawable="@color/ic_launcher_background"/>\n'
    '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
    '</adaptive-icon>\n', encoding="utf-8")
(ROOT / "android/app/src/main/res/values/ic_launcher_background.xml").write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
    '    <color name="ic_launcher_background">#%02X%02X%02X</color>\n'
    '</resources>\n' % BG, encoding="utf-8")

# Android status-bar icon for reminders: Android draws it as a white
# silhouette, so cut the glyph (purple + gold, far brighter than the
# background) out as white-on-transparent, with the engraved tick as a hole.
value = MASTER.convert("HSV").split()[2]  # max(r, g, b) per pixel
glyph = value.point(lambda v: 255 if v > 120 else 0)
# Close the thin shadow creases between the blocks (the tick is wider).
glyph = glyph.filter(ImageFilter.MaxFilter(11)).filter(ImageFilter.MinFilter(11))
glyph = glyph.crop(glyph.getbbox())
side = round(max(glyph.size) * 1.12)
mask = Image.new("L", (side, side), 0)
mask.paste(glyph, ((side - glyph.width) // 2, (side - glyph.height) // 2))
for dpi, px in [("mdpi", 24), ("hdpi", 36), ("xhdpi", 48),
                ("xxhdpi", 72), ("xxxhdpi", 96)]:
    icon = Image.new("RGBA", (px, px), (255, 255, 255, 0))
    icon.putalpha(mask.resize((px, px), Image.LANCZOS))
    save(icon, f"android/app/src/main/res/drawable-{dpi}/ic_stat_habitrail.png")

# macOS: the Big Sur tile, an inset rounded square with a soft shadow.
mac = "macos/Runner/Assets.xcassets/AppIcon.appiconset"
for size in (16, 32, 64, 128, 256, 512, 1024):
    tile = rounded(size, radius=0.225, inset=100 / 1024)
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.putalpha(tile.getchannel("A").point(lambda a: a * 0.35))
    shadow = shadow.filter(ImageFilter.GaussianBlur(max(1, size / 80)))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(shadow, (0, max(1, round(size / 100))), shadow)
    out.alpha_composite(tile)
    save(out, f"{mac}/app_icon_{size}.png")

# Windows: one .ico with the sizes Explorer and the taskbar use.
ico = rounded(256, radius=0.2)
ico_path = ROOT / "windows/runner/resources/app_icon.ico"
ico.save(ico_path, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64),
                          (128, 128), (256, 256)])
print("windows/runner/resources/app_icon.ico", "7 sizes")

# In-app copy: the notification preview in Settings and the Windows toast icon.
save(rounded(128, radius=0.22), "assets/branding/app_icon.png")

# Web: favicon, home-screen icons, and maskable icons with the glyph inside
# the 80% safe circle.
save(rounded(32, radius=0.2), "web/favicon.png")
for size in (192, 512):
    save(square(size), f"web/icons/Icon-{size}.png")
    m = Image.new("RGB", (size, size), BG)
    inner = round(size * 0.84)
    m.paste(square(inner), ((size - inner) // 2,) * 2)
    save(m, f"web/icons/Icon-maskable-{size}.png")
