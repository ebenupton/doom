"""Python wrapper for the 6502 span clipper subsystem.

Loads span_clip.bin into py65, provides methods to call each entry point,
and reads results back.  Used for comparison testing against EndpointClipSpans.
"""
import os

# CPU target: set DOOM_CPU=65c02 to build the engine with -D C02=1 and run it on
# py65's 65C02 core; anything else = plain 6502. Drives both the beebasm flag and
# the MPU class so the build and the executor always agree.
_C02 = '1' if os.environ.get('DOOM_CPU', '').lower() in ('65c02', 'c02', '1') else '0'
if _C02 == '1':
    from py65.devices.mpu65c02 import MPU
else:
    from py65.devices.mpu6502 import MPU


# Engine addresses come from the linked symbol map (ld65 dbgfile) — no more
# hand-mirrored magic numbers. Names are the .s source labels/equates.
from symmap import sym as _sym

# Entry points (span_clip jump table labels)
ENTRY_INIT       = _sym('jt_init')
ENTRY_MARK_SOLID = _sym('jt_mark_solid')
ENTRY_HAS_GAP    = _sym('jt_has_gap')
ENTRY_IS_FULL    = _sym('jt_is_full')
ENTRY_READ       = _sym('jt_read')
ENTRY_INTERP_ST  = _sym('jt_interp_store')
ENTRY_DRAW_CLIP  = _sym('jt_draw_clip')
ENTRY_TIGHTEN_FROM_RECORDS = _sym('jt_tighten_from_records')
ENTRY_DRAW_CLIP_S16 = _sym('jt_draw_clip_s16')

# Records buffers
TOP_RECORDS = _sym('TOP_RECORDS')
BOT_RECORDS = _sym('BOT_RECORDS')
REC_BYTES = 4   # one record per surviving DCL segment: (xl, yl, xr, yr)

# s16 line clipper hi bytes (ZP, alias CB-clip / secondary-seg block).
zp_line_xl_hi = _sym('zp_line_xl_hi')
zp_line_yl_hi = _sym('zp_line_yl_hi')
zp_line_xr_hi = _sym('zp_line_xr_hi')
zp_line_yr_hi = _sym('zp_line_yr_hi')

# DCL records-hook ZP slots
ZP_DCL_REC_BUF   = _sym('zp_dcl_rec_buf')
ZP_DCL_REC_BUF_H = _sym('zp_dcl_rec_buf_h')

# ZP addresses (linked equates)
ZP_HEAD  = _sym('zp_head')
ZP_FREE  = _sym('zp_free')
ZP_ILO   = _sym('zp_ilo')
ZP_IHI   = _sym('zp_ihi')
ZP_I_X0  = _sym('zp_i_x0')
ZP_I_Y0  = _sym('zp_i_y0')
ZP_I_Y1  = _sym('zp_i_y1')
ZP_DIV_DEN = _sym('zp_div_den')
ZP_BUF   = _sym('zp_buf')
ZP_MS_EMIT = _sym('zp_ms_emit')
ZP_LINE_XL = _sym('zp_line_xl_lo')
ZP_LINE_YL = _sym('zp_line_yl_lo')
ZP_LINE_XR = _sym('zp_line_xr_lo')
ZP_LINE_YR = _sym('zp_line_yr_lo')
# Secondary seg Y values (u8), also aliased as the s16 DCL input hi bytes

# Pool
POOL_BASE = _sym('POOL')

# Buffer for span_read output (harness-owned scratch, not an engine symbol)
READ_BUF = 0x0300

# Line output buffer (written by 6502 during tighten/mark_solid)
LINE_OUT_COUNT = _sym('LINE_OUT_COUNT')
LINE_OUT_BUF   = _sym('LINE_OUT_BUF')


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
        # When set to a list, every emitted (x0,y0,x1,y1) raster segment is
        # appended (drained from LINE_OUT after each entry that can emit).
        # Feeds the pixel-exact pure-Python reference (tools/pyref_render.py).
        self.capture = None
        mem = self.mpu.memory

        # Load quarter-square tables
        sqr_lo, sqr_hi, sqr2_lo, sqr2_hi = _gen_quarter_square()
        mem[0xA500:0xA600] = sqr_lo
        mem[0xA600:0xA700] = sqr_hi
        mem[0xA700:0xA800] = sqr2_lo
        mem[0xA800:0xA900] = sqr2_hi

        # Build + load every engine region (clipper, renderer regions, angle
        # module) at the addresses in the ld65 config — one loader, no
        # file-existence guards to rot (a deleted legacy .asm once silently
        # disabled the renderer load).
        from engine_load import load_engine
        load_engine(mem, banked=0, c02=int(_C02))

        # Reciprocal mantissa table at $E000: M8[idx] for the 10-bit 9.1
        # index (4 pages; S = bit_length(idx-1) is computed, not stored).
        from fp import _RECIP_M8
        for i in range(1024):
            mem[0xE000 + i] = _RECIP_M8[i]

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
        """mark_solid(lo, hi).

        Inclusive right edge (solid wall covers last column).
        Closed-interval: ilo, ihi are both inclusive column indices in [0,255].

        Seg params are accepted for API compatibility but ignored — wall
        line emission is handled by draw_clipped_line (DCL), so the 6502's
        internal ms_emit_lines path stays disabled (ZP_MS_EMIT = 0).
        """
        mem = self.mpu.memory
        ilo = max(0, lo)
        ihi = min(255, hi)
        if ihi < ilo:
            return
        mem[ZP_ILO] = ilo & 0xFF
        mem[ZP_IHI] = ihi & 0xFF
        mem[ZP_MS_EMIT] = 0x00
        self._run(ENTRY_MARK_SOLID)
        if self.capture is not None:
            self.capture.extend(self.drain_lines())

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

        Records-driven path (default) skips all seg-param preconditioning —
        line geometry comes from segment records written by the prior
        draw_clipped_line(yt) and draw_clipped_line(yb) calls. The
        BSP/transform-cache values flow through unchanged. Legacy path
        (records mode off) still applies _remap_seg_for_8bit for
        ENTRY_TIGHTEN's 8-bit interp pipeline.
        """
        mem = self.mpu.memory
        ilo = max(0, lo)
        ihi = min(255, hi)
        if ihi < ilo:
            return

        # Records-driven (the ONLY path): line geometry comes from the
        # segment records the prior draw_clipped_line(yt/yb) calls wrote.
        # Just pass [ilo, ihi] through and dispatch.
        if mem[TOP_RECORDS] == 0 and mem[BOT_RECORDS] == 0:
            # Zero records is ambiguous: the aperture edges drew nothing
            # either because the opening covers the whole screen (genuine
            # no-op) or because the opening is entirely OFF-screen (every
            # visible row in [ilo,ihi] is wall/flat -> the columns must be
            # CLOSED). Mirror of seg_zero_rec_solid in src/clip/tfr.s and
            # of endpoint_spans' record verdicts. yt/yb here are the
            # combined (min/max) band boundaries, biased.
            if ((yb1 < 48 and yb2 < 48) or
                    (yt1 > 48 + 159 and yt2 > 48 + 159)):
                self.mark_solid(ilo, ihi)
            return
        mem[ZP_ILO] = ilo & 0xFF
        mem[ZP_IHI] = ihi & 0xFF
        self._run(ENTRY_TIGHTEN_FROM_RECORDS)
        if self.capture is not None:
            self.capture.extend(self.drain_lines())

    _reset_count = [0]
    def reset_records(self):
        """Zero record buffer counts. Called by the wireframe between segs
        so stale records don't leak into the next seg's tighten."""
        mem = self.mpu.memory
        mem[TOP_RECORDS] = 0
        mem[BOT_RECORDS] = 0
        SpanClip6502._reset_count[0] += 1

    def _read_span_at_slot(self, slot):
        """Read a single span from pool by slot number."""
        mem = self.mpu.memory
        POOL_NEXT = 0x0400
        POOL_XLO = 0x0420
        POOL_DEN = 0x0440
        POOL_TL = 0x0460
        POOL_BL = 0x0480
        POOL_TR = 0x04A0
        POOL_BR = 0x04C0
        POOL_XSTART = 0x04E0
        POOL_XEND = 0x0500
        xlo = mem[POOL_XLO + slot]
        den = mem[POOL_DEN + slot]
        return (mem[POOL_XSTART + slot], mem[POOL_XEND + slot],
                xlo, (xlo + den) & 0xFF,
                mem[POOL_TL + slot], mem[POOL_BL + slot],
                mem[POOL_TR + slot], mem[POOL_BR + slot])

    def _set_spans(self, spans):
        """Write spans list to 6502 pool, replacing current state.
        Spans must be in xstart order, non-overlapping. Up to 31 spans."""
        mem = self.mpu.memory
        POOL_NEXT = 0x0400
        POOL_XLO = 0x0420
        POOL_DEN = 0x0440
        POOL_TL = 0x0460
        POOL_BL = 0x0480
        POOL_TR = 0x04A0
        POOL_BR = 0x04C0
        POOL_XSTART = 0x04E0
        POOL_XEND = 0x0500
        POOL_OT = 0x0520
        POOL_OB = 0x0540
        POOL_IT = 0x0560
        POOL_IB = 0x0580
        n = len(spans)
        if n > 31:
            raise RuntimeError(f"too many spans for pool ({n} > 31)")
        for i, s in enumerate(spans):
            slot = i + 1
            xstart, xend, xlo, xhi, tl, bl, tr, br = s
            mem[POOL_XSTART + slot] = xstart & 0xFF
            mem[POOL_XEND + slot] = xend & 0xFF
            mem[POOL_XLO + slot] = xlo & 0xFF
            mem[POOL_DEN + slot] = (xhi - xlo) & 0xFF
            mem[POOL_TL + slot] = tl & 0xFF
            mem[POOL_BL + slot] = bl & 0xFF
            mem[POOL_TR + slot] = tr & 0xFF
            mem[POOL_BR + slot] = br & 0xFF
            mem[POOL_OT + slot] = min(tl, tr) & 0xFF
            mem[POOL_OB + slot] = max(bl, br) & 0xFF
            mem[POOL_IT + slot] = max(tl, tr) & 0xFF
            mem[POOL_IB + slot] = min(bl, br) & 0xFF
            mem[POOL_NEXT + slot] = (i + 2) if (i + 1) < n else 0
        mem[ZP_HEAD] = 1 if n > 0 else 0
        # Free chain: slots after used spans
        free_start = n + 1
        if free_start <= 31:
            mem[ZP_FREE] = free_start
            for i in range(free_start, 32):
                mem[POOL_NEXT + i] = (i + 1) if i < 31 else 0
        else:
            mem[ZP_FREE] = 0

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
    def _clip_x_range(x1, y1, x2, y2, xlo, xhi):
        """Clip line x range to [xlo, xhi]; uses _interp_store (matches
        6502's u8 interp) for y values at clipped endpoints, preserving
        the original line's interpolation behaviour at intermediate x.
        Returns (cx1, cy1, cx2, cy2) or None if outside.

        Phase A's clip_line_records skips spans with xstart >= ihi.
        DCL's walk terminator `xstart >= line_xr` gives the same
        exclusion when line_xr = ihi. To preserve overlap [xstart, ihi]
        for spans crossing ihi, line_xr is set to ihi+1 (so DCL accepts
        spans with xstart=ihi as the last column).
        Note: Phase A's clr_skip uses BCC zp_ihi → BCC + BEQ skip, so it
        effectively skips when xstart >= ihi too; matched here.
        """
        from endpoint_spans import _interp_store
        if x1 > x2:
            x1, y1, x2, y2 = x2, y2, x1, y1
        if x2 < xlo or x1 > xhi:
            return None
        orig_x1, orig_y1, orig_x2, orig_y2 = x1, y1, x2, y2
        if x1 < xlo:
            y1 = _interp_store(xlo, orig_x1, orig_y1, orig_x2, orig_y2)
            x1 = xlo
        if x2 > xhi:
            y2 = _interp_store(xhi, orig_x1, orig_y1, orig_x2, orig_y2)
            x2 = xhi
        x1 = max(0, min(255, x1))
        x2 = max(0, min(255, x2))
        y1 = max(0, min(255, y1))
        y2 = max(0, min(255, y2))
        return x1, y1, x2, y2

    @staticmethod
    def _clip_to_screen(x1, y1, x2, y2):
        """Clip line to u8 [0,255] x [0,255].

        Uses _interp_store (matches 6502's u8 interp_store rounding) for y
        values at clipped endpoints when only x is out of range. This is
        important for records-mode emission: tighten consumes records cy
        values directly, so they must match what the tighten event walk's
        interp would compute at the same x — i.e., be rounded the same way.

        Returns (cx1, cy1, cx2, cy2) or None if fully outside.
        """
        from endpoint_spans import _interp_store
        # Quick reject: line fully off-screen on one axis.
        if x1 < 0 and x2 < 0: return None
        if x1 > 255 and x2 > 255: return None
        if y1 < 0 and y2 < 0: return None
        if y1 > 255 and y2 > 255: return None

        # Y in range — only X clipping needed (common path).
        if 0 <= y1 <= 255 and 0 <= y2 <= 255:
            ox1, oy1, ox2, oy2 = x1, y1, x2, y2
            if x1 < 0:
                y1 = _interp_store(0, ox1, oy1, ox2, oy2)
                x1 = 0
            if x1 > 255:
                y1 = _interp_store(255, ox1, oy1, ox2, oy2)
                x1 = 255
            if x2 < 0:
                y2 = _interp_store(0, ox1, oy1, ox2, oy2)
                x2 = 0
            if x2 > 255:
                y2 = _interp_store(255, ox1, oy1, ox2, oy2)
                x2 = 255
            return x1, y1, x2, y2

        # Y out of range — fall back to Liang-Barsky float clipping.
        dx = x2 - x1
        dy = y2 - y1
        checks = [(-dx, x1), (dx, 255 - x1), (-dy, y1), (dy, 255 - y1)]
        t0, t1 = 0.0, 1.0
        for p, q in checks:
            if p == 0:
                if q < 0:
                    return None
            elif p < 0:
                t = q / p
                if t > t1: return None
                if t > t0: t0 = t
            else:
                t = q / p
                if t < t0: return None
                if t < t1: t1 = t
        cx1 = int(round(x1 + t0 * dx))
        cy1 = int(round(y1 + t0 * dy))
        cx2 = int(round(x1 + t1 * dx))
        cy2 = int(round(y1 + t1 * dy))
        cx1 = max(0, min(255, cx1))
        cy1 = max(0, min(255, cy1))
        cx2 = max(0, min(255, cx2))
        cy2 = max(0, min(255, cy2))
        return cx1, cy1, cx2, cy2

    def tighten_from_records(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2):
        """Run tighten consuming top+bot record buffers."""
        mem = self.mpu.memory
        mem[ZP_ILO] = max(0, lo) & 0xFF
        mem[ZP_IHI] = min(255, hi) & 0xFF
        # ZP for records-tighten not yet defined — pass via existing slots
        # for now (caller already wrote records to TOP_RECORDS/BOT_RECORDS).
        self._run(ENTRY_TIGHTEN_FROM_RECORDS)

    def draw_clipped_line(self, xl, yl, xr, yr, records_buf=None):
        """Clip a single s16 line against the span list and emit visible segments.

        Inputs are s16 (raw BSP/transform values, can be negative or > 255).
        The 6502 ENTRY_DRAW_CLIP_S16 entry checks if the line is already in
        u8 range; if so it tail-calls DCL directly (the wrapper has already
        written zp_line_xl_lo/yl/xr/yr). Out-of-range lines hit the slow
        clipping path. Returns list of emitted (x1, y1, x2, y2) segments.
        """
        mem = self.mpu.memory
        if records_buf is not None:
            mem[records_buf] = 0
        # Trivial wrapper-side prep: order endpoints, reject degenerate.
        # Both are simple data shuffling — they preserve the line's
        # geometry and don't constitute "pre-conditioning" of values.
        if xl > xr:
            xl, yl, xr, yr = xr, yr, xl, yl
        if xl == xr and yl == yr:
            return []
        # Lo bytes alias zp_line_*; on the in-range fast path the 6502
        # entry just JMPs draw_clipped_line and these bytes are already
        # the correct u8 values DCL needs.
        mem[ZP_LINE_XL] = xl & 0xFF
        mem[ZP_LINE_YL] = yl & 0xFF
        mem[ZP_LINE_XR] = xr & 0xFF
        mem[ZP_LINE_YR] = yr & 0xFF
        mem[zp_line_xl_hi] = (xl >> 8) & 0xFF
        mem[zp_line_yl_hi] = (yl >> 8) & 0xFF
        mem[zp_line_xr_hi] = (xr >> 8) & 0xFF
        mem[zp_line_yr_hi] = (yr >> 8) & 0xFF
        if records_buf is not None:
            mem[ZP_DCL_REC_BUF]   = records_buf & 0xFF
            mem[ZP_DCL_REC_BUF_H] = (records_buf >> 8) & 0xFF
        else:
            mem[ZP_DCL_REC_BUF_H] = 0
        self._run(ENTRY_DRAW_CLIP_S16)
        if records_buf is not None:
            mem[ZP_DCL_REC_BUF]   = 0
            mem[ZP_DCL_REC_BUF_H] = 0
        lines = self.drain_lines()
        if self.capture is not None:
            self.capture.extend(lines)
        return lines

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



# NOTE: the old __main__ self-tests were removed — their expectations
# predated Y_BIAS and reported false failures. The real gates are
# run_regression.py (unit + differential + ground-truth + cycles).
