#!/usr/bin/env python3
"""DOOM E1M1 wireframe renderer — BSP front-to-back with 2D trapezoid clip spans.

COMMAND LIST ARCHITECTURE (planned)
====================================

The renderer can be split into front-end (BSP traversal) and back-end
(clip + rasterise) communicating via a sequential command buffer (~2KB/frame).

Commands:
  DRAW_LINE      9B   cmd(1) x1(2) y1(2) x2(2) y2(2)
  MARK_SOLID     5B   cmd(1) x_lo(2) x_hi(2)
  TIGHTEN       17B   cmd(1) x_lo(2) x_hi(2) sx1(2) sx2(2) yt1(2) yt2(2) yb1(2) yb2(2)
  END_SUBSECTOR  1B   cmd(1) — barrier: apply deferred clip updates

Front-end (BSP processor):
  - BSP walk, point_on_side, back-face test
  - View transform, near-clip, projection (all cached via flat arrays)
  - Determine seg type, emit DRAW_LINE commands
  - Emit deferred MARK_SOLID / TIGHTEN after END_SUBSECTOR
  - Maintain 32-byte coarse column bitmap for has_gap / is_full

Back-end (clip + raster processor):
  - Maintain precise clip spans (trapezoid list with inner/outer bbox)
  - Process DRAW_LINE: trivial accept/reject, portal walk, Cyrus-Beck, rasterise
  - Process MARK_SOLID: remove columns, recompute span inner/outer bbox
  - Process TIGHTEN: narrow boundaries, detect dominance internally, merge spans
  - Process END_SUBSECTOR: apply deferred ops from the preceding draw phase

Key design issues resolved:

1. has_gap is a synchronous query — solved by coarse column bitmap (32 bytes)
   in the front-end.  One bit per screen column.  MARK_SOLID sets bits locally
   when the command is emitted.  has_gap checks if any bits in [lo,hi] are
   clear — O(1) byte-level operations.  Conservative: may over-traverse (enter
   subtrees the precise back-end would reject) but never misses visible geometry.

2. is_full — front-end checks if all 32 bitmap bytes are $FF.  Also
   detectable by the back-end as a flag after MARK_SOLID/TIGHTEN.

3. line_survives (tighten dominance) — moved entirely to back-end.  When
   processing TIGHTEN, the back-end checks if new boundaries are more
   restrictive than all existing span boundaries in the range.  If so, merge.
   No front-end query needed.  More accurate than the front-end's approximate
   line_survives check.

4. Deferred draw ordering — END_SUBSECTOR acts as a barrier.  All DRAW_LINEs
   in a subsector are processed before the clip updates that follow.

5. Bitmap lag — deferred MARK_SOLID means the front-end bitmap updates at
   subsector boundaries, not per-seg.  Within a subsector, the bitmap is stale.
   Cost: a few extra segs processed before the bitmap catches up.  Acceptable
   since within-subsector geometry is typically compact.

6. 16-bit coordinates — off-screen projections (e.g. sy = -4746) require
   s16 in DRAW_LINE and TIGHTEN.  Back-end clamps to screen at draw time.

Architecture enables:
  - Front-end and back-end on different processors (or pipelined on one)
  - Back-end is self-contained FIFO processor, no callbacks
  - Front-end never accesses clip spans — only its coarse bitmap
  - Command buffer is small (~2KB) and strictly sequential
"""

import os, struct, math, sys, random, pygame
from line6502 import estimate_line_cycles
import fp as fp_module
from endpoint_spans import EndpointClipSpans
from fp import (fp_mul8, fp_mul7, fp_div8, s8,
                fp_sin, fp_cos, fp_sincos,
                fp_recip, fp_project_x, fp_project_x_subpx, fp_project_y,
                fp_linfn, fp_eval, fp_eval_88, fp_view_context, fp_to_view, fp_near_clip,
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
# Heights are prescaled by (PRESCALE / 1.2) instead of PRESCALE, baking in
# the 1.2x aspect ratio correction.  This allows a single reciprocal table
# for both X and Y projection.

from fp import ASPECT_NUM, ASPECT_DEN

fp_vertexes = [
    ((v[0] - MAP_CENTER_X) // PRESCALE,
     (v[1] - MAP_CENTER_Y) // PRESCALE)
    for v in vertexes
]

def _prescale_height(h):
    """Prescale a height value with 1.2x aspect baked in."""
    return (h * ASPECT_NUM + ASPECT_DEN // 2) // (PRESCALE * ASPECT_DEN)

fp_sectors = [
    (_prescale_height(s[0]), _prescale_height(s[1]), *s[2:])
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

# ── Vertex With Height (VWH) table ──────────────────────────────────────
#
# Each VWH is a unique (vertex_index, prescaled_height) pair.
# Segs reference VWH indices for cached Y projection.

_vwh_map = {}   # (vertex_idx, height) -> vwh_idx
_vwh_table = [] # vwh_idx -> (vertex_idx, height)

def _vwh(vertex_idx, height):
    """Get or create a VWH index for (vertex, height)."""
    key = (vertex_idx, height)
    idx = _vwh_map.get(key)
    if idx is None:
        idx = len(_vwh_table)
        _vwh_table.append(key)
        _vwh_map[key] = idx
    return idx

# Build VWH-augmented seg table: original seg fields + 4 front VWH indices
# + 4 back VWH indices (or -1 if one-sided) + linedef deltas (ldx, ldy).
#
# Invariant: ldx and ldy must fit in s8.  The 6502 back-face test reads
# them as single-byte signed values and uses an s8×s16 multiply.  The
# Python FP renderer uses the same values so the two paths agree.
# A linedef exceeding this bound would require a wider multiply primitive
# on the 6502 and would silently diverge from the reference — assert here
# so the failure is loud at load time instead of a subtle rendering bug
# on some other map.
_fp_segs_vwh = []
for _i, _s in enumerate(_stripped_segs):
    _fi, _bi = seg_sectors(_s)
    _fs = fp_sectors[_fi]
    _fh, _ch = _fs[0], _fs[1]
    _v1, _v2 = _s[0], _s[1]
    _vwh_ft1 = _vwh(_v1, _ch)
    _vwh_fb1 = _vwh(_v1, _fh)
    _vwh_ft2 = _vwh(_v2, _ch)
    _vwh_fb2 = _vwh(_v2, _fh)
    if _bi is not None:
        _bs = fp_sectors[_bi]
        _vwh_bt1 = _vwh(_v1, _bs[1])
        _vwh_bb1 = _vwh(_v1, _bs[0])
        _vwh_bt2 = _vwh(_v2, _bs[1])
        _vwh_bb2 = _vwh(_v2, _bs[0])
    else:
        _vwh_bt1 = _vwh_bb1 = _vwh_bt2 = _vwh_bb2 = -1
    # Linedef delta (for back-face test), asserted s8 — matches 6502 packing.
    _ld = linedefs[_s[3]]
    _lv1 = fp_vertexes[_ld[0]]
    _lv2 = fp_vertexes[_ld[1]]
    _ldx = _lv2[0] - _lv1[0]
    _ldy = _lv2[1] - _lv1[1]
    assert -128 <= _ldx <= 127, (
        f"seg {_i} linedef {_s[3]}: prescaled ldx={_ldx} exceeds s8; "
        f"raw linedef longer than {PRESCALE * 127} units on this axis")
    assert -128 <= _ldy <= 127, (
        f"seg {_i} linedef {_s[3]}: prescaled ldy={_ldy} exceeds s8; "
        f"raw linedef longer than {PRESCALE * 127} units on this axis")
    _fp_segs_vwh.append((_s, _fi, _bi, _fh, _ch,
                         _vwh_ft1, _vwh_fb1, _vwh_ft2, _vwh_fb2,
                         _vwh_bt1, _vwh_bb1, _vwh_bt2, _vwh_bb2,
                         _ldx, _ldy))

fp_segs = _stripped_segs
fp_segs_vwh = _fp_segs_vwh
fp_ssectors = _stripped_ssectors
vwh_table = _vwh_table

# ── Build packed byte arrays for 8-bit processor simulation ──────────────
from wad_packed import build_packed
print(f"PRESCALE={PRESCALE} (set DOOM_PRESCALE env var to override; 8 or 16)")
_render_6502 = None  # lazy-loaded on first use
_6502_result = None  # (lines, muls) from background render
packed_rom_main, packed_rom_detail, packed_rom_recip, packed_bbox_table, packed_layout = build_packed(
    vertexes, fp_vertexes, nodes, fp_ssectors, fp_segs,
    fp_segs_vwh, vwh_table, fp_sectors, linedefs, sidedefs,
    PRESCALE, MAP_CENTER_X, MAP_CENTER_Y)

# Build ROM banks for sideways ROM paging
packed_rom_banks = [
    bytearray(16384),  # bank 0: rom_main
    bytearray(16384),  # bank 1: rom_detail
    bytearray(16384),  # bank 2: bbox_table + rasteriser + clipper
]
packed_rom_banks[0][:len(packed_rom_main)] = packed_rom_main
packed_rom_banks[1][:len(packed_rom_detail)] = packed_rom_detail
packed_rom_banks[2][:len(packed_bbox_table)] = packed_bbox_table
_rast_path = os.path.join(os.path.dirname(__file__) or '.', 'linedraw_bank2.bin')
if os.path.exists(_rast_path):
    with open(_rast_path, 'rb') as _f:
        _rast_bin = _f.read()
    _rast_offset = len(packed_bbox_table)
    packed_rom_banks[2][_rast_offset:_rast_offset + len(_rast_bin)] = _rast_bin
_clip_path = os.path.join(os.path.dirname(__file__) or '.', 'clipper_bank2.bin')
if os.path.exists(_clip_path):
    with open(_clip_path, 'rb') as _f:
        _clip_bin = _f.read()
    # clipper ORG is $9B20, bank 2 base is $8000 → offset $1B20
    _clip_offset = 0x9B20 - 0x8000
    packed_rom_banks[2][_clip_offset:_clip_offset + len(_clip_bin)] = _clip_bin

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

# ── Map trace (populated during BSP traversal, drawn in map mode) ─────────

map_trace = {
    "subsectors": set(),      # indices of traversed subsectors
    "ss_order": [],           # traversal order of subsectors
    "segs_processed": set(),  # indices of segs that passed back-face test
    "segs_drawn": set(),      # indices of segs that produced visible lines
    "vertices": set(),        # vertex indices that were projected
    "nodes_visited": set(),   # BSP node indices visited
    "vertex_muls": {},        # vertex_idx -> [v_muls, p_muls]
}


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
                for _vs in self.spans:
                    xlo, xhi, tfn, bfn = _vs[:4]
                    if xlo <= ix < xhi:
                        found_span = True
                        yt, yb = _eval(tfn, ix), _eval(bfn, ix)
                        if yt >= yb: break
                        ya_orig, yb_orig = min(ly1, ly2), max(ly1, ly2)
                        ya = max(ya_orig, yt)
                        ybb = min(yb_orig, yb)
                        if ya < ybb:
                            pygame.draw.line(surface, _rand_color(),
                                             (ix, int(ya)), (ix, int(ybb)), 1)
                            drawn = True
                            if ya > ya_orig + 0.5 or ybb < yb_orig - 0.5:
                                was_clipped = True
                        break
                if not drawn and stats is not None:
                    stats[3 if not found_span else 4] += 1
            else:
                # Float path: simple per-span Cyrus-Beck (no portal walk).
                x_min, x_max = min(lx1, lx2), max(lx1, lx2)
                overlaps_any = False
                for xlo, xhi, tfn, bfn in self.spans:
                    if xhi <= x_min or xlo >= x_max:
                        continue
                    overlaps_any = True
                    c = _clip_to_trap(lx1, ly1, lx2, ly2,
                                      xlo, xhi, tfn, bfn)
                    if c:
                        pygame.draw.line(surface, _rand_color(),
                                         (int(c[0]), int(c[1])),
                                         (int(c[2]), int(c[3])), 1)
                        drawn = True
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

def _bbox_screen_range(pts, half_w, focal_x):
    """Project view-space bbox corners to screen X range, clipping edges to near plane.

    pts: list of (vx, vy) in view space (4 corners of the bbox quad).
    Returns (min_sx, max_sx) or None if entirely behind.
    """
    if all(p[1] < NEAR for p in pts):
        return None
    # Collect projected X values from all visible corners and near-clipped edge crossings
    sxs = []
    n = len(pts)
    for i in range(n):
        vx0, vy0 = pts[i]
        vx1, vy1 = pts[(i + 1) % n]
        if vy0 >= NEAR:
            sxs.append(half_w + vx0 * focal_x / vy0)
        # If this edge crosses the near plane, add the crossing point
        if (vy0 < NEAR) != (vy1 < NEAR):
            t = (NEAR - vy0) / (vy1 - vy0)
            cx = vx0 + t * (vx1 - vx0)
            sxs.append(half_w + cx * focal_x / NEAR)
    if not sxs:
        return None
    return int(min(sxs)), int(max(sxs))

def bbox_visible(node, far_side, cos_a, sin_a, vx, vy):
    base = 4 + far_side * 4
    top, bot, left, right = node[base], node[base+1], node[base+2], node[base+3]
    if left <= vx <= right and bot <= vy <= top:
        return 0, WIDTH - 1
    pts = [to_view(wx, wy, vx, vy, cos_a, sin_a)
           for wx, wy in ((left, top), (right, top), (right, bot), (left, bot))]
    return _bbox_screen_range(pts, WIDTH * 0.5, FOCAL_X)

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
    return _bbox_screen_range(pts, FP_RENDER_W * 0.5, FP_FOCAL_X)


def fp_bbox_visible_fixed(node, far_side, ctx):
    """Fixed-point bbox visibility — matches the 6502 native implementation.

    Prescales the raw bbox corners, runs them through fp_to_view / fp_recip /
    fp_project_x with the same precision the 6502 pipeline uses, and returns
    (min_sx, max_sx) or None.  Both Python and 6502 call into this routine,
    so verify_exact stays bit-exact.

    Args:
        node: Python node tuple (raw WAD coords at node[4..11])
        far_side: 0 (right) or 1 (left)
        ctx: fp_view_context result (prescaled player + rotated frac)
    """
    from fp import (PRESCALE as _PRESCALE, MAP_CENTER_X as _MCX,
                         MAP_CENTER_Y as _MCY, FP_RENDER_W as _FPW,
                         NEAR_FP as _NEAR, fp_to_view as _fp_to_view,
                         fp_recip as _fp_recip, fp_project_x as _fp_project_x,
                         m8 as _m8)
    base = 4 + far_side * 4
    rt_raw, rb_raw, rl_raw, rr_raw = (
        node[base], node[base + 1], node[base + 2], node[base + 3])
    # Prescale bbox corners into the same 8.0 frame as the player in ctx.
    top = (rt_raw - _MCY) // _PRESCALE
    bot = (rb_raw - _MCY) // _PRESCALE
    left = (rl_raw - _MCX) // _PRESCALE
    right = (rr_raw - _MCX) // _PRESCALE

    px_int, py_int = ctx[0], ctx[1]

    # Trivial inside test (prescaled).
    if left <= px_int <= right and bot <= py_int <= top:
        return 0, _FPW - 1

    # Transform the 4 bbox corners to view space using the shared prescaled
    # fp_to_view routine (same precision as fp_render_seg).
    corners = ((left, top), (right, top), (right, bot), (left, bot))
    pts = []
    for wx, wy in corners:
        _, evx, evy, _, evy_idx = _fp_to_view(wx, wy, ctx)
        pts.append((evx, evy, evy_idx))

    # Entirely behind near plane → not visible.
    if all(p[1] < _NEAR for p in pts):
        return None

    sxs = []
    for i in range(4):
        vx0, vy0, vy_idx0 = pts[i]
        vx1, vy1, _ = pts[(i + 1) % 4]
        if vy0 >= _NEAR:
            rxh, rxl = _fp_recip(vy_idx0)
            sxs.append(_fp_project_x(vx0, rxh, rxl))
        # Edge crossing NEAR plane → project the crossing point at NEAR.
        if (vy0 < _NEAR) != (vy1 < _NEAR):
            dvy = vy1 - vy0
            if dvy != 0:
                # Parametric t in 0.8: (NEAR - vy0) << 8 / dvy
                t = ((_NEAR - vy0) << 8) // dvy
                dvx = vx1 - vx0
                cx = vx0 + _m8(t, dvx)
                # 6502's use_ey1 path passes ey1 (=NEAR_FP) directly as a
                # raw integer index with averaging flag = 0.  In fp_recip's
                # 9.1 convention that's NEAR_FP << 1 (even → no averaging).
                rxh, rxl = _fp_recip(_NEAR << 1)
                sxs.append(_fp_project_x(cx, rxh, rxl))

    if not sxs:
        return None
    return min(sxs), max(sxs)

# ── BSP rendering ────────────────────────────────────────────────────────────

GREEN = (0, 200, 0)

def _rand_color():
    return (random.randint(60, 255), random.randint(60, 255), random.randint(60, 255))

_frame_nj_lines = []  # captured line coords for NJ raster mode

def _cycle_drawline(surface, color, p1, p2, w=1):
    """Draw line and accumulate 6502 cycle estimate."""
    x1, y1, x2, y2 = int(p1[0]), int(p1[1]), int(p2[0]), int(p2[1])
    _frame_6502_cycles[0] += estimate_line_cycles(x1, y1, x2, y2)
    _frame_nj_lines.append((x1, y1, x2, y2))
    return _real_drawline(surface, color, p1, p2, w)

def render_bsp(nid, clips, cos_a, sin_a, vx, vy, vz, surface):
    if clips.is_full(): return
    if nid & NF_SUBSECTOR:
        ssid = 0 if nid == 0xFFFF else nid & 0x7FFF
        map_trace["subsectors"].add(ssid)
        map_trace["ss_order"].append(ssid)
        render_subsector(ssid, clips, cos_a, sin_a, vx, vy, vz, surface)
        return
    map_trace["nodes_visited"].add(nid)
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
    deferred = []
    for si in range(ssec[1], ssec[1] + ssec[0]):
        render_seg(si, clips, cos_a, sin_a, vx, vy, vz, surface, deferred)
    # Apply clip updates after all draws in this subsector
    for op in deferred:
        if op[0] == 'solid':
            clips.mark_solid(op[1], op[2])
        else:
            clips.tighten(*op[1:])
        if clips.is_full(): return

def render_seg(si, clips, cos_a, sin_a, vx, vy, vz, surface, deferred=None):
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

    map_trace["segs_processed"].add(si)
    map_trace["vertices"].add(s[0])
    map_trace["vertices"].add(s[1])

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

    map_trace["segs_drawn"].add(si)

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
        if deferred is not None:
            deferred.append(('solid', x_lo, x_hi))
        else:
            clips.mark_solid(x_lo, x_hi)
    elif back:
        if back[1] < ch:
            lines = [(sx1, bt1, sx2, bt2),
                     (sx1, ft1, sx1, bt1), (sx2, ft2, sx2, bt2)]
            if ch <= vz:  # face below eyeline: top edge (ft) always clipped
                pass      # ft already omitted
            else:
                lines.insert(0, (sx1, ft1, sx2, ft2))
            clips.draw_clipped(lines, GREEN, surface, draw_stats)
        elif back[1] > ch:
            clips.draw_clipped([(sx1, ft1, sx2, ft2)], GREEN, surface, draw_stats)
        if back[0] > fh:
            lines = [(sx1, bb1, sx2, bb2),
                     (sx1, bb1, sx1, fb1), (sx2, bb2, sx2, fb2)]
            if fh >= vz:  # face above eyeline: bottom edge (fb) always clipped
                pass      # fb already omitted
            else:
                lines.insert(1, (sx1, fb1, sx2, fb2))
            clips.draw_clipped(lines, GREEN, surface, draw_stats)
        elif back[0] < fh:
            clips.draw_clipped([(sx1, fb1, sx2, fb2)], GREEN, surface, draw_stats)
        if deferred is not None:
            deferred.append(('tighten', x_lo, x_hi, sx1, sx2,
                             max(ft1, bt1), max(ft2, bt2),
                             min(fb1, bb1), min(fb2, bb2)))
        else:
            clips.tighten(x_lo, x_hi, sx1, sx2,
                           max(ft1, bt1), max(ft2, bt2),
                           min(fb1, bb1), min(fb2, bb2))

# ── Fixed-point clip spans ────────────────────────────────────────────────────
#
# 8-bit screen coordinates throughout.  Slopes are 0.8, intercepts are 8.0.
# All multiplies are 8x8.





# ── Fixed-point BSP rendering (prescaled 8-bit) ──────────────────────────────

def fp_render_seg(si, clips, ctx, vz, surface, vcache, vwh_cache, deferred=None):
    """Render a seg from the stripped fp_segs table.

    vcache: frame-global vertex transforms.
    vwh_cache: frame-global Y projections indexed by VWH.
    """
    svwh = fp_segs_vwh[si]
    s = svwh[0]
    v1_idx, v2_idx = s[0], s[1]

    # Back-face test using prescaled linedef vertices.  ldx/ldy are taken
    # from the precomputed s8-asserted table (matches 6502 packed format).
    ld = linedefs[s[3]]
    lv1 = fp_vertexes[ld[0]]
    ldx, ldy = svwh[13], svwh[14]
    px_int = ctx[0]
    py_int = ctx[1]
    dot = ldy * (px_int - lv1[0]) - ldx * (py_int - lv1[1])
    if s[4] == 1:
        dot = -dot
    if dot <= 0:
        return

    map_trace["segs_processed"].add(si)
    map_trace["vertices"].add(v1_idx)
    map_trace["vertices"].add(v2_idx)

    front_idx, back_idx = svwh[1], svwh[2]
    fh, ch = svwh[3], svwh[4]

    # Lazily compute + cache view-space transforms (only for segs that pass back-face)
    fp_module.mul_cat("view")
    vm = map_trace["vertex_muls"]
    for vi in (v1_idx, v2_idx):
        if vi not in vm:
            vm[vi] = [0, 0]
    v_before = fp_module.mul_counts["view"]
    if vcache[v1_idx] is None:
        vcache[v1_idx] = fp_to_view(fp_vertexes[v1_idx][0], fp_vertexes[v1_idx][1], ctx)
        vm[v1_idx][0] += fp_module.mul_counts["view"] - v_before
        v_before = fp_module.mul_counts["view"]
    if vcache[v2_idx] is None:
        vcache[v2_idx] = fp_to_view(fp_vertexes[v2_idx][0], fp_vertexes[v2_idx][1], ctx)
        vm[v2_idx][0] += fp_module.mul_counts["view"] - v_before
    vc1_full = vcache[v1_idx]
    evx1_t, evx1_r, evy1, fvx1, vy_idx1 = vc1_full[:5]
    vc2_full = vcache[v2_idx]
    evx2_t, evx2_r, evy2, fvx2, vy_idx2 = vc2_full[:5]
    # Sub-pixel uses truncated vx (frac compensates); otherwise use rounded
    evx1 = evx1_t
    evx2 = evx2_t

    # Near clip (8-bit view coords, 0.8 parametric t)
    nc = fp_near_clip(evx1, evy1, evx2, evy2)
    if nc is None:
        return
    ex1, ey1, ex2, ey2 = nc

    # Reciprocals and X projection — cached per vertex (non-near-clipped only)
    idx1 = vy_idx1 if ey1 == evy1 else (ey1 << RECIP_FRAC_BITS)
    idx2 = vy_idx2 if ey2 == evy2 else (ey2 << RECIP_FRAC_BITS)
    rxh1, rxl1 = fp_recip(idx1)
    rxh2, rxl2 = fp_recip(idx2)

    fp_module.mul_cat("proj")
    p_before = fp_module.mul_counts["proj"]
    # Cache key 'sx' in vcache: (sx, rxh, rxl) appended on first X projection.
    # Near-clipped endpoints always recompute (different ex/ey).
    vc1 = vcache[v1_idx]
    if ey1 == evy1 and len(vc1) > 5:
        sx1, rxh1, rxl1 = vc1[5], vc1[6], vc1[7]
    else:
        fvx1_c = fvx1 if ey1 == evy1 else 0
        sx1 = fp_project_x_subpx(ex1, fvx1_c, rxh1, rxl1)
        if ey1 == evy1:
            vcache[v1_idx] = vc1 + (sx1, rxh1, rxl1)
    vm[v1_idx][1] += fp_module.mul_counts["proj"] - p_before
    p_before = fp_module.mul_counts["proj"]

    vc2 = vcache[v2_idx]
    if ey2 == evy2 and len(vc2) > 5:
        sx2, rxh2, rxl2 = vc2[5], vc2[6], vc2[7]
    else:
        fvx2_c = fvx2 if ey2 == evy2 else 0
        sx2 = fp_project_x_subpx(ex2, fvx2_c, rxh2, rxl2)
        if ey2 == evy2:
            vcache[v2_idx] = vc2 + (sx2, rxh2, rxl2)
    vm[v2_idx][1] += fp_module.mul_counts["proj"] - p_before

    x_lo = min(sx1, sx2)
    x_hi = max(sx1, sx2)

    fp_module.mul_cat("clip")   # has_gap may call fp_eval → don't pollute "proj"
    if not clips.has_gap(x_lo, x_hi):
        return

    map_trace["segs_drawn"].add(si)

    # Front-sector Y projections via VWH cache (flat array, O(1) lookup).
    # Near-clipped endpoints bypass the cache (different recip).
    fp_module.mul_cat("proj")
    p_before = fp_module.mul_counts["proj"]
    _vft1, _vfb1 = svwh[5], svwh[6]
    ryh1, ryl1 = fp_recip(idx1)
    if ey1 == evy1 and vwh_cache[_vft1] is not None and vwh_cache[_vfb1] is not None:
        ft1 = vwh_cache[_vft1]
        fb1 = vwh_cache[_vfb1]
    else:
        ft1 = fp_project_y(ch - vz, ryh1, ryl1)
        fb1 = fp_project_y(fh - vz, ryh1, ryl1)
        if ey1 == evy1:
            vwh_cache[_vft1] = ft1
            vwh_cache[_vfb1] = fb1
    vm[v1_idx][1] += fp_module.mul_counts["proj"] - p_before
    p_before = fp_module.mul_counts["proj"]
    _vft2, _vfb2 = svwh[7], svwh[8]
    ryh2, ryl2 = fp_recip(idx2)
    if ey2 == evy2 and vwh_cache[_vft2] is not None and vwh_cache[_vfb2] is not None:
        ft2 = vwh_cache[_vft2]
        fb2 = vwh_cache[_vfb2]
    else:
        ft2 = fp_project_y(ch - vz, ryh2, ryl2)
        fb2 = fp_project_y(fh - vz, ryh2, ryl2)
        if ey2 == evy2:
            vwh_cache[_vft2] = ft2
            vwh_cache[_vfb2] = fb2
    vm[v2_idx][1] += fp_module.mul_counts["proj"] - p_before

    solid = back_idx is None
    if back_idx is not None:
        back = fp_sectors[back_idx]
        if back[1] <= fh or back[0] >= ch:
            solid = True
    else:
        back = None

    fp_module.mul_cat("clip")
    if solid:
        clips.draw_clipped([
            (sx1, ft1, sx2, ft2),
            (sx1, fb1, sx2, fb2),
            (sx1, ft1, sx1, fb1),
            (sx2, ft2, sx2, fb2),
        ], GREEN, surface, draw_stats)
        if deferred is not None:
            deferred.append(('solid', x_lo, x_hi))
        else:
            clips.mark_solid(x_lo, x_hi)
    elif back:
        # Only project back heights when needed (saves up to 8 muls)
        need_bt = back[1] < ch   # ceiling drops: need bt for upper step + tighten
        need_bb = back[0] > fh   # floor rises: need bb for lower step + tighten

        if need_bt:
            fp_module.mul_cat("proj")
            _vbt1, _vbt2 = svwh[9], svwh[11]  # back ceil VWH at v1, v2
            if ey1 == evy1 and vwh_cache[_vbt1] is not None:
                bt1 = vwh_cache[_vbt1]
            else:
                bt1 = fp_project_y(back[1] - vz, ryh1, ryl1)
                if ey1 == evy1: vwh_cache[_vbt1] = bt1
            if ey2 == evy2 and vwh_cache[_vbt2] is not None:
                bt2 = vwh_cache[_vbt2]
            else:
                bt2 = fp_project_y(back[1] - vz, ryh2, ryl2)
                if ey2 == evy2: vwh_cache[_vbt2] = bt2
            fp_module.mul_cat("clip")
            lines = [(sx1, bt1, sx2, bt2),
                     (sx1, ft1, sx1, bt1), (sx2, ft2, sx2, bt2)]
            if ch <= vz:  # face below eyeline: top edge (ft) always clipped
                pass
            else:
                lines.insert(0, (sx1, ft1, sx2, ft2))
            clips.draw_clipped(lines, GREEN, surface, draw_stats)
        elif back[1] > ch:
            clips.draw_clipped([(sx1, ft1, sx2, ft2)], GREEN, surface, draw_stats)

        if need_bb:
            fp_module.mul_cat("proj")
            _vbb1, _vbb2 = svwh[10], svwh[12]  # back floor VWH at v1, v2
            if ey1 == evy1 and vwh_cache[_vbb1] is not None:
                bb1 = vwh_cache[_vbb1]
            else:
                bb1 = fp_project_y(back[0] - vz, ryh1, ryl1)
                if ey1 == evy1: vwh_cache[_vbb1] = bb1
            if ey2 == evy2 and vwh_cache[_vbb2] is not None:
                bb2 = vwh_cache[_vbb2]
            else:
                bb2 = fp_project_y(back[0] - vz, ryh2, ryl2)
                if ey2 == evy2: vwh_cache[_vbb2] = bb2
            fp_module.mul_cat("clip")
            lines = [(sx1, bb1, sx2, bb2),
                     (sx1, bb1, sx1, fb1), (sx2, bb2, sx2, fb2)]
            if fh >= vz:  # face above eyeline: bottom edge (fb) always clipped
                pass
            else:
                lines.insert(1, (sx1, fb1, sx2, fb2))
            clips.draw_clipped(lines, GREEN, surface, draw_stats)
        elif back[0] < fh:
            clips.draw_clipped([(sx1, fb1, sx2, fb2)], GREEN, surface, draw_stats)

        # Tighten: use back heights only if computed, otherwise front = tighter
        tt1 = bt1 if need_bt else ft1
        tt2 = bt2 if need_bt else ft2
        tb1 = bb1 if need_bb else fb1
        tb2 = bb2 if need_bb else fb2
        yt1, yt2 = max(ft1, tt1), max(ft2, tt2)
        yb1, yb2 = min(fb1, tb1), min(fb2, tb2)
        # Detect if tighten edges dominate all existing spans (0 muls).
        # If the step edge passed through all spans unclipped, the new
        # boundary dominates and spans can be merged after tighten.
        top_dom = need_bt and clips.line_survives(sx1, bt1, sx2, bt2)
        bot_dom = need_bb and clips.line_survives(sx1, bb1, sx2, bb2)
        if deferred is not None:
            deferred.append(('tighten', x_lo, x_hi, sx1, sx2,
                             yt1, yt2, yb1, yb2, top_dom, bot_dom))
        else:
            clips.tighten(x_lo, x_hi, sx1, sx2, yt1, yt2, yb1, yb2,
                          top_dom, bot_dom)


def render_subsector_fp(idx, clips, ctx, vz, surface, vcache, vwh_cache):
    """Render a subsector with frame-global vertex cache.

    ctx: view context tuple from fp_view_context.
    """
    ssec = fp_ssectors[idx]

    # Both caches are lazily populated by fp_render_seg:
    # vcache (frame-global): view transforms, computed on first access per vertex
    # vwh_cache (frame-global): Y projections indexed by VWH
    deferred = []
    for si in range(ssec[1], ssec[1] + ssec[0]):
        fp_render_seg(si, clips, ctx, vz, surface, vcache, vwh_cache, deferred)
    # Apply clip updates after all draws in this subsector
    for op in deferred:
        if op[0] == 'solid':
            clips.mark_solid(op[1], op[2])
        else:
            clips.tighten(*op[1:])
        if clips.is_full():
            return


def render_bsp_fp(nid, clips, ctx, vz,
                   wx_full, wy_full, cos_f, sin_f, surface, vcache, vwh_cache):
    """BSP traversal for the 8-bit fixed-point path."""
    if clips.is_full():
        return
    if nid & NF_SUBSECTOR:
        ssid = 0 if nid == 0xFFFF else nid & 0x7FFF
        map_trace["subsectors"].add(ssid)
        map_trace["ss_order"].append(ssid)
        render_subsector_fp(ssid, clips, ctx, vz, surface, vcache, vwh_cache)
        return
    map_trace["nodes_visited"].add(nid)
    node = nodes[nid]
    side = point_on_side(wx_full, wy_full, node)
    ch = (node[12], node[13])
    render_bsp_fp(ch[side], clips, ctx, vz,
                  wx_full, wy_full, cos_f, sin_f, surface, vcache, vwh_cache)
    if clips.is_full():
        return
    far = side ^ 1
    br = fp_bbox_visible_fixed(node, far, ctx)
    if br is not None:
        if clips.has_gap(br[0], br[1]):
            render_bsp_fp(ch[far], clips, ctx, vz,
                          wx_full, wy_full, cos_f, sin_f, surface, vcache, vwh_cache)


# ── Packed-ROM rendering (reads from byte arrays, writes cache to RAM) ────────
#
# Same algorithm as the classic FP pipeline above, but geometry comes from
# packed_rom_main / packed_rom_detail byte arrays (via read_u8/read_s16 etc.)
# and cached transforms live in a RAM byte array (via write_s16 / is_valid).
# The EndpointClipSpans back-end and all fp.py math helpers are shared.

from wad_packed import (read_u8, read_s8, read_u16, read_s16, write_u16, write_s16,
                        clear_valid, is_valid, set_valid,
                        VERTEX_SIZE, NODE_SIZE, SSECTOR_SIZE, SEG_HDR_SIZE, SEG_DTL_SIZE,
                        VWH_SIZE, VCACHE_ENTRY,
                        SH_V1, SH_V2, SH_LV1X, SH_LV1Y, SH_LDX, SH_LDY, SH_FLAGS,
                        SD_FH, SD_CH, SD_BFH, SD_BCH,
                        SD_VWH_FT1, SD_VWH_FB1, SD_VWH_FT2, SD_VWH_FB2,
                        SD_VWH_BT1, SD_VWH_BB1, SD_VWH_BT2, SD_VWH_BB2,
                        SF_DIR, SF_SOLID, SF_NEEDBT, SF_NEEDBB,
                        VC_VX, VC_VY, VC_VYIDX, VC_SX, VWHCACHE_ENTRY)

use_packed = False   # toggle: when True (and use_fixedpoint), use packed path

# Alias the already-built packed data
_p_rom_main   = packed_rom_main
_p_rom_detail = packed_rom_detail
_p_rom_recip  = packed_rom_recip
_p_layout     = packed_layout
_p_ram        = None   # allocated per-frame


def _packed_ram_new():
    """Allocate a fresh RAM byte array and clear valid bitmaps."""
    ram = bytearray(_p_layout['ram_size'])
    # valid bitmaps are already 0 in a fresh bytearray
    return ram


def _packed_read_vcache(ram, vi):
    """Read a vertex cache entry from RAM.  Returns (vx, vy, vy_idx, sx) or None."""
    if not is_valid(ram, _p_layout['ram_vcache_valid'], vi):
        return None
    base = _p_layout['ram_vcache'] + vi * VCACHE_ENTRY
    vx  = read_s16(ram, base + VC_VX)
    vy  = read_s16(ram, base + VC_VY)
    vyi = read_u16(ram, base + VC_VYIDX)
    sx  = read_s16(ram, base + VC_SX)
    return (vx, vy, vyi, sx)


def _packed_write_vcache(ram, vi, vx, vy, vy_idx, sx):
    """Write a vertex cache entry to RAM and set its valid bit."""
    base = _p_layout['ram_vcache'] + vi * VCACHE_ENTRY
    write_s16(ram, base + VC_VX, vx)
    write_s16(ram, base + VC_VY, vy)
    write_u16(ram, base + VC_VYIDX, vy_idx)
    write_s16(ram, base + VC_SX, sx)
    set_valid(ram, _p_layout['ram_vcache_valid'], vi)


def _packed_read_vwh(ram, wi):
    """Read a VWH cache entry from RAM.  Returns screen Y (s16) or None."""
    if not is_valid(ram, _p_layout['ram_vwh_valid'], wi):
        return None
    base = _p_layout['ram_vwh_cache'] + wi * VWHCACHE_ENTRY
    return read_s16(ram, base)


def _packed_write_vwh(ram, wi, sy):
    """Write a VWH cache entry to RAM and set its valid bit."""
    base = _p_layout['ram_vwh_cache'] + wi * VWHCACHE_ENTRY
    write_s16(ram, base, sy)
    set_valid(ram, _p_layout['ram_vwh_valid'], wi)


def packed_render_seg(si, clips, ctx, vz, surface, ram, deferred=None):
    """Render seg #si reading geometry from packed ROM, caching in RAM.

    Produces IDENTICAL output to fp_render_seg when data is consistent.
    """
    layout = _p_layout
    rom = _p_rom_main
    rom_d = _p_rom_detail

    # ── Read seg header from rom_main ──
    seg_off = layout['off_seg_hdr'] + si * SEG_HDR_SIZE
    v1_idx = read_u16(rom, seg_off + SH_V1)
    v2_idx = read_u16(rom, seg_off + SH_V2)
    lv1_x  = read_s16(rom, seg_off + SH_LV1X)
    lv1_y  = read_s16(rom, seg_off + SH_LV1Y)
    ldx    = read_s8(rom,  seg_off + SH_LDX)
    ldy    = read_s8(rom,  seg_off + SH_LDY)
    flags  = read_u8(rom,  seg_off + SH_FLAGS)

    # ── Back-face test (same arithmetic as classic path) ──
    px_int = ctx[0]
    py_int = ctx[1]
    dot = ldy * (px_int - lv1_x) - ldx * (py_int - lv1_y)
    if flags & SF_DIR:
        dot = -dot
    if dot <= 0:
        return

    # ── Read vertex positions from rom_main ──
    verts_off = layout['off_verts']
    wx1 = read_s16(rom, verts_off + v1_idx * VERTEX_SIZE)
    wy1 = read_s16(rom, verts_off + v1_idx * VERTEX_SIZE + 2)
    wx2 = read_s16(rom, verts_off + v2_idx * VERTEX_SIZE)
    wy2 = read_s16(rom, verts_off + v2_idx * VERTEX_SIZE + 2)

    # ── View transform with RAM vcache ──
    fp_module.mul_cat("view")
    vc1 = _packed_read_vcache(ram, v1_idx)
    if vc1 is None:
        result = fp_to_view(wx1, wy1, ctx)
        evx1_t, evx1_r, evy1, fvx1, vy_idx1 = result[:5]
        # We need to also compute sx to cache it, but sx depends on
        # whether the vertex is near-clipped.  Cache the view transform
        # first; sx is computed after near-clip and cached separately.
        # For the vcache we store: vx_round, vy, vy_idx, sx=0 (placeholder)
        _packed_write_vcache(ram, v1_idx, evx1_r, evy1, vy_idx1, 0)
        _vc1_has_sx = False
    else:
        evx1_r = vc1[0]
        evx1_t = evx1_r  # packed path doesn't support sub-pixel in vcache
        evy1   = vc1[1]
        vy_idx1 = vc1[2]
        fvx1 = 0
        _vc1_has_sx = (vc1[3] != 0)  # sx was stored

    vc2 = _packed_read_vcache(ram, v2_idx)
    if vc2 is None:
        result = fp_to_view(wx2, wy2, ctx)
        evx2_t, evx2_r, evy2, fvx2, vy_idx2 = result[:5]
        _packed_write_vcache(ram, v2_idx, evx2_r, evy2, vy_idx2, 0)
        _vc2_has_sx = False
    else:
        evx2_r = vc2[0]
        evx2_t = evx2_r
        evy2   = vc2[1]
        vy_idx2 = vc2[2]
        fvx2 = 0
        _vc2_has_sx = (vc2[3] != 0)

    evx1 = evx1_t
    evx2 = evx2_t

    # ── Near clip ──
    nc = fp_near_clip(evx1, evy1, evx2, evy2)
    if nc is None:
        return
    ex1, ey1, ex2, ey2 = nc

    # ── Reciprocals + X projection ──
    idx1 = vy_idx1 if ey1 == evy1 else (ey1 << RECIP_FRAC_BITS)
    idx2 = vy_idx2 if ey2 == evy2 else (ey2 << RECIP_FRAC_BITS)
    rxh1, rxl1 = fp_recip(idx1)
    rxh2, rxl2 = fp_recip(idx2)

    fp_module.mul_cat("proj")

    # sx1
    if ey1 == evy1 and _vc1_has_sx:
        sx1 = _packed_read_vcache(ram, v1_idx)[3]
    else:
        fvx1_c = fvx1 if ey1 == evy1 else 0
        sx1 = fp_project_x_subpx(ex1, fvx1_c, rxh1, rxl1)
        if ey1 == evy1:
            # Update vcache with sx
            base = _p_layout['ram_vcache'] + v1_idx * VCACHE_ENTRY
            write_s16(ram, base + VC_SX, sx1)

    # sx2
    if ey2 == evy2 and _vc2_has_sx:
        sx2 = _packed_read_vcache(ram, v2_idx)[3]
    else:
        fvx2_c = fvx2 if ey2 == evy2 else 0
        sx2 = fp_project_x_subpx(ex2, fvx2_c, rxh2, rxl2)
        if ey2 == evy2:
            base = _p_layout['ram_vcache'] + v2_idx * VCACHE_ENTRY
            write_s16(ram, base + VC_SX, sx2)

    x_lo = min(sx1, sx2)
    x_hi = max(sx1, sx2)

    fp_module.mul_cat("clip")
    if not clips.has_gap(x_lo, x_hi):
        return

    # ── Read seg detail from rom_detail ──
    dtl_off = si * SEG_DTL_SIZE
    fh  = read_s8(rom_d, dtl_off + SD_FH)
    ch  = read_s8(rom_d, dtl_off + SD_CH)

    # ── Front-sector Y projections via VWH cache in RAM ──
    fp_module.mul_cat("proj")
    vwh_ft1 = read_u16(rom_d, dtl_off + SD_VWH_FT1)
    vwh_fb1 = read_u16(rom_d, dtl_off + SD_VWH_FB1)
    ryh1, ryl1 = fp_recip(idx1)

    cached_ft1 = _packed_read_vwh(ram, vwh_ft1) if ey1 == evy1 else None
    cached_fb1 = _packed_read_vwh(ram, vwh_fb1) if ey1 == evy1 else None
    if cached_ft1 is not None and cached_fb1 is not None:
        ft1 = cached_ft1
        fb1 = cached_fb1
    else:
        ft1 = fp_project_y(ch - vz, ryh1, ryl1)
        fb1 = fp_project_y(fh - vz, ryh1, ryl1)
        if ey1 == evy1:
            _packed_write_vwh(ram, vwh_ft1, ft1)
            _packed_write_vwh(ram, vwh_fb1, fb1)

    vwh_ft2 = read_u16(rom_d, dtl_off + SD_VWH_FT2)
    vwh_fb2 = read_u16(rom_d, dtl_off + SD_VWH_FB2)
    ryh2, ryl2 = fp_recip(idx2)

    cached_ft2 = _packed_read_vwh(ram, vwh_ft2) if ey2 == evy2 else None
    cached_fb2 = _packed_read_vwh(ram, vwh_fb2) if ey2 == evy2 else None
    if cached_ft2 is not None and cached_fb2 is not None:
        ft2 = cached_ft2
        fb2 = cached_fb2
    else:
        ft2 = fp_project_y(ch - vz, ryh2, ryl2)
        fb2 = fp_project_y(fh - vz, ryh2, ryl2)
        if ey2 == evy2:
            _packed_write_vwh(ram, vwh_ft2, ft2)
            _packed_write_vwh(ram, vwh_fb2, fb2)

    # ── Determine solid / two-sided ──
    solid = bool(flags & SF_SOLID)

    fp_module.mul_cat("clip")
    if solid:
        clips.draw_clipped([
            (sx1, ft1, sx2, ft2),
            (sx1, fb1, sx2, fb2),
            (sx1, ft1, sx1, fb1),
            (sx2, ft2, sx2, fb2),
        ], GREEN, surface, draw_stats)
        if deferred is not None:
            deferred.append(('solid', x_lo, x_hi))
        else:
            clips.mark_solid(x_lo, x_hi)
    else:
        # Two-sided: read back heights from seg detail
        need_bt = bool(flags & SF_NEEDBT)
        need_bb = bool(flags & SF_NEEDBB)
        bfh = read_s8(rom_d, dtl_off + SD_BFH)
        bch = read_s8(rom_d, dtl_off + SD_BCH)

        if need_bt:
            fp_module.mul_cat("proj")
            vwh_bt1 = read_u16(rom_d, dtl_off + SD_VWH_BT1)
            vwh_bt2 = read_u16(rom_d, dtl_off + SD_VWH_BT2)
            cached_bt1 = _packed_read_vwh(ram, vwh_bt1) if ey1 == evy1 else None
            if cached_bt1 is not None:
                bt1 = cached_bt1
            else:
                bt1 = fp_project_y(bch - vz, ryh1, ryl1)
                if ey1 == evy1: _packed_write_vwh(ram, vwh_bt1, bt1)
            cached_bt2 = _packed_read_vwh(ram, vwh_bt2) if ey2 == evy2 else None
            if cached_bt2 is not None:
                bt2 = cached_bt2
            else:
                bt2 = fp_project_y(bch - vz, ryh2, ryl2)
                if ey2 == evy2: _packed_write_vwh(ram, vwh_bt2, bt2)
            fp_module.mul_cat("clip")
            lines = [(sx1, bt1, sx2, bt2),
                     (sx1, ft1, sx1, bt1), (sx2, ft2, sx2, bt2)]
            if ch <= vz:
                pass
            else:
                lines.insert(0, (sx1, ft1, sx2, ft2))
            clips.draw_clipped(lines, GREEN, surface, draw_stats)
        elif bch > ch:
            clips.draw_clipped([(sx1, ft1, sx2, ft2)], GREEN, surface, draw_stats)

        if need_bb:
            fp_module.mul_cat("proj")
            vwh_bb1 = read_u16(rom_d, dtl_off + SD_VWH_BB1)
            vwh_bb2 = read_u16(rom_d, dtl_off + SD_VWH_BB2)
            cached_bb1 = _packed_read_vwh(ram, vwh_bb1) if ey1 == evy1 else None
            if cached_bb1 is not None:
                bb1 = cached_bb1
            else:
                bb1 = fp_project_y(bfh - vz, ryh1, ryl1)
                if ey1 == evy1: _packed_write_vwh(ram, vwh_bb1, bb1)
            cached_bb2 = _packed_read_vwh(ram, vwh_bb2) if ey2 == evy2 else None
            if cached_bb2 is not None:
                bb2 = cached_bb2
            else:
                bb2 = fp_project_y(bfh - vz, ryh2, ryl2)
                if ey2 == evy2: _packed_write_vwh(ram, vwh_bb2, bb2)
            fp_module.mul_cat("clip")
            lines = [(sx1, bb1, sx2, bb2),
                     (sx1, bb1, sx1, fb1), (sx2, bb2, sx2, fb2)]
            if fh >= vz:
                pass
            else:
                lines.insert(1, (sx1, fb1, sx2, fb2))
            clips.draw_clipped(lines, GREEN, surface, draw_stats)
        elif bfh < fh:
            clips.draw_clipped([(sx1, fb1, sx2, fb2)], GREEN, surface, draw_stats)

        # Tighten
        tt1 = bt1 if need_bt else ft1
        tt2 = bt2 if need_bt else ft2
        tb1 = bb1 if need_bb else fb1
        tb2 = bb2 if need_bb else fb2
        yt1, yt2 = max(ft1, tt1), max(ft2, tt2)
        yb1, yb2 = min(fb1, tb1), min(fb2, tb2)
        top_dom = need_bt and clips.line_survives(sx1, bt1, sx2, bt2)
        bot_dom = need_bb and clips.line_survives(sx1, bb1, sx2, bb2)
        if deferred is not None:
            deferred.append(('tighten', x_lo, x_hi, sx1, sx2,
                             yt1, yt2, yb1, yb2, top_dom, bot_dom))
        else:
            clips.tighten(x_lo, x_hi, sx1, sx2, yt1, yt2, yb1, yb2,
                          top_dom, bot_dom)


def packed_render_subsector(idx, clips, ctx, vz, surface, ram):
    """Render a subsector reading from packed ROM arrays."""
    layout = _p_layout
    rom = _p_rom_main
    ss_off = layout['off_ss'] + idx * SSECTOR_SIZE
    count     = read_u8(rom, ss_off)
    first_seg = read_u16(rom, ss_off + 2)

    deferred = []
    for si in range(first_seg, first_seg + count):
        packed_render_seg(si, clips, ctx, vz, surface, ram, deferred)
    for op in deferred:
        if op[0] == 'solid':
            clips.mark_solid(op[1], op[2])
        else:
            clips.tighten(*op[1:])
        if clips.is_full():
            return


def packed_render_bsp(nid, clips, ctx, vz,
                      wx_full, wy_full, cos_f, sin_f, surface, ram):
    """BSP traversal reading nodes from packed ROM.

    Node children are read from rom_main.  point_on_side and bbox visibility
    use the original un-prescaled Python node data (same as render_bsp_fp)
    to avoid rounding differences from prescaled partition lines.
    """
    if clips.is_full():
        return
    if nid & NF_SUBSECTOR:
        ssid = 0 if nid == 0xFFFF else nid & 0x7FFF
        packed_render_subsector(ssid, clips, ctx, vz, surface, ram)
        return

    # Read children from packed ROM
    layout = _p_layout
    rom = _p_rom_main
    node_off = layout['off_nodes'] + nid * NODE_SIZE
    child_r = read_u16(rom, node_off + 8)
    child_l = read_u16(rom, node_off + 10)

    # point_on_side uses un-prescaled node data (matches render_bsp_fp exactly)
    node = nodes[nid]
    side = point_on_side(wx_full, wy_full, node)

    ch = (child_r, child_l)
    packed_render_bsp(ch[side], clips, ctx, vz,
                      wx_full, wy_full, cos_f, sin_f, surface, ram)
    if clips.is_full():
        return
    far = side ^ 1
    # Bbox visibility uses the fixed-point path so Python, packed-Python,
    # and the 6502 native bbox_cull all agree bit-exact.
    br = fp_bbox_visible_fixed(node, far, ctx)
    if br is not None:
        if clips.has_gap(br[0], br[1]):
            packed_render_bsp(ch[far], clips, ctx, vz,
                              wx_full, wy_full, cos_f, sin_f, surface, ram)


# ── Verification: compare classic FP vs packed paths ─────────────────────────

def verify_packed(positions=None):
    """Run both FP paths at multiple positions and compare draw calls.

    Returns (n_tested, n_passed, failures) where failures is a list of
    (pos, angle, mismatch_details) for any position that produced
    different output.
    """
    if positions is None:
        # Default: 25 positions around the E1M1 start area
        positions = []
        base_x, base_y = player_x, player_y
        for dx in (-80, -40, 0, 40, 80):
            for dy in (-80, -40, 0, 40, 80):
                positions.append((base_x + dx, base_y + dy))

    angles = list(range(0, 256, 10))  # 26 angles covering full circle

    n_tested = 0
    n_passed = 0
    failures = []

    # Intercept pygame.draw.line to capture coordinates
    _classic_draws = []
    _packed_draws = []
    _current_list = [None]

    def _intercept(surface, color, p1, p2, w=1):
        if _current_list[0] is not None:
            _current_list[0].append(((int(p1[0]), int(p1[1])),
                                      (int(p2[0]), int(p2[1]))))
        return _real_drawline(surface, color, p1, p2, w)

    orig_drawline = pygame.draw.line
    tmp = pygame.Surface((FP_WIDTH, FP_HEIGHT))

    for px, py in positions:
        for ab in angles:
            n_tested += 1

            ang_rad = ab * 2 * math.pi / 256
            cos_f = math.cos(ang_rad)
            sin_f = math.sin(ang_rad)
            px_88 = int((px - MAP_CENTER_X) * 256 / PRESCALE)
            py_88 = int((py - MAP_CENTER_Y) * 256 / PRESCALE)
            vz_ps = _prescale_height(player_floor(px, py) + 41)
            sc = fp_sincos(ab)

            # ── Classic FP run ──
            _classic_draws.clear()
            _current_list[0] = _classic_draws
            pygame.draw.line = _intercept
            fp_module.mul_reset()
            ctx_c = fp_view_context(px_88, py_88, sc)
            random.seed(42)
            for i in range(5): draw_stats[i] = 0
            for k in map_trace:
                map_trace[k] = {} if k == "vertex_muls" else ([] if k == "ss_order" else set())
            tmp.fill((0, 0, 0))
            render_bsp_fp(len(nodes)-1, EndpointClipSpans(), ctx_c, vz_ps,
                          int(px), int(py), cos_f, sin_f, tmp,
                          [None]*len(vertexes), [None]*len(vwh_table))
            classic_result = list(_classic_draws)

            # ── Packed run ──
            _packed_draws.clear()
            _current_list[0] = _packed_draws
            fp_module.mul_reset()
            ctx_p = fp_view_context(px_88, py_88, sc)
            random.seed(42)
            for i in range(5): draw_stats[i] = 0
            for k in map_trace:
                map_trace[k] = {} if k == "vertex_muls" else ([] if k == "ss_order" else set())
            tmp.fill((0, 0, 0))
            from wad_packed import spans_init_full
            p_ram = _packed_ram_new()
            spans_base = packed_layout['ram_spans']
            spans_init_full(p_ram, spans_base, FP_RENDER_W, FP_RENDER_H - 1)
            packed_render_bsp(len(nodes)-1,
                              EndpointClipSpans(),
                              ctx_p, vz_ps,
                              int(px), int(py), cos_f, sin_f, tmp, p_ram)
            packed_result = list(_packed_draws)

            _current_list[0] = None
            pygame.draw.line = orig_drawline

            if classic_result == packed_result:
                n_passed += 1
            else:
                detail = {
                    'classic_count': len(classic_result),
                    'packed_count': len(packed_result),
                    'first_diff': None,
                }
                for i in range(max(len(classic_result), len(packed_result))):
                    c = classic_result[i] if i < len(classic_result) else None
                    p = packed_result[i] if i < len(packed_result) else None
                    if c != p:
                        detail['first_diff'] = (i, c, p)
                        break
                failures.append(((px, py), ab, detail))

    pygame.draw.line = _real_drawline
    return n_tested, n_passed, failures


# ── Top-down map visualisation ────────────────────────────────────────────────

def _fit_scale():
    """Compute scale to fit the whole map on screen."""
    xs = [v[0] for v in vertexes]
    ys = [v[1] for v in vertexes]
    margin = 40
    dw = (max(xs) - min(xs)) or 1
    dh = (max(ys) - min(ys)) or 1
    return min((SCREEN_W - 2 * margin) / dw, (SCREEN_H - 2 * margin) / dh)

_map_scale = _fit_scale()
_map_cx = 0.0    # world center X (updated per frame when map shown)
_map_cy = 0.0    # world center Y

def _m2s(wx, wy):
    """World coords -> screen pixel (DOOM Y is flipped)."""
    sx = SCREEN_W / 2 + (wx - _map_cx) * _map_scale
    sy = SCREEN_H / 2 - (wy - _map_cy) * _map_scale
    return int(sx), int(sy)

def _ssector_convex_hull(idx):
    """Return screen-space convex hull of a subsector's vertices."""
    ssec = ssectors[idx]
    seen = set()
    pts = []
    for si in range(ssec[1], ssec[1] + ssec[0]):
        s = segs[si]
        for vi in (s[0], s[1]):
            if vi not in seen:
                seen.add(vi)
                pts.append(vertexes[vi])
    if len(pts) < 3:
        return []
    # Sort by angle around centroid (subsectors are convex)
    cx = sum(p[0] for p in pts) / len(pts)
    cy = sum(p[1] for p in pts) / len(pts)
    pts.sort(key=lambda p: math.atan2(p[1] - cy, p[0] - cx))
    return [_m2s(p[0], p[1]) for p in pts]

# Precompute exact subsector polygons by clipping against BSP partition lines.
# Start with the map bounding box, then clip at each node on the root-to-leaf path.

def _clip_polygon_by_line(poly, lx, ly, ldx, ldy, keep_side):
    """Sutherland-Hodgman clip: keep vertices on keep_side of the partition line."""
    if not poly:
        return []
    def side(px, py):
        # Must match point_on_side: node[3]*dx - node[2]*dy > 0 → side 0
        cross = ldy * (px - lx) - ldx * (py - ly)
        return 0 if cross > 0 else 1
    out = []
    n = len(poly)
    for i in range(n):
        cx, cy = poly[i]
        nx, ny = poly[(i + 1) % n]
        c_side = side(cx, cy)
        n_side = side(nx, ny)
        if c_side == keep_side:
            out.append((cx, cy))
        if c_side != n_side:
            # Edge crosses the line — find intersection
            dx, dy = nx - cx, ny - cy
            denom = ldy * dx - ldx * dy
            if abs(denom) > 1e-10:
                t = (ldx * (cy - ly) - ldy * (cx - lx)) / denom
                out.append((cx + t * dx, cy + t * dy))
    return out

def _clip_polygon_to_bbox(poly, left, right, bot, top):
    """Clip polygon to axis-aligned bounding box."""
    # Clip by 4 half-planes: x >= left, x <= right, y >= bot, y <= top
    # Express each as a partition line (lx, ly, ldx, ldy) with appropriate side
    poly = _clip_polygon_by_line(poly, left, 0, 0, 1, 0)   # x >= left (keep side 0)
    poly = _clip_polygon_by_line(poly, right, 0, 0, -1, 0)  # x <= right
    poly = _clip_polygon_by_line(poly, 0, bot, -1, 0, 0)    # y >= bot
    poly = _clip_polygon_by_line(poly, 0, top, 1, 0, 0)     # y <= top
    return poly

_ss_polys = {}
def _build_ss_polys(nid, poly):
    if nid & NF_SUBSECTOR:
        ssid = 0 if nid == 0xFFFF else nid & 0x7FFF
        _ss_polys[ssid] = poly
        return
    node = nodes[nid]
    lx, ly, ldx, ldy = node[0], node[1], node[2], node[3]
    for side in (0, 1):
        clipped = _clip_polygon_by_line(poly, lx, ly, ldx, ldy, side)
        _build_ss_polys(node[12 + side], clipped)

# Start with a large bounding box around the entire map
_all_x = [v[0] for v in vertexes]
_all_y = [v[1] for v in vertexes]
_margin = 200
_map_poly = [
    (min(_all_x) - _margin, min(_all_y) - _margin),
    (max(_all_x) + _margin, min(_all_y) - _margin),
    (max(_all_x) + _margin, max(_all_y) + _margin),
    (min(_all_x) - _margin, max(_all_y) + _margin),
]
_build_ss_polys(len(nodes) - 1, _map_poly)

# Trim to map bbox, then verify each polygon contains its subsector's geometry.
# Degenerate subsectors on BSP partition lines get the wrong polygon — replace
# with convex hull of seg vertices.
def _point_in_poly(px, py, poly):
    inside = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]; xj, yj = poly[j]
        if ((yi > py) != (yj > py)) and (px < (xj-xi)*(py-yi)/(yj-yi)+xi):
            inside = not inside
        j = i
    return inside

for _ssid in list(_ss_polys):
    _ss_polys[_ssid] = _clip_polygon_to_bbox(
        _ss_polys[_ssid],
        min(_all_x) - 16, max(_all_x) + 16,
        min(_all_y) - 16, max(_all_y) + 16)
    # Verify: does the polygon contain the subsector's first vertex?
    _ssec = ssectors[_ssid]
    if _ssec[0] > 0 and len(_ss_polys[_ssid]) >= 3:
        _sv = vertexes[segs[_ssec[1]][0]]
        if not _point_in_poly(_sv[0], _sv[1], _ss_polys[_ssid]):
            _ss_polys[_ssid] = None  # mark for convex hull fallback

def _ss_screen_poly(ssid):
    """Get screen-space polygon for a subsector."""
    poly = _ss_polys.get(ssid)
    if poly and len(poly) >= 3:
        return [_m2s(p[0], p[1]) for p in poly]
    # Fallback: convex hull of seg vertices (already screen coords)
    return _ssector_convex_hull(ssid)

def draw_map(surface, px, py, ang):
    """Draw top-down map with BSP traversal highlighting."""
    global _map_cx, _map_cy
    _map_cx = px
    _map_cy = py
    surface.fill((0, 0, 0))

    # 1. Draw all linedefs as dark grey base map
    for ld in linedefs:
        v1, v2 = vertexes[ld[0]], vertexes[ld[1]]
        p1 = _m2s(v1[0], v1[1])
        p2 = _m2s(v2[0], v2[1])
        two_sided = ld[6] != 0xFFFF
        color = (40, 40, 40) if two_sided else (60, 60, 60)
        _real_drawline(surface, color, p1, p2, 1)

    # 2. Draw traversed subsectors — filled polygons + numbered centroid dots.
    ss_color = (40, 25, 60)
    ss_order = map_trace.get("ss_order", [])
    for ssid in map_trace["subsectors"]:
        screen_pts = _ss_screen_poly(ssid)
        if len(screen_pts) >= 3:
            pygame.draw.polygon(surface, ss_color, screen_pts)
    # Also draw numbered centroid dots to verify polygon placement
    for idx, ssid in enumerate(ss_order):
        ssec = ssectors[ssid]
        xs, ys = [], []
        for si in range(ssec[1], ssec[1] + ssec[0]):
            s = segs[si]
            xs.extend([vertexes[s[0]][0], vertexes[s[1]][0]])
            ys.extend([vertexes[s[0]][1], vertexes[s[1]][1]])
        if xs:
            cx, cy = sum(xs) // len(xs), sum(ys) // len(ys)
            sp = _m2s(cx, cy)
            pygame.draw.circle(surface, (255, 100, 100), sp, 4)
            lbl = hud_font.render(f"{idx}", True, (255, 200, 200))
            surface.blit(lbl, (sp[0] + 5, sp[1] - 5))

    # 3. Draw processed segs (passed back-face test) in dim yellow
    use_fp = use_fixedpoint
    seg_list = fp_segs if use_fp else segs
    for si in map_trace["segs_processed"]:
        s = seg_list[si]
        v1 = vertexes[s[0]]
        v2 = vertexes[s[1]]
        p1 = _m2s(v1[0], v1[1])
        p2 = _m2s(v2[0], v2[1])
        _real_drawline(surface, (100, 100, 0), p1, p2, 1)

    # 4. Draw drawn segs (produced visible lines) in bright green
    for si in map_trace["segs_drawn"]:
        s = seg_list[si]
        v1 = vertexes[s[0]]
        v2 = vertexes[s[1]]
        p1 = _m2s(v1[0], v1[1])
        p2 = _m2s(v2[0], v2[1])
        _real_drawline(surface, (0, 255, 0), p1, p2, 2)

    # 5. Draw processed vertices (dots only — labels drawn last)
    vm = map_trace.get("vertex_muls", {})
    for vi in map_trace["vertices"]:
        vx, vy = vertexes[vi]
        sp = _m2s(vx, vy)
        pygame.draw.circle(surface, (0, 150, 255), sp, 2)

    # 6. Player position + FOV cone
    pp = _m2s(px, py)
    pygame.draw.circle(surface, (255, 255, 255), pp, 5)
    fov_len = 80
    for da in (-HFOV / 2, 0, HFOV / 2):
        a = ang + da
        ex = pp[0] + int(fov_len * math.cos(a))
        ey = pp[1] - int(fov_len * math.sin(a))
        _real_drawline(surface, (255, 255, 255) if da == 0 else (128, 128, 128),
                       pp, (ex, ey), 1)

    # 7. Vertex mul count labels (drawn last, on top of everything)
    for vi in map_trace["vertices"]:
        if vi in vm:
            v_m, p_m = vm[vi]
            if v_m + p_m > 0:
                vx, vy = vertexes[vi]
                sp = _m2s(vx, vy)
                lbl = hud_font.render(f"v{vi} {v_m}+{p_m}", True, (255, 255, 100))
                bg = pygame.Surface(lbl.get_size(), pygame.SRCALPHA)
                bg.fill((0, 0, 0, 192))
                surface.blit(bg, (sp[0] + 4, sp[1] - 6))
                surface.blit(lbl, (sp[0] + 4, sp[1] - 6))

    # 8. Legend (bottom right)
    ly = SCREEN_H - 5 * 16 - 4
    lx = SCREEN_W - 180
    for label, color in [("Traversed subsector", (25, 25, 40)),
                         ("Processed seg", (100, 100, 0)),
                         ("Drawn seg", (0, 255, 0)),
                         ("Projected vertex", (0, 150, 255)),
                         ("Player + FOV", (255, 255, 255))]:
        pygame.draw.rect(surface, color, (lx, ly, 12, 12))
        surface.blit(hud_font.render(label, True, (200, 200, 200)), (lx + 16, ly))
        ly += 16

    # Stats
    vm = map_trace.get("vertex_muls", {})
    sum_v = sum(m[0] for m in vm.values())
    sum_p = sum(m[1] for m in vm.values())
    if use_fixedpoint:
        mc = fp_module.mul_counts
        v_ok = "=" if sum_v == mc["view"] else "!"
        p_ok = "=" if sum_p == mc["proj"] else "!"
        check_str = f"  V:{sum_v}{v_ok}{mc['view']} P:{sum_p}{p_ok}{mc['proj']}"
    else:
        check_str = ""
    stats_str = (f"Subsectors: {len(map_trace['subsectors'])}/{len(ssectors)}  "
                 f"Segs: {len(map_trace['segs_drawn'])}/{len(map_trace['segs_processed'])} drawn/proc  "
                 f"Vertices: {len(map_trace['vertices'])}/{len(vertexes)}  "
                 f"Nodes: {len(map_trace['nodes_visited'])}/{len(nodes)}{check_str}")
    surface.blit(hud_font.render(stats_str, True, (255, 255, 0)),
                 (4, SCREEN_H - 20))


# ── Angle conversion helpers ─────────────────────────────────────────────────

def radians_to_byte(rad):
    """Convert radians to 0..255 (8-bit angle)."""
    deg = math.degrees(rad) % 360.0
    return int(deg * 256.0 / 360.0 + 0.5) & 0xFF

def byte_to_radians(b):
    """Convert 0..255 (8-bit angle) to radians."""
    return math.radians((b & 0xFF) * 360.0 / 256.0)


# ── Draw-call comparison (press D) ────────────────────────────────────────────

def _compare_draw_calls():
    """Run both float and FP renderers, compare draw call counts per seg."""
    _log = []
    _current = [None]
    def _interceptor(surface, color, p1, p2, w=1):
        if _current[0] is not None:
            _log.append((_current[0], (p1, p2)))
        return _real_drawline(surface, color, p1, p2, w)

    ang_rad = byte_to_radians(angle_byte)
    cos_a, sin_a = math.cos(ang_rad), math.sin(ang_rad)
    vz = player_floor(player_x, player_y) + 41.0

    # Float run
    _log.clear()
    tmp = pygame.Surface((SCREEN_W, SCREEN_H))
    pygame.draw.line = _interceptor

    _orig = render_seg.__code__
    # Wrap render_seg to tag draws
    orig_render_seg_fn = globals()['render_seg']
    def _float_seg(si, clips, ca, sa, vx, vy, vz, surface, deferred=None):
        _current[0] = ('F', si)
        orig_render_seg_fn(si, clips, ca, sa, vx, vy, vz, surface, deferred)
        _current[0] = None
    globals()['render_seg'] = _float_seg
    render_bsp(len(nodes)-1, ClipSpans(), cos_a, sin_a,
               player_x, player_y, vz, tmp)
    globals()['render_seg'] = orig_render_seg_fn
    float_log = list(_log)

    # FP run
    _log.clear()
    tmp_fp = pygame.Surface((FP_WIDTH, FP_HEIGHT))
    fp_module.mul_reset()
    px_88 = int((player_x - MAP_CENTER_X) * 256 / PRESCALE)
    py_88 = int((player_y - MAP_CENTER_Y) * 256 / PRESCALE)
    vz_ps = _prescale_height(player_floor(player_x, player_y) + 41)
    sc = fp_sincos(angle_byte)
    ctx = fp_view_context(px_88, py_88, sc)
    cos_f, sin_f = cos_a, sin_a

    orig_fp_seg_fn = globals()['fp_render_seg']
    def _fp_seg(si, clips, ctx, vz, surface, vcache, vwh_cache, deferred=None):
        _current[0] = ('P', si)
        orig_fp_seg_fn(si, clips, ctx, vz, surface, vcache, vwh_cache, deferred)
        _current[0] = None
    globals()['fp_render_seg'] = _fp_seg
    render_bsp_fp(len(nodes)-1, EndpointClipSpans(), ctx, vz_ps,
                  int(player_x), int(player_y), cos_f, sin_f, tmp_fp,
                      [None]*len(vertexes), [None]*len(vwh_table))
    globals()['fp_render_seg'] = orig_fp_seg_fn
    pygame.draw.line = _real_drawline

    # Compare
    float_counts = {}
    for (mode, si), _ in float_log:
        float_counts[si] = float_counts.get(si, 0) + 1
    fp_counts = {}
    for (mode, si), _ in float_log:
        pass  # wrong list
    fp_counts = {}
    for (mode, si), _ in [x for x in _log]:  # _log was overwritten
        pass

    # Redo: collect from the stored logs
    fc = {}
    for tag, draw in float_log:
        fc[tag[1]] = fc.get(tag[1], 0) + 1
    # Need to collect fp_log separately
    # Actually _log was cleared and reused. Let me fix:
    pass

    # Simpler approach: just count from the two runs
    # Re-do with proper separation
    print(f"\n=== Draw-call comparison at ({player_x:.0f},{player_y:.0f}) a={angle_byte} ===")
    print(f"Float: {len(float_log)} draw calls")

    # Re-run FP with fresh log
    _log.clear()
    pygame.draw.line = _interceptor
    fp_module.mul_reset()
    ctx2 = fp_view_context(px_88, py_88, sc)
    globals()['fp_render_seg'] = _fp_seg
    for k in map_trace:
        map_trace[k] = {} if k == "vertex_muls" else ([] if k == "ss_order" else set())
    render_bsp_fp(len(nodes)-1, EndpointClipSpans(), ctx2, vz_ps,
                  int(player_x), int(player_y), cos_f, sin_f, tmp_fp,
                      [None]*len(vertexes), [None]*len(vwh_table))
    globals()['fp_render_seg'] = orig_fp_seg_fn
    pygame.draw.line = _real_drawline
    fp_log = list(_log)
    print(f"FP:    {len(fp_log)} draw calls")

    # Per-seg comparison
    fc = {}
    for tag, draw in float_log:
        si = tag[1]
        fc.setdefault(si, []).append(draw)
    pc = {}
    for tag, draw in fp_log:
        si = tag[1]
        pc.setdefault(si, []).append(draw)

    diffs = 0
    for si in sorted(set(list(fc.keys()) + list(pc.keys()))):
        fn = len(fc.get(si, []))
        pn = len(pc.get(si, []))
        if fn != pn:
            diffs += 1
            # Identify the seg
            if si < len(segs):
                s = segs[si]
                print(f"  seg {si} v{s[0]}-v{s[1]}: float={fn} fp={pn}")
                for d in pc.get(si, []):
                    print(f"    FP: {d}")
                for d in fc.get(si, []):
                    print(f"    FL: ({d[0][0]:.0f},{d[0][1]:.0f})->({d[1][0]:.0f},{d[1][1]:.0f})")
    if diffs == 0:
        print("  No differences found!")
    print(f"Total differing segs: {diffs}")
    print("=== end ===\n", flush=True)


# ── Main loop ────────────────────────────────────────────────────────────────

# [total, unclipped, clipped, trivial_reject, clip_reject]
draw_stats = [0, 0, 0, 0, 0]
_frame_6502_cycles = [0]  # mutable for closure access

sys.setrecursionlimit(10000)
pygame.init()
if __name__ == '__main__':
    # Register under the canonical module name so that deferred imports like
    # `from doom_wireframe import ...` in background threads find this module
    # instance instead of re-importing the file (which would call
    # pygame.display.set_mode from a non-main thread and crash on macOS).
    sys.modules['doom_wireframe'] = sys.modules['__main__']
    screen = pygame.display.set_mode((SCREEN_W, SCREEN_H))
    pygame.display.set_caption("DOOM E1M1 — Wireframe BSP")
else:
    screen = pygame.display.set_mode((1, 1))
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
show_map = False                          # Top-down map visualisation
_show_nj_raster = False                   # Show NJ 6502 rasteriser output (FP lines)
_use_6502_frontend = False                # H key: 6502 front-end + Python clip/draw
_use_6502_full = False                    # J key: 6502 front-end + clip + NJ rasteriser

def clip_and_draw_6502(commands, surface, vz_ps):
    """Process 6502 engine seg commands through EndpointClipSpans with full clipping.

    Commands are in BSP front-to-back order. Within each subsector, clip
    updates are deferred until the 'E' (end subsector) marker.
    """
    fp_module.mul_reset()
    clips = EndpointClipSpans()
    deferred = []
    drawn = 0
    for cmd in commands:
        if cmd[0] == 'E':
            for op in deferred:
                if op[0] == 'solid':
                    clips.mark_solid(op[1], op[2])
                else:
                    clips.tighten(*op[1:])
                if clips.is_full():
                    return drawn
            deferred.clear()
            continue

        _, sx1, sx2, ft1, fb1, ft2, fb2 = cmd[:7]
        x_lo, x_hi = min(sx1, sx2), max(sx1, sx2)

        if not clips.has_gap(x_lo, x_hi):
            continue

        if cmd[0] == 'S':
            clips.draw_clipped([
                (sx1, ft1, sx2, ft2),
                (sx1, fb1, sx2, fb2),
                (sx1, ft1, sx1, fb1),
                (sx2, ft2, sx2, fb2),
            ], GREEN, surface, draw_stats)
            deferred.append(('solid', x_lo, x_hi))
            drawn += 4

        elif cmd[0] == 'P':
            need_bt, need_bb = cmd[7], cmd[8]
            bt1, bt2, bb1, bb2 = cmd[9], cmd[10], cmd[11], cmd[12]
            bch, bfh, ch, fh = cmd[13], cmd[14], cmd[15], cmd[16]

            if need_bt:
                lines = [(sx1, bt1, sx2, bt2),
                         (sx1, ft1, sx1, bt1), (sx2, ft2, sx2, bt2)]
                if ch > vz_ps:
                    lines.insert(0, (sx1, ft1, sx2, ft2))
                clips.draw_clipped(lines, GREEN, surface, draw_stats)
                drawn += len(lines)
            elif bch > ch:
                clips.draw_clipped([(sx1, ft1, sx2, ft2)], GREEN, surface, draw_stats)
                drawn += 1

            if need_bb:
                lines = [(sx1, bb1, sx2, bb2),
                         (sx1, bb1, sx1, fb1), (sx2, bb2, sx2, fb2)]
                if fh < vz_ps:
                    lines.insert(1, (sx1, fb1, sx2, fb2))
                clips.draw_clipped(lines, GREEN, surface, draw_stats)
                drawn += len(lines)
            elif bfh < fh:
                clips.draw_clipped([(sx1, fb1, sx2, fb2)], GREEN, surface, draw_stats)
                drawn += 1

            # Tighten: compute boundaries
            tt1 = bt1 if need_bt else ft1
            tt2 = bt2 if need_bt else ft2
            tb1 = bb1 if need_bb else fb1
            tb2 = bb2 if need_bb else fb2
            yt1, yt2 = max(ft1, tt1), max(ft2, tt2)
            yb1, yb2 = min(fb1, tb1), min(fb2, tb2)
            top_dom = need_bt and clips.line_survives(sx1, bt1, sx2, bt2)
            bot_dom = need_bb and clips.line_survives(sx1, bb1, sx2, bb2)
            deferred.append(('tighten', x_lo, x_hi, sx1, sx2,
                             yt1, yt2, yb1, yb2, top_dom, bot_dom))

    return drawn


def clip_and_draw_6502_lines(commands, vz_ps):
    """Like clip_and_draw_6502 but returns a list of (x1,y1,x2,y2) line coords
    instead of drawing to a surface.  Used by render_frame_full to feed the
    NJ rasteriser."""
    captured = []
    def _capture(surface, color, p1, p2, w=1):
        captured.append((int(p1[0]), int(p1[1]), int(p2[0]), int(p2[1])))
    # Temporarily redirect draw.line to our capture function
    saved = pygame.draw.line
    pygame.draw.line = _capture
    dummy = pygame.Surface((FP_RENDER_W, FP_RENDER_H))
    clip_and_draw_6502(commands, dummy, vz_ps)
    pygame.draw.line = saved
    return captured


turn_speed = 2.5                          # radians/sec for float mode
turn_speed_byte = 45                      # byte-units/sec for FP mode (~63 deg/sec)
move_speed = 300.0

# ── Debug line stepper (press G to enter, +/- to step, G to exit) ────────────

_debug_mode = False
_debug_steps = []     # list of (input_line, spans_snapshot, clipped_segments)
_debug_idx = 0

def _record_frame_steps():
    """Re-render the current frame in FP mode, recording every draw operation."""
    global _debug_steps
    _debug_steps = []

    ang_rad = byte_to_radians(angle_byte)
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
    fp_module.mul_reset()
    px_88 = int((player_x - MAP_CENTER_X) * 256 / PRESCALE)
    py_88 = int((player_y - MAP_CENTER_Y) * 256 / PRESCALE)
    vz_ps = _prescale_height(player_floor(player_x, player_y) + 41)
    sc = fp_sincos(angle_byte)
    ctx = fp_view_context(px_88, py_88, sc)

    # Create a recording clip spans wrapper that captures actual draw calls
    _rec_current_line = [None]
    _rec_draws = []

    import copy

    class RecordingClipSpans(EndpointClipSpans):
        def draw_clipped(self, lines, color, surface, stats=None):
            import endpoint_spans as _es
            for lx1, ly1, lx2, ly2 in lines:
                groups_snap = copy.deepcopy(self.spans)
                _rec_current_line[0] = (lx1, ly1, lx2, ly2)
                _rec_draws.clear()
                mul_before = sum(fp_module.mul_counts.values())
                _es._line_cost = {}  # enable cost tracking
                super().draw_clipped([(lx1, ly1, lx2, ly2)], color, surface, stats)
                cost_snap = dict(_es._line_cost) if _es._line_cost else {}
                _es._line_cost = None  # disable
                mul_after = sum(fp_module.mul_counts.values())
                _debug_steps.append(((lx1, ly1, lx2, ly2), groups_snap,
                                     list(_rec_draws), mul_after - mul_before,
                                     cost_snap))
                _rec_current_line[0] = None

    _orig_drawline = pygame.draw.line
    def _rec_interceptor(surface, color, p1, p2, w=1):
        if _rec_current_line[0] is not None:
            _rec_draws.append((p1[0], p1[1], p2[0], p2[1]))
        return _orig_drawline(surface, color, p1, p2, w)
    pygame.draw.line = _rec_interceptor

    tmp = pygame.Surface((FP_WIDTH, FP_HEIGHT))
    for k in map_trace:
        map_trace[k] = {} if k == "vertex_muls" else ([] if k == "ss_order" else set())
    for i in range(5):
        draw_stats[i] = 0
    render_bsp_fp(len(nodes) - 1, RecordingClipSpans(),
                  ctx, vz_ps, int(player_x), int(player_y),
                  cos_f, sin_f, tmp,
                      [None]*len(vertexes), [None]*len(vwh_table))
    pygame.draw.line = _real_drawline

def _dump_portal_analysis():
    """Write detailed portal walk analysis to doom_debug.txt."""
    _df = open("doom_debug.txt", "a")
    idx = max(0, min(_debug_idx, len(_debug_steps) - 1))
    step = _debug_steps[idx]
    input_line, spans, clipped = step[0], step[1], step[2]
    step_muls = step[3] if len(step) > 3 else 0
    lx1, ly1, lx2, ly2 = input_line
    w = _df.write
    w(f"Line: ({lx1},{ly1}) -> ({lx2},{ly2})\n")
    w(f"Clipped into {len(clipped)} segments: {clipped}\n")
    w(f"Spans ({len(spans)}):\n")

    if lx1 <= lx2:
        xl, yl_w, xr, yr_w = lx1, ly1, lx2, ly2
    else:
        xl, yl_w, xr, yr_w = lx2, ly2, lx1, ly1
    dx = xr - xl
    y_lo = min(yl_w, yr_w)
    y_hi = max(yl_w, yr_w)

    def ly_at(x):
        if dx == 0: return yl_w
        return yl_w + (yr_w - yl_w) * (x - xl) // dx

    from endpoint_spans import _interp
    intervals = []
    for span_s in spans:
        xlo, xhi, tl, bl, tr, br = span_s[:6]
        if xhi > xl and xlo < xr:
            intervals.append((xlo, xhi, tl, bl, tr, br))

    for i, iv in enumerate(intervals):
        xlo, xhi, yt0, yb0, yt1, yb1 = iv
        gap = ""
        if i > 0 and intervals[i-1][1] != xlo:
            gap = f"  ** GAP {intervals[i-1][1]}-{xlo} **"
        ex = max(xl, xlo)
        xx = min(xr, xhi - 1)
        top_ex = _interp(ex, xlo, yt0, xhi, yt1)
        bot_ex = _interp(ex, xlo, yb0, xhi, yb1)
        top_xx = _interp(xx, xlo, yt0, xhi, yt1)
        bot_xx = _interp(xx, xlo, yb0, xhi, yb1)
        ly_ex = ly_at(ex)
        ly_xx = ly_at(xx)
        pass_ex = top_ex <= ly_ex <= bot_ex
        pass_xx = top_xx <= ly_xx <= bot_xx
        bbox_ex = top_ex <= y_lo and y_hi <= bot_ex
        bbox_xx = top_xx <= y_lo and y_hi <= bot_xx
        w(f"  interval {i}: [{xlo},{xhi}) top=[{yt0},{yt1}] bot=[{yb0},{yb1}]{gap}\n")
        w(f"    entry x={ex}: top={top_ex} bot={bot_ex} ly={ly_ex} bbox={'OK' if bbox_ex else 'FAIL'} exact={'OK' if pass_ex else 'FAIL'}\n")
        w(f"    exit  x={xx}: top={top_xx} bot={bot_xx} ly={ly_xx} bbox={'OK' if bbox_xx else 'FAIL'} exact={'OK' if pass_xx else 'FAIL'}\n")

        if i + 1 < len(intervals) and iv[1] == intervals[i+1][0]:
            nx = xhi
            niv = intervals[i+1]
            pt = max(yt1, niv[2])
            pb = min(yb1, niv[3])
            ly_nx = ly_at(nx)
            pass_p = pt <= ly_nx <= pb
            bbox_p = pt <= y_lo and y_hi <= pb
            w(f"    portal x={nx}: top={pt} bot={pb} ly={ly_nx} bbox={'OK' if bbox_p else 'FAIL'} exact={'OK' if pass_p else 'FAIL'}\n")
    w("=== end ===\n\n")
    _df.close()


def _draw_debug_step(surface):
    """Draw the debug view for the current step."""
    surface.fill((0, 0, 0))
    if not _debug_steps:
        return
    idx = max(0, min(_debug_idx, len(_debug_steps) - 1))

    # Draw all lines up to this step in dim green
    for i in range(idx):
        clipped = _debug_steps[i][2]
        for c in clipped:
            _real_drawline(surface, (0, 60, 0),
                           (c[0] * FP_SCALE, c[1] * FP_SCALE),
                           (c[2] * FP_SCALE, c[3] * FP_SCALE), 1)

    # Draw the clip region at this step as blue alpha overlay
    step = _debug_steps[idx]
    input_line, spans, clipped = step[0], step[1], step[2]
    step_muls = step[3] if len(step) > 3 else 0
    clip_surf = pygame.Surface((SCREEN_W, SCREEN_H), pygame.SRCALPHA)
    _trap_hues = [(40, 40, 180), (60, 100, 160), (30, 70, 200),
                  (80, 50, 170), (50, 90, 140), (70, 60, 190),
                  (40, 110, 150), (90, 40, 180)]
    # spans is a list of (xlo, xhi, yt_lo, yb_lo, yt_hi, yb_hi) — all pixels
    for si, span_s in enumerate(spans):
        xlo, xhi, tl, bl, tr, br = span_s[:6]
        pts = [(xlo * FP_SCALE, tl * FP_SCALE),
               ((xhi - 1) * FP_SCALE, tr * FP_SCALE),
               ((xhi - 1) * FP_SCALE, br * FP_SCALE),
               (xlo * FP_SCALE, bl * FP_SCALE)]
        hue = _trap_hues[si % len(_trap_hues)]
        pygame.draw.polygon(clip_surf, (*hue, 90), pts)
        pygame.draw.polygon(clip_surf, (*(min(c + 60, 255) for c in hue), 200), pts, 1)
    surface.blit(clip_surf, (0, 0))

    # Draw the input line (unclipped) in dim white
    lx1, ly1, lx2, ly2 = input_line
    _real_drawline(surface, (80, 80, 80),
                   (int(lx1 * FP_SCALE), int(ly1 * FP_SCALE)),
                   (int(lx2 * FP_SCALE), int(ly2 * FP_SCALE)), 1)

    # Draw clipped segments in bright colors with split markers
    for ci, c in enumerate(clipped):
        color = (255, 255, 0)
        sx1, sy1 = int(c[0] * FP_SCALE), int(c[1] * FP_SCALE)
        sx2, sy2 = int(c[2] * FP_SCALE), int(c[3] * FP_SCALE)
        _real_drawline(surface, color, (sx1, sy1), (sx2, sy2), 2)
        if ci > 0:
            _real_drawline(surface, (255, 0, 0), (sx1 - 6, sy1 - 6), (sx1 + 6, sy1 + 6), 2)
            _real_drawline(surface, (255, 0, 0), (sx1 - 6, sy1 + 6), (sx1 + 6, sy1 - 6), 2)
        if ci < len(clipped) - 1:
            _real_drawline(surface, (255, 100, 0), (sx2 - 6, sy2 - 6), (sx2 + 6, sy2 + 6), 2)
            _real_drawline(surface, (255, 100, 0), (sx2 - 6, sy2 + 6), (sx2 + 6, sy2 - 6), 2)

    # Cost annotation next to the line
    cost = step[4] if len(step) > 4 else {}
    mid_x = int((lx1 + lx2) / 2 * FP_SCALE)
    mid_y = int((ly1 + ly2) / 2 * FP_SCALE)
    if cost:
        # Build compact label
        parts = []
        if cost.get('bbox_rej'):     parts.append('Brej')
        if cost.get('outer_rej'):    parts.append(f"Or{cost['outer_rej']}")
        if cost.get('inner_acc'):    parts.append(f"Ia{cost['inner_acc']}")
        if cost.get('cb_entry'):     parts.append(f"Ce{cost['cb_entry']}")
        if cost.get('cb_rej'):       parts.append(f"Cr{cost['cb_rej']}")
        if cost.get('portal_cheap'): parts.append(f"Pc{cost['portal_cheap']}")
        if cost.get('portal_exact'): parts.append(f"Px{cost['portal_exact']}")
        if cost.get('portal_exact_fail'): parts.append(f"Pf{cost['portal_exact_fail']}")
        if cost.get('portal_bbox_fail'):  parts.append(f"Pb{cost['portal_bbox_fail']}")
        if cost.get('cb_exit'):      parts.append(f"Cx{cost['cb_exit']}")
        cost_str = ' '.join(parts) if parts else '?'
        # Color: green if all cheap, yellow if some exact, red if CB clips
        has_cb = cost.get('cb_entry',0) + cost.get('cb_exit',0) + cost.get('cb_rej',0)
        has_exact = cost.get('portal_exact',0)
        if has_cb:
            lbl_color = (255, 100, 100)
        elif has_exact:
            lbl_color = (255, 255, 100)
        else:
            lbl_color = (100, 255, 100)
    else:
        cost_str = f"{len(clipped)}"
        lbl_color = (255, 255, 255)
    count_lbl = hud_font.render(cost_str, True, lbl_color)
    bg = pygame.Surface(count_lbl.get_size(), pygame.SRCALPHA)
    bg.fill((0, 0, 0, 192))
    surface.blit(bg, (mid_x + 8, mid_y - 8))
    surface.blit(count_lbl, (mid_x + 8, mid_y - 8))

    # HUD
    hud_font.set_bold(False)
    ang_display = angle_byte if use_fixedpoint else radians_to_byte(angle)
    cum_muls = sum(s[3] if len(s) > 3 else 0 for s in _debug_steps[:idx+1])
    info = (f"({player_x:.0f},{player_y:.0f},{ang_display})  "
            f"Step {idx+1}/{len(_debug_steps)}  line=({lx1},{ly1})->({lx2},{ly2})  "
            f"{len(clipped)} draws  {len(spans)} spans  "
            f"+{step_muls} muls (total {cum_muls})")
    surface.blit(hud_font.render(info, True, (255, 255, 0)), (4, 4))


def _main():
  global player_x, player_y, angle, angle_byte, use_fixedpoint, use_xor
  global show_map, use_packed, _debug_mode, _debug_steps, _debug_idx, _map_scale, _show_nj_raster, _use_6502_frontend, _use_6502_full, _render_6502, _6502_result
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
            elif ev.key == pygame.K_m:
                show_map = not show_map
            elif ev.key == pygame.K_r:
                use_packed = not use_packed
                print(f"Packed ROM path: {'ON' if use_packed else 'OFF'}")
            elif ev.key == pygame.K_n:
                _show_nj_raster = not _show_nj_raster
            elif ev.key == pygame.K_h:
                _use_6502_frontend = not _use_6502_frontend
                if _use_6502_frontend:
                    # Lazy-init the persistent Frontend6502 instance
                    if _render_6502 is None:
                        from fe6502 import Frontend6502
                        _render_6502 = Frontend6502(
                            packed_rom_banks, packed_rom_recip,
                            packed_bbox_table, packed_layout)
                    print("6502 front-end ON (inline)", flush=True)
                else:
                    print("6502 front-end OFF", flush=True)
            elif ev.key == pygame.K_j:
                _use_6502_full = not _use_6502_full
                if _use_6502_full:
                    _use_6502_frontend = False  # J supersedes H
                    if _render_6502 is None:
                        from fe6502 import Frontend6502
                        _render_6502 = Frontend6502(
                            packed_rom_banks, packed_rom_recip,
                            packed_bbox_table, packed_layout)
                    print("6502 full pipeline ON (front-end + clip + NJ raster)", flush=True)
                else:
                    print("6502 full pipeline OFF", flush=True)
            elif ev.key == pygame.K_p:
                # Profile: run 6502 with per-function cycle accounting
                import threading
                _ab = angle_byte if use_fixedpoint else radians_to_byte(angle)
                _px, _py = player_x, player_y
                _rb, _rr, _bt, _pl, _nd = packed_rom_banks, packed_rom_recip, packed_bbox_table, packed_layout, nodes
                _fz = player_floor(player_x, player_y)
                _vzps = _prescale_height(_fz + 41)
                def _profile_6502():
                    global _6502_result
                    import time as _time
                    from fe6502 import Frontend6502, format_profile
                    fe = Frontend6502(_rb, _rr, _bt, _pl)
                    _t0 = _time.time()
                    cmds, cycles, profile = fe.profile_frame(_px, _py, _ab, _fz)
                    _t1 = _time.time()
                    _6502_result = (cmds, cycles, _vzps)
                    print(f"\n=== 6502 profile ({_px:.0f},{_py:.0f},{_ab}) "
                          f"— {_t1-_t0:.1f}s wall ===", flush=True)
                    print(format_profile(profile, cycles), flush=True)
                    print("", flush=True)
                print("6502 profiling in background...", flush=True)
                threading.Thread(target=_profile_6502, daemon=True).start()
                _use_6502_frontend = True
            elif ev.key == pygame.K_d:
                _compare_draw_calls()
            elif ev.key == pygame.K_g:
                _debug_mode = not _debug_mode
                if _debug_mode:
                    _record_frame_steps()
                    _debug_idx = 0
                    # Auto-dump all steps to doom_debug.txt
                    with open("doom_debug.txt", "w") as _gf:
                        _gf.write(f"Position: ({player_x:.0f},{player_y:.0f},{angle_byte})\n")
                        _gf.write(f"Total steps: {len(_debug_steps)}\n\n")
                        for _gi, _gs in enumerate(_debug_steps):
                            _m = _gs[3] if len(_gs) > 3 else 0
                            _gf.write(f"Step {_gi+1}: line={_gs[0]} draws={len(_gs[2])} muls={_m}\n")
            elif ev.key == pygame.K_p and _debug_mode and _debug_steps:
                _dump_portal_analysis()
            elif ev.key in (pygame.K_EQUALS, pygame.K_PLUS, pygame.K_KP_PLUS):
                if _debug_mode:
                    _debug_idx = min(_debug_idx + 1, len(_debug_steps) - 1)
                    _dump_portal_analysis()
                else:
                    _map_scale = _map_scale * 1.5
            elif ev.key in (pygame.K_MINUS, pygame.K_KP_MINUS):
                if _debug_mode:
                    _debug_idx = max(_debug_idx - 1, 0)
                    _dump_portal_analysis()
                else:
                    _map_scale = _map_scale / 1.5

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
        _frame_6502_cycles[0] = 0
        _frame_nj_lines.clear()
        if use_xor:
            pygame.draw.line = _xor_drawline
        else:
            pygame.draw.line = _cycle_drawline
        random.seed(42)
        for i in range(5):
            draw_stats[i] = 0
        for k in map_trace:
            map_trace[k] = {} if k == "vertex_muls" else ([] if k == "ss_order" else set())

        # Fixed-point sin/cos (1.7)
        fp_module.mul_reset()
        # Prescaled player position in 8.8 (sub-unit precision, smooth movement)
        px_88 = int((player_x - MAP_CENTER_X) * 256 / PRESCALE)
        py_88 = int((player_y - MAP_CENTER_Y) * 256 / PRESCALE)
        vz_ps = _prescale_height(player_floor(player_x, player_y) + 41)
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

        if _use_6502_full and _render_6502 is not None:
            # J mode: full 6502 pipeline with NJ rasteriser → extract framebuffer
            import time as _time
            _ab = angle_byte if use_fixedpoint else radians_to_byte(angle)
            _fz = player_floor(player_x, player_y)
            _t0 = _time.perf_counter()
            hw_cyc = _render_6502.render_frame(
                player_x, player_y, _ab, _fz)
            _t1 = _time.perf_counter()
            # Extract framebuffer from py65 memory at $5800 (256×160, Mode 4)
            _mem = _render_6502.mpu.memory
            fp_surface.fill((0, 0, 0))
            _pix = pygame.PixelArray(fp_surface)
            for _cy in range(20):
                for _col in range(32):
                    for _pr in range(8):
                        _y = _cy * 8 + _pr
                        if _y >= 160: break
                        _byte = _mem[0x5800 + _cy * 256 + _col * 8 + _pr]
                        for _bit in range(8):
                            if _byte & (1 << (7 - _bit)):
                                _pix[_col * 8 + _bit, _y] = (255, 255, 255)
            del _pix
        elif _use_6502_frontend and _render_6502 is not None:
            # H mode: 6502 BSP + clip, but Python rasterisation via peripheral
            import time as _time
            _ab = angle_byte if use_fixedpoint else radians_to_byte(angle)
            _fz = player_floor(player_x, player_y)
            _t0 = _time.perf_counter()
            hw_lines, hw_cyc = _render_6502.render_frame(
                player_x, player_y, _ab, _fz, use_peripheral=True)
            _t1 = _time.perf_counter()
            # Draw captured lines with pygame (identical to Python rasterisation)
            fp_surface.fill((0, 0, 0))
            _c = (255, 255, 255)
            for _x0, _y0, _x1, _y1 in hw_lines:
                pygame.draw.line(fp_surface, _c, (_x0, _y0), (_x1, _y1))
        elif use_packed:
            from wad_packed import spans_init_full, SPAN_TOTAL
            p_ram = _packed_ram_new()
            spans_base = packed_layout['ram_spans']
            spans_init_full(p_ram, spans_base, FP_RENDER_W, FP_RENDER_H - 1)
            packed_render_bsp(len(nodes) - 1,
                              EndpointClipSpans(),
                              ctx, vz_ps,
                              px_full, py_full, cos_f, sin_f, fp_surface,
                              p_ram)
        else:
            render_bsp_fp(len(nodes) - 1, EndpointClipSpans(),
                          ctx, vz_ps,
                          px_full, py_full, cos_f, sin_f, fp_surface,
                          [None]*len(vertexes), [None]*len(vwh_table))

        # Nearest-neighbour upscale to display
        _scr = pygame.display.get_surface()
        _scr.fill((0, 0, 0))
        _scr.blit(pygame.transform.scale(fp_surface, (SCREEN_W, SCREEN_H)), (0, 0))
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
        random.seed(42)
        for i in range(5):
            draw_stats[i] = 0
        for k in map_trace:
            map_trace[k] = {} if k == "vertex_muls" else ([] if k == "ss_order" else set())
        cos_a, sin_a = math.cos(angle), math.sin(angle)
        vz = player_floor(player_x, player_y) + 41.0
        render_bsp(len(nodes) - 1, ClipSpans(), cos_a, sin_a,
                   player_x, player_y, vz, screen)

    # Restore normal draw after frame
    pygame.draw.line = _real_drawline

    # ── NJ 6502 raster overlay ──
    if _show_nj_raster and use_fixedpoint:
        from raster6502 import render_lines_6502
        nj_surf, nj_cyc = render_lines_6502(_frame_nj_lines)
        screen.blit(pygame.transform.scale(nj_surf, (SCREEN_W, SCREEN_H)), (0, 0))

    # ── Debug stepper or map overlay ──
    if _debug_mode:
        _draw_debug_step(screen)
        pygame.display.flip()
        continue
    elif show_map:
        ang_for_map = byte_to_radians(angle_byte) if use_fixedpoint else angle
        draw_map(screen, player_x, player_y, ang_for_map)

    # ── HUD ──
    total, unclipped, clipped, trivial, clip_rej = draw_stats
    ang_display = angle_byte if use_fixedpoint else radians_to_byte(angle)
    if use_fixedpoint:
        if _use_6502_frontend and _6502_result is not None:
            hw_cmds, hw_cyc, hw_vzps = _6502_result
            n_segs = sum(1 for c in hw_cmds if c[0] in ('S', 'P'))
            hud = (f"6502x{PRESCALE} ({player_x:.0f},{player_y:.0f},{ang_display})  "
                   f"{n_segs} segs  {hw_cyc} fe cyc  "
                   f"{clock.get_fps():.0f}fps")
        elif _use_6502_frontend:
            hud = f"6502x{PRESCALE} rendering... ({player_x:.0f},{player_y:.0f},{ang_display})"
        else:
            mc = fp_module.mul_counts
            mul_total = sum(mc.values())
            cyc = _frame_6502_cycles[0]
            mode_tag = "fp/ROM" if use_packed else "fp"
            hud = (f"{mode_tag}x{PRESCALE} ({player_x:.0f},{player_y:.0f},{ang_display})  {total} lines  "
                   f"{unclipped} pass  {trivial + clip_rej} fail  {clipped} partial  "
                   f"{mul_total} muls (V:{mc['view']} P:{mc['proj']} C:{mc['clip']})  "
                   f"~{cyc//1000}K cyc  {clock.get_fps():.0f}fps")
    else:
        hud = (f"float ({player_x:.0f},{player_y:.0f},{ang_display})  {total} lines  "
               f"{unclipped} pass  {trivial + clip_rej} fail  {clipped} partial  "
               f"{clock.get_fps():.0f}fps")
    screen.blit(hud_font.render(hud, True, (255, 255, 0)), (4, 4))
    pygame.display.flip()

  pygame.quit()

if __name__ == '__main__':
    try:
        _main()
    except Exception:
        import traceback
        traceback.print_exc()
        import sys; sys.exit(1)
