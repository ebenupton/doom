#!/usr/bin/env python3
"""hud_draw gate (banked build): run the REAL linked HUD blitter in py65.

Nothing else covers this code. The tube host has its own blitter in
beebasm (gated by tube/test_hostt_hud.py); this is the engine-side one
that runs when H is pressed on a plain Model B or a Master, out of the
bank C window at $A400.

Two things it pins:

  * both font bases. $C000 is glyph-aligned and $F900 is not, so on a
    Master the (ascii-32)*8 offset add CARRIES out of the low byte --
    a path the $C000 case never exercises.

  * the segment stays clear of $A500. banked_bsp seeds VDESC there, and
    when the HUD grew a font search it ran straight into it and pressing
    H crashed the Model B.

Both CPU variants are run. That is not ceremony: the entry guard used to
branch on the flags left by the ZERO macro, which is LDA #0 on NMOS but
STZ on the 65C02 host build -- where it sets no flags at all, so the HUD
silently drew nothing.

The font is synthetic (glyph for character c is eight bytes of c), so
the drawn row decodes back to ASCII and the check is on the TEXT.
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory
import symmap, abi

HUD_ORG = 0xA400
VDESC = 0xA500                 # banked_bsp.py seeds the vertex-span descriptors
FB = abi.SCREEN0

POSE = {'DV_ANGIDX': 0x3D, 'DV_BACKHI': FB >> 8,
        'DV_PXF': 0xD2, 'DV_PXL': 0xE6, 'DV_PXH': 0xFF,
        'DV_PYF': 0xE3, 'DV_PYL': 0x1D, 'DV_PYH': 0x00,
        'DV_FIELDS': 0x03}
EXPECT = "X=FFE6.D2 Y=001D.E3 R=F4 F=03"     # angidx $3D * 4 = $F4


def run(img, base, c02):
    mem = ObservableMemory()
    mem[HUD_ORG:HUD_ORG + len(img)] = list(img)
    for c in range(32, 128):                 # synthetic font
        o = base + (c - 32) * 8
        for i in range(8):
            mem[o + i] = c
    for name, v in POSE.items():
        mem[getattr(abi, name)] = v
    mem[abi.DV_HUD_FONT] = base & 0xFF
    mem[abi.DV_HUD_FONT + 1] = base >> 8
    mpu = MPU(memory=mem)
    mpu.pc, mpu.sp = symmap.sym('hud_draw', banked=1, c02=c02), 0xFD
    mem[0x01FF], mem[0x01FE] = 0x00, 0xFF    # RTS -> $0100
    for _ in range(200_000):
        if mpu.pc == 0x0100:
            break
        mpu.step()
    else:
        return None, mem
    out = ''
    for cell in range(len(EXPECT)):
        g = set(mem[FB + cell * 8:FB + cell * 8 + 8])
        out += chr(g.pop()) if len(g) == 1 else '?'
    return out, mem


def main():
    import asmbuild
    ok = True
    for c02 in (0, 1):
        print(f'== {"65C02 host" if c02 else "NMOS 6502 host"} ==')
        asmbuild.build_all(banked=1, c02=c02, force=True)
        ok = one(c02) and ok
    asmbuild.build_all(banked=1, c02=0, force=True)      # leave NMOS on disk
    print('HUDDRAW: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


def one(c02):
    img = open(os.path.join(ROOT, 'bsp_render_hud_bk.bin'), 'rb').read()
    ok = True

    fits = HUD_ORG + len(img) <= VDESC
    ok = ok and fits
    print(f'  segment ${HUD_ORG:04X}-${HUD_ORG + len(img) - 1:04X} ({len(img)} B), '
          f'VDESC at ${VDESC:04X}  '
          f'{"ok" if fits else "*** OVERLAPS -- H will crash ***"}')

    for label, base in (('Model B  $C000', abi.HUD_FONT_B),
                        ('Master   $F900', abi.HUD_FONT_MASTER)):
        got, mem = run(img, base, c02)
        if got is None:
            print(f'  {label}: hud_draw never returned')
            ok = False
            continue
        # the blit must stay inside row 0 -- a bad font pointer used to
        # spray 192 bytes over a random page
        spill = any(mem[FB + 0x100 + i] for i in range(256))
        good = got == EXPECT and not spill
        ok = ok and good
        print(f'  {label}: "{got}"  {"ok" if good else "*** WRONG ***"}'
              + ('  SPILLED past row 0' if spill else ''))

    # and with no probe result (0), it must draw nothing rather than blit
    # from page zero
    mem = ObservableMemory()
    mem[HUD_ORG:HUD_ORG + len(img)] = list(img)
    for name, v in POSE.items():
        mem[getattr(abi, name)] = v
    mem[abi.DV_HUD_FONT] = mem[abi.DV_HUD_FONT + 1] = 0
    mpu = MPU(memory=mem)
    mpu.pc, mpu.sp = symmap.sym('hud_draw', banked=1, c02=c02), 0xFD
    mem[0x01FF], mem[0x01FE] = 0x00, 0xFF
    for _ in range(200_000):
        if mpu.pc == 0x0100:
            break
        mpu.step()
    quiet = not any(mem[FB + i] for i in range(256))
    ok = ok and quiet
    print(f'  no probe result    : {"drew nothing, ok" if quiet else "*** DREW ***"}')
    return ok


if __name__ == '__main__':
    sys.exit(main())
