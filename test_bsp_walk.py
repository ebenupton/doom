"""Test BSP walker — verify it visits all subsectors when given a real
packed WAD.

This tests the structural traversal only (not geometric correctness;
the side test is currently a stub that always picks front).
"""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

from span_clip_6502 import SpanClip6502

ENTRY_BR_RENDER_FRAME = 0x4815

# ROM/RAM offset ZP slots (must match bsp_render.asm).
ZP_ROM_VERTS_LO   = 0x40
ZP_ROM_VERTS_HI   = 0x41
ZP_ROM_NODES_LO   = 0x42
ZP_ROM_NODES_HI   = 0x43
ZP_ROM_SS_LO      = 0x44
ZP_ROM_SS_HI      = 0x45
ZP_ROM_SEG_HDR_LO = 0x46
ZP_ROM_SEG_HDR_HI = 0x47
ZP_ROM_VWH_LO     = 0x48
ZP_ROM_VWH_HI     = 0x49
ZP_ROM_DETAIL_LO  = 0x4A
ZP_ROM_DETAIL_HI  = 0x4B
ZP_ROOT_NODE_LO   = 0x4C
ZP_ROOT_NODE_HI   = 0x4D

SS_VISITED_BITMAP = 0x0A80

# Where we'll put the WAD ROMs in 6502 memory.
# Carefully avoid: rasteriser at $A900-$B55E, recip table at $E000-$E483,
# screen $5800-$6BFF, span_clip $2000-$4737, multiply tables $5000-$57FF.
ROM_MAIN_BASE   = 0x6C00     # ROM main (no VWH) at $6C00. Without VWH,
                             # this ends at $6C00 + off_vwh = $A4B0, below
                             # the rasteriser at $A900.
VWH_BASE        = 0xE484     # VWH separately, after the recip table.
ROM_DETAIL_BASE = 0xB600     # ROM detail (13K) at $B600 → ends $E990,
                             # just past recip ($E000-$E483). 250 bytes
                             # of recip overlap — but the BSP doesn't read
                             # detail in the current stub so this is OK
                             # for now. TODO: relocate when seg detail
                             # processing is wired in.


def load_wad():
    """Build packed WAD from the doom_wireframe loaded data."""
    import doom_wireframe as dw
    return dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail


def setup_wad(sc, layout, rom_main, rom_detail):
    """Copy WAD ROMs into 6502 memory; set ZP offset slots."""
    mem = sc.mpu.memory
    # ROM main excluding VWH: vertices, nodes, subsectors, seg headers.
    vwh_start = layout['off_vwh']
    for i in range(vwh_start):
        mem[ROM_MAIN_BASE + i] = rom_main[i]
    # VWH heights at separate base.
    for i in range(len(rom_main) - vwh_start):
        mem[VWH_BASE + i] = rom_main[vwh_start + i]
    # ROM detail (currently unread by stub render_subsector).
    for i, b in enumerate(rom_detail):
        mem[ROM_DETAIL_BASE + i] = b

    # Resolve absolute addresses for each section.
    addr_verts   = ROM_MAIN_BASE + layout['off_verts']
    addr_nodes   = ROM_MAIN_BASE + layout['off_nodes']
    addr_ss      = ROM_MAIN_BASE + layout['off_ss']
    addr_seg_hdr = ROM_MAIN_BASE + layout['off_seg_hdr']
    addr_vwh     = VWH_BASE
    addr_detail  = ROM_DETAIL_BASE

    def w16(addr_lo, val):
        mem[addr_lo]     = val & 0xFF
        mem[addr_lo + 1] = (val >> 8) & 0xFF

    w16(ZP_ROM_VERTS_LO,   addr_verts)
    w16(ZP_ROM_NODES_LO,   addr_nodes)
    w16(ZP_ROM_SS_LO,      addr_ss)
    w16(ZP_ROM_SEG_HDR_LO, addr_seg_hdr)
    w16(ZP_ROM_VWH_LO,     addr_vwh)
    w16(ZP_ROM_DETAIL_LO,  addr_detail)

    # Root node id is layout['root_id'] — the index of the last (top-level)
    # BSP node. With high bit possibly set if it's a single-subsector tree.
    n_nodes = layout['n_nodes']
    root_id = n_nodes - 1
    w16(ZP_ROOT_NODE_LO, root_id)


def clear_visited(sc):
    mem = sc.mpu.memory
    for i in range(384):
        mem[SS_VISITED_BITMAP + i] = 0


def read_visited(sc, n_ss):
    mem = sc.mpu.memory
    visited = set()
    for i in range(n_ss):
        if mem[SS_VISITED_BITMAP + (i >> 3)] & (1 << (i & 7)):
            visited.add(i)
    return visited


def main():
    print("Loading packed WAD...")
    layout, rom_main, rom_detail = load_wad()
    n_ss = layout['n_ss']
    print(f"  {layout['n_verts']} vertices, {layout['n_nodes']} nodes, "
          f"{n_ss} subsectors, {layout['n_segs']} segs")
    print(f"  ROM main: {len(rom_main)} bytes, ROM detail: {len(rom_detail)} bytes")

    sc = SpanClip6502()
    setup_wad(sc, layout, rom_main, rom_detail)
    clear_visited(sc)

    print("Running br_render_frame...")
    sc._run(ENTRY_BR_RENDER_FRAME)

    visited = read_visited(sc, n_ss)
    print(f"  Visited {len(visited)}/{n_ss} subsectors")
    if len(visited) == n_ss:
        print("  ✓ All subsectors visited")
    else:
        missing = set(range(n_ss)) - visited
        print(f"  ✗ Missing: {sorted(missing)[:20]}{'...' if len(missing) > 20 else ''}")


if __name__ == '__main__':
    main()
