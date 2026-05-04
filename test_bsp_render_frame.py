"""End-to-end test: render one frame using bsp_render's BSP walker
+ minimal seg processor. Counts pixels in the framebuffer to confirm
that lines are actually being emitted.

This is a smoke test, not a pixel-perfect comparison. The seg
processor emits one horizontal line per seg at HALF_H, which won't
match the Python reference but should produce visible pixels.
"""
import os, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

from span_clip_6502 import SpanClip6502
import doom_wireframe as dw
import fp

ENTRY_BR_VIEW_SETUP   = 0x4809
ENTRY_BR_RENDER_FRAME = 0x4815

# ROM/RAM offset slots
ZP_ROM_VERTS_LO   = 0x40
ZP_ROM_NODES_LO   = 0x42
ZP_ROM_SS_LO      = 0x44
ZP_ROM_SEG_HDR_LO = 0x46
ZP_ROM_VWH_LO     = 0x48
ZP_ROM_DETAIL_LO  = 0x4A
ZP_ROOT_NODE_LO   = 0x4C

# View context slots
ZP_PX = 0x00; ZP_PY = 0x02
ZP_SMAG = 0x05; ZP_SNEG = 0x06; ZP_SONE = 0x07
ZP_CMAG = 0x08; ZP_CNEG = 0x09; ZP_CONE = 0x0A

ROM_MAIN_BASE   = 0x6C00       # ROM main (no VWH) — fits below rasteriser.
VWH_BASE        = 0xE484       # VWH separately, after recip table.
ROM_DETAIL_BASE = 0xB600       # OK while detail is unread by stub.


def setup_wad(sc):
    layout = dw.packed_layout
    rom_main = dw.packed_rom_main
    rom_detail = dw.packed_rom_detail
    mem = sc.mpu.memory
    vwh_start = layout['off_vwh']
    for i in range(vwh_start):
        mem[ROM_MAIN_BASE + i] = rom_main[i]
    for i in range(len(rom_main) - vwh_start):
        mem[VWH_BASE + i] = rom_main[vwh_start + i]
    # ROM detail not loaded — not read by the current stub render_subsector,
    # and there's no contiguous space for it without conflicting with the
    # recip table at $E000-$E483.

    def w16(addr_lo, val):
        mem[addr_lo]     = val & 0xFF
        mem[addr_lo + 1] = (val >> 8) & 0xFF

    w16(ZP_ROM_VERTS_LO,   ROM_MAIN_BASE + layout['off_verts'])
    w16(ZP_ROM_NODES_LO,   ROM_MAIN_BASE + layout['off_nodes'])
    w16(ZP_ROM_SS_LO,      ROM_MAIN_BASE + layout['off_ss'])
    w16(ZP_ROM_SEG_HDR_LO, ROM_MAIN_BASE + layout['off_seg_hdr'])
    w16(ZP_ROM_VWH_LO,     VWH_BASE)
    w16(ZP_ROM_DETAIL_LO,  ROM_DETAIL_BASE)
    w16(ZP_ROOT_NODE_LO,   layout['n_nodes'] - 1)


def setup_view(sc, px, py, ab):
    """Set up player view in 6502 ZP."""
    mem = sc.mpu.memory
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    mem[ZP_PX]     = px_88 & 0xFF
    mem[ZP_PX + 1] = (px_88 >> 8) & 0xFF
    mem[ZP_PY]     = py_88 & 0xFF
    mem[ZP_PY + 1] = (py_88 >> 8) & 0xFF

    s_mag, s_neg, s_one, c_mag, c_neg, c_one = fp.fp_sincos(ab)
    mem[ZP_SMAG] = s_mag
    mem[ZP_SNEG] = 1 if s_neg else 0
    mem[ZP_SONE] = 1 if s_one else 0
    mem[ZP_CMAG] = c_mag
    mem[ZP_CNEG] = 1 if c_neg else 0
    mem[ZP_CONE] = 1 if c_one else 0

    sc._run(ENTRY_BR_VIEW_SETUP)


def init_pool(sc):
    """Initialize the span pool (one full-screen span)."""
    sc.init()


def clear_screen(sc):
    sc.clear_screen()


def count_pixels(sc):
    mem = sc.mpu.memory
    n = 0
    for i in range(5120):
        b = mem[0x5800 + i]
        if b:
            for bit in range(8):
                if b & (0x80 >> bit):
                    n += 1
    return n


def main():
    sc = SpanClip6502()
    setup_wad(sc)

    # Standard test position from test_phase_b_pixels.py
    px, py, ab = 1056, -3616, 64

    setup_view(sc, px, py, ab)
    init_pool(sc)
    clear_screen(sc)

    print(f"Rendering frame from (px={px}, py={py}, angle={ab})...")
    sc._run(ENTRY_BR_RENDER_FRAME)

    n = count_pixels(sc)
    print(f"  Framebuffer has {n} pixels set")
    if n > 0:
        print(f"  ✓ Something rendered!")
    else:
        print(f"  ✗ No pixels — rendering pipeline not fully connected yet")


if __name__ == '__main__':
    main()
