"""Integer-endpoint flat-span visibility for the DOOM wireframe renderer.

Each span is (xlo, xhi, yt_lo, yb_lo, yt_hi, yb_hi) — six u8 values
defining a trapezoid with linear top/bottom boundaries between integer
Y endpoints.  Drop-in replacement for FPClipSpans.

Eliminates slope quantisation and crossover-division rounding by storing
exact integer Y values at span boundaries.
"""

import random
import pygame
from fp import FP_RENDER_W, FP_RENDER_H


def _rand_color():
    return (random.randint(60, 255), random.randint(60, 255), random.randint(60, 255))


def _interp(x, x0, y0, x1, y1):
    """Integer linear interpolation with round-to-nearest."""
    if x1 == x0:
        return y0
    num = (y1 - y0) * (x - x0)
    den = x1 - x0
    if (num < 0) != (den < 0):
        return y0 + (num - den // 2) // den
    return y0 + (num + den // 2) // den


class EndpointClipSpans:
    """Visibility spans using integer pixel endpoints.

    self.spans is a list of (xlo, xhi, yt_lo, yb_lo, yt_hi, yb_hi) tuples
    sorted by xlo, non-overlapping.  The boundary between xlo and xhi is:
      top: line from (xlo, yt_lo) to (xhi, yt_hi)
      bot: line from (xlo, yb_lo) to (xhi, yb_hi)
    Interval is [xlo, xhi).
    """

    __slots__ = ("spans",)

    def __init__(self):
        self.spans = [(0, FP_RENDER_W, 0, FP_RENDER_H - 1, 0, FP_RENDER_H - 1)]

    # -- Queries ---------------------------------------------------------------

    def is_full(self):
        return not self.spans

    def has_gap(self, lo, hi):
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W - 1, hi)
        for s in self.spans:
            xlo, xhi = s[0], s[1]
            if xlo > ihi:
                break
            if xhi <= ilo:
                continue
            it = max(s[2], s[4])  # inner_top
            ib = min(s[3], s[5])  # inner_bot
            if it < ib:
                return True
        return False

    def line_survives(self, lx1, ly1, lx2, ly2):
        if abs(lx1 - lx2) < 1:
            return False
        xl, xr = min(lx1, lx2), max(lx1, lx2)
        y_lo, y_hi = min(ly1, ly2), max(ly1, ly2)
        found = False
        for s in self.spans:
            if s[1] <= xl or s[0] >= xr:
                continue
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
        if ilo >= ihi:
            return
        new = []
        for s in self.spans:
            xlo, xhi, tl, bl, tr, br = s
            if xhi <= ilo or xlo >= ihi:
                new.append(s)
                continue
            if xlo < ilo:
                ns = _make_sub(s, xlo, ilo)
                if ns:
                    new.append(ns)
            if ihi < xhi:
                ns = _make_sub(s, ihi, xhi)
                if ns:
                    new.append(ns)
        self.spans = new

    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                top_dom=False, bot_dom=False):
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W, hi + 1)
        if ilo >= ihi:
            return
        new = []
        for s in self.spans:
            xlo, xhi = s[0], s[1]
            if xhi <= ilo or xlo >= ihi:
                new.append(s)
                continue
            # Left fragment
            if xlo < ilo:
                ns = _make_sub(s, xlo, ilo)
                if ns:
                    new.append(ns)
            # Right fragment
            right_s = _make_sub(s, ihi, xhi) if ihi < xhi else None
            # Overlap region
            ox0 = max(xlo, ilo)
            ox1 = min(xhi, ihi)
            if ox0 < ox1:
                _tighten_span(s, ox0, ox1, sx1, sx2, yt1, yt2, yb1, yb2, new)
            if right_s:
                new.append(right_s)
        self.spans = new

    # -- Clipping --------------------------------------------------------------

    def draw_clipped(self, lines, color, surface, stats=None):
        for lx1, ly1, lx2, ly2 in lines:
            if stats is not None:
                stats[0] += 1
            drawn = False

            if abs(lx1 - lx2) < 1:
                # Vertical
                ix = lx1
                for s in self.spans:
                    xlo, xhi = s[0], s[1]
                    if xlo <= ix < xhi:
                        top_y = _interp(ix, xlo, s[2], xhi, s[4])
                        bot_y = _interp(ix, xlo, s[3], xhi, s[5])
                        if top_y >= bot_y:
                            break
                        cy1 = max(min(ly1, ly2), top_y)
                        cy2 = min(max(ly1, ly2), bot_y)
                        if cy1 <= cy2:
                            pygame.draw.line(surface, _rand_color(),
                                             (ix, cy1), (ix, cy2), 1)
                            drawn = True
                        break
            else:
                # Non-vertical: portal walk across contiguous spans
                if lx1 <= lx2:
                    xl, yl, xr, yr = lx1, ly1, lx2, ly2
                else:
                    xl, yl, xr, yr = lx2, ly2, lx1, ly1
                dx_line = xr - xl
                y_lo = min(yl, yr)
                y_hi = max(yl, yr)

                def _line_y_at(x):
                    if dx_line == 0:
                        return yl
                    return yl + (yr - yl) * (x - xl) // dx_line

                # Collect overlapping spans
                active = []
                for s in self.spans:
                    if s[1] > xl and s[0] < xr:
                        active.append(s)

                if not active:
                    if stats is not None:
                        stats[3] += 1
                    continue

                # Group contiguous spans
                groups = [[active[0]]]
                for i in range(1, len(active)):
                    if active[i - 1][1] == active[i][0]:
                        groups[-1].append(active[i])
                    else:
                        groups.append([active[i]])

                for group in groups:
                    if len(group) == 1:
                        s = group[0]
                        # Outer bbox reject
                        ot = min(s[2], s[4])
                        ob = max(s[3], s[5])
                        if y_hi < ot or y_lo > ob:
                            continue
                        # Inner bbox accept
                        it = max(s[2], s[4])
                        ib = min(s[3], s[5])
                        if y_lo >= it and y_hi <= ib:
                            ex = max(xl, s[0])
                            xx = min(xr, s[1] - 1)
                            eyl = _line_y_at(ex) if ex != xl else yl
                            eyr = _line_y_at(xx) if xx != xr else yr
                            eyl = max(0, min(FP_RENDER_H - 1, eyl))
                            eyr = max(0, min(FP_RENDER_H - 1, eyr))
                            pygame.draw.line(surface, _rand_color(),
                                             (ex, eyl), (xx, eyr), 1)
                            drawn = True
                            continue
                        c = _clip_to_span(lx1, ly1, lx2, ly2, s)
                        if c:
                            pygame.draw.line(surface, _rand_color(),
                                             (c[0], c[1]), (c[2], c[3]), 1)
                            drawn = True
                        continue

                    # Multi-span group: scan for first/last visible
                    c_first = c_last = None
                    fi = li = -1
                    for i, s in enumerate(group):
                        c = _clip_to_span(lx1, ly1, lx2, ly2, s)
                        if c:
                            if fi < 0:
                                fi = i
                                c_first = c
                            li = i
                            c_last = c

                    if fi < 0:
                        continue
                    if fi == li:
                        pygame.draw.line(surface, _rand_color(),
                                         (c_first[0], c_first[1]),
                                         (c_first[2], c_first[3]), 1)
                        drawn = True
                        continue

                    # Portal walk
                    portals_ok = True
                    for i in range(fi, li):
                        s_cur = group[i]
                        s_nxt = group[i + 1]
                        px = s_cur[1]  # boundary X
                        pt = max(s_cur[4], s_nxt[2])  # max of tops
                        pb = min(s_cur[5], s_nxt[3])  # min of bots
                        if pt >= pb:
                            portals_ok = False
                            break
                        ly = _line_y_at(px)
                        if ly < pt or ly > pb:
                            portals_ok = False
                            break

                    if portals_ok:
                        pygame.draw.line(surface, _rand_color(),
                                         (c_first[0], c_first[1]),
                                         (c_last[2], c_last[3]), 1)
                        drawn = True
                    else:
                        for i in range(fi, li + 1):
                            c = _clip_to_span(lx1, ly1, lx2, ly2, group[i])
                            if c:
                                pygame.draw.line(surface, _rand_color(),
                                                 (c[0], c[1]), (c[2], c[3]), 1)
                                drawn = True

            if not drawn and stats is not None:
                stats[3] += 1


# -- Helpers -------------------------------------------------------------------

def _make_sub(s, new_xlo, new_xhi):
    """Extract sub-span [new_xlo, new_xhi) from span s by interpolation."""
    if new_xlo >= new_xhi:
        return None
    xlo, xhi, tl, bl, tr, br = s
    ntl = _interp(new_xlo, xlo, tl, xhi, tr)       # top: floor (generous)
    nbl = _interp(new_xlo, xlo, bl, xhi, br)   # bot: ceil (generous)
    ntr = _interp(new_xhi, xlo, tl, xhi, tr)
    nbr = _interp(new_xhi, xlo, bl, xhi, br)
    return (new_xlo, new_xhi, ntl, nbl, ntr, nbr)


def _tighten_span(s, ox0, ox1, sx1, sx2, yt1, yt2, yb1, yb2, out):
    """Tighten span s over [ox0, ox1) with new boundary, append results to out."""
    xlo, xhi, tl, bl, tr, br = s
    # Old boundary Y at overlap endpoints
    old_tl = _interp(ox0, xlo, tl, xhi, tr)
    old_bl = _interp(ox0, xlo, bl, xhi, br)
    old_tr = _interp(ox1, xlo, tl, xhi, tr)
    old_br = _interp(ox1, xlo, bl, xhi, br)
    # New boundary Y at overlap endpoints
    new_tl = _interp(ox0, sx1, yt1, sx2, yt2)
    new_bl = _interp(ox0, sx1, yb1, sx2, yb2)
    new_tr = _interp(ox1, sx1, yt1, sx2, yt2)
    new_br = _interp(ox1, sx1, yb1, sx2, yb2)

    # Check for crossovers and collect split X positions
    splits = [ox0]
    # Top crossover
    dt0 = old_tl - new_tl
    dt1 = old_tr - new_tr
    if dt0 != dt1 and ((dt0 >= 0) != (dt1 >= 0)):
        denom = dt0 - dt1
        if denom != 0:
            cx = ox0 + dt0 * (ox1 - ox0) // denom
            if ox0 < cx < ox1:
                splits.append(cx)
    # Bot crossover
    db0 = old_bl - new_bl
    db1 = old_br - new_br
    if db0 != db1 and ((db0 >= 0) != (db1 >= 0)):
        denom = db0 - db1
        if denom != 0:
            cx = ox0 + db0 * (ox1 - ox0) // denom
            if ox0 < cx < ox1:
                splits.append(cx)
    splits.append(ox1)
    splits.sort()

    # Emit sub-spans for each split interval
    for i in range(len(splits) - 1):
        sx_lo, sx_hi = splits[i], splits[i + 1]
        if sx_lo >= sx_hi:
            continue
        ot_l = _interp(sx_lo, xlo, tl, xhi, tr)
        ob_l = _interp(sx_lo, xlo, bl, xhi, br)
        ot_r = _interp(sx_hi, xlo, tl, xhi, tr)
        ob_r = _interp(sx_hi, xlo, bl, xhi, br)
        nt_l = _interp(sx_lo, sx1, yt1, sx2, yt2)
        nb_l = _interp(sx_lo, sx1, yb1, sx2, yb2)
        nt_r = _interp(sx_hi, sx1, yt1, sx2, yt2)
        nb_r = _interp(sx_hi, sx1, yb1, sx2, yb2)
        rt_l = max(ot_l, nt_l)
        rb_l = min(ob_l, nb_l)
        rt_r = max(ot_r, nt_r)
        rb_r = min(ob_r, nb_r)
        # Check aperture exists
        if rt_l < rb_l or rt_r < rb_r:
            out.append((sx_lo, sx_hi, rt_l, rb_l, rt_r, rb_r))


def _clip_to_span(lx1, ly1, lx2, ly2, s):
    """Cyrus-Beck clip of line to span using cross-product form."""
    xlo, xhi, tl, bl, tr, br = s
    dx = lx2 - lx1
    dy = ly2 - ly1
    T_ONE = 256
    t0, t1 = 0, T_ONE

    # LEFT
    r = _cb_update(-dx, lx1 - xlo, t0, t1)
    if r is None: return None
    t0, t1 = r

    # RIGHT
    r = _cb_update(dx, xhi - lx1, t0, t1)
    if r is None: return None
    t0, t1 = r

    # TOP: cross product, outward normal convention
    ex = xhi - xlo
    ey_t = tr - tl
    p = ey_t * dx - ex * dy
    q = ex * (ly1 - tl) - ey_t * (lx1 - xlo)
    r = _cb_update(p, q, t0, t1)
    if r is None: return None
    t0, t1 = r

    # BOT
    ey_b = br - bl
    p = ex * dy - ey_b * dx
    q = ey_b * (lx1 - xlo) - ex * (ly1 - bl)
    r = _cb_update(p, q, t0, t1)
    if r is None: return None
    t0, t1 = r

    if t0 > t1:
        return None

    if t0 == 0:
        cx1, cy1 = lx1, ly1
    else:
        cx1 = lx1 + (t0 * dx) // T_ONE
        cy1 = ly1 + (t0 * dy) // T_ONE
    if t1 == T_ONE:
        cx2, cy2 = lx2, ly2
    else:
        cx2 = lx1 + (t1 * dx) // T_ONE
        cy2 = ly1 + (t1 * dy) // T_ONE

    if cx1 < xlo: cx1 = xlo
    if cx2 >= xhi: cx2 = xhi - 1
    if cx1 > cx2: return None

    cy1 = max(0, min(FP_RENDER_H - 1, cy1))
    cy2 = max(0, min(FP_RENDER_H - 1, cy2))
    return (cx1, cy1, cx2, cy2)


def _cb_update(p, q, t0, t1):
    """Cyrus-Beck constraint update."""
    if abs(p) < 1:
        if q < -1:
            return None
        return (t0, t1)
    r = q * 256
    if (r < 0) != (p < 0):
        t = -(abs(r) // abs(p))
    else:
        t = abs(r) // abs(p)
    if p < 0:
        if t > t1: return None
        if t > t0: t0 = t
    else:
        if t < t0: return None
        if t < t1: t1 = t
    return (t0, t1)
