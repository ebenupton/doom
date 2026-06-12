"""End-to-end test: render one frame using bsp_render's BSP walker
+ seg processor with real fh/ch heights. Counts pixels in the
framebuffer to confirm that lines are actually being emitted.
"""
import os, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

from span_clip_6502 import SpanClip6502
import doom_wireframe as dw
import fp
from wad_packed import SEG_DTL_SIZE, SD_FH, SD_CH, SD_BFH, SD_BCH

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
ZP_ROM_FHCH_LO    = 0x30        # fh/ch table base
ZP_ROM_BBOX_LO    = 0x32        # bbox table base (16B per node × 236 = 3776B)

# View context slots
ZP_PX = 0x00; ZP_PY = 0x02
ZP_VZ = 0x04
ZP_SMAG = 0x05; ZP_SNEG = 0x06; ZP_SONE = 0x07
ZP_CMAG = 0x08; ZP_CNEG = 0x09; ZP_CONE = 0x0A
ZP_PXRAW_LO = 0x90  # raw (unprescaled) player position s16 — for side test
ZP_PYRAW_LO = 0x73

ROM_MAIN_BASE   = 0x6C00       # ROM main (no VWH) — fits below rasteriser.
VWH_BASE        = 0xE484       # VWH separately, after recip table.
ROM_DETAIL_BASE = 0xB600       # OK while detail is unread by stub.
ROM_FHCH_BASE   = 0xB600       # 1320-byte fh/ch table (same area; detail unused now)
ROM_BBOX_BASE   = 0xC100       # 3776-byte prescaled bbox table (16B per node); $BC00 collided with the 4B/seg FHCH table ($B600+2640=$C050)


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

    # Pack fh/ch/bfh/bch (4 bytes per seg) at ROM_FHCH_BASE.
    # 660 segs × 4 = 2640 bytes.
    n_segs = layout['n_segs']
    for si in range(n_segs):
        off = si * SEG_DTL_SIZE
        mem[ROM_FHCH_BASE + si * 4 + 0] = rom_detail[off + SD_FH]
        mem[ROM_FHCH_BASE + si * 4 + 1] = rom_detail[off + SD_CH]
        mem[ROM_FHCH_BASE + si * 4 + 2] = rom_detail[off + SD_BFH]
        mem[ROM_FHCH_BASE + si * 4 + 3] = rom_detail[off + SD_BCH]

    # Bbox table: 16 bytes per node (right-side bbox, then left-side).
    # Each side is (top, bot, left, right) as s16, prescaled.
    bbox = dw.packed_bbox_table
    for i, b in enumerate(bbox):
        mem[ROM_BBOX_BASE + i] = b

    def w16(addr_lo, val):
        mem[addr_lo]     = val & 0xFF
        mem[addr_lo + 1] = (val >> 8) & 0xFF

    w16(ZP_ROM_VERTS_LO,   ROM_MAIN_BASE + layout['off_verts'])
    w16(ZP_ROM_NODES_LO,   ROM_MAIN_BASE + layout['off_nodes'])
    w16(ZP_ROM_SS_LO,      ROM_MAIN_BASE + layout['off_ss'])
    w16(ZP_ROM_SEG_HDR_LO, ROM_MAIN_BASE + layout['off_seg_hdr'])
    w16(ZP_ROM_VWH_LO,     VWH_BASE)
    w16(ZP_ROM_DETAIL_LO,  ROM_DETAIL_BASE)
    w16(ZP_ROM_FHCH_LO,    ROM_FHCH_BASE)
    w16(ZP_ROM_BBOX_LO,    ROM_BBOX_BASE)
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

    # vz = prescale_height(player_floor + 41), s8.
    fz = dw.player_floor(px, py)
    vz = dw._prescale_height(fz + 41)
    mem[ZP_VZ] = vz & 0xFF

    # Raw player position (relative to map_center) for BSP side test, s16.
    raw_px = px - dw.MAP_CENTER_X
    raw_py = py - dw.MAP_CENTER_Y
    mem[ZP_PXRAW_LO]     = raw_px & 0xFF
    mem[ZP_PXRAW_LO + 1] = (raw_px >> 8) & 0xFF
    mem[ZP_PYRAW_LO]     = raw_py & 0xFF
    mem[ZP_PYRAW_LO + 1] = (raw_py >> 8) & 0xFF

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
    sc._run(ENTRY_BR_RENDER_FRAME, max_cycles=10000000)

    n = count_pixels(sc)
    print(f"  Framebuffer has {n} pixels set")
    if n > 0:
        print(f"  ✓ Something rendered!")
    else:
        print(f"  ✗ No pixels — rendering pipeline not fully connected yet")


if __name__ == '__main__':
    main()
