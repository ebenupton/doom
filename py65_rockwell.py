"""Rockwell/WDC bit-branch extension for py65's 65C02 MPU (2026-08-11).

py65's MPU65C02 implements SMB/RMB but not BBR0-7/BBS0-7 — which is
REPRESENTATIVE of the Acorn CMOS parts (Master 65C12, vintage 65C102
copro): they lack the Rockwell ops too, and jsbeeb's Master boot goes
black on them. The engine therefore emits BBS/BBR only in the OPT-IN
DOOM_ROCKWELL=1 build (BR_BIT_SET/CLR macros in src/bsp/header.s,
PiTubeDirect-class copros only). Harnesses that may execute such a
build import this module — it patches the MPU65C02 CLASS on import (instruct/
cycletime are class-shared in py65, so one patch covers every
instance; handlers use the executing MPU passed by step(), never a
closed-over instance).

Opcodes: BBRn = $0F + n*$10, BBSn = $8F + n*$10. 3 bytes (zp, rel).
5 cycles, +1 taken (+1 more on page cross — modelled as +1 taken,
matching py65's coarse branch model).

REAL-HARDWARE CAVEAT: Rockwell bit ops exist on R65C02/W65C02 and on
PiTubeDirect's 65C02; a vintage NCR/GTE 65C02 (or Acorn 65C102 copro)
may NOT implement them. The C02 build targets the modern parts.
"""
from py65.devices.mpu65c02 import MPU as _MPU65C02


def _make(bit, want_set):
    mask = 1 << bit

    def op(mpu):
        addr = mpu.memory[mpu.pc]
        rel = mpu.memory[(mpu.pc + 1) & 0xFFFF]
        mpu.pc = (mpu.pc + 2) & 0xFFFF
        if bool(mpu.memory[addr] & mask) == want_set:
            mpu.pc = (mpu.pc + rel - (256 if rel >= 128 else 0)) & 0xFFFF
            mpu.excycles += 1
    op.__name__ = f"inst_{'BBS' if want_set else 'BBR'}{bit}"
    return op


def patch(cls=_MPU65C02):
    if getattr(cls, '_rockwell_patched', False):
        return
    for n in range(8):
        for base, want_set in ((0x0F, False), (0x8F, True)):
            cls.instruct[base + n * 0x10] = _make(n, want_set)
            cls.cycletime[base + n * 0x10] = 5
            cls.extracycles[base + n * 0x10] = 1
    cls._rockwell_patched = True


patch()
