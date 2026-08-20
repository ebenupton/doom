"""clip_ref — the SIMPLE clipper truth model (Eben, 2026-08-20).

Two primitives, nothing else:
  draw_line(l, sense)  draw a portal edge, return its visible fragments,
                       then the FULL line becomes a clip authority for
                       every future line — over its whole x extent,
                       including columns where it was itself hidden or
                       off-screen.  sense='top' occludes everything
                       ABOVE the line (y < yl); 'bot' everything BELOW.
  mark_solid(x0, x1)   occlude the HALF-OPEN column range completely
                       (a 'top' authority at y=+inf, exactly as the
                       original one-sided model did it).

Screen bounds are part of visibility (x in [0,256), y in [0,160)) but
NOT of authority: a line's clip authority is pure geometry.

Intervals are HALF-OPEN ([x0, x1) — the original sketch's convention,
restored by decree 2026-08-20): a chain of connected lines
[a,m) [m,b) ... gives EVERY column exactly one claiming authority.
That single-ownership tiling is the design point of this model. (The
engine's tighten is the mirror tiling, (lo, hi] — joint column to the
LEFT seg — and its mark_solid is closed on both ends; those seams are
exactly what the differential harness probes.)

Interpolation matches the engine's interp_store rounding (half away
from zero on |dy|) so the oracle can be compared EXACTLY against the
python clipper reference; y values are conceptually unbounded ints.
"""

SCREEN_W, SCREEN_H = 256, 160
SOLID_Y = 10**6


def interp(x, x0, y0, x1, y1):
    """interp_store rounding: |offset|,|den|,|dy| with +den//2."""
    if x1 == x0:
        return y0
    offset, den = x - x0, x1 - x0
    if den < 0:
        offset, den = -offset, -den
    if y1 >= y0:
        return y0 + (offset * (y1 - y0) + den // 2) // den
    return y0 - (offset * (y0 - y1) + den // 2) // den


class line:
    def __init__(self, x0, y0, x1, y1, sense='top'):
        assert x0 < x1
        self.x0, self.y0, self.x1, self.y1 = x0, y0, x1, y1
        self.sense = sense                  # 'top' | 'bot'

    def eval(self, x):
        if self.x0 <= x < self.x1:
            return interp(x, self.x0, self.y0, self.x1, self.y1)
        return None

    def __repr__(self):
        return (f"({self.x0},{self.y0})->({self.x1},{self.y1})"
                f"[{self.sense}]")


class ClipRef:
    def __init__(self):
        self.lines = []

    def inside(self, x, y):
        if not (0 <= x < SCREEN_W and 0 <= y < SCREEN_H):
            return False
        for l in self.lines:
            yl = l.eval(x)
            if yl is None:
                continue
            if l.sense == 'top':
                if y < yl:
                    return False            # above a top edge: hidden
            else:
                if y > yl:
                    return False            # below a bottom edge: hidden
        return True

    def draw_line(self, l):
        """Visible fragments of l, then l joins the authority list."""
        output = []
        start = None
        for x in range(l.x0, l.x1):
            y = l.eval(x)
            if self.inside(x, y):
                if start is None:
                    start = (x, y)
            else:
                if start is not None:
                    output.append((*start, x, y))
                    start = None
        if start is not None:
            output.append((*start, l.x1, l.y1))
        self.lines.append(l)
        return output

    def mark_solid(self, x0, x1):
        if x0 < x1:
            self.lines.append(line(x0, SOLID_Y, x1, SOLID_Y, 'top'))

    # -- state queries for the differential harness ----------------------
    def aperture(self, x):
        """(top, bot) inclusive visible band at column x, or None if the
        column is fully occluded.  Screen bounds included."""
        top, bot = 0, SCREEN_H - 1
        for l in self.lines:
            yl = l.eval(x)
            if yl is None:
                continue
            if l.sense == 'top':
                top = max(top, yl)
            else:
                bot = min(bot, yl)
        return None if top > bot else (top, bot)


if __name__ == '__main__':
    c = ClipRef()
    c.mark_solid(2, 4)
    print(c.draw_line(line(0, 20, 10, 30, 'top')))
    print(c.draw_line(line(0, 25, 15, 25, 'top')))
    print(c.draw_line(line(0, 100, 20, 80, 'bot')))
    print([c.aperture(x) for x in range(0, 12)])
