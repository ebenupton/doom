"""Python wrapper for the 6502 span clipper subsystem.

Loads span_clip.bin into py65, provides methods to call each entry point,
and reads results back.  Used for comparison testing against EndpointClipSpans.
"""
import os
from py65.devices.mpu6502 import MPU


# Entry points (must match span_clip.asm jump table)
ENTRY_INIT       = 0x2000
ENTRY_MARK_SOLID = 0x2003
ENTRY_TIGHTEN    = 0x2006
ENTRY_HAS_GAP    = 0x2009
ENTRY_IS_FULL    = 0x200C
ENTRY_READ       = 0x200F
ENTRY_INTERP_FL  = 0x2012
ENTRY_INTERP_CE  = 0x2015
ENTRY_INTERP_ST  = 0x2018

# ZP addresses (must match span_clip.asm)
ZP_HEAD  = 0xC0
ZP_FREE  = 0xC1
ZP_ILO   = 0xC2
ZP_IHI   = 0xC3
ZP_SX1   = 0xC4
ZP_SX2   = 0xC5
ZP_YT1   = 0xC6
ZP_YT2   = 0xC7
ZP_YB1   = 0xC8
ZP_YB2   = 0xC9
ZP_I_X   = 0xCA
ZP_I_X0  = 0xCB
ZP_I_Y0  = 0xCC
ZP_I_X1  = 0xCD
ZP_I_Y1  = 0xCE
ZP_I_RES = 0xCF
ZP_BUF   = 0xDC

# Pool
POOL_BASE = 0x0400

# Buffer for span_read output
READ_BUF = 0x0300


def _gen_quarter_square():
    """Generate quarter-square tables (same as fe6502.py)."""
    sqr_lo = bytearray(256)
    sqr_hi = bytearray(256)
    sqr2_lo = bytearray(256)
    sqr2_hi = bytearray(256)
    for n in range(256):
        v = (n * n) >> 2
        sqr_lo[n] = v & 0xFF
        sqr_hi[n] = (v >> 8) & 0xFF
    for n in range(256):
        v = ((n + 256) * (n + 256)) >> 2
        sqr2_lo[n] = v & 0xFF
        sqr2_hi[n] = (v >> 8) & 0xFF
    return sqr_lo, sqr_hi, sqr2_lo, sqr2_hi


class SpanClip6502:
    """6502 span clipper subsystem running in py65."""

    def __init__(self):
        self.mpu = MPU()
        mem = self.mpu.memory

        # Load quarter-square tables
        sqr_lo, sqr_hi, sqr2_lo, sqr2_hi = _gen_quarter_square()
        mem[0x5400:0x5500] = sqr_lo
        mem[0x5500:0x5600] = sqr_hi
        mem[0x5600:0x5700] = sqr2_lo
        mem[0x5700:0x5800] = sqr2_hi

        # Assemble and load span_clip.bin
        asm_path = os.path.join(os.path.dirname(__file__) or '.', 'span_clip.asm')
        bin_path = os.path.join(os.path.dirname(__file__) or '.', 'span_clip.bin')
        os.system(f'./beebasm -i {asm_path} -o {bin_path} 2>/dev/null')
        with open(bin_path, 'rb') as f:
            code = f.read()
        for i, b in enumerate(code):
            mem[0x2000 + i] = b

        # BRK at halt address
        mem[0xFF00] = 0x00

        # Set up read buffer pointer
        mem[ZP_BUF] = READ_BUF & 0xFF
        mem[ZP_BUF + 1] = (READ_BUF >> 8) & 0xFF

    def _run(self, entry, max_cycles=500000):
        """Run from entry point until BRK at $FF00."""
        mpu = self.mpu
        mem = mpu.memory
        mpu.pc = entry
        mpu.sp = 0xFD
        mpu.p = 0x30
        # Push return to $FF00-1 = $FEFF (RTS adds 1)
        mem[0x01FF] = 0xFE
        mem[0x01FE] = 0xFF
        mpu.processorCycles = 0
        for _ in range(max_cycles):
            if mpu.pc == 0xFF00:
                break
            mpu.step()
        return mpu.processorCycles

    def init(self):
        """Initialize: one full-screen span."""
        self._run(ENTRY_INIT)

    def mark_solid(self, lo, hi):
        """mark_solid(lo, hi)."""
        mem = self.mpu.memory
        ilo = max(0, lo)
        ihi = min(256, hi + 1)
        mem[ZP_ILO] = ilo & 0xFF
        mem[ZP_IHI] = ihi & 0xFF
        self._run(ENTRY_MARK_SOLID)

    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2):
        """tighten(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2)."""
        mem = self.mpu.memory
        ilo = max(0, lo)
        ihi = min(256, hi + 1)
        mem[ZP_ILO] = ilo & 0xFF
        mem[ZP_IHI] = ihi & 0xFF
        mem[ZP_SX1] = sx1 & 0xFF
        mem[ZP_SX2] = sx2 & 0xFF
        mem[ZP_YT1] = yt1 & 0xFF
        mem[ZP_YT2] = yt2 & 0xFF
        mem[ZP_YB1] = yb1 & 0xFF
        mem[ZP_YB2] = yb2 & 0xFF
        self._run(ENTRY_TIGHTEN)

    def has_gap(self, lo, hi):
        """has_gap(lo, hi) → bool."""
        mem = self.mpu.memory
        mem[ZP_ILO] = max(0, lo) & 0xFF
        mem[ZP_IHI] = min(255, hi) & 0xFF
        self._run(ENTRY_HAS_GAP)
        return self.mpu.a != 0

    def is_full(self):
        """is_full() → bool."""
        self._run(ENTRY_IS_FULL)
        return self.mpu.a != 0

    def read_spans(self):
        """Read span list → list of (xlo, xhi, tl, bl, tr, br) tuples."""
        mem = self.mpu.memory
        mem[ZP_BUF] = READ_BUF & 0xFF
        mem[ZP_BUF + 1] = (READ_BUF >> 8) & 0xFF
        self._run(ENTRY_READ)
        count = mem[READ_BUF]
        spans = []
        off = READ_BUF + 1
        for i in range(count):
            xlo = mem[off]; xhi = mem[off+1]
            tl = mem[off+2]; bl = mem[off+3]
            tr = mem[off+4]; br = mem[off+5]
            if xhi == 0: xhi = 256
            spans.append((xlo, xhi, tl, bl, tr, br))
            off += 6
        return spans

    def interp(self, mode, x, x0, y0, x1, y1):
        """Call one of the interp variants.
        mode: 'floor', 'ceil', 'store'."""
        mem = self.mpu.memory
        mem[ZP_I_X] = x & 0xFF
        mem[ZP_I_X0] = x0 & 0xFF
        mem[ZP_I_Y0] = y0 & 0xFF
        mem[ZP_I_X1] = x1 & 0xFF
        mem[ZP_I_Y1] = y1 & 0xFF
        entry = {'floor': ENTRY_INTERP_FL, 'ceil': ENTRY_INTERP_CE,
                 'store': ENTRY_INTERP_ST}[mode]
        self._run(entry)
        # Result is signed — return as s8
        r = mem[ZP_I_RES]
        return r if r < 128 else r - 256


def test_interp():
    """Test all three interp variants against Python."""
    from endpoint_spans import _interp, _interp_ceil, _interp_store
    sc = SpanClip6502()
    sc.init()
    errors = 0
    for x0 in range(0, 250, 50):
        for x1 in range(x0+1, min(x0+100, 256), 17):
            for y0 in range(0, 160, 40):
                for y1 in range(0, 160, 40):
                    for x in range(x0, x1, max(1, (x1-x0)//5)):
                        py_f = _interp(x, x0, y0, x1, y1)
                        py_c = _interp_ceil(x, x0, y0, x1, y1)
                        py_s = _interp_store(x, x0, y0, x1, y1)
                        asm_f = sc.interp('floor', x, x0, y0, x1, y1)
                        asm_c = sc.interp('ceil', x, x0, y0, x1, y1)
                        asm_s = sc.interp('store', x, x0, y0, x1, y1)
                        for name, py, asm in [('floor',py_f,asm_f),
                                               ('ceil',py_c,asm_c),
                                               ('store',py_s,asm_s)]:
                            if py != asm:
                                errors += 1
                                if errors <= 5:
                                    print(f'  {name} MISMATCH: x={x} [{x0},{x1}) y=[{y0},{y1}] py={py} asm={asm}')
    print(f'Interp test: {errors} errors')
    return errors == 0


def test_mark_solid():
    """Test mark_solid against Python EndpointClipSpans."""
    from endpoint_spans import EndpointClipSpans
    sc = SpanClip6502()

    # Test 1: simple middle removal
    sc.init()
    py = EndpointClipSpans()
    sc.mark_solid(50, 100)
    py.mark_solid(50, 100)
    asm_spans = sc.read_spans()
    py_spans = py.spans
    if asm_spans == py_spans:
        print('  mark_solid test 1: MATCH')
    else:
        print(f'  mark_solid test 1: MISMATCH')
        print(f'    py:  {py_spans}')
        print(f'    asm: {asm_spans}')

    # Test 2: left edge removal
    sc.init()
    py = EndpointClipSpans()
    sc.mark_solid(-10, 50)
    py.mark_solid(-10, 50)
    asm_spans = sc.read_spans()
    py_spans = py.spans
    if asm_spans == py_spans:
        print('  mark_solid test 2: MATCH')
    else:
        print(f'  mark_solid test 2: MISMATCH')
        print(f'    py:  {py_spans}')
        print(f'    asm: {asm_spans}')

    # Test 3: multiple mark_solids
    sc.init()
    py = EndpointClipSpans()
    for lo, hi in [(100, 150), (50, 80), (200, 250)]:
        sc.mark_solid(lo, hi)
        py.mark_solid(lo, hi)
    asm_spans = sc.read_spans()
    py_spans = py.spans
    if asm_spans == py_spans:
        print('  mark_solid test 3: MATCH')
    else:
        print(f'  mark_solid test 3: MISMATCH')
        print(f'    py:  {py_spans}')
        print(f'    asm: {asm_spans}')


def test_tighten():
    """Test tighten against Python EndpointClipSpans."""
    from endpoint_spans import EndpointClipSpans
    sc = SpanClip6502()

    # Test 1: simple tighten
    sc.init(); py = EndpointClipSpans()
    args = (50, 200, 50, 200, 30, 40, 120, 110)
    sc.tighten(*args); py.tighten(*args)
    asm = sc.read_spans(); pys = py.spans
    print(f'  tighten test 1: {"MATCH" if asm==pys else "MISMATCH"}')
    if asm != pys: print(f'    py:  {pys}\n    asm: {asm}')

    # Test 2: tighten after mark_solid
    sc.init(); py = EndpointClipSpans()
    sc.mark_solid(100, 150); py.mark_solid(100, 150)
    args = (50, 200, 50, 200, 20, 50, 130, 100)
    sc.tighten(*args); py.tighten(*args)
    asm = sc.read_spans(); pys = py.spans
    print(f'  tighten test 2: {"MATCH" if asm==pys else "MISMATCH"}')
    if asm != pys: print(f'    py:  {pys}\n    asm: {asm}')

    # Test 3: dominated tighten (should be no-op)
    sc.init(); py = EndpointClipSpans()
    args = (50, 200, 50, 200, 30, 40, 120, 110)
    sc.tighten(*args); py.tighten(*args)
    args2 = (50, 200, 50, 200, -10, -5, 170, 160)  # much wider → dominated
    sc.tighten(*args2); py.tighten(*args2)
    asm = sc.read_spans(); pys = py.spans
    print(f'  tighten test 3 (dominated): {"MATCH" if asm==pys else "MISMATCH"}')
    if asm != pys: print(f'    py:  {pys}\n    asm: {asm}')


def test_frame():
    """Run a full frame and compare span state after every mutation."""
    import os, math
    os.environ['SDL_VIDEODRIVER'] = 'dummy'
    os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
    import pygame; pygame.init(); pygame.display.set_mode((1, 1))
    import doom_wireframe as dw
    from endpoint_spans import EndpointClipSpans
    import fp as fpmod

    PX, PY, ANGLE = 1056, -3616, 64
    FZ = dw.player_floor(PX, PY)

    sc = SpanClip6502()
    sc.init()
    total_cyc = [0]
    mismatches = [0]

    _orig_ms = EndpointClipSpans.mark_solid
    _orig_tg = EndpointClipSpans.tighten
    op_num = [0]

    def _hook_ms(self, lo, hi):
        _orig_ms(self, lo, hi)
        op_num[0] += 1
        c = sc.mpu.processorCycles
        sc.mark_solid(lo, hi)
        total_cyc[0] += sc.mpu.processorCycles
        asm = sc.read_spans()
        if asm != self.spans:
            mismatches[0] += 1
            if mismatches[0] <= 3:
                print(f'  mark_solid #{op_num[0]} [{lo},{hi}] MISMATCH')
                print(f'    py:  {self.spans[:3]}...')
                print(f'    asm: {asm[:3]}...')

    def _hook_tg(self, *args, **kw):
        _orig_tg(self, *args, **kw)
        lo, hi, sx1, sx2, yt1, yt2, yb1, yb2 = args[:8]
        op_num[0] += 1
        sc.tighten(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2)
        total_cyc[0] += sc.mpu.processorCycles
        asm = sc.read_spans()
        if asm != self.spans:
            mismatches[0] += 1
            if mismatches[0] <= 3:
                print(f'  tighten #{op_num[0]} [{lo},{hi}] MISMATCH')
                print(f'    py:  {self.spans[:3]}...')
                print(f'    asm: {asm[:3]}...')

    EndpointClipSpans.mark_solid = _hook_ms
    EndpointClipSpans.tighten = _hook_tg

    pygame.draw.line = lambda s, c, p1, p2, w=1: None
    fpmod.mul_reset()
    px_88 = int((PX - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((PY - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz_ps = dw._prescale_height(FZ + 41)
    sc2 = dw.fp_sincos(ANGLE)
    ctx = dw.fp_view_context(px_88, py_88, sc2)
    cos_f, sin_f = math.cos(dw.byte_to_radians(ANGLE)), math.sin(dw.byte_to_radians(ANGLE))
    dw.render_bsp_fp(len(dw.nodes) - 1, EndpointClipSpans(), ctx, vz_ps,
                     int(PX), int(PY), cos_f, sin_f,
                     pygame.Surface((256, 160)),
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))

    EndpointClipSpans.mark_solid = _orig_ms
    EndpointClipSpans.tighten = _orig_tg
    print(f'  Full frame: {op_num[0]} ops, {mismatches[0]} mismatches, {total_cyc[0]} 6502 cycles')


if __name__ == '__main__':
    print('Testing 6502 span clipper...')
    print()
    print('Interp tests:')
    test_interp()
    print()
    print('mark_solid tests:')
    test_mark_solid()
    print()
    print('tighten tests:')
    test_tighten()
    print()
    print('Full frame comparison:')
    test_frame()
