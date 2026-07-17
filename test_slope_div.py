"""Unit-test the 6502 F corner pipeline against the angle_bbox F mirror."""
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
# (The slope_div sweep died with the routine — option F, 2026-07-17:
# the corner pipeline is table-based; the point_to_angle sweep below
# now exercises L8/ATANEXP + the octant fold against the F mirror.)

# ---- point_to_angle ----
# The generic corner_phi entry is GONE (2026-07-19): the sweep drives
# the four LIVE sign-class entries — exactly what the ZC arms call —
# picking the class the way an arm's zone would (P: delta >= 0,
# N: delta <= 0; zero deltas fit either class, ties go to P).
# Calling with bca_afn=0 makes the tail return r = -psi in A/Y.
ENTRY = {(0, 0): sym('corner_phi_pp'), (0, 1): sym('corner_phi_pn'),
         (1, 0): sym('corner_phi_np'), (1, 1): sym('corner_phi_nn')}


def s16(v):
    return v & 0xFFFF


PA_DX, PA_DY = sym('pa_dx'), sym('pa_dy')
PA_RES, BCA_AFN = sym('pa_res'), sym('bca_afn')


def run_pa(dx, dy):
    mpu.memory[PA_DX] = dx & 0xFF; mpu.memory[PA_DX + 1] = (dx >> 8) & 0xFF
    mpu.memory[PA_DY] = dy & 0xFF; mpu.memory[PA_DY + 1] = (dy >> 8) & 0xFF
    mpu.memory[BCA_AFN] = 0; mpu.memory[BCA_AFN + 1] = 0  # afn=0 -> r = -psi
    mpu.pc = ENTRY[(1 if dx & 0x8000 else 0, 1 if dy & 0x8000 else 0)]
    mpu.sp = 0xFD
    mpu.memory[0x01FF] = 0xFF; mpu.memory[0x01FE] = 0xFF
    steps = 0
    while mpu.pc != 0x0000 and steps < 5000:
        mpu.step(); steps += 1
    raw = mpu.y | (mpu.a << 8)  # r returned in A/Y (store-backs died 2026-07-18)
    if raw >= 0x8000:
        raw -= 0x10000
    return (-raw) % 4096                                 # recover psi in [0,4096)


pafails = pachecked = 0
for dx in range(-660, 661, 11):
    for dy in range(-660, 661, 11):
        if dx == 0 and dy == 0:
            continue    # (0,0) is UNREACHABLE through the arms: the viewer
                        # would be AT the tested box's corner, and the closed
                        # inside test full-exits before any corner is taken
        exp = A.point_to_angle_f(dx, dy)
        got = run_pa(s16(dx), s16(dy))
        pachecked += 1
        if got != exp:
            pafails += 1
            if pafails <= 12:
                print(f"  PA MISMATCH dx={dx} dy={dy}: 6502={got} py={exp}")
print(f"point_to_angle: checked {pachecked} (dx,dy), {pafails} mismatches")
print("PASS" if pafails == 0 else "FAIL")
sys.exit(1 if pafails else 0)
