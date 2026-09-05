#!/usr/bin/env python3
"""HUD font-base gate: the MOS glyphs are NOT at a fixed address.

OS 1.2 keeps the 96 glyphs at $C000; MOS 3.20 keeps them at $F900. The
HUD used to hardwire $C000, so on a Master it blitted MOS code and the
readout came out as garbage -- the bug Eben hit on hardware.

Searching for the font was the first fix and it was the wrong one: it
cost 105 bytes, which pushed the banked HUD segment past $A500 into
VDESC, and pressing H crashed the Model B. The drivers now just ASK the
OS which machine this is (OSBYTE 129) at entry, while the OS is still
alive, and pick a base from the answer.

This runs the REAL probe out of both drivers -- walk_drv (host) and
hostg (tube host) -- against a stubbed OSBYTE returning each documented
version byte, and checks the base each one picks. The two probes are
separate code in two assemblers, so both are driven here.
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.chdir(ROOT)
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory
import abi

B, M = abi.HUD_FONT_B, abi.HUD_FONT_MASTER

# OSBYTE 129's returns, and the base each must select.  MEASURED on
# jsbeeb (2026-09-02): Master 128 answers $FD, this B's OS 1.2 answers
# $FF.  The rule is "[$F0,$FE] is the Master/ANDY family" — the old
# '3..$7F is a Master' model here matched the driver's old bug, so the
# gate was green while real Masters drew garbage.
CASES = ((0x00, B, 'OS 1.00'), (0x01, B, 'OS 1.20'), (0x02, B, 'OS 2 (B+)'),
         (0x03, B, 'OS 3-ish? unknown-low'), (0x7F, B, 'unknown-mid'),
         (0xE0, B, 'Electron'), (0x80, B, 'reserved'),
         (0xF5, M, 'MOS 5 Compact'), (0xFC, M, 'Master ET'),
         (0xFD, M, 'Master 128 MOS 3.20'),
         (0xFF, B, 'OS 0.10 (and jsbeeb OS 1.2 answers this)'))
# THE MAPPING (validated live on jsbeeb 2026-09-02, commit 622ad83):
# X in [$F0,$FE] = the Master/ANDY family; everything else including
# $FF takes the $C000 MOS font.  The previous table here expected LOW
# values (3..$7F) to be Masters — the same wrong model as the driver,
# so the gate stayed green while every real Master drew garbage.


def assemble(name, defs, labels):
    """ca65/ld65 since 2026-09-05 (this shelled out to beebasm before).
    Bytes from the link, symbols from ld65's VICE label dump."""
    import build_boot
    out = build_boot.build(name, defs, labels=os.path.join(ROOT, labels))
    code = open(out, 'rb').read()
    return code, build_boot.symbols(os.path.join(ROOT, labels))


def seed_font(mem, base):
    """A synthetic MOS font: space blank, every other glyph inked. The
    probes VALIDATE the base against these two properties (2026-08-29),
    so a stub with no font is now a legitimate 'absent' answer."""
    for c in range(32, 128):
        for i in range(8):
            mem[base + (c - 32) * 8 + i] = 0 if c == 32 else c


def probe(code, org, start, ver, stop_op=None, fonts=()):
    """Run one probe with OSBYTE 129 stubbed to return X = ver."""
    mem = ObservableMemory()
    mem[org:org + len(code)] = list(code)
    for b in fonts:
        seed_font(mem, b)
    mem[0xFFF4], mem[0xFFF5], mem[0xFFF6] = 0xA2, ver, 0x60   # LDX #ver : RTS
    mpu = MPU(memory=mem)
    mpu.pc, mpu.sp = start, 0xFD
    mem[0x01FF], mem[0x01FE] = 0x00, 0xFF                     # RTS -> $0100
    for _ in range(20000):
        if mpu.pc == 0x0100:
            break
        if stop_op is not None and mem[mpu.pc] == stop_op:
            break                     # walk_drv falls straight into SEI
        mpu.step()
    else:
        return None, mem
    return mpu, mem


def main():
    ok = True
    # ---- walk_drv: the probe is inline at the entry, ending at the SEI ----
    # walk_drv is a ca65 LINK UNIT since 749ba62 -- no beebasm pass and no
    # generated labels file.  Take the bytes from the link and the symbols
    # from the map.  (This gate still shelled out to beebasm after the
    # conversion, so it broke the moment walk_drv.asm was retired.)
    import asmbuild, symmap
    asmbuild.build('engine', banked=1)
    code = open(os.path.join(ROOT, 'engine_bk.bin'), 'rb').read()  # driver heads MAIN
    sym = {'drv': symmap.sym('drv', banked=1)}
    print('-- walk_drv (host) --')
    for ver, want, label in CASES:
        _, mem = probe(code, abi.DRV_ORG, sym['drv'], ver, stop_op=0x78)
        got = mem[abi.DV_HUD_FONT] | (mem[abi.DV_HUD_FONT + 1] << 8)
        good = got == want
        ok = ok and good
        print(f'   X=${ver:02X} {label:16s} -> ${got:04X} '
              f'{"ok" if good else f"*** want ${want:04X} ***"}')

    # ---- hostg: a called routine, so run it to its RTS -------------------
    code, sym = assemble('hostg', ['BANKED=1'], 'build/hostt.labels')
    print('-- hostg (tube host) --')
    for ver, want, label in CASES:
        mpu, mem = probe(code, sym['start'], sym['hudprobe'], ver)
        if mpu is None:
            print(f'   X=${ver:02X}: hudprobe never returned')
            ok = False
            continue
        got = mem[sym['hudbase']] | (mem[sym['hudbase'] + 1] << 8)
        good = got == want
        ok = ok and good
        print(f'   X=${ver:02X} {label:16s} -> ${got:04X} '
              f'{"ok" if good else f"*** want ${want:04X} ***"}')
    # Pin the Master claim (2026-08-29): its font is the CURRENT character
    # definitions in ANDY, chars 32-255 x 8 bytes = $700, filling
    # $8900-$8FFF exactly. $F900 -- the constant until this was found --
    # is MOS CODE, which is what the HUD had been drawing as glyphs.
    fits = M == 0x8900 and M + 224 * 8 == 0x9000
    ok = ok and fits
    print(f'   ANDY font ${M:04X} + 224*8 = ${M + 224 * 8:04X} '
          f'{"ok (fills ANDY to $9000)" if fits else "*** not the $8900-$8FFF block ***"}')

    print('HUDFONT: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
