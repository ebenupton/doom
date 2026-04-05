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
HK_HAS_GAP          = 0xFE02  # spans_has_gap
HK_IS_FULL          = 0xFE04  # spans_is_full
HK_QUEUE_SOLID      = 0xFE06  # queue a deferred mark_solid
HK_QUEUE_TIGHTEN    = 0xFE08  # queue a deferred tighten (9 args)
HK_FLUSH            = 0xFE0A  # flush deferred queue into span state
HK_BBOX_CULL        = 0xFE0C  # project node bbox and test has_gap

# Span state lives in 6502 RAM at this address.  Choose a region that
# doesn't collide with existing allocations: cmd_buffer ($0300..$0EFF),
# deferred_stk ($0B00..$0BFF), vcache ($0C00..$1BFF) already used —
# put spans at $1C80 (after vcache_valid which is 64 bytes at $1C00).
SPANS_BASE = 0x1C80


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
        self.deferred = []  # list of deferred ops
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
        """spans_init: reset span array to one full-screen span + clear deferred."""
        from fp import FP_RENDER_W, FP_RENDER_H
        spans_init_full(self.mem, SPANS_BASE, FP_RENDER_W, FP_RENDER_H - 1)
        # xhi=FP_RENDER_W=256 stored as 0 (wrap)
        self.mem[SPANS_BASE + SPAN_HDR + 1] = FP_RENDER_W & 0xFF
        self.deferred.clear()

    def has_gap(self, mpu):
        """spans_has_gap: read lo/hi from $A0/$A2, set carry iff gap."""
        lo = _rs16(self.mem, ZP_LO)
        hi = _rs16(self.mem, ZP_HI)
        clips = self._get_clips()
        _set_carry(mpu, clips.has_gap(lo, hi))

    def is_full(self, mpu):
        """spans_is_full: set carry iff no spans remain (fully occluded)."""
        clips = self._get_clips()
        _set_carry(mpu, clips.is_full())

    def queue_solid(self, mpu):
        """Queue a deferred mark_solid. Args: $A0=lo, $A2=hi."""
        lo = _rs16(self.mem, ZP_LO)
        hi = _rs16(self.mem, ZP_HI)
        self.deferred.append(('solid', lo, hi))

    def queue_tighten(self, mpu):
        """Queue a deferred tighten.  Compute yt/yb from raw ft/fb/bt/bb
        here so the 6502 side only has to marshal the raw values."""
        lo = _rs16(self.mem, ZP_LO)
        hi = _rs16(self.mem, ZP_HI)
        sx1 = _rs16(self.mem, ZP_SX1)
        sx2 = _rs16(self.mem, ZP_SX2)
        ft1 = _rs16(self.mem, ZP_FT1)
        ft2 = _rs16(self.mem, ZP_FT2)
        fb1 = _rs16(self.mem, ZP_FB1)
        fb2 = _rs16(self.mem, ZP_FB2)
        need_bt = bool(self.mem[ZP_NEED_BT])
        need_bb = bool(self.mem[ZP_NEED_BB])
        bt1 = _rs16(self.mem, ZP_BT1)
        bt2 = _rs16(self.mem, ZP_BT2)
        bb1 = _rs16(self.mem, ZP_BB1)
        bb2 = _rs16(self.mem, ZP_BB2)

        # Mirror Python FP's tighten-arg derivation:
        #   tt1 = bt1 if need_bt else ft1;  yt1 = max(ft1, tt1)
        #   tb1 = bb1 if need_bb else fb1;  yb1 = min(fb1, tb1)
        tt1 = bt1 if need_bt else ft1
        tt2 = bt2 if need_bt else ft2
        tb1 = bb1 if need_bb else fb1
        tb2 = bb2 if need_bb else fb2
        yt1, yt2 = max(ft1, tt1), max(ft2, tt2)
        yb1, yb2 = min(fb1, tb1), min(fb2, tb2)

        # line_survives has to be evaluated on the CURRENT state (before
        # the tighten itself is applied) to match Python FP exactly.
        clips = self._get_clips()
        top_dom = need_bt and clips.line_survives(sx1, bt1, sx2, bt2)
        bot_dom = need_bb and clips.line_survives(sx1, bb1, sx2, bb2)

        self.deferred.append(
            ('tighten', lo, hi, sx1, sx2, yt1, yt2, yb1, yb2, top_dom, bot_dom))

    def bbox_cull(self, mpu):
        """spans_bbox_cull: project a node's far-side bbox and test has_gap.
        Input: $A0 = node index (u16), $A2 = far_side (u8 0/1).
        Reads player position/angle from standard ZP ($10-$13, $15).
        Returns carry = visible.
        """
        import math
        from doom_wireframe import nodes, fp_bbox_visible, byte_to_radians
        # Read node index from hook args
        nid = self.mem[ZP_LO] | (self.mem[ZP_LO + 1] << 8)
        far_side = self.mem[ZP_SX1]  # reusing ZP_SX1 byte for far side

        # Recompute world-space player position and angle from ZP state
        from fp import PRESCALE, MAP_CENTER_X, MAP_CENTER_Y
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
        # reconstitute raw world coords from prescaled 8.8
        wx_full = (px_88 * PRESCALE) // 256 + MAP_CENTER_X
        wy_full = (py_88 * PRESCALE) // 256 + MAP_CENTER_Y

        angle_byte = self.mem[0x15]
        ang_rad = byte_to_radians(angle_byte)
        cos_f = math.cos(ang_rad)
        sin_f = math.sin(ang_rad)

        node = nodes[nid]
        br = fp_bbox_visible(node, far_side, cos_f, sin_f, wx_full, wy_full)
        if br is None:
            _set_carry(mpu, False)  # not visible
            return
        clips = self._get_clips()
        _set_carry(mpu, clips.has_gap(br[0], br[1]))

    def flush(self, mpu):
        """Apply all queued operations to the span state, in order."""
        if not self.deferred:
            return
        clips = self._get_clips()
        for op in self.deferred:
            if op[0] == 'solid':
                clips.mark_solid(op[1], op[2])
            else:
                # tighten(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2, top_dom, bot_dom)
                clips.tighten(*op[1:])
            if clips.is_full():
                break
        self.deferred.clear()
        self._flush_clips(clips)


def install_hooks(mpu, mem):
    """Return (state, hook_table) where hook_table maps PC → callable."""
    state = SpanState(mem)
    table = {
        HK_INIT:          state.init,
        HK_HAS_GAP:       state.has_gap,
        HK_IS_FULL:       state.is_full,
        HK_QUEUE_SOLID:   state.queue_solid,
        HK_QUEUE_TIGHTEN: state.queue_tighten,
        HK_FLUSH:         state.flush,
        HK_BBOX_CULL:     state.bbox_cull,
    }
    return state, table
