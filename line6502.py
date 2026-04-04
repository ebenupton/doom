"""6502 cycle-accurate line draw simulation using py65.

Loads the NJ+Hamiltonian rasteriser assembled by BeebAsm and runs it
in py65 for each line, returning the exact cycle count.
"""

import os
from py65.devices.mpu6502 import MPU

# Load assembled binary
_BIN_PATH = os.path.join(os.path.dirname(__file__), "linedraw.bin")
_ORG = 0x2000

with open(_BIN_PATH, "rb") as f:
    _CODE = f.read()

# ZP locations (must match linedraw_build.asm)
_ZP_SCR     = 0x74  # 2 bytes
_ZP_SCRSTRT = 0x70
_ZP_X0      = 0x82
_ZP_Y0      = 0x83
_ZP_X1      = 0x84
_ZP_Y1      = 0x85

# Entry point
_ENTRY = _ORG  # .linedraw4

# Trampoline at $0400: JSR linedraw4; BRK
_TRAMPOLINE = 0x0400

# Pre-build template memory image
_TEMPLATE_MEM = bytearray(0x10000)
_TEMPLATE_MEM[_ORG:_ORG + len(_CODE)] = _CODE
_TEMPLATE_MEM[_TRAMPOLINE] = 0x20  # JSR
_TEMPLATE_MEM[_TRAMPOLINE + 1] = _ENTRY & 0xFF
_TEMPLATE_MEM[_TRAMPOLINE + 2] = (_ENTRY >> 8) & 0xFF
_TEMPLATE_MEM[_TRAMPOLINE + 3] = 0x00  # BRK

# Screen start page (MODE 4 = $5800)
_SCREEN_START_HI = 0x58

# Reusable MPU (reset between calls)
_mpu = MPU()


def estimate_line_cycles(x0, y0, x1, y1):
    """Run the NJ+Hamiltonian rasteriser in py65 and return cycle count."""
    x0 = max(0, min(255, int(x0)))
    y0 = max(0, min(255, int(y0)))
    x1 = max(0, min(255, int(x1)))
    y1 = max(0, min(255, int(y1)))

    if x0 == x1 and y0 == y1:
        return 20

    mpu = _mpu
    mpu.memory[:] = _TEMPLATE_MEM

    # Set up ZP
    mpu.memory[_ZP_X0] = x0 & 0xFF
    mpu.memory[_ZP_Y0] = y0 & 0xFF
    mpu.memory[_ZP_X1] = x1 & 0xFF
    mpu.memory[_ZP_Y1] = y1 & 0xFF
    mpu.memory[_ZP_SCRSTRT] = _SCREEN_START_HI

    # Reset CPU state
    mpu.a = 0
    mpu.x = 0
    mpu.y = 0
    mpu.p = 0x30  # unused + break flags set
    mpu.sp = 0xFD
    mpu.pc = _TRAMPOLINE
    mpu.processorCycles = 0

    # Run until BRK (after RTS from linedraw4)
    max_steps = 100000
    for _ in range(max_steps):
        if mpu.pc == _TRAMPOLINE + 3:  # hit the BRK
            break
        mpu.step()

    return mpu.processorCycles
