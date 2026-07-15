"""Per-subsector differential test: Python vs 6502 seg processor.

Drives the pure-Python BSP (the reference traversal). At each subsector:
  1. Snapshot the full 6502 memory (clipper span pool, records, FB).
  2. Run the 6502 br_render_subsector; capture its clipper-call trace and
     post-run span state.
  3. Restore the snapshot.
  4. Run Python's packed_render_subsector (which shadows into the same
     6502 clipper); capture its trace and post-run span state.
  5. Diff. Continue from the PYTHON state, so every subsector comparison
     starts from reference-true state and local divergences can't compound.

This isolates seg-processor bugs subsector-by-subsector with no
traversal noise. Divergences in draw calls produce wrong pixels;
divergences in span state produce wrong occlusion for LATER subsectors.
"""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp
from wad_packed import spans_init_full
import trace_compare as tc

from symmap import sym as _sym
ENTRY_BR_RENDER_SUBSECTOR = _sym('jt_br_render_subsector')
ENTRY_BR_INIT_FRAME       = _sym('jt_br_init_frame')
_E_MARK_SOLID = _sym('jt_mark_solid')
_E_TFR        = _sym('jt_tighten_from_records')
_E_DCL_S16    = _sym('jt_draw_clip_s16')


def install_tracing(sc, trace_all):
    """Stepping _run that records clipper entry calls into trace_all."""
    def s16(v):
        return v - 0x10000 if v >= 0x8000 else v

    def traced_run(entry, max_cycles=20_000_000):
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
            if pc == _E_MARK_SOLID:
                trace_all.append(('mark_solid', mem[0xC2], mem[0xC3]))
            elif pc == _E_TFR:
                trace_all.append(('tighten', mem[0xC2], mem[0xC3]))
            elif pc == _E_DCL_S16:
                xl = s16(mem[0xA8] | (mem[0xB2] << 8))
                yl = s16(mem[0xA9] | (mem[0xB3] << 8))
                xr = s16(mem[0xAA] | (mem[0xB4] << 8))
                yr = s16(mem[0xAB] | (mem[0xB5] << 8))
                trace_all.append(('draw', xl, yl, xr, yr))
            mpu.step()
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += sc.last_cycles
        return sc.last_cycles
    sc._run = traced_run


class SubsectorDiffer:
    def __init__(self, sc, trace_all):
        self.sc = sc
        self.trace_all = trace_all
        self.orig_subsector = dw.packed_render_subsector
        self.divergences = []   # (ssid, asm_trace, py_trace, spans_match)
        self.n_compared = 0

    def __call__(self, idx, clips, ctx, vz, surface, ram):
        sc = self.sc
        mem = sc.mpu.memory
        ta = self.trace_all
        snap = bytes(mem[0x0000:0x10000])

        # --- 6502 run ---
        a0 = len(ta)
        mem[0x58] = idx & 0xFF
        sc._run(ENTRY_BR_RENDER_SUBSECTOR)
        asm_trace = ta[a0:]
        del ta[a0:]
        asm_spans = sc.read_spans()
        asm_fb = bytes(mem[0x5800:0x6C00])
        mem[0x0000:0x10000] = snap

        # --- Python reference run (this is the state we continue from) ---
        p0 = len(ta)
        self.orig_subsector(idx, clips, ctx, vz, surface, ram)
        py_trace = ta[p0:]
        del ta[p0:]
        py_spans = sc.read_spans()
        py_fb = bytes(mem[0x5800:0x6C00])

        self.n_compared += 1
        spans_match = (asm_spans == py_spans)
        # Pixel diff: XOR popcount over the 1bpp framebuffer.
        px_diff = 0
        if asm_fb != py_fb:
            px_diff = sum(bin(a ^ b).count('1')
                          for a, b in zip(asm_fb, py_fb))
        if asm_trace != py_trace or not spans_match or px_diff:
            self.divergences.append((idx, asm_trace, py_trace,
                                     asm_spans, py_spans, px_diff))


def run_position(px, py, ab, verbose=False):
    _ = dw.Instrumented6502Spans()   # force shared instance creation
    sc = dw._span_clip_6502
    tc.setup_wad(sc)
    tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    sc.init()
    sc.clear_screen()
    sc._run(ENTRY_BR_INIT_FRAME)

    trace_all = []
    install_tracing(sc, trace_all)

    differ = SubsectorDiffer(sc, trace_all)
    dw.packed_render_subsector = differ
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
        dw.packed_render_bsp(len(dw.nodes) - 1, dw.Instrumented6502Spans(),
                             ctx, vz, px, py, cos_f, sin_f, surf, p_ram)
    finally:
        dw.packed_render_subsector = differ.orig_subsector

    return differ


def fmt(call):
    if call[0] == 'draw':
        return f'draw({call[1]},{call[2]},{call[3]},{call[4]})'
    return f'{call[0]}({call[1]},{call[2]})'


def report(differ, px, py, ab, max_detail=3):
    harmful = [d for d in differ.divergences if d[5] or d[3] != d[4]]
    print(f'\n=== ({px},{py},{ab}): {differ.n_compared} subsectors, '
          f'{len(differ.divergences)} divergent '
          f'({len(harmful)} pixel/span-affecting) ===')
    shown = 0
    for ssid, asm_t, py_t, asm_s, py_s, px_diff in differ.divergences:
        affects = px_diff or asm_s != py_s
        if not affects:
            continue
        shown += 1
        if shown > max_detail:
            break
        same_set = sorted(asm_t) == sorted(py_t)
        print(f'  ss {ssid}: {px_diff} px diff, '
              f'spans {"match" if asm_s == py_s else "DIFFER"}, '
              f'traces {"same-set" if same_set else "differ"} '
              f'(asm {len(asm_t)}, py {len(py_t)})')
        if not same_set:
            asm_only = [c for c in asm_t if c not in py_t]
            py_only = [c for c in py_t if c not in asm_t]
            for c in asm_only[:6]:
                print(f'      asm-only: {fmt(c)}')
            for c in py_only[:6]:
                print(f'      py-only:  {fmt(c)}')
        if asm_s != py_s:
            print(f'      asm spans: {asm_s}')
            print(f'      py  spans: {py_s}')
    if shown > max_detail:
        print(f'  ... and {len(harmful) - max_detail} more pixel/span-affecting')


if __name__ == '__main__':
    if len(sys.argv) >= 4:
        POSITIONS = [(int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]))]
        detail = 100
    else:
        # Cardinal angles (0/64/128/192) nudged +1 — they take the sin/cos
        # unity path and behave atypically; off-axis views are representative.
        POSITIONS = [
            (1056, -3616, 1), (1056, -3616, 32), (1056, -3616, 65),
            (1056, -3616, 129), (1056, -3616, 193), (1056, -3616, 224),
            (1024, -3500, 65), (1500, -3700, 1),  (800, -3400, 96),
            (1200, -3000, 129),
            # far-from-spawn, in-spec (within +/-1023 units of MAP_CENTER)
            (2112, -2368, 35), (192, -2368, 99), (1984, -2496, 67),
            (1856, -2368, 3),
            # beyond the old +/-1023-unit box (s16 player int)
            (3648, -2368, 35), (2500, -2600, 67), (3648, -4800, 131),
            (-486, -3307, 243),
        ]
        detail = 3

    total_div = total_ss = total_harm = total_px = 0
    for px, py, ab in POSITIONS:
        differ = run_position(px, py, ab)
        report(differ, px, py, ab, max_detail=detail)
        total_div += len(differ.divergences)
        total_ss += differ.n_compared
        total_harm += sum(1 for d in differ.divergences if d[5] or d[3] != d[4])
        total_px += sum(d[5] for d in differ.divergences)
    print(f'\nTOTAL: {total_div}/{total_ss} subsectors divergent, '
          f'{total_harm} pixel/span-affecting, {total_px} px')
