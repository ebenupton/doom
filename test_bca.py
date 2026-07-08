"""Unit-test 6502 bbox_check_angle vs angle_bbox.bbox_check_angle."""
import subprocess, re, sys
import angle_bbox as A
import asmbuild

if asmbuild.env_c02():
    from py65.devices.mpu65c02 import MPU
else:
    from py65.devices.mpu6502 import MPU

from engine_load import load_angle_module
from symmap import sym

mpu = MPU()
load_angle_module(mpu.memory)
BCA = sym('jt_bca_check')
BOX = sym('bca_top')


def w16(addr, v):
    mpu.memory[addr] = v & 0xFF; mpu.memory[addr + 1] = (v >> 8) & 0xFF


def run(top, bot, left, right, px, py, ab):
    w16(sym('bca_top'), top); w16(sym('bca_bot'), bot)
    w16(sym('bca_left'), left); w16(sym('bca_right'), right)
    mpu.memory[sym('bca_px')] = px & 0xFF
    mpu.memory[sym('bca_py')] = py & 0xFF
    mpu.memory[sym('bca_ab')] = ab & 0xFF
    afn = (ab << 4) & 0xFFFF          # a_fine now precomputed by the caller
    w16(sym('bca_afn'), afn)
    mpu.memory[sym('bca_pxs')] = px & 0xFF
    mpu.memory[sym('bca_pxs') + 1] = 0xFF if px < 0 else 0
    mpu.memory[sym('bca_pys')] = py & 0xFF
    mpu.memory[sym('bca_pys') + 1] = 0xFF if py < 0 else 0
    w16(sym('bca_boxp'), BOX)                       # box pointer -> bca_top
    mpu.pc = BCA; mpu.sp = 0xFD
    mpu.memory[0x01FF] = 0xFF; mpu.memory[0x01FE] = 0xFF
    steps = 0
    while mpu.pc != 0x0000 and steps < 20000:
        mpu.step(); steps += 1
    vis = mpu.memory[sym('bca_vis')]
    return (mpu.memory[sym('bca_ilo')], mpu.memory[sym('bca_ihi')]) if vis else None


# sample boxes around the map, varied viewer positions/angles
boxes = [(80, -80, -80, 80), (40, 10, -60, -20), (120, 60, 20, 90),
         (-10, -50, 30, 70), (100, -100, -100, 100), (20, 5, 5, 40)]
fails = checked = 0
exam = []
for (top, bot, left, right) in boxes:
    for px in range(-120, 121, 13):
        for py in range(-120, 121, 13):
            for ab in range(0, 256, 17):
                exp = A.bbox_check_angle(top, bot, left, right, px, py, ab)
                got = run(top, bot, left, right, px, py, ab)
                checked += 1
                # compare (treat None vs None; tuples exact)
                if exp != got:
                    fails += 1
                    if len(exam) < 14:
                        exam.append(((top, bot, left, right, px, py, ab), got, exp))
for e in exam:
    print("  ", e)
print(f"bbox_check_angle: checked {checked}, {fails} mismatches "
      f"({100*fails/checked:.2f}%)")
print("PASS" if fails == 0 else "FAIL")
sys.exit(1 if fails else 0)
