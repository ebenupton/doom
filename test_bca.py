"""Unit-test 6502 bbox_check_angle vs angle_bbox.bbox_check_angle."""
import subprocess, re, sys
import angle_bbox as A
import asmbuild

if asmbuild.env_c02():
    from py65.devices.mpu65c02 import MPU
else:
    from py65.devices.mpu6502 import MPU

asmbuild.build('slope_div.asm', banked=0)
BCA = 0xE943
code = open('bsp_render_ang.bin', 'rb').read()

mpu = MPU()
for i, b in enumerate(code):
    mpu.memory[0xE940 + i] = b
for i in range(1024):                            # TA_LO $DC00 / TA_HI $EE00
    v = A._tantoangle[i]
    mpu.memory[0xDC00 + i] = v & 0xFF
    mpu.memory[0xF200 + i] = (v >> 8) & 0xFF
for k in range(1025):                           # VATOX shrunk: phi+512, $F300
    c = (A._vatox_lo[k + 512] + A._vatox_hi[k + 512]) // 2
    mpu.memory[0xF601 + k] = max(0, min(255, c))


def w16(addr, v):
    mpu.memory[addr] = v & 0xFF; mpu.memory[addr + 1] = (v >> 8) & 0xFF


def run(top, bot, left, right, px, py, ab):
    w16(0xFA10, top); w16(0xFA12, bot); w16(0xFA14, left); w16(0xFA16, right)
    mpu.memory[0x01] = px & 0xFF; mpu.memory[0x03] = py & 0xFF
    mpu.memory[0xFA2F] = ab & 0xFF
    afn = (ab << 4) & 0xFFFF          # a_fine now precomputed by the caller
    mpu.memory[0x3B] = afn & 0xFF; mpu.memory[0x3C] = (afn >> 8) & 0xFF
    mpu.memory[0x8D] = px & 0xFF; mpu.memory[0x8E] = 0xFF if px < 0 else 0  # bca_pxs
    mpu.memory[0x9B] = py & 0xFF; mpu.memory[0x9C] = 0xFF if py < 0 else 0  # bca_pys
    mpu.memory[0x86] = 0x10; mpu.memory[0x87] = 0xFA   # bca_boxp -> box at $FA10
    mpu.pc = BCA; mpu.sp = 0xFD
    mpu.memory[0x01FF] = 0xFF; mpu.memory[0x01FE] = 0xFF
    steps = 0
    while mpu.pc != 0x0000 and steps < 20000:
        mpu.step(); steps += 1
    vis = mpu.memory[0xFA32]
    return (mpu.memory[0xFA30], mpu.memory[0xFA31]) if vis else None


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
