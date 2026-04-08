"""Integer-endpoint flat-span visibility for the DOOM wireframe renderer.

Each span is (xlo, xhi, yt_lo, yb_lo, yt_hi, yb_hi) — six bytes.
All values are integer pixels: X in [0,256], Y in [0,159].
Boundary between endpoints is a straight line.

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
    # Ceiling = floor + 1 when there's a remainder
    q = num // den
    if q * den != num:
        # Has remainder: ceiling is floor + 1 for positive quotient,
        # floor for negative (Python // already floors toward -inf)
        if (num > 0) == (den > 0):
            q += 1
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


# Cost tracking for debug mode
_line_cost = None


class EndpointClipSpans:
    """Visibility spans with integer pixel Y boundaries.

    self.spans: list of (xlo, xhi, yt_lo, yb_lo, yt_hi, yb_hi)
      xlo, xhi: u8 pixel X coords, interval [xlo, xhi)
      yt_*, yb_*: pixel Y coords
    """

    __slots__ = ("spans", "bbox")

    def __init__(self):
        self.spans = [(0, FP_RENDER_W, 0, FP_RENDER_H - 1, 0, FP_RENDER_H - 1)]
        self._update_bbox()

    def _update_bbox(self):
        if not self.spans:
            self.bbox = None
            return
        x_min = self.spans[0][0]
        x_max = self.spans[-1][1]
        yt_min = min(min(s[2], s[4]) for s in self.spans)
        yb_max = max(max(s[3], s[5]) for s in self.spans)
        self.bbox = (x_min, x_max, yt_min, yb_max)

    # -- Queries ---------------------------------------------------------------

    def is_full(self):
        return not self.spans

    def has_gap(self, lo, hi):
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W - 1, hi)
        for s in self.spans:
            if s[0] > ihi: break
            if s[1] <= ilo: continue
            it = max(s[2], s[4])
            ib = min(s[3], s[5])
            if it < ib:
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
            if s[1] <= xl or s[0] >= xr: continue
            found = True
            it = max(s[2], s[4])
            ib = min(s[3], s[5])
            if y_lo < it or y_hi > ib:
                return False
        return found

    # -- Mutations -------------------------------------------------------------

    def mark_solid(self, lo, hi):
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W, hi + 1)
        if ilo >= ihi: return
        new = []
        for s in self.spans:
            xlo, xhi = s[0], s[1]
            if xhi <= ilo or xlo >= ihi:
                new.append(s); continue
            if xlo < ilo:
                ns = _make_sub(s, xlo, ilo)
                if ns: new.append(ns)
            if ihi < xhi:
                ns = _make_sub(s, ihi, xhi)
                if ns: new.append(ns)
        self.spans = new
        self._update_bbox()

    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                top_dom=False, bot_dom=False):
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W, hi + 1)
        if ilo >= ihi: return
        new = []
        for s in self.spans:
            xlo, xhi = s[0], s[1]
            if xhi <= ilo or xlo >= ihi:
                new.append(s); continue
            ox0 = max(xlo, ilo); ox1 = min(xhi, ihi)
            if ox0 < ox1:
                old_tl = _interp(ox0, xlo, s[2], xhi, s[4])
                old_tr = _interp(ox1, xlo, s[2], xhi, s[4])
                old_bl = _interp(ox0, xlo, s[3], xhi, s[5])
                old_br = _interp(ox1, xlo, s[3], xhi, s[5])
                new_tl = _interp(ox0, sx1, yt1, sx2, yt2)
                new_tr = _interp(ox1, sx1, yt1, sx2, yt2)
                new_bl = _interp(ox0, sx1, yb1, sx2, yb2)
                new_br = _interp(ox1, sx1, yb1, sx2, yb2)
                if (new_tl <= old_tl and new_tr <= old_tr and
                        new_bl >= old_bl and new_br >= old_br):
                    new.append(s); continue
            if xlo < ilo:
                ns = _make_sub(s, xlo, ilo)
                if ns: new.append(ns)
            right_s = _make_sub(s, ihi, xhi) if ihi < xhi else None
            if ox0 < ox1:
                _tighten_span(s, ox0, ox1, sx1, sx2, yt1, yt2,
                              yb1, yb2, new)
            if right_s: new.append(right_s)
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
                if x_hi < bx0 or x_lo >= bx1 or y_hi < bt or y_lo > bb:
                    if _line_cost is not None: _line_cost['bbox_rej'] += 1
                    if stats is not None: stats[3] += 1
                    continue
            elif not self.spans:
                if stats is not None: stats[3] += 1
                continue

            if abs(lx1 - lx2) < 1:
                ix = lx1
                for s in self.spans:
                    xlo, xhi = s[0], s[1]
                    if xlo <= ix < xhi:
                        top_y = _interp_ceil(ix, xlo, s[2], xhi, s[4])  # ceil: never above boundary
                        bot_y = _interp(ix, xlo, s[3], xhi, s[5])       # floor: never below boundary
                        if top_y >= bot_y: break
                        cy1 = max(min(ly1, ly2), top_y)
                        cy2 = min(max(ly1, ly2), bot_y)
                        if cy1 <= cy2:
                            pygame.draw.line(surface, _rand_color(),
                                             (ix, cy1), (ix, cy2), 1)
                            drawn = True
                        break
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
                for si, s in enumerate(self.spans):
                    if s[1] <= xl or s[0] >= xr:
                        continue

                    ot = min(s[2], s[4])
                    ob = max(s[3], s[5])

                    if seg_start is None:
                        if y_hi < ot or y_lo > ob:
                            if cost is not None: cost['outer_rej'] += 1
                            continue
                        it = max(s[2], s[4])
                        ib = min(s[3], s[5])
                        if y_lo >= it and y_hi <= ib:
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
                    if si + 1 < len(self.spans) and self.spans[si + 1][0] == s[1]:
                        ns = self.spans[si + 1]
                        if ns[0] < xr:
                            next_s = ns

                    if next_s is not None:
                        px = s[1]
                        pt = max(s[4], next_s[2])
                        pb = min(s[5], next_s[3])
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
                        seg_start = None
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

def _make_sub(s, new_xlo, new_xhi):
    """Extract sub-span [new_xlo, new_xhi) from span s.
    Uses round-to-nearest for boundary Y (no systematic bias)."""
    if new_xlo >= new_xhi: return None
    xlo, xhi, tl, bl, tr, br = s
    return (new_xlo, new_xhi,
            _interp_store(new_xlo, xlo, tl, xhi, tr),
            _interp_store(new_xlo, xlo, bl, xhi, br),
            _interp_store(new_xhi, xlo, tl, xhi, tr),
            _interp_store(new_xhi, xlo, bl, xhi, br))


def _tighten_span(s, ox0, ox1, sx1, sx2, yt1, yt2, yb1, yb2, out):
    """Tighten span s over [ox0, ox1). All Y values are pixels."""
    xlo, xhi, tl, bl, tr, br = s
    old_tl = _interp(ox0, xlo, tl, xhi, tr)
    old_bl = _interp(ox0, xlo, bl, xhi, br)
    old_tr = _interp(ox1, xlo, tl, xhi, tr)
    old_br = _interp(ox1, xlo, bl, xhi, br)
    new_tl = _interp(ox0, sx1, yt1, sx2, yt2)
    new_bl = _interp(ox0, sx1, yb1, sx2, yb2)
    new_tr = _interp(ox1, sx1, yt1, sx2, yt2)
    new_br = _interp(ox1, sx1, yb1, sx2, yb2)

    splits = [ox0]
    dt0 = old_tl - new_tl; dt1 = old_tr - new_tr
    if dt0 != dt1 and ((dt0 >= 0) != (dt1 >= 0)):
        cx = _crossover_x(ox0, ox1, dt0, dt1)
        if cx is not None: splits.append(cx)
    db0 = old_bl - new_bl; db1 = old_br - new_br
    if db0 != db1 and ((db0 >= 0) != (db1 >= 0)):
        cx = _crossover_x(ox0, ox1, db0, db1)
        if cx is not None: splits.append(cx)
    splits.append(ox1)
    splits.sort()

    for i in range(len(splits) - 1):
        sx_lo, sx_hi = splits[i], splits[i + 1]
        if sx_lo >= sx_hi: continue
        ot_l = _interp_store(sx_lo, xlo, tl, xhi, tr)
        ob_l = _interp_store(sx_lo, xlo, bl, xhi, br)
        ot_r = _interp_store(sx_hi, xlo, tl, xhi, tr)
        ob_r = _interp_store(sx_hi, xlo, bl, xhi, br)
        nt_l = _interp_store(sx_lo, sx1, yt1, sx2, yt2)
        nb_l = _interp_store(sx_lo, sx1, yb1, sx2, yb2)
        nt_r = _interp_store(sx_hi, sx1, yt1, sx2, yt2)
        nb_r = _interp_store(sx_hi, sx1, yb1, sx2, yb2)
        rt_l = max(ot_l, nt_l); rb_l = min(ob_l, nb_l)
        rt_r = max(ot_r, nt_r); rb_r = min(ob_r, nb_r)
        if rt_l < rb_l or rt_r < rb_r:
            out.append((sx_lo, sx_hi, rt_l, rb_l, rt_r, rb_r))


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
    """Clip line to span. Span Y in pixels. Line Y via real division."""
    from clip_math import boundary_ix
    xlo, xhi, tl, bl, tr, br = s
    dx = lx2 - lx1
    dy = ly2 - ly1
    ex = xhi - xlo
    if ex <= 0:
        return None

    cx1, cy1, cx2, cy2 = lx1, ly1, lx2, ly2

    # -- Clip to X range [xlo, xhi-1] --
    if dx == 0:
        if lx1 < xlo or lx1 >= xhi:
            return None
    else:
        if (dx > 0 and cx1 < xlo) or (dx < 0 and cx2 < xlo):
            y_at = _line_y(ly1, dy, dx, xlo, lx1)
            if dx > 0:
                cx1, cy1 = xlo, y_at
            else:
                cx2, cy2 = xlo, y_at
        xhi_clip = xhi - 1
        if (dx > 0 and cx2 > xhi_clip) or (dx < 0 and cx1 > xhi_clip):
            y_at = _line_y(ly1, dy, dx, xhi_clip, lx1)
            if dx > 0:
                cx2, cy2 = xhi_clip, y_at
            else:
                cx1, cy1 = xhi_clip, y_at
        if min(cx1, cx2) >= xhi or max(cx1, cx2) < xlo:
            return None

    # -- Evaluate boundaries at clipped X endpoints --
    # Top: ceiling (never above boundary).  Bot: floor (never below).
    top1 = _interp_ceil(cx1, xlo, tl, xhi, tr)
    top2 = _interp_ceil(cx2, xlo, tl, xhi, tr)
    bot1 = _interp(cx1, xlo, bl, xhi, br)
    bot2 = _interp(cx2, xlo, bl, xhi, br)

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
            bot1 = _interp(ix, xlo, bl, xhi, br)
        else:
            bot2 = _interp(ix, xlo, bl, xhi, br)

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
