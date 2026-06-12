"""Unit test: br_project_x_wide vs Python full-width projection.

sx = 128 + evx*rxh + (evx*rxl >> 8) + (frac*rxh >> 8)   (mod 2^16, s16)
evx s16 outside s8 range, frac u8, rxh in [0,127], rxl u8.
"""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'

from span_clip_6502 import SpanClip6502
import subprocess, re


def _find_label(label):
    """Resolve a label's address from the beebasm verbose listing."""
    out = subprocess.run(['./beebasm', '-i', 'bsp_render.asm', '-v'],
                         capture_output=True, text=True).stdout
    m = re.search(r'\.%s\n\s+([0-9A-F]{4})' % re.escape(label), out)
    if not m:
        raise RuntimeError(f'label {label} not found in listing')
    return int(m.group(1), 16)


ENTRY_WIDE = _find_label('br_project_x_wide')

ZP_V_XINT, ZP_V_XFRAC, ZP_V_XEXT = 0x37, 0x38, 0x75
ZP_RHI, ZP_RLO = 0x1A, 0x1B
ZP_RESL, ZP_RESH = 0x17, 0x18


def py_ref(evx, frac, rxh, rxl):
    sx = 128 + evx * rxh + ((evx * rxl) >> 8) + ((frac * rxh) >> 8)
    return sx & 0xFFFF


def run_6502(sc, evx, frac, rxh, rxl):
    mem = sc.mpu.memory
    mem[ZP_V_XINT] = evx & 0xFF
    mem[ZP_V_XEXT] = (evx >> 8) & 0xFF
    mem[ZP_V_XFRAC] = frac & 0xFF
    mem[ZP_RHI] = rxh
    mem[ZP_RLO] = rxl
    sc._run(ENTRY_WIDE)
    return mem[ZP_RESL] | (mem[ZP_RESH] << 8)


if __name__ == '__main__':
    sc = SpanClip6502()
    import random
    random.seed(42)
    cases = []
    # Systematic edges
    for evx in (-32768, -32767, -2048, -300, -129, -128, 128, 129, 300,
                2047, 2048, 32767):
        for frac in (0, 1, 127, 128, 255):
            for rxh in (0, 1, 9, 64, 127):
                for rxl in (0, 1, 128, 255):
                    cases.append((evx, frac, rxh, rxl))
    # Random sweep
    for _ in range(2000):
        evx = random.choice([random.randint(-32768, -129),
                             random.randint(128, 32767)])
        cases.append((evx, random.randint(0, 255),
                      random.randint(0, 127), random.randint(0, 255)))

    fails = 0
    for evx, frac, rxh, rxl in cases:
        want = py_ref(evx, frac, rxh, rxl)
        got = run_6502(sc, evx, frac, rxh, rxl)
        if want != got:
            fails += 1
            if fails <= 10:
                print(f'FAIL evx={evx} frac={frac} rxh={rxh} rxl={rxl}: '
                      f'want {want:04X} got {got:04X}')
    print(f'{len(cases) - fails}/{len(cases)} pass')
