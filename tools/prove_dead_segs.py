#!/usr/bin/env python3
"""Formal never-renderable certificates for candidate segs.

THEOREM (per candidate seg s): the engine never draws s.
  Lemma A (backface exactness): the engine draws s only if the viewer
    center lies strictly inside s's front half-plane, whose parameters
    are the PACKED engine bytes (axis C-form: baked form/C16 with the
    documented tie folding; diagonal: folded DIR deltas + LV1 reference
    with sub-prescale K residues, full-precision dot, tie draws only if
    dyp>0). Grounding: packed_render_seg is bit-identical to the 6502
    by the exact-backface construction and its regression gates.
  Lemma B (containment): the viewer center always lies in the closed
    union of reachable sectors R+. R+ is the flood from the spawn sector
    over two-sided linedefs, passable iff step<=24 AND opening>=56 at
    SOME mover phase; mover heights range over [far,rest] (colmap far
    pose rules) and both conditions are monotone in each height, so the
    exact EXISTS-phase test is the OR over interval endpoints. One-sided
    lines always block; ML_BLOCKING is IGNORED (over-approximation).
    pmove (the only mover of the player) rejects any move crossing a
    line that fails these tests at the live heights (colmap.py is the
    single canonical statement; pm_box_vs_seg/pm_move_crosses_line
    prevent tunnelling), so no center path leaves R+.
  Certificate C: closure(sector) is contained in the convex hull of the
    sector's linedef vertices; the dot is linear, so its maximum over
    the hull is attained at a vertex. If every vertex of every R+
    sector has dot < 0 (exact integers, 8.8 world units), no reachable
    viewer position satisfies Lemma A's draw condition.  QED.
"""
import sys, os
sys.path.insert(0,'/Users/ebenupton/doom')
os.chdir('/Users/ebenupton/doom')
os.environ['SDL_VIDEODRIVER']='dummy'; os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import doom_wireframe as dw
from wad_packed import SH_DIAG, SH_FLAGS

CANDS = [659,660,670,676,709]   # provable set (west lobe; ld121 included)
REFUTED = [153,157,159,161,164,168,169,461]  # east group + ld372: reachable-front
CONTROLS = [672]            # ld111: known drawable, must FAIL

lay = dw.packed_layout; rom = dw.packed_rom_main

# ---- Lemma B: R+ flood (exact EXISTS-phase edge test) ------------------
movers = sorted(dw.ANIM_SECTORS)
def far_heights(s):
    fh, ch = dw.sectors[s][0], dw.sectors[s][1]
    nb = set()
    for ld in dw.linedefs:
        ss = [dw.sidedefs[sd][5] for sd in (ld[5], ld[6]) if sd != 0xFFFF]
        if s in ss: nb.update(x for x in ss if x != s)
    if dw.ANIM_SECTORS[s] == 'ceil':
        ch = min(dw.sectors[n][1] for n in nb) - 4
    else:
        fh = min(dw.sectors[n][0] for n in nb)
    return fh, ch
def phases(s):
    rest = (dw.sectors[s][0], dw.sectors[s][1])
    return [rest, far_heights(s)] if s in dw.ANIM_SECTORS else [rest]
import collections
adj = collections.defaultdict(set)
for ld in dw.linedefs:
    r, l = ld[5], ld[6]
    if r == 0xFFFF or l == 0xFFFF: continue          # one-sided: blocks
    sr, sl = dw.sidedefs[r][5], dw.sidedefs[l][5]
    for (fr, cr) in phases(sr):
        for (fl, cl) in phases(sl):
            if min(cr, cl) - max(fr, fl) < 56: continue
            if fl - fr <= 24: adj[sr].add(sl)
            if fr - fl <= 24: adj[sl].add(sr)
sx, sy = 1056, -3616
spawn_sec = None
nid = len(dw.nodes) - 1
while not (nid & 0x8000):
    n = dw.nodes[nid]
    nid = n[12] if (n[3]*(sx-n[0]) - n[2]*(sy-n[1])) > 0 else n[13]
spawn_sec = dw.seg_sectors(dw.segs[dw.ssectors[nid & 0x7FFF][1]])[0]
Rp = {spawn_sec}; work=[spawn_sec]
while work:
    s = work.pop()
    for t in adj[s]:
        if t not in Rp: Rp.add(t); work.append(t)

# R+ boundary vertex set (every vertex of every linedef bounding an R+ sector)
verts = set()
for ld in dw.linedefs:
    secs = [dw.sidedefs[sd][5] for sd in (ld[5], ld[6]) if sd != 0xFFFF]
    if any(s in Rp for s in secs):
        verts.add(dw.vertexes[ld[0]]); verts.add(dw.vertexes[ld[1]])
print(f'R+ = {len(Rp)} sectors: {sorted(Rp)}')
print(f'boundary vertex set: {len(verts)} vertices')

# ---- Lemma A: per-seg engine half-plane from PACKED bytes --------------
from wad_packed import seg_hdr_off, SH_C
def seg_params(si):
    # map raw wad seg -> packed seg id (renumbered): match by linedef+side+span
    s = dw.segs[si]
    for pi, svwh in enumerate(dw.fp_segs_vwh):
        ps = svwh[0]
        if ps[3] == s[3] and ps[4] == s[4]:
            # merged span may cover several raw segs; accept (same line)
            break
    else:
        raise KeyError(f'seg {si} not in packed set')
    off = lay['off_seg_hdr'] + seg_hdr_off(pi)
    form = rom[off + 4] & 0x07 if False else None
    # bf_form location: read the packed TYPE byte the mirror reads
    return pi, off

def draw_condition(si):
    """Returns (kind, params, human) for the engine draw half-plane."""
    pi, off = seg_params(si)
    bf_form = rom[off + 4] & 0x0F if False else None
    # replicate the mirror's decode exactly:
    formbyte = rom[off + 4]
    # mirror: bf_form < 4 -> axis; else diagonal with did = bf_form-4
    bf_form = formbyte
    if bf_form < 4:
        c16 = rom[off + SH_C] | (rom[off + SH_C + 1] << 8)
        if c16 & 0x8000: c16 -= 0x10000
        axis = 'x' if bf_form < 2 else 'y'
        # cull iff (d>=0 if form&1 else d<=0), d = p_int - c16
        if bf_form & 1:
            return ('axis', (axis, '<', c16), f'draw iff {axis}_int < {c16}')
        else:
            return ('axis', (axis, '>', c16), f'draw iff {axis}_int > {c16}')
    did = bf_form - 4
    od = lay['off_dirs']; md = lay['max_dirs']
    dxm, dym, sg = rom[od+did], rom[od+md+did], rom[od+2*md+did]
    dxp = -dxm if (sg & 0x40) else dxm
    dyp = -dym if (sg & 0x80) else dym
    rid = rom[off + SH_DIAG]
    ol = lay['off_lv1']
    lx = rom[ol+rid] | (rom[ol+0x80+rid] << 8)
    ly = rom[ol+0x100+rid] | (rom[ol+0x180+rid] << 8)
    if lx & 0x8000: lx -= 0x10000
    if ly & 0x8000: ly -= 0x10000
    kx, ky, _, _ = lay['lv1_krec'][rid]
    rx88, ry88 = 256*lx + 32*kx, 256*ly + 32*ky
    return ('diag', (dxp, dyp, rx88, ry88),
            f'draw iff {dyp}*(x88-{rx88}) - {dxp}*(y88-{ry88}) > 0'
            + (f' (tie draws: dyp={dyp}>0)' if dyp > 0 else ' (tie culls)'))

CX, CY = dw.MAP_CENTER_X, dw.MAP_CENTER_Y
def certify(si):
    kind, prm, human = draw_condition(si)
    worst = None
    for (wvx, wvy) in verts:
        # engine units: map-centre-relative counts (prescale 8, exact)
        assert (wvx-CX) % 8 == 0 and (wvy-CY) % 8 == 0
        vx, vy = (wvx-CX)//8, (wvy-CY)//8
        if kind == 'axis':
            axis, op, c = prm
            val = vx if axis == 'x' else vy
            # draw iff p_int OP c; p_int = floor(p); vertex coords integer
            margin = (c - val) if op == '<' else (val - c)   # draw when margin > 0... careful:
            # op '<': draw iff p_int < c -> dead needs ALL verts >= c -> margin_bad = c - val > 0 means val < c = DRAWS
            bad = (val < c) if op == '<' else (val > c)
            key = (c - val) if op == '<' else (val - c)
        else:
            dxp, dyp, rx, ry = prm
            dot = dyp*(256*vx - rx) - dxp*(256*vy - ry)
            bad = dot > 0 or (dot == 0 and dyp > 0)
            key = dot
        if worst is None or key > worst[0]:
            worst = (key, (wvx, wvy), bad)
    return kind, human, worst

print()
print('== CERTIFICATES ==')
allpass = True
for si in CANDS:
    s = dw.segs[si]
    kind, human, (key, wv, bad) = certify(si)
    verdict = 'FAIL' if bad else 'PROVED-DEAD'
    if bad: allpass = False
    print(f'seg {si} (ld{s[3]} s{s[4]}, {kind}): {human}')
    print(f'   worst vertex {wv}: margin/dot {key}  -> {verdict}')
print()
print('== REFUTED CANDIDATES + CONTROL (must FAIL) ==')
for si in REFUTED + CONTROLS:
    s = dw.segs[si]
    kind, human, (key, wv, bad) = certify(si)
    print(f'seg {si} (ld{s[3]} s{s[4]}, {kind}): worst vertex {wv} key {key} -> {"FAIL (correct)" if bad else "PROVED-DEAD (UNEXPECTED!)"}')
print()
print('ALL CANDIDATES PROVED' if allpass else 'SOME CANDIDATES FAILED')
