#!/usr/bin/env python3
"""Dense pose-grid evidence for a BSP tree change (2026-09-04).

THE LESSON THIS TOOL EXISTS FOR: a sparse battery and a raw map sweep
both gave the WRONG SIGN on the polish_c30 candidate.

  * a cone of views aimed INTO the armour room said +0.037% (worse);
    the same points swept over ALL EIGHT angles said -0.108%
  * the raw 504-pose map grid said +0.042% -- but 394 of those poses are
    OFF-MAP; the 110 reachable ones said -0.130%

So: every direction from every position, and positions filtered to
standable AND inside the closed map.  `colmap.try_move` alone is NOT a
filter -- it accepts (-9999,-9999); the in-map test is a 24-direction
ray sweep (inside a closed map, every ray hits a linedef).

Usage (a candidate tree is a wad passed as DOOM_ALT_WAD):
  python3 tools/bsp_dense_grid.py grid    <out.json> [cx cy]   # build poses
  python3 tools/bsp_dense_grid.py measure <wad|-> <tag> <grid.json> <out.json>
  python3 tools/bsp_dense_grid.py compare <a.json> <b.json>

`measure` FB-verifies a 60-pose sample against the float reference
(objects off -- pyref draws no billboards) before any cycle number
counts: a broken tree renders nothing and looks like a huge win.
"""
import os, sys, json, math, time, random, collections, statistics

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANGLES = [0, 32, 64, 96, 128, 160, 192, 224]
ARMOUR = (-224, -3232)                     # the green armour: room seed


def _dw():
    os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
    os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
    sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
    import pygame; pygame.init(); pygame.display.set_mode((1, 1))
    import doom_wireframe as dw
    return dw


def build_grid(out, seed=ARMOUR):
    import numpy as np
    dw = _dw()
    import colmap, anim_sectors as an
    V = np.array([[v[0], v[1]] for v in dw.vertexes], float)
    A = np.array([V[ld[0]] for ld in dw.linedefs])
    E = np.array([V[ld[1]] for ld in dw.linedefs]) - A
    DIRS = np.array([[math.cos(2 * math.pi * k / 24), math.sin(2 * math.pi * k / 24)]
                     for k in range(24)])

    def in_map(px, py):
        AP = A - np.array([px, py], float)
        for d in DIRS:
            den = d[0] * E[:, 1] - d[1] * E[:, 0]
            ok = np.abs(den) > 1e-9
            t = np.where(ok, (AP[:, 0] * E[:, 1] - AP[:, 1] * E[:, 0]) / np.where(ok, den, 1), -1)
            u = np.where(ok, (AP[:, 0] * d[1] - AP[:, 1] * d[0]) / np.where(ok, den, 1), -1)
            if not np.any(ok & (t > 1e-6) & (u >= 0) & (u <= 1)):
                return False
        return True

    m = colmap.build()
    rest = [dw._prescale_height(an.MOVERS[s].closed if an.MOVERS[s].kind == 'ceil'
                                else an.MOVERS[s].top) & 0xFF
            for s in sorted(dw.ANIM_SECTORS)]

    def standable(wx, wy):
        rx, ry = wx - dw.MAP_CENTER_X, wy - dw.MAP_CENTER_Y
        try:
            ss = colmap.find_ss(rx, ry)
            vz = m['ss_vz'][ss]; vz -= 256 if vz >= 128 else 0
            if not colmap.try_move(rx, ry, rx, ry, vz, rest)[0]:
                return False                       # embedded in a wall
            return any(colmap.try_move(rx, ry, rx + dx, ry + dy, vz, rest)[0]
                       for dx, dy in ((8, 0), (-8, 0), (0, 8), (0, -8)))
        except Exception:
            return False

    ok = lambda x, y: standable(x, y) and in_map(x, y)
    STEP = 32
    seen = {seed}; stack = [seed]; room = []
    while stack:                                   # flood the room itself
        x, y = stack.pop()
        if not ok(x, y):
            continue
        room.append((x, y))
        for dx, dy in ((STEP, 0), (-STEP, 0), (0, STEP), (0, -STEP)):
            n = (x + dx, y + dy)
            if n not in seen and -640 <= n[0] <= 224 and -3520 <= n[1] <= -2944:
                seen.add(n); stack.append(n)
    into = [(x, y) for x in range(256, 1216, STEP) for y in range(-3616, -3008, STEP)
            if ok(x, y)]
    g = {'in': [(x, y, a) for (x, y) in sorted(room) for a in ANGLES],
         'into': [(x, y, a) for (x, y) in into for a in ANGLES]}
    json.dump(g, open(out, 'w'))
    print(f'grid: {len(room)} room + {len(into)} approach points, '
          f'{len(g["in"]) + len(g["into"])} poses')


def measure(wad, tag, grid, out):
    if wad != '-':
        os.environ['DOOM_ALT_WAD'] = wad
    dw = _dw()
    from banked_bsp import BankedBspRender
    import pyref_render
    from bsp_render_6502 import disable_objects
    from symmap import sym
    g = json.load(open(grid))
    poses = [('in', tuple(p)) for p in g['in']] + [('into', tuple(p)) for p in g['into']]
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    disable_objects(r.sc.mpu.memory)               # VERIFY FIRST, objects off
    sample = poses[::max(1, len(poses) // 60)]
    bad = []
    for _g, (x, y, ab) in sample:
        r.render_frame(x, y, ab, dw.player_floor(x, y))
        fb = bytes(r.sc.mpu.memory[0x5800:0x6C00])
        ref, _ = pyref_render.render_ref_fb(x, y, ab)
        nd = sum(1 for p, q in zip(fb, ref) if p != q)
        if nd > 8:                                 # seam-wobble tolerance
            bad.append((x, y, ab, nd))
    print(f'VERIFY [{tag}] {len(sample)} sampled, {len(bad)} over tolerance')
    for b in bad[:10]:
        print(f'  VERIFY FAIL ({b[0]},{b[1]},{b[2]}): {b[3]} FB bytes differ')
    L = dw.packed_layout                           # objects back on to measure
    anyb = sym('OBJ_ANYB', banked=1); bits = L['off_obj'] + 7 * L['n_obj']
    for i in range(L['obj_bits_len']):
        r.sc.mpu.memory[anyb + i] = dw.packed_rom_main[bits + i]
    res = []; t0 = time.time()
    for i, (grp, (x, y, ab)) in enumerate(poses):
        res.append([grp, x, y, ab, r.render_frame(x, y, ab, dw.player_floor(x, y))])
        if i % 500 == 0:
            print(f'  {tag} {i}/{len(poses)} ({time.time() - t0:.0f}s)', flush=True)
    json.dump({'tag': tag, 'verify_sampled': len(sample), 'verify_bad': bad,
               'ss': L['n_ss'], 'nodes': L['n_nodes'], 'poses': res}, open(out, 'w'))
    tot = sum(p[4] for p in res)
    print(f'DONE [{tag}] {len(res)} poses TOTAL {tot:,} MEAN {tot // len(res):,} '
          f'({L["n_ss"]} ss / {L["n_nodes"]} nodes)')


def compare(fa, fb):
    a, b = json.load(open(fa)), json.load(open(fb))
    A = {tuple(p[:4]): p[4] for p in a['poses']}
    B = {tuple(p[:4]): p[4] for p in b['poses']}
    keys = sorted(set(A) & set(B))
    print(f"{a['tag']} ({a['ss']} ss/{a['nodes']} nodes) vs "
          f"{b['tag']} ({b['ss']} ss/{b['nodes']} nodes); "
          f"verify bad {len(a['verify_bad'])}/{len(b['verify_bad'])}")

    def block(label, ks):
        if not ks:
            return
        ta, tb = sum(A[k] for k in ks), sum(B[k] for k in ks)
        d = [B[k] - A[k] for k in ks]
        rel = sorted(100.0 * (B[k] - A[k]) / A[k] for k in ks)
        imp = sum(1 for v in d if v < 0)
        print(f'-- {label}: n={len(ks)}  {ta:,} -> {tb:,}  {100 * (tb - ta) / ta:+.3f}%  '
              f'improved {100 * imp / len(ks):.0f}%  median {statistics.median(rel):+.3f}%')
        print(f'   max frame {max(A[k] for k in ks):,} -> {max(B[k] for k in ks):,}   '
              f'p1 {rel[len(rel) // 100]:+.2f}%  p99 {rel[min(len(rel) - 1, 99 * len(rel) // 100)]:+.2f}%')
    block('ALL', keys)
    for grp in ('in', 'into'):
        block(f'{grp.upper()} region', [k for k in keys if k[0] == grp])
    block('HOTTEST 10%', sorted(keys, key=lambda k: -A[k])[:len(keys) // 10])
    # paired bootstrap on the aggregate percentage
    random.seed(7); n = len(keys); d = [B[k] - A[k] for k in keys]; reps = []
    for _ in range(2000):
        s = [random.randrange(n) for _ in range(n)]
        reps.append(100.0 * sum(d[i] for i in s) / sum(A[keys[i]] for i in s))
    reps.sort()
    print(f'bootstrap 2000x: 95% CI [{reps[50]:+.3f}%, {reps[1949]:+.3f}%]  '
          f'P(better) {100 * sum(1 for v in reps if v < 0) / len(reps):.1f}%')
    pos = collections.defaultdict(lambda: [0, 0])
    for k in keys:
        p = pos[k[:3]]; p[0] += A[k]; p[1] += B[k]
    imp = sum(1 for v in pos.values() if v[1] < v[0])
    print(f'per POSITION (all 8 dirs summed): {imp}/{len(pos)} improve '
          f'({100 * imp / len(pos):.1f}%)')


if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'grid':
        build_grid(sys.argv[2], (int(sys.argv[3]), int(sys.argv[4])) if len(sys.argv) > 4 else ARMOUR)
    elif cmd == 'measure':
        measure(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif cmd == 'compare':
        compare(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
