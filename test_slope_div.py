"""Unit-test the 6502 slope_div against angle_bbox.slope_div (Python)."""
import subprocess, sys
from py65.devices.mpu6502 import MPU
import angle_bbox as A

subprocess.run(['./beebasm', '-i', 'slope_div.asm', '-o', 'slope_div.bin'],
               check=True, capture_output=True)
code = open('bsp_render_ang.bin', 'rb').read()

mpu = MPU()
for i, b in enumerate(code):
    mpu.memory[0xE940 + i] = b
mpu.memory[0xFFFE] = 0x00; mpu.memory[0xFFFF] = 0xFF  # IRQ vec sink
mpu.memory[0xFF00] = 0x00  # BRK lands here -> we detect via PC


def run(num, den):
    mpu.memory[0x44] = num & 0xFF; mpu.memory[0x45] = (num >> 8) & 0xFF
    mpu.memory[0x46] = den & 0xFF; mpu.memory[0x47] = (den >> 8) & 0xFF
    mpu.pc = 0xE940
    mpu.sp = 0xFD
    mpu.memory[0x01FF] = 0xFF; mpu.memory[0x01FE] = 0xFF  # RTS -> $0000
    steps = 0
    while mpu.pc != 0x0000 and steps < 2000:
        mpu.step(); steps += 1
    return mpu.memory[0x48] | (mpu.memory[0x49] << 8)


fails = 0
checked = 0
for den in range(1, 661):
    for num in range(0, den + 1):
        exp = A.slope_div(num, den)
        got = run(num, den)
        checked += 1
        if got != exp:
            fails += 1
            if fails <= 10:
                print(f"  MISMATCH num={num} den={den}: 6502={got} py={exp}")
print(f"slope_div: checked {checked} (num,den) pairs, {fails} mismatches")

# ---- point_to_angle ----
# load tantoangle table: TA_LO=$3000, TA_HI=$3800 (1025 entries)
for i in range(1024):
    v=A._tantoangle[i]
    mpu.memory[0xDC00 + i] = v & 0xFF
    mpu.memory[0xEF00 + i] = (v >> 8) & 0xFF
PA = None
out = subprocess.run(['./beebasm', '-i', 'slope_div.asm', '-v'],
                     capture_output=True, text=True).stdout
import re
m = re.search(r'\.point_to_angle\n\s+([0-9A-F]{4})', out)
PA = int(m.group(1), 16)


def s16(v):
    return v & 0xFFFF


def run_pa(dx, dy):
    mpu.memory[0x30] = dx & 0xFF; mpu.memory[0x31] = (dx >> 8) & 0xFF
    mpu.memory[0x32] = dy & 0xFF; mpu.memory[0x33] = (dy >> 8) & 0xFF
    mpu.pc = PA; mpu.sp = 0xFD
    mpu.memory[0x01FF] = 0xFF; mpu.memory[0x01FE] = 0xFF
    steps = 0
    while mpu.pc != 0x0000 and steps < 5000:
        mpu.step(); steps += 1
    return mpu.memory[0x39] | (mpu.memory[0x3A] << 8)


pafails = pachecked = 0
for dx in range(-660, 661, 11):
    for dy in range(-660, 661, 11):
        exp = A.point_to_angle(dx, dy)
        got = run_pa(s16(dx), s16(dy))
        pachecked += 1
        if got != exp:
            pafails += 1
            if pafails <= 12:
                print(f"  PA MISMATCH dx={dx} dy={dy}: 6502={got} py={exp}")
print(f"point_to_angle: checked {pachecked} (dx,dy), {pafails} mismatches")
print("PASS" if (fails == 0 and pafails == 0) else "FAIL")
sys.exit(1 if (fails or pafails) else 0)
