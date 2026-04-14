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
    """Interpolate Y for span storage: round-to-nearest (no systematic bias).
    Prevents the min/max ratchet from accumulating in one direction."""
    if x1 == x0:
        return y0
    num = (y1 - y0) * (x - x0)
    den = x1 - x0
    if den > 0:
        return y0 + (num + den // 2) // den
    return y0 + (-num + (-den) // 2) // (-den)


def _remap_seg_for_8bit(ilo, ihi, sx1, sx2, yt1, yt2, yb1, yb2):
    """Remap seg parameters so the 6502 8-bit interp pipeline always works.

    Constraints:
      - ex = sx2 - sx1 ≤ 255 (fits u8)
      - offset = eval_x - sx1 ∈ [0, 255] for all eval_x ∈ [ilo, ihi]
      - |dy_top|, |dy_bot| ≤ 127 (fits s8 fast path)

    The remap chooses new_ex so |new_dy| ≤ 126 in real arithmetic; after
    interp_store rounding the actual |new_dy| ≤ 127 with margin.

    Degenerate case: when the line is too steep (`max_dy > 126 * orig_ex`,
    e.g. orig_ex=3, max_dy=548), no integer new_ex ≥ 1 can achieve
    |new_dy| ≤ 127. In that case we check whether the line is consistently
    off-screen throughout [ilo, ihi]; if so, we replace that boundary with
    a constant at the clamp value (0 or 159), which is exactly equivalent
    to what the asm's clamping+dominance would compute. The crossing case
    (line enters and exits visible range within [ilo, ihi]) is rare enough
    that we leave the remap as-is and accept minor divergence.
    """
    orig_ex = sx2 - sx1
    if orig_ex == 0:
        return sx1, sx1 + 1, yt1, yt2, yb1, yb2
    max_dy = max(abs(yt2 - yt1), abs(yb2 - yb1))
    # Early return when original parameters already satisfy all constraints
    if (sx1 <= ilo and sx1 + 255 >= ihi and
            orig_ex <= 255 and max_dy <= 127):
        return sx1, sx2, yt1, yt2, yb1, yb2
    # Compute new_ex such that |new_dy_real| ≤ 126 (rounding margin → ≤127)
    if max_dy >= 1:
        new_ex = (126 * orig_ex) // max_dy
    else:
        new_ex = orig_ex
    new_ex = max(1, min(255, new_ex))
    x_lo = ilo
    x_hi = x_lo + new_ex
    nyt1 = _interp_store(x_lo, sx1, yt1, sx2, yt2)
    nyt2 = _interp_store(x_hi, sx1, yt1, sx2, yt2)
    nyb1 = _interp_store(x_lo, sx1, yb1, sx2, yb2)
    nyb2 = _interp_store(x_hi, sx1, yb1, sx2, yb2)
    # Verify |new_dy| ≤ 127. If the line is too steep for any new_ex ≥ 1,
    # check whether the affected boundary is consistently off-screen
    # across [ilo, ihi] and substitute a constant if so.
    if abs(nyt2 - nyt1) > 127:
        t_ilo = _interp_store(ilo, sx1, yt1, sx2, yt2)
        t_ihi = _interp_store(ihi, sx1, yt1, sx2, yt2)
        if t_ilo <= 0 and t_ihi <= 0:
            nyt1 = nyt2 = 0          # top entirely above screen → clamp
        elif t_ilo >= 159 and t_ihi >= 159:
            nyt1 = nyt2 = 159        # top entirely below screen → clamp
        # else: crossing case, leave unchanged (rare, may diverge)
    if abs(nyb2 - nyb1) > 127:
        b_ilo = _interp_store(ilo, sx1, yb1, sx2, yb2)
        b_ihi = _interp_store(ihi, sx1, yb1, sx2, yb2)
        if b_ilo <= 0 and b_ihi <= 0:
            nyb1 = nyb2 = 0          # bot entirely above screen → clamp
        elif b_ilo >= 159 and b_ihi >= 159:
            nyb1 = nyb2 = 159        # bot entirely below screen → clamp
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

# Partial-aperture detector. A "partial aperture" span is one where top<bot
# at one endpoint but top>=bot at the other — i.e., the linear top/bot pair
# crosses inside the span and aperture only exists in part of the [xlo, xhi]
# range. The has_gap test would have to do real per-column work for these.
# Set _partial_aperture_check_enabled = True from the test harness to print.
_partial_aperture_check_enabled = False
_partial_aperture_count = 0

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

    __slots__ = ("spans", "bbox")

    def __init__(self):
        # Initial full-screen span: line and active range both [0, 255],
        # top constant 0, bot constant 159.
        s = (0, FP_RENDER_W - 1,           # xstart, xend
             0, FP_RENDER_W - 1,           # xlo, xhi (line anchors)
             0, FP_RENDER_H - 1,           # tl, bl
             0, FP_RENDER_H - 1)           # tr, br
        self.spans = [s]
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
            if s[1] < xl or s[0] > xr: continue
            found = True
            # Aperture at the active range endpoints (interp from line).
            ts = _span_top(s, s[0]); te = _span_top(s, s[1])
            bs = _span_bot(s, s[0]); be = _span_bot(s, s[1])
            it = max(ts, te)
            ib = min(bs, be)
            if y_lo < it or y_hi > ib:
                return False
        return found

    # -- Mutations -------------------------------------------------------------

    def mark_solid(self, lo, hi):
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
                top_dom=False, bot_dom=False):
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W - 1, hi)
        if ihi < ilo: return
        if sx1 > sx2:
            sx1, sx2 = sx2, sx1
            yt1, yt2 = yt2, yt1
            yb1, yb2 = yb2, yb1
        sx1, sx2, yt1, yt2, yb1, yb2 = _remap_seg_for_8bit(
            ilo, ihi, sx1, sx2, yt1, yt2, yb1, yb2)
        new = []
        for s in self.spans:
            xs, xe = s[0], s[1]
            if xe <= ilo or xs >= ihi:  # pixel-center: endpoint-only ≠ overlap
                _append_merge(new, s); continue
            ox0 = max(xs, ilo); ox1 = min(xe, ihi)
            # Dominance/crossover prelude
            # Fast path: if the overlap endpoints match the old span's LINE
            # anchors, the stored tl/bl/tr/br *are* the y values at those
            # endpoints — no interp needed.
            if ox0 == s[2] and ox1 == s[3]:
                old_tl = s[4]; old_bl = s[5]
                old_tr = s[6]; old_br = s[7]
            else:
                old_tl = _span_top_store(s, ox0)
                old_tr = _span_top_store(s, ox1)
                old_bl = _span_bot_store(s, ox0)
                old_br = _span_bot_store(s, ox1)
            # Same fast path for the seg's line
            if ox0 == sx1 and ox1 == sx2:
                new_tl = yt1; new_bl = yb1
                new_tr = yt2; new_br = yb2
            else:
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
            c_tl = 0 if new_tl < 0 else (159 if new_tl > 159 else new_tl)
            c_tr = 0 if new_tr < 0 else (159 if new_tr > 159 else new_tr)
            c_bl = 0 if new_bl < 0 else (159 if new_bl > 159 else new_bl)
            c_br = 0 if new_br < 0 else (159 if new_br > 159 else new_br)

            if (c_tl <= old_tl and c_tr <= old_tr and
                    c_bl >= old_bl and c_br >= old_br):
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
                        _append_merge(new, (ox0, ox1, s[2], s[3],
                                            s[4], s[5], s[6], s[7]))
                    else:
                        _append_merge(new, (ox0, ox1, ox0, ox1,
                                            rt_l, rb_l, rt_r, rb_r))
            else:
                _tighten_span(s, ox0, ox1, sx1, sx2, yt1, yt2,
                              yb1, yb2, new,
                              old_tl, old_tr, old_bl, old_br,
                              new_tl, new_tr, new_bl, new_br)
            if right_s is not None:
                _append_merge(new, right_s)
        self.spans = new
        self._update_bbox()

    # -- Clipping --------------------------------------------------------------

    def draw_clipped(self, lines, color, surface, stats=None):
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
                            pygame.draw.line(surface, _rand_color(),
                                             (ix, cy1), (ix, cy2), 1)
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
                    if s[1] < xl or s[0] > xr:
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
                    if si + 1 < len(self.spans) and self.spans[si + 1][0] == s[1] + 1:
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
                            sy = max(0, min(FP_RENDER_H-1, sy))
                            ey = max(0, min(FP_RENDER_H-1, ey))
                            pygame.draw.line(surface, _rand_color(),
                                             (sx, sy), (ex, ey), 1)
                            drawn = True
                            if cost is not None: cost['cb_exit'] += 1
                        seg_start = None; trivial_entry = False
                    else:
                        # Last span: line ends here.
                        if trivial_entry and xr <= s[1]:
                            # Trivially accepted line ends inside span — no clip needed
                            sx, sy = seg_start
                            sy = max(0, min(FP_RENDER_H-1, sy))
                            yr_c = max(0, min(FP_RENDER_H-1, yr))
                            pygame.draw.line(surface, _rand_color(),
                                             (sx, sy), (xr, yr_c), 1)
                            drawn = True
                        else:
                            c = _clip_to_span(lx1, ly1, lx2, ly2, s)
                            if c:
                                sx, sy = seg_start
                                ex, ey = c[2], c[3]
                                sy = max(0, min(FP_RENDER_H-1, sy))
                                ey = max(0, min(FP_RENDER_H-1, ey))
                                pygame.draw.line(surface, _rand_color(),
                                                 (sx, sy), (ex, ey), 1)
                                drawn = True
                                if cost is not None: cost['cb_exit'] += 1
                        seg_start = None

            if not drawn and stats is not None:
                stats[3] += 1


# -- Helpers -------------------------------------------------------------------

def _tighten_span(s, ox0, ox1, sx1, sx2, yt1, yt2, yb1, yb2, out,
                  old_tl, old_tr, old_bl, old_br,
                  new_tl, new_tr, new_bl, new_br):
    """Tighten span s over closed interval [ox0, ox1], crossover case only.
    The caller has already computed the dominance values at (ox0, ox1);
    those are passed in as old_tl..new_br (all via _interp_store). Result
    spans at sub-interval boundaries are dense-anchored, except the
    "old wins both" case which preserves the old line.
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
    splits.append(ox1 + 1)

    for i in range(len(splits) - 1):
        sx_lo = splits[i]
        sx_hi = splits[i + 1] - 1
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
        if nt_l < 0: nt_l = 0
        elif nt_l > 159: nt_l = 159
        if nb_l < 0: nb_l = 0
        elif nb_l > 159: nb_l = 159
        if nt_r < 0: nt_r = 0
        elif nt_r > 159: nt_r = 159
        if nb_r < 0: nb_r = 0
        elif nb_r > 159: nb_r = 159
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

    cy1 = max(0, min(FP_RENDER_H - 1, cy1))
    cy2 = max(0, min(FP_RENDER_H - 1, cy2))
    return (cx1, cy1, cx2, cy2)
