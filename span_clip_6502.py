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
ENTRY_INTERP_ST  = 0x2012
ENTRY_DRAW_CLIP  = 0x2015
ENTRY_CLIP_LINE_RECORDS = 0x2018
ENTRY_TIGHTEN_FROM_RECORDS = 0x201B

# Records buffers (must match span_clip.asm)
TOP_RECORDS = 0x0700
BOT_RECORDS = 0x0800
REC_BYTES = 6
REC_VERDICT_ABOVE = 0
REC_VERDICT_INSIDE = 1
REC_VERDICT_BELOW = 2

# ZP addresses (must match span_clip.asm)
ZP_HEAD  = 0xC0
ZP_FREE  = 0xC1
ZP_ILO   = 0xC2
ZP_IHI   = 0xC3
ZP_SX1   = 0xC4  # s16 (lo/hi at C4/C5)
ZP_SX2   = 0xC6  # s16 (lo/hi at C6/C7)
ZP_YT1   = 0xC8  # s16 (lo/hi at C8/C9)
ZP_YT2   = 0xCA  # s16 (lo/hi at CA/CB)
ZP_YB1   = 0xCC  # s16 (lo/hi at CC/CD)
ZP_YB2   = 0xCE  # s16 (lo/hi at CE/CF)
ZP_I_X   = 0xD0
ZP_I_X0  = 0xD1
ZP_I_Y0  = 0xD2
ZP_I_X1  = 0xD4
ZP_I_Y1  = 0xD5
ZP_I_RES = 0xD7
ZP_DIV_DEN = 0xDC
ZP_BUF   = 0xE3
ZP_MS_EMIT = 0xA8
ZP_LINE_XL = 0xA8
ZP_LINE_YL = 0xA9
ZP_LINE_XR = 0xAA
ZP_LINE_YR = 0xAB
ZP_TG_EMIT = 0xBB  # tighten emit mask: bit0=top, bit1=bot, 0x03=both
# Secondary seg Y values (u8) for emit_sec_top/emit_sec_bot — passed when flags set
ZP_YT_SEC1 = 0xB2
ZP_YT_SEC2 = 0xB3
ZP_YB_SEC1 = 0xB4
ZP_YB_SEC2 = 0xB5

# Pool
POOL_BASE = 0x0400

# Buffer for span_read output
READ_BUF = 0x0300

# Line output buffer (written by 6502 during tighten/mark_solid)
LINE_OUT_COUNT = 0x0200
LINE_OUT_BUF   = 0x0201


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
        self.total_cycles = 0
        self.last_cycles = 0
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

        # Load NJ rasteriser at $A900 (for integrated line drawing)
        raster_path = os.path.join(os.path.dirname(__file__) or '.', 'linedraw_or_reloc.bin')
        if os.path.exists(raster_path):
            with open(raster_path, 'rb') as f:
                raster_code = f.read()
            for i, b in enumerate(raster_code):
                mem[0xA900 + i] = b
            self._has_rasteriser = True
        else:
            self._has_rasteriser = False

        # Screen buffer at $5800 (5120 bytes)
        self.SCREEN_START = 0x5800
        self.SCREEN_SIZE = 5120
        mem[0x70] = self.SCREEN_START >> 8  # rasteriser scrstrt ZP

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
        self.last_cycles = mpu.processorCycles
        self.total_cycles += self.last_cycles
        return self.last_cycles

    def clear_screen(self):
        """Clear the framebuffer."""
        mem = self.mpu.memory
        start = self.SCREEN_START
        for i in range(self.SCREEN_SIZE):
            mem[start + i] = 0

    def get_framebuffer_surface(self):
        """Extract framebuffer as a pygame Surface (256×160, 1bpp)."""
        import pygame
        mem = self.mpu.memory
        start = self.SCREEN_START
        surf = pygame.Surface((256, 160))
        surf.fill((0, 0, 0))
        pxa = pygame.surfarray.pixels3d(surf)
        for py in range(160):
            char_row = py >> 3
            scanline = py & 7
            for byte_col in range(32):
                addr = start + char_row * 256 + byte_col * 8 + scanline
                byte = mem[addr]
                if byte == 0:
                    continue
                for bit in range(8):
                    if byte & (0x80 >> bit):
                        px = byte_col * 8 + bit
                        pxa[px, py] = (0, 200, 0)
        del pxa
        return surf

    def init(self):
        """Initialize: one full-screen span."""
        self._run(ENTRY_INIT)
        self.total_cycles = 0  # init cost doesn't count toward frame

    def mark_solid(self, lo, hi, sx1=None, sx2=None, yt1=None, yt2=None, yb1=None, yb2=None):
        """mark_solid(lo, hi[, sx1, sx2, yt1, yt2, yb1, yb2]).

        Inclusive right edge (solid wall covers last column).
        Closed-interval: ilo, ihi are both inclusive column indices in [0,255].

        When seg Y values are provided, the 6502 also emits wall edge lines
        clipped against the pre-mutation span boundaries.
        """
        mem = self.mpu.memory
        ilo = max(0, lo)
        ihi = min(255, hi)
        if ihi < ilo:
            return
        mem[ZP_ILO] = ilo & 0xFF
        mem[ZP_IHI] = ihi & 0xFF

        # Optionally write seg parameters for line emission
        if sx1 is not None:
            from endpoint_spans import _remap_seg_for_8bit
            s1, s2, t1, t2, b1, b2 = sx1, sx2, yt1, yt2, yb1, yb2
            if s1 > s2:
                s1, s2 = s2, s1
                t1, t2 = t2, t1
                b1, b2 = b2, b1
            s1, s2, t1, t2, b1, b2 = _remap_seg_for_8bit(
                ilo, ihi, s1, s2, t1, t2, b1, b2)

            def _w16(addr, val):
                mem[addr] = val & 0xFF
                mem[addr + 1] = (val >> 8) & 0xFF

            _w16(ZP_SX1, s1)
            _w16(ZP_SX2, s2)
            _w16(ZP_YT1, t1)
            _w16(ZP_YT2, t2)
            _w16(ZP_YB1, b1)
            _w16(ZP_YB2, b2)
            mem[ZP_MS_EMIT] = 0x00  # DCL via draw_clipped handles all line emission
        else:
            mem[ZP_MS_EMIT] = 0x00

        self._run(ENTRY_MARK_SOLID)

    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                emit_top=True, emit_bot=True,
                emit_sec_top=False, emit_sec_bot=False,
                yt_sec1=None, yt_sec2=None,
                yb_sec1=None, yb_sec2=None):
        """tighten with 16-bit seg parameters.

        Closed-interval: ilo, ihi are both inclusive column indices in [0,255].

        emit_top/emit_bot: when True (default), the 6502 emits portal top/bot
        edge lines during mutation where the new seg narrows the old span.
        Set False to suppress emission for segs where the Python reference
        doesn't draw the corresponding line (e.g. need_bt-only segs don't
        draw the floor line, so emit_bot=False matches the Python semantic).

        emit_sec_top/emit_sec_bot: when True, the 6502 emits the OLD span
        boundary (ot_l/r or ob_l/r) in addition to the new seg boundary.
        Used for step cases (need_bt + ch>vz draws both bt and ft; need_bb
        + fh<vz draws both bb and fb).  The old boundary at overlap
        endpoints typically equals the front ceiling/floor projection when
        the span is at its original room boundary.

        Wraps the call in _remap_seg_for_8bit so the 6502 8-bit interp pipeline
        always operates with ex≤255, offset≤255, |dy|≤127 — i.e., always the
        s8 fast path. The slow path (s16-overflow-prone) is never triggered.
        """
        mem = self.mpu.memory
        ilo = max(0, lo)
        ihi = min(255, hi)
        if ihi < ilo:
            return

        # Remember pre-remap anchors so we can re-interp secondary values
        # at the NEW anchors (remap shifts sx1/sx2 when the original seg
        # doesn't fit u8 constraints).
        orig_sx1, orig_sx2 = sx1, sx2
        orig_yt_sec1, orig_yt_sec2 = yt_sec1, yt_sec2
        orig_yb_sec1, orig_yb_sec2 = yb_sec1, yb_sec2

        # Swap inverted segs (sx1 > sx2) — 6502 can't handle negative ex
        if sx1 > sx2:
            sx1, sx2 = sx2, sx1
            yt1, yt2 = yt2, yt1
            yb1, yb2 = yb2, yb1
            orig_sx1, orig_sx2 = orig_sx2, orig_sx1
            if orig_yt_sec1 is not None:
                orig_yt_sec1, orig_yt_sec2 = orig_yt_sec2, orig_yt_sec1
            if orig_yb_sec1 is not None:
                orig_yb_sec1, orig_yb_sec2 = orig_yb_sec2, orig_yb_sec1

        from endpoint_spans import _remap_seg_for_8bit, _interp_store_s16
        sx1, sx2, yt1, yt2, yb1, yb2 = _remap_seg_for_8bit(
            ilo, ihi, sx1, sx2, yt1, yt2, yb1, yb2)

        # Re-interpolate secondary Y values at the new anchors.  The
        # secondary values (ft/fb) are on a linear line between orig_sx1
        # and orig_sx2; project them to (sx1, sx2).
        if emit_sec_top and orig_yt_sec1 is not None:
            if sx1 == orig_sx1 and sx2 == orig_sx2:
                new_yt_sec1, new_yt_sec2 = orig_yt_sec1, orig_yt_sec2
            else:
                new_yt_sec1 = _interp_store_s16(sx1, orig_sx1, orig_yt_sec1, orig_sx2, orig_yt_sec2)
                new_yt_sec2 = _interp_store_s16(sx2, orig_sx1, orig_yt_sec1, orig_sx2, orig_yt_sec2)
            new_yt_sec1 = max(0, min(255, new_yt_sec1))
            new_yt_sec2 = max(0, min(255, new_yt_sec2))
        else:
            new_yt_sec1 = new_yt_sec2 = 0
        if emit_sec_bot and orig_yb_sec1 is not None:
            if sx1 == orig_sx1 and sx2 == orig_sx2:
                new_yb_sec1, new_yb_sec2 = orig_yb_sec1, orig_yb_sec2
            else:
                new_yb_sec1 = _interp_store_s16(sx1, orig_sx1, orig_yb_sec1, orig_sx2, orig_yb_sec2)
                new_yb_sec2 = _interp_store_s16(sx2, orig_sx1, orig_yb_sec1, orig_sx2, orig_yb_sec2)
            new_yb_sec1 = max(0, min(255, new_yb_sec1))
            new_yb_sec2 = max(0, min(255, new_yb_sec2))
        else:
            new_yb_sec1 = new_yb_sec2 = 0

        def _w16(addr, val):
            mem[addr] = val & 0xFF
            mem[addr + 1] = (val >> 8) & 0xFF

        mem[ZP_ILO] = ilo & 0xFF
        mem[ZP_IHI] = ihi & 0xFF
        _w16(ZP_SX1, sx1)
        _w16(ZP_SX2, sx2)
        _w16(ZP_YT1, yt1)
        _w16(ZP_YT2, yt2)
        _w16(ZP_YB1, yb1)
        _w16(ZP_YB2, yb2)
        mem[ZP_YT_SEC1] = new_yt_sec1 & 0xFF
        mem[ZP_YT_SEC2] = new_yt_sec2 & 0xFF
        mem[ZP_YB_SEC1] = new_yb_sec1 & 0xFF
        mem[ZP_YB_SEC2] = new_yb_sec2 & 0xFF
        mem[ZP_TG_EMIT] = ((0x01 if emit_top else 0) | (0x02 if emit_bot else 0) |
                           (0x04 if emit_sec_top else 0) | (0x08 if emit_sec_bot else 0))
        self._run(ENTRY_TIGHTEN)

    def has_gap(self, lo, hi):
        """has_gap(lo, hi) → bool. Closed interval [lo, hi]."""
        mem = self.mpu.memory
        ilo = max(0, lo)
        ihi = min(255, hi)
        if ihi < ilo:
            return False
        mem[ZP_ILO] = ilo & 0xFF
        mem[ZP_IHI] = ihi & 0xFF
        self._run(ENTRY_HAS_GAP)
        return self.mpu.a != 0

    def is_full(self):
        """is_full() → bool."""
        self._run(ENTRY_IS_FULL)
        return self.mpu.a != 0

    def read_spans(self):
        """Read span list. Returns list of 8-tuples in the new format:
        (xstart, xend, xlo, xhi, tl, bl, tr, br)
        where (xlo, xhi, tl, bl, tr, br) is the line definition (immutable
        once a span is created) and (xstart, xend) is the active range.
        """
        mem = self.mpu.memory
        mem[ZP_BUF] = READ_BUF & 0xFF
        mem[ZP_BUF + 1] = (READ_BUF >> 8) & 0xFF
        self._run(ENTRY_READ)
        count = mem[READ_BUF]
        spans = []
        off = READ_BUF + 1
        for i in range(count):
            xstart = mem[off];   xend = mem[off+1]
            xlo    = mem[off+2]; xhi  = mem[off+3]
            tl     = mem[off+4]; bl   = mem[off+5]
            tr     = mem[off+6]; br   = mem[off+7]
            spans.append((xstart, xend, xlo, xhi, tl, bl, tr, br))
            off += 8
        return spans

    def drain_lines(self):
        """Read and clear line output buffer. Returns list of (x1,y1,x2,y2) tuples."""
        mem = self.mpu.memory
        count = mem[LINE_OUT_COUNT]  # byte count
        lines = []
        for i in range(0, count, 4):
            x1 = mem[LINE_OUT_BUF + i]
            y1 = mem[LINE_OUT_BUF + i + 1]
            x2 = mem[LINE_OUT_BUF + i + 2]
            y2 = mem[LINE_OUT_BUF + i + 3]
            lines.append((x1, y1, x2, y2))
        mem[LINE_OUT_COUNT] = 0
        return lines

    @staticmethod
    def _clip_to_screen(x1, y1, x2, y2):
        """Liang-Barsky clip of line to [0,255] x [0,255] (u8 range).

        Y values are biased, so the full u8 range is valid.
        Returns (cx1, cy1, cx2, cy2) as integers, or None if fully outside.
        """
        dx = x2 - x1
        dy = y2 - y1
        # p, q pairs for the four boundaries
        checks = [
            (-dx, x1),          # left   (x >= 0)
            ( dx, 255 - x1),    # right  (x <= 255)
            (-dy, y1),          # top    (y >= 0)
            ( dy, 255 - y1),    # bottom (y <= 255)
        ]
        t0, t1 = 0.0, 1.0
        for p, q in checks:
            if p == 0:
                if q < 0:
                    return None  # parallel and outside
            elif p < 0:
                t = q / p
                if t > t1:
                    return None
                if t > t0:
                    t0 = t
            else:
                t = q / p
                if t < t0:
                    return None
                if t < t1:
                    t1 = t
        cx1 = int(round(x1 + t0 * dx))
        cy1 = int(round(y1 + t0 * dy))
        cx2 = int(round(x1 + t1 * dx))
        cy2 = int(round(y1 + t1 * dy))
        # Final safety clamp
        cx1 = max(0, min(255, cx1))
        cy1 = max(0, min(255, cy1))
        cx2 = max(0, min(255, cx2))
        cy2 = max(0, min(255, cy2))
        return cx1, cy1, cx2, cy2

    def clip_line_records(self, xl, yl, xr, yr, ilo, ihi, buffer_addr):
        """Walk active span list, write per-span sub-records to buffer.
        Returns list of decoded records for testing/inspection.
        Each record: dict with 'si', 'sox0', 'sox1', 'verdict', 'cy0', 'cy1'.
        """
        clipped = self._clip_to_screen(xl, yl, xr, yr)
        if clipped is None:
            # Write count=0, return empty
            self.mpu.memory[buffer_addr] = 0
            return []
        xl, yl, xr, yr = clipped
        if xl == xr and yl == yr:
            self.mpu.memory[buffer_addr] = 0
            return []
        mem = self.mpu.memory
        if xl > xr:
            xl, yl, xr, yr = xr, yr, xl, yl
        mem[ZP_LINE_XL] = xl & 0xFF
        mem[ZP_LINE_YL] = yl & 0xFF
        mem[ZP_LINE_XR] = xr & 0xFF
        mem[ZP_LINE_YR] = yr & 0xFF
        mem[ZP_ILO] = ilo & 0xFF
        mem[ZP_IHI] = ihi & 0xFF
        # Buffer pointer
        mem[ZP_BUF] = buffer_addr & 0xFF
        mem[ZP_BUF + 1] = (buffer_addr >> 8) & 0xFF
        self._run(ENTRY_CLIP_LINE_RECORDS)
        return self._decode_records(buffer_addr)

    def _decode_records(self, buffer_addr):
        """Read records from buffer, return list of dicts."""
        mem = self.mpu.memory
        count = mem[buffer_addr]
        records = []
        for i in range(count):
            off = buffer_addr + 1 + i * REC_BYTES
            v = mem[off + 3]
            verdict = {0: 'above', 1: 'inside', 2: 'below'}.get(v, f'?{v}')
            records.append({
                'si': mem[off + 0],
                'sox0': mem[off + 1],
                'sox1': mem[off + 2],
                'verdict': verdict,
                'cy0': mem[off + 4],
                'cy1': mem[off + 5],
            })
        return records

    def tighten_from_records(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2):
        """Run tighten consuming top+bot record buffers."""
        mem = self.mpu.memory
        mem[ZP_ILO] = max(0, lo) & 0xFF
        mem[ZP_IHI] = min(255, hi) & 0xFF
        # ZP for records-tighten not yet defined — pass via existing slots
        # for now (caller already wrote records to TOP_RECORDS/BOT_RECORDS).
        self._run(ENTRY_TIGHTEN_FROM_RECORDS)

    def draw_clipped_line(self, xl, yl, xr, yr):
        """Clip a single line against the span list and emit visible segments.

        The line is oriented left-to-right by this method.  All coords u8.
        Returns list of (x1, y1, x2, y2) tuples for emitted segments.
        """
        # Pre-clip to screen bounds so all coords fit in u8
        clipped = self._clip_to_screen(xl, yl, xr, yr)
        if clipped is None:
            return []
        xl, yl, xr, yr = clipped
        # Reject degenerate (single-point) lines
        if xl == xr and yl == yr:
            return []
        mem = self.mpu.memory
        # Orient left-to-right
        if xl > xr:
            xl, yl, xr, yr = xr, yr, xl, yl
        mem[ZP_LINE_XL] = xl & 0xFF
        mem[ZP_LINE_YL] = yl & 0xFF
        mem[ZP_LINE_XR] = xr & 0xFF
        mem[ZP_LINE_YR] = yr & 0xFF
        self._run(ENTRY_DRAW_CLIP)
        return self.drain_lines()

    def interp_store(self, x, x0, y0, x1, y1):
        """Call the round-to-nearest interp (span boundary values).

        New interface (post-hoist): x passed in A register, den pre-set
        in zp_div_den, result returned in A. Caller (this wrapper)
        computes den = x1 - x0 before invoking.
        """
        mem = self.mpu.memory
        mem[ZP_I_X0] = x0 & 0xFF
        mem[ZP_I_Y0] = y0 & 0xFF
        mem[ZP_I_Y1] = y1 & 0xFF
        mem[ZP_DIV_DEN] = (x1 - x0) & 0xFF
        self.mpu.a = x & 0xFF
        self._run(ENTRY_INTERP_ST)
        r = self.mpu.a
        return r if r < 128 else r - 256


def test_interp():
    """Test interp_store against Python _interp_store.
    (floor/ceil variants were deleted — only interp_store/seg_interp_store
    are needed by the span-clipper hot path.)"""
    from endpoint_spans import _interp_store
    sc = SpanClip6502()
    sc.init()
    errors = 0
    for x0 in range(0, 250, 50):
        for x1 in range(x0+1, min(x0+100, 256), 17):
            for y0 in range(0, 160, 40):
                for y1 in range(0, 160, 40):
                    for x in range(x0, x1+1, max(1, (x1-x0)//5)):
                        py_s = _interp_store(x, x0, y0, x1, y1)
                        asm_s = sc.interp_store(x, x0, y0, x1, y1)
                        if py_s != asm_s:
                            errors += 1
                            if errors <= 5:
                                print(f'  store MISMATCH: x={x} [{x0},{x1}) y=[{y0},{y1}] py={py_s} asm={asm_s}')
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


def test_draw_clipped_line():
    """Test draw_clipped_line against Python draw_clipped reference.

    Phase 1: basic walk, inner bbox only, no CB clip, no portal.
    Tests lines against various span configurations.
    """
    from endpoint_spans import EndpointClipSpans, _span_top, _span_bot, _interp_store
    from clip_math import div_round

    sc = SpanClip6502()
    total = 0
    matches = 0
    mismatches = 0
    skipped = 0

    def _line_y_at(xl, yl, xr, yr, x):
        """Reference line_y_at using interp_store semantics."""
        dx = xr - xl
        if dx == 0:
            return yl
        return _interp_store(x, xl, yl, xr, yr)

    def _py_draw_clipped_phase1(spans, lx1, ly1, lx2, ly2):
        """Python reference for Phase 1 draw_clipped (inner bbox only, no portal).

        Returns list of (x1, y1, x2, y2) tuples.
        """
        # Orient left-to-right
        if lx1 > lx2:
            lx1, ly1, lx2, ly2 = lx2, ly2, lx1, ly1
        elif lx1 == lx2:
            pass  # vertical
        xl, yl, xr, yr = lx1, ly1, lx2, ly2
        dx_line = xr - xl
        y_lo = min(yl, yr)
        y_hi = max(yl, yr)

        result = []
        seg_start = None
        for s in spans:
            xs, xe = s[0], s[1]
            # Skip spans entirely left/right of line
            if xe <= xl or xs >= xr:
                continue

            # Compute overlap
            ox0 = max(xs, xl)
            ox1 = min(xe, xr)

            # Aperture bounds
            ts = _span_top(s, xs); te = _span_top(s, xe)
            bs = _span_bot(s, xs); be = _span_bot(s, xe)
            ot = min(ts, te)
            ob = max(bs, be)
            it = max(ts, te)
            ib = min(bs, be)

            if seg_start is None:
                # Entry: outer bbox reject
                if y_hi < ot or y_lo > ob:
                    continue
                # Inner bbox accept
                if y_lo >= it and y_hi <= ib:
                    ex = ox0
                    ey = _line_y_at(xl, yl, xr, yr, ex) if ex != xl else yl
                    seg_start = (ex, ey)
                else:
                    # Phase 1: skip ambiguous
                    continue

            # Exit check: does line end within this span?
            if xr <= xe:
                # Line ends here
                sx, sy = seg_start
                # Emit
                result.append((sx, sy, xr, yr))
                seg_start = None
                break
            else:
                # Phase 1: no portal, emit segment and reset
                ex = ox1
                ey = _line_y_at(xl, yl, xr, yr, ex) if ex != xr else yr
                sx, sy = seg_start
                result.append((sx, sy, ex, ey))
                seg_start = None

        # If seg_start still active at end of walk, emit to (xr, yr)
        if seg_start is not None:
            sx, sy = seg_start
            result.append((sx, sy, xr, yr))
        return result

    # --- Test 1: Full screen span, line entirely inside ---
    print('  Test 1: Full screen span, horizontal line')
    sc.init()
    spans = sc.read_spans()
    lines_asm = sc.draw_clipped_line(50, 80, 200, 80)
    lines_py = _py_draw_clipped_phase1(spans, 50, 80, 200, 80)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 2: Full screen span, diagonal line ---
    print('  Test 2: Full screen span, diagonal line')
    sc.init()
    spans = sc.read_spans()
    lines_asm = sc.draw_clipped_line(20, 30, 200, 120)
    lines_py = _py_draw_clipped_phase1(spans, 20, 30, 200, 120)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 3: After mark_solid, line spans gap ---
    print('  Test 3: After mark_solid, line in gap')
    sc.init()
    sc.mark_solid(100, 150)
    spans = sc.read_spans()
    # Line entirely in left gap
    lines_asm = sc.draw_clipped_line(20, 80, 80, 80)
    lines_py = _py_draw_clipped_phase1(spans, 20, 80, 80, 80)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 4: After mark_solid, line crosses solid region ---
    print('  Test 4: Line crosses solid region (no portal = two segments)')
    sc.init()
    sc.mark_solid(100, 150)
    spans = sc.read_spans()
    lines_asm = sc.draw_clipped_line(50, 80, 200, 80)
    lines_py = _py_draw_clipped_phase1(spans, 50, 80, 200, 80)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 5: Line entirely outside (above top) ---
    print('  Test 5: Line above aperture top')
    sc.init()
    sc.tighten(0, 255, 0, 255, 50, 50, 120, 120)
    spans = sc.read_spans()
    lines_asm = sc.draw_clipped_line(20, 10, 200, 10)
    lines_py = _py_draw_clipped_phase1(spans, 20, 10, 200, 10)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 6: Line entirely outside (below bot) ---
    print('  Test 6: Line below aperture bot')
    sc.init()
    sc.tighten(0, 255, 0, 255, 50, 50, 120, 120)
    spans = sc.read_spans()
    lines_asm = sc.draw_clipped_line(20, 140, 200, 140)
    lines_py = _py_draw_clipped_phase1(spans, 20, 140, 200, 140)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 7: Diagonal line inside tightened aperture ---
    print('  Test 7: Diagonal line inside tightened aperture')
    sc.init()
    sc.tighten(0, 255, 0, 255, 20, 20, 140, 140)
    spans = sc.read_spans()
    lines_asm = sc.draw_clipped_line(30, 60, 220, 100)
    lines_py = _py_draw_clipped_phase1(spans, 30, 60, 220, 100)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 8: Line partially outside (Phase 1 skips ambiguous) ---
    print('  Test 8: Line partially outside aperture (Phase 1 skips)')
    sc.init()
    sc.tighten(0, 255, 0, 255, 50, 50, 120, 120)
    spans = sc.read_spans()
    # Line from y=40 (above top=50) to y=80 (inside) — ambiguous entry
    lines_asm = sc.draw_clipped_line(30, 40, 200, 80)
    lines_py = _py_draw_clipped_phase1(spans, 30, 40, 200, 80)
    if lines_asm == lines_py:
        print('    MATCH (both empty — Phase 1 skips ambiguous)')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 9: Line starts mid-span (ox0 != xl) ---
    print('  Test 9: Line starts mid-span (needs line_y_at)')
    sc.init()
    sc.mark_solid(0, 50)  # remove left columns
    spans = sc.read_spans()
    # Line from x=20 to x=200, but span starts at x=51
    lines_asm = sc.draw_clipped_line(20, 40, 200, 120)
    lines_py = _py_draw_clipped_phase1(spans, 20, 40, 200, 120)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 10: Multiple spans after multiple mark_solids ---
    print('  Test 10: Multiple gaps, line through all')
    sc.init()
    sc.mark_solid(50, 80)
    sc.mark_solid(120, 160)
    sc.mark_solid(200, 220)
    spans = sc.read_spans()
    lines_asm = sc.draw_clipped_line(10, 79, 250, 79)
    lines_py = _py_draw_clipped_phase1(spans, 10, 79, 250, 79)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 11: Sloped line through multiple gaps ---
    print('  Test 11: Sloped line through multiple gaps')
    sc.init()
    sc.mark_solid(80, 120)
    sc.mark_solid(180, 200)
    spans = sc.read_spans()
    lines_asm = sc.draw_clipped_line(10, 30, 250, 130)
    lines_py = _py_draw_clipped_phase1(spans, 10, 30, 250, 130)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 12: Reversed line (xr < xl before orient) ---
    print('  Test 12: Reversed line orientation')
    sc.init()
    spans = sc.read_spans()
    lines_asm = sc.draw_clipped_line(200, 120, 50, 40)
    lines_py = _py_draw_clipped_phase1(spans, 200, 120, 50, 40)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 13: Edge case - line exactly at bbox boundary ---
    print('  Test 13: Line Y exactly at inner bbox boundary')
    sc.init()
    sc.tighten(0, 255, 0, 255, 50, 50, 120, 120)
    spans = sc.read_spans()
    # Line at y=50 (exactly at top boundary) — should be accepted (ylo >= it)
    lines_asm = sc.draw_clipped_line(20, 50, 200, 50)
    lines_py = _py_draw_clipped_phase1(spans, 20, 50, 200, 50)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 14: Line at y=120 (exactly at bottom boundary) ---
    print('  Test 14: Line Y exactly at bottom bbox boundary')
    sc.init()
    sc.tighten(0, 255, 0, 255, 50, 50, 120, 120)
    spans = sc.read_spans()
    lines_asm = sc.draw_clipped_line(20, 120, 200, 120)
    lines_py = _py_draw_clipped_phase1(spans, 20, 120, 200, 120)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 15: Sloped tighten aperture, flat line inside ---
    print('  Test 15: Sloped aperture, flat line inside')
    sc.init()
    sc.tighten(0, 255, 0, 255, 30, 60, 130, 100)
    spans = sc.read_spans()
    lines_asm = sc.draw_clipped_line(10, 80, 240, 80)
    lines_py = _py_draw_clipped_phase1(spans, 10, 80, 240, 80)
    if lines_asm == lines_py:
        print('    MATCH')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    # --- Test 16: Empty span list (all solid) ---
    print('  Test 16: Empty span list')
    sc.init()
    sc.mark_solid(0, 255)
    spans = sc.read_spans()
    lines_asm = sc.draw_clipped_line(50, 80, 200, 80)
    lines_py = _py_draw_clipped_phase1(spans, 50, 80, 200, 80)
    if lines_asm == lines_py:
        print('    MATCH (both empty)')
        matches += 1
    else:
        print(f'    MISMATCH: asm={lines_asm} py={lines_py}')
        mismatches += 1
    total += 1

    print(f'  Summary: {matches}/{total} tests passed, {mismatches} mismatches')
    return mismatches == 0


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
    print('draw_clipped_line tests:')
    test_draw_clipped_line()
    print()
    print('Full frame comparison:')
    test_frame()
