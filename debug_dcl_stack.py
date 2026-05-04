"""Instruction-level trace of DCL when called from inside BSP.

We step the simulator manually until PC reaches the JSR-DCL site,
then trace until SP underflows (or something obvious happens)."""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

from span_clip_6502 import SpanClip6502
import doom_wireframe as dw

# Patch render_subsector to call DCL with hardcoded line.
sc = SpanClip6502()
mem = sc.mpu.memory

# Load WAD.
layout = dw.packed_layout
for i, b in enumerate(dw.packed_rom_main):
    mem[0x9000 + i] = b
for i, b in enumerate(dw.packed_rom_detail):
    mem[0xC000 + i] = b
def w16(a, v):
    mem[a] = v & 0xFF
    mem[a+1] = (v >> 8) & 0xFF
w16(0x40, 0x9000 + layout['off_verts'])
w16(0x42, 0x9000 + layout['off_nodes'])
w16(0x44, 0x9000 + layout['off_ss'])
w16(0x46, 0x9000 + layout['off_seg_hdr'])
w16(0x48, 0x9000 + layout['off_vwh'])
w16(0x4A, 0xC000)
w16(0x4C, layout['n_nodes'] - 1)

sc.init()
sc.clear_screen()

# Override br_render_subsector to: store a marker, call DCL, store another marker.
# Find the address by inspecting bsp_render.bin code.
# Easier: poke a small inline routine at $4F00 and patch the JMP at $480F.

# Build at $4F00:
#   mark "entered" at $0BF0, set up line, JSR DCL, mark "after DCL" at $0BF1, RTS.
patch = [
    0xEE, 0xF0, 0x0B,       # INC $0BF0
    0xA9, 50, 0x85, 0xA8,   # LDA #50; STA $A8
    0xA9, 100, 0x85, 0xA9,  # LDA #100; STA $A9
    0xA9, 200, 0x85, 0xAA,  # LDA #200; STA $AA
    0xA9, 100, 0x85, 0xAB,  # LDA #100; STA $AB
    0xA9, 0, 0x85, 0xB2,    # LDA #0; STA $B2
    0x85, 0xB3,             # STA $B3
    0x85, 0xB4,             # STA $B4
    0x85, 0xB5,             # STA $B5
    0x85, 0xBD,             # STA $BD
    0x20, 0x15, 0x20,       # JSR $2015 (draw_clipped_line, u8)
    0xEE, 0xF1, 0x0B,       # INC $0BF1
    0x60,                   # RTS
]
for i, b in enumerate(patch):
    mem[0x4F00 + i] = b

# Find br_render_subsector: it's the target of the JSR in the BSP loop.
# Easier: just patch the entry to call our routine.
# Actually let's just call our routine directly from the test: skip the BSP
# walk and JSR our routine to see if standalone calling from a deeper stack
# frame fails the same way.

# Stub at $0500: JSR $4F00, then JSR $4F00 again, then RTS.
mem[0x0500] = 0x20; mem[0x0501] = 0x00; mem[0x0502] = 0x4F  # JSR $4F00
mem[0x0503] = 0x20; mem[0x0504] = 0x00; mem[0x0505] = 0x4F  # JSR $4F00 (again)
mem[0x0506] = 0x60  # RTS

mem[0x0BF0] = 0; mem[0x0BF1] = 0
sc._run(0x0500, max_cycles=500000)
print(f'after stub run: $0BF0 (entered) = {mem[0x0BF0]}, $0BF1 (after DCL) = {mem[0x0BF1]}')
print(f'final PC: ${sc.mpu.pc:04X}')

# Now run from BSP entry.
sc.init()
sc.clear_screen()
mem[0x0BF0] = 0; mem[0x0BF1] = 0

# Patch the BSP's JSR br_render_subsector ($4815 entry → JMP br_render_frame
# → loop → JSR br_render_subsector). Find the JSR by scanning.
# Easier: patch $4F00 + offset to be the BSP's JSR target.
# Actually, we replace br_render_subsector itself. Find its address.
# br_render_subsector is in bsp_render.asm — let's just put our patch
# at a known address and patch the BSP's call.

# Get br_render_subsector's address by reading the JSR site.
# Look at the BSP loop: scan for "JSR" near the bsp_loop area.
# Easiest: find the pattern "AND #$7F : STA chhi : JSR ..."
# bsp_render.bin starts at $4800. Scan it for the BSP subsector dispatch.
for addr in range(0x4800, 0x5000):
    if mem[addr] == 0x29 and mem[addr+1] == 0x7F:
        if mem[addr+2] == 0x85 and mem[addr+4] == 0x20:
            print(f'found subsector dispatch at ${addr:04X}: JSR ${mem[addr+6]<<8 | mem[addr+5]:04X}')
            # Patch the JSR target to $4F00.
            mem[addr+5] = 0x00
            mem[addr+6] = 0x4F
            break

# Run BSP with patched render_subsector.
sc._run(0x4815, max_cycles=2000000)
print(f'after bsp run: $0BF0 (entered) = {mem[0x0BF0]}, $0BF1 (after DCL) = {mem[0x0BF1]}')
print(f'final PC: ${sc.mpu.pc:04X}')
