"""Unit-test 6502 bbox_check_angle vs angle_bbox.bbox_check_angle."""
import subprocess, re, sys
from py65.devices.mpu6502 import MPU
import angle_bbox as A

subprocess.run(['./beebasm', '-i', 'slope_div.asm', '-o', 'slope_div.bin'],
               check=True, capture_output=True)
out = subprocess.run(['./beebasm', '-i', 'slope_div.asm', '-v'],
                     capture_output=True, text=True).stdout
BCA = 0xE946
code = open('bsp_render_ang.bin', 'rb').read()

mpu = MPU()
for i, b in enumerate(code):
    mpu.memory[0xE940 + i] = b
for i in range(1024):                            # TA_LO $DC00 / TA_HI $EE00
    v = A._tantoangle[i]
    mpu.memory[0xDC00 + i] = v & 0xFF
    mpu.memory[0xEE00 + i] = (v >> 8) & 0xFF
for idx in range(A.ANG180 + 1):                 # VATOX $4000 (centres, u8)
    c = (A._vatox_lo[idx] + A._vatox_hi[idx]) // 2
    mpu.memory[0xF200 + idx] = max(0, min(255, c))


def w16(addr, v):
    mpu.memory[addr] = v & 0xFF; mpu.memory[addr + 1] = (v >> 8) & 0xFF


def run(top, bot, left, right, px, py, ab):
    w16(0x88, top); w16(0x8A, bot); w16(0x8C, left); w16(0x8E, right)
    mpu.memory[0x90] = px & 0xFF; mpu.memory[0x91] = py & 0xFF
    mpu.memory[0x92] = ab & 0xFF
    mpu.pc = BCA; mpu.sp = 0xFD
    mpu.memory[0x01FF] = 0xFF; mpu.memory[0x01FE] = 0xFF
    steps = 0
    while mpu.pc != 0x0000 and steps < 20000:
        mpu.step(); steps += 1
    vis = mpu.memory[0x95]
    return (mpu.memory[0x93], mpu.memory[0x94]) if vis else None


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
