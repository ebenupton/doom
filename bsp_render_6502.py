"""BspRender6502 — wrap span_clip + bsp_render.bin for use by doom_wireframe.

Loads the BSP-traversal/transform 6502 binary alongside span_clip + the
quarter-square tables + the recip table, and exposes a render_frame()
method that runs one frame and returns the framebuffer at $5800.

This is the binary built by bsp_render.asm (BSP walk, vertex transform,
seg processing, span_clip integration) — distinct from the older
Frontend6502 in fe6502.py which uses doom_fe.bin.
"""
import os
from span_clip_6502 import SpanClip6502


# ZP slots used by bsp_render.asm — mirror these from the .asm file.
ZP_PX           = 0x00
ZP_PY           = 0x02
ZP_VZ           = 0x04
ZP_SMAG         = 0x05
ZP_SNEG         = 0x06
ZP_SONE         = 0x07
ZP_CMAG         = 0x08
ZP_CNEG         = 0x09
ZP_CONE         = 0x0A
ZP_ROM_FHCH_LO  = 0x30
ZP_ROM_BBOX_LO  = 0x32
ZP_ROM_VERTS_LO = 0x40
ZP_ROM_NODES_LO = 0x42
ZP_ROM_SS_LO    = 0x44
ZP_ROM_SEG_HDR_LO = 0x46
ZP_ROM_VWH_LO   = 0x48
ZP_ROM_DETAIL_LO = 0x4A
ZP_ROOT_NODE_LO = 0x4C
ZP_PXRAW_LO     = 0x90
ZP_PYRAW_LO     = 0x92

ENTRY_BR_VIEW_SETUP   = 0x4809
ENTRY_BR_RENDER_FRAME = 0x4815

ROM_MAIN_BASE   = 0x6C00
VWH_BASE        = 0xE484
ROM_DETAIL_BASE = 0xB600
ROM_FHCH_BASE   = 0xB600
ROM_BBOX_BASE   = 0xC600


class BspRender6502:
    """Persistent BSP-render 6502 instance for interactive use."""

    def __init__(self, packed_layout, packed_rom_main, packed_rom_detail,
                 packed_bbox_table, map_center_x=1200, map_center_y=-3250,
                 prescale=8):
        self.layout = packed_layout
        self.rom_main = packed_rom_main
        self.rom_detail = packed_rom_detail
        self.bbox_table = packed_bbox_table
        self.map_center_x = map_center_x
        self.map_center_y = map_center_y
        self.prescale = prescale
        self.last_cycles = 0

        self.sc = SpanClip6502()
        self._load_wad()

    def _load_wad(self):
        from wad_packed import SEG_DTL_SIZE, SD_FH, SD_CH, SD_BFH, SD_BCH

        layout = self.layout
        rom_main = self.rom_main
        rom_detail = self.rom_detail
        bbox = self.bbox_table
        mem = self.sc.mpu.memory

        vwh_start = layout['off_vwh']
        for i in range(vwh_start):
            mem[ROM_MAIN_BASE + i] = rom_main[i]
        for i in range(len(rom_main) - vwh_start):
            mem[VWH_BASE + i] = rom_main[vwh_start + i]

        # 4 bytes per seg: fh, ch, bfh, bch (front + back floor/ceiling, s8).
        n_segs = layout['n_segs']
        for si in range(n_segs):
            off = si * SEG_DTL_SIZE
            mem[ROM_FHCH_BASE + si * 6 + 0] = rom_detail[off + SD_FH]
            mem[ROM_FHCH_BASE + si * 6 + 1] = rom_detail[off + SD_CH]
            mem[ROM_FHCH_BASE + si * 6 + 2] = rom_detail[off + SD_BFH]
            mem[ROM_FHCH_BASE + si * 6 + 3] = rom_detail[off + SD_BCH]
            # bytes 4/5: solid-seg APV2 aperture heights (detail 12/13)
            mem[ROM_FHCH_BASE + si * 6 + 4] = rom_detail[off + 12]
            mem[ROM_FHCH_BASE + si * 6 + 5] = rom_detail[off + 13]

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

    def render_frame(self, player_x, player_y, angle_byte, floor_z=0):
        import fp
        sc = self.sc
        mem = sc.mpu.memory

        px_88 = int((player_x - self.map_center_x) * 256 / self.prescale)
        py_88 = int((player_y - self.map_center_y) * 256 / self.prescale)
        mem[ZP_PX]     = px_88 & 0xFF
        mem[ZP_PX + 1] = (px_88 >> 8) & 0xFF
        mem[ZP_PY]     = py_88 & 0xFF
        mem[ZP_PY + 1] = (py_88 >> 8) & 0xFF

        # Eye height (pre-scaled, s8). doom_wireframe normally does
        # vz = prescale_height(player_floor + 41); we get player_floor in.
        # Inline a minimal prescale_height.
        ASPECT_NUM = 6; ASPECT_DEN = 5
        vz = ((floor_z + 41) * ASPECT_NUM + ASPECT_DEN // 2) \
             // (self.prescale * ASPECT_DEN)
        mem[ZP_VZ] = vz & 0xFF

        raw_px = int(player_x) - self.map_center_x
        raw_py = int(player_y) - self.map_center_y
        mem[ZP_PXRAW_LO]     = raw_px & 0xFF
        mem[ZP_PXRAW_LO + 1] = (raw_px >> 8) & 0xFF
        mem[ZP_PYRAW_LO]     = raw_py & 0xFF
        mem[ZP_PYRAW_LO + 1] = (raw_py >> 8) & 0xFF

        s_mag, s_neg, s_one, c_mag, c_neg, c_one = fp.fp_sincos(angle_byte)
        mem[ZP_SMAG] = s_mag
        mem[ZP_SNEG] = 1 if s_neg else 0
        mem[ZP_SONE] = 1 if s_one else 0
        mem[ZP_CMAG] = c_mag
        mem[ZP_CNEG] = 1 if c_neg else 0
        mem[ZP_CONE] = 1 if c_one else 0

        sc._run(ENTRY_BR_VIEW_SETUP)
        sc.init()
        sc.clear_screen()
        cyc = sc._run(ENTRY_BR_RENDER_FRAME, max_cycles=10000000)
        self.last_cycles = cyc
        return cyc

    def blit_framebuffer_to(self, surface):
        """Render the 256×160 BBC mode-4 framebuffer at $5800 into surface."""
        import pygame
        mem = self.sc.mpu.memory
        start = 0x5800
        surface.fill((0, 0, 0))
        pix = pygame.PixelArray(surface)
        for cy in range(20):
            for col in range(32):
                for pr in range(8):
                    y = cy * 8 + pr
                    if y >= surface.get_height():
                        break
                    byte = mem[start + cy * 256 + col * 8 + pr]
                    for bit in range(8):
                        if byte & (0x80 >> bit):
                            pix[col * 8 + bit, y] = (255, 255, 255)
        del pix
