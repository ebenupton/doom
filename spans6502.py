"""Visibility-span hooks for the 6502 front-end.

The 6502 front-end uses the same visibility algorithm as the Python FP
renderer (`FPClipSpans`) by calling out to Python at known hook addresses
in its memory map.  When py65 steps to one of these addresses, fe6502.py
dispatches to the corresponding Python handler here, which operates on
the span byte array living inside the 6502's memory at SPANS_BASE.

The span byte format is identical to `wad_packed.SPAN_*` — a 2-byte
header (count + pad) followed by up to MAX_SPANS × 16-byte records.
This lets us use `wad_packed.read_all_spans` / `write_all_spans` and
Python `FPClipSpans` directly, sharing exactly the same code path.

Hook calling convention:
  6502 code JSRs to a hook address (HOOK_BASE + n * 2).
  fe6502.py intercepts the PC before stepping, reads arguments from
  zero-page slots $A0..$BF, runs the Python handler on `mpu.memory`
  with the span base offset, writes the carry flag result (when
  applicable) into `mpu.p`, and manually performs an RTS.

Zero-page argument layout for tighten (all little-endian s16 unless noted):
  $A0-$A1  x_lo
  $A2-$A3  x_hi
  $A4-$A5  sx1
  $A6-$A7  sx2
  $A8-$A9  ft1
  $AA-$AB  ft2
  $AC-$AD  fb1
  $AE-$AF  fb2
  $B0      need_bt (u8, 0/non-zero)
  $B1      need_bb (u8, 0/non-zero)
  $B2-$B3  bt1
  $B4-$B5  bt2
  $B6-$B7  bb1
  $B8-$B9  bb2
"""
from wad_packed import (SPAN_HDR, SPAN_SIZE, MAX_SPANS, SPAN_TOTAL,
                        spans_init_full, read_all_spans, write_all_spans,
                        read_s16, write_s16)

# Hook addresses (in unused high memory — never executed as real 6502 code)
HOOK_BASE           = 0xFE00
HK_INIT             = 0xFE00  # spans_init
HK_FLUSH            = 0xFE0A  # flush deferred queue into span state
HK_BBOX_CULL        = 0xFE0C  # project node bbox and test has_gap
HK_ENTER_SS         = 0xFE0E  # diagnostic: note which subsector we entered

# 6502-side deferred span-op queue (populated natively by queue_solid /
# queue_tighten in doom_fe.asm).  The Python flush hook reads entries
# from this queue and applies them to the span state.
QUEUE_COUNT_ADDR = 0x22D2
QUEUE_BASE       = 0x22E0
QE_SIZE          = 20
QE_TYPE          = 0
QE_TOP_DOM       = 1
QE_BOT_DOM       = 2
QE_LO            = 4
QE_HI            = 6
QE_SX1           = 8
QE_SX2           = 10
QE_YT1           = 12
QE_YT2           = 14
QE_YB1           = 16
QE_YB2           = 18
QET_SOLID        = 0
QET_TIGHTEN      = 1

# Span state lives in 6502 RAM at this address.
SPANS_BASE = 0x20D0


# Zero-page argument slots
ZP_LO   = 0xA0  # s16
ZP_HI   = 0xA2  # s16
ZP_SX1  = 0xA4  # s16
ZP_SX2  = 0xA6  # s16
ZP_FT1  = 0xA8  # s16
ZP_FT2  = 0xAA  # s16
ZP_FB1  = 0xAC  # s16
ZP_FB2  = 0xAE  # s16
ZP_NEED_BT = 0xB0  # u8
ZP_NEED_BB = 0xB1  # u8
ZP_BT1  = 0xB2  # s16
ZP_BT2  = 0xB4  # s16
ZP_BB1  = 0xB6  # s16
ZP_BB2  = 0xB8  # s16


def _rs16(mem, addr):
    v = mem[addr] | (mem[addr + 1] << 8)
    return v - 65536 if v >= 32768 else v


def _do_rts(mpu):
    """Pop return address from stack and set PC (simulates RTS)."""
    sp = mpu.sp
    lo = mpu.memory[0x100 + ((sp + 1) & 0xFF)]
    hi = mpu.memory[0x100 + ((sp + 2) & 0xFF)]
    mpu.sp = (sp + 2) & 0xFF
    mpu.pc = (((hi << 8) | lo) + 1) & 0xFFFF


def _set_carry(mpu, val):
    if val:
        mpu.p |= 0x01
    else:
        mpu.p &= ~0x01


class SpanState:
    """Persistent span state for one render frame — shared across all
    hook calls.  Holds a Python-side deferred queue that mirrors the
    subsector-bounded deferral Python FP does."""

    def __init__(self, mem):
        self.mem = mem  # reference to mpu.memory (bytearray-like)
        self._clips = None  # lazily constructed FPClipSpans view

    def _get_clips(self):
        """Return a PackedClipSpans-like object that reads/writes SPANS_BASE."""
        # Re-read spans from RAM into a Python FPClipSpans instance, then
        # mutate and write back.  Simpler than keeping a persistent object.
        from doom_wireframe import FPClipSpans
        clips = FPClipSpans()
        clips.spans = read_all_spans(self.mem, SPANS_BASE)
        return clips

    def _flush_clips(self, clips):
        write_all_spans(self.mem, SPANS_BASE, clips.spans)

    # ── Hook handlers ──────────────────────────────────────────────────

    def init(self, mpu):
        """spans_init: reset span array to one full-screen span.
        The 6502-side queue is cleared by the asm entry point."""
        from fp import FP_RENDER_W, FP_RENDER_H
        spans_init_full(self.mem, SPANS_BASE, FP_RENDER_W, FP_RENDER_H - 1)
        # xhi=FP_RENDER_W=256 stored as 0 (wrap)
        self.mem[SPANS_BASE + SPAN_HDR + 1] = FP_RENDER_W & 0xFF

    def enter_ss(self, mpu):
        """Diagnostic hook: note which subsector is being entered.
        Arg: $A0-$A1 = ssid (u16)."""
        ssid = self.mem[ZP_LO] | (self.mem[ZP_LO + 1] << 8)
        # Append to a history list for diagnostic scripts to inspect.
        if not hasattr(self, 'ss_history'):
            self.ss_history = []
        self.ss_history.append(ssid)

    def bbox_cull(self, mpu):
        """spans_bbox_cull: project a node's far-side bbox and test has_gap.
        Input: $A0 = node index (u16), $A4 = far_side (u8 0/1).
        Reads player position/angle from standard ZP.
        Returns carry = visible.
        """
        from doom_wireframe import nodes, fp_bbox_visible_fixed
        from fp import fp_sincos, fp_view_context
        # Read node index from hook args
        nid = self.mem[ZP_LO] | (self.mem[ZP_LO + 1] << 8)
        far_side = self.mem[ZP_SX1]  # reusing ZP_SX1 byte for far side

        # Reconstruct prescaled 8.8 player position and sincos context from ZP.
        px_int = self.mem[0x10]
        if px_int >= 128: px_int -= 256
        py_int = self.mem[0x11]
        if py_int >= 128: py_int -= 256
        px_lo = self.mem[0x12]
        py_lo = self.mem[0x13]
        px_88 = (px_int << 8) | px_lo
        if px_88 >= 32768: px_88 -= 65536
        py_88 = (py_int << 8) | py_lo
        if py_88 >= 32768: py_88 -= 65536

        angle_byte = self.mem[0x15]
        sc = fp_sincos(angle_byte)
        ctx = fp_view_context(px_88, py_88, sc)

        node = nodes[nid]
        br = fp_bbox_visible_fixed(node, far_side, ctx)
        if br is None:
            _set_carry(mpu, False)  # not visible
            return
        clips = self._get_clips()
        _set_carry(mpu, clips.has_gap(br[0], br[1]))

    def flush(self, mpu):
        """Apply the 6502-side deferred queue (populated by native
        queue_solid / queue_tighten) to the span state, in order.
        Also clears the queue count and resets the tail pointer."""
        count = self.mem[QUEUE_COUNT_ADDR]
        if count == 0:
            return
        clips = self._get_clips()
        for i in range(count):
            eb = QUEUE_BASE + i * QE_SIZE
            qtype = self.mem[eb + QE_TYPE]
            lo = _rs16(self.mem, eb + QE_LO)
            hi = _rs16(self.mem, eb + QE_HI)
            if qtype == QET_SOLID:
                clips.mark_solid(lo, hi)
            else:
                sx1 = _rs16(self.mem, eb + QE_SX1)
                sx2 = _rs16(self.mem, eb + QE_SX2)
                yt1 = _rs16(self.mem, eb + QE_YT1)
                yt2 = _rs16(self.mem, eb + QE_YT2)
                yb1 = _rs16(self.mem, eb + QE_YB1)
                yb2 = _rs16(self.mem, eb + QE_YB2)
                top_dom = bool(self.mem[eb + QE_TOP_DOM])
                bot_dom = bool(self.mem[eb + QE_BOT_DOM])
                clips.tighten(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                              top_dom, bot_dom)
            if clips.is_full():
                break
        self._flush_clips(clips)
        # Reset the 6502-side queue
        self.mem[QUEUE_COUNT_ADDR] = 0
        self.mem[0xD1] = QUEUE_BASE & 0xFF
        self.mem[0xD2] = (QUEUE_BASE >> 8) & 0xFF


def install_hooks(mpu, mem):
    """Return (state, hook_table) where hook_table maps PC → callable."""
    state = SpanState(mem)
    table = {
        HK_INIT:          state.init,
        HK_FLUSH:         state.flush,
        HK_BBOX_CULL:     state.bbox_cull,
        HK_ENTER_SS:      state.enter_ss,
    }
    return state, table
