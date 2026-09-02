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
ENTRY_INIT       = _sym('span_init')
ENTRY_MARK_SOLID = _sym('span_mark_solid')
ENTRY_HAS_GAP    = _sym('span_has_gap')
ENTRY_INTERP_ST  = _sym('interp_store')
ENTRY_DRAW_CLIP  = _sym('draw_clipped_line')
ENTRY_FUSED_BEGIN = _sym('fused_begin')
ENTRY_FUSED_ABOVE = _sym('fused_above_raw')
ENTRY_FUSED_BELOW = _sym('fused_below_raw')
ENTRY_FUSED_MERGE = _sym('fused_merge_range')
FW_TOUCH = _sym('FW_TOUCH')
ENTRY_DRAW_CLIP_S16 = _sym('draw_clipped_line_s16')

# Records buffers
# (TOP/BOT_RECORDS died with the records machinery, 2026-08-25)
REC_BYTES = 4   # one record per surviving DCL segment: (xl, yl, xr, yr)

# s16 line clipper hi bytes (ZP, alias CB-clip / secondary-seg block).
zp_line_xl_h = _sym('zp_line_xl_h')
zp_line_yl_h = _sym('zp_line_yl_h')
zp_line_xr_h = _sym('zp_line_xr_h')
zp_line_yr_h = _sym('zp_line_yr_h')

# DCL records-hook ZP slots
# (ZP_DCL_REC_* retired 2026-08-25: the records machinery died with the
#  FUSED walker; the zp bytes were reassigned)

# ZP addresses (linked equates)
ZP_HEAD  = _sym('zp_head')
ZP_FREE  = _sym('zp_free')
ZP_ILO   = _sym('zp_i_l')
ZP_IHI   = _sym('zp_i_h')
ZP_I_X0  = _sym('zp_i_x0')
ZP_I_Y0  = _sym('zp_i_y0')
ZP_I_Y1  = _sym('zp_i_y1')
ZP_DIV_DEN = _sym('zp_div_den')
ZP_LINE_XL = _sym('zp_line_xl_l')
ZP_LINE_YL = _sym('zp_line_yl_l')
ZP_LINE_XR = _sym('zp_line_xr_l')
ZP_LINE_YR = _sym('zp_line_yr_l')
# Secondary seg Y values (u8), also aliased as the s16 DCL input hi bytes

# Pool
POOL_BASE = _sym('POOL')
# Pool field planes (linked symbols — one truth with the .s layout;
# hoisted 2026-07-26 when read_spans went direct, replacing two
# method-local magic-number blocks)
POOL_NEXT   = _sym('POOL_NEXT')
POOL_TXLO    = _sym('POOL_TXLO')
POOL_TDEN    = _sym('POOL_TDEN')
POOL_TL     = _sym('POOL_TL')
POOL_BL     = _sym('POOL_BL')
POOL_TR     = _sym('POOL_TR')
POOL_BR     = _sym('POOL_BR')
POOL_XSTART = _sym('POOL_XSTART')
POOL_XEND   = _sym('POOL_XEND')
POOL_OT     = _sym('POOL_OT')
POOL_OB     = _sym('POOL_OB')
POOL_IT     = _sym('POOL_IT')
POOL_IB     = _sym('POOL_IB')

# Plot-entry PCs for line capture (LINE_OUT retired 2026-07-26: _run
# traps these PCs and reads the staged RASTER_ZP args directly — the
# engine-side buffer, EN gate and per-call count zeroing are gone).
# Every emitted line reaches exactly one of these three entries.
PLOT_PCS = frozenset((_sym('plot_h'), _sym('plot_v'), _sym('RASTER_ENTRY')))
RZ_X0 = _sym('RASTER_ZP_X0'); RZ_Y0 = _sym('RASTER_ZP_Y0')
RZ_X1 = _sym('RASTER_ZP_X1'); RZ_Y1 = _sym('RASTER_ZP_Y1')


def _gen_quarter_square():
    """Generate quarter-square tables (same as fe6502.py)."""
    sqr_l = bytearray(256)
    sqr_h = bytearray(256)
    sqr2_l = bytearray(256)
    sqr2_h = bytearray(256)
    for n in range(256):
        v = (n * n) >> 2
        sqr_l[n] = v & 0xFF
        sqr_h[n] = (v >> 8) & 0xFF
    for n in range(256):
        v = ((n + 256) * (n + 256)) >> 2
        sqr2_l[n] = v & 0xFF
        sqr2_h[n] = (v >> 8) & 0xFF
    return sqr_l, sqr_h, sqr2_l, sqr2_h


class SpanClip6502:
    """6502 span clipper subsystem running in py65."""

    def __init__(self):
        self.mpu = MPU()
        self.total_cycles = 0
        self.last_cycles = 0
        # When set to a list, every emitted (x0,y0,x1,y1) raster segment is
        # appended (plot-entry PC traps in _run collect them per call).
        # Feeds the pixel-exact pure-Python reference (tools/pyref_render.py).
        self.capture = None
        # lines emitted by the most recent _run (plot-entry PC traps);
        # a traced-run override (trace_compare) bypasses the traps, so
        # this can be stale there — those flows never read it.
        self.last_lines = []
        # Per-instance so a BANKED rig can swap in bank-C code addresses:
        # plot_h/plot_v/RASTER_ENTRY are the only symbols here that MOVE
        # between builds (everything else is zp/pool, and $0000-$57FF is
        # identical in both maps).  2026-08-29.
        self.PLOT_PCS = PLOT_PCS
        # ...and so are the CODE ENTRIES.  These are the only other symbols
        # this class names that MOVE between builds; zp/pool names do not
        # ($0000-$57FF is identical in both maps by rule).  A banked rig
        # left with the flat values jumps into unrelated code: has_gap came
        # back with the wrong carry, so the Python walk pruned at the ROOT
        # and the differential visited ZERO subsectors while reporting
        # itself green.  2026-08-30.
        self.ENTRY_INIT = ENTRY_INIT
        self.ENTRY_MARK_SOLID = ENTRY_MARK_SOLID
        self.ENTRY_HAS_GAP = ENTRY_HAS_GAP
        self.ENTRY_INTERP_ST = ENTRY_INTERP_ST
        self.ENTRY_DRAW_CLIP = ENTRY_DRAW_CLIP
        self.ENTRY_FUSED_BEGIN = ENTRY_FUSED_BEGIN
        self.ENTRY_FUSED_ABOVE = ENTRY_FUSED_ABOVE
        self.ENTRY_FUSED_BELOW = ENTRY_FUSED_BELOW
        self.ENTRY_FUSED_MERGE = ENTRY_FUSED_MERGE
        self.ENTRY_DRAW_CLIP_S16 = ENTRY_DRAW_CLIP_S16
        mem = self.mpu.memory

        # Load quarter-square tables (base from the generated ABI — the flat
        # base moved $A500 -> $A400 in the 2026-07-12 one-region merge)
        import abi as _abi
        sqr_l, sqr_h, sqr2_l, sqr2_h = _gen_quarter_square()
        mem[_abi.SQR_LO:_abi.SQR_LO + 0x100] = sqr_l
        mem[_abi.SQR2_LO:_abi.SQR2_LO + 0x100] = sqr2_l
        mem[_abi.SQR_HI:_abi.SQR_HI + 0x100] = sqr_h
        mem[_abi.SQR2_HI:_abi.SQR2_HI + 0x100] = sqr2_h
        # even-mirror pages (what the boot fill tail writes): MIR[k] =
        # f(256-k), MIR[0] = f(256) — the t16p2 diff-side reach
        for k in range(1, 256):
            mem[_abi.SQR_MIR_LO + k] = sqr_l[256 - k] if 256 - k < 256 else 0
            mem[_abi.SQR_MIR_HI + k] = sqr_h[256 - k] if 256 - k < 256 else 0
        mem[_abi.SQR_MIR_LO] = 0
        mem[_abi.SQR_MIR_HI] = 64

        # Build + load every engine region (clipper, renderer regions, angle
        # module) at the addresses in the ld65 config — one loader, no
        # file-existence guards to rot (a deleted legacy .asm once silently
        # disabled the renderer load).
        from engine_load import load_engine
        load_engine(mem, banked=0, c02=int(_C02))

        # Reciprocal mantissa table at $D500: M8[idx] for the 10-bit 9.1
        # index (4 pages; S = bit_length(idx-1) is computed, not stored).
        # Page 0 NIBBLE-SWAPPED (2026-08-10): the fast path indexes
        # (vy_l & $F0) | vy_h; pages 1-3 linear (recip_hi ladder).
        from fp import _RECIP_M8
        import symmap as _sm, wad_packed as _wp
        _m8 = _sm.sym('RECIP_M8', banked=0)
        for i in range(256):
            mem[_m8 + (((i & 0x0F) << 4) | (i >> 4))] = _RECIP_M8[i]
        _m8h = _sm.sym('RECIP_M8H', banked=0)
        for i in range(128, 256):
            mem[_m8h + i - 128] = _RECIP_M8[i]     # far half (unswapped;
                                                   # the linear pages died)
        # RECIP_S, the junior-page shift table: assembled data in the LDATA
        # region at $1E00 until 2026-08-17, a seeded table beside the mantissa
        # pages since (banked: bank A $B300).
        _s = _sm.sym('RECIP_S', banked=0)
        for i, b in enumerate(_wp.srecip_table()):
            mem[_s + i] = b

        # NO NJ RASTERISER (2026-08-30).  The flat image IS the tube
        # parasite now: the copro runs the engine and EMITS draw commands,
        # the host rasterises.  The blob used to be loaded here at $7500 and
        # then blind-zeroed by tube/build_tube_game before the emitters were
        # written over it -- surgery that once wiped a LIVE region and gave
        # a black screen.  Not shipping it is the fix.  The flat rig is a
        # bisect tool only (DOOM_FLAT_RIG=1) and cannot draw diagonals.
        self._has_rasteriser = False

        # Screen buffer at $5800 (5120 bytes)
        # THE PARASITE MAP (2026-09-02): the flat build has NO framebuffer
        # — $EA00+ is CBITS territory and the old FB clear was shredding
        # the clipper.  SCREEN_START = None makes clear_screen and the
        # surface reader inert; pixel harnesses run the BANKED build.
        self.SCREEN_START = None
        self.SCREEN_SIZE = 0
        mem[_sym('RASTER_ZP_SCRSTRT')] = 0x58   # vestigial (banked FB hi)

        # BRK at halt address
        mem[0xFF00] = 0x00

        # PLOT STUBS (2026-09-02): the parasite ships plot_h/plot_v as
        # 3-byte patch slots and no rasteriser at RASTER_ENTRY — the tube
        # builder writes the real emitters.  The bare rig plants RTS so a
        # render runs to completion; _run's PLOT_PCS traps still record
        # every emitted line from RASTER_ZP.
        for _n in ('plot_h', 'plot_v', 'RASTER_ENTRY'):
            mem[_sym(_n)] = 0x60

    def _run(self, entry, max_cycles=500000):
        """Run from entry point until BRK at $FF00.

        STACK GUARD (2026-08-31, Eben): FAULT on any push that would land
        in $01E0-$01FF -- that range is SQR_MIRROR, the quarter-square
        diff prefix, and the design contract says the stack never touches
        it (SP is capped at $DD everywhere).  The trig8-restore hunt
        found the mirror trashed mid-render, so the contract is enforced
        at the simulator now: PHA/PHP with SP >= $E0, JSR with SP >= $E0
        or SP == 0 (its second byte wraps to $01FF), BRK with SP >= $E0
        or SP <= 1.  A fault here is an ENGINE bug, never noise."""
        mpu = self.mpu
        mem = mpu.memory
        mpu.pc = entry
        mpu.sp = 0xDD  # SP capped below SQR_MIRROR ($01E0-$01FF, the stack-page mirror)
        mpu.p = 0x30
        # Push return to $FF00-1 = $FEFF (RTS adds 1)
        mem[0x01DF] = 0xFE
        mem[0x01DE] = 0xFF
        mpu.processorCycles = 0
        lines = self.last_lines = []
        for _ in range(max_cycles):
            pc = mpu.pc
            if pc == 0xFF00:
                break
            op = mem[pc]
            if op == 0x20 or op == 0x48 or op == 0x08 or op == 0x00:
                sp = mpu.sp
                if sp >= 0xE0 or (op == 0x20 and sp == 0) or (op == 0x00 and sp <= 1):
                    raise RuntimeError(
                        f'STACK GUARD: op ${op:02x} at ${pc:04x} would push '
                        f'into SQR_MIRROR (SP=${sp:02x}, write at '
                        f'${0x100 + sp:04x}) — entry ${entry:04x}')
            if pc in self.PLOT_PCS:
                lines.append((mem[RZ_X0], mem[RZ_Y0], mem[RZ_X1], mem[RZ_Y1]))
            mpu.step()
        self.last_cycles = mpu.processorCycles
        self.total_cycles += self.last_cycles
        return self.last_cycles

    def clear_screen(self):
        """Clear the framebuffer (no-op on the FB-less parasite map)."""
        if self.SCREEN_START is None:
            return
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
        self._run(self.ENTRY_INIT)
        self.total_cycles = 0  # init cost doesn't count toward frame

    def mark_solid(self, lo, hi, sx1=None, sx2=None, yt1=None, yt2=None, yb1=None, yb2=None):
        """mark_solid(lo, hi) — NATIVE HALF-OPEN [lo, hi), hi exclusive.

        Empty (hi <= lo) is a no-op. Both edges fit u8: the column
        domain is [0, 255) with 255 the permanently-solid decree column.

        Seg params are accepted for API compatibility but ignored — wall
        line emission is handled by draw_clipped_line (DCL), so the 6502's
        (the vestigial ms_emit flag was GC'd 2026-07-12.)
        """
        mem = self.mpu.memory
        ilo = max(0, lo)
        ihi = min(255, hi)                 # NATIVE [lo, hi): 255 max edge
        if ihi <= ilo:
            return
        mem[ZP_ILO] = ilo & 0xFF
        mem[ZP_IHI] = ihi & 0xFF
        self._run(self.ENTRY_MARK_SOLID)
        if self.capture is not None:
            self.capture.extend(self.last_lines)

    def fused_begin(self):
        """Per-seg / per-object: reset the walker's touch state."""
        self._run(self.ENTRY_FUSED_BEGIN, max_cycles=100)

    def draw_fused_line(self, xl, yl, xr, yr, side):
        """FUSED (2026-08-25): clip + plot + APPLY one armed aperture
        line, sequentially (Eben's decree). side: 'top' | 'bot'. The
        boundary written to covered spans is the FULL u8 line — pure
        copy, no interpolation. Returns the plotted fragments."""
        mem = self.mpu.memory
        if xl > xr:
            xl, yl, xr, yr = xr, yr, xl, yl
        if xl == xr and yl == yr:
            return []
        mem[ZP_LINE_XL] = xl & 0xFF
        mem[ZP_LINE_YL] = yl & 0xFF
        mem[ZP_LINE_XR] = xr & 0xFF
        mem[ZP_LINE_YR] = yr & 0xFF
        mem[zp_line_xl_h] = (xl >> 8) & 0xFF
        mem[zp_line_yl_h] = (yl >> 8) & 0xFF
        mem[zp_line_xr_h] = (xr >> 8) & 0xFF
        mem[zp_line_yr_h] = (yr >> 8) & 0xFF
        self._run(self.ENTRY_FUSED_ABOVE if side == 'top' else self.ENTRY_FUSED_BELOW)
        lines = self.last_lines
        if self.capture is not None:
            self.capture.extend(lines)
        return lines

    def fused_touched(self):
        return self.mpu.memory[FW_TOUCH] != 0

    def fused_finish(self, lo, hi, yt1, yt2, yb1, yb2):
        """Seg-end: touched -> the merge pass over [lo, hi); untouched
        -> the zero-touch dispatch (seg_zero_rec_solid semantics: an
        aperture wholly off-screen closes its columns)."""
        mem = self.mpu.memory
        ilo = max(0, lo)
        ihi = min(255, hi)
        if ihi < ilo:
            return
        if mem[FW_TOUCH]:
            mem[ZP_ILO] = ilo & 0xFF
            mem[ZP_IHI] = ihi & 0xFF
            self._run(self.ENTRY_FUSED_MERGE)
            return
        if ((yb1 < 48 and yb2 < 48) or
                (yt1 > 48 + 159 and yt2 > 48 + 159)):
            self.mark_solid(ilo, ihi)

    _reset_count = [0]
    def reset_records(self):
        """(records are gone — kept as a no-op for old callers)"""
        pass

    def _read_span_at_slot(self, slot):
        """Read a single span from pool by slot number."""
        mem = self.mpu.memory
        xlo = mem[POOL_TXLO + slot]
        den = mem[POOL_TDEN + slot]
        return (mem[POOL_XSTART + slot], mem[POOL_XEND + slot],
                xlo, (xlo + den) & 0xFF,
                mem[POOL_TL + slot], mem[POOL_BL + slot],
                mem[POOL_TR + slot], mem[POOL_BR + slot])

    def _set_spans(self, spans):
        """Write spans list to 6502 pool, replacing current state.
        Spans must be in xstart order, non-overlapping. Up to 31 spans."""
        mem = self.mpu.memory
        n = len(spans)
        if n > 31:
            raise RuntimeError(f"too many spans for pool ({n} > 31)")
        for i, s in enumerate(spans):
            slot = i + 1
            xstart, xend, xlo, xhi, tl, bl, tr, br = s
            mem[POOL_XSTART + slot] = xstart & 0xFF
            mem[POOL_XEND + slot] = xend & 0xFF
            mem[POOL_TXLO + slot] = xlo & 0xFF
            mem[POOL_TDEN + slot] = (xhi - xlo) & 0xFF
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
        # A-hi ABI (2026-07-26): hi rides in A, lo in zp_i_l; zp_i_h is
        # untouched. C-only return (same day): the verdict is the carry
        # bit — A comes back holding ihi, not a 0/1.
        mem[ZP_ILO] = ilo & 0xFF
        self.mpu.a = ihi & 0xFF
        self._run(self.ENTRY_HAS_GAP)
        return (self.mpu.p & 0x01) != 0

    def is_full(self):
        """is_full() → bool. (span_is_full retired 2026-07-26: the truth
        is zp_head == 0; the walk inlines SPAN_IS_NOT_FULL.)"""
        return self.mpu.memory[ZP_HEAD] == 0

    def read_spans(self):
        """Read span list. Returns list of 8-tuples in the new format:
        (xstart, xend, xlo, xhi, tl, bl, tr, br)
        where (xlo, xhi, tl, bl, tr, br) is the line definition (immutable
        once a span is created) and (xstart, xend) is the active range.

        span_read RETIRED 2026-07-26: this walks zp_head/POOL_* directly
        (the 6502 serializer only existed to marshal this exact walk
        through a buffer). xhi is reconstructed as (xlo + den) & 0xFF —
        the pool stores DEN, not XHI — matching the old CLC/ADC exactly.
        """
        mem = self.mpu.memory
        spans = []
        slot = mem[ZP_HEAD]
        for _ in range(64):                 # 31 spans max; a longer chase
            if slot == 0:                   # means pool corruption
                return spans
            xlo = mem[POOL_TXLO + slot]
            spans.append((mem[POOL_XSTART + slot], mem[POOL_XEND + slot],
                          xlo, (xlo + mem[POOL_TDEN + slot]) & 0xFF,
                          mem[POOL_TL + slot], mem[POOL_BL + slot],
                          mem[POOL_TR + slot], mem[POOL_BR + slot]))
            slot = mem[POOL_NEXT + slot]
        raise RuntimeError('read_spans: NEXT chain exceeds pool size')

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
        Note: Phase A's clr_skip uses BCC zp_i_h → BCC + BEQ skip, so it
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

    def draw_clipped_line(self, xl, yl, xr, yr):
        """Clip a single s16 line against the span list and emit visible segments.

        Inputs are s16 (raw BSP/transform values, can be negative or > 255).
        The 6502 ENTRY_DRAW_CLIP_S16 entry checks if the line is already in
        u8 range; if so it tail-calls DCL directly (the wrapper has already
        written zp_line_xl_l/yl/xr/yr). Out-of-range lines hit the slow
        clipping path. Returns list of emitted (x1, y1, x2, y2) segments.
        """
        mem = self.mpu.memory
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
        mem[zp_line_xl_h] = (xl >> 8) & 0xFF
        mem[zp_line_yl_h] = (yl >> 8) & 0xFF
        mem[zp_line_xr_h] = (xr >> 8) & 0xFF
        mem[zp_line_yr_h] = (yr >> 8) & 0xFF
        self._run(self.ENTRY_DRAW_CLIP_S16)
        lines = self.last_lines
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
        self._run(self.ENTRY_INTERP_ST)
        r = self.mpu.a
        return r if r < 128 else r - 256



# NOTE: the old __main__ self-tests were removed — their expectations
# predated Y_BIAS and reported false failures. The real gates are
# run_regression.py (unit + differential + ground-truth + cycles).
