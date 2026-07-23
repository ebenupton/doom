#!/usr/bin/env python3
"""Joint-rule vertical prototype (Eben's spec, 2026-07-23).

Interactive visualizer over the float reference pipeline comparing:
  mode A — CURRENT verticals: per-seg emission + NOVT/APEDGE rule web
           (fp_render_seg untouched);
  mode B — JOINT RULE: all per-seg verticals suppressed; at each
           (vertex, front-sector) group, met once per frame, the
           vertical bits are F_A Δ F_B (colinear joint) or F_A ∪ F_B
           (corner), where F = the seg's static face-interval set:
             solid          [T, B]
             portal         [T, bt] if NEEDBT  ∪  [bb, B] if NEEDBB
             back-facing    ∅
           (T/B/bt/bb projected at THIS vertex with the shared recip,
           so every y is bit-identical to what the seg itself would
           project.)

Every drawn (post-clip) segment renders at ~50% additive gray, so
overdraw = brighter pixels; the status bar counts overdrawn pixels.

Keys: arrows move/turn - TAB or V toggle mode - N annotate (mode A
NOVT debug off) - ESC quit.
"""
import os, sys, math
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame
import doom_wireframe as dw
import endpoint_spans as es
from endpoint_spans import EndpointClipSpans

W, H, SCALE = 256, 160, 3
LINE_VAL = 110                    # ~50% alpha; 2 hits = 220 (visibly hot)

MODE_B = [False]                  # toggled live


# ---------------------------------------------------------------------------
# static joint tables
# ---------------------------------------------------------------------------
segs = dw.fp_segs_vwh
sectors = dw.fp_sectors
fpv = dw.fp_vertexes
linedefs = dw.linedefs

def _solid(svwh):
    bi = svwh[2]
    if bi is None:
        return True
    bs = sectors[bi]
    return bs[1] <= svwh[3] or bs[0] >= svwh[4]

def _colinear(si, sj):
    # LINEDEF-identity/direction colinearity (matches mode A's rules):
    # a BSP split vertex is QUANTIZED off the parent line, so seg-delta
    # cross products see a phantom 1-2 degree corner (v437's bogus
    # full-height vertical, Eben 2026-07-23). Same linedef = colinear
    # by identity; distinct linedefs compare the s8 linedef dirs.
    if segs[si][0][3] == segs[sj][0][3]:
        return True
    (ax, ay) = segs[si][13], segs[si][14]
    (bx, by) = segs[sj][13], segs[sj][14]
    return ax * by - ay * bx == 0

# vertex -> list of seg indices with an endpoint there (ALL fronts:
# the wall plane continues across front-sector boundaries — Eben's
# staircase report: the step-side wall of the NEXT sector is the
# colinear partner that stops the edge at the step top)
groups = {}
for _i, _svwh in enumerate(segs):
    _s = _svwh[0]
    for _v in (_s[0], _s[1]):
        groups.setdefault(_v, []).append(_i)

# static run partition per vertex: run = maximal colinear cluster.
# EMISSION IS PER RUN, triggered by the first RENDERED member of that
# run reaching the vertex (Eben's v15 report: first-meet-per-vertex
# emitted a far wall's edge while the near corridor rendered — before
# the occluders between them had marked solid. Mode A's timing is
# per-seg; per-run triggering restores it edge-for-edge.)
run_of = {}                       # (vertex, seg) -> run id
run_members = {}                  # (vertex, rid) -> [seg, ...]
for _v, _sjs in groups.items():
    rid = 0
    assigned = {}
    for _sj in _sjs:
        for _sk, _r in assigned.items():
            if _colinear(_sj, _sk):
                assigned[_sj] = _r
                break
        else:
            assigned[_sj] = rid
            rid += 1
    for _sj, _r in assigned.items():
        run_of[(_v, _sj)] = _r
        run_members.setdefault((_v, _r), []).append(_sj)


def _front_facing(si, ctx):
    svwh = segs[si]
    s = svwh[0]
    ld = linedefs[s[3]]
    lv1 = fpv[ld[0]]
    ldx, ldy = svwh[13], svwh[14]
    dot = ldy * (ctx[0] - lv1[0]) - ldx * (ctx[1] - lv1[1])
    if s[4] == 1:
        dot = -dot
    return dot > 0


# interval algebra on (top, bottom) screen-y pairs -------------------------
def _union(iv):
    iv = sorted(p for p in iv if p[1] > p[0])
    out = []
    for a, b in iv:
        if out and a <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out

def _inter(fa, fb):
    ys = sorted({y for p in fa + fb for y in p})
    out = []
    for a, b in zip(ys, ys[1:]):
        m = (a + b) / 2
        if any(p[0] <= m < p[1] for p in fa) and \
           any(p[0] <= m < p[1] for p in fb):
            out.append((a, b))
    return _union(out)

def _setminus(fa, fb):
    ys = sorted({y for p in fa + fb for y in p})
    out = []
    for a, b in zip(ys, ys[1:]):
        m = (a + b) / 2
        if any(p[0] <= m < p[1] for p in fa) and \
           not any(p[0] <= m < p[1] for p in fb):
            out.append((a, b))
    return _union(out)

def _symdiff(fa, fb):
    ys = sorted({y for p in fa + fb for y in p})
    out = []
    for a, b in zip(ys, ys[1:]):
        m = (a + b) / 2
        ina = any(p[0] <= m < p[1] for p in fa)
        inb = any(p[0] <= m < p[1] for p in fb)
        if ina != inb:
            out.append((a, b))
    return _union(out)


# ---------------------------------------------------------------------------
# mode B: joint evaluation at first meeting
# ---------------------------------------------------------------------------
_done = set()                     # (vertex, front) groups evaluated this frame
_prov = []                        # mode-B emissions: (sx, y_a, y_b, vertex, front)
_emitted = {}                     # vertex -> interval list already drawn (any
                                  # front): the cross-front dedup mode A gets
                                  # from _vert_covered_by_solid_ap yielding

def _joint_pass(si, clips, ctx, vz, surface, vcache, vwh_cache):
    svwh = segs[si]
    s = svwh[0]
    if not _front_facing(si, ctx):
        return
    front = svwh[1]
    for vidx in (s[0], s[1]):
        rid = run_of[(vidx, si)]
        key = (vidx, si)
        if key in _done:
            continue
        _done.add(key)
        # vertex transform + projection, EXACTLY the seg's own recipe
        # (and cached, so the seg reuses these values verbatim)
        dw.fp_module.mul_cat("view")
        if vcache[vidx] is None:
            vcache[vidx] = dw.fp_to_view(fpv[vidx][0], fpv[vidx][1], ctx)
        evx_t, evx_r, evy, fvx, vy_idx = vcache[vidx][:5]
        if evy < 1:
            continue              # near-clipped: the seg draws no vertical here either
        dw.fp_module.mul_cat("proj")
        rxh, rxl = dw.fp_recip(vy_idx)
        vc = vcache[vidx]
        if len(vc) > 5:
            sx = vc[5]
        else:
            sx = dw.fp_project_x(evx_t, fvx, rxh, rxl)
            vcache[vidx] = vc + (sx, rxh, rxl)
        if sx < 0 or sx > 255:
            continue              # off-screen column (engine parity)
        # face sets of ALL members at this vertex, EACH from its own
        # front heights (cross-front: the wall plane continues across
        # sector boundaries). Facing recorded, not filtered — a
        # colinear partner continues the surface whichever way it
        # faces; whole runs are silhouette-gated below.
        members = []
        for sj in run_members[(vidx, rid)]:
            svj = segs[sj]
            fh_j, ch_j = svj[3], svj[4]
            T_j = dw.fp_project_y(ch_j - vz, rxh, rxl)
            B_j = dw.fp_project_y(fh_j - vz, rxh, rxl)
            if _solid(svj):
                F = [(T_j, B_j)]
            else:
                bs = sectors[svj[2]]
                F = []
                if bs[1] < ch_j:  # NEEDBT
                    F.append((T_j, dw.fp_project_y(bs[1] - vz, rxh, rxl)))
                if bs[0] > fh_j:  # NEEDBB
                    F.append((dw.fp_project_y(bs[0] - vz, rxh, rxl), B_j))
            members.append((sj, _union(F), _front_facing(sj, ctx)))
        # THIS run's side-split edge (we are here because one of its
        # members is rendering — the run is live by construction):
        # members leave V along +dir or -dir of the run's line;
        # coverage per side = union, edge = where the two sides'
        # coverage DIFFERS (single member: far side empty -> its
        # whole F, the wall-end silhouette)
        rdx, rdy = segs[si][13], segs[si][14]
        pos, neg = [], []
        for sj, F, _ff in members:
            sv = segs[sj][0]
            other = sv[1] if sv[0] == vidx else sv[0]
            dd = ((fpv[other][0] - fpv[vidx][0]) * rdx +
                  (fpv[other][1] - fpv[vidx][1]) * rdy)
            (pos if dd >= 0 else neg).extend(F)
        edges = _symdiff(_union(pos), _union(neg))
        # OWNERSHIP TIMING (Eben's v15 report, round 2): a Δ piece is
        # emitted when a member whose face COVERS it renders — mode A
        # timing, piece for piece. (The doorframe's transom band derives
        # from the room-side face; emitting it when the corridor-side
        # face rendered predated the corridor portal's tighten and leaked
        # through columns the aperture caps.) Pieces covered only by
        # never-rendered members never emit — matching A, where an
        # undrawn seg draws nothing.
        F_self = next(F for sj, F, _ff in members if sj == si)
        edges = _inter(edges, F_self)
        # snap to the pixel grid BEFORE dedup: two front groups derive
        # the same world edge through different height chains, and the
        # float projections differ in the fraction — sub-pixel slivers
        # would survive setminus as 1px dots
        bits = _union([(round(a), round(b)) for a, b in edges])
        # cross-front dedup: never redraw coverage another group at this
        # vertex already emitted this frame
        prev = _emitted.get(vidx, [])
        bits2 = _setminus(bits, prev)
        if prev:
            # dedup REMAINDER slivers: the two fronts' aperture chains
            # can disagree by ~1px in projection; the protruding lip is
            # sub-informative — drop pieces the dedup shaved below 2px
            bits2 = [p for p in bits2 if p[1] - p[0] >= 2]
        bits = bits2
        _emitted[vidx] = _union(prev + bits)
        lines = [(sx, a, sx, b) for a, b in bits if b - a >= 1]
        for l in lines:
            _prov.append((l[0], l[1], l[3], vidx, front))
            clips._draw_vertical_fixed(l[0], l[1], l[3], surface)


# ---------------------------------------------------------------------------
# pipeline hooks
# ---------------------------------------------------------------------------
class ProtoClips(EndpointClipSpans):
    def draw_clipped(self, lines, color, surface, stats=None, roles=None):
        if MODE_B[0]:
            lines = [l for l in lines if abs(l[0] - l[2]) >= 0.5]
        verts = [l for l in lines if abs(l[0] - l[2]) < 1]
        rest = [l for l in lines if abs(l[0] - l[2]) >= 1]
        for (x1, y1, x2, y2) in verts:
            self._draw_vertical_fixed(x1, y1, y2, surface)
        if rest:
            super().draw_clipped(rest, color, surface, stats)

    # TFIX (Eben's longstanding-bug find, 2026-07-24): the shared
    # vertical clip picks the span serving a column with a doubly-
    # INCLUSIVE first-match (xs <= ix <= xe) — boundary columns are
    # always served by the LEFTMOST touching span, so a portal's left
    # jamb column reads the stale pre-tighten aperture (spawn door:
    # left jamb drew [26,116], right [62,107]; both should be the
    # aperture). Correct serving at a shared boundary column is the
    # MORE RESTRICTIVE touching span: the jamb vertical (inside both
    # apertures) still draws; the transom/sill leak is blocked.
    # PROTOTYPE-LOCAL: the engine fix (dcl_vertical's dv_check + the
    # python spans + rebaseline) is its own landing.
    def _draw_vertical_fixed(self, ix, y1, y2, surface):
        import endpoint_spans as _es
        best = None
        for s in self.spans:
            if s[0] <= ix <= s[1]:
                top_y = _es._span_top_ceil(s, ix)
                bot_y = _es._span_bot(s, ix)
                if top_y >= bot_y:
                    continue
                if best is None or (bot_y - top_y) < (best[1] - best[0]):
                    best = (top_y, bot_y)
            elif s[0] > ix:
                break
        if best is None:
            return
        y_min, y_max = min(y1, y2), max(y1, y2)
        cy1, cy2 = max(y_min, best[0]), min(y_max, best[1])
        if cy1 > cy2:
            return
        p1 = (ix, cy1 - self.y_display_offset)
        p2 = (ix, cy2 - self.y_display_offset)
        if _es._drawn_lines is not None:
            _es._drawn_lines.append((len(_es._drawn_lines),
                                     p1[0], p1[1], p2[0], p2[1]))
        pygame.draw.line(surface, (0, 255, 0), p1, p2, 1)

_orig_seg = dw.fp_render_seg
def _seg_hook(si, clips, ctx, vz, surface, vcache, vwh_cache, deferred=None):
    if MODE_B[0]:
        _joint_pass(si, clips, ctx, vz, surface, vcache, vwh_cache)
    _orig_seg(si, clips, ctx, vz, surface, vcache, vwh_cache, deferred)
dw.fp_render_seg = _seg_hook


def _reset_trace():
    for k in dw.map_trace:
        dw.map_trace[k] = {} if k == "vertex_muls" else (
            [] if k == "ss_order" else set())


def render_frame(px, py, ab):
    _done.clear()
    _emitted.clear()
    del _prov[:]
    _reset_trace()
    dw.fp_module.mul_reset()
    es._drawn_lines = []
    p8 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    q8 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz = dw._prescale_height(dw.player_floor(px, py) + 41)
    ctx = dw.fp_view_context(p8, q8, dw.fp_sincos(ab))
    ar = ab * 2 * math.pi / 256
    scratch = pygame.Surface((W, H))
    dw.render_bsp_fp(len(dw.nodes) - 1, ProtoClips(), ctx, vz,
                     int(px), int(py), math.cos(ar), math.sin(ar), scratch,
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))
    segs_drawn = list(es._drawn_lines)
    es._drawn_lines = None
    return segs_drawn


def accumulate(drawn):
    """Render collected segments at ~50% additive gray; return surface +
    overdraw pixel count."""
    accum = pygame.Surface((W, H))
    accum.fill((0, 0, 0))
    temp = pygame.Surface((W, H))
    for (_i, x1, y1, x2, y2) in drawn:
        temp.fill((0, 0, 0))
        pygame.draw.line(temp, (LINE_VAL, LINE_VAL, LINE_VAL),
                         (x1, y1), (x2, y2))
        accum.blit(temp, (0, 0), special_flags=pygame.BLEND_RGB_ADD)
    arr = pygame.surfarray.pixels_red(accum)
    over = int((arr > LINE_VAL).sum())
    del arr
    return accum, over


def vertical_labels(drawn):
    """[(label, x, y1, y2, provenance-or-None)] for drawn verticals, in
    draw order. Provenance = (vertex, front) when a mode-B emission at
    that column contains the clipped range."""
    out = []
    n = 0
    for (_i, x1, y1, x2, y2) in drawn:
        if x1 != x2 or abs(y2 - y1) < 1:
            continue              # (1px x1==x2 fragments of clipped
                                  #  diagonals are not verticals)
        n += 1
        lo, hi = min(y1, y2), max(y1, y2)
        prov = None
        for (sx, a, b, vtx, fr) in _prov:   # exact interval first
            if sx == x1 and abs(a - lo) <= 1 and abs(b - hi) <= 1:
                prov = (vtx, fr)
                break
        if prov is None:
            for (sx, a, b, vtx, fr) in _prov:
                if sx == x1 and a - 1 <= lo and hi <= b + 1:
                    prov = (vtx, fr)
                    break
        out.append((n, x1, lo, hi, prov))
    return out


def print_label_table(labels, mode_b):
    print(f'--- verticals ({"B joint" if mode_b else "A current"}) ---')
    for (n, x, lo, hi, prov) in labels:
        src = f'v{prov[0]}/f{prov[1]}' if prov else ('seg-emitted' if not mode_b else '?')
        print(f'  #{n:<3d} x={x:<3d} y={lo:.0f}-{hi:.0f}  {src}')


_DIGITS = {                     # 3x5 bitmap font (font subsystem-proof)
 '0':'111101101101111','1':'010110010010111','2':'111001111100111',
 '3':'111001111001111','4':'101101111001001','5':'111100111001111',
 '6':'111100111101111','7':'111001010010010','8':'111101111101111',
 '9':'111101111001111'}

def _blit_num(screen, n, x, y, color, px=2):
    for i, ch in enumerate(str(n)):
        bm = _DIGITS[ch]
        for r in range(5):
            for c in range(3):
                if bm[r * 3 + c] == '1':
                    screen.fill(color, (x + i * 4 * px + c * px,
                                        y + r * px, px, px))

def draw_labels(screen, labels, font=None):
    placed = []
    for (n, x, lo, hi, _prov_) in labels:
        w = len(str(n)) * 4 * 2
        lx = x * SCALE + 3
        if lx + w > W * SCALE:
            lx = x * SCALE - w - 3
        ly = int((lo + hi) / 2 * SCALE) - 5
        ly = max(0, min(H * SCALE - 12, ly))
        for _ in range(20):                    # nudge below colliders
            if not any(abs(ly - py) < 12 and lx < px + pw and px < lx + w
                       for (px, py, pw) in placed):
                break
            ly += 12
        placed.append((lx, ly, w))
        _blit_num(screen, n, lx, ly, (255, 220, 60))


def main():
    pygame.init()
    screen = pygame.display.set_mode((W * SCALE, H * SCALE + 24))
    font = pygame.font.Font(None, 16)
    px, py, ab = 1056.0, -3616.0, 64
    dirty = True
    clock = pygame.time.Clock()
    while True:
        for e in pygame.event.get():
            if e.type == pygame.QUIT:
                return
            if e.type == pygame.KEYDOWN:
                if e.key == pygame.K_ESCAPE:
                    return
                if e.key in (pygame.K_TAB, pygame.K_v):
                    MODE_B[0] = not MODE_B[0]; dirty = True
        keys = pygame.key.get_pressed()
        if keys[pygame.K_LEFT]:
            ab = (ab + 4) & 255; dirty = True
        if keys[pygame.K_RIGHT]:
            ab = (ab - 4) & 255; dirty = True
        if keys[pygame.K_UP] or keys[pygame.K_DOWN]:
            st = 16.0 if keys[pygame.K_UP] else -16.0
            px += st * math.cos(ab * 2 * math.pi / 256)
            py += st * math.sin(ab * 2 * math.pi / 256)
            dirty = True
        if dirty:
            drawn = render_frame(px, py, ab)
            accum, over = accumulate(drawn)
            labels = vertical_labels(drawn)
            print_label_table(labels, MODE_B[0])
            screen.fill((0, 0, 0))
            screen.blit(pygame.transform.scale(accum, (W * SCALE, H * SCALE)),
                        (0, 0))
            draw_labels(screen, labels, font)
            mode = 'B: JOINT RULE' if MODE_B[0] else 'A: CURRENT (NOVT/APEDGE)'
            txt = (f'{mode}   segs={len(drawn)}  verts={len(labels)}  '
                   f'overdraw px={over}   ({px:.0f},{py:.0f},{ab})  '
                   f'TAB=toggle')
            screen.blit(font.render(txt, True, (255, 255, 160)),
                        (6, H * SCALE + 4))
            pygame.display.flip()
            dirty = False
        clock.tick(30)


if __name__ == '__main__':
    if '--selftest' in sys.argv:
        os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
        pygame.init()
        pygame.display.set_mode((1, 1))
        for (px, py, ab) in [(1056, -3616, 64), (1500, -3700, 0),
                             (800, -3400, 96), (1200, -3000, 129)]:
            MODE_B[0] = False
            a_drawn = render_frame(px, py, ab)
            sa, oa = accumulate(a_drawn)
            MODE_B[0] = True
            b_drawn = render_frame(px, py, ab)
            sb, ob = accumulate(b_drawn)
            va = sum(1 for d in a_drawn if d[1] == d[3])
            vb = sum(1 for d in b_drawn if d[1] == d[3])
            font = pygame.font.Font(None, 15)
            for tag, dr, surf, mb in (('A', a_drawn, sa, False),
                                      ('B', b_drawn, sb, True)):
                MODE_B[0] = mb
                # re-render for provenance capture (cheap, deterministic)
                dr2 = render_frame(px, py, ab)
                labels = vertical_labels(dr2)
                print_label_table(labels, mb)
                big = pygame.transform.scale(surf, (W * SCALE, H * SCALE))
                draw_labels(big, labels, font)
                pygame.image.save(big, f'/tmp/jpl_{tag}_{px}_{py}_{ab}.png')
            print(f'({px},{py},{ab}): A segs={len(a_drawn)} verts={va} '
                  f'overdraw={oa} | B segs={len(b_drawn)} verts={vb} '
                  f'overdraw={ob}')
            pygame.image.save(sa, f'/tmp/jp_A_{px}_{py}_{ab}.png')
            pygame.image.save(sb, f'/tmp/jp_B_{px}_{py}_{ab}.png')
            import pygame.surfarray as sfa
            ra, rb = sfa.array_red(sa), sfa.array_red(sb)
            dif = pygame.Surface((W, H))
            pa = sfa.pixels3d(dif)
            import numpy as np
            both = ((ra > 0) & (rb > 0)).astype(np.uint8) * 90
            pa[..., 0] = np.maximum(((ra > 0) & (rb == 0)).astype(np.uint8) * 255, both)
            pa[..., 1] = np.maximum(((rb > 0) & (ra == 0)).astype(np.uint8) * 255, both)
            pa[..., 2] = both
            del pa
            pygame.image.save(dif, f'/tmp/jp_D_{px}_{py}_{ab}.png')
        print('selftest done')
    else:
        main()
