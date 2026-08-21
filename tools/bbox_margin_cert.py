#!/usr/bin/env python3
"""Angular->screen margin certificate for the bca bbox gate.

Question (Eben 2026-08-21): under NATIVE half-open has_gap, can bca_ihi
be read as an EXCLUSIVE right edge as-is (no +1), given the margin
stack (world-inflated packed corners -> +-EPS angle bias -> vatox
bracket centre -> +-1 column inflate)?

Method: at each viewpoint, run the packed reference with the bbox gate
and clipper verdicts FORCED OPEN (full descent, every seg stages) and a
recording stub in place of the clipper.  Claims and paints are
op-ARGUMENTS, which are clip-state independent, so the forced-open run
yields each subtree's maximal potential:
  claims  = tighten/mark_solid [lo, hi)      (occlusion vocabulary)
  paints  = drawn-line x extents (run-out: dcl paints THROUGH x_hi)
          + vertex-span columns sx           (paint AT the column)
Then for every (node, side) the REAL fp_bbox_visible_fixed extent
(ilo, ihi) is compared against the subtree aggregate:
  exclusive-claim safety:  ihi >= max(claim_hi)      slack_rc
  run-out paint safety:    ihi >= max(paint_col)+1   slack_rp
  left (both readings):    ilo <= min(claim_lo)      slack_lc
                           ilo <= min(paint_col)     slack_lp
A cull (None) with any subtree activity is a hard violation.

Usage: bbox_margin_cert.py [n_corpus_sample] [seed] [n_workers]
"""
import os, sys, random, json
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame
pygame.init()

import doom_wireframe as dw
import fp
from wad_packed import spans_init_full

dw._AP_SKIP_ENABLE = False
dw._USE_ANGLE_BBOX = True

NF_SUBSECTOR = dw.NF_SUBSECTOR


# ── static tree structure (packed ROM, same reads as packed_render_bsp) ──
def _children(nid):
    layout = dw.packed_layout
    rom = dw.packed_rom_main
    nb = layout['off_nodes']
    typ = rom[nb + 8*256 + nid]
    child_r = rom[nb + 6*256 + nid] | ((typ & 0x80) << 8)
    child_l = rom[nb + 7*256 + nid] | ((typ & 0x40) << 9)
    return child_r, child_l


def _subtree_ss(child):
    """All subsector ids under a child link."""
    if child & NF_SUBSECTOR:
        return [0 if child == 0xFFFF else child & 0x7FFF]
    out = []
    for c in _children(child):
        out.extend(_subtree_ss(c))
    return out

_ROOT = len(dw.nodes) - 1
SUBTREE = {}
for _n in range(_ROOT + 1):
    _cr, _cl = _children(_n)
    SUBTREE[(_n, 0)] = _subtree_ss(_cr)
    SUBTREE[(_n, 1)] = _subtree_ss(_cl)


# ── recording clipper stub ──
class RecClips:
    """Everything open, nothing clipped; records op arguments."""
    def __init__(self):
        self.ops = []            # (ssid, kind, lo, hi)
        self.ssid = None
        self.spans = []
    def has_gap(self, lo, hi):  return True
    def is_full(self):          return False
    def line_above_spans(self, *a, **k): return False
    def line_below_spans(self, *a, **k): return False
    def vertical_outside_spans(self, *a, **k): return False
    def mark_solid(self, lo, hi, **k):
        self.ops.append((self.ssid, 'claim', lo, hi))
        self.ops.append((self.ssid, 'paint', lo, hi))   # edge lines run out
    def tighten(self, lo, hi, *a, **k):
        self.ops.append((self.ssid, 'claim', lo, hi))
        self.ops.append((self.ssid, 'paint', lo, hi))   # emitted portal edges
    def snapshot_tighten_records(self, lo, hi, *a, **k):
        self.tighten(lo, hi)
    def draw_clipped(self, lines, color, surface, stats, roles=None):
        for (x0, y0, x1, y1) in lines:
            lo, hi = (x0, x1) if x0 <= x1 else (x1, x0)
            self.ops.append((self.ssid, 'paint', int(lo), int(hi)))
        return []


class _SCStub:
    def reset_records(self): pass
    def mark_solid(self, *a, **k): pass
    def tighten(self, *a, **k): pass


def run_frame(px, py, ab):
    clips = RecClips()
    orig_ab = dw._VIEW_AB
    orig_bbox = dw.fp_bbox_visible_fixed
    orig_ss = dw.packed_render_subsector
    orig_evs = dw.emit_vertex_spans
    orig_sc = dw._span_clip_6502
    dw._VIEW_AB = ab
    try:
        px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
        py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
        sc_t = fp.fp_sincos(ab)
        ctx = fp.fp_view_context(px_88, py_88, sc_t)
        vz = dw._prescale_height(dw.player_floor(px, py) + 41)
        cos_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).x
        sin_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).y
        ram = bytearray(dw.packed_layout['ram_size'])
        spans_init_full(ram, dw.packed_layout['ram_spans'],
                        dw.FP_RENDER_W, dw.FP_RENDER_H - 1)

        def forced_bbox(node, far_side, c):
            return (0, 255)
        def ss_wrap(idx, cl, c, v, surf, rm):
            cl.ssid = idx
            return orig_ss(idx, cl, c, v, surf, rm)
        def evs_wrap(vidx, sx, proj, H, cl, surf, stats, on_screen):
            if on_screen:
                cl.ops.append((cl.ssid, 'paint', int(sx), int(sx)))
            return orig_evs(vidx, sx, proj, H, cl, surf, stats, on_screen)
        dw.fp_bbox_visible_fixed = forced_bbox
        dw.packed_render_subsector = ss_wrap
        dw.emit_vertex_spans = evs_wrap
        dw._span_clip_6502 = _SCStub()

        surf = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
        dw.packed_render_bsp(_ROOT, clips, ctx, vz,
                             px, py, cos_f, sin_f, surf, ram)
    finally:
        dw._VIEW_AB = orig_ab
        dw.fp_bbox_visible_fixed = orig_bbox
        dw.packed_render_subsector = orig_ss
        dw.emit_vertex_spans = orig_evs
        dw._span_clip_6502 = orig_sc

    # aggregate per subsector
    agg = {}                     # ssid -> [cl_lo, cl_hi, pt_lo, pt_hi]
    for (ssid, kind, lo, hi) in clips.ops:
        # intersect with the screen domain FIRST: the reference tighten
        # legitimately receives raw off-screen s16 columns (the pool
        # clamps naturally), and the gate only answers for [0, 255)
        # WILD channel: raw extents far outside the screen are the
        # standing projection-overflow class (far-west / clip-to-screen
        # symptom), not an angular-margin property — certify separately
        wild = lo < -256 or hi > 511
        if kind == 'claim':
            lo, hi = max(0, lo), min(255, hi)
            if hi <= lo:
                continue
            a = agg.setdefault(ssid, [999, -999, 999, -999, []])
            if wild:
                a[4].append(('claim', lo, hi)); continue
            a[0] = min(a[0], lo); a[1] = max(a[1], hi)
        else:
            lo, hi = max(0, lo), min(254, hi)  # col 255 nonexistent
            if hi < lo:
                continue
            a = agg.setdefault(ssid, [999, -999, 999, -999, []])
            if wild:
                a[4].append(('paint', lo, hi)); continue
            a[2] = min(a[2], lo); a[3] = max(a[3], hi)

    # per-(node, side) certificate rows
    dw._VIEW_AB = ab             # real extents need the view angle too
    rows = []
    try:
        px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
        py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
        ctx = fp.fp_view_context(px_88, py_88, fp.fp_sincos(ab))
        for (nid, side), sslist in SUBTREE.items():
            cl_lo = min((agg[s][0] for s in sslist if s in agg), default=999)
            cl_hi = max((agg[s][1] for s in sslist if s in agg), default=-999)
            pt_lo = min((agg[s][2] for s in sslist if s in agg), default=999)
            pt_hi = max((agg[s][3] for s in sslist if s in agg), default=-999)
            n_wild = sum(len(agg[s][4]) for s in sslist if s in agg)
            if cl_hi < 0 and pt_hi < 0 and n_wild == 0:
                continue                       # subtree inert here
            br = orig_bbox(dw.nodes[nid], side, ctx)
            rows.append((nid, side, br, cl_lo, cl_hi, pt_lo, pt_hi, n_wild))
    finally:
        dw._VIEW_AB = orig_ab
    return rows


def main():
    n_sample = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    suite = [(1056, -3616, 128), (1056, -3328, 14), (1308, -3289, 252),
             (1500, -3700, 0), (800, -3400, 96), (1792, -3351, 108)]
    views = [(x, y, a) for (x, y, _) in suite for a in (0, 64, 128, 192)]
    views += [(x, y, a) for (x, y, a) in suite]
    if n_sample:
        rng = random.Random(seed)
        corpus = [tuple(map(float, l.split()))
                  for l in open('build/inside_corpus.txt')
                  if not l.startswith('#')]
        for (x, y) in rng.sample(corpus, n_sample):
            for a in (0, 64, 128, 192):
                views.append((x, y, a))

    from collections import Counter
    slack = {k: Counter() for k in ('rc', 'rp', 'lc', 'lp', 'rcU', 'rpU', 'lcU', 'lpU')}
    cull_viol = []
    wild_rows = []
    viol_rows = []
    worst = {}
    for i, (px, py, ab) in enumerate(views):
        for (nid, side, br, cl_lo, cl_hi, pt_lo, pt_hi, n_wild) in run_frame(px, py, ab):
            if n_wild:
                wild_rows.append((px, py, ab, nid, side, br, n_wild))
            if cl_hi < 0 and pt_hi < 0:
                continue                       # only wild activity here
            if br is None:
                cull_viol.append((px, py, ab, nid, side, cl_lo, cl_hi, pt_lo, pt_hi))
                continue
            ilo, ihi = br
            vals = {}
            if cl_hi >= 0:
                vals['rc'] = ihi - cl_hi
                vals['lc'] = cl_lo - ilo
            if pt_hi >= 0:
                vals['rp'] = ihi - 1 - pt_hi
                vals['lp'] = pt_lo - ilo
            # unsaturated channels: only rows where the box edge is
            # interior (not clamped), the honest tightness signal
            if ihi < 255:
                if cl_hi >= 0: vals['rcU'] = ihi - cl_hi
                if pt_hi >= 0: vals['rpU'] = ihi - 1 - pt_hi
            if ilo > 0:
                if cl_hi >= 0: vals['lcU'] = cl_lo - ilo
                if pt_hi >= 0: vals['lpU'] = pt_lo - ilo
            for k, v in vals.items():
                slack[k][max(-5, min(12, v))] += 1
                if v < 0:
                    viol_rows.append(dict(k=k, slack=v, px=px, py=py, ab=ab,
                                          nid=nid, side=side, br=br,
                                          cl=(cl_lo, cl_hi), pt=(pt_lo, pt_hi)))
                if v < worst.get(k, (99,))[0]:
                    worst[k] = (v, px, py, ab, nid, side, br,
                                cl_lo, cl_hi, pt_lo, pt_hi)
        if i % 50 == 49:
            print(f"  ... {i+1}/{len(views)} viewpoints", flush=True)

    json.dump(dict(cull=cull_viol, viol=viol_rows), open('build/margin_cert_viol.json', 'w'))
    print(f"\n{len(views)} viewpoints; cull-violations: {len(cull_viol)}; "
          f"wild-projection rows: {len(wild_rows)} "
          f"(gate rows contaminated by the overflow class, certified separately)")
    for w in wild_rows[:4]:
        print("  WILD", w)
    for v in cull_viol[:5]:
        print("  CULLVIOL", v)
    names = {'rc': 'right exclusive-claim  (ihi - max claim_hi)',
             'rp': 'right run-out paint    (ihi-1 - max paint)',
             'lc': 'left  claim            (min claim_lo - ilo)',
             'lp': 'left  paint            (min paint - ilo)',
             'rcU': 'right claim UNSATURATED (ihi<255 rows only)',
             'rpU': 'right paint UNSATURATED',
             'lcU': 'left  claim UNSATURATED (ilo>0 rows only)',
             'lpU': 'left  paint UNSATURATED'}
    for k in ('rc', 'rp', 'lc', 'lp', 'rcU', 'rpU', 'lcU', 'lpU'):
        c = slack[k]
        neg = sum(n for s, n in c.items() if s < 0)
        print(f"\n{names[k]}: n={sum(c.values())}  VIOLATIONS(<0)={neg}")
        print("  slack histo:", dict(sorted(c.items())))
        if k in worst:
            print("  worst:", worst[k])


if __name__ == '__main__':
    main()
