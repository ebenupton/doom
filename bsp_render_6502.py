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
from symmap import sym as _sym


# ZP slots used by the engine — resolved from the linked symbol map.
ZP_PX           = _sym('zp_br_px')
ZP_PY           = _sym('zp_br_py')
ZP_VZ           = _sym('zp_br_vz')
ZP_SMAG         = _sym('zp_br_smag')
ZP_SNEG         = _sym('zp_br_sneg')
ZP_SONE         = _sym('zp_br_sone')
ZP_CMAG         = _sym('zp_br_cmag')
ZP_CNEG         = _sym('zp_br_cneg')
ZP_CONE         = _sym('zp_br_cone')
# Table base pointer slots (absolute RAM — the ZP scavenge moved most of
# them out of ZP; the angle module owns the freed slots).
ZP_PXRAW_LO     = _sym('zp_br_pxraw_l')
ZP_PYRAW_LO     = _sym('zp_br_pyraw_l')

ENTRY_BR_VIEW_SETUP   = _sym('jt_br_view_setup')
ENTRY_BR_RENDER_FRAME = _sym('jt_br_render_frame')

# Table load addresses: harness-owned placement decisions (the engine reads
# these tables only through the pointer slots above), NOT engine symbols.
ROM_MAIN_BASE   = 0x6C00
                           # mover slots (1248 total) overflowed the old slot below
                           # ANG at $E940; $FB00-$FFF9 is unused in the flat harness.
                           # $E484-$E93F now hosts the flat ANIM tables + workers.
ROM_DETAIL_BASE = 0xB600
# flat bases (KEEP IN SYNC with src/layout.inc flat branch):
ROM_SEG_HDR_BASE = 0x6C00       # stride-18 headers, heights at +12..17
ROM_VERTS_BASE   = 0x9C00
NODE_SOA_BASE    = 0xB600       # node/ss SoA pages (old FHCH hole)
ROM_BBOX_BASE   = 0xC400   # 16 corner planes $C400-$D3FF (page-split SoA)
                           # build/split the bbox pointer byte-at-a-time


def poke_init_frame_state(mem):
    """Mirror br_render_frame's inline per-frame init for partial-flow
    harnesses (the standalone jt_br_init_frame entry retired 2026-07-15):
    records-pointer ground state + the 60-byte vcache valid clear."""
    mem[_sym('zp_dcl_rec_buf')] = 0
    mem[_sym('zp_dcl_rec_buf_h')] = 0
    base = _sym('VCACHE_VALID_BASE')
    for i in range(60):
        mem[base + i] = 0


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

        # Flat placement (2026-07-11, heights inlined in stride-18 headers):
        # headers $6C00-$9B8B, verts $9C00, node/ss SoA $B600 (the hole the
        # retired FHCH stream vacated). The packer bakes the height bytes
        # (former load-time FHCH synthesis) into the header at +12..17.
        off_verts = layout['off_verts']; off_hdr = layout['off_seg_hdr']
        for i in range(off_verts):                       # SoA pages (14: 11 node + 3 ss)
            mem[NODE_SOA_BASE + i] = rom_main[i]
        # SS_PHI page ships first*16 offsets — rebase onto the flat
        # seg-header base so the engine reads ready pointers
        for i in range(0xB00, 0xC00):
            mem[NODE_SOA_BASE + i] = (rom_main[i] + (ROM_SEG_HDR_BASE >> 8)) & 0xFF
        for i in range(off_verts, off_hdr):              # verts
            mem[ROM_VERTS_BASE + (i - off_verts)] = rom_main[i]
        for i in range(off_hdr, len(rom_main)):          # stride-18 headers
            mem[ROM_SEG_HDR_BASE + (i - off_hdr)] = rom_main[i]

        for i, b in enumerate(bbox):
            mem[ROM_BBOX_BASE + i] = b

        def w16(addr_lo, val):
            mem[addr_lo]     = val & 0xFF
            mem[addr_lo + 1] = (val >> 8) & 0xFF

        # Angle-space bbox module + tables (rebuilds first — a standalone run
        # after a source edit must not test a stale bin).
        from engine_load import load_angle_module
        load_angle_module(mem)

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
        # s16 integer position: high bytes (whole-map support, not just
        # +/-127 prescaled units around MAP_CENTER)
        mem[_sym('zp_br_px_x')] = (px_88 >> 16) & 0xFF
        mem[_sym('zp_br_py_x')] = (py_88 >> 16) & 0xFF

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
        mem[_sym('bca_ab')] = angle_byte & 0xFF  # angle-space bbox view angle

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
