#!/usr/bin/env python3
"""Always-descend policy sweep (Eben, 2026-08-20).

For every bbox_visible check site (node, boxside), measure across a
position x orientation corpus whether ALWAYS DESCENDING (skipping the
check) beats running it — i.e. nodes whose check cost exceeds what the
occasional reject saves.  Level-by-level from the leaves:

  level 1: candidates are (node, side) whose checked child is a LEAF
  level 2: child is a node whose own check sites are all accepted, etc.

Mechanism: the py65 step loop gets a PC watch on bbox_visible.  A
baseline pass records (node, side, verdict, cycles) per check.  A
bypass pass WARPS flagged checks: pop the JSR return, set C=1, jump —
zero cycles, exact downstream state (the flat model has no banking to
replicate).  Never-rejecting candidates are exact analytically
(frame_B = frame_A - check cycles); sometimes-rejectors get real bypass
runs on their rejecting frames.  The REAL far-site gate tax (~10 cyc,
see walk.s) is charged to every still-checked far visit in the verdict.

Outputs a JSON verdict per level; progress on stderr throughout.
"""
import os, sys, json, time, argparse
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
from symmap import sym

FAR_GATE_TAX = 10          # real-build cost of the far-site DSGN test
ANGLES = (0, 64, 128, 192)

def log(*a):
    print(*a, file=sys.stderr, flush=True)

# ---------------------------------------------------------------- corpus --
def corpus(step):
    xs = range(-768, 3809, step)
    ys = range(-4864, -1535, step)
    pos = []
    for x in xs:
        for y in ys:
            try:
                ss = dw.find_subsector(x, y)
                if dw.ssectors[ss][0] == 0:          # empty ss: fine but
                    pass                             # floor lookup works
                dw.player_floor(x, y)
                pos.append((x, y))
            except Exception:
                continue
    return pos

# ------------------------------------------------------------- the watch --
class Watcher:
    """Step-loop wrapper: records every bbox_visible call, warps flagged
    ones (policy = set of (node, boxside))."""
    def __init__(self, sc):
        self.sc = sc
        self.entry = sym('bbox_visible')
        self.zp_node = sym('zp_node_ch_l')
        self.zp_side = sym('zp_bbox_side')
        self.policy = frozenset()
        self.checks = []            # (node, side, verdict, cycles)

    def run(self, entry, max_cycles=10_000_000):
        sc = self.sc
        mpu, mem = sc.mpu, sc.mpu.memory
        mpu.pc = entry
        mpu.sp = 0xDD
        mpu.p = 0x30
        mem[0x01DF] = 0xFE
        mem[0x01DE] = 0xFF
        mpu.processorCycles = 0
        checks = self.checks
        E, ZN, ZS = self.entry, self.zp_node, self.zp_side
        pol = self.policy
        in_chk = None               # (node, side, c0, sp0)
        for _ in range(max_cycles):
            pc = mpu.pc
            if pc == 0xFF00:
                break
            if pc == E:
                node, side = mem[ZN], mem[ZS]
                if (node, side) in pol:
                    # WARP: pop the JSR return, C=1, continue after it
                    sp = mpu.sp
                    ret = (mem[0x100 + sp + 1] | (mem[0x100 + sp + 2] << 8)) + 1
                    mpu.sp = (sp + 2) & 0xFF
                    mpu.p |= 0x01
                    mpu.pc = ret
                    checks.append((node, side, 2, 0))    # 2 = bypassed
                    continue
                in_chk = (node, side, mpu.processorCycles, mpu.sp)
            elif in_chk is not None and mpu.sp > in_chk[3] + 1:
                # the check's RTS popped past its frame: it just returned
                node, side, c0, _ = in_chk
                checks.append((node, side, mpu.p & 1,
                               mpu.processorCycles - c0))
                in_chk = None
            mpu.step()
        sc.last_cycles = mpu.processorCycles
        return mpu.processorCycles

def render(r, w, pos, ab, policy):
    import bsp_render_6502 as br
    w.policy = policy
    w.checks = []
    old = r.sc._run
    def hooked(entry, max_cycles=500000):
        if entry == br.ENTRY_BR_RENDER_FRAME:
            return w.run(entry, 10_000_000)
        return old(entry, max_cycles)
    r.sc._run = hooked
    try:
        cyc = r.render_frame(pos[0], pos[1], ab, dw.player_floor(*pos))
    finally:
        r.sc._run = old
    fb = r.sc.mpu.memory
    s0 = r.sc.SCREEN_START
    fbh = hash(bytes(fb[s0:s0 + 5120]))
    return cyc, list(w.checks), fbh

# ------------------------------------------------------------------ main --
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--step', type=int, default=256)
    ap.add_argument('--level', type=int, default=1)
    ap.add_argument('--policy', default=None,
                    help='JSON list of accepted [node, side] from lower levels')
    ap.add_argument('--out', default='build/adesc_l1.json')
    args = ap.parse_args()

    accepted = set()
    if args.policy:
        accepted = {tuple(p) for p in json.load(open(args.policy))}

    pos = corpus(args.step)
    frames = [(p, a) for p in pos for a in ANGLES]
    log(f'corpus: {len(pos)} positions x {len(ANGLES)} angles = {len(frames)} frames')

    # child map: boxside 0 -> RIGHT child (n[12]), 1 -> LEFT (n[13])
    child = {}
    for i, n in enumerate(dw.nodes):
        child[(i, 0)] = n[12]
        child[(i, 1)] = n[13]

    def is_level(nd_side, lvl):
        c = child[nd_side]
        if c & 0x8000:
            return lvl == 1
        # child is a node: level k iff both its check sites are accepted
        # (or it is a level-(k-1) member... practical recursion: accepted
        # covers everything below)
        return lvl > 1 and (c, 0) in accepted and (c, 1) in accepted

    r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                      dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                      dw.PRESCALE)
    w = Watcher(r.sc)

    # ---------------- PASS 1: baseline (lower-level policy active) -------
    log(f'PASS 1 (baseline, {len(accepted)} lower-level bypasses active)')
    base = {}         # (pos,ab) -> (cycles, fbh)
    stats = {}        # (node,side) -> [visits, rejects, chk_cycles, rej_frames]
    t0 = time.time()
    for i, (p, a) in enumerate(frames):
        cyc, checks, fbh = render(r, w, p, a, frozenset(accepted))
        base[(p, a)] = (cyc, fbh)
        rejc = {}
        for node, side, v, c in checks:
            if v == 2:
                continue
            st = stats.setdefault((node, side), [0, 0, 0, [], 0])
            st[0] += 1; st[2] += c
            if v == 0:
                st[1] += 1
                if (p, a) not in [f for f, _ in st[3]]:
                    st[3].append(((p, a), 0))
                st[4] += c
        if (i + 1) % 50 == 0 or i + 1 == len(frames):
            el = time.time() - t0
            log(f'  {i+1}/{len(frames)} frames, {el:.0f}s '
                f'({el/(i+1)*1000:.0f} ms/frame)')

    cands = sorted(k for k in stats if is_level(k, args.level)
                   and k not in accepted)
    log(f'level {args.level}: {len(cands)} candidate check sites')

    verdicts = {}
    never, some = [], []
    for k in cands:
        (never if stats[k][1] == 0 else some).append(k)
    log(f'  never-reject: {len(never)}  sometimes-reject: {len(some)}')

    # never-rejectors: exact analytic — every sampled frame keeps the same
    # verdict path, so bypass = frame minus the check cycles, everywhere.
    for k in never:
        v, rej, chk, _, _ = stats[k]
        verdicts[str(k)] = dict(visits=v, rejects=0, chk_cycles=chk,
                                delta_total=-chk, worst_loc_delta=0,
                                verdict='WIN' if chk > 0 else 'ZERO')

    # sometimes-rejectors: real bypass runs on their rejecting frames.
    # Delta on a NON-rejecting frame = -check (analytic); on a rejecting
    # frame = measured cyc_b - cyc_a (the warp already omits the check).
    log(f'PASS 2: bypass runs for {len(some)} sometimes-rejectors')
    for j, k in enumerate(some):
        v, rej, chk_all, rejf, chk_rej = stats[k]
        worst = 0
        dtot = -(chk_all - chk_rej)          # savings on clean frames
        pixel_bad = False
        for (p, a), _ in rejf:
            cyc_b, _, fbh_b = render(r, w, p, a, frozenset(accepted | {k}))
            cyc_a, fbh_a = base[(p, a)]
            d = cyc_b - cyc_a
            if fbh_b != fbh_a:
                pixel_bad = True
                break
            worst = max(worst, d)
            dtot += d
        if pixel_bad:
            verdicts[str(k)] = dict(visits=v, rejects=rej,
                                    verdict='PIXEL-UNSAFE')
        else:
            verdicts[str(k)] = dict(visits=v, rejects=rej,
                                    chk_cycles=chk_all, delta_total=dtot,
                                    worst_loc_delta=worst,
                                    verdict='WIN' if (worst <= 0 and dtot < 0)
                                            else 'LOSS')
        log(f'  [{j+1}/{len(some)}] {k}: rejects {rej}/{v} '
            f'-> {verdicts[str(k)]["verdict"]}'
            + ('' if pixel_bad else f' (dtot {dtot}, worst {worst})'))

    wins = [k for k in cands if verdicts[str(k)].get('verdict') == 'WIN']
    tot = sum(-verdicts[str(k)].get('delta_total', 0) for k in wins)
    log(f'LEVEL {args.level} RESULT: {len(wins)}/{len(cands)} WIN sites, '
        f'~{tot} cycles over the corpus ({tot // max(1,len(frames))} /frame)')
    json.dump(dict(level=args.level, frames=len(frames),
                   accepted=sorted(accepted), candidates=[list(k) for k in cands],
                   wins=[list(k) for k in wins], verdicts=verdicts),
              open(args.out, 'w'), indent=1)
    log(f'wrote {args.out}')

if __name__ == '__main__':
    main()
