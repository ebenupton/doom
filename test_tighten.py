#!/usr/bin/env python3
"""Unit test: call 6502 tighten with the exact inputs from the failing case."""
import os, sys, subprocess
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from fe6502 import Frontend6502, CODE_BASE, SPANS_BASE

SPAN_SIZE = 16; SPAN_HDR = 2
SP_XLO=0; SP_XHI=1; SP_TSLOPE=2; SP_BSLOPE=4
SP_TINTERCEPT=6; SP_BINTERCEPT=8; SP_INNER_TOP=10; SP_INNER_BOT=12
SP_OUTER_TOP=14; SP_OUTER_BOT=15

result = subprocess.run(['./beebasm', '-i', 'doom_fe.asm', '-v'], capture_output=True, text=True)
ADDR_TIGHTEN = None
for i, line in enumerate(result.stdout.split('\n')):
    if line.strip() == '.tighten':
        ADDR_TIGHTEN = int(result.stdout.split('\n')[i+1].strip().split()[0], 16)
        break
print(f"tighten: ${ADDR_TIGHTEN:04X}")

def write_s16(mem, addr, val):
    v = val & 0xFFFF
    mem[addr] = v & 0xFF; mem[addr+1] = (v >> 8) & 0xFF

def read_s16(mem, addr):
    v = mem[addr] | (mem[addr+1] << 8)
    return v - 65536 if v >= 32768 else v

fe = Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                  dw.packed_bbox_table, dw.packed_layout)
mem = fe.mpu.memory; mpu = fe.mpu

# Initial span: [0,256) with top=(0,0), bot=(0,159)
spans_buf = SPANS_BASE
mem[0x56] = spans_buf & 0xFF; mem[0x57] = (spans_buf >> 8) & 0xFF
mem[spans_buf] = 1; mem[spans_buf + 1] = 0
s = spans_buf + SPAN_HDR
mem[s + SP_XLO] = 0; mem[s + SP_XHI] = 0  # 0=256
write_s16(mem, s + SP_TSLOPE, 0); write_s16(mem, s + SP_BSLOPE, 0)
write_s16(mem, s + SP_TINTERCEPT, 0); write_s16(mem, s + SP_BINTERCEPT, 159)
write_s16(mem, s + SP_INNER_TOP, 0); write_s16(mem, s + SP_INNER_BOT, 159)
mem[s + SP_OUTER_TOP] = 0; mem[s + SP_OUTER_BOT] = 159

alt_buf = 0x046A
mem[alt_buf] = 0; mem[alt_buf + 1] = 0

# Tighten inputs: lo=-78, hi=470, yt1=12, yt2=12, sx1=-78, sx2=470, yb1=183, yb2=183
write_s16(mem, 0xF0, -78); write_s16(mem, 0xF2, 470)
write_s16(mem, 0x60, 12); write_s16(mem, 0x62, 12)
write_s16(mem, 0x64, -78); write_s16(mem, 0x66, 470)
write_s16(mem, 0x90, 183); write_s16(mem, 0x92, 183)

mem[0xFF00] = 0x00
mpu.pc = ADDR_TIGHTEN; mpu.sp = 0xFD; mpu.p = 0x30
mem[0x01FF] = 0xFE; mem[0x01FE] = 0xFF; mpu.processorCycles = 0

for _ in range(500000):
    if mpu.pc == 0xFF00: break
    mpu.step()

cspan = mem[0x56] | (mem[0x57] << 8)
print(f"cspan after: ${cspan:04X}")
count = mem[cspan]
print(f"Count: {count}")
base = cspan + SPAN_HDR
for i in range(count):
    a = base + i * SPAN_SIZE
    xlo = mem[a]; xhi_raw = mem[a+1]; xhi = xhi_raw if xhi_raw else 256
    ta = read_s16(mem, a + SP_TSLOPE); ba = read_s16(mem, a + SP_BSLOPE)
    tb = read_s16(mem, a + SP_TINTERCEPT); bb = read_s16(mem, a + SP_BINTERCEPT)
    it = read_s16(mem, a + SP_INNER_TOP); ib = read_s16(mem, a + SP_INNER_BOT)
    ot = mem[a + SP_OUTER_TOP]; ob = mem[a + SP_OUTER_BOT]
    print(f"  [{i}] xlo={xlo} xhi={xhi} ta={ta} ba={ba} tb={tb} bb={bb} inner=[{it},{ib}] outer=[{ot},{ob}]")
print(f"\nExpected: tb=12 bb=159")
if count >= 1:
    tb = read_s16(mem, base + SP_TINTERCEPT)
    bb = read_s16(mem, base + SP_BINTERCEPT)
    print(f"Got:      tb={tb} bb={bb}")
    print("CORRECT!" if tb == 12 and bb == 159 else f"BUG: tb={tb} (expected 12)")
