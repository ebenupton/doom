#!/usr/bin/env python3
"""The copro BOOT STUB, end-to-end in py65 (2026-09-02).

Nothing else covers this code: every other tube gate enters at the
RESIDENT ($F600) with the loads pre-applied, so the stub that runs on
real hardware -- arena zeroing, the OSCLI load loop, the raw-R2 RUN
HOSTT, and above all the UN-STAGE COPY that moves VDESC+sincos from
their $7C00 disc staging into the reclaimed client-OS 1K at $F800 --
shipped without a harness ever executing it.  A wrong page bound or a
botched src->dst offset there is a black screen on hardware and green
gates everywhere else.

Model: COPROT at $7800, COPRES at $F600, a random stage at $7C00-$7FFF,
junk at $F800-$FBFF and in the arenas; OSCLI is an RTS stub (the loads
are the OS's job, not the stub's logic), R2 always-free, R1 empty so
the resident wedges harmlessly at .wm once boot completes.
"""
import os, subprocess, sys, random

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
from py65.memory import ObservableMemory
from py65.devices.mpu65c02 import MPU


def main():
    env = dict(os.environ, DOOM_CPU='65c02')
    subprocess.run(['./beebasm', '-i', 'tube/tubedrv.asm'], check=True,
                   capture_output=True, env=env)
    boot = open('COPROT', 'rb').read()
    res = open('COPRES', 'rb').read()
    os.remove('COPROT'); os.remove('COPRES')

    base = ObservableMemory()
    base[0x7800:0x7800 + len(boot)] = list(boot)
    base[0xF600:0xF600 + len(res)] = list(res)
    random.seed(42)
    stage = [random.randrange(1, 255) for _ in range(0x200)]
    base[0x7C00:0x7E00] = stage                  # as the DATA load delivers
    base[0xF800:0xFA00] = [0xEE] * 0x200         # OS junk to be replaced
    base[0x0400:0x1A00] = [0xAA] * 0x1600        # arena junk to be zeroed
    base[0xFFF7] = 0x60                          # OSCLI -> RTS stub
    base.subscribe_to_read([0xFEFA], lambda a: 0x40)   # R2: always free
    base.subscribe_to_write([0xFEFB], lambda a, v: None)
    base.subscribe_to_read([0xFEF8], lambda a: 0x00)   # R1: empty

    mpu = MPU(memory=base)
    mpu.pc = 0x7800
    mpu.sp = 0xFF                                # boot caps it itself
    reached = False
    for _ in range(2_000_000):
        if mpu.pc == 0xF600:
            reached = True
            break
        mpu.step()
    copied = list(base[0xF800:0xFA00]) == stage
    zeroed = not any(base[0x0400:0x1A00])
    ok = reached and copied and zeroed
    print(f'  reached RESIDENT: {reached}; un-stage copy exact: {copied}; '
          f'arenas zeroed: {zeroed}')
    print('BOOTSTUB: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
