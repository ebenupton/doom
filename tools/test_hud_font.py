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
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory
import abi

B, M = abi.HUD_FONT_B, abi.HUD_FONT_MASTER

# OSBYTE 129's documented returns, and the base each one must select.
# The rule is "3..$7F is a Master-class MOS": 3 = MOS 3.20 (Master 128),
# 4 = OS 3.50, 5 = MOS 5 (Master Compact -- ASSUMED, unverified). $FF is
# OS 0.10, which is older than 1.2, not newer.
CASES = ((0x00, B, 'OS 1.00'), (0x01, B, 'OS 1.20'), (0x02, B, 'OS 2 (B+)'),
         (0x03, M, 'MOS 3.20 Master'), (0x04, M, 'OS 3.50'),
         (0x05, M, 'MOS 5 Compact'), (0x7F, M, 'high version'),
         (0x80, B, 'reserved/neg'), (0xFF, B, 'OS 0.10'))


def assemble(src, defs, out, labels):
    subprocess.run(['./beebasm', '-i', src] + defs + ['-d', '-labels', labels],
                   check=True, cwd=ROOT, stdout=subprocess.DEVNULL)
    code = open(os.path.join(ROOT, out), 'rb').read()
    os.remove(os.path.join(ROOT, out))
    sym = {m.group(1): int(m.group(2))
           for m in re.finditer(r"'(\w+)':(\d+)L?", open(labels).read())}
    return code, sym


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
    code, sym = assemble('walk_drv.asm', ['-D', 'BANKED=1'],
                         'WALKDRV', 'build/walkdrv.labels')
    print('-- walk_drv (host) --')
    for ver, want, label in CASES:
        _, mem = probe(code, abi.DRV_ORG, sym['drv'], ver, stop_op=0x78)
        got = mem[abi.DV_HUD_FONT] | (mem[abi.DV_HUD_FONT + 1] << 8)
        good = got == want
        ok = ok and good
        print(f'   X=${ver:02X} {label:16s} -> ${got:04X} '
              f'{"ok" if good else f"*** want ${want:04X} ***"}')

    # ---- hostg: a called routine, so run it to its RTS -------------------
    code, sym = assemble('tube/hostg.asm', [], 'HOSTT', 'build/hostt.labels')
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
