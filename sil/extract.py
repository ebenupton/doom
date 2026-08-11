#!/usr/bin/env python3
"""Silhouette extractor: DOOM sprite alpha masks -> simplified closed outlines.

Pipeline (per the design brief):
  1. Read sprite lumps from the shareware IWAD (DOOM picture format).
  2. Build the binary alpha mask (posts present = opaque).
  3. Marching-squares walk of the mask's cell-edge grid -> exact closed
     boundary loops at pixel-corner coordinates (integer, u8-safe).
  4. Douglas-Peucker simplification, iterating epsilon (binary search) to
     land at or under a per-figure segment budget.
  5. Mirrored rotations (A2A8-style lumps) are produced by x-flipping.
  6. Minimal internal strokes where the outline alone loses identity
     (MEDI/STIM: 2-segment red cross derived from the red palette region).

Outputs:
  sil/silhouettes.py   generated data module
  sil/preview/*.png    contact sheets (mask + outline overlay / outline only)
  sil/report.txt       segment/byte table

Run:  python3 sil/extract.py [path-to-DOOM1.WAD]
"""
import os
import struct
import sys

from PIL import Image, ImageDraw

SIL_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_WAD = os.path.join(os.path.dirname(SIL_DIR), "DOOM1.WAD")

# ----------------------------------------------------------------------------
# WAD reading
# ----------------------------------------------------------------------------

def read_wad(path):
    with open(path, "rb") as f:
        data = f.read()
    ident, num, ofs = struct.unpack("<4sII", data[:12])
    assert ident in (b"IWAD", b"PWAD"), "not a WAD"
    lumps = []
    for i in range(num):
        o, sz, nm = struct.unpack("<II8s", data[ofs + 16 * i : ofs + 16 * i + 16])
        lumps.append((nm.rstrip(b"\0").decode("ascii"), o, sz))
    return data, lumps


def sprite_lump_index(lumps):
    """Map (sprite4, frame, rotation) -> (lump_name, mirrored)."""
    names = [l[0] for l in lumps]
    s0, s1 = names.index("S_START"), names.index("S_END")
    by_name = {l[0]: l for l in lumps}
    idx = {}
    for name, _, _ in lumps[s0 + 1 : s1]:
        if len(name) not in (6, 8):
            continue
        spr, f1, r1 = name[:4], name[4], int(name[5])
        idx[(spr, f1, r1)] = (name, False)
        if len(name) == 8:
            f2, r2 = name[6], int(name[7])
            idx[(spr, f2, r2)] = (name, True)
    return idx, by_name


def decode_picture(data, lump):
    """DOOM picture format -> (w, h, left, top, mask rows, palette-index rows).

    mask[y][x] is True where a post covers the pixel; pix[y][x] is the
    palette index (0 where transparent).
    """
    _, off, _ = lump
    w, h, left, top = struct.unpack("<HHhh", data[off : off + 8])
    colofs = struct.unpack("<%dI" % w, data[off + 8 : off + 8 + 4 * w])
    mask = [[False] * w for _ in range(h)]
    pix = [[0] * w for _ in range(h)]
    for x in range(w):
        p = off + colofs[x]
        while True:
            topdelta = data[p]
            if topdelta == 0xFF:
                break
            length = data[p + 1]
            for i in range(length):
                y = topdelta + i
                if 0 <= y < h:
                    mask[y][x] = True
                    pix[y][x] = data[p + 3 + i]
            p += 4 + length
    return w, h, left, top, mask, pix


# ----------------------------------------------------------------------------
# Marching squares: binary mask -> closed boundary loops (pixel corners)
# ----------------------------------------------------------------------------

def trace_loops(mask, w, h):
    """Every boundary edge between an opaque pixel and a transparent
    neighbour becomes a directed cell edge (opaque pixel on a fixed side);
    chaining them yields the marching-squares contour loops.  At a
    checkerboard corner the sharper (clockwise) turn is preferred so the
    two diagonal regions stay in separate loops."""
    out = {}  # start point -> list of end points

    def filled(x, y):
        return 0 <= x < w and 0 <= y < h and mask[y][x]

    for y in range(h):
        for x in range(w):
            if not mask[y][x]:
                continue
            if not filled(x, y - 1):
                out.setdefault((x, y), []).append((x + 1, y))
            if not filled(x + 1, y):
                out.setdefault((x + 1, y), []).append((x + 1, y + 1))
            if not filled(x, y + 1):
                out.setdefault((x + 1, y + 1), []).append((x, y + 1))
            if not filled(x - 1, y):
                out.setdefault((x, y + 1), []).append((x, y))

    loops = []
    while out:
        start = next(iter(out))
        ends = out[start]
        cur, nxt = start, ends.pop()
        if not ends:
            del out[start]
        loop = [start]
        while nxt != start:
            loop.append(nxt)
            d = (nxt[0] - cur[0], nxt[1] - cur[1])
            cands = out.get(nxt)
            if not cands:
                break  # should not happen on well-formed masks
            if len(cands) == 1:
                chosen = cands[0]
            else:
                # preference: clockwise turn, straight, counter-clockwise
                prefs = [(-d[1], d[0]), d, (d[1], -d[0])]
                chosen = None
                for pd in prefs:
                    want = (nxt[0] + pd[0], nxt[1] + pd[1])
                    if want in cands:
                        chosen = want
                        break
                if chosen is None:
                    chosen = cands[0]
            cands.remove(chosen)
            if not cands:
                del out[nxt]
            cur, nxt = nxt, chosen
        loops.append(loop)
    return loops


def collapse_collinear(loop):
    """Merge runs of same-direction unit edges (closed loop)."""
    n = len(loop)
    keep = []
    for i in range(n):
        p0, p1, p2 = loop[i - 1], loop[i], loop[(i + 1) % n]
        d0 = (p1[0] - p0[0], p1[1] - p0[1])
        d1 = (p2[0] - p1[0], p2[1] - p1[1])
        if d0[0] * d1[1] - d0[1] * d1[0] != 0 or (d0[0] * d1[0] + d0[1] * d1[1]) < 0:
            keep.append(p1)
    return keep


def loop_area(loop):
    a = 0
    n = len(loop)
    for i in range(n):
        x0, y0 = loop[i]
        x1, y1 = loop[(i + 1) % n]
        a += x0 * y1 - x1 * y0
    return a / 2.0


# ----------------------------------------------------------------------------
# Douglas-Peucker with segment budget
# ----------------------------------------------------------------------------

def _dp_chain(pts, eps):
    """Douglas-Peucker on an open chain; returns kept points incl. ends."""
    if len(pts) <= 2:
        return list(pts)
    (x0, y0), (x1, y1) = pts[0], pts[-1]
    dx, dy = x1 - x0, y1 - y0
    L2 = dx * dx + dy * dy
    imax, dmax = 0, -1.0
    for i in range(1, len(pts) - 1):
        px, py = pts[i]
        if L2 == 0:
            d2 = (px - x0) ** 2 + (py - y0) ** 2
        else:
            d2 = (dx * (py - y0) - dy * (px - x0)) ** 2 / L2
        if d2 > dmax:
            imax, dmax = i, d2
    if dmax <= eps * eps:
        return [pts[0], pts[-1]]
    a = _dp_chain(pts[: imax + 1], eps)
    b = _dp_chain(pts[imax:], eps)
    return a[:-1] + b


def dp_closed(loop, eps):
    """DP on a closed loop: anchor at the two mutually farthest-ish points
    (point 0 and the point farthest from it), simplify both halves."""
    if len(loop) <= 3:
        return list(loop)
    x0, y0 = loop[0]
    k = max(range(len(loop)), key=lambda i: (loop[i][0] - x0) ** 2 + (loop[i][1] - y0) ** 2)
    a = _dp_chain(loop[: k + 1], eps)
    b = _dp_chain(loop[k:] + [loop[0]], eps)
    return a[:-1] + b[:-1]


def simplify_budget(loops, budget, min_area=4.0):
    """Single epsilon shared by all loops, binary-searched so the total
    closed-loop segment count lands at or under `budget`."""
    loops = [lp for lp in loops if abs(loop_area(lp)) >= min_area]
    loops.sort(key=lambda lp: -abs(loop_area(lp)))
    if not loops:
        return [], 0.0

    def run(eps):
        out = []
        for lp in loops:
            s = dp_closed(lp, eps)
            if len(s) >= 3:
                out.append(s)
        return out

    lo, hi = 0.0, 256.0
    best = None
    for _ in range(48):
        mid = (lo + hi) / 2.0
        s = run(mid)
        if sum(len(x) for x in s) <= budget:
            best, hi = (s, mid), mid
        else:
            lo = mid
    if best is None:
        best = (run(hi), hi)
    return best


# ----------------------------------------------------------------------------
# Internal strokes
# ----------------------------------------------------------------------------

def load_palette(data, by_name):
    _, off, _ = by_name["PLAYPAL"]
    return [tuple(data[off + 3 * i : off + 3 * i + 3]) for i in range(256)]


def red_cross_strokes(mask, pix, pal, w, h):
    """MEDI/STIM identity: the red cross.  Emit it as two straight open
    strokes (vertical + horizontal bar through the red region's bbox) --
    2 segments instead of a 12-segment plus-sign polygon."""
    xs, ys = [], []
    for y in range(h):
        for x in range(w):
            if mask[y][x]:
                r, g, b = pal[pix[y][x]]
                if r > 110 and r > 1.7 * g and r > 1.7 * b:
                    xs.append(x)
                    ys.append(y)
    if len(xs) < 8:
        return []
    x0, x1 = min(xs), max(xs) + 1
    y0, y1 = min(ys), max(ys) + 1
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    return [[(cx, y0), (cx, y1)], [(x0, cy), (x1, cy)]]


def green_rim_stroke(mask, pix, pal, w, h):
    """BAR1 identity: a plain rounded box needs the sludge-rim line to read
    as a barrel.  One horizontal stroke across the barrel at the bottom of
    the green (nukage) region."""
    ys = [y for y in range(h // 2) for x in range(w)
          if mask[y][x] and pal[pix[y][x]][1] > 90
          and pal[pix[y][x]][1] > 1.4 * pal[pix[y][x]][0]
          and pal[pix[y][x]][1] > 1.4 * pal[pix[y][x]][2]]
    if len(ys) < 8:
        return []
    yr = max(ys) + 1
    row = [x for x in range(w) if mask[min(yr, h - 1)][x]]
    return [[(min(row), yr), (max(row) + 1, yr)]] if row else []


# ----------------------------------------------------------------------------
# Roster
# ----------------------------------------------------------------------------

# (sprite, frame, rotations, outline budget, stroke fn, label)
ENEMIES = [
    ("POSS", "A", 30, "Zombieman"),
    ("SPOS", "A", 30, "Shotgun sergeant"),
    ("TROO", "A", 30, "Imp"),
]
OBJECTS = [
    ("BAR1", "A", 10, green_rim_stroke, "Exploding barrel"),
    ("STIM", "A", 8, red_cross_strokes, "Stimpack"),
    ("MEDI", "A", 8, red_cross_strokes, "Medikit"),
    ("BON1", "A", 6, None, "Health potion"),
    ("BON2", "A", 6, None, "Armor bonus"),
    ("ARM1", "A", 10, None, "Green armor"),
    ("CLIP", "A", 6, None, "Ammo clip"),
    ("SBOX", "A", 8, None, "Shell box"),
    ("PLAY", "N", 12, None, "Dead marine"),
    ("PLAY", "W", 10, None, "Bloody mess"),
]


def mirror_entry(w, loops, strokes):
    ml = [[(w - x, y) for (x, y) in reversed(lp)] for lp in loops]
    ms = [[(w - x, y) for (x, y) in st] for st in strokes]
    return ml, ms


def seg_count(loops, strokes):
    return sum(len(lp) for lp in loops) + sum(len(st) - 1 for st in strokes)


def pt_count(loops, strokes):
    return sum(len(lp) for lp in loops) + sum(len(st) for st in strokes)


# ----------------------------------------------------------------------------
# Previews
# ----------------------------------------------------------------------------

SCALE = 5
PAD = 8


def render_cell(w, h, mask, loops, strokes, mode):
    img = Image.new("RGB", (w * SCALE + 2, h * SCALE + 2), (255, 255, 255))
    dr = ImageDraw.Draw(img)
    if mode == "overlay":
        for y in range(h):
            for x in range(w):
                if mask[y][x]:
                    dr.rectangle(
                        [x * SCALE + 1, y * SCALE + 1, (x + 1) * SCALE, (y + 1) * SCALE],
                        fill=(190, 190, 190),
                    )
    for lp in loops:
        pts = [(x * SCALE + 1, y * SCALE + 1) for (x, y) in lp]
        dr.line(pts + [pts[0]], fill=(200, 0, 0) if mode == "overlay" else (0, 0, 0), width=2)
    for st in strokes:
        pts = [(x * SCALE + 1, y * SCALE + 1) for (x, y) in st]
        dr.line(pts, fill=(0, 0, 200) if mode == "overlay" else (0, 0, 0), width=2)
    return img


def contact_sheet(path, cells, labels):
    """cells: list of (overlay_img, outline_img); two rows."""
    cw = max(c[0].width for c in cells)
    ch0 = max(c[0].height for c in cells)
    ch1 = max(c[1].height for c in cells)
    W = PAD + sum(c[0].width + PAD for c in cells)
    H = PAD + 14 + ch0 + PAD + ch1 + PAD
    sheet = Image.new("RGB", (W, H), (255, 255, 255))
    dr = ImageDraw.Draw(sheet)
    x = PAD
    for (ov, ol), lab in zip(cells, labels):
        dr.text((x, PAD), lab, fill=(0, 0, 0))
        sheet.paste(ov, (x, PAD + 14 + (ch0 - ov.height)))
        sheet.paste(ol, (x, PAD + 14 + ch0 + PAD + (ch1 - ol.height)))
        x += ov.width + PAD
    sheet.save(path)


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

def extract_one(data, lump, budget, stroke_fn, pal):
    w, h, left, top, mask, pix = decode_picture(data, lump)
    raw = [collapse_collinear(lp) for lp in trace_loops(mask, w, h)]
    strokes = stroke_fn(mask, pix, pal, w, h) if stroke_fn else []
    ob = budget - sum(len(st) - 1 for st in strokes)
    loops, eps = simplify_budget(raw, ob)
    assert w <= 255 and h <= 255
    return dict(w=w, h=h, left=left, top=top, mask=mask, loops=loops, strokes=strokes, eps=eps)


def main():
    wad_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_WAD
    data, lumps = read_wad(wad_path)
    idx, by_name = sprite_lump_index(lumps)
    pal = load_palette(data, by_name)

    entries = {}   # (sprite, frame, rot) -> dict
    order = []
    report = []

    def add(spr, frame, rot, e, mirrored_from=None):
        key = (spr, frame, rot)
        entries[key] = e
        order.append(key)

    # enemies: frame A, rotations 1..8 (mirrors generated by x-flip)
    for spr, frame, budget, label in ENEMIES:
        for rot in range(1, 9):
            name, mirrored = idx[(spr, frame, rot)]
            e = extract_one(data, by_name[name], budget, None, pal)
            if mirrored:
                e = dict(e)
                e["loops"], e["strokes"] = mirror_entry(e["w"], e["loops"], e["strokes"])
                e["left"] = e["w"] - e["left"]
                e["mask"] = [list(reversed(row)) for row in e["mask"]]
            add(spr, frame, rot, e)

    # objects: single rotation 0
    for spr, frame, budget, stroke_fn, label in OBJECTS:
        name, mirrored = idx[(spr, frame, 0)]
        e = extract_one(data, by_name[name], budget, stroke_fn, pal)
        add(spr, frame, 0, e)

    # ---- emit silhouettes.py -------------------------------------------
    labels = {(s, f): lab for s, f, _, lab in ENEMIES}
    labels.update({(s, f): lab for s, f, _, _, lab in OBJECTS})
    out = os.path.join(SIL_DIR, "silhouettes.py")
    with open(out, "w") as f:
        f.write('"""Generated by sil/extract.py -- do not hand-edit.\n\n')
        f.write("SILHOUETTES[(sprite, frame, rotation)] = {\n")
        f.write("  'size': (w, h),            # sprite pixel size; coords are pixel corners 0..w/0..h (u8)\n")
        f.write("  'offset': (left, top),     # DOOM sprite offsets (mirror-adjusted)\n")
        f.write("  'outline': [loop, ...],    # closed contours, each a list of (x, y)\n")
        f.write("  'strokes': [line, ...],    # open internal polylines\n")
        f.write("  'segments': n,             # closed: len(loop); open: len(line)-1\n")
        f.write("}\nRotation 0 = single-view object.  Mirrored rotations are baked (x already flipped).\n\"\"\"\n\n")
        f.write("SILHOUETTES = {\n")
        for key in order:
            e = entries[key]
            f.write("  %r: {\n" % (key,))
            f.write("    'size': (%d, %d), 'offset': (%d, %d),\n" % (e["w"], e["h"], e["left"], e["top"]))
            f.write("    'outline': [\n")
            for lp in e["loops"]:
                f.write("      %r,\n" % (lp,))
            f.write("    ],\n")
            f.write("    'strokes': [\n")
            for st in e["strokes"]:
                f.write("      %r,\n" % (st,))
            f.write("    ],\n")
            f.write("    'segments': %d,\n" % seg_count(e["loops"], e["strokes"]))
            f.write("  },\n")
        f.write("}\n")

    # ---- previews -------------------------------------------------------
    prev = os.path.join(SIL_DIR, "preview")
    os.makedirs(prev, exist_ok=True)
    for spr, frame, budget, label in ENEMIES:
        cells, labs = [], []
        for rot in range(1, 9):
            e = entries[(spr, frame, rot)]
            cells.append((
                render_cell(e["w"], e["h"], e["mask"], e["loops"], e["strokes"], "overlay"),
                render_cell(e["w"], e["h"], e["mask"], e["loops"], e["strokes"], "outline"),
            ))
            labs.append("%s%s%d  %dseg" % (spr, frame, rot, seg_count(e["loops"], e["strokes"])))
        contact_sheet(os.path.join(prev, "%s_%s.png" % (spr, frame)), cells, labs)
    cells, labs = [], []
    for spr, frame, budget, stroke_fn, label in OBJECTS:
        e = entries[(spr, frame, 0)]
        cells.append((
            render_cell(e["w"], e["h"], e["mask"], e["loops"], e["strokes"], "overlay"),
            render_cell(e["w"], e["h"], e["mask"], e["loops"], e["strokes"], "outline"),
        ))
        labs.append("%s%s0 %dseg" % (spr, frame, seg_count(e["loops"], e["strokes"])))
    contact_sheet(os.path.join(prev, "objects.png"), cells, labs)

    # ---- report ---------------------------------------------------------
    lines = []
    lines.append("%-20s %-10s %4s %4s %5s  %s" % ("figure", "entry", "segs", "pts", "bytes", "eps"))
    total_bytes = 0
    total_segs = 0
    for key in order:
        spr, frame, rot = key
        e = entries[key]
        segs = seg_count(e["loops"], e["strokes"])
        pts = pt_count(e["loops"], e["strokes"])
        by = 2 * pts
        total_bytes += by
        total_segs += segs
        lines.append("%-20s %-10s %4d %4d %5d  %.2f" % (
            labels[(spr, frame)], "%s%s%s" % (spr, frame, rot if rot else "0"), segs, pts, by, e["eps"]))
    lines.append("")
    lines.append("entries: %d   total segments: %d   total bytes (2/pt): %d" % (len(order), total_segs, total_bytes))
    rpt = "\n".join(lines)
    with open(os.path.join(SIL_DIR, "report.txt"), "w") as f:
        f.write(rpt + "\n")
    print(rpt)


if __name__ == "__main__":
    main()
