#!/usr/bin/env python3
"""DOOM E1M1 wireframe renderer — BSP front-to-back with 2D trapezoid clip spans."""

import struct, math, sys, pygame
import fp as fp_module
from fp import (fp_mul8, fp_mul7, fp_div8, s8,
                fp_sin, fp_cos, fp_sincos,
                fp_recip_x, fp_recip_y, fp_project_x, fp_project_x_subpx, fp_project_y,
                fp_linfn, fp_eval, fp_view_context, fp_to_view, fp_near_clip, fp_clip_to_trap,
                FP7, FP8, HALF_W, HALF_H, NEAR_FP, RECIP_FRAC_BITS,
                FP_RENDER_W, FP_RENDER_H, FP_FOCAL_X,
                MAP_CENTER_X, MAP_CENTER_Y, PRESCALE)

# ── WAD parsing ──────────────────────────────────────────────────────────────

def load_wad(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, numlumps, dirofs = struct.unpack_from("<4sII", data, 0)
    directory = []
    for i in range(numlumps):
        off = dirofs + i * 16
        fpos, size = struct.unpack_from("<II", data, off)
        name = data[off+8:off+16].split(b"\x00")[0].decode("ascii", "replace")
        directory.append((name, fpos, size))
    return data, directory

def find_map_lumps(directory, mapname):
    for i, (name, _, _) in enumerate(directory):
        if name == mapname:
            return {directory[i+j][0]: (directory[i+j][1], directory[i+j][2])
                    for j in range(1, 11)}
    sys.exit(f"Map {mapname} not found")

def parse_lump(data, lumps, name, fmt):
    pos, size = lumps[name]
    sz = struct.calcsize(fmt)
    return [struct.unpack_from(fmt, data, pos + i * sz) for i in range(size // sz)]

# ── Load E1M1 ────────────────────────────────────────────────────────────────

data, directory = load_wad("DOOM1.WAD")
lumps = find_map_lumps(directory, "E1M1")

vertexes  = parse_lump(data, lumps, "VERTEXES",  "<hh")
linedefs  = parse_lump(data, lumps, "LINEDEFS",  "<HHHHHHH")
sidedefs  = parse_lump(data, lumps, "SIDEDEFS",  "<hh8s8s8sH")
sectors   = parse_lump(data, lumps, "SECTORS",   "<hh8s8sHHH")
segs      = parse_lump(data, lumps, "SEGS",      "<HHhHHH")
ssectors  = parse_lump(data, lumps, "SSECTORS",  "<HH")
nodes     = parse_lump(data, lumps, "NODES",     "<hhhhhhhhhhhhHH")
things    = parse_lump(data, lumps, "THINGS",    "<hhHHH")

for t in things:
    if t[3] == 1:
        player_x, player_y, pangle = float(t[0]), float(t[1]), t[2]
        break

# ── Prescaled data for 8-bit fixed-point path ───────────────────────────
#
# Center on map and divide by 8 so all vertex/height values fit in 8 bits.
# Heights are also divided by 8 (same as XY) so projection is scale-invariant.

fp_vertexes = [
    ((v[0] - MAP_CENTER_X) // PRESCALE,
     (v[1] - MAP_CENTER_Y) // PRESCALE)
    for v in vertexes
]

fp_sectors = [
    (s[0] // PRESCALE, s[1] // PRESCALE, *s[2:])
    for s in sectors
]

# ── Helpers ──────────────────────────────────────────────────────────────────

def seg_sectors(seg):
    ld = linedefs[seg[3]]
    right_side, left_side = ld[5], ld[6]
    if seg[4] == 0:
        front = sidedefs[right_side][5]
        back  = sidedefs[left_side][5] if left_side != 0xFFFF else None
    else:
        front = sidedefs[left_side][5] if left_side != 0xFFFF else sidedefs[right_side][5]
        back  = sidedefs[right_side][5] if left_side != 0xFFFF else None
    return front, back

NF_SUBSECTOR = 0x8000

def point_on_side(x, y, node):
    dx, dy = x - node[0], y - node[1]
    return 0 if (node[3] * dx - node[2] * dy) > 0 else 1

def find_subsector(x, y):
    nid = len(nodes) - 1
    while not (nid & NF_SUBSECTOR):
        node = nodes[nid]
        nid = node[12] if point_on_side(x, y, node) == 0 else node[13]
    return nid & 0x7FFF

def player_floor(x, y):
    ss = ssectors[find_subsector(x, y)]
    s = segs[ss[1]]
    ld = linedefs[s[3]]
    sd_idx = ld[5] if s[4] == 0 else ld[6]
    if sd_idx == 0xFFFF: sd_idx = ld[5]
    return sectors[sidedefs[sd_idx][5]][0]

# ── Strip invisible segs for fixed-point path ────────────────────────────
#
# Two-sided segs with identical floor AND ceiling on both sides are pure
# lighting/trigger boundaries.  They produce no draws and their tighten is
# a no-op.  Strip them and rebuild the subsector seg table.

def _is_renderable(s):
    fi, bi = seg_sectors(s)
    if bi is None: return True
    return sectors[fi][0] != sectors[bi][0] or sectors[fi][1] != sectors[bi][1]

_stripped_segs = []
_stripped_ssectors = []
_strip_count = 0
for _ssi, _ss in enumerate(ssectors):
    _first = len(_stripped_segs)
    for _si in range(_ss[1], _ss[1] + _ss[0]):
        if _is_renderable(segs[_si]):
            _stripped_segs.append(segs[_si])
        else:
            _strip_count += 1
    _stripped_ssectors.append((len(_stripped_segs) - _first, _first))

fp_segs = _stripped_segs
fp_ssectors = _stripped_ssectors

# ── Analytical 2D trapezoid clip spans ───────────────────────────────────────
#
# The visible region is a list of non-overlapping half-open spans [xlo, xhi).
# Each span's top and bottom boundaries are linear functions stored as
# (slope, intercept): y = a*x + b.  This avoids accumulated interpolation
# error — every evaluation uses the original tighten parameters.
#
# Lines are clipped analytically against each span's trapezoid using
# Cyrus-Beck (4 half-planes).  No per-column iteration.

SCREEN_W, SCREEN_H = 1024, 640     # display window size
WIDTH, HEIGHT = SCREEN_W, SCREEN_H  # rendering resolution (float mode)
FP_WIDTH, FP_HEIGHT = 256, 160      # rendering resolution (fixed-point mode)
FP_SCALE = SCREEN_W // FP_WIDTH     # = 4, nearest-neighbour upscale factor
HFOV = math.pi / 2
FOCAL_X = (WIDTH / 2) / math.tan(HFOV / 2)   # 512
FOCAL_Y = FOCAL_X * 1.2                        # 614.4
NEAR = 1.0

ZERO_FN = (0.0, 0.0)                   # y = 0 everywhere
BOT_FN  = (0.0, float(HEIGHT - 1))     # y = 599 everywhere


def _linfn(y1, y2, sx1, sx2):
    """Convert two-point form to (slope, intercept) where y = slope*x + intercept."""
    if abs(sx2 - sx1) < 0.5:
        return (0.0, (y1 + y2) * 0.5)
    a = (y2 - y1) / (sx2 - sx1)
    return (a, y1 - a * sx1)


def _eval(fn, x):
    """Evaluate y = a*x + b."""
    return fn[0] * x + fn[1]


def _clip_to_trap(x1, y1, x2, y2, xlo, xhi, tfn, bfn):
    """Clip line to trapezoid [xlo,xhi) with linear top/bot (slope,intercept).

    Cyrus-Beck: 4 half-planes — left, right, top, bottom.
    """
    dxs = xhi - xlo
    if dxs < 1:
        return None
    dx, dy = x2 - x1, y2 - y1
    ta, tb = tfn     # top: y >= ta*x + tb
    ba, bb = bfn     # bot: y <= ba*x + bb
    t0, t1 = 0.0, 1.0
    for p, q in (
        (-dx, x1 - xlo),                     # x >= xlo
        ( dx, xhi - x1),                      # x < xhi
        (ta * dx - dy, y1 - ta * x1 - tb),   # y >= top(x)
        (dy - ba * dx, ba * x1 + bb - y1),   # y <= bot(x)
    ):
        if abs(p) < 1e-10:
            if q < -1e-10:
                return None
        else:
            t = q / p
            if p < 0:
                if t > t1: return None
                t0 = max(t0, t)
            else:
                if t < t0: return None
                t1 = min(t1, t)
    if t0 > t1:
        return None
    return (x1 + t0 * dx, y1 + t0 * dy, x1 + t1 * dx, y1 + t1 * dy)


class ClipSpans:
    """Visible region as sorted half-open trapezoid spans [xlo, xhi).

    Each span is (xlo, xhi, top_fn, bot_fn) where top_fn/bot_fn are
    (slope, intercept) pairs.  Splitting a span just changes the x
    boundaries — the same linear function applies throughout.
    """
    __slots__ = ("spans",)

    def __init__(self):
        self.spans = [(0, WIDTH, ZERO_FN, BOT_FN)]

    def is_full(self):
        return not self.spans

    def has_gap(self, lo, hi):
        ilo, ihi = max(0, int(lo)), min(WIDTH - 1, int(hi))
        for xlo, xhi, tfn, bfn in self.spans:
            if xlo > ihi: break
            if xhi <= ilo: continue
            # Check if any column in overlap is alive
            clo, chi = max(xlo, ilo), min(xhi - 1, ihi)
            for x in range(clo, chi + 1):
                if _eval(tfn, x) < _eval(bfn, x):
                    return True
        return False

    def draw_clipped(self, lines, color, surface, stats=None):
        """Clip each line analytically to each overlapping span.

        stats = [total, unclipped, clipped, trivial_reject, clip_reject]
        """
        for lx1, ly1, lx2, ly2 in lines:
            if stats is not None: stats[0] += 1
            drawn = False
            was_clipped = False
            if abs(lx1 - lx2) < 0.5:
                ix = int(lx1)
                if ix < 0 or ix >= WIDTH:
                    if stats is not None: stats[3] += 1
                    continue
                found_span = False
                for xlo, xhi, tfn, bfn in self.spans:
                    if xlo <= ix < xhi:
                        found_span = True
                        yt, yb = _eval(tfn, ix), _eval(bfn, ix)
                        if yt >= yb: break
                        ya_orig, yb_orig = min(ly1, ly2), max(ly1, ly2)
                        ya = max(ya_orig, yt)
                        ybb = min(yb_orig, yb)
                        if ya < ybb:
                            pygame.draw.line(surface, color,
                                             (ix, int(ya)), (ix, int(ybb)), 1)
                            drawn = True
                            if ya > ya_orig + 0.5 or ybb < yb_orig - 0.5:
                                was_clipped = True
                        break
                if not drawn and stats is not None:
                    stats[3 if not found_span else 4] += 1
            else:
                x_min, x_max = min(lx1, lx2), max(lx1, lx2)
                overlaps_any = False
                for xlo, xhi, tfn, bfn in self.spans:
                    if xhi <= x_min or xlo >= x_max:
                        continue
                    overlaps_any = True
                    c = _clip_to_trap(lx1, ly1, lx2, ly2,
                                      xlo, xhi, tfn, bfn)
                    if c:
                        pygame.draw.line(surface, color,
                                         (int(c[0]), int(c[1])),
                                         (int(c[2]), int(c[3])), 1)
                        drawn = True
                        if (abs(c[0] - lx1) > 0.5 or abs(c[1] - ly1) > 0.5 or
                            abs(c[2] - lx2) > 0.5 or abs(c[3] - ly2) > 0.5):
                            was_clipped = True
                if not drawn and stats is not None:
                    stats[3 if not overlaps_any else 4] += 1
            if drawn and stats is not None:
                stats[2 if was_clipped else 1] += 1

    def mark_solid(self, lo, hi):
        """Remove [ilo, ihi) from spans."""
        ilo = max(0, int(lo))
        ihi = min(WIDTH, int(hi) + 1)
        if ilo >= ihi: return
        new = []
        for xlo, xhi, tfn, bfn in self.spans:
            if xhi <= ilo or xlo >= ihi:
                new.append((xlo, xhi, tfn, bfn))
                continue
            if xlo < ilo:
                new.append((xlo, ilo, tfn, bfn))
            if ihi < xhi:
                new.append((ihi, xhi, tfn, bfn))
        self.spans = new

    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2):
        """Tighten top/bottom over [ilo, ihi).

        New bounds are linear: yt1..yt2 along sx1..sx2, yb1..yb2 along sx1..sx2.
        Top = pointwise max(old, new).  Bottom = pointwise min(old, new).
        Spans split at crossover points for exact piecewise-linear result.
        """
        ilo = max(0, int(lo))
        ihi = min(WIDTH, int(hi) + 1)
        if ilo >= ihi: return
        new_tfn = _linfn(yt1, yt2, sx1, sx2)
        new_bfn = _linfn(yb1, yb2, sx1, sx2)
        new = []
        for xlo, xhi, tfn, bfn in self.spans:
            if xhi <= ilo or xlo >= ihi:
                new.append((xlo, xhi, tfn, bfn))
                continue
            # Left unchanged [xlo, ilo)
            if xlo < ilo:
                new.append((xlo, ilo, tfn, bfn))
            # Right unchanged [ihi, xhi)
            right = (ihi, xhi, tfn, bfn) if ihi < xhi else None
            # Overlap [ox0, ox1)
            ox0, ox1 = max(xlo, ilo), min(xhi, ihi)
            # Piecewise max for top × piecewise min for bottom
            for tx0, tx1, t_fn in _pw_max(tfn, new_tfn, ox0, ox1):
                for bx0, bx1, b_fn in _pw_min(bfn, new_bfn, tx0, tx1):
                    if bx1 > bx0:
                        # Check if any column is alive in this piece
                        if (_eval(t_fn, bx0) < _eval(b_fn, bx0) or
                            _eval(t_fn, bx1 - 1) < _eval(b_fn, bx1 - 1)):
                            new.append((bx0, bx1, t_fn, b_fn))
            if right:
                new.append(right)
        self.spans = new


def _pw_max(f, g, x0, x1):
    """Piecewise max of two linear functions over [x0, x1).

    Returns list of (x0, x1, winning_fn).  Crossover rounded to integer,
    then verified: the crossover column is assigned to whichever function
    is actually larger there.
    """
    fv0, gv0 = _eval(f, x0), _eval(g, x0)
    fv1, gv1 = _eval(f, x1 - 1), _eval(g, x1 - 1)
    d0, d1 = fv0 - gv0, fv1 - gv1
    if d0 >= 0 and d1 >= 0: return [(x0, x1, f)]
    if d0 <= 0 and d1 <= 0: return [(x0, x1, g)]
    fvx1, gvx1 = _eval(f, x1), _eval(g, x1)
    dx0 = fv0 - gv0
    dx1 = fvx1 - gvx1
    if abs(dx0 - dx1) < 1e-10:
        return [(x0, x1, f if d0 >= 0 else g)]
    t = dx0 / (dx0 - dx1)
    cx = int(x0 + t * (x1 - x0) + 0.5)
    cx = max(x0 + 1, min(x1 - 1, cx))
    # Verify: which function wins at cx?
    if _eval(f, cx) >= _eval(g, cx):
        # f wins at cx — cx belongs to the f-dominant piece
        cx += 1
        if cx >= x1: return [(x0, x1, f)]
    else:
        if cx <= x0: return [(x0, x1, g)]
    if d0 > 0: return [(x0, cx, f), (cx, x1, g)]
    return [(x0, cx, g), (cx, x1, f)]


def _pw_min(f, g, x0, x1):
    """Piecewise min of two linear functions over [x0, x1)."""
    fv0, gv0 = _eval(f, x0), _eval(g, x0)
    fv1, gv1 = _eval(f, x1 - 1), _eval(g, x1 - 1)
    d0, d1 = fv0 - gv0, fv1 - gv1
    if d0 <= 0 and d1 <= 0: return [(x0, x1, f)]
    if d0 >= 0 and d1 >= 0: return [(x0, x1, g)]
    fvx1, gvx1 = _eval(f, x1), _eval(g, x1)
    dx0 = fv0 - gv0
    dx1 = fvx1 - gvx1
    if abs(dx0 - dx1) < 1e-10:
        return [(x0, x1, f if d0 <= 0 else g)]
    t = dx0 / (dx0 - dx1)
    cx = int(x0 + t * (x1 - x0) + 0.5)
    cx = max(x0 + 1, min(x1 - 1, cx))
    # Verify: which function wins at cx?
    if _eval(f, cx) <= _eval(g, cx):
        cx += 1
        if cx >= x1: return [(x0, x1, f)]
    else:
        if cx <= x0: return [(x0, x1, g)]
    if d0 < 0: return [(x0, cx, f), (cx, x1, g)]
    return [(x0, cx, g), (cx, x1, f)]


# ── View-space transform ────────────────────────────────────────────────────

def to_view(wx, wy, vx, vy, cos_a, sin_a):
    dx, dy = wx - vx, wy - vy
    return dx * sin_a - dy * cos_a, dx * cos_a + dy * sin_a

def near_clip(vx1, vy1, vx2, vy2):
    if vy1 < NEAR and vy2 < NEAR: return None
    if vy1 >= NEAR and vy2 >= NEAR: return vx1, vy1, vx2, vy2
    t = (NEAR - vy1) / (vy2 - vy1)
    cx = vx1 + t * (vx2 - vx1)
    if vy1 < NEAR: return cx, NEAR, vx2, vy2
    return vx1, vy1, cx, NEAR

def bbox_visible(node, far_side, cos_a, sin_a, vx, vy):
    base = 4 + far_side * 4
    top, bot, left, right = node[base], node[base+1], node[base+2], node[base+3]
    if left <= vx <= right and bot <= vy <= top:
        return 0, WIDTH - 1
    pts = [to_view(wx, wy, vx, vy, cos_a, sin_a)
           for wx, wy in ((left, top), (right, top), (right, bot), (left, bot))]
    if all(p[1] < NEAR for p in pts): return None
    if any(p[1] < NEAR for p in pts): return 0, WIDTH - 1
    sxs = [WIDTH * 0.5 + p[0] * FOCAL_X / p[1] for p in pts]
    return int(min(sxs)), int(max(sxs))

def fp_bbox_visible(node, far_side, cos_a, sin_a, vx, vy):
    """Bbox visibility for fixed-point mode (256-wide render target).

    Uses float arithmetic on un-prescaled node data.
    Returns screen X range in 8.0 pixels, or None.
    """
    base = 4 + far_side * 4
    top, bot, left, right = node[base], node[base+1], node[base+2], node[base+3]
    if left <= vx <= right and bot <= vy <= top:
        return 0, FP_RENDER_W - 1
    pts = [to_view(wx, wy, vx, vy, cos_a, sin_a)
           for wx, wy in ((left, top), (right, top), (right, bot), (left, bot))]
    if all(p[1] < NEAR for p in pts): return None
    if any(p[1] < NEAR for p in pts): return 0, FP_RENDER_W - 1
    sxs = [FP_RENDER_W * 0.5 + p[0] * FP_FOCAL_X / p[1] for p in pts]
    return int(min(sxs)), int(max(sxs))

# ── BSP rendering ────────────────────────────────────────────────────────────

GREEN = (0, 200, 0)

def render_bsp(nid, clips, cos_a, sin_a, vx, vy, vz, surface):
    if clips.is_full(): return
    if nid & NF_SUBSECTOR:
        render_subsector(0 if nid == 0xFFFF else nid & 0x7FFF,
                         clips, cos_a, sin_a, vx, vy, vz, surface)
        return
    node = nodes[nid]
    side = point_on_side(vx, vy, node)
    ch = (node[12], node[13])
    render_bsp(ch[side], clips, cos_a, sin_a, vx, vy, vz, surface)
    if clips.is_full(): return
    far = side ^ 1
    br = bbox_visible(node, far, cos_a, sin_a, vx, vy)
    if br is not None and clips.has_gap(br[0], br[1]):
        render_bsp(ch[far], clips, cos_a, sin_a, vx, vy, vz, surface)

def render_subsector(idx, clips, cos_a, sin_a, vx, vy, vz, surface):
    ssec = ssectors[idx]
    for si in range(ssec[1], ssec[1] + ssec[0]):
        render_seg(si, clips, cos_a, sin_a, vx, vy, vz, surface)
        if clips.is_full(): return

def render_seg(si, clips, cos_a, sin_a, vx, vy, vz, surface):
    s = segs[si]
    v1, v2 = vertexes[s[0]], vertexes[s[1]]
    # Back-face test
    ld = linedefs[s[3]]
    lv1, lv2 = vertexes[ld[0]], vertexes[ld[1]]
    ldx, ldy = lv2[0] - lv1[0], lv2[1] - lv1[1]
    dot = ldy * (vx - lv1[0]) - ldx * (vy - lv1[1])
    if s[4] == 1: dot = -dot
    front_facing = dot > 0

    if not front_facing: return

    front_idx, back_idx = seg_sectors(s)

    nc = near_clip(*to_view(v1[0], v1[1], vx, vy, cos_a, sin_a),
                   *to_view(v2[0], v2[1], vx, vy, cos_a, sin_a))
    if nc is None: return
    ex1, ey1, ex2, ey2 = nc

    half_w, half_h = WIDTH * 0.5, HEIGHT * 0.5
    fx1, fx2 = FOCAL_X / ey1, FOCAL_X / ey2
    fy1, fy2 = FOCAL_Y / ey1, FOCAL_Y / ey2
    sx1, sx2 = half_w + ex1 * fx1, half_w + ex2 * fx2
    x_lo, x_hi = min(sx1, sx2), max(sx1, sx2)
    if not clips.has_gap(x_lo, x_hi): return

    front = sectors[front_idx]
    fh, ch = front[0], front[1]
    ft1, fb1 = half_h - (ch - vz) * fy1, half_h - (fh - vz) * fy1
    ft2, fb2 = half_h - (ch - vz) * fy2, half_h - (fh - vz) * fy2

    solid = back_idx is None
    back = sectors[back_idx] if back_idx is not None else None
    if back and (back[1] <= fh or back[0] >= ch): solid = True

    if back:
        bt1, bt2 = half_h - (back[1] - vz) * fy1, half_h - (back[1] - vz) * fy2
        bb1, bb2 = half_h - (back[0] - vz) * fy1, half_h - (back[0] - vz) * fy2

    # ── Draw first, then update clip state.
    # The step surface is the visible geometry; the tighten constrains
    # future geometry behind it.

    if solid:
        clips.draw_clipped([
            (sx1, ft1, sx2, ft2), (sx1, fb1, sx2, fb2),
            (sx1, ft1, sx1, fb1), (sx2, ft2, sx2, fb2),
        ], GREEN, surface, draw_stats)
        clips.mark_solid(x_lo, x_hi)
    elif back:
        if back[1] < ch:
            clips.draw_clipped([
                (sx1, ft1, sx2, ft2), (sx1, bt1, sx2, bt2),
                (sx1, ft1, sx1, bt1), (sx2, ft2, sx2, bt2),
            ], GREEN, surface, draw_stats)
        elif back[1] > ch:
            clips.draw_clipped([(sx1, ft1, sx2, ft2)], GREEN, surface, draw_stats)
        if back[0] > fh:
            clips.draw_clipped([
                (sx1, bb1, sx2, bb2), (sx1, fb1, sx2, fb2),
                (sx1, bb1, sx1, fb1), (sx2, bb2, sx2, fb2),
            ], GREEN, surface, draw_stats)
        elif back[0] < fh:
            clips.draw_clipped([(sx1, fb1, sx2, fb2)], GREEN, surface, draw_stats)
        clips.tighten(x_lo, x_hi, sx1, sx2,
                       max(ft1, bt1), max(ft2, bt2),
                       min(fb1, bb1), min(fb2, bb2))

# ── Fixed-point clip spans ────────────────────────────────────────────────────
#
# 8-bit screen coordinates throughout.  Slopes are 0.8, intercepts are 8.0.
# All multiplies are 8x8.

FP_ZERO_FN = (0, 0)                     # slope=0, intercept=0
FP_BOT_FN  = (0, FP_RENDER_H - 1)      # slope=0, intercept=159


class FPClipSpans:
    """Fixed-point version of ClipSpans — pure 8-bit screen coordinates.

    Spans store xlo/xhi in 8.0 (pixel coords), top/bot as (slope_8, intercept)
    where slope_8 is 0.8 signed and intercept is 8.0.
    All multiplies are 8x8.
    """
    __slots__ = ("spans",)

    def __init__(self):
        self.spans = [(0, FP_RENDER_W, FP_ZERO_FN, FP_BOT_FN)]

    def is_full(self):
        return not self.spans

    def has_gap(self, lo, hi):
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W - 1, hi)
        for xlo, xhi, tfn, bfn in self.spans:
            if xlo > ihi:
                break
            if xhi <= ilo:
                continue
            clo = max(xlo, ilo)
            chi = min(xhi - 1, ihi)
            for x in range(clo, chi + 1):
                if fp_eval(tfn, x) < fp_eval(bfn, x):
                    return True
        return False

    def draw_clipped(self, lines, color, surface, stats=None):
        """Clip each line analytically to each overlapping span, then draw.

        Lines are in 8.0 screen pixel coordinates — direct to pygame.
        """
        for lx1, ly1, lx2, ly2 in lines:
            if stats is not None:
                stats[0] += 1
            drawn = False
            was_clipped = False

            # Nearly vertical line (less than 1 pixel wide)
            if abs(lx1 - lx2) < 1:
                ix = lx1
                if ix < 0 or ix >= FP_RENDER_W:
                    if stats is not None:
                        stats[3] += 1
                    continue
                found_span = False
                for xlo, xhi, tfn, bfn in self.spans:
                    if xlo <= ix < xhi:
                        found_span = True
                        yt = fp_eval(tfn, ix)
                        yb = fp_eval(bfn, ix)
                        if yt >= yb:
                            break
                        ya_orig = min(ly1, ly2)
                        yb_orig = max(ly1, ly2)
                        ya = max(ya_orig, yt)
                        ybb = min(yb_orig, yb)
                        if ya < ybb:
                            pygame.draw.line(surface, color,
                                             (ix, ya), (ix, ybb), 1)
                            drawn = True
                            if ya > ya_orig or ybb < yb_orig:
                                was_clipped = True
                        break
                if not drawn and stats is not None:
                    stats[3 if not found_span else 4] += 1
            else:
                x_min = min(lx1, lx2)
                x_max = max(lx1, lx2)
                overlaps_any = False
                for xlo, xhi, tfn, bfn in self.spans:
                    if xhi <= x_min or xlo >= x_max:
                        continue
                    overlaps_any = True
                    c = fp_clip_to_trap(lx1, ly1, lx2, ly2,
                                        xlo, xhi, tfn, bfn)
                    if c:
                        pygame.draw.line(surface, color,
                                         (c[0], c[1]),
                                         (c[2], c[3]), 1)
                        drawn = True
                        if (abs(c[0] - lx1) > 0 or
                            abs(c[1] - ly1) > 0 or
                            abs(c[2] - lx2) > 0 or
                            abs(c[3] - ly2) > 0):
                            was_clipped = True
                if not drawn and stats is not None:
                    stats[3 if not overlaps_any else 4] += 1
            if drawn and stats is not None:
                stats[2 if was_clipped else 1] += 1

    def mark_solid(self, lo, hi):
        """Remove [ilo, ihi) from spans.  All values in 8.0 pixels."""
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W, hi + 1)
        if ilo >= ihi:
            return
        new = []
        for xlo, xhi, tfn, bfn in self.spans:
            if xhi <= ilo or xlo >= ihi:
                new.append((xlo, xhi, tfn, bfn))
                continue
            if xlo < ilo:
                new.append((xlo, ilo, tfn, bfn))
            if ihi < xhi:
                new.append((ihi, xhi, tfn, bfn))
        self.spans = new

    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2):
        """Tighten top/bottom over [ilo, ihi).  All values in 8.0 pixels."""
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W, hi + 1)
        if ilo >= ihi:
            return
        new_tfn = fp_linfn(yt1, yt2, sx1, sx2)
        new_bfn = fp_linfn(yb1, yb2, sx1, sx2)
        new = []
        for xlo, xhi, tfn, bfn in self.spans:
            if xhi <= ilo or xlo >= ihi:
                new.append((xlo, xhi, tfn, bfn))
                continue
            if xlo < ilo:
                new.append((xlo, ilo, tfn, bfn))
            right = (ihi, xhi, tfn, bfn) if ihi < xhi else None
            ox0, ox1 = max(xlo, ilo), min(xhi, ihi)
            for tx0, tx1, t_fn in _fp_pw_max(tfn, new_tfn, ox0, ox1):
                for bx0, bx1, b_fn in _fp_pw_min(bfn, new_bfn, tx0, tx1):
                    if bx1 > bx0:
                        if (fp_eval(t_fn, bx0) < fp_eval(b_fn, bx0) or
                            fp_eval(t_fn, bx1 - 1) < fp_eval(b_fn, bx1 - 1)):
                            new.append((bx0, bx1, t_fn, b_fn))
            if right:
                new.append(right)
        self.spans = new


def _fp_pw_max(f, g, x0, x1):
    """Piecewise max of two 8-bit linear functions over [x0, x1).

    All x values in 8.0.  Functions are (slope_8, intercept).
    Returns list of (x0, x1, winning_fn).
    """
    fv0 = fp_eval(f, x0)
    gv0 = fp_eval(g, x0)
    fv1 = fp_eval(f, x1 - 1)
    gv1 = fp_eval(g, x1 - 1)
    d0, d1 = fv0 - gv0, fv1 - gv1
    if d0 >= 0 and d1 >= 0:
        return [(x0, x1, f)]
    if d0 <= 0 and d1 <= 0:
        return [(x0, x1, g)]
    # Crossover
    fvx1 = fp_eval(f, x1)
    gvx1 = fp_eval(g, x1)
    dx0 = fv0 - gv0
    dx1 = fvx1 - gvx1
    denom = dx0 - dx1
    if abs(denom) < 1:
        return [(x0, x1, f if d0 >= 0 else g)]
    span = x1 - x0
    cx = x0 + (dx0 * span) // denom
    cx = max(x0 + 1, min(x1 - 1, cx))
    if fp_eval(f, cx) >= fp_eval(g, cx):
        cx += 1
        if cx >= x1:
            return [(x0, x1, f)]
    else:
        if cx <= x0:
            return [(x0, x1, g)]
    if d0 > 0:
        return [(x0, cx, f), (cx, x1, g)]
    return [(x0, cx, g), (cx, x1, f)]


def _fp_pw_min(f, g, x0, x1):
    """Piecewise min of two 8-bit linear functions over [x0, x1)."""
    fv0 = fp_eval(f, x0)
    gv0 = fp_eval(g, x0)
    fv1 = fp_eval(f, x1 - 1)
    gv1 = fp_eval(g, x1 - 1)
    d0, d1 = fv0 - gv0, fv1 - gv1
    if d0 <= 0 and d1 <= 0:
        return [(x0, x1, f)]
    if d0 >= 0 and d1 >= 0:
        return [(x0, x1, g)]
    fvx1 = fp_eval(f, x1)
    gvx1 = fp_eval(g, x1)
    dx0 = fv0 - gv0
    dx1 = fvx1 - gvx1
    denom = dx0 - dx1
    if abs(denom) < 1:
        return [(x0, x1, f if d0 <= 0 else g)]
    span = x1 - x0
    cx = x0 + (dx0 * span) // denom
    cx = max(x0 + 1, min(x1 - 1, cx))
    if fp_eval(f, cx) <= fp_eval(g, cx):
        cx += 1
        if cx >= x1:
            return [(x0, x1, f)]
    else:
        if cx <= x0:
            return [(x0, x1, g)]
    if d0 < 0:
        return [(x0, cx, f), (cx, x1, g)]
    return [(x0, cx, g), (cx, x1, f)]


# ── Fixed-point BSP rendering (prescaled 8-bit) ──────────────────────────────

def fp_render_seg(si, clips, ctx, vz, surface, vcache):
    """Render a seg from the stripped fp_segs table.

    ctx: view context tuple from fp_view_context.
    vcache: dict mapping vertex index -> (evx_t, evx_r, evy, fvx, vy_idx).
    """
    s = fp_segs[si]
    v1_idx, v2_idx = s[0], s[1]

    # Back-face test using prescaled linedef vertices (integer part of player pos)
    ld = linedefs[s[3]]
    lv1, lv2 = fp_vertexes[ld[0]], fp_vertexes[ld[1]]
    ldx, ldy = lv2[0] - lv1[0], lv2[1] - lv1[1]
    px_int = ctx[0]
    py_int = ctx[1]
    dot = ldy * (px_int - lv1[0]) - ldx * (py_int - lv1[1])
    if s[4] == 1:
        dot = -dot
    if dot <= 0:
        return

    front_idx, back_idx = seg_sectors(s)

    # Look up cached view-space transforms
    evx1_t, evx1_r, evy1, fvx1, vy_idx1 = vcache[v1_idx]
    evx2_t, evx2_r, evy2, fvx2, vy_idx2 = vcache[v2_idx]
    # Sub-pixel uses truncated vx (frac compensates); otherwise use rounded
    evx1 = evx1_t if use_subpixel else evx1_r
    evx2 = evx2_t if use_subpixel else evx2_r

    # Near clip (8-bit view coords, 0.8 parametric t)
    nc = fp_near_clip(evx1, evy1, evx2, evy2)
    if nc is None:
        return
    ex1, ey1, ex2, ey2 = nc

    # Perspective reciprocal: 512-entry table lookup (5.2 index, zero muls)
    # Use vy_idx from view transform; near-clipped endpoints use integer vy << 2
    idx1 = vy_idx1 if ey1 == evy1 else (ey1 << RECIP_FRAC_BITS)
    idx2 = vy_idx2 if ey2 == evy2 else (ey2 << RECIP_FRAC_BITS)
    rxh1, rxl1 = fp_recip_x(idx1)
    rxh2, rxl2 = fp_recip_x(idx2)
    ryh1, ryl1 = fp_recip_y(idx1)
    ryh2, ryl2 = fp_recip_y(idx2)

    # Project to screen X
    fp_module.mul_cat("proj")
    if use_subpixel:
        # Near-clipped endpoints have no useful fraction
        fvx1_c = fvx1 if ey1 == evy1 else 0
        fvx2_c = fvx2 if ey2 == evy2 else 0
        sx1 = fp_project_x_subpx(ex1, fvx1_c, rxh1, rxl1)
        sx2 = fp_project_x_subpx(ex2, fvx2_c, rxh2, rxl2)
    else:
        sx1 = fp_project_x(ex1, rxh1, rxl1)
        sx2 = fp_project_x(ex2, rxh2, rxl2)

    x_lo = min(sx1, sx2)
    x_hi = max(sx1, sx2)

    if not clips.has_gap(x_lo, x_hi):
        return

    # Sector heights (prescaled by /8)
    front = fp_sectors[front_idx]
    fh, ch = front[0], front[1]

    # Project top/bottom: two 8x8 muls per endpoint
    ft1 = fp_project_y(ch - vz, ryh1, ryl1)
    fb1 = fp_project_y(fh - vz, ryh1, ryl1)
    ft2 = fp_project_y(ch - vz, ryh2, ryl2)
    fb2 = fp_project_y(fh - vz, ryh2, ryl2)

    solid = back_idx is None
    back = fp_sectors[back_idx] if back_idx is not None else None
    if back and (back[1] <= fh or back[0] >= ch):
        solid = True

    fp_module.mul_cat("clip")
    if solid:
        clips.draw_clipped([
            (sx1, ft1, sx2, ft2),
            (sx1, fb1, sx2, fb2),
            (sx1, ft1, sx1, fb1),
            (sx2, ft2, sx2, fb2),
        ], GREEN, surface, draw_stats)
        clips.mark_solid(x_lo, x_hi)
    elif back:
        # Only project back heights when needed (saves up to 8 muls)
        need_bt = back[1] < ch   # ceiling drops: need bt for upper step + tighten
        need_bb = back[0] > fh   # floor rises: need bb for lower step + tighten

        if need_bt:
            fp_module.mul_cat("proj")
            bt1 = fp_project_y(back[1] - vz, ryh1, ryl1)
            bt2 = fp_project_y(back[1] - vz, ryh2, ryl2)
            fp_module.mul_cat("clip")
            clips.draw_clipped([
                (sx1, ft1, sx2, ft2),
                (sx1, bt1, sx2, bt2),
                (sx1, ft1, sx1, bt1),
                (sx2, ft2, sx2, bt2),
            ], GREEN, surface, draw_stats)
        elif back[1] > ch:
            clips.draw_clipped([(sx1, ft1, sx2, ft2)], GREEN, surface, draw_stats)

        if need_bb:
            fp_module.mul_cat("proj")
            bb1 = fp_project_y(back[0] - vz, ryh1, ryl1)
            bb2 = fp_project_y(back[0] - vz, ryh2, ryl2)
            fp_module.mul_cat("clip")
            clips.draw_clipped([
                (sx1, bb1, sx2, bb2),
                (sx1, fb1, sx2, fb2),
                (sx1, bb1, sx1, fb1),
                (sx2, bb2, sx2, fb2),
            ], GREEN, surface, draw_stats)
        elif back[0] < fh:
            clips.draw_clipped([(sx1, fb1, sx2, fb2)], GREEN, surface, draw_stats)

        # Tighten: use back heights only if computed, otherwise front = tighter
        tt1 = bt1 if need_bt else ft1
        tt2 = bt2 if need_bt else ft2
        tb1 = bb1 if need_bb else fb1
        tb2 = bb2 if need_bb else fb2
        clips.tighten(x_lo, x_hi, sx1, sx2,
                       max(ft1, tt1), max(ft2, tt2),
                       min(fb1, tb1), min(fb2, tb2))


def render_subsector_fp(idx, clips, ctx, vz, surface, vcache):
    """Render a subsector with frame-global vertex cache.

    ctx: view context tuple from fp_view_context.
    """
    ssec = fp_ssectors[idx]

    # Collect unique vertex indices from this subsector's segs
    vert_indices = set()
    for si in range(ssec[1], ssec[1] + ssec[0]):
        s = fp_segs[si]
        vert_indices.add(s[0])
        vert_indices.add(s[1])

    # Transform each unique vertex once (frame-global cache)
    fp_module.mul_cat("view")
    for vi in vert_indices:
        if vi not in vcache:
            v = fp_vertexes[vi]
            vcache[vi] = fp_to_view(v[0], v[1], ctx)

    # Render segs using cached vertex data
    for si in range(ssec[1], ssec[1] + ssec[0]):
        fp_render_seg(si, clips, ctx, vz, surface, vcache)
        if clips.is_full():
            return


def render_bsp_fp(nid, clips, ctx, vz,
                   wx_full, wy_full, cos_f, sin_f, surface, vcache):
    """BSP traversal for the 8-bit fixed-point path."""
    if clips.is_full():
        return
    if nid & NF_SUBSECTOR:
        render_subsector_fp(0 if nid == 0xFFFF else nid & 0x7FFF,
                            clips, ctx, vz, surface, vcache)
        return
    node = nodes[nid]
    side = point_on_side(wx_full, wy_full, node)
    ch = (node[12], node[13])
    render_bsp_fp(ch[side], clips, ctx, vz,
                  wx_full, wy_full, cos_f, sin_f, surface, vcache)
    if clips.is_full():
        return
    far = side ^ 1
    br = fp_bbox_visible(node, far, cos_f, sin_f, wx_full, wy_full)
    if br is not None:
        if clips.has_gap(br[0], br[1]):
            render_bsp_fp(ch[far], clips, ctx, vz,
                          wx_full, wy_full, cos_f, sin_f, surface, vcache)


# ── Angle conversion helpers ─────────────────────────────────────────────────

def radians_to_byte(rad):
    """Convert radians to 0..255 (8-bit angle)."""
    deg = math.degrees(rad) % 360.0
    return int(deg * 256.0 / 360.0 + 0.5) & 0xFF

def byte_to_radians(b):
    """Convert 0..255 (8-bit angle) to radians."""
    return math.radians((b & 0xFF) * 360.0 / 256.0)


# ── Main loop ────────────────────────────────────────────────────────────────

# [total, unclipped, clipped, trivial_reject, clip_reject]
draw_stats = [0, 0, 0, 0, 0]

sys.setrecursionlimit(10000)
pygame.init()
screen = pygame.display.set_mode((SCREEN_W, SCREEN_H))
pygame.display.set_caption("DOOM E1M1 — Wireframe BSP")
clock = pygame.time.Clock()
hud_font = pygame.font.SysFont("monospace", 14)
fp_surface = pygame.Surface((FP_WIDTH, FP_HEIGHT))  # small render target for FP mode
_real_drawline = pygame.draw.line

def _xor_drawline(surface, color, p1, p2, w=1):
    """Draw a line by XOR-ing each pixel onto the surface."""
    x0, y0 = int(p1[0]), int(p1[1])
    x1, y1 = int(p2[0]), int(p2[1])
    bx, by = min(x0, x1), min(y0, y1)
    bw = max(abs(x1 - x0), 1) + 1
    bh = max(abs(y1 - y0), 1) + 1
    # Clamp to screen
    if bx < 0: bw += bx; x0 -= bx; x1 -= bx; bx = 0
    if by < 0: bh += by; y0 -= by; y1 -= by; by = 0
    if bx + bw > WIDTH: bw = WIDTH - bx
    if by + bh > HEIGHT: bh = HEIGHT - by
    if bw <= 0 or bh <= 0: return
    tmp = pygame.Surface((bw, bh))
    tmp.fill((0, 0, 0))
    _real_drawline(tmp, color, (x0 - bx, y0 - by), (x1 - bx, y1 - by), w)
    # XOR the bounding rect
    region = surface.subsurface((bx, by, bw, bh))
    sa = pygame.surfarray.pixels3d(region)
    ta = pygame.surfarray.pixels3d(tmp)
    sa ^= ta
    del sa, ta

angle = math.radians(pangle)              # float radians (used in float mode)
angle_byte = radians_to_byte(angle)       # 0..255 (used in fixed-point mode)
use_fixedpoint = False                    # False = float, True = fixed-point
use_xor = False                           # XOR drawing mode
use_subpixel = False                      # Sub-pixel X projection (1 extra mul)
turn_speed = 2.5                          # radians/sec for float mode
turn_speed_byte = 45                      # byte-units/sec for FP mode (~63 deg/sec)
move_speed = 300.0

running = True
while running:
    dt = clock.tick(60) / 1000.0
    for ev in pygame.event.get():
        if ev.type == pygame.QUIT:
            running = False
        if ev.type == pygame.KEYDOWN:
            if ev.key == pygame.K_ESCAPE:
                running = False
            elif ev.key == pygame.K_f:
                use_fixedpoint = not use_fixedpoint
                # Sync angle representations without resetting position
                if use_fixedpoint:
                    angle_byte = radians_to_byte(angle)
                else:
                    angle = byte_to_radians(angle_byte)
            elif ev.key == pygame.K_x:
                use_xor = not use_xor
            elif ev.key == pygame.K_s:
                use_subpixel = not use_subpixel

    keys = pygame.key.get_pressed()

    if use_fixedpoint:
        # ── Fixed-point movement ──
        if keys[pygame.K_LEFT]:
            angle_byte = (angle_byte + int(turn_speed_byte * dt + 0.5)) & 0xFF
        if keys[pygame.K_RIGHT]:
            angle_byte = (angle_byte - int(turn_speed_byte * dt + 0.5)) & 0xFF
        # Movement uses float cos/sin of the byte angle for sub-pixel precision
        move_angle = byte_to_radians(angle_byte)
        if keys[pygame.K_UP]:
            player_x += math.cos(move_angle) * move_speed * dt
            player_y += math.sin(move_angle) * move_speed * dt
        if keys[pygame.K_DOWN]:
            player_x -= math.cos(move_angle) * move_speed * dt
            player_y -= math.sin(move_angle) * move_speed * dt

        fp_surface.fill((0, 0, 0))
        if use_xor:
            pygame.draw.line = _xor_drawline
        else:
            pygame.draw.line = _real_drawline
        for i in range(5):
            draw_stats[i] = 0

        # Fixed-point sin/cos (1.7)
        fp_module.mul_reset()
        # Prescaled player position in 8.8 (sub-unit precision, smooth movement)
        px_88 = int((player_x - MAP_CENTER_X) * 256 / PRESCALE)
        py_88 = int((player_y - MAP_CENTER_Y) * 256 / PRESCALE)
        vz_ps = (player_floor(player_x, player_y) + 41) // PRESCALE
        # Un-prescaled position for BSP node traversal
        px_full = int(player_x)
        py_full = int(player_y)

        # Precompute view context once per frame
        fp_module.mul_cat("view")
        sc = fp_sincos(angle_byte)
        ctx = fp_view_context(px_88, py_88, sc)

        # Float sin/cos for bbox visibility (computed once per frame)
        ang_rad = angle_byte * 2 * math.pi / 256
        cos_f = math.cos(ang_rad)
        sin_f = math.sin(ang_rad)

        render_bsp_fp(len(nodes) - 1, FPClipSpans(),
                      ctx, vz_ps,
                      px_full, py_full, cos_f, sin_f, fp_surface, {})

        # Nearest-neighbour upscale to display
        screen.fill((0, 0, 0))
        pygame.transform.scale(fp_surface, (SCREEN_W, SCREEN_H), screen)
    else:
        # ── Float movement (original) ──
        if keys[pygame.K_LEFT]:
            angle += turn_speed * dt
        if keys[pygame.K_RIGHT]:
            angle -= turn_speed * dt
        if keys[pygame.K_UP]:
            player_x += math.cos(angle) * move_speed * dt
            player_y += math.sin(angle) * move_speed * dt
        if keys[pygame.K_DOWN]:
            player_x -= math.cos(angle) * move_speed * dt
            player_y -= math.sin(angle) * move_speed * dt

        screen.fill((0, 0, 0))
        if use_xor:
            pygame.draw.line = _xor_drawline
        else:
            pygame.draw.line = _real_drawline
        for i in range(5):
            draw_stats[i] = 0
        cos_a, sin_a = math.cos(angle), math.sin(angle)
        vz = player_floor(player_x, player_y) + 41.0
        render_bsp(len(nodes) - 1, ClipSpans(), cos_a, sin_a,
                   player_x, player_y, vz, screen)

    # Restore normal draw after frame
    pygame.draw.line = _real_drawline

    # ── HUD (works for both modes) ──
    total, unclipped, clipped, trivial, clip_rej = draw_stats
    fps = clock.get_fps()
    mode_str = f"FP {FP_WIDTH}x{FP_HEIGHT}" if use_fixedpoint else f"FLOAT {SCREEN_W}x{SCREEN_H}"
    xor_str = " XOR" if use_xor else ""
    subpx_str = " SUBPX" if use_subpixel else ""
    if use_fixedpoint:
        mc = fp_module.mul_counts
        mul_total = sum(mc.values())
        mul_str = f"  {mul_total} muls (V:{mc['view']} P:{mc['proj']} C:{mc['clip']})"
    else:
        mul_str = ""
    hud = (f"[{mode_str}{xor_str}{subpx_str}]  {total} total  {unclipped} pass  {clipped} clip  "
           f"{trivial} trivial  {clip_rej} reject{mul_str}  {fps:.0f}fps")
    screen.blit(hud_font.render(hud, True, (255, 255, 0)), (4, 4))
    pygame.display.flip()

pygame.quit()
