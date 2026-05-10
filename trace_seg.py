"""Per-seg trace comparator. Run both Python+6502 paths, capture clipper
calls with (subsector, seg) context, group by subsector, print side-by-side.

The Python path uses dw._span_clip_6502 (a global wrapper). For the Python
side, ssid/seg_idx come from a Python-side context tracker that monkey-
patches packed_render_subsector / packed_render_seg.
"""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp
from wad_packed import (SEG_DTL_SIZE, SD_FH, SD_CH, SD_BFH, SD_BCH,
                        spans_init_full)
import trace_compare as tc


# Python-side per-call context: capture the (ssid, seg_idx) at the time
# of each clipper call by hooking the wrapper methods.
_py_ctx = {'ssid': 0xFFFF, 'seg_idx': 0xFFFF}


def hook_python_context():
    """Wrap packed_render_subsector + packed_render_seg to track context."""
    orig_ss = dw.packed_render_subsector
    orig_seg = dw.packed_render_seg
    def wrap_ss(idx, *args, **kwargs):
        prev = _py_ctx['ssid']
        _py_ctx['ssid'] = 0x8000 | idx
        try:
            return orig_ss(idx, *args, **kwargs)
        finally:
            _py_ctx['ssid'] = prev
    def wrap_seg(si, *args, **kwargs):
        prev = _py_ctx['seg_idx']
        _py_ctx['seg_idx'] = si
        try:
            return orig_seg(si, *args, **kwargs)
        finally:
            _py_ctx['seg_idx'] = prev
    dw.packed_render_subsector = wrap_ss
    dw.packed_render_seg = wrap_seg


def install_python_tracer(sc, trace):
    """Like install_tracing_run, but also pull ssid/seg_idx from _py_ctx
    (the simulator's $58/$5A reflect the Python tracker, not the 6502 BSP).
    """
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
            evt = None
            if pc == 0x2003:
                evt = ('mark_solid', mem[0xC2], mem[0xC3])
            elif pc == 0x2009:
                evt = ('has_gap', mem[0xC2], mem[0xC3])
            elif pc == 0x200C:
                evt = ('is_full',)
            elif pc == 0x201E:
                xl = tc.s16(mem[0xA8] | (mem[0xB2] << 8))
                yl = tc.s16(mem[0xA9] | (mem[0xB3] << 8))
                xr = tc.s16(mem[0xAA] | (mem[0xB4] << 8))
                yr = tc.s16(mem[0xAB] | (mem[0xB5] << 8))
                evt = ('draw', xl, yl, xr, yr)
            if evt is not None:
                evt = evt + (_py_ctx['ssid'], _py_ctx['seg_idx'])
                trace.append(evt)
            mpu.step()
        sc.last_cycles = mpu.processorCycles
        sc.total_cycles += sc.last_cycles
        return sc.last_cycles
    sc._run = traced_run


def trace_python(px, py, ab):
    spans = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    tc.setup_wad(sc)
    tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    sc.init()
    sc.clear_screen()
    hook_python_context()
    trace = []
    install_python_tracer(sc, trace)

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
    dw.packed_render_bsp(
        len(dw.nodes) - 1, spans,
        ctx, vz, px, py, cos_f, sin_f, surf, p_ram)
    return trace


def trace_6502(px, py, ab):
    sc = tc.SpanClip6502()
    tc.setup_wad(sc)
    tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    sc.init()
    sc.clear_screen()
    trace = []
    tc.install_tracing_run(sc, trace, with_context=True)
    sc._run(tc.ENTRY_BR_RENDER_FRAME)
    return trace


def fmt_evt(evt):
    op = evt[0]
    body = ''
    if op == 'is_full':
        body = '()'
    elif op == 'draw':
        body = f'({evt[1]},{evt[2]},{evt[3]},{evt[4]})'
    elif op in ('has_gap', 'mark_solid'):
        body = f'({evt[1]},{evt[2]})'
    return f'{op}{body}'


def filter_ss(trace, ssid):
    """Keep only events with matching ssid (mask the $8000 subsector flag —
    Python tags the ssid with $8000, the 6502 strips it before render)."""
    target = ssid & 0x7FFF
    return [evt for evt in trace if (evt[-2] & 0x7FFF) == target]


if __name__ == '__main__':
    if len(sys.argv) < 5:
        print('Usage: trace_seg.py PX PY AB SSID')
        sys.exit(1)
    px = int(sys.argv[1]); py = int(sys.argv[2]); ab = int(sys.argv[3])
    ss = int(sys.argv[4])
    target_ssid = 0x8000 | ss

    print(f'Tracing at ({px},{py},{ab}) — focusing on ss{ss}')
    py_trace = trace_python(px, py, ab)
    asm_trace = trace_6502(px, py, ab)

    py_ss = filter_ss(py_trace, target_ssid)
    asm_ss = filter_ss(asm_trace, target_ssid)

    print(f'\npy events in ss{ss}: {len(py_ss)}')
    print(f'asm events in ss{ss}: {len(asm_ss)}')

    n = max(len(py_ss), len(asm_ss))
    if n == 0:
        print('No events in this subsector for either path. Bug or wrong ss.')
        sys.exit(0)

    print('\n  idx  py-seg  py-call                                    asm-seg asm-call')
    for i in range(n):
        if i < len(py_ss):
            p = py_ss[i]
            p_seg = p[-1]
            p_str = fmt_evt(p[:-2])
        else:
            p_seg = -1
            p_str = '(end)'
        if i < len(asm_ss):
            a = asm_ss[i]
            a_seg = a[-1]
            a_str = fmt_evt(a[:-2])
        else:
            a_seg = -1
            a_str = '(end)'
        mark = '   ' if p_str == a_str and p_seg == a_seg else '<--'
        print(f'  [{i:3d}] s{p_seg:5d}  {p_str:42s} s{a_seg:5d}  {a_str:30s} {mark}')
