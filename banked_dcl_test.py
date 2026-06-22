#!/usr/bin/env python3
"""Verify the bank-C clipper (span_clip_bankc.bin @ $8000) is bit-identical to
the flat clipper (span_clip.bin @ $2000), using the banked_mem.py $FE30 model.

This proves the hardest novel piece of the BBC banked port: the clipper running
from sideways-RAM bank C, calling the sqr multiply tables relocated to low RAM
($1000), reading/writing the pool + line-list + output in low RAM — producing
the same emitted segments as the flat build.

Method: for each dcl_test case, run the flat DCLHarness and a banked harness
(clipper in bank C, sqr @ $1000, RASTER stubbed) and assert identical LINE_OUT.
"""
import os, sys, random
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
from py65.devices.mpu6502 import MPU
from banked_mem import BankedMemory
from span_clip_6502 import _gen_quarter_square
import dcl_test as T

BANK_C = 6
DCL_ENTRY_BANKED = 0x8015          # JMP draw_clipped_line (flat $2015 + $6000)
RASTER_FLAT = 0xA900               # clipper's RASTER_ENTRY constant (in-bank when banked)


class BankedDCL:
    def __init__(self):
        # build the banked clipper
        rc = os.system('./beebasm -i span_clip.asm -D BANKED=1 >/dev/null 2>&1')
        assert rc == 0 and os.path.exists('span_clip_bankc.bin'), "banked clipper build failed"
        self.mpu = MPU()
        self.mem = BankedMemory([0] * 65536)
        self.mpu.memory = self.mem
        # sqr tables LOW at $1000 (banked clipper references them there)
        slo, shi, s2lo, s2hi = _gen_quarter_square()
        self.mem[0x1000:0x1100] = slo
        self.mem[0x1100:0x1200] = shi
        self.mem[0x1200:0x1300] = s2lo
        self.mem[0x1300:0x1400] = s2hi
        # bank C = the clipper
        img = open('span_clip_bankc.bin', 'rb').read()
        self.mem.define_bank(BANK_C, img)
        self.mem.select(BANK_C)
        # stub RASTER_ENTRY ($A900, in bank C's unused tail past end_code $A7DB)
        self.mem[RASTER_FLAT] = 0x60        # RTS

    def run(self, line):
        m = self.mem; mpu = self.mpu
        self.mem.select(BANK_C)
        xl, yl, xr, yr = line
        m[T.L_XL] = xl; m[T.L_YL] = yl; m[T.L_XR] = xr; m[T.L_YR] = yr
        m[T.DCL_REC_LO] = 0; m[T.DCL_REC_HI] = 0
        m[T.LINE_OUT_COUNT] = 0
        mpu.pc = DCL_ENTRY_BANKED; mpu.sp = 0xFD; mpu.p = 0x30
        m[0x01FF] = 0xFE; m[0x01FE] = 0xFF
        for _ in range(200000):
            if mpu.pc == 0xFF00:
                break
            mpu.step()
        segs = []
        n = m[T.LINE_OUT_COUNT] // 4
        for i in range(n):
            b = T.LINE_OUT_BUF + i * 4
            segs.append((m[b], m[b + 1], m[b + 2], m[b + 3]))
        return segs

    def set_pool(self, spans):
        # reuse dcl_test's pool layout (all low-RAM, always mapped)
        T.DCLHarness.set_pool(self, spans)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    flat = T.DCLHarness()
    bank = BankedDCL()
    rng = random.Random(seed)
    mism = 0
    # directed cases first
    cases = list(T.directed_cases())
    for spans, line in cases:
        flat.set_pool(spans); fseg = flat.run(line)
        bank.set_pool(spans); bseg = bank.run(line)
        tag = "OK" if fseg == bseg else "MISMATCH"
        print(f"directed {line}: flat={len(fseg)} banked={len(bseg)} segs  {tag}")
        if fseg != bseg:
            mism += 1
            print(f"   flat:  {fseg}")
            print(f"   bankC: {bseg}")
    for i in range(n):
        spans, line = T.gen_random(rng)
        flat.set_pool(spans); fseg = flat.run(line)
        bank.set_pool(spans); bseg = bank.run(line)
        if fseg != bseg:
            mism += 1
            if mism <= 8:
                print(f"MISMATCH #{mism}: line={line}")
                print(f"   flat:  {fseg}")
                print(f"   bankC: {bseg}")
                print(f"   spans: {spans}")
        if (i + 1) % 5000 == 0:
            print(f"  ...{i+1}/{n}, {mism} mismatches")
    print(f"\nBANK-C CLIPPER vs FLAT: {n} random cases, {mism} mismatches.")
    print("PASS — bank-C clipper is bit-identical to flat" if mism == 0 else "FAIL")


if __name__ == '__main__':
    main()
