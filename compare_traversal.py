"""Traversal differential: pure-6502 BSP walk vs Python BSP walk, with BOTH
sides using the 6502 seg processor and the 6502 clipper for visibility.

Because the seg processor is identical on both sides, any divergence in
the visited-subsector sequence or the has_gap(ilo,ihi) query stream is a
pure TRAVERSAL bug (bbox visibility / side test / ordering) in
br_render_frame + br_bbox_visible.

Python side: packed_render_bsp with
  - packed_render_subsector replaced by the 6502 br_render_subsector
  - a clips wrapper whose has_gap/is_full delegate to the 6502 clipper
    state (unlike Instrumented6502Spans, whose Python spans never see the
    6502 seg processor's mutations)
  - fp_bbox_visible_fixed left as the Python reference.

6502 side: br_render_frame end-to-end.
"""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp
from wad_packed import spans_init_full
import trace_compare as tc

ENTRY_BR_RENDER_SUBSECTOR = 0x4818
ENTRY_BR_INIT_FRAME       = 0x481B
ENTRY_BR_RENDER_FRAME     = 0x4815


class Asm6502Clips:
    """Visibility queries answered by the 6502 clipper itself."""
    def __init__(self, sc):
        self.sc = sc

    def has_gap(self, lo, hi):
        return self.sc.has_gap(lo, hi)

    def is_full(self):
        return self.sc.is_full()


def setup(sc, px, py, ab):
    tc.setup_wad(sc)
    tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    sc.init()
    sc.clear_screen()
    sc._run(ENTRY_BR_INIT_FRAME)


def install_tracing(sc, trace_all):
    # The BSP walk JSRs br_render_subsector's real address, not the jump
    # table — read the JMP operand at $4819 to find it.
    ss_real = (sc.mpu.memory[ENTRY_BR_RENDER_SUBSECTOR + 1]
               | (sc.mpu.memory[ENTRY_BR_RENDER_SUBSECTOR + 2] << 8))

    def traced_run(entry, max_cycles=30_000_000):
        mpu = sc.mpu
        mem = mpu.memory
        mpu.pc = entry
        mpu.sp = 0xFD
        mpu.p = 0x30
        mem[0x01FF] = 0xFE
        mem[0x01FE] = 0xFF
        mpu.processorCycles = 0
        for _ in range(max_cycles):
            if mpu.pc == 0xFF00:
                break
            pc = mpu.pc
            if pc == 0x2009:
                trace_all.append(('has_gap', mem[0xC2], mem[0xC3]))
            elif pc == ss_real:
                trace_all.append(('ss', mem[0x58] | (mem[0x59] << 8)))
            mpu.step()
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += sc.last_cycles
        return sc.last_cycles
    sc._run = traced_run


def trace_asm(px, py, ab):
    _ = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    setup(sc, px, py, ab)
    trace = []
    install_tracing(sc, trace)
    sc._run(ENTRY_BR_RENDER_FRAME)
    fb = bytes(sc.mpu.memory[0x5800:0x6C00])
    return trace, fb


def trace_hybrid(px, py, ab):
    """Python BSP + 6502 seg processor + 6502-backed visibility."""
    _ = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    setup(sc, px, py, ab)
    trace = []
    install_tracing(sc, trace)

    def hybrid_ss(idx, clips, ctx, vz, surface, ram):
        # (the traced_run pc watch records the ss entry — no explicit append)
        mem = sc.mpu.memory
        mem[0x58] = idx & 0xFF
        mem[0x59] = (idx >> 8) & 0xFF
        sc._run(ENTRY_BR_RENDER_SUBSECTOR)

    orig = dw.packed_render_subsector
    dw.packed_render_subsector = hybrid_ss
    try:
        px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
        py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
        sc_t = fp.fp_sincos(ab)
        ctx = fp.fp_view_context(px_88, py_88, sc_t)
        vz = dw._prescale_height(dw.player_floor(px, py) + 41)
        cos_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).x
        sin_f = pygame.math.Vector2(1, 0).rotate(ab * 360 / 256).y
        p_ram = bytearray(dw.packed_layout['ram_size'])
        spans_base = dw.packed_layout['ram_spans']
        spans_init_full(p_ram, spans_base, dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
        surf = pygame.Surface((256, 160))
        dw.packed_render_bsp(len(dw.nodes) - 1, Asm6502Clips(sc),
                             ctx, vz, px, py, cos_f, sin_f, surf, p_ram)
    finally:
        dw.packed_render_subsector = orig
    fb = bytes(sc.mpu.memory[0x5800:0x6C00])
    return trace, fb


def fmt(c):
    return f'{c[0]}({",".join(str(x) for x in c[1:])})'


if __name__ == '__main__':
    if len(sys.argv) >= 4:
        POSITIONS = [(int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]))]
    else:
        POSITIONS = [
            (1056, -3616, 0), (1056, -3616, 32), (1056, -3616, 64),
            (1056, -3616, 128), (1056, -3616, 192), (1056, -3616, 224),
            (1024, -3500, 64), (1500, -3700, 0),  (800, -3400, 96),
            (1200, -3000, 128),
        ]

    for px, py, ab in POSITIONS:
        asm_t, asm_fb = trace_asm(px, py, ab)
        hyb_t, hyb_fb = trace_hybrid(px, py, ab)
        px_diff = sum(bin(a ^ b).count('1') for a, b in zip(asm_fb, hyb_fb))
        # has_gap order legitimately differs (the 6502 walk bbox-checks far
        # children only; Python checks near+far) — compare the subsector
        # visit SEQUENCE and the framebuffer.
        asm_ss = [c[1] for c in asm_t if c[0] == 'ss']
        hyb_ss = [c[1] for c in hyb_t if c[0] == 'ss']
        match = 'MATCH' if asm_ss == hyb_ss else 'DIFFER'
        print(f'({px},{py},{ab}): ss-seq {match} '
              f'(asm {len(asm_ss)}, hyb {len(hyb_ss)}), fb diff={px_diff} px')
        if asm_ss != hyb_ss:
            n = min(len(asm_ss), len(hyb_ss))
            for i in range(n):
                if asm_ss[i] != hyb_ss[i]:
                    print(f'    first ss divergence at #{i}: '
                          f'asm={asm_ss[i]} hyb={hyb_ss[i]}')
                    print(f'    asm: ...{asm_ss[max(0,i-2):i+4]}')
                    print(f'    hyb: ...{hyb_ss[max(0,i-2):i+4]}')
                    break
            else:
                print(f'    one is a prefix of the other: '
                      f'asm extra={asm_ss[n:][:6]} hyb extra={hyb_ss[n:][:6]}')
