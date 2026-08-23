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
           0x00, 0x00, 0x00, 0x00]
EXPECT = "X=FFE6.D2 Y=001D.E3 R=F4"


def main():
    code, sym = assemble()
    mem = ObservableMemory()
    mem[0x1900:0x1900 + len(code)] = list(code)

    # synthetic OS font: glyph(c) = eight bytes of c, so a cell decodes
    # back to its own ASCII
    for c in range(32, 128):
        for i in range(8):
            mem[0xC000 + (c - 32) * 8 + i] = c

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
    got = ''
    for cell in range(len(EXPECT)):
        col = mem[base + cell * 8: base + cell * 8 + 8]
        if len(set(col)) != 1:                 # a glyph is 8 copies of its code
            got += '?'
        else:
            got += chr(col[0])
    ok = got == EXPECT
    print(f'  drawn: "{got}"')
    print(f'  want : "{EXPECT}"')

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

    print('HOSTT-HUD: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
