#!/usr/bin/env python3
"""Compare integrated 6502 framebuffer pre vs post (3): captures
post-(3) pixels then asks user to git stash for baseline."""
import os, sys, math, json
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp as fpmod

POSITIONS = [
    (1056, -3616, 64, "S1_E"),
    (1056, -3616, 0, "N"),
    (1056, -3616, 32, "S2_NE"),
    (1056, -3616, 96, "SE"),
    (1200, -3300, 64, "T_moved"),
    (964, -3441, 79, "doorway"),
    (1200, -3300, 0, "T_N"),
    (1200, -3300, 32, "T_NE"),
    (800, -3500, 32, "spawn-W"),
]

def render_capture_fb(px, py, ab):
    fz = dw.player_floor(px, py)
    real = pygame.draw.line
    pygame.draw.line = lambda *a, **k: None
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz_ps = dw._prescale_height(fz + 41)
    sc = dw.fp_sincos(ab)
    ctx = dw.fp_view_context(px_88, py_88, sc)
    ang_rad = dw.byte_to_radians(ab)
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
    tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    for k in dw.map_trace:
        if hasattr(dw.map_trace[k], 'clear'):
            dw.map_trace[k].clear()
    fpmod.mul_reset()
    from wad_packed import spans_init_full
    p_ram = dw._packed_ram_new()
    spans_base = dw.packed_layout['ram_spans']
    spans_init_full(p_ram, spans_base, dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    if dw._span_clip_6502 is not None:
        dw._span_clip_6502.clear_screen()
    dw.packed_render_bsp(len(dw.nodes) - 1, dw.Instrumented6502Spans(),
                         ctx, vz_ps, int(px), int(py), cos_f, sin_f,
                         tmp, p_ram)
    pygame.draw.line = real
    sc6 = dw._span_clip_6502
    mem = sc6.mpu.memory
    start = sc6.SCREEN_START
    pixels = set()
    for char_row in range(20):
        for byte_col in range(32):
            for scanline in range(8):
                addr = start + char_row * 256 + byte_col * 8 + scanline
                byte = mem[addr]
                if byte == 0:
                    continue
                py_y = char_row * 8 + scanline
                for bit in range(8):
                    if byte & (0x80 >> bit):
                        pixels.add((byte_col * 8 + bit, py_y))
    return pixels


# Mode: 'save' or 'compare'
mode = sys.argv[1] if len(sys.argv) > 1 else 'save'
filename = '/tmp/fb_pixels.json'

if mode == 'save':
    out = {}
    for px, py, ab, name in POSITIONS:
        out[name] = sorted(list(render_capture_fb(px, py, ab)))
    with open(filename, 'w') as f:
        json.dump(out, f)
    print(f"Saved {sum(len(v) for v in out.values())} total pixels to {filename}")
elif mode == 'compare':
    with open(filename, 'r') as f:
        baseline = json.load(f)
    print(f"{'scene':<10s}  {'now':>6s}  {'base':>6s}  {'lost':>4s}  {'gained':>6s}")
    for px, py, ab, name in POSITIONS:
        now_set = render_capture_fb(px, py, ab)
        base_set = set(tuple(p) for p in baseline.get(name, []))
        lost = base_set - now_set
        gained = now_set - base_set
        print(f"{name:<10s}  {len(now_set):>6d}  {len(base_set):>6d}  "
              f"{len(lost):>4d}  {len(gained):>6d}")
        if (lost or gained) and len(sys.argv) > 2 and sys.argv[2] == name:
            for p in sorted(lost)[:20]:
                print(f"   LOST  {p}")
            for p in sorted(gained)[:20]:
                print(f"   GAIN  {p}")
