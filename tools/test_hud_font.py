#!/usr/bin/env python3
"""hud_find gate (banked build): the MOS font is NOT at a fixed address.

OS 1.2 keeps the 96 glyphs at $C000; MOS 3.20 keeps them at $F900. The
HUD used to hardwire $C000, so on a Master it blitted MOS code (or HAZEL
RAM, depending on ACCCON) and the readout came out as garbage -- the bug
Eben hit on hardware. hud_find searches for the 'A' glyph and derives the
base, confirming with '0'.

Runs the REAL linked hud_find in py65 against a memory image with the
font planted at each address in turn, and requires it to find both. The
tube host has the same search, gated end-to-end by tube/test_hostt_hud.py.
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory
import symmap

# the two reference glyphs hud_find searches for, byte-identical in both ROMs
GLYPH_A = [0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00]
GLYPH_0 = [0x3C, 0x66, 0x6E, 0x7E, 0x76, 0x66, 0x3C, 0x00]

CASES = ((0xC000, 'Model B / OS 1.2'),
         (0xF900, 'Master  / MOS 3.20'))


def glyph(c):
    return GLYPH_A if c == 65 else GLYPH_0 if c == 48 else [c] * 8


def main():
    find = symmap.sym('hud_find', banked=1)
    font = symmap.sym('DV_HUD_FONT', banked=1)
    img = open(os.path.join(ROOT, 'bsp_render_hud_bk.bin'), 'rb').read()
    ok = True
    for base, label in CASES:
        mem = ObservableMemory()
        mem[0xA400:0xA400 + len(img)] = list(img)
        for a in range(0xC000, 0xFC00):        # nothing that can false-match
            mem[a] = 0xEA
        for c in range(32, 128):
            o = base + (c - 32) * 8
            for i, b in enumerate(glyph(c)):
                mem[o + i] = b
        mem[font] = mem[font + 1] = 0          # not searched yet
        # the rest of the driver block must be untouched: DV_HUD_FONT once
        # sat on walk_drv's space_prev/mv_dir and hud_find silently ate the
        # input state.
        import abi as _abi
        blk = _abi.DRV_VARS
        for i in range(16):
            if blk + i not in (font, font + 1):
                mem[blk + i] = 0x5A
        mpu = MPU(memory=mem)
        mpu.pc, mpu.sp = find, 0xFD
        mem[0x01FF], mem[0x01FE] = 0x00, 0xFF  # RTS -> $0100
        for _ in range(4_000_000):
            if mpu.pc == 0x0100:
                break
            mpu.step()
        else:
            print(f'  {label}: hud_find never returned')
            ok = False
            continue
        got = mem[font] | (mem[font + 1] << 8)
        smashed = [i for i in range(16)
                   if blk + i not in (font, font + 1) and mem[blk + i] != 0x5A]
        if smashed:
            print(f'  {label}: hud_find wrote DRV_VARS+{smashed} '
                  f'-- it must only touch its own two bytes')
        good = got == base and not smashed
        ok = ok and good
        print(f'  {label}: font at ${base:04X} -> found ${got:04X}'
              f'  {"ok" if good else "*** WRONG ***"}')

    # and a machine with no font at all must be reported, not guessed at
    mem = ObservableMemory()
    mem[0xA400:0xA400 + len(img)] = list(img)
    for a in range(0xC000, 0xFC00):
        mem[a] = 0xEA
    mem[font] = mem[font + 1] = 0
    mpu = MPU(memory=mem)
    mpu.pc, mpu.sp = find, 0xFD
    mem[0x01FF], mem[0x01FE] = 0x00, 0xFF
    for _ in range(4_000_000):
        if mpu.pc == 0x0100:
            break
        mpu.step()
    none_ok = mem[font + 1] == 0xFF
    ok = ok and none_ok
    print(f'  no font present     : sentinel ${mem[font + 1]:02X}'
          f'  {"ok" if none_ok else "*** should be $FF ***"}')

    print('HUDFONT: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
