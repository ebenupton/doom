"""Integer-endpoint flat-span visibility for the DOOM wireframe renderer.

Each span is an 8-tuple (xstart, xend, xlo, xhi, tl, bl, tr, br):
- (xstart, xend) is the ACTIVE column range (closed; both inclusive). This
  is what mark_solid / tighten narrow, what has_gap / draw_clipped use to
  decide which columns belong to the span.
- (xlo, xhi, tl, bl, tr, br) is the LINE definition: anchor x's plus the
  top/bot y values at those anchors. The line is fixed once a span is
  created and is used to interpolate y at any column in [xstart, xend].
  xlo/xhi need NOT equal xstart/xend — when a span is narrowed by
  mark_solid or by tighten's left/right fragment paths, the line params
  are preserved verbatim and only xstart/xend move. This avoids the
  interp_store calls that the old (dense-anchored) representation needed
  at every split.

All values are integer pixels: X in [0,255] (closed interval), Y in [0,159].
6502-friendly: all span arithmetic is 8-bit.  Boundary interpolation
is u8*s8/u8 (one 8x8 multiply + one 8-bit division).
"""

import random
import pygame
from fp import FP_RENDER_W, FP_RENDER_H

Y_BIAS = 48  # bias Y so visible [0,159] maps to [48,207] within u8


def _rand_color():
    return (random.randint(60, 255), random.randint(60, 255), random.randint(60, 255))


def _interp(x, x0, y0, x1, y1):
    """Interpolate pixel Y values at integer X. Floor division.
    On 6502: s8 * u8 / u8.  When denominator is 256 (full-screen span),
    the division is just a right-shift by 8 (take high byte of multiply).
    Otherwise use restoring division loop (8 iterations, ~80 cycles).
    A 256-byte reciprocal table is NOT used — direct division gives
    better precision for the same cycle cost."""
    if x1 == x0:
        return y0
    return y0 + (y1 - y0) * (x - x0) // (x1 - x0)


def _interp_ceil(x, x0, y0, x1, y1):
    """Interpolate pixel Y, rounding UP (ceiling).  Used for TOP boundary
    evaluation so lines never start above the true boundary.
    On 6502: negate-interp-negate, or floor + conditional +1."""
    if x1 == x0:
        return y0
    num = (y1 - y0) * (x - x0)
    den = x1 - x0
    q = num // den
    if q * den != num:
        q += 1  # ceiling: always round toward +inf when there's a remainder
    return y0 + q


def _interp_store(x, x0, y0, x1, y1):
    """Interpolate Y: direction-split unsigned formula.
    Matches the 6502's interp_store which always computes with |dy|
    and adds/subtracts the quotient. Used for u8 span boundaries
    and u8 line-Y evaluation."""
    if x1 == x0:
        return y0
    offset = x - x0
    den = x1 - x0
    if den < 0:
        offset, den = -offset, -den
    if y1 >= y0:
        dy = y1 - y0
        return y0 + (offset * dy + den // 2) // den
    else:
        dy = y0 - y1
        return y0 - (offset * dy + den // 2) // den


def _interp_store_s16(x, x0, y0, x1, y1):
    """Interpolate Y for s16 seg values, rounding half AWAY FROM ZERO to match
    the 6502 s16_interp exactly (it computes with |offset|,|den|,|dy| and
    adds/subtracts the +den//2-rounded quotient).

    The previous form used signed-floor with a +den//2 bias, which rounds half
    toward +inf -- diverging from the 6502 by 1px on DESCENDING lines (dy<0) at
    exact half-points (even den). That 1px error cascaded through occlusion:
    a span boundary off by one flips a has_gap result, leaking whole walls
    (e.g. the wall at player 1056,-3328 byte-angle 14). The 6502 binary is the
    shipping target, so the Python reference is aligned to it here. Verified
    0/8000 mismatches vs the emulated s16_interp over wide and narrow inputs.
    Note _interp_store (u8 spans) already rounds away-from-zero this way."""
    if x1 == x0:
        return y0
    offset = x - x0
    den = x1 - x0
    if den < 0:
        offset, den = -offset, -den
    if y1 >= y0:
        dy = y1 - y0
        return y0 + (offset * dy + den // 2) // den
    dy = y0 - y1
    return y0 - (offset * dy + den // 2) // den


def _remap_seg_for_8bit(ilo, ihi, sx1, sx2, yt1, yt2, yb1, yb2,
                        clamp_u8=True):
    """Remap seg parameters so the 6502 8-bit interp pipeline works.

    Constraints (X-only — Y constraint removed with unsigned interp):
      - ex = sx2 - sx1 ≤ 255 (fits u8)
      - offset = eval_x - sx1 ∈ [0, 255] for all eval_x ∈ [ilo, ihi]

    When orig_ex > 255 or the seg doesn't cover [ilo, ihi], resample the
    seg at closer anchor points.

    clamp_u8: when True (default, 6502 pipeline), clamp remapped yt/yb
    to [0, 255] and require that range for the fast path.  When False
    (Python reference with unbiased coordinates), skip the u8 clamp so
    negative "above-screen" y values survive, preserving the sign info
    that tighten's crossover detection relies on.
    """
    orig_ex = sx2 - sx1
    if orig_ex == 0:
        return sx1, sx1 + 1, yt1, yt2, yb1, yb2
    max_dy = max(abs(yt2 - yt1), abs(yb2 - yb1))
    # Early return when original parameters already satisfy all constraints.
    # The Y range check is only required when we'll clamp the output.
    y_ok = (not clamp_u8) or (
        0 <= yt1 <= 255 and 0 <= yt2 <= 255 and
        0 <= yb1 <= 255 and 0 <= yb2 <= 255)
    if (sx1 <= ilo and sx1 + 255 >= ihi and
            orig_ex <= 255 and max_dy <= 127 and y_ok):
        return sx1, sx2, yt1, yt2, yb1, yb2
    # Compute new_ex: fit both X offset and |dy| constraints
    if max_dy >= 1:
        new_ex = min(255, (126 * orig_ex) // max_dy)
    else:
        new_ex = min(255, orig_ex)
    new_ex = max(1, new_ex)
    x_lo = ilo
    x_hi = x_lo + new_ex
    nyt1 = _interp_store_s16(x_lo, sx1, yt1, sx2, yt2)
    nyt2 = _interp_store_s16(x_hi, sx1, yt1, sx2, yt2)
    nyb1 = _interp_store_s16(x_lo, sx1, yb1, sx2, yb2)
    nyb2 = _interp_store_s16(x_hi, sx1, yb1, sx2, yb2)
    if clamp_u8:
        # Clamp to u8 [0,255] for the 6502 pipeline.  The slope is
        # correct because we interpolated from the original (un-clamped)
        # seg values; we only clamp the resampled anchor Y values here.
        nyt1 = max(0, min(255, nyt1))
        nyt2 = max(0, min(255, nyt2))
        nyb1 = max(0, min(255, nyb1))
        nyb2 = max(0, min(255, nyb2))
    return x_lo, x_hi, nyt1, nyt2, nyb1, nyb2


def _compute_tighten_splits(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2):
    """Split a tighten call if the remap can't cover [ilo, ihi].

    Returns a list of (lo, hi, sx1, sx2, yt1, yt2, yb1, yb2) tuples.
    Usually one element; two when the seg is too steep for the full range.
    """
    ilo = max(0, lo)
    ihi = min(255, hi)
    if ihi < ilo:
        return [(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2)]
    s1, s2, t1, t2, b1, b2 = sx1, sx2, yt1, yt2, yb1, yb2
    if s1 > s2:
        s1, s2 = s2, s1
        t1, t2 = t2, t1
        b1, b2 = b2, b1
    r = _remap_seg_for_8bit(ilo, ihi, s1, s2, t1, t2, b1, b2)
    if r[1] < ihi:
        return [
            (lo, r[1], sx1, sx2, yt1, yt2, yb1, yb2),
            (r[1] + 1, hi, r[1], r[1] + 1, r[3], r[3], r[5], r[5]),
        ]
    return [(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2)]


# Cost tracking for debug mode
_line_cost = None

# Drawn-line collector: when enabled, every pygame.draw.line from draw_clipped
# appends (idx, x1, y1, x2, y2) so an overlay can label them.
_drawn_lines = None  # set to [] to enable collection

# Partial-aperture detector. A "partial aperture" span is one where top<bot
# at one endpoint but top>=bot at the other — i.e., the linear top/bot pair
# crosses inside the span and aperture only exists in part of the [xlo, xhi]
# range. The has_gap test would have to do real per-column work for these.
# Set _partial_aperture_check_enabled = True from the test harness to print.
_partial_aperture_check_enabled = False
_partial_aperture_count = 0

# Toggle: which implementation EndpointClipSpans.tighten dispatches to.
#   'normal'  — current per-span tighten (default).
#   'unified' — unified_clip_tighten (single-walk; state-equivalent).
#   'records' — clip_line_records + tighten_from_records (records-driven;
#               proof-of-concept that DCL's per-span clip output drives
#               tighten via sub-range records, no per-span interp in
#               tighten itself).
# All three modes produce identical span state — verified by
# test_unified_tighten.py against the 9 reference scenes.
_TIGHTEN_MODE = 'normal'

# Legacy boolean flag — retained as alias for back-compat. Set True ⇒
# 'unified' mode. Read at tighten dispatch time, not import time.
_USE_UNIFIED_TIGHTEN = False

# Tighten instrumentation: counts dispositions per overlapping span.
# Used to bound achievable savings of asymmetric top/bot anchor optimisation.
TIGHTEN_STATS = {
    'tighten_calls': 0,
    'spans_visited': 0,
    'no_overlap': 0,
    'full_dom': 0,         # span unchanged (clamped seg between old top/bot)
    'no_cx_both_win': 0,   # both sides unchanged after clamp
    'no_cx_top_only': 0,   # only top side narrowed (bot unchanged) ← asymmetric saves here
    'no_cx_bot_only': 0,   # only bot side narrowed (top unchanged) ← asymmetric saves here
    'no_cx_both_narrow': 0,# both sides narrowed (asymmetric doesn't help)
    'no_cx_killed': 0,     # span killed (rt >= rb after clamp)
    'crossover': 0,        # has_top_cx or has_bot_cx
    'old_fast_path': 0,    # ox0 == s[xlo] and ox1 == s[xhi] — old corners reused
    'old_interp_path': 0,  # old corners need 4 interp_stores
    'new_fast_path': 0,    # ox0 == sx1 and ox1 == sx2 — new corners are seg endpoints
    'new_interp_path': 0,  # new corners need 4 interp_stores from seg line
    # Pre-check fires (sufficient, not necessary): seg_top_max <= OT_span ⇒ top wins.
    # If we add this check + asymmetric anchors, we skip top-side OLD+NEW interps
    # for these spans (4 saved per fire when not also full-dom).
    'pre_top_dom': 0,
    'pre_bot_dom': 0,
    # Spans where pre-check would save interps (top-only narrow → save top, etc.)
    'pre_save_top4': 0,    # pre_top_dom AND ends up no_cx_bot_only → save 4 top interps
    'pre_save_bot4': 0,    # pre_bot_dom AND ends up no_cx_top_only → save 4 bot interps
}


def _check_partial_aperture(span, source):
    # Disabled by default; preserved as a debugging hook for future work.
    if not _partial_aperture_check_enabled:
        return
    xstart, xend, xlo, xhi, tl, bl, tr, br = span
    # Check aperture at the line endpoints (where the y values are stored).
    aper_l = tl < bl
    aper_r = tr < br
    if aper_l != aper_r:
        global _partial_aperture_count
        _partial_aperture_count += 1
        if _partial_aperture_count <= 10:
            print(f'PARTIAL APERTURE from {source}: {span}')


# Span field accessors / helpers --------------------------------------------
def _span_top(s, x):
    """Top y at column x using the span's line."""
    return _interp(x, s[2], s[4], s[3], s[6])

def _span_bot(s, x):
    """Bot y at column x using the span's line."""
    return _interp(x, s[2], s[5], s[3], s[7])

def _span_top_ceil(s, x):
    return _interp_ceil(x, s[2], s[4], s[3], s[6])

def _span_top_store(s, x):
    """Top y at column x using the span's line, round-to-nearest."""
    return _interp_store(x, s[2], s[4], s[3], s[6])

def _span_bot_store(s, x):
    return _interp_store(x, s[2], s[5], s[3], s[7])


def _append_merge(new, span):
    """Append span to `new`, merging with the tail when both are constant
    lines (tl==tr, bl==br) with matching (tl, bl) and contiguous active
    ranges. Matches the 6502 `tg_append_x` merge fast path.

    Non-constant co-linear pairs (same line stored with different anchors,
    but dy != 0) are rare (~6/568 in scene 2) and not handled here — the
    cost of a general co-linear check would eat the savings.
    """
    if new:
        tail = new[-1]
        if (tail[4] == tail[6] and tail[5] == tail[7] and
                span[4] == span[6] and span[5] == span[7] and
                tail[4] == span[4] and tail[5] == span[5] and
                tail[1] == span[0]):
            new[-1] = (tail[0], span[1],
                       tail[2], tail[3], tail[4], tail[5], tail[6], tail[7])
            return
    new.append(span)


class EndpointClipSpans:
    """Visibility spans with integer pixel Y boundaries.

    self.spans: list of 8-tuples (xstart, xend, xlo, xhi, tl, bl, tr, br).
    Both xstart/xend and the line endpoints xlo/xhi are needed because
    the active range can be a strict subset of the line range (after
    mark_solid splits or tighten's lazy left/right fragment paths).
    """

    __slots__ = ("spans", "bbox", "y_display_offset")

    def __init__(self):
        # Initial full-screen span: un-biased Y [0, 159].
        s = (0, FP_RENDER_W - 1,                   # xstart, xend
             0, FP_RENDER_W - 1,                   # xlo, xhi (line anchors)
             0, FP_RENDER_H - 1,                   # tl, bl
             0, FP_RENDER_H - 1)                   # tr, br
        self.spans = [s]
        self.y_display_offset = 0
        self._update_bbox()

    def _update_bbox(self):
        if not self.spans:
            self.bbox = None
            return
        x_min = self.spans[0][0]
        x_max = self.spans[-1][1]
        # Conservative y bbox using line endpoint y values (the actual span
        # y values within the active range are bounded by these).
        yt_min = min(min(s[4], s[6]) for s in self.spans)
        yb_max = max(max(s[5], s[7]) for s in self.spans)
        self.bbox = (x_min, x_max, yt_min, yb_max)

    # -- Queries ---------------------------------------------------------------

    def is_full(self):
        return not self.spans

    def has_gap(self, lo, hi):
        # Trivial overlap test — every span in the active list is treated
        # as having aperture (matching the cheapened 6502 has_gap).
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W - 1, hi)
        if ihi < ilo: return False
        for s in self.spans:
            if s[0] > ihi: break
            if s[1] < ilo: continue
            return True
        return False

    def line_survives(self, lx1, ly1, lx2, ly2):
        if abs(lx1 - lx2) < 1:
            return False
        xl, xr = min(lx1, lx2), max(lx1, lx2)
        y_lo = min(ly1, ly2)
        y_hi = max(ly1, ly2)
        found = False
        for s in self.spans:
            if s[1] <= xl or s[0] >= xr: continue  # pixel-center overlap
            found = True
            # Aperture at the active range endpoints (interp from line).
            ts = _span_top(s, s[0]); te = _span_top(s, s[1])
            bs = _span_bot(s, s[0]); be = _span_bot(s, s[1])
            it = max(ts, te)
            ib = min(bs, be)
            if y_lo < it or y_hi > ib:
                return False
        return found

    def line_above_spans(self, lx1, ly1, lx2, ly2, _dbg=False):
        """True iff the line is above span_top at every overlapping
        span column.  Used to skip portal need_bt emission when the
        back-ceiling horizontal lies entirely above the visible
        aperture: the step verticals (which extend even further up)
        are also above-clipped, so we can drop the whole need_bt
        block (horizontal + 2 step verts + optional front-ceil line).

        Conservative: returns True only when the line endpoints fall
        strictly above each overlapping span's max top-y.  No partial
        coverage / mixed-span handling.
        """
        if lx1 == lx2:
            return False
        xl, xr = min(lx1, lx2), max(lx1, lx2)
        # Slope-form line: y at x = ly1 + (x-lx1)*(ly2-ly1)/(lx2-lx1)
        dx = lx2 - lx1
        dy = ly2 - ly1
        found = False
        for s in self.spans:
            if s[1] <= xl or s[0] >= xr: continue
            found = True
            ox0 = max(s[0], xl); ox1 = min(s[1], xr)
            ly_l = ly1 + (ox0 - lx1) * dy // dx
            ly_r = ly1 + (ox1 - lx1) * dy // dx
            ts_l = _span_top(s, ox0); ts_r = _span_top(s, ox1)
            if _dbg:
                print(f"   span {s[:4]} top {s[4],s[6]}  ox=[{ox0},{ox1}] "
                      f"ly_l={ly_l} ly_r={ly_r} ts_l={ts_l} ts_r={ts_r}")
            # max-of-line-y at the overlap < min-of-span-top in the overlap
            if max(ly_l, ly_r) >= min(ts_l, ts_r):
                return False
        return found

    def vertical_outside_spans(self, sx, y_lo, y_hi):
        """True iff the vertical line at column sx with y range
        [y_lo, y_hi] is entirely outside the visible aperture: either
        no span covers column sx, the span at sx has no aperture, or
        [y_lo, y_hi] sits entirely above span_top(sx) / below
        span_bot(sx).  When True, the call to draw_clipped on this
        vertical can be skipped — it would clip to nothing anyway,
        saving the dispatch / span walk."""
        for s in self.spans:
            if not (s[0] <= sx <= s[1]):
                continue
            top_y = _span_top(s, sx)
            bot_y = _span_bot(s, sx)
            if top_y >= bot_y:
                return True  # degenerate aperture at this column
            return y_hi < top_y or y_lo > bot_y
        return True  # no span covers sx

    def line_below_spans(self, lx1, ly1, lx2, ly2):
        """Symmetric to line_above_spans for the bottom.  Used to skip
        portal need_bb emission when the back-floor horizontal lies
        entirely below the visible aperture."""
        if lx1 == lx2:
            return False
        xl, xr = min(lx1, lx2), max(lx1, lx2)
        dx = lx2 - lx1
        dy = ly2 - ly1
        found = False
        for s in self.spans:
            if s[1] <= xl or s[0] >= xr: continue
            found = True
            ox0 = max(s[0], xl); ox1 = min(s[1], xr)
            ly_l = ly1 + (ox0 - lx1) * dy // dx
            ly_r = ly1 + (ox1 - lx1) * dy // dx
            bs_l = _span_bot(s, ox0); bs_r = _span_bot(s, ox1)
            if min(ly_l, ly_r) <= max(bs_l, bs_r):
                return False
        return found

    # -- Mutations -------------------------------------------------------------

    def mark_solid(self, lo, hi, **_kw):
        # LAZY: only updates xstart/xend on existing spans. The line params
        # (xlo, xhi, tl, bl, tr, br) are preserved verbatim across splits —
        # no _interp_store calls happen in this method any more.
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W - 1, hi)
        if ihi < ilo: return
        new = []
        for s in self.spans:
            xs, xe = s[0], s[1]
            if xe < ilo or xs > ihi:
                _append_merge(new, s); continue
            if xs < ilo:
                _append_merge(new, (xs, ilo - 1,
                                    s[2], s[3], s[4], s[5], s[6], s[7]))
            if ihi < xe:
                _append_merge(new, (ihi + 1, xe,
                                    s[2], s[3], s[4], s[5], s[6], s[7]))
        self.spans = new
        self._update_bbox()

    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                top_dom=False, bot_dom=False,
                emit_top=True, emit_bot=True,
                emit_sec_top=False, emit_sec_bot=False,
                yt_sec1=None, yt_sec2=None,
                yb_sec1=None, yb_sec2=None):
        # emit_top/emit_bot/emit_sec_top/emit_sec_bot and yt_sec/yb_sec
        # are consumed by the 6502 shadow — ignored in Python state
        # mutation (Python doesn't emit lines during tighten).
        _ = emit_top, emit_bot, emit_sec_top, emit_sec_bot
        _ = yt_sec1, yt_sec2, yb_sec1, yb_sec2
        # Mode dispatch (legacy boolean still honoured).
        mode = _TIGHTEN_MODE
        if _USE_UNIFIED_TIGHTEN and mode == 'normal':
            mode = 'unified'
        if mode == 'unified':
            return self.unified_clip_tighten(lo, hi, sx1, sx2,
                                             yt1, yt2, yb1, yb2)
        if mode == 'records':
            ilo = max(0, lo); ihi = min(FP_RENDER_W - 1, hi)
            if ihi < ilo: return
            if sx1 > sx2:
                sx1, sx2 = sx2, sx1
                yt1, yt2 = yt2, yt1
                yb1, yb2 = yb2, yb1
            sx1, sx2, yt1, yt2, yb1, yb2 = _remap_seg_for_8bit(
                ilo, ihi, sx1, sx2, yt1, yt2, yb1, yb2,
                clamp_u8=(self.y_display_offset != 0))
            top_records = self.clip_line_records(sx1, yt1, sx2, yt2,
                                                 ilo=ilo, ihi=ihi)
            bot_records = self.clip_line_records(sx1, yb1, sx2, yb2,
                                                 ilo=ilo, ihi=ihi)
            return self.tighten_from_records(
                lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                top_records, bot_records)
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W - 1, hi)
        if ihi < ilo: return
        if sx1 > sx2:
            sx1, sx2 = sx2, sx1
            yt1, yt2 = yt2, yt1
            yb1, yb2 = yb2, yb1
        # 6502 shadow biases (y_display_offset=Y_BIAS) and needs u8 yt/yb.
        # The unbiased Python reference (y_display_offset=0) preserves
        # above-screen negative y values — without this, remap's u8 clamp
        # forces nt_l up to 0, losing the sign info that crossover
        # detection uses to split the span where seg transitions from
        # above-screen to on-screen.
        sx1, sx2, yt1, yt2, yb1, yb2 = _remap_seg_for_8bit(
            ilo, ihi, sx1, sx2, yt1, yt2, yb1, yb2,
            clamp_u8=(self.y_display_offset != 0))
        TIGHTEN_STATS['tighten_calls'] += 1
        new = []
        for s in self.spans:
            TIGHTEN_STATS['spans_visited'] += 1
            xs, xe = s[0], s[1]
            if xe <= ilo or xs >= ihi:  # pixel-center: endpoint-only ≠ overlap
                TIGHTEN_STATS['no_overlap'] += 1
                _append_merge(new, s); continue
            ox0 = max(xs, ilo); ox1 = min(xe, ihi)
            # Pre-check (cheap, no interp): does the seg's bbox prove one-sided
            # dominance? OT_span = min(tl, tr); OB_span = max(bl, br); seg_top_max
            # = max(yt1, yt2); seg_bot_min = min(yb1, yb2). If seg_top_max <=
            # OT_span, the seg top is above old top everywhere on overlap → top
            # wins for sure. Symmetric for bot. With asymmetric anchors, top-wins
            # would let us skip ALL top-side interps.
            ot_span = min(s[4], s[6])
            ob_span = max(s[5], s[7])
            seg_top_max_pre = max(yt1, yt2)
            seg_bot_min_pre = min(yb1, yb2)
            pre_top_dom = (seg_top_max_pre <= ot_span)
            pre_bot_dom = (seg_bot_min_pre >= ob_span)
            if pre_top_dom: TIGHTEN_STATS['pre_top_dom'] += 1
            if pre_bot_dom: TIGHTEN_STATS['pre_bot_dom'] += 1
            # Dominance/crossover prelude
            # Fast path: if the overlap endpoints match the old span's LINE
            # anchors, the stored tl/bl/tr/br *are* the y values at those
            # endpoints — no interp needed.
            if ox0 == s[2] and ox1 == s[3]:
                TIGHTEN_STATS['old_fast_path'] += 1
                old_tl = s[4]; old_bl = s[5]
                old_tr = s[6]; old_br = s[7]
            else:
                TIGHTEN_STATS['old_interp_path'] += 1
                old_tl = _span_top_store(s, ox0)
                old_tr = _span_top_store(s, ox1)
                old_bl = _span_bot_store(s, ox0)
                old_br = _span_bot_store(s, ox1)
            # Same fast path for the seg's line
            if ox0 == sx1 and ox1 == sx2:
                TIGHTEN_STATS['new_fast_path'] += 1
                new_tl = yt1; new_bl = yb1
                new_tr = yt2; new_br = yb2
            else:
                TIGHTEN_STATS['new_interp_path'] += 1
                new_tl = _interp_store(ox0, sx1, yt1, sx2, yt2)
                new_tr = _interp_store(ox1, sx1, yt1, sx2, yt2)
                new_bl = _interp_store(ox0, sx1, yb1, sx2, yb2)
                new_br = _interp_store(ox1, sx1, yb1, sx2, yb2)
            # Crossover detection uses UNCLAMPED s16 values so that a line
            # that crosses entirely in negative-y territory still registers
            # as a crossover. Matches the asm which does sign-bit logic on
            # the high byte before clamping.
            dt0 = old_tl - new_tl; dt1 = old_tr - new_tr
            db0 = old_bl - new_bl; db1 = old_br - new_br
            has_top_cx = (dt0 != dt1 and ((dt0 >= 0) != (dt1 >= 0)))
            has_bot_cx = (db0 != db1 and ((db0 >= 0) != (db1 >= 0)))

            # Clamped copies of new_* for dominance check and no-crossover
            # storage (matches asm `tg_cn{1..4}` block). Unclamped new_*
            # stays available for the crossover path — _tighten_span needs
            # the signed values to compute the crossover x correctly.
            # The visible Y range depends on the caller's coordinate
            # system: biased (Instrumented6502Spans) uses [Y_BIAS, VIS_YMAX]
            # = [48, 207], unbiased (plain EndpointClipSpans used by
            # debug stepper / FP reference) uses [0, 159].  Derive from
            # self.y_display_offset so tighten matches the caller's spans.
            vis_min = self.y_display_offset
            vis_max = self.y_display_offset + FP_RENDER_H - 1
            c_tl = max(vis_min, min(vis_max, new_tl))
            c_tr = max(vis_min, min(vis_max, new_tr))
            c_bl = max(vis_min, min(vis_max, new_bl))
            c_br = max(vis_min, min(vis_max, new_br))

            if (c_tl <= old_tl and c_tr <= old_tr and
                    c_bl >= old_bl and c_br >= old_br):
                TIGHTEN_STATS['full_dom'] += 1
                _append_merge(new, s); continue
            # Left fragment (line preserved, abutting: includes ilo)
            if xs < ilo:
                _append_merge(new, (xs, ilo,
                                    s[2], s[3], s[4], s[5], s[6], s[7]))
            # Right fragment (abutting: includes ihi)
            right_s = ((ihi, xe, s[2], s[3], s[4], s[5], s[6], s[7])
                       if ihi < xe else None)

            if not has_top_cx and not has_bot_cx:
                rt_l = max(old_tl, c_tl); rb_l = min(old_bl, c_bl)
                rt_r = max(old_tr, c_tr); rb_r = min(old_br, c_br)
                if rt_l < rb_l or rt_r < rb_r:  # ox0 < ox1 guaranteed by strict overlap
                    old_top_wins = (rt_l == old_tl and rt_r == old_tr)
                    old_bot_wins = (rb_l == old_bl and rb_r == old_br)
                    if old_top_wins and old_bot_wins:
                        TIGHTEN_STATS['no_cx_both_win'] += 1
                        _append_merge(new, (ox0, ox1, s[2], s[3],
                                            s[4], s[5], s[6], s[7]))
                    else:
                        if old_top_wins:
                            TIGHTEN_STATS['no_cx_bot_only'] += 1
                            if pre_top_dom:
                                TIGHTEN_STATS['pre_save_top4'] += 1
                        elif old_bot_wins:
                            TIGHTEN_STATS['no_cx_top_only'] += 1
                            if pre_bot_dom:
                                TIGHTEN_STATS['pre_save_bot4'] += 1
                        else:
                            TIGHTEN_STATS['no_cx_both_narrow'] += 1
                        _append_merge(new, (ox0, ox1, ox0, ox1,
                                            rt_l, rb_l, rt_r, rb_r))
                else:
                    TIGHTEN_STATS['no_cx_killed'] += 1
            else:
                TIGHTEN_STATS['crossover'] += 1
                _tighten_span(s, ox0, ox1, sx1, sx2, yt1, yt2,
                              yb1, yb2, new,
                              old_tl, old_tr, old_bl, old_br,
                              new_tl, new_tr, new_bl, new_br,
                              y_display_offset=self.y_display_offset)
            if right_s is not None:
                _append_merge(new, right_s)
        self.spans = new
        self._update_bbox()

    # -- Records-based unified clip+tighten (prototype) -----------------------

    def clip_line_records(self, lx1, ly1, lx2, ly2, ilo=None, ihi=None):
        """Per-span clip sub-records for a line. Mirrors what DCL writes
        during its emission walk: the clipped fragment endpoints encode
        the boundary x's where the line crosses span_top or span_bot.

        Each span's overlap [ox0, ox1] is decomposed into 1-3 sub-ranges
        with uniform verdict (the natural sub-ranges between consecutive
        clip-boundary x's). The user's observation: crossover IS just
        "line goes from being clipped to not clipped" — those are the
        sub-range boundaries.

        Returns flat list of sub-records:
          'si'              span index in self.spans
          'sox0','sox1'     sub-range column range [sox0, sox1]
          'verdict'         'above'  (line above span_top → no narrow)
                            'inside' (line in aperture  → narrow to line)
                            'below'  (line below span_bot → mark_solid)
          'cy0','cy1'       line y at sox0, sox1 (only for verdict='inside';
                            these are what tighten uses for narrowing)
        """
        if lx1 == lx2:
            return []
        if lx1 > lx2:
            xl, yl, xr, yr = lx2, ly2, lx1, ly1
        else:
            xl, yl, xr, yr = lx1, ly1, lx2, ly2
        if ilo is None: ilo = xl
        if ihi is None: ihi = xr
        records = []
        for si, s in enumerate(self.spans):
            xs, xe = s[0], s[1]
            if xe <= ilo or xs >= ihi:
                continue
            ox0 = max(xs, ilo); ox1 = min(xe, ihi)
            # Endpoint values to detect crossings.
            cy0 = _interp_store(ox0, xl, yl, xr, yr)
            cy1 = _interp_store(ox1, xl, yl, xr, yr)
            old_tl = _span_top_store(s, ox0)
            old_tr = _span_top_store(s, ox1)
            old_bl = _span_bot_store(s, ox0)
            old_br = _span_bot_store(s, ox1)
            # Collect sub-range boundaries via line-vs-boundary crossings.
            # Sign change in (cy - boundary) over [ox0, ox1] ⇒ crossing.
            dt0 = cy0 - old_tl; dt1 = cy1 - old_tr
            db0 = cy0 - old_bl; db1 = cy1 - old_br
            splits = [ox0, ox1]
            if dt0 != dt1 and ((dt0 < 0) != (dt1 < 0)):
                cx_t = _crossover_x(ox0, ox1, dt0, dt1)
                if cx_t is not None and ox0 < cx_t < ox1:
                    splits.append(cx_t)
            if db0 != db1 and ((db0 < 0) != (db1 < 0)):
                cx_b = _crossover_x(ox0, ox1, db0, db1)
                if cx_b is not None and ox0 < cx_b < ox1:
                    splits.append(cx_b)
            splits = sorted(set(splits))
            # Single-column span (ox0 == ox1) collapses to one boundary; emit
            # a degenerate sub-record at that point.
            if len(splits) == 1:
                p = splits[0]
                cy_p = _interp_store(p, xl, yl, xr, yr)
                tp = _span_top_store(s, p)
                bp = _span_bot_store(s, p)
                if cy_p <= tp:
                    records.append({'si': si, 'sox0': p, 'sox1': p,
                                    'verdict': 'above'})
                elif cy_p >= bp:
                    records.append({'si': si, 'sox0': p, 'sox1': p,
                                    'verdict': 'below'})
                else:
                    records.append({'si': si, 'sox0': p, 'sox1': p,
                                    'verdict': 'inside',
                                    'cy0': cy_p, 'cy1': cy_p})
                continue
            # Emit one sub-record per [splits[i], splits[i+1]]. Verdict is
            # determined by both endpoints (handles "boundary touch" cases
            # where the line equals span_top at one end and is in-aperture
            # at the other — the endpoint-based check catches these).
            for i in range(len(splits) - 1):
                s_lo = splits[i]; s_hi = splits[i + 1]
                if s_hi <= s_lo:
                    continue
                cy_lo = _interp_store(s_lo, xl, yl, xr, yr)
                cy_hi = _interp_store(s_hi, xl, yl, xr, yr)
                t_lo = _span_top_store(s, s_lo)
                t_hi = _span_top_store(s, s_hi)
                b_lo = _span_bot_store(s, s_lo)
                b_hi = _span_bot_store(s, s_hi)
                # Inclusive: cy <= top at both endpoints → 'above'
                # (no narrow for yt, mark_solid for yb).
                if cy_lo <= t_lo and cy_hi <= t_hi:
                    records.append({'si': si, 'sox0': s_lo, 'sox1': s_hi,
                                    'verdict': 'above'})
                elif cy_lo >= b_lo and cy_hi >= b_hi:
                    records.append({'si': si, 'sox0': s_lo, 'sox1': s_hi,
                                    'verdict': 'below'})
                else:
                    records.append({'si': si, 'sox0': s_lo, 'sox1': s_hi,
                                    'verdict': 'inside',
                                    'cy0': cy_lo, 'cy1': cy_hi})
        return records

    def tighten_from_records(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                             top_records, bot_records):
        """Tighten consumes sub-records from clip_line_records of yt and yb.
        Each span's [ox0, ox1] is partitioned into uniform sub-ranges by
        the union of top and bot crossings. Per combined sub-range:
          top_verdict='below' OR bot_verdict='above' → mark_solid
          top='above' AND bot='below' → span unchanged in this sub-range
          top='inside' → narrow top to yt-line in this sub-range
          bot='inside' → narrow bot to yb-line in this sub-range
        Crossover handled natively by sub-range fragmentation; no fallback
        to per-span interp.

        Verdict semantics per line:
          yt 'above':  yt < span_top → no top narrow.
          yt 'inside': yt in aperture → narrow top to yt.
          yt 'below':  yt > span_bot → mark_solid (seg below span).
          yb 'above':  yb < span_top → mark_solid (seg above span).
          yb 'inside': yb in aperture → narrow bot to yb.
          yb 'below':  yb > span_bot → no bot narrow.
        """
        _ = sx1, sx2, yt1, yt2, yb1, yb2  # not needed — info is in records
        ilo = max(0, lo); ihi = min(FP_RENDER_W - 1, hi)
        if ihi < ilo: return
        # Group sub-records by span index.
        top_by_si = {}
        bot_by_si = {}
        for r in top_records:
            top_by_si.setdefault(r['si'], []).append(r)
        for r in bot_records:
            bot_by_si.setdefault(r['si'], []).append(r)
        new = []
        for si, s in enumerate(self.spans):
            top_subs = top_by_si.get(si, [])
            bot_subs = bot_by_si.get(si, [])
            if not top_subs and not bot_subs:
                _append_merge(new, s); continue
            # Full-dom shortcut: yt above span_top AND yb below span_bot
            # everywhere on overlap → span unchanged. Matches norm's
            # _append_merge(new, s) case (line 532) when c_tl<=old_tl etc.
            if (all(r['verdict'] == 'above' for r in top_subs) and
                    all(r['verdict'] == 'below' for r in bot_subs)):
                _append_merge(new, s); continue
            xs, xe = s[0], s[1]
            # Union of all sub-range boundaries inside this span.
            boundaries = set()
            for r in top_subs:
                boundaries.add(r['sox0']); boundaries.add(r['sox1'])
            for r in bot_subs:
                boundaries.add(r['sox0']); boundaries.add(r['sox1'])
            boundaries = sorted(boundaries)
            ox0 = boundaries[0]; ox1 = boundaries[-1]
            # Single-column span: treat as one degenerate sub-range.
            if len(boundaries) == 1:
                p = boundaries[0]
                top_r = next((r for r in top_subs if r['sox0'] == p), None)
                bot_r = next((r for r in bot_subs if r['sox0'] == p), None)
                top_v = top_r['verdict'] if top_r else 'above'
                bot_v = bot_r['verdict'] if bot_r else 'below'
                if top_v == 'below' or bot_v == 'above':
                    continue  # mark_solid
                old_t_p = _span_top_store(s, p); old_b_p = _span_bot_store(s, p)
                rt = max(old_t_p, top_r['cy0']) if top_v == 'inside' else old_t_p
                rb = min(old_b_p, bot_r['cy0']) if bot_v == 'inside' else old_b_p
                if rt >= rb: continue  # no aperture
                if rt == old_t_p and rb == old_b_p:
                    _append_merge(new, s); continue
                _append_merge(new, (p, p, p, p, rt, rb, rt, rb))
                continue
            # Left fragment outside seg (line preserved).
            if xs < ox0:
                _append_merge(new, (xs, ox0,
                                    s[2], s[3], s[4], s[5], s[6], s[7]))
            right_s = ((ox1, xe, s[2], s[3], s[4], s[5], s[6], s[7])
                       if ox1 < xe else None)
            # Walk combined sub-ranges.
            for i in range(len(boundaries) - 1):
                s_lo = boundaries[i]; s_hi = boundaries[i + 1]
                if s_hi <= s_lo: continue
                mid = (s_lo + s_hi) // 2
                # Find covering sub-records (linear scan — small N per span).
                top_r = None
                for r in top_subs:
                    if r['sox0'] <= mid <= r['sox1']:
                        top_r = r; break
                bot_r = None
                for r in bot_subs:
                    if r['sox0'] <= mid <= r['sox1']:
                        bot_r = r; break
                # If no record covers this sub-range, treat as no narrow on
                # that side (line wasn't sampled there — happens when one
                # line's overlap extends beyond the other's).
                top_v = top_r['verdict'] if top_r else 'above'
                bot_v = bot_r['verdict'] if bot_r else 'below'
                # mark_solid?
                if top_v == 'below' or bot_v == 'above':
                    continue
                # Compute narrowing values at sub-range endpoints.
                old_t_lo = _span_top_store(s, s_lo)
                old_t_hi = _span_top_store(s, s_hi)
                old_b_lo = _span_bot_store(s, s_lo)
                old_b_hi = _span_bot_store(s, s_hi)
                if top_v == 'inside':
                    # Interp yt-line value at s_lo, s_hi from top_r endpoints.
                    t_a, t_b = top_r['sox0'], top_r['sox1']
                    t_y0, t_y1 = top_r['cy0'], top_r['cy1']
                    if t_a == t_b or (s_lo == t_a and s_hi == t_b):
                        nt_lo, nt_hi = t_y0, t_y1
                    else:
                        nt_lo = _interp_store(s_lo, t_a, t_y0, t_b, t_y1)
                        nt_hi = _interp_store(s_hi, t_a, t_y0, t_b, t_y1)
                    rt_lo = max(old_t_lo, nt_lo)
                    rt_hi = max(old_t_hi, nt_hi)
                else:
                    rt_lo, rt_hi = old_t_lo, old_t_hi
                if bot_v == 'inside':
                    b_a, b_b = bot_r['sox0'], bot_r['sox1']
                    b_y0, b_y1 = bot_r['cy0'], bot_r['cy1']
                    if b_a == b_b or (s_lo == b_a and s_hi == b_b):
                        nb_lo, nb_hi = b_y0, b_y1
                    else:
                        nb_lo = _interp_store(s_lo, b_a, b_y0, b_b, b_y1)
                        nb_hi = _interp_store(s_hi, b_a, b_y0, b_b, b_y1)
                    rb_lo = min(old_b_lo, nb_lo)
                    rb_hi = min(old_b_hi, nb_hi)
                else:
                    rb_lo, rb_hi = old_b_lo, old_b_hi
                # Aperture check (closed range — abutting seam-friendly).
                if rt_lo >= rb_lo and rt_hi >= rb_hi:
                    continue  # no aperture → mark_solid
                old_top_wins = (rt_lo == old_t_lo and rt_hi == old_t_hi)
                old_bot_wins = (rb_lo == old_b_lo and rb_hi == old_b_hi)
                if old_top_wins and old_bot_wins:
                    _append_merge(new, (s_lo, s_hi, s[2], s[3],
                                        s[4], s[5], s[6], s[7]))
                else:
                    _append_merge(new, (s_lo, s_hi, s_lo, s_hi,
                                        rt_lo, rb_lo, rt_hi, rb_hi))
            if right_s is not None:
                _append_merge(new, right_s)
        self.spans = new
        self._update_bbox()

    # -- Unified clip+tighten (prototype) --------------------------------------

    def unified_clip_tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                             emit_top_to=None, emit_bot_to=None):
        """Single-walk clip+narrow.

        Walks self.spans once. For each span overlapping [lo, hi]:
          - Compute the seg's effective top/bot at overlap endpoints.
          - Compute the span's old top/bot at overlap endpoints.
          - Determine: full_dom (span unchanged), mark_solid (seg outside
            span aperture), narrow (intersection), or split (crossover).
          - If emit_top_to / emit_bot_to callbacks are provided, emit the
            yt-line / yb-line clipped to the span's aperture in [ox0, ox1].

        Equivalent to tighten() in span-state outcome — verified by parallel
        test. Adds emission piggybacked on the same per-span interp work,
        which on 6502 would replace the separate DCL-of-bt/bb pass.

        Mark-solid handling: when the seg's clamped aperture [c_tl, c_bl]
        / [c_tr, c_br] doesn't overlap the span aperture at either endpoint,
        the span is removed in [ox0, ox1] (its left/right fragments outside
        the seg are preserved). This is equivalent to mark_solid for that
        sub-range — but matches existing tighten behaviour which simply
        omits the no-aperture span from the new list.

        emit_top_to / emit_bot_to: optional callbacks `f(x1, y1, x2, y2)`
        invoked with the clipped fragment of the yt-line / yb-line within
        the span's aperture. None = don't emit (state-only mode).
        """
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W - 1, hi)
        if ihi < ilo: return
        if sx1 > sx2:
            sx1, sx2 = sx2, sx1
            yt1, yt2 = yt2, yt1
            yb1, yb2 = yb2, yb1
        sx1, sx2, yt1, yt2, yb1, yb2 = _remap_seg_for_8bit(
            ilo, ihi, sx1, sx2, yt1, yt2, yb1, yb2,
            clamp_u8=(self.y_display_offset != 0))
        new = []
        for s in self.spans:
            xs, xe = s[0], s[1]
            if xe <= ilo or xs >= ihi:
                _append_merge(new, s); continue
            ox0 = max(xs, ilo); ox1 = min(xe, ihi)
            # Per-span interp work (used for both narrowing AND emission clip)
            if ox0 == s[2] and ox1 == s[3]:
                old_tl = s[4]; old_bl = s[5]
                old_tr = s[6]; old_br = s[7]
            else:
                old_tl = _span_top_store(s, ox0)
                old_tr = _span_top_store(s, ox1)
                old_bl = _span_bot_store(s, ox0)
                old_br = _span_bot_store(s, ox1)
            if ox0 == sx1 and ox1 == sx2:
                new_tl = yt1; new_bl = yb1
                new_tr = yt2; new_br = yb2
            else:
                new_tl = _interp_store(ox0, sx1, yt1, sx2, yt2)
                new_tr = _interp_store(ox1, sx1, yt1, sx2, yt2)
                new_bl = _interp_store(ox0, sx1, yb1, sx2, yb2)
                new_br = _interp_store(ox1, sx1, yb1, sx2, yb2)
            dt0 = old_tl - new_tl; dt1 = old_tr - new_tr
            db0 = old_bl - new_bl; db1 = old_br - new_br
            has_top_cx = (dt0 != dt1 and ((dt0 >= 0) != (dt1 >= 0)))
            has_bot_cx = (db0 != db1 and ((db0 >= 0) != (db1 >= 0)))

            vis_min = self.y_display_offset
            vis_max = self.y_display_offset + FP_RENDER_H - 1
            c_tl = max(vis_min, min(vis_max, new_tl))
            c_tr = max(vis_min, min(vis_max, new_tr))
            c_bl = max(vis_min, min(vis_max, new_bl))
            c_br = max(vis_min, min(vis_max, new_br))

            # Emission: yt-line clipped to aperture in [ox0, ox1].
            # Visible iff the clamped new top is between old top and old bot
            # at both endpoints (plain in-aperture). For partial visibility
            # we'd compute a sub-range, but for the prototype we keep this
            # simple: emit only when both endpoints are in-aperture.
            if emit_top_to is not None:
                if old_tl <= c_tl <= old_bl and old_tr <= c_tr <= old_br:
                    emit_top_to(ox0, c_tl, ox1, c_tr)
            if emit_bot_to is not None:
                if old_tl <= c_bl <= old_bl and old_tr <= c_br <= old_br:
                    emit_bot_to(ox0, c_bl, ox1, c_br)

            # Span narrowing — same logic as tighten.
            if (c_tl <= old_tl and c_tr <= old_tr and
                    c_bl >= old_bl and c_br >= old_br):
                _append_merge(new, s); continue
            if xs < ilo:
                _append_merge(new, (xs, ilo,
                                    s[2], s[3], s[4], s[5], s[6], s[7]))
            right_s = ((ihi, xe, s[2], s[3], s[4], s[5], s[6], s[7])
                       if ihi < xe else None)

            if not has_top_cx and not has_bot_cx:
                rt_l = max(old_tl, c_tl); rb_l = min(old_bl, c_bl)
                rt_r = max(old_tr, c_tr); rb_r = min(old_br, c_br)
                if rt_l < rb_l or rt_r < rb_r:
                    old_top_wins = (rt_l == old_tl and rt_r == old_tr)
                    old_bot_wins = (rb_l == old_bl and rb_r == old_br)
                    if old_top_wins and old_bot_wins:
                        _append_merge(new, (ox0, ox1, s[2], s[3],
                                            s[4], s[5], s[6], s[7]))
                    else:
                        _append_merge(new, (ox0, ox1, ox0, ox1,
                                            rt_l, rb_l, rt_r, rb_r))
                # else: rt >= rb at both endpoints — span fully occluded by
                # seg's wall in [ox0, ox1] → mark_solid (omit fragment).
            else:
                _tighten_span(s, ox0, ox1, sx1, sx2, yt1, yt2,
                              yb1, yb2, new,
                              old_tl, old_tr, old_bl, old_br,
                              new_tl, new_tr, new_bl, new_br,
                              y_display_offset=self.y_display_offset)
            if right_s is not None:
                _append_merge(new, right_s)
        self.spans = new
        self._update_bbox()

    # -- Clipping --------------------------------------------------------------

    def draw_clipped(self, lines, color, surface, stats=None):
        # Optionally collect drawn line segments for labelling overlay
        _real_draw = pygame.draw.line
        if _drawn_lines is not None:
            def _tracking_draw(surf, col, p1, p2, w=1):
                _drawn_lines.append((len(_drawn_lines), p1[0], p1[1], p2[0], p2[1]))
                return _real_draw(surf, col, p1, p2, w)
            _draw = _tracking_draw
        else:
            _draw = _real_draw

        for lx1, ly1, lx2, ly2 in lines:
            if stats is not None: stats[0] += 1
            drawn = False

            # Cost tracking
            if _line_cost is not None:
                _line_cost.clear()
                for k in ('bbox_rej','outer_rej','inner_acc','cb_entry','cb_rej',
                          'portal_cheap','portal_exact','portal_exact_fail',
                          'portal_bbox_fail','cb_exit','vert_clip'):
                    _line_cost[k] = 0

            # Global bbox reject
            if self.bbox:
                bx0, bx1, bt, bb = self.bbox
                x_lo = min(lx1, lx2); x_hi = max(lx1, lx2)
                y_lo = min(ly1, ly2); y_hi = max(ly1, ly2)
                if x_hi < bx0 or x_lo > bx1 or y_hi < bt or y_lo > bb:
                    if _line_cost is not None: _line_cost['bbox_rej'] += 1
                    if stats is not None: stats[3] += 1
                    continue
            elif not self.spans:
                if stats is not None: stats[3] += 1
                continue

            if abs(lx1 - lx2) < 1:
                ix = lx1
                _vert_drew = False
                for s in self.spans:
                    xs, xe = s[0], s[1]
                    if xs <= ix <= xe:
                        top_y = _span_top_ceil(s, ix)
                        bot_y = _span_bot(s, ix)
                        if top_y >= bot_y: break
                        y_min, y_max = min(ly1, ly2), max(ly1, ly2)
                        cy1 = max(y_min, top_y)
                        cy2 = min(y_max, bot_y)
                        if cy1 <= cy2:
                            _draw(surface, _rand_color(),
                                             (ix, cy1 - self.y_display_offset), (ix, cy2 - self.y_display_offset), 1)
                            drawn = True
                            if y_min >= top_y and y_max <= bot_y:
                                _vert_drew = 'acc'
                            else:
                                _vert_drew = 'clip'
                        break
                if _line_cost is not None:
                    if _vert_drew == 'acc':
                        _line_cost['vert_acc'] = 1
                    elif _vert_drew == 'clip':
                        _line_cost['vert_clip'] = 1
                    else:
                        _line_cost['vert_rej'] = 1
            else:
                from clip_math import div_round

                if lx1 <= lx2:
                    xl, yl, xr, yr = lx1, ly1, lx2, ly2
                else:
                    xl, yl, xr, yr = lx2, ly2, lx1, ly1
                dx_line = xr - xl
                dy_line = yr - yl
                y_lo = min(yl, yr)
                y_hi = max(yl, yr)

                def _line_y_at(x):
                    if dx_line == 0: return yl
                    return yl + div_round(dy_line * (x - xl), dx_line)

                cost = _line_cost
                seg_start = None
                trivial_entry = False
                for si, s in enumerate(self.spans):
                    if s[1] <= xl or s[0] >= xr:  # pixel-center overlap
                        continue

                    # Aperture top/bot at the active range endpoints
                    ts = _span_top(s, s[0]); te = _span_top(s, s[1])
                    bs = _span_bot(s, s[0]); be = _span_bot(s, s[1])
                    ot = min(ts, te)
                    ob = max(bs, be)
                    # Re-evaluate trivial_entry against THIS span. The flag
                    # must track the span we're currently in, not the one we
                    # entered via — otherwise the "last span" draw-unclipped
                    # fast path below trusts a stale flag from an earlier
                    # span whose aperture was wider. (Portal seam checks only
                    # verify line-inside-aperture at one x; the next span's
                    # aperture can still shrink across its own x range.)
                    it = max(ts, te)
                    ib = min(bs, be)
                    trivial_entry = y_lo >= it and y_hi <= ib

                    if seg_start is None:
                        if y_hi < ot or y_lo > ob:
                            if cost is not None: cost['outer_rej'] += 1
                            continue
                        if trivial_entry:
                            ex = max(xl, s[0])
                            seg_start = (ex, _line_y_at(ex) if ex != xl else yl)
                            if cost is not None: cost['inner_acc'] += 1
                        else:
                            c = _clip_to_span(lx1, ly1, lx2, ly2, s)
                            if c is None:
                                if cost is not None: cost['cb_rej'] += 1
                                continue
                            seg_start = (c[0], c[1])
                            if cost is not None: cost['cb_entry'] += 1

                    next_s = None
                    # Portal continuation only applies when the line
                    # extends STRICTLY past this span's right edge.  If
                    # xr == s[1] the line ends exactly at the portal
                    # boundary; taking the portal path then causes the
                    # next iteration to skip (ns[0] >= xr) and the
                    # seg_start gets silently dropped.  Fall through to
                    # the else branch and emit via _clip_to_span.
                    if xr > s[1] and si + 1 < len(self.spans) and self.spans[si + 1][0] == s[1]:
                        ns = self.spans[si + 1]
                        if ns[0] <= xr:
                            next_s = ns

                    if next_s is not None:
                        px = next_s[0]  # first column of next span
                        # Portal top/bot use line-evaluated y at the seam
                        pt = max(_span_top(s, s[1]), _span_top(next_s, next_s[0]))
                        pb = min(_span_bot(s, s[1]), _span_bot(next_s, next_s[0]))
                        if pt < pb:
                            if pt <= y_lo and y_hi <= pb:
                                if cost is not None: cost['portal_cheap'] += 1
                                continue
                            if y_hi < pt or y_lo > pb:
                                if cost is not None: cost['portal_bbox_fail'] += 1
                            else:
                                ly = _line_y_at(px)
                                if cost is not None: cost['portal_exact'] += 1
                                if pt <= ly <= pb:
                                    y_lo = min(y_lo, ly)
                                    y_hi = max(y_hi, ly)
                                    continue
                                if cost is not None: cost['portal_exact_fail'] += 1

                        c = _clip_to_span(lx1, ly1, lx2, ly2, s)
                        if c:
                            sx, sy = seg_start
                            ex, ey = c[2], c[3]
                            yoff = self.y_display_offset
                            sy = max(0, min(FP_RENDER_H-1, sy - yoff))
                            ey = max(0, min(FP_RENDER_H-1, ey - yoff))
                            _draw(surface, _rand_color(),
                                             (sx, sy), (ex, ey), 1)
                            drawn = True
                            if cost is not None: cost['cb_exit'] += 1
                        seg_start = None; trivial_entry = False
                    else:
                        # Last span: line ends here.
                        if trivial_entry and xr <= s[1]:
                            sx, sy = seg_start
                            yoff = self.y_display_offset
                            sy = max(0, min(FP_RENDER_H-1, sy - yoff))
                            yr_c = max(0, min(FP_RENDER_H-1, yr - yoff))
                            _draw(surface, _rand_color(),
                                             (sx, sy), (xr, yr_c), 1)
                            drawn = True
                        else:
                            c = _clip_to_span(lx1, ly1, lx2, ly2, s)
                            if c:
                                sx, sy = seg_start
                                ex, ey = c[2], c[3]
                                yoff = self.y_display_offset
                                sy = max(0, min(FP_RENDER_H-1, sy - yoff))
                                ey = max(0, min(FP_RENDER_H-1, ey - yoff))
                                _draw(surface, _rand_color(),
                                                 (sx, sy), (ex, ey), 1)
                                drawn = True
                                if cost is not None: cost['cb_exit'] += 1
                        seg_start = None

            if not drawn and stats is not None:
                stats[3] += 1


# -- Helpers -------------------------------------------------------------------

def _tighten_span(s, ox0, ox1, sx1, sx2, yt1, yt2, yb1, yb2, out,
                  old_tl, old_tr, old_bl, old_br,
                  new_tl, new_tr, new_bl, new_br,
                  y_display_offset=Y_BIAS):
    """Tighten span s over closed interval [ox0, ox1], crossover case only.
    The caller has already computed the dominance values at (ox0, ox1);
    those are passed in as old_tl..new_br (all via _interp_store). Result
    spans at sub-interval boundaries are dense-anchored, except the
    "old wins both" case which preserves the old line.

    y_display_offset: caller's coordinate-system offset (0 for unbiased
    EndpointClipSpans, Y_BIAS=48 for biased Instrumented6502Spans).
    Used to derive the visible Y clamp range.  Default Y_BIAS matches
    the production (biased) caller; the debug stepper / FP reference
    should pass 0.
    """
    xlo, xhi, tl, bl, tr, br = s[2], s[3], s[4], s[5], s[6], s[7]

    splits = [ox0]
    dt0 = old_tl - new_tl; dt1 = old_tr - new_tr
    if dt0 != dt1 and ((dt0 >= 0) != (dt1 >= 0)):
        cx = _crossover_x(ox0, ox1, dt0, dt1)
        if cx is not None: splits.append(cx)
    db0 = old_bl - new_bl; db1 = old_br - new_br
    if db0 != db1 and ((db0 >= 0) != (db1 >= 0)):
        cx = _crossover_x(ox0, ox1, db0, db1)
        if cx is not None: splits.append(cx)
    splits.sort()

    for i in range(len(splits)):
        sx_lo = splits[i]
        sx_hi = splits[i + 1] if i + 1 < len(splits) else ox1
        if sx_hi < sx_lo: continue
        # Reuse cached values at the ox0/ox1 ends of the sub-intervals.
        # Caller passes UNCLAMPED new_*; we clamp after fetching so that
        # the internal crossover_x above still saw the signed values and
        # storage below sees u8 values. Matches asm tg_overlap_sub which
        # recomputes and clamps unconditionally.
        if sx_lo == ox0:
            ot_l = old_tl; ob_l = old_bl
            nt_l = new_tl; nb_l = new_bl
        else:
            ot_l = _interp_store(sx_lo, xlo, tl, xhi, tr)
            ob_l = _interp_store(sx_lo, xlo, bl, xhi, br)
            nt_l = _interp_store(sx_lo, sx1, yt1, sx2, yt2)
            nb_l = _interp_store(sx_lo, sx1, yb1, sx2, yb2)
        if sx_hi == ox1:
            ot_r = old_tr; ob_r = old_br
            nt_r = new_tr; nb_r = new_br
        else:
            ot_r = _interp_store(sx_hi, xlo, tl, xhi, tr)
            ob_r = _interp_store(sx_hi, xlo, bl, xhi, br)
            nt_r = _interp_store(sx_hi, sx1, yt1, sx2, yt2)
            nb_r = _interp_store(sx_hi, sx1, yb1, sx2, yb2)
        vis_min = y_display_offset
        vis_max = y_display_offset + FP_RENDER_H - 1
        nt_l = max(vis_min, min(vis_max, nt_l))
        nb_l = max(vis_min, min(vis_max, nb_l))
        nt_r = max(vis_min, min(vis_max, nt_r))
        nb_r = max(vis_min, min(vis_max, nb_r))
        rt_l = max(ot_l, nt_l); rb_l = min(ob_l, nb_l)
        rt_r = max(ot_r, nt_r); rb_r = min(ob_r, nb_r)
        # Opt 2: if old wins both top and bot at the sub-interval endpoints,
        # preserve the old span's line verbatim. This runs UNCONDITIONALLY
        # (no aperture check) to match asm tg_overlap_sub Opt 2: an old
        # span with a 1-pixel aperture (top==bot) is a valid closed
        # interval and must not be dropped. The aperture check only gates
        # the dense-anchored fallback.
        old_top_wins = (rt_l == ot_l and rt_r == ot_r)
        old_bot_wins = (rb_l == ob_l and rb_r == ob_r)
        if old_top_wins and old_bot_wins:
            _append_merge(out, (sx_lo, sx_hi, xlo, xhi, tl, bl, tr, br))
        elif rt_l < rb_l or rt_r < rb_r:
            _append_merge(out, (sx_lo, sx_hi,
                        sx_lo, sx_hi,
                        rt_l, rb_l,
                        rt_r, rb_r))


def _crossover_x(x0, x1, d0, d1):
    """Find X where two boundary lines cross, given their differences d0,d1
    at x0,x1. Returns X in (x0,x1) or None. Floor division.
    On 6502: s8 * u8 / s9 — one 8x8 mul + one 8-bit div."""
    denom = d0 - d1
    if denom == 0:
        return None
    cx = x0 + d0 * (x1 - x0) // denom
    if x0 < cx < x1:
        return cx
    return None


def _crossover_x_6502(ox0, ox1, d0, d1):
    """Find crossover X using the same formula as the 6502 compute_crossover.

    Uses |d0| * ex / (|d0| + |d1|), unsigned truncating division.
    Returns X in (ox0, ox1) exclusive, or None if at boundary or outside.
    """
    ex = ox1 - ox0
    if ex <= 0:
        return None
    abs_d0 = abs(d0)
    abs_d1 = abs(d1)
    den = abs_d0 + abs_d1
    if den == 0:
        return None
    quot = (abs_d0 * ex) // den
    cx = ox0 + quot
    if cx <= ox0 or cx >= ox1:
        return None
    return cx


def _clamp8(v):
    """Clamp a signed value to [Y_BIAS, VIS_YMAX] matching the 6502's clamping."""
    vis_min = Y_BIAS
    vis_max = Y_BIAS + FP_RENDER_H - 1  # 207
    if v < vis_min:
        return vis_min
    if v > vis_max:
        return vis_max
    return v


def compute_expected_tighten_lines(spans, ilo, ihi, sx1, sx2, yt1, yt2, yb1, yb2):
    """Compute the lines the 6502 would emit during a tighten call.

    Matches the 6502's two emission sites:
    1. No-crossover path: emits top edge when nt_l > ot_l, bot edge when
       nb_l < ob_l. Guarded by ox0 < ox1.
    2. Crossover sub-interval path (tg_overlap_sub): same checks per
       sub-interval, but no ox0 < ox1 guard (the 6502 doesn't have one).

    Args:
        spans: list of 8-tuples (xstart, xend, xlo, xhi, tl, bl, tr, br)
        ilo, ihi: seg column range (pre-clamped to [0,255])
        sx1, sx2, yt1, yt2, yb1, yb2: seg parameters (already remapped)

    Returns:
        list of (x1, y1, x2, y2) tuples matching what the 6502 emits.
    """
    lines = []

    for s in spans:
        xs, xe = s[0], s[1]
        # Pixel-center overlap: endpoint-only contact is NOT overlap
        if xe <= ilo or xs >= ihi:
            continue
        ox0 = max(xs, ilo)
        ox1 = min(xe, ihi)

        # --- Evaluate old span boundaries at overlap endpoints ---
        xlo, xhi, tl, bl, tr, br = s[2], s[3], s[4], s[5], s[6], s[7]
        if ox0 == xlo and ox1 == xhi:
            old_tl, old_tr = tl, tr
            old_bl, old_br = bl, br
        elif tl == tr and bl == br:
            old_tl = old_tr = tl
            old_bl = old_br = bl
        else:
            old_tl = _interp_store(ox0, xlo, tl, xhi, tr)
            old_tr = _interp_store(ox1, xlo, tl, xhi, tr)
            old_bl = _interp_store(ox0, xlo, bl, xhi, br)
            old_br = _interp_store(ox1, xlo, bl, xhi, br)

        # --- Evaluate new seg boundaries at overlap endpoints ---
        if ox0 == sx1 and ox1 == sx2:
            new_tl, new_tr = yt1, yt2
            new_bl, new_br = yb1, yb2
        elif yt1 == yt2 and yt1 >> 8 == yt2 >> 8 and yb1 == yb2 and yb1 >> 8 == yb2 >> 8:
            new_tl = new_tr = yt1
            new_bl = new_br = yb1
        else:
            new_tl = _interp_store(ox0, sx1, yt1, sx2, yt2)
            new_tr = _interp_store(ox1, sx1, yt1, sx2, yt2)
            new_bl = _interp_store(ox0, sx1, yb1, sx2, yb2)
            new_br = _interp_store(ox1, sx1, yb1, sx2, yb2)

        # --- Crossover detection (on unclamped values) ---
        dt0 = old_tl - new_tl
        dt1 = old_tr - new_tr
        db0 = old_bl - new_bl
        db1 = old_br - new_br
        has_top_cx = (dt0 != dt1 and ((dt0 >= 0) != (dt1 >= 0)))
        has_bot_cx = (db0 != db1 and ((db0 >= 0) != (db1 >= 0)))

        # Also check dt != 0 at each endpoint (matching 6502 tg_cc_t_ne_l/r)
        if has_top_cx:
            if dt0 == 0 or dt1 == 0:
                has_top_cx = False
        if has_bot_cx:
            if db0 == 0 or db1 == 0:
                has_bot_cx = False

        # If both nt hi bytes negative, no top crossover (6502 fast path)
        if has_top_cx:
            nt_lh = (new_tl >> 8) & 0xFF if new_tl < 0 or new_tl > 255 else 0
            nt_rh = (new_tr >> 8) & 0xFF if new_tr < 0 or new_tr > 255 else 0
            if new_tl < 0 and new_tr < 0:
                has_top_cx = False

        # --- Clamp new values for dominance check ---
        c_tl = _clamp8(new_tl)
        c_tr = _clamp8(new_tr)
        c_bl = _clamp8(new_bl)
        c_br = _clamp8(new_br)

        # Old dominates: skip
        if (c_tl <= old_tl and c_tr <= old_tr and
                c_bl >= old_bl and c_br >= old_br):
            continue

        if not has_top_cx and not has_bot_cx:
            # --- No-crossover path ---
            # Guard: ox0 < ox1 (skip emission for degenerate 1-column overlap)
            if ox0 >= ox1:
                continue
            # Top edge: nt_l > ot_l (new ceiling more restrictive)
            if c_tl > old_tl:
                lines.append((ox0, c_tl, ox1, c_tr))
            # Bot edge: nb_l < ob_l (new floor more restrictive)
            if c_bl < old_bl:
                lines.append((ox0, c_bl, ox1, c_br))
        else:
            # --- Crossover sub-interval path ---
            # Compute crossover points using 6502-matching formula
            cx_top = None
            cx_bot = None
            if has_top_cx:
                cx_top = _crossover_x_6502(ox0, ox1, dt0, dt1)
            if has_bot_cx:
                cx_bot = _crossover_x_6502(ox0, ox1, db0, db1)

            # Build split points
            splits_x = [ox0]
            if cx_top is not None:
                splits_x.append(cx_top)
            if cx_bot is not None:
                splits_x.append(cx_bot)
            splits_x.sort()
            # Deduplicate
            splits_x = sorted(set(splits_x))

            # Process each sub-interval
            for si in range(len(splits_x)):
                sub_lo = splits_x[si]
                if si + 1 < len(splits_x):
                    sub_hi = splits_x[si + 1]  # abutting: shared boundary
                else:
                    sub_hi = ox1

                if sub_hi < sub_lo:
                    continue

                # Re-interpolate old and new at sub-interval endpoints
                if tl == tr and bl == br:
                    s_ot_l = s_ot_r = tl
                    s_ob_l = s_ob_r = bl
                else:
                    s_ot_l = _interp_store(sub_lo, xlo, tl, xhi, tr)
                    s_ot_r = _interp_store(sub_hi, xlo, tl, xhi, tr)
                    s_ob_l = _interp_store(sub_lo, xlo, bl, xhi, br)
                    s_ob_r = _interp_store(sub_hi, xlo, bl, xhi, br)

                if yt1 == yt2 and yb1 == yb2:
                    s_nt_l = s_nt_r = yt1
                    s_nb_l = s_nb_r = yb1
                else:
                    s_nt_l = _interp_store(sub_lo, sx1, yt1, sx2, yt2)
                    s_nt_r = _interp_store(sub_hi, sx1, yt1, sx2, yt2)
                    s_nb_l = _interp_store(sub_lo, sx1, yb1, sx2, yb2)
                    s_nb_r = _interp_store(sub_hi, sx1, yb1, sx2, yb2)

                # Clamp new values
                s_nt_l = _clamp8(s_nt_l)
                s_nt_r = _clamp8(s_nt_r)
                s_nb_l = _clamp8(s_nb_l)
                s_nb_r = _clamp8(s_nb_r)

                # Opt 2: if old wins all 4 comparisons, skip emission
                if (s_ot_l >= s_nt_l and s_ot_r >= s_nt_r and
                        s_nb_l >= s_ob_l and s_nb_r >= s_ob_r):
                    continue

                # Guard: skip emission for degenerate 1-column sub-intervals
                if sub_lo >= sub_hi:
                    continue
                # Emit top edge: nt_l > ot_l
                if s_nt_l > s_ot_l:
                    lines.append((sub_lo, s_nt_l, sub_hi, s_nt_r))
                # Emit bot edge: nb_l < ob_l
                if s_nb_l < s_ob_l:
                    lines.append((sub_lo, s_nb_l, sub_hi, s_nb_r))

    return lines


def _line_y(ly1, dy, dx, x, lx1):
    """Compute line Y at x using real division with round-to-nearest."""
    from clip_math import div_round
    if dx == 0:
        return ly1
    return ly1 + div_round(dy * (x - lx1), dx)


def _clip_to_span(lx1, ly1, lx2, ly2, s):
    """Clip line to span's ACTIVE range, using the span's LINE for top/bot."""
    from clip_math import boundary_ix
    xlo, xhi = s[0], s[1]                           # active range
    line_xlo, line_xhi = s[2], s[3]                 # line anchors
    tl, bl, tr, br = s[4], s[5], s[6], s[7]
    dx = lx2 - lx1
    dy = ly2 - ly1
    if xhi < xlo:
        return None

    cx1, cy1, cx2, cy2 = lx1, ly1, lx2, ly2

    # -- Clip to X range [xlo, xhi] (closed) --
    if dx == 0:
        if lx1 < xlo or lx1 > xhi:
            return None
    else:
        if (dx > 0 and cx1 < xlo) or (dx < 0 and cx2 < xlo):
            y_at = _line_y(ly1, dy, dx, xlo, lx1)
            if dx > 0:
                cx1, cy1 = xlo, y_at
            else:
                cx2, cy2 = xlo, y_at
        if (dx > 0 and cx2 > xhi) or (dx < 0 and cx1 > xhi):
            y_at = _line_y(ly1, dy, dx, xhi, lx1)
            if dx > 0:
                cx2, cy2 = xhi, y_at
            else:
                cx1, cy1 = xhi, y_at
        if min(cx1, cx2) > xhi or max(cx1, cx2) < xlo:
            return None

    # -- Evaluate boundaries at clipped X endpoints --
    # Top: ceiling (never above boundary).  Bot: floor (never below).
    top1 = _interp_ceil(cx1, line_xlo, tl, line_xhi, tr)
    top2 = _interp_ceil(cx2, line_xlo, tl, line_xhi, tr)
    bot1 = _interp(cx1, line_xlo, bl, line_xhi, br)
    bot2 = _interp(cx2, line_xlo, bl, line_xhi, br)

    # -- Clip to top boundary (cy >= top) --
    above1 = cy1 < top1
    above2 = cy2 < top2
    if above1 and above2:
        return None
    if above1 or above2:
        d1 = cy1 - top1
        d2 = cy2 - top2
        ix = boundary_ix(cx1, cx2, d1, d2, above1)
        if ix is None:
            return None
        iy = _line_y(ly1, dy, dx, ix, lx1)
        if above1:
            cx1, cy1 = ix, iy
        else:
            cx2, cy2 = ix, iy
        if above1:
            bot1 = _interp(ix, line_xlo, bl, line_xhi, br)
        else:
            bot2 = _interp(ix, line_xlo, bl, line_xhi, br)

    # -- Clip to bottom boundary (cy <= bot) --
    below1 = cy1 > bot1
    below2 = cy2 > bot2
    if below1 and below2:
        return None
    if below1 or below2:
        d1 = cy1 - bot1
        d2 = cy2 - bot2
        ix = boundary_ix(cx1, cx2, d1, d2, below1)
        if ix is None:
            return None
        iy = _line_y(ly1, dy, dx, ix, lx1)
        if below1:
            cx1, cy1 = ix, iy
        else:
            cx2, cy2 = ix, iy

    # -- Final validation --
    if dx >= 0:
        if cx1 > cx2: return None
    else:
        if cx1 < cx2: return None

    return (cx1, cy1, cx2, cy2)
