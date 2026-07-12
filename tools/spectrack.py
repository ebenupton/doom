#!/usr/bin/env python3
"""spectrack — find UNCONDITIONAL computation whose results are only
CONDITIONALLY consumed (speculation), plus fully-wasted subroutine calls.

The class this hunts: the pre-deferral Y projections — computed for every
front-facing seg, thrown away whenever has_gap culled it. The dead-write
tracker cannot see these (the slots are read on OTHER executions); this
tool tracks liveness PER VALUE INSTANCE and aggregates per producer.

Model (py65 step loop over render_frame, flat build):
  - A JSR pushes an INVOCATION (target, inclusive-cycle start); RTS pops.
  - Every RAM write is an OUTPUT INSTANCE of the innermost invocation.
  - A read of a live instance from a DIFFERENT invocation marks the
    producer invocation USEFUL (self-reads are scratch, not results).
    Framebuffer writes count as useful immediately (terminal product).
  - Overwrite kills an instance.
Reports:
  A. routines ranked by cycles spent in invocations with ZERO consumed
     outputs (candidates for call-site gating / deferral);
  B. write sites whose instances die unread 5-95% of the time
     (speculation band — staged values only sometimes consumed).
KNOWN NOISE CLASSES (triaged 2026-07-12 — check before believing):
  - REG-CONTRACT returns (A/Y/Z results: is_full, has_gap verdicts,
    umul prod-hi, interp_store, udiv quotient) are invisible to memory
    tracking -> false 'wasted'. Check the register consumers first.
  - SMC patches (rns_select -> rns_go+1, frame hooks): the patched
    byte is consumed by an operand FETCH, which the tracker must
    ignore for its own addressing -> SMC writers look 100% dead.
  - Cache/coherence writes (hg cache, D-cache, VWHC keys) are
    cross-frame value stores; single-frame flush marks the last
    frame's tail dead.
  - Span-pool mutation credit is unreliable (mark_solid/tg_append
    show wasted despite live consumers) — suspected cause: node
    fields rewritten by later pool ops before the reader arrives;
    refine before trusting clipper-side verdicts.
FINDS LANDED (2026-07-12): ev_clamp_evy16 88% no-op -> call-site
inline; apv_stage off-screen gate -> as_one head; ap_edges 28-cycle
no-op call -> AND #$41 gate at the call site; view-x saves deferred
past the near-clip verdict. OPEN LEADS (parent-attributed): px's
frac*M8 mul never reads prod_lo (a dup-tail SC_UMUL8_HI variant would
save ~3/call, ~270/frame — marginal); emit_vert_sx1/2 ~35% of vertical
DCL walks clip to nothing (~5k/frame warm, no pre-test cheaper than
the walk found yet). umul_round_div/interp/tighten 'waste' is A-return
noise.
Usage: python3 tools/spectrack.py [n_positions] [warm]
  warm: fixed-angle walk sequence, VXC+RCACHE+D enabled, warmup skipped.
"""
import os, sys, bisect, collections
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
os.chdir(os.path.join(os.path.dirname(__file__), '..'))
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
from symmap import sym, _load

POSITIONS = [(1056, -3616, 64), (845, -3084, 215), (800, -3400, 96),
             (1056, -3328, 14), (1308, -3289, 252)]

table, _ = _load(banked=0)
_syms = sorted((v, k) for k, v in table.items() if 0x200 <= v <= 0xFFFF)
_addrs = [a for a, _ in _syms]

def attr(pc):
    i = bisect.bisect_right(_addrs, pc) - 1
    if i < 0: return f"${pc:04X}"
    base, nm = _syms[i]
    return f"{nm}+{pc-base}" if pc != base else nm

FB_LO, FB_HI = 0x5800, 0x6C00

class Tracker(list):
    def __init__(self, base):
        super().__init__(base)
        self.armed = False
        self.pc = 0
        self.cycles = lambda: 0
        # invocation stack: [id]; inv data keyed by id
        self.inv_stack = [0]
        self.inv_seq = 0
        self.inv_target = {0: 'TOP'}
        self.inv_start = {0: 0}
        self.inv_useful = {0: True}
        self.inv_cycles = collections.Counter()   # inclusive, finalized
        self.inv_wasted = collections.Counter()
        self.inv_count = collections.Counter()
        self.inv_wcount = collections.Counter()
        self.pending = {}                          # addr -> (inv_id, site_pc)
        self.inv_closed = {}                       # popped, awaiting verdict
        self.site_dead = collections.Counter()
        self.site_live = collections.Counter()

    def push(self, target):
        self.inv_seq += 1
        i = self.inv_seq
        parent = self.inv_stack[-1]
        self.inv_stack.append(i)
        self.inv_target[i] = target + ' <- ' + self.inv_target.get(parent, '?').split(' <- ')[0]
        self.inv_start[i] = self.cycles()
        self.inv_useful[i] = False
        return i

    def pop(self):
        if len(self.inv_stack) <= 1: return
        i = self.inv_stack.pop()
        t = self.inv_target.pop(i)
        cyc = self.cycles() - self.inv_start.pop(i)
        self.inv_cycles[t] += cyc
        self.inv_count[t] += 1
        # verdict DEFERRED: results are usually consumed after the
        # producer returns — credit arrives via reads until frame flush
        if not self.inv_useful.pop(i):
            self.inv_closed[i] = (t, cyc)

    def __getitem__(self, i):
        if self.armed and type(i) is int and not (self.pc <= i <= self.pc + 2):
            p = self.pending.pop(i, None)
            if p is not None:
                inv, site = p
                cur = self.inv_stack[-1]
                if inv != cur:
                    if inv in self.inv_useful:
                        self.inv_useful[inv] = True
                    elif inv in self.inv_closed:      # post-return credit
                        self.inv_closed.pop(inv)
                    self.site_live[site] += 1
                else:
                    # self-read: scratch; re-arm the instance so a LATER
                    # external read still counts
                    self.pending[i] = p
        return list.__getitem__(self, i)

    def __setitem__(self, i, v):
        if self.armed and type(i) is int:
            if FB_LO <= i < FB_HI:
                cur = self.inv_stack[-1]
                if cur in self.inv_useful: self.inv_useful[cur] = True
            elif i < 0x0100 or i >= 0x0200:        # skip HW stack
                old = self.pending.get(i)
                if old is not None:
                    self.site_dead[old[1]] += 1
                self.pending[i] = (self.inv_stack[-1], self.pc)
        return list.__setitem__(self, i, v)

    def flush(self):
        for inv, site in self.pending.values():
            self.site_dead[site] += 1
        self.pending.clear()
        for i, (t, cyc) in self.inv_closed.items():
            self.inv_wasted[t] += cyc
            self.inv_wcount[t] += 1
        self.inv_closed.clear()


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else len(POSITIONS)
    args = (dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
            dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    r = BspRender6502(*args)
    sc = r.sc
    m = Tracker(sc.mpu.memory)
    sc.mpu.memory = m
    RF = sym('jt_br_render_frame')
    orig = sc._run

    def run(entry, max_cycles=30_000_000):
        if entry != RF:
            return orig(entry, max_cycles)
        mpu = sc.mpu
        mpu.pc = entry; mpu.sp = 0xFD; mpu.p = 0x30
        m[0x01FF] = 0xFE; m[0x01FE] = 0xFF
        m.cycles = lambda: mpu.processorCycles
        m.armed = getattr(m, 'arm_next', True)
        depth0 = len(m.inv_stack)
        for _ in range(15_000_000):
            if mpu.pc == 0xFF00: break
            m.pc = mpu.pc
            op = list.__getitem__(m, mpu.pc)
            if op == 0x20:                                    # JSR
                tgt = (list.__getitem__(m, mpu.pc + 1)
                       | (list.__getitem__(m, mpu.pc + 2) << 8))
                m.push(attr(tgt))
            elif op == 0x60:                                  # RTS
                m.pop()
            mpu.step()
        m.armed = False
        while len(m.inv_stack) > depth0: m.pop()
        return mpu.processorCycles

    sc._run = run
    warm = len(sys.argv) > 2 and sys.argv[2] == 'warm'
    if warm:
        # fixed-angle walk with all three coherence caches enabled (the
        # flat build honors the enable bytes); track from frame 4 on so
        # VXC/RCACHE/D and the VWHC are genuinely warm.
        import abi, pygame as pg
        mem = sc.mpu.memory
        list.__setitem__(m, abi.D_ENABLE, 1)
        list.__setitem__(m, abi.VXC_ENABLE, 1)
        list.__setitem__(m, sym('RCACHE_ENABLE'), 1)
        D_FWD = sym('D_FWD')
        px, py, ab = 1056.0, -3616.0, 65
        for k in range(4 + n):
            if k >= 4: m.arm_next = True
            v = pg.math.Vector2(1, 0).rotate(ab * 360 / 256)
            px, py = px + v.x * 8.0, py + v.y * 8.0
            list.__setitem__(m, D_FWD, 1)
            r.render_frame(int(px), int(py), ab, dw.player_floor(int(px), int(py)))
            m.flush()
    else:
        for px, py, ab in POSITIONS[:n]:
            r.render_frame(px, py, ab, dw.player_floor(px, py))
            m.flush()

    print(f"== A. wasted invocations (zero externally-consumed outputs), {n} frames ==")
    print(f"{'routine':34s} {'calls':>6s} {'wasted':>7s} {'w%':>5s} {'wasted cyc':>10s}")
    rows = sorted(m.inv_wasted.items(), key=lambda kv: -kv[1])
    for t, wc in rows[:22]:
        c, w = m.inv_count[t], m.inv_wcount[t]
        print(f"{t:34s} {c:6d} {w:7d} {100*w//max(1,c):4d}% {wc:10d}")
    print(f"\n== B. speculation-band write sites (5-95% of instances die) ==")
    print(f"{'site':40s} {'dead':>6s} {'live':>6s} {'dead%':>6s}")
    rows = []
    for site in set(m.site_dead) | set(m.site_live):
        d, l = m.site_dead[site], m.site_live[site]
        tot = d + l
        if tot >= 40 and 0.05 <= d / tot <= 0.95:
            rows.append((d, l, site))
    rows.sort(reverse=True)
    for d, l, site in rows[:22]:
        print(f"{attr(site):40s} {d:6d} {l:6d} {100*d//(d+l):5d}%")

if __name__ == '__main__':
    main()
