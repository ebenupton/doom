#!/usr/bin/env python3
"""D-cache (forward-coherence bbox cache) bench — FIELD-SCALED kinematics.

Scenarios:
  armour (default) — the priority path: spawn room -> bent western
                     hallway -> armour room, dwell, u-turn, walk back.
  views            — cachebench's four forward-walk views (arrive
                     pristine, walk forward VIEWS_DIST units).
  corpus           — GAME-EXACT walks via colmap.move_frame from pm_fuzz's
                     standable starts (spawn + 40 u off every 6th port),
                     two headings each: hold forward, then turn.

Kinematics mirror pmove (2026-09-03 rewrite; the old rig moved a FIXED
12 units per frame, a dead walk_drv constant): the shipped engine moves
PF_MOVE[fields] = fields x 143/32 units per frame along the quantized
view heading, where fields = PAL fields elapsed since the last frame =
ceil(frame cycles / 39,936), clamped 1..10.  The cached engine's own
frame time drives the stride (it IS the shipped engine), so the walk's
stride is ~27-36 units in these scenes, not 12.  Turns are PF_TURN =
90/256 steps of 4 angle-bytes per field with the fraction carried
(PM_TURNREM).  --stride N restores a fixed stride (N units per frame,
one 4-byte step per turn frame) for comparison with the old numbers.

Twin-engine method: the cached engine runs the full classifier; the
pristine twin runs D_ENABLE=0 with bca_cachepos spoiled before every
frame so every frame classifies moving-pristine.  Gate: byte-identical
framebuffers every frame (caches must never move pixels).

Options:
  --mask M        D refresh mask (default = the build's, BUILD_MASK = 7 =
                  period 8; runtime patch of the two `AND #` immediates
                  in dbox_check; 255 = wheel effectively off)
  --nostraddle    divert the STRADDLE serve arm to the refresh path
  --defs A=1,B=2  extra ca65 defines (DOOM_ASMDEFS) — builds a policy
                  VARIANT of the engine for both twins
  --overhead C    non-render cycles per frame added before the field
                  count (driver, pmove, hud; default 0)
  --trace FILE    pickle per-check traces (both twins) for dtrace.py
"""
import os, sys, math, argparse, pickle
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

ap = argparse.ArgumentParser()
ap.add_argument('scenario', nargs='?', default='armour', choices=['armour', 'views', 'corpus'])
ap.add_argument('--mask', type=int, default=None)
ap.add_argument('--nostraddle', action='store_true')
ap.add_argument('--defs', default='')
ap.add_argument('--stride', type=float, default=None)
ap.add_argument('--overhead', type=int, default=0)
ap.add_argument('--trace', default=None)
ap.add_argument('--verbose', action='store_true', help='per-frame lines')
ap.add_argument('--anim', action='store_true',
                help='run anim_init once and anim_tick every frame on BOTH twins '
                     '(movers cycle as on the disc; ANIM_FIELDS = the fields moved)')
ap.add_argument('--dfwd-fields', action='store_true',
                help='write the field count (not 1) into D_FWD on forward frames')
ARGS = ap.parse_args()
if ARGS.defs:
    os.environ['DOOM_ASMDEFS'] = ARGS.defs      # before the engine imports build
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init()
import doom_wireframe as dw
from banked_bsp import BankedBspRender
from symmap import sym

FIELD_CYCLES = 39936            # 19,968 us PAL field at 2 MHz
FIELD_UNITS = 143 / 32          # PF_MOVE[1]: 80% of DOOM's 8 u/tic, per field
FIELD_TURN_Q8 = 90              # PF_TURN[1]: Q8 steps (of 4 angle-bytes) per field
PM_FCAP = 10
WAYPOINTS = [(1056, -3616), (704, -3488), (448, -3392), (256, -3300),
             (-224, -3232)]
VIEW_LOCS = [(0xFFEE72, 0xFFDCBA, 0x3C), (0x002E29, 0x005EEB, 0x04),
             (0x00DF9A, 0x003CC8, 0xCC), (0x00B636, 0x0002E9, 0x88)]
VIEWS_DIST = 256

D_ENABLE = sym('D_ENABLE', banked=1)
D_FWD = sym('D_FWD', banked=1)
CACHEPOS = sym('bca_cachepos', banked=1)
ZBV = sym('zp_bv_entry', banked=1)
CLASSES = {sym('dbox_check', banked=1) & 0xFF: 'D',
           sym('box_classify', banked=1) & 0xFF: 'prist',
           sym('bbox_check_angle', banked=1) & 0xFF: 'rcache'}
BANK_STATE = 7                  # bca memo/state bank (walk group)


def quant_ab(dx, dy):
    ab = round(math.atan2(dy, dx) / (2 * math.pi) * 256 / 4) * 4
    return ab & 0xFF


class Mover:
    """pmove's field-scaled kinematics.  `fields(c)` = PAL fields a frame
    of c cycles occupies; the NEXT frame's motion is scaled by it."""
    def __init__(self, stride=None, overhead=0):
        self.stride = stride
        self.overhead = overhead
        self.turnrem = 0
        self.hist = {}

    def fields(self, cycles):
        f = max(1, min(PM_FCAP, -(-(cycles + self.overhead) // FIELD_CYCLES)))
        self.hist[f] = self.hist.get(f, 0) + 1
        return f

    def step_len(self, cycles):
        if self.stride is not None:
            return self.stride
        return self.fields(cycles) * FIELD_UNITS

    def turn_steps(self, cycles):
        if self.stride is not None:
            return 1
        t = FIELD_TURN_Q8 * self.fields(cycles) + self.turnrem
        self.turnrem = t & 0xFF
        return t >> 8


def armour_script(mover):
    """Generator of (phase, px, py, ab, fwd); receives the cached engine's
    cycle count for the frame just rendered (drives the next stride)."""
    cyc = None

    def emit(frame):
        nonlocal cyc
        cyc = yield frame

    def turn_to(px, py, ab_from, ab_to, phase):
        ab = ab_from
        while ab != ab_to:
            d = (ab_to - ab) & 0xFF
            n = mover.turn_steps(cyc)
            for _ in range(n):
                if ab == ab_to:
                    break
                ab = (ab + (4 if d < 128 else -4)) & 0xFF
            yield from emit((phase, px, py, ab, 0))
        return ab

    def legs(points, phase):
        px, py = points[0]
        ab = None
        for (tx, ty) in points[1:]:
            want = quant_ab(tx - px, ty - py)
            if ab is None:
                ab = want
                yield from emit((phase, px, py, ab, 0))     # arrival pose
            else:
                ab = yield from turn_to(px, py, ab, want, phase + '-turn')
            vx = math.cos(ab * 2 * math.pi / 256)
            vy = math.sin(ab * 2 * math.pi / 256)
            while True:
                s = mover.step_len(cyc)
                if (tx - px) * vx + (ty - py) * vy < s / 2:   # progress along
                    break                                     # the heading
                px, py = px + vx * s, py + vy * s
                yield from emit((phase, px, py, ab, 1))
        return px, py, ab

    px, py, ab = yield from legs(WAYPOINTS, 'in')
    for _ in range(6):
        yield from emit(('dwell', px, py, ab, 0))
    ab = yield from turn_to(px, py, ab, (ab + 128) & 0xFF, 'uturn')
    yield from legs([(px, py)] + WAYPOINTS[-2::-1], 'out')


def views_script(mover):
    cyc = None

    def world(v24, center):
        s = v24 - 0x1000000 if v24 & 0x800000 else v24
        return center + (s / 256.0) * dw.PRESCALE

    for (x24, y24, ab) in VIEW_LOCS:
        px, py = world(x24, dw.MAP_CENTER_X), world(y24, dw.MAP_CENTER_Y)
        phase = f'{x24:06X}.{ab:02X}'
        vx = math.cos(ab * 2 * math.pi / 256)
        vy = math.sin(ab * 2 * math.pi / 256)
        cyc = yield (phase + ' seed', px, py, ab, 0)          # arrive pristine
        dist = 0.0
        first = True
        while dist < VIEWS_DIST:
            s = mover.step_len(cyc)
            px, py, dist = px + vx * s, py + vy * s, dist + s
            cyc = yield (phase + (' seed' if first else ''), px, py, ab, 1)
            first = False


CORPUS_HOLD = 14                 # forward frames per start x heading
CORPUS_TURN = 4                  # then a left-turn tail (rcache class)


def corpus_script(mover):
    """GAME-EXACT walks: colmap.move_frame (the pmove mirror: chunked
    collision, wall slide, d_fwd) drives the player from pm_fuzz's
    standable starts (spawn + a point 40 u off every 6th port), two
    headings each, holding forward CORPUS_HOLD frames at the engine's
    own field-scaled speed, then CORPUS_TURN turn frames.  D_FWD comes
    from move_frame exactly as the driver would set it (a slide clears
    it).  Positions are 8.8 prescaled centre-relative (px88 = raw*32)."""
    import colmap, anim_sectors as an
    m = colmap.build()
    rest = [dw._prescale_height(an.MOVERS[s].closed if an.MOVERS[s].kind == 'ceil'
                                else an.MOVERS[s].top) & 0xFF
            for s in sorted(dw.ANIM_SECTORS)]
    cands = [(1056 - dw.MAP_CENTER_X, -3616 - dw.MAP_CENTER_Y)]
    for p in m['ports'][::3]:
        x1, y1, dx, dy = p[:4]
        ln = math.hypot(dx, dy) or 1
        cands.append((int(round(x1 + dx * 0.5 - dy / ln * 40)),
                      int(round(y1 + dy * 0.5 + dx / ln * 40))))
    starts = []
    for rx, ry in cands:
        try:
            ss = colmap.find_ss(rx, ry)
        except Exception:
            continue
        vz = m['ss_vz'][ss]
        vz -= 256 if vz >= 128 else 0
        if colmap.try_move(rx, ry, rx, ry, vz, rest)[0]:
            starts.append((rx * 32, ry * 32, vz))
    def free_run(rx, ry, vz, ang):
        """units of straight walking before try_move blocks (16-u probes)"""
        cw, cn, sw, sn = colmap._unit5(ang)
        ux = (-cw if cn else cw) / 32.0
        uy = (-sw if sn else sw) / 32.0
        x, y, z, d = rx, ry, vz, 0
        while d < 480:
            nx, ny = int(round(x + ux * 16)), int(round(y + uy * 16))
            ok, z2 = colmap.try_move(int(round(x)), int(round(y)), nx, ny, z, rest)
            if not ok:
                break
            x, y, z, d = nx, ny, z2, d + 16
        return d
    cyc = None
    for si, (px88, py88, vz) in enumerate(starts):
        runs = sorted(((free_run(px88 // 32, py88 // 32, vz, a), a)
                       for a in range(0, 64, 4)), reverse=True)
        heads = [a for d, a in runs[:2] if d >= 96]     # the two longest open headings
        for ang in heads:
            st = (px88, py88, vz, ang, 0)
            phase = f'c{si:02d}.{ang:02d}'
            wx = lambda s: dw.MAP_CENTER_X + s[0] / 32.0
            wy = lambda s: dw.MAP_CENTER_Y + s[1] / 32.0
            cyc = yield (phase + ' seed', wx(st), wy(st), (st[3] * 4) & 0xFF, 0)
            for k in range(CORPUS_HOLD + CORPUS_TURN):
                f = mover.fields(cyc)
                fwd = k < CORPUS_HOLD
                nst = colmap.move_frame(st[0], st[1], st[2], st[3], st[4], f,
                                        fwd, False, not fwd, False, rest)
                if fwd and nst[:2] == st[:2]:
                    break                                   # boxed in
                st, d_fwd = nst[:5], nst[5]
                cyc = yield (phase, wx(st), wy(st), (st[3] * 4) & 0xFF, d_fwd)


def mkeng():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main,
                        dw.packed_rom_detail, dw.packed_bbox_table,
                        dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    mem = r.sc.mpu.memory
    anyb = sym('OBJ_ANYB', banked=1)
    bits = dw.packed_layout['off_obj'] + 7 * dw.packed_layout['n_obj']
    for i in range(dw.packed_layout['obj_bits_len']):
        mem[anyb + i] = dw.packed_rom_main[bits + i]
    return r


def find_mask_sites(mem):
    lo, hi = sym('bca_dfrm', banked=1) & 0xFF, sym('bca_dfrm', banked=1) >> 8
    base = sym('dbox_check', banked=1)
    return [a for a in range(base, base + 0x400)
            if mem[a] == 0x6D and mem[a + 1] == lo and mem[a + 2] == hi
            and mem[a + 3] == 0x29]


def patch_straddle_recompute(mem):
    """Overwrite each side's straddle serve arm (after `CMP #132 / BCS`)
    with JMP <that side's refresh path> (the BEQ target at the refresh
    mask site).  X still holds the valid byte there — the fresh path's
    only register contract."""
    done = 0
    for a in find_mask_sites(mem):
        assert mem[a + 5] == 0xF0
        fresh = a + 7 + (mem[a + 6] ^ 0x80) - 0x80
        for b in range(a, a + 0x40):
            if mem[b] == 0xC9 and mem[b + 1] == 132 and mem[b + 2] == 0xB0:
                st = b + 4
                mem[st] = 0x4C
                mem[st + 1] = fresh & 0xFF
                mem[st + 2] = fresh >> 8
                done += 1
                break
    assert done == 2, f'patched {done} straddle arms, expected 2'


def straddle_pcs(mem):
    out = []
    for a in find_mask_sites(mem):
        for b in range(a, a + 0x40):
            if mem[b] == 0xC9 and mem[b + 1] == 132 and mem[b + 2] == 0xB0:
                out.append(b + 4)
                break
    return out


BUILD_MASK = 7                  # the shipped refresh mask (dbox_check AND #7)


def patch_refresh_mask(mem, mask):
    """Patch the two `ADC bca_dfrm / AND #mask` immediates in dbox_check."""
    save = mem[0xFE30]
    mem.select(BANK_STATE)
    sites = find_mask_sites(mem)
    for a in sites:
        assert mem[a + 4] == BUILD_MASK, f'unexpected mask at ${a+4:04X}: {mem[a+4]}'
        mem[a + 4] = mask
    mem.select(save)
    assert len(sites) == 2, f'expected 2 refresh-mask sites, found {len(sites)}'


def spoil(mem):
    save = mem[0xFE30]
    mem.select(BANK_STATE)
    mem[CACHEPOS] = (mem[CACHEPOS] + 1) & 0xFF
    mem.select(save)


# ------------------------------------------------------------------ trace --
class Tracer:
    """Step-loop replacement for render_frame: records every bbox check
    (node, side, path, ilo, ihi, verdict, check cycles) and, for
    descents, the subtree's cycles, the number of segs that passed
    has_gap under it, and n/f = near/far site (far = tail call).  Paths: prist (box_classify), inv (served
    invisible), L/R/S (served left/right/straddle extent), miss, fresh."""
    def __init__(self, sc):
        self.sc = sc
        mem = sc.mpu.memory
        s = lambda n: sym(n, banked=1)
        self.E = s('bbox_visible')
        self.ZN, self.ZS = s('zp_node_ch_l'), s('zp_bbox_side')
        self.ILO = s('bca_ilo')
        self.HG = s('span_has_gap')
        self.DRAW = s('hgp_fwd')
        self.NEAR_RET = {s('r0_far'), s('r1_far')}
        paths = {s('dcv_invis'): 'inv', s('dcap_s0_miss'): 'miss',
                 s('dcap_s1_miss'): 'miss', s('dcap_s0_fresh'): 'fresh',
                 s('dcap_s1_fresh'): 'fresh', s('dcv_left_0'): 'L',
                 s('dcv_left_1'): 'L', s('dcv_right_0'): 'R',
                 s('dcv_right_1'): 'R', s('bcls_s0'): 'prist',
                 s('bcls_s1'): 'prist'}
        for pc in straddle_pcs(mem):
            paths[pc] = 'S'
        self.PATHS = paths
        self.checks = []

    def run(self, entry, max_cycles=3_000_000):
        sc = self.sc
        mpu, mem = sc.mpu, sc.mpu.memory
        mpu.pc = entry
        mpu.sp = 0xDD
        mpu.p = 0x30
        mem[0x01DF] = 0xFE
        mem[0x01DE] = 0xFF
        mpu.processorCycles = 0
        checks = self.checks = []
        E, ZN, ZS, ILO, HG, DRAW = (self.E, self.ZN, self.ZS, self.ILO,
                                    self.HG, self.DRAW)
        PATHS, NEAR_RET = self.PATHS, self.NEAR_RET
        cur = None                  # open check: [node, side, path, ilo, ihi, c0, sp0]
        stack = []                  # open descents: [check_idx, sp_ret, c0, d0]
        draws = 0
        for _ in range(max_cycles):
            pc = mpu.pc
            if pc == 0xFF00:
                break
            sp = mpu.sp
            while stack:
                top = stack[-1]
                if sp > top[1] or (sp == top[1] and pc in NEAR_RET):
                    rec = checks[top[0]]
                    rec[7] = mpu.processorCycles - top[2]
                    rec[8] = draws - top[3]
                    rec[9] = 'n' if sp == top[1] else 'f'
                    stack.pop()
                else:
                    break
            if cur is None:
                if pc == E:
                    cur = [mem[ZN], mem[ZS], '?', -1, -1, mpu.processorCycles, sp]
                elif pc == DRAW:
                    draws += 1
            else:
                if pc in PATHS:
                    if cur[2] == '?':
                        cur[2] = PATHS[pc]
                elif pc == HG:
                    cur[3], cur[4] = mem[ILO], mpu.a
                elif sp > cur[6] + 1:
                    v = mpu.p & 1
                    node, side, path, ilo, ihi, c0, sp0 = cur
                    checks.append([node, side, path, ilo, ihi, v,
                                   mpu.processorCycles - c0, 0, 0, '-'])
                    if v:
                        stack.append([len(checks) - 1, sp0 + 2,
                                      mpu.processorCycles, draws])
                    cur = None
            mpu.step()
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += mpu.processorCycles
        return mpu.processorCycles


def hook_tracer(r):
    t = Tracer(r.sc)
    rf = sym('render_frame', banked=1)
    old = r.sc._run
    def hooked(entry, max_cycles=500000):
        if entry == rf:
            return t.run(entry)
        return old(entry, max_cycles)
    r.sc._run = hooked
    return t


def main():
    frames_script = {'armour': armour_script, 'views': views_script,
                     'corpus': corpus_script}[ARGS.scenario]
    mover = Mover(ARGS.stride, ARGS.overhead)
    eng, prs = mkeng(), mkeng()
    mem, pmem = eng.sc.mpu.memory, prs.sc.mpu.memory
    mem[D_ENABLE] = 1
    pmem[D_ENABLE] = 0
    if ARGS.mask is not None and ARGS.mask != BUILD_MASK:
        patch_refresh_mask(mem, ARGS.mask)
        patch_refresh_mask(pmem, ARGS.mask)      # twin never probes; parity anyway
    if ARGS.nostraddle:
        patch_straddle_recompute(mem)
    ANIM_FIELDS = sym('ANIM_FIELDS', banked=1)
    ANIM_INIT, ANIM_TICK = sym('anim_init', banked=1), sym('anim_tick', banked=1)
    def anim(r, entry):
        m = r.sc.mpu.memory; save = m[0xFE30]; m.select(BANK_STATE)
        r.sc._run(entry); m.select(save)
    if ARGS.anim:
        for r in (eng, prs):
            anim(r, ANIM_INIT)
    tracers = None
    if ARGS.trace:
        tracers = (hook_tracer(eng), hook_tracer(prs))
        traces = []

    def fb(r):
        m = r.sc.mpu.memory
        return bytes(m[0x5800 + i] for i in range(5120))

    from collections import defaultdict
    agg = defaultdict(lambda: [0, 0, 0, defaultdict(int), 0, 0])   # phase -> [n, cyc, pcyc, classes, fields, pfields]
    fld = lambda c: -(-c // FIELD_CYCLES)       # PAL fields the frame occupies (uncapped)
    order = []
    bad = 0
    gen = frames_script(mover)
    cyc = None
    dist = 0.0
    last = None
    i = 0
    while True:
        try:
            phase, px, py, ab, fwd = gen.send(cyc)
        except StopIteration:
            break
        mem[D_FWD] = (mover.fields(cyc) if (ARGS.dfwd_fields and fwd and cyc) else fwd)
        if ARGS.anim:                       # movers advance identically on both twins
            f = mover.fields(cyc) if cyc else 1
            for r in (eng, prs):
                r.sc.mpu.memory[ANIM_FIELDS] = f
                anim(r, ANIM_TICK)
        try:
            fz = dw.player_floor(px, py)
        except Exception:
            print(f'  frame {i} {phase}: no floor at ({px:.0f},{py:.0f}) — stopping')
            break
        cyc = eng.render_frame(px, py, ab, fz)
        spoil(pmem)
        p = prs.render_frame(px, py, ab, fz)
        if fb(eng) != fb(prs):
            bad += 1
            print(f'  FB MISMATCH frame {i} {phase} ({px:.0f},{py:.0f},{ab})')
        if tracers:
            traces.append((phase, px, py, ab, fwd, cyc, p,
                           tracers[0].checks, tracers[1].checks))
        cls = CLASSES.get(mem[ZBV], '?')
        if phase not in agg:
            order.append(phase)
        a = agg[phase]
        a[0] += 1; a[1] += cyc; a[2] += p; a[3][cls] += 1
        a[4] += fld(cyc); a[5] += fld(p)
        if ARGS.verbose:
            print(f'  {i:4d} {phase:12s} ({px:7.1f},{py:7.1f}) ab={ab:3d} fwd={fwd} '
                  f'{cyc:7d} {p:7d} f={fld(cyc):2d}/{fld(p):2d} {cls}')
        if last and fwd:
            dist += math.hypot(px - last[0], py - last[1])
        last = (px, py)
        i += 1
    print(f'{"phase":16s} {"n":>4s} {"cached":>9s} {"pristine":>9s} '
          f'{"save":>6s} {"fields":>6s} {"pfield":>6s} {"fsave":>6s}  classes')
    tot = [0, 0, 0, 0, 0]
    for phase in order:
        n, c, p, cl, f, pf = agg[phase]
        if not phase.endswith(' seed'):
            tot[0] += n; tot[1] += c; tot[2] += p; tot[3] += f; tot[4] += pf
        print(f'{phase:16s} {n:4d} {c/n:9.0f} {p/n:9.0f} '
              f'{100*(p-c)/p:5.1f}% {f:6d} {pf:6d} {100*(pf-f)/max(1,pf):5.1f}%  {dict(cl)}')
    print(f'{"TOTAL":16s} {tot[0]:4d} {tot[1]/tot[0]:9.0f} {tot[2]/tot[0]:9.0f} '
          f'{100*(tot[2]-tot[1])/tot[2]:5.1f}% {tot[3]:6d} {tot[4]:6d} '
          f'{100*(tot[4]-tot[3])/max(1,tot[4]):5.1f}%')
    print(f'sum cycles: cached {tot[1]:,} pristine {tot[2]:,}  '
          f'(fields = sum of ceil(cycles/39936) per frame, uncapped; the walk '
          f'covers a fixed distance at 4.47 u/field, so fewer fields = higher frame rate)')
    print(f'fields histogram: {dict(sorted(mover.hist.items()))}  '
          f'forward distance {dist:.0f} u')
    print('CACHE GATE:', 'PASS' if not bad else f'FAIL ({bad} frames)')
    if tracers:
        with open(ARGS.trace, 'wb') as f:
            pickle.dump({'args': vars(ARGS), 'frames': traces}, f)
        print(f'trace: {ARGS.trace} ({len(traces)} frames)')


if __name__ == '__main__':
    main()
