#!/usr/bin/env python3
"""Reproduce real-HW boot conditions in the faithful banked_mem model.

Real hardware after the bootloader has: banks 4/6/7 loaded, LOW file at
$1B40-$5784 loaded, and everything else in low RAM = whatever was there at
power-on (we model it as zeros, the optimistic 'freshly zeroed' case). The DRV
driver ($3C00) is the ONLY thing that initializes ZP/table-pointers before it
SEIs, sets CRTC, runs span_init, clears the FB, and renders one frame.

This drives the EXACT driver bytes (from the assembled DRV file) through py65 on
a BankedMemory built from that bare state, then compares the resulting frame to
the reference model render of the same spawn. If this passes, the disc+driver is
correct and any jsbeeb-Master failure is a Master-emulator artifact (shadow RAM,
etc). If it fails, we've found the real bug cheaply (no jsbeeb round-trips)."""
import os
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
from banked_mem import BankedMemory
from banked_bsp import BankedBspRender, BANK_L0, BANK_C, BANK_L2
from span_clip_6502 import SpanClip6502

SPAWN = (1056, -3616, 128)
import abi
import symmap
DRV_ADDR = abi.DRV_ORG
# SPIN (.spin JMP self, see banked_boot.asm DRV) is found by scanning DRV
# for the self-jump — the driver shrinks/moves with layout work.
FB_LO, FB_HI = 0x5800, 0x6C00     # true 256x160 mode-4 framebuffer = 5K (20 pages)


def fb_bytes(mem):
    return bytes(mem[FB_LO:FB_HI])


def main():
    # --- reference: normal verified model render of the same spawn ---
    ref = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                          dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    px, py, ab = SPAWN
    fz = dw.player_floor(px, py)
    # OBJECTS OFF (bb6491f default): the hardware driver boots billboards
    # off, so the reference frame must too.
    from bsp_render_6502 import disable_objects
    disable_objects(ref.sc.mpu.memory)
    ref.render_frame(px, py, ab, fz)
    ref_fb = fb_bytes(ref.bm)
    ref_nz = sum(1 for b in ref_fb if b)
    print(f"reference frame: {ref_nz} non-zero FB bytes")

    # --- bank + LOW images, exactly as build_banked_ssd extracts them ---
    src = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                          dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    L0 = bytes(src.bm._banks[BANK_L0])
    C  = bytes(src.bm._banks[BANK_C])
    L2 = bytes(src.bm._banks[BANK_L2])
    import os as _os
    LOW = bytes(src.bm[abi.LOW_BASE:abi.MAIN_BASE + _os.path.getsize('bsp_render_bk.bin')])  # LOW base = strip head (abi)
    import subprocess as _sp
    import asmbuild
    asmbuild.gen_engine_syms()              # driver entries from the ld65 map
    _sp.run(['./beebasm', '-i', 'banked_boot.asm'], check=True)  # fresh DRV
    DRV = open('DRV', 'rb').read()

    def build_and_run(zp_poison=None, ram_poison=None):
        return _boot(L0, C, L2, LOW, DRV, zp_poison, ram_poison)

    bare, bare_fb = build_and_run()
    poisoned, pois_fb = build_and_run(0xA5)
    # FULL-JUNK arm (2026-09-01, the jsbeeb spawn-artefact class): real
    # hardware does not hand the engine zeroed RAM anywhere.  Junk-fill
    # ALL non-shipped memory; the boot must produce the identical frame.
    junk, junk_fb = build_and_run(0xA5, ram_poison=0xE5)
    if junk_fb != bare_fb:
        dj = sum(1 for a, b in zip(junk_fb, bare_fb) if a != b)
        print(f"\nFAIL — {dj} FB bytes differ when ALL unshipped RAM is junk "
              f"(the hardware-boot class the zero-RAM model hides)")
        return 1
    ref_ok = bare_fb == ref_fb
    pois_ok = pois_fb == bare_fb
    print(f"bare frame: {sum(1 for b in bare_fb if b)} non-zero FB bytes")
    print(f"ZP-poisoned frame: {sum(1 for b in pois_fb if b)} non-zero FB bytes")
    if not pois_ok:
        d = sum(1 for a, b in zip(pois_fb, bare_fb) if a != b)
        print(f"\nFAIL — {d} FB bytes differ when zero page starts as $A5.\n"
              f"  The engine reads ZP bytes it never writes and relies on them\n"
              f"  being 0.  Real hardware does not provide that: the parasite's\n"
              f"  ZP holds tube MOS workspace and the host's holds OS/BASIC\n"
              f"  leftovers.  Run tools/zpvirgin.py to list the consumers, and\n"
              f"  check the drivers' zpclr blocks still run.")
    if ref_ok and pois_ok:
        print("\nPASS — bare-boot driver frame is bit-identical to the model "
              "reference, and immune to a poisoned zero page")
    elif not ref_ok:
        diff = sum(1 for a, b in zip(bare_fb, ref_fb) if a != b)
        print(f"\nFAIL — {diff} FB bytes differ from reference")
        _ss = symmap.sym('ANIM_SSMASK', banked=1)
        print(f"  ssmask ${_ss:04X} = {' '.join('%02X'%bare[_ss+i] for i in range(8))}")
    return


def _boot(L0, C, L2, LOW, DRV, zp_poison, ram_poison=None):
    # --- bare machine: banks + LOW + driver, nothing else.  RAM starts
    # zeroed, OR with zero page poisoned: hardware does NOT hand the
    # engine a zeroed ZP, so both must render identically.
    sc = SpanClip6502()
    bare = BankedMemory([ram_poison if ram_poison is not None else 0] * 65536)
    bare.define_bank(BANK_L0, L0)
    bare.define_bank(BANK_C, C)
    bare.define_bank(BANK_L2, L2)
    for i, b in enumerate(LOW):
        bare[abi.LOW_BASE + i] = b
    for i, b in enumerate(DRV):
        bare[DRV_ADDR + i] = b
    bare.select(BANK_L0)
    if zp_poison is not None:
        for a in range(0x100):
            bare[a] = zp_poison
    sc.mpu.memory = bare

    # --- run the driver from DRV_ADDR until it reaches the spin loop ---
    mpu = sc.mpu
    mpu.pc = DRV_ADDR
    mpu.sp = 0xDD  # SP capped below SQR_MIRROR ($01E0-$01FF, the stack-page mirror) — the driver TXSes to $DF itself
    mpu.p = 0x34            # I set (SEI will set it too)
    steps = 0
    MAX = 30_000_000
    reached = False
    while steps < MAX:
        pc0 = mpu.pc
        mpu.step()
        steps += 1
        if mpu.pc == pc0:        # JMP self == driver spin loop reached
            reached = True
            break
    tag = 'poisoned' if zp_poison is not None else 'clean'
    print(f"driver[{tag}]: {'reached spin at $%04X'%mpu.pc if reached else f'STUCK at ${mpu.pc:04X}'} "
          f"after {steps:,} steps")
    return bare, fb_bytes(bare)


if __name__ == '__main__':
    main()
