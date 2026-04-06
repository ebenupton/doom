"""6502 NJ+Hamiltonian rasteriser — renders lines into a pixel buffer via py65.

Provides render_lines_6502(lines) which runs the NJ rasteriser (OR mode)
for each line and returns a 256×160 pixel buffer as a pygame Surface.

BBC Micro Mode 4 screen layout (adapted for 256×160):
  - 20 character rows of 8 scanlines each
  - 32 byte columns per scanline
  - 256 bytes per character row (32 cols × 8 scanlines)
  - Pixel (px, py): address = screen_start + (py//8)*256 + (px//8)*8 + (py%8)
  - Bit within byte: 7 - (px % 8) = MSB is leftmost pixel
"""

import os
import pygame
from py65.devices.mpu6502 import MPU

# Load OR-mode rasteriser binary
_BIN_PATH = os.path.join(os.path.dirname(__file__), "linedraw_or.bin")
_ORG = 0x2000
with open(_BIN_PATH, "rb") as f:
    _RASTER_CODE = f.read()

# Screen buffer config (256×160, 1bpp, BBC Micro layout)
SCREEN_W = 256
SCREEN_H = 160
CHAR_ROWS = SCREEN_H // 8  # 20
BYTES_PER_CHAR_ROW = 256    # 32 columns × 8 scanlines
SCREEN_SIZE = CHAR_ROWS * BYTES_PER_CHAR_ROW  # 5120 bytes
SCREEN_START = 0x5800       # BBC Micro Mode 4 default (buffer 0)
SCREEN_START_1 = 0x6C00     # BBC Micro Mode 4 buffer 1
SCREEN_START_HI = SCREEN_START >> 8

# ZP locations for the rasteriser
_ZP_SCR = 0x74
_ZP_SCRSTRT = 0x70
_ZP_X0 = 0x82
_ZP_Y0 = 0x83
_ZP_X1 = 0x84
_ZP_Y1 = 0x85

# Trampoline
_TRAMPOLINE = 0x0400

# Pre-build template memory
_TEMPLATE = bytearray(0x10000)
_TEMPLATE[_ORG:_ORG + len(_RASTER_CODE)] = _RASTER_CODE
_TEMPLATE[_TRAMPOLINE] = 0x20  # JSR
_TEMPLATE[_TRAMPOLINE + 1] = _ORG & 0xFF
_TEMPLATE[_TRAMPOLINE + 2] = (_ORG >> 8) & 0xFF
_TEMPLATE[_TRAMPOLINE + 3] = 0x00  # BRK

_mpu = MPU()


def _draw_one_line(mpu, x0, y0, x1, y1):
    """Run the NJ rasteriser for one line. Screen buffer is in mpu.memory."""
    mpu.memory[_ZP_X0] = x0 & 0xFF
    mpu.memory[_ZP_Y0] = y0 & 0xFF
    mpu.memory[_ZP_X1] = x1 & 0xFF
    mpu.memory[_ZP_Y1] = y1 & 0xFF
    mpu.memory[_ZP_SCRSTRT] = SCREEN_START_HI

    mpu.a = 0; mpu.x = 0; mpu.y = 0
    mpu.p = 0x30; mpu.sp = 0xFD
    mpu.pc = _TRAMPOLINE
    mpu.processorCycles = 0

    max_steps = 200000
    for _ in range(max_steps):
        if mpu.pc == _TRAMPOLINE + 3:
            break
        mpu.step()

    return mpu.processorCycles


def _screen_to_surface(mem, screen_start=SCREEN_START):
    """Convert BBC Micro screen buffer to a pygame Surface."""
    surf = pygame.Surface((SCREEN_W, SCREEN_H))
    surf.fill((0, 0, 0))
    pxa = pygame.surfarray.pixels3d(surf)

    for py in range(SCREEN_H):
        char_row = py >> 3
        scanline = py & 7
        for byte_col in range(32):
            addr = screen_start + char_row * 256 + byte_col * 8 + scanline
            byte = mem[addr]
            if byte == 0:
                continue
            for bit in range(8):
                if byte & (0x80 >> bit):
                    px = byte_col * 8 + bit
                    pxa[px, py] = (0, 200, 0)

    del pxa
    return surf


def render_lines_6502(lines, buffer=0):
    """Render a list of (x1, y1, x2, y2) lines through the NJ rasteriser.

    Returns (surface, total_cycles) where surface is 256×160 pygame Surface.
    Lines with coordinates outside 0-255 / 0-159 are clipped to screen bounds.
    buffer: 0 = SCREEN_START ($5800), 1 = SCREEN_START_1 ($6C00).
    """
    scr_start = SCREEN_START_1 if buffer else SCREEN_START
    scr_start_hi = scr_start >> 8

    mpu = _mpu
    mpu.memory[:] = _TEMPLATE
    # Clear screen buffer
    for i in range(SCREEN_SIZE):
        mpu.memory[scr_start + i] = 0

    total_cycles = 0
    for x1, y1, x2, y2 in lines:
        # Clamp to screen bounds (the rasteriser expects 0-255 x, 0-255 y)
        x1 = max(0, min(255, int(x1)))
        y1 = max(0, min(SCREEN_H - 1, int(y1)))
        x2 = max(0, min(255, int(x2)))
        y2 = max(0, min(SCREEN_H - 1, int(y2)))
        if x1 == x2 and y1 == y2:
            continue
        mpu.memory[_ZP_SCRSTRT] = scr_start_hi
        total_cycles += _draw_one_line(mpu, x1, y1, x2, y2)

    return _screen_to_surface(mpu.memory, scr_start), total_cycles
