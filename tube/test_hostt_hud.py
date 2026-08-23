#!/usr/bin/env python3
"""HOSTT debug-HUD gate: drive the REAL host command loop in py65.

The Tube HUD is split across the wire: the copro has neither a
framebuffer nor the OS font, so it ships its 8.8 pose in an
FE FE FE FE packet and HOSTT draws the readout.  test_copro_py65 gates
the parasite's half (one packet a frame, carrying the live DV_* pose);
this gates the HOST's half, which nothing else touches -- the pipeline
gate drives `drawcmd` directly and never sees the packet at all.

Feeds the host's ring a real frame -- one line, the HUD packet, EOF --
and reads the glyphs back out of the buffer the frame was drawn into.
The font at $C000 is synthetic (glyph for character c is eight bytes of
c), so a drawn cell decodes straight back to its ASCII and the check is
on the TEXT, not on a byte blob.

The payload is Eben's own readout from the show-through report,
ffe6.d2 001d.e3 f4, so a pass means the HUD would have printed exactly
the string he quoted.
"""
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
from py65.devices.mpu6502 import MPU          # the host is an NMOS 6502
from py65.memory import ObservableMemory

LABELS = os.path.join(ROOT, 'build', 'hostt.labels')


def assemble():
    os.makedirs(os.path.dirname(LABELS), exist_ok=True)
    subprocess.run(['./beebasm', '-i', 'tube/hostg.asm', '-d',
                    '-labels', LABELS], check=True, cwd=ROOT,
                   stdout=subprocess.DEVNULL)
    with open(os.path.join(ROOT, 'HOSTT'), 'rb') as f:
        code = f.read()
    os.remove(os.path.join(ROOT, 'HOSTT'))
    txt = open(LABELS).read()
    sym = {m.group(1): int(m.group(2))
           for m in re.finditer(r"'(\w+)':(\d+)L?", txt)}
    return code, sym


# zero page, mirroring hostg.asm's map
DRAW, PEND, FREE, EOFS = 0x62, 0x61, 0x63, 0x65
WRL, WRH, RDL, RDH = 0x66, 0x67, 0x68, 0x69
RING = 0x3000                                  # wrh is masked &0F ORA &30

# angidx 0x3D -> angle byte 0xF4; x = $FFE6.D2, y = $001D.E3
PAYLOAD = [0x3D, 0xD2, 0xE6, 0x00,
           0xFF, 0xE3, 0x1D, 0x00,
           0x00, 0x5C, 0x03, 0x00]      # 9 = TRIPWIRE latch, 10 = PAL fields
EXPECT = "X=FFE6.D2 Y=001D.E3 R=F4 F=03"


# The REAL 'A' and '0' glyphs (identical in OS 1.2 and MOS 3.20) -- the
# host's search looks for these two to locate the font. Every other
# character gets eight bytes of its own code so a drawn cell decodes
# straight back to ASCII.
GLYPH_A = [0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00]
GLYPH_0 = [0x3C, 0x66, 0x6E, 0x7E, 0x76, 0x66, 0x3C, 0x00]


def glyph(c):
    return GLYPH_A if c == ord('A') else GLYPH_0 if c == ord('0') else [c] * 8


def install_font(mem, base):
    for a in range(0xC000, 0xFC00):          # nothing that can false-match
        mem[a] = 0xEA
    for c in range(32, 128):
        o = base + (c - 32) * 8
        for i, b in enumerate(glyph(c)):
            mem[o + i] = b


def decode(mem, base_page, n):
    rev = {tuple(glyph(c)): chr(c) for c in range(32, 128)}
    out = ''
    for cell in range(n):
        o = (base_page << 8) + cell * 8
        out += rev.get(tuple(mem[o:o + 8]), '?')
    return out


def run_case(code, sym, font_base):
    mem = ObservableMemory()
    mem[0x1900:0x1900 + len(code)] = list(code)
    install_font(mem, font_base)

    mem[sym['huden']] = 1                      # as if H had been pressed
    mem[DRAW], mem[PEND], mem[FREE], mem[EOFS] = 1, 0xFF, 2, 1
    target_page = mem[sym['bufhi'] + 1]        # the buffer this frame draws into

    stream = ([10, 20, 30, 20] +               # one ordinary horizontal line
              [0xFE] * 4 + PAYLOAD +           # the HUD packet
              [0xFF] * 4)                      # end of frame
    for i, b in enumerate(stream):
        mem[RING + i] = b
    mem[RDL], mem[RDH] = RING & 0xFF, RING >> 8
    mem[WRL], mem[WRH] = (RING + len(stream)) & 0xFF, (RING + len(stream)) >> 8

    mpu = MPU(memory=mem)
    mpu.pc = sym['main']
    mpu.sp = 0xFF
    for _ in range(2_000_000):
        if mpu.pc == sym['skipchk']:           # frame consumed, HUD drawn
            break
        mpu.step()
    else:
        print('HOSTT-HUD: FAIL - the host never completed the frame')
        return 1

    base = target_page << 8
    got = decode(mem, target_page, len(EXPECT))
    ok = got == EXPECT
    print(f'   drawn: "{got}"')

    # and with the HUD off, the row must be untouched
    mem[sym['huden']] = 0
    for i, b in enumerate(stream):
        mem[RING + i] = b
    mem[RDL], mem[RDH] = RING & 0xFF, RING >> 8
    mem[WRL], mem[WRH] = (RING + len(stream)) & 0xFF, (RING + len(stream)) >> 8
    mem[DRAW], mem[PEND], mem[FREE], mem[EOFS] = 1, 0xFF, 2, 1
    for i in range(len(EXPECT) * 8):
        mem[base + i] = 0
    mpu.pc = sym['main']; mpu.sp = 0xFF
    for _ in range(2_000_000):
        if mpu.pc == sym['skipchk']:
            break
        mpu.step()
    off_clean = not any(mem[base + i] for i in range(len(EXPECT) * 8))
    if not off_clean:
        print('  FAIL: the HUD drew with huden = 0')
    ok = ok and off_clean

    return ok


def main():
    code, sym = assemble()
    allok = True
    # Model B keeps the font at $C000, the Master at $F900. The host must
    # find BOTH -- reading $C000 on a Master is MOS code, which is exactly
    # how the HUD came out corrupted there.
    for name, base in (('Model B  $C000', 0xC000), ('Master   $F900', 0xF900)):
        print(f'-- font at {name} --')
        ok = run_case(code, sym, base)
        print(f'   {"ok" if ok else "FAILED"}')
        allok = allok and ok
    print('HOSTT-HUD: ' + ('PASS' if allok else 'FAIL'))
    return 0 if allok else 1


if __name__ == '__main__':
    sys.exit(main())
