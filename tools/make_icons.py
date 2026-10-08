"""Draw the menu's sidebar icons (white glyphs on transparent 64x64 PNGs).

Drawn at 4x and downsampled for smooth edges. Output: LortModMenu/icons/<name>.png
"""
import math, os
from PIL import Image, ImageDraw

S = 256  # drawing size
OUT = os.path.join(os.path.dirname(__file__), "..", "LortModMenu", "icons")
W = (255, 255, 255, 255)


def canvas():
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)


def save(im, name):
    os.makedirs(OUT, exist_ok=True)
    im.resize((64, 64), Image.LANCZOS).save(os.path.join(OUT, name + ".png"))


def player():
    im, d = canvas()
    d.ellipse((88, 24, 168, 104), fill=W)
    d.pieslice((36, 120, 220, 304), 180, 360, fill=W)
    d.rectangle((36, 212, 220, 232), fill=W)
    return im


def combat():
    im, d = canvas()
    # sword blade diagonal from top-right to centre, guard, grip, pommel
    blade = [(222, 20), (236, 34), (110, 160), (96, 146)]
    d.polygon(blade, fill=W)
    d.polygon([(222, 20), (236, 34), (240, 16)], fill=W)
    d.line((62, 132, 124, 194), fill=W, width=22)          # guard
    d.line((92, 164, 44, 212), fill=W, width=20)           # grip
    d.ellipse((22, 210, 54, 242), fill=W)                  # pommel
    return im


def fun():
    im, d = canvas()
    cx, cy, ro, ri = 128, 134, 116, 48
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        r = ro if i % 2 == 0 else ri
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    d.polygon(pts, fill=W)
    return im


def actions():
    im, d = canvas()
    d.polygon([(150, 12), (52, 146), (118, 146), (96, 244), (204, 104), (138, 104), (170, 12)], fill=W)
    return im


def achievements():
    im, d = canvas()
    d.pieslice((60, -40, 196, 150), 0, 180, fill=W)        # cup bowl
    d.rectangle((60, 20, 196, 56), fill=W)
    d.arc((18, 30, 90, 110), 90, 270, fill=W, width=16)     # handles
    d.arc((166, 30, 238, 110), 270, 90, fill=W, width=16)
    d.rectangle((114, 140, 142, 190), fill=W)               # stem
    d.rounded_rectangle((70, 190, 186, 222), radius=8, fill=W)  # base
    return im


def settings():
    im, d = canvas()
    cx = cy = 128
    for i in range(8):
        a = i * math.pi / 4
        x, y = cx + 92 * math.cos(a), cy + 92 * math.sin(a)
        d.ellipse((x - 26, y - 26, x + 26, y + 26), fill=W)
    d.ellipse((cx - 82, cy - 82, cx + 82, cy + 82), fill=W)
    d.ellipse((cx - 34, cy - 34, cx + 34, cy + 34), fill=(0, 0, 0, 0))
    return im


def spawner():
    im, d = canvas()
    # treasure chest: domed lid, body, lock
    d.pieslice((28, 40, 228, 160), 180, 360, fill=W)
    d.rectangle((28, 100, 228, 112), fill=(0, 0, 0, 0))
    d.rectangle((28, 112, 228, 222), fill=W)
    d.rectangle((28, 136, 228, 146), fill=(0, 0, 0, 0))
    d.rounded_rectangle((108, 116, 148, 166), radius=8, fill=(0, 0, 0, 0))
    d.rounded_rectangle((116, 124, 140, 158), radius=6, fill=W)
    return im


def weapons():
    im, d = canvas()
    for flip in (False, True):
        layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        dd = ImageDraw.Draw(layer)
        dd.polygon([(222, 20), (236, 34), (110, 160), (96, 146)], fill=W)
        dd.line((62, 132, 124, 194), fill=W, width=20)
        dd.line((92, 164, 44, 212), fill=W, width=18)
        dd.ellipse((22, 210, 54, 242), fill=W)
        if flip:
            layer = layer.transpose(Image.FLIP_LEFT_RIGHT)
        im.alpha_composite(layer)
    return im


def monsters():
    im, d = canvas()
    d.ellipse((40, 24, 216, 190), fill=W)                       # skull dome
    d.rounded_rectangle((78, 160, 178, 230), radius=14, fill=W)  # jaw
    T = (0, 0, 0, 0)
    d.ellipse((74, 92, 118, 140), fill=T)                       # eyes
    d.ellipse((138, 92, 182, 140), fill=T)
    d.polygon([(128, 146), (116, 172), (140, 172)], fill=T)     # nose
    for x in (98, 120, 142):                                    # teeth gaps
        d.rectangle((x, 196, x + 6, 230), fill=T)
    return im


def run():
    im, d = canvas()
    d.rounded_rectangle((50, 20, 74, 240), radius=10, fill=W)             # pole
    d.polygon([(74, 28), (226, 60), (74, 132)], fill=W)                  # pennant
    return im


def model():
    im, d = canvas()
    # two figures: a small one behind, a big one in front (= swap body)
    d.ellipse((150, 30, 206, 86), fill=(255, 255, 255, 150))
    d.pieslice((120, 96, 236, 212), 180, 360, fill=(255, 255, 255, 150))
    d.ellipse((58, 60, 132, 134), fill=W)
    d.pieslice((20, 144, 170, 294), 180, 360, fill=W)
    d.rectangle((20, 218, 170, 236), fill=W)
    return im


if __name__ == "__main__":
    for name, fn in [("player", player), ("combat", combat), ("fun", fun), ("actions", actions),
                     ("achievements", achievements), ("settings", settings), ("spawner", spawner),
                     ("weapons", weapons), ("monsters", monsters), ("run", run), ("model", model)]:
        save(fn(), name)
    print("icons written to", os.path.abspath(OUT))
