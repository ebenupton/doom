"""Unit-test the 6502 slope_div against angle_bbox.slope_div (Python)."""
import sys
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
mpu.memory[0xFFFE] = 0x00; mpu.memory[0xFFFF] = 0xFF  # IRQ vec sink
mpu.memory[0xFF00] = 0x00  # BRK lands here -> we detect via PC
SD_NUM, SD_DEN, SD_Q = sym('sd_num'), sym('sd_den'), sym('sd_q')


def run(num, den):
    mpu.memory[SD_NUM] = num & 0xFF; mpu.memory[SD_NUM + 1] = (num >> 8) & 0xFF
    mpu.memory[SD_DEN] = den & 0xFF; mpu.memory[SD_DEN + 1] = (den >> 8) & 0xFF
    mpu.pc = sym('slope_div')
    mpu.sp = 0xFD
    mpu.memory[0x01FF] = 0xFF; mpu.memory[0x01FE] = 0xFF  # RTS -> $0000
    steps = 0
    while mpu.pc != 0x0000 and steps < 2000:
        mpu.step(); steps += 1
    return mpu.memory[SD_Q] | (mpu.memory[SD_Q + 1] << 8)


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
# (tantoangle tables already loaded by load_angle_module.)
# point_to_angle is FUSED (2026-07-17): stage_c consumes the classify
# stash, so the test drives stage_c itself — poke the CABS stash the
# way box_classify would for a single corner (slots 0/2 = |dx|/|dy|
# with the corner-sign bytes) and dispatch. bca_afn=0 makes the tail
# compute pa_res = u12(0 - psi), so psi = (-pa_res) % 4096.
def s16(v):
    return v & 0xFFFF


STAGE_C = sym('stage_c')
CABS = 0x0A40
PA_RES, BCA_AFN = sym('pa_res'), sym('bca_afn')
ZP_CPMF = sym('zp_cpm_frame')


def run_pa(dx, dy):
    m = mpu.memory
    if dx >= 0x8000: dx -= 0x10000         # callers pass u16 via s16()
    if dy >= 0x8000: dy -= 0x10000
    adx, ady = abs(dx), abs(dy)
    m[CABS + 0] = adx & 0xFF; m[CABS + 4] = adx >> 8      # |dx| -> x slot 0
    m[CABS + 2] = ady & 0xFF; m[CABS + 6] = ady >> 8      # |dy| -> y slot 2
    m[CABS + 8] = 4 if dx < 0 else 0                      # sx (pre-shifted)
    m[CABS + 10] = 2 if dy < 0 else 0                     # sy
    m[BCA_AFN] = 0; m[BCA_AFN + 1] = 0     # afn=0 -> pa_res = -psi
    m[ZP_CPMF] = (m[ZP_CPMF] + 1) & 0xFF   # new epoch: no stale memo hits
    mpu.pc = STAGE_C; mpu.sp = 0xFD
    mpu.x, mpu.y = 0, 2                    # corner = (slot 0, slot 2)
    m[0x01FF] = 0xFF; m[0x01FE] = 0xFF
    steps = 0
    while mpu.pc != 0x0000 and steps < 5000:
        mpu.step(); steps += 1
    raw = m[PA_RES] | (m[PA_RES + 1] << 8)
    if raw >= 0x8000:
        raw -= 0x10000
    return (-raw) % 4096                                 # recover psi in [0,4096)


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
