"""Integer-endpoint flat-span visibility for the DOOM wireframe renderer.

Each span is (xlo, xhi, yt_lo, yb_lo, yt_hi, yb_hi) where X values are
u8 pixels and Y values are s16 in 8.8 fixed point (256 = 1 pixel).
This eliminates cumulative rounding drift from tighten's min/max ratchet
by pushing quantisation to sub-pixel level.

Drop-in replacement for FPClipSpans.
"""

import random
import pygame
from fp import FP_RENDER_W, FP_RENDER_H

# 8.8 fixed point: 256 units = 1 pixel
Y_SHIFT = 8
Y_ONE = 1 << Y_SHIFT  # 256


def _rand_color():
    return (random.randint(60, 255), random.randint(60, 255), random.randint(60, 255))


def _y(pixel):
    """Convert pixel Y to 8.8 fixed point."""
    return pixel << Y_SHIFT


def _px(y88):
    """Convert 8.8 Y to pixel (round to nearest)."""
    return (y88 + (Y_ONE >> 1)) >> Y_SHIFT


def _interp(x, x0, y0, x1, y1):
    """Interpolate 8.8 Y values at integer X. No rounding loss for Y."""
    if x1 == x0:
        return y0
    return y0 + (y1 - y0) * (x - x0) // (x1 - x0)


class EndpointClipSpans:
    """Visibility spans with 8.8 fixed-point Y boundaries.

    self.spans: list of (xlo, xhi, yt_lo, yb_lo, yt_hi, yb_hi)
      xlo, xhi: u8 pixel X coords, interval [xlo, xhi)
      yt_*, yb_*: s16 in 8.8 format (256 = 1 pixel)
    """

    __slots__ = ("spans",)

    def __init__(self):
        self.spans = [(0, FP_RENDER_W, _y(0), _y(FP_RENDER_H - 1),
                       _y(0), _y(FP_RENDER_H - 1))]

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
        y_lo, y_hi = _y(min(ly1, ly2)), _y(max(ly1, ly2))
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

    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                top_dom=False, bot_dom=False):
        ilo = max(0, lo)
        ihi = min(FP_RENDER_W, hi + 1)
        if ilo >= ihi: return
        # Convert new boundary pixel Y to 8.8
        yt1_88 = _y(yt1); yt2_88 = _y(yt2)
        yb1_88 = _y(yb1); yb2_88 = _y(yb2)
        new = []
        for s in self.spans:
            xlo, xhi = s[0], s[1]
            if xhi <= ilo or xlo >= ihi:
                new.append(s); continue
            ox0 = max(xlo, ilo); ox1 = min(xhi, ihi)
            # Old dominates: new boundary less restrictive → skip
            if ox0 < ox1:
                old_tl = _interp(ox0, xlo, s[2], xhi, s[4])
                old_tr = _interp(ox1, xlo, s[2], xhi, s[4])
                old_bl = _interp(ox0, xlo, s[3], xhi, s[5])
                old_br = _interp(ox1, xlo, s[3], xhi, s[5])
                new_tl = _interp(ox0, sx1, yt1_88, sx2, yt2_88)
                new_tr = _interp(ox1, sx1, yt1_88, sx2, yt2_88)
                new_bl = _interp(ox0, sx1, yb1_88, sx2, yb2_88)
                new_br = _interp(ox1, sx1, yb1_88, sx2, yb2_88)
                if (new_tl <= old_tl and new_tr <= old_tr and
                        new_bl >= old_bl and new_br >= old_br):
                    new.append(s); continue
            if xlo < ilo:
                ns = _make_sub(s, xlo, ilo)
                if ns: new.append(ns)
            right_s = _make_sub(s, ihi, xhi) if ihi < xhi else None
            if ox0 < ox1:
                _tighten_span(s, ox0, ox1, sx1, sx2, yt1_88, yt2_88,
                              yb1_88, yb2_88, new)
            if right_s: new.append(right_s)
        self.spans = new

    # -- Clipping --------------------------------------------------------------

    def draw_clipped(self, lines, color, surface, stats=None):
        for lx1, ly1, lx2, ly2 in lines:
            if stats is not None: stats[0] += 1
            drawn = False

            if abs(lx1 - lx2) < 1:
                ix = lx1
                for s in self.spans:
                    xlo, xhi = s[0], s[1]
                    if xlo <= ix < xhi:
                        top_88 = _interp(ix, xlo, s[2], xhi, s[4])
                        bot_88 = _interp(ix, xlo, s[3], xhi, s[5])
                        top_y = _px(top_88)
                        bot_y = _px(bot_88)
                        if top_y >= bot_y: break
                        cy1 = max(min(ly1, ly2), top_y)
                        cy2 = min(max(ly1, ly2), bot_y)
                        if cy1 <= cy2:
                            pygame.draw.line(surface, _rand_color(),
                                             (ix, cy1), (ix, cy2), 1)
                            drawn = True
                        break
            else:
                # Pre-clip line X to [0, 255] (wide math, once per line)
                from clip_math import preclip_line_x, frac08, line_y_narrow
                pc = preclip_line_x(lx1, ly1, lx2, ly2)
                if pc is None:
                    if stats is not None: stats[3] += 1
                    continue
                lx1, ly1, lx2, ly2 = pc

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
                    f = frac08(x - xl, dx_line)
                    return line_y_narrow(yl, dy_line, f)

                active = [s for s in self.spans if s[1] > xl and s[0] < xr]
                if not active:
                    if stats is not None: stats[3] += 1
                    continue

                groups = [[active[0]]]
                for i in range(1, len(active)):
                    if active[i-1][1] == active[i][0]:
                        groups[-1].append(active[i])
                    else:
                        groups.append([active[i]])

                for group in groups:
                    if len(group) == 1:
                        s = group[0]
                        ot = min(_px(s[2]), _px(s[4]))
                        ob = max(_px(s[3]), _px(s[5]))
                        if y_hi < ot or y_lo > ob: continue
                        it = max(_px(s[2]), _px(s[4]))
                        ib = min(_px(s[3]), _px(s[5]))
                        if y_lo >= it and y_hi <= ib:
                            ex = max(xl, s[0])
                            xx = min(xr, s[1] - 1)
                            eyl = _line_y_at(ex) if ex != xl else yl
                            eyr = _line_y_at(xx) if xx != xr else yr
                            eyl = max(0, min(FP_RENDER_H-1, eyl))
                            eyr = max(0, min(FP_RENDER_H-1, eyr))
                            pygame.draw.line(surface, _rand_color(),
                                             (ex, eyl), (xx, eyr), 1)
                            drawn = True; continue
                        c = _clip_to_span(lx1, ly1, lx2, ly2, s)
                        if c:
                            pygame.draw.line(surface, _rand_color(),
                                             (c[0], c[1]), (c[2], c[3]), 1)
                            drawn = True
                        continue

                    c_first = c_last = None; fi = li = -1
                    for i, s in enumerate(group):
                        c = _clip_to_span(lx1, ly1, lx2, ly2, s)
                        if c:
                            if fi < 0: fi = i; c_first = c
                            li = i; c_last = c
                    if fi < 0: continue
                    if fi == li:
                        pygame.draw.line(surface, _rand_color(),
                                         (c_first[0], c_first[1]),
                                         (c_first[2], c_first[3]), 1)
                        drawn = True; continue

                    portals_ok = True
                    for i in range(fi, li):
                        s_cur, s_nxt = group[i], group[i+1]
                        px = s_cur[1]
                        pt = _px(max(s_cur[4], s_nxt[2]))
                        pb = _px(min(s_cur[5], s_nxt[3]))
                        if pt >= pb: portals_ok = False; break
                        ly = _line_y_at(px)
                        if ly < pt or ly > pb: portals_ok = False; break

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
    """Extract sub-span [new_xlo, new_xhi) from span s. Y in 8.8."""
    if new_xlo >= new_xhi: return None
    xlo, xhi, tl, bl, tr, br = s
    return (new_xlo, new_xhi,
            _interp(new_xlo, xlo, tl, xhi, tr),
            _interp(new_xlo, xlo, bl, xhi, br),
            _interp(new_xhi, xlo, tl, xhi, tr),
            _interp(new_xhi, xlo, bl, xhi, br))


def _tighten_span(s, ox0, ox1, sx1, sx2, yt1, yt2, yb1, yb2, out):
    """Tighten span s over [ox0, ox1). All Y values in 8.8."""
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
    # Top crossover
    dt0 = old_tl - new_tl; dt1 = old_tr - new_tr
    if dt0 != dt1 and ((dt0 >= 0) != (dt1 >= 0)):
        denom = dt0 - dt1
        if denom != 0:
            cx = ox0 + dt0 * (ox1 - ox0) // denom
            if ox0 < cx < ox1: splits.append(cx)
    # Bot crossover
    db0 = old_bl - new_bl; db1 = old_br - new_br
    if db0 != db1 and ((db0 >= 0) != (db1 >= 0)):
        denom = db0 - db1
        if denom != 0:
            cx = ox0 + db0 * (ox1 - ox0) // denom
            if ox0 < cx < ox1: splits.append(cx)
    splits.append(ox1)
    splits.sort()

    for i in range(len(splits) - 1):
        sx_lo, sx_hi = splits[i], splits[i + 1]
        if sx_lo >= sx_hi: continue
        ot_l = _interp(sx_lo, xlo, tl, xhi, tr)
        ob_l = _interp(sx_lo, xlo, bl, xhi, br)
        ot_r = _interp(sx_hi, xlo, tl, xhi, tr)
        ob_r = _interp(sx_hi, xlo, bl, xhi, br)
        nt_l = _interp(sx_lo, sx1, yt1, sx2, yt2)
        nb_l = _interp(sx_lo, sx1, yb1, sx2, yb2)
        nt_r = _interp(sx_hi, sx1, yt1, sx2, yt2)
        nb_r = _interp(sx_hi, sx1, yb1, sx2, yb2)
        rt_l = max(ot_l, nt_l); rb_l = min(ob_l, nb_l)
        rt_r = max(ot_r, nt_r); rb_r = min(ob_r, nb_r)
        if rt_l < rb_l or rt_r < rb_r:
            out.append((sx_lo, sx_hi, rt_l, rb_l, rt_r, rb_r))


def _clip_to_span(lx1, ly1, lx2, ly2, s):
    """Clip line to span. All multiplies are 8x8 (via clip_math primitives).

    Line coords are pixels (pre-clipped to X [0,255]).
    Span Y values are 8.8 fixed point (s16).
    """
    from clip_math import (frac08, eval_boundary_88, line_y_narrow,
                           compare_y_vs_boundary, boundary_ix)
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
        abs_dx = abs(dx)
        if (dx > 0 and cx1 < xlo) or (dx < 0 and cx2 < xlo):
            f = frac08(abs(xlo - lx1), abs_dx)
            y_at = line_y_narrow(ly1, dy, f)
            if dx > 0:
                cx1, cy1 = xlo, y_at
            else:
                cx2, cy2 = xlo, y_at
        xhi_clip = xhi - 1
        if (dx > 0 and cx2 > xhi_clip) or (dx < 0 and cx1 > xhi_clip):
            f = frac08(abs(xhi_clip - lx1), abs_dx)
            y_at = line_y_narrow(ly1, dy, f)
            if dx > 0:
                cx2, cy2 = xhi_clip, y_at
            else:
                cx1, cy1 = xhi_clip, y_at
        if min(cx1, cx2) >= xhi or max(cx1, cx2) < xlo:
            return None

    # -- Evaluate boundaries at clipped X endpoints --
    f1 = frac08(abs(cx1 - xlo), ex)
    f2 = frac08(abs(cx2 - xlo), ex)
    top1 = eval_boundary_88(tl, tr, f1)
    top2 = eval_boundary_88(tl, tr, f2)
    bot1 = eval_boundary_88(bl, br, f1)
    bot2 = eval_boundary_88(bl, br, f2)

    # -- Clip to top boundary (cy >= top) --
    above1 = compare_y_vs_boundary(cy1, top1) < 0
    above2 = compare_y_vs_boundary(cy2, top2) < 0
    if above1 and above2:
        return None
    if above1 or above2:
        d1 = _y(cy1) - top1
        d2 = _y(cy2) - top2
        ix = boundary_ix(cx1, cx2, d1, d2)
        if ix is None:
            return None
        if dx != 0:
            f = frac08(abs(ix - lx1), abs(dx))
            iy = line_y_narrow(ly1, dy, f)
        else:
            iy = ly1
        if above1:
            cx1, cy1 = ix, iy
        else:
            cx2, cy2 = ix, iy
        # Recompute boundary at new endpoint for bot clip
        fnew = frac08(abs(ix - xlo), ex)
        if above1:
            bot1 = eval_boundary_88(bl, br, fnew)
        else:
            bot2 = eval_boundary_88(bl, br, fnew)

    # -- Clip to bottom boundary (cy <= bot) --
    below1 = compare_y_vs_boundary(cy1, bot1) > 0
    below2 = compare_y_vs_boundary(cy2, bot2) > 0
    if below1 and below2:
        return None
    if below1 or below2:
        d1 = _y(cy1) - bot1
        d2 = _y(cy2) - bot2
        ix = boundary_ix(cx1, cx2, d1, d2)
        if ix is None:
            return None
        if dx != 0:
            f = frac08(abs(ix - lx1), abs(dx))
            iy = line_y_narrow(ly1, dy, f)
        else:
            iy = ly1
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
