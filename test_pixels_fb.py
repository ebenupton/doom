#!/usr/bin/env python3
"""Test pixel coverage by comparing the integrated framebuffer (NJ
rasteriser output via Instrumented6502Spans) before/after toggling
_AP_SKIP_ENABLE.  This captures emissions that go through the
rasteriser rather than pygame.draw.line — needed for verifying
re-enabled tighten emission."""
import os, sys, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp as fpmod

POSITIONS = [
    (1056, -3616, 64, "S1 E"),
    (1056, -3616, 0, "N"),
    (1056, -3616, 32, "S2 NE"),
    (1056, -3616, 96, "SE"),
    (1200, -3300, 64, "T moved"),
    (964, -3441, 79, "doorway"),
    (1200, -3300, 0, "T N"),
    (1200, -3300, 32, "T NE"),
    (800, -3500, 32, "spawn-W"),
]

def render_capture_fb(px, py, ab):
    """Render via packed_render_bsp into Instrumented6502Spans, then
    extract the integrated 6502 framebuffer from the NJ rasteriser."""
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
    # Extract framebuffer from _span_clip_6502 RAM at SCREEN_START
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


bad = 0
print(f"{'scene':<10s}  {'on px':>6s}  {'off px':>6s}  {'lost':>4s}  {'gained':>6s}")
for px, py, ab, name in POSITIONS:
    dw._AP_SKIP_ENABLE = True
    on_set = render_capture_fb(px, py, ab)
    dw._AP_SKIP_ENABLE = False
    off_set = render_capture_fb(px, py, ab)
    lost = off_set - on_set
    gained = on_set - off_set
    bad += len(lost) + len(gained)
    print(f"{name:<10s}  {len(on_set):>6d}  {len(off_set):>6d}  {len(lost):>4d}  {len(gained):>6d}")

print()
print(f"Total {bad} pixel divergences" if bad else "All scenes match — fb pixel coverage preserved.")
dw._AP_SKIP_ENABLE = True
