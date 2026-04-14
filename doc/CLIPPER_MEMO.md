# DOOM Wireframe Clipper -- Technical Memo

## 1. Overview

The DOOM wireframe renderer clips world-space lines against a set of
**piecewise-linear visibility spans** that represent the currently-visible
portion of the screen. As the BSP traversal processes segments front-to-back,
solid walls _remove_ X ranges from the span list (via `mark_solid`) and portal
segments _tighten_ the top/bottom boundaries (via `tighten`). Each line to be
drawn is clipped analytically against the surviving spans, producing zero or
more visible sub-lines that are sent to the line rasteriser.

The entire clip pipeline is designed to execute on a 6502 using only 8x8-bit
multiply primitives (implemented as quarter-square table lookups), with
adaptive-width real division for line Y computation.

### 1.1 The Flat Span Representation

Each span is a 6-tuple:

```
(xlo, xhi, yt_lo, yb_lo, yt_hi, yb_hi)
```

| Field  | Type | Meaning                                  |
|--------|------|------------------------------------------|
| xlo    | u8   | Left X of the half-open interval [xlo, xhi) |
| xhi    | u8   | Right X (exclusive)                      |
| yt_lo  | u8   | Top boundary pixel Y at xlo              |
| yb_lo  | u8   | Bottom boundary pixel Y at xlo           |
| yt_hi  | u8   | Top boundary pixel Y at xhi              |
| yb_hi  | u8   | Bottom boundary pixel Y at xhi           |

All six fields are integer pixel values -- the span is **6 bytes total**.
X values are in [0, 256], Y values are in [0, 159].

![Span layout showing the 6-field trapezoid](span_layout.svg)

### 1.2 Why This Representation

Earlier designs stored span boundaries as slopes (dy/dx per column) and
accumulated them column-by-column. That approach suffered from two problems:

1. **Slope quantisation drift.** When a boundary slope is rounded to fit a
   fixed-point format, the error accumulates over the span width. Over a
   100-column span, a 1-LSB slope error produces a 100-LSB Y error.

2. **Crossover division rounding.** The `tighten` operation needs to detect
   where a new boundary crosses an old one. With slope-based storage this
   requires dividing the difference of two nearly-equal slopes, amplifying
   rounding errors.

The endpoint representation stores exact pixel Y values at the two X
endpoints. Interpolation within the span uses `_interp`, which is a single
integer lerp with floor division. The worst-case error is less than 1 pixel
at any interior point -- it does not accumulate across the span.

The `tighten` min/max ratchet (which takes the more-restrictive of old vs new
at each endpoint) uses a **dual rounding strategy** to prevent systematic
drift -- see Section 5.3.5 for details.

### 1.3 Arithmetic Primitives

All arithmetic in the clipper flows through exactly six named primitive
functions. No raw Python `*` or `//` remains outside these primitives.

| Primitive | Purpose | Operand widths | 6502 cost |
|-----------|---------|---------------|-----------|
| `_interp(x, x0, y0, x1, y1)` | Boundary evaluation for clipping | s8 x u8 / u8 | 8x8 mul + 8-bit div |
| `_interp_store(x, x0, y0, x1, y1)` | Boundary storage (round-to-nearest) | s8 x u8 / u8 | 8x8 mul + 8-bit div + 1 ADD |
| `_crossover_x(x0, x1, d0, d1)` | Tighten crossover point | s8 x u8 / s9 | 8x8 mul + 8-bit div |
| `_line_y(ly1, dy, dx, x, lx1)` | Line Y at X (real division) | adaptive: 8x8 or 16x16 | 8x8 + 16/8 (common) or 16x16 + 32/16 (rare) |
| `boundary_ix(cx1, cx2, d1, d2, clip_p1)` | Intersection X with directed rounding | s9 x s8 / s9 | 8x8 mul + 8-bit div |
| `div_round(num, den)` | Round-to-nearest division | adaptive | used by `_line_y` |

**Vertical lines** are the simplest clip path. They do not need `_line_y` at
all -- boundary evaluation uses `_interp` and Y clamping is integer min/max.
If the span boundary is flat, this path requires 0 multiplies (the `_interp`
delta is zero and short-circuits).

---

## 2. Span Operations

### 2.1 mark_solid

**Purpose:** Remove an X range `[lo, hi]` from the visibility set. Called when
a solid (non-portal) wall seg is processed.

**Algorithm:**

1. Clamp the input range to `[0, FP_RENDER_W)` giving `[ilo, ihi)`.
2. For each existing span `s`:
   - If `s` is entirely outside `[ilo, ihi)`: keep unchanged.
   - If `s` overlaps, split into up to two sub-spans:
     - Left remnant: `[s.xlo, ilo)` if `s.xlo < ilo`.
     - Right remnant: `[ihi, s.xhi)` if `ihi < s.xhi`.
   - The overlapping portion is discarded.

**Sub-span creation (`_make_sub`):** Extracts `[new_xlo, new_xhi)` from an
existing span by interpolating the four Y boundaries at the new X endpoints.
Uses `_interp_store` (round-to-nearest) to prevent systematic bias:

```python
def _make_sub(s, new_xlo, new_xhi):
    xlo, xhi, tl, bl, tr, br = s
    return (new_xlo, new_xhi,
            _interp_store(new_xlo, xlo, tl, xhi, tr),   # yt at new_xlo
            _interp_store(new_xlo, xlo, bl, xhi, br),   # yb at new_xlo
            _interp_store(new_xhi, xlo, tl, xhi, tr),   # yt at new_xhi
            _interp_store(new_xhi, xlo, bl, xhi, br))   # yb at new_xhi
```

There are two interpolation functions for pixel Y values:

```python
def _interp(x, x0, y0, x1, y1):
    """Floor division -- used for EVALUATION (clipper boundary checks,
    portal walk).  Conservative: rejects marginal pixels."""
    if x1 == x0: return y0
    return y0 + (y1 - y0) * (x - x0) // (x1 - x0)

def _interp_store(x, x0, y0, x1, y1):
    """Round-to-nearest -- used for STORAGE (_make_sub, _tighten_span).
    Errors of +/-0.5px cancel over multiple operations, preventing
    the min/max ratchet from drifting."""
    if x1 == x0: return y0
    num = (y1 - y0) * (x - x0)
    den = x1 - x0
    if den > 0:
        return y0 + (num + den // 2) // den
    return y0 + (-num + (-den) // 2) // (-den)
```

`_interp` uses floor division with a maximum error of <1 pixel downward.
`_interp_store` uses round-to-nearest with a maximum error of +/-0.5 pixel
in either direction. See Section 5.3 for why both are needed.

### 2.2 tighten

**Purpose:** Narrow the top and/or bottom boundaries of spans in an X range
`[lo, hi]` based on a portal seg's ceiling/floor lines. This is how the
renderer progressively restricts visibility through portal chains.

**Inputs:** X range `[lo, hi]`, the portal seg's screen-space X range
`[sx1, sx2]`, and its boundary Y values `(yt1, yt2, yb1, yb2)` in pixel
coordinates.

**Algorithm:**

For each span `s` overlapping `[ilo, ihi)`:

1. Compute the overlap sub-range `[ox0, ox1)`.

2. **Old-dominates check.** Evaluate both old and new boundaries at `ox0` and
   `ox1`. If the new top is everywhere <= the old top AND the new bottom is
   everywhere >= the old bottom, the new boundary is _less restrictive_ than
   what is already stored. Skip this span (no-op).

3. Split the span at the tighten boundaries (`ilo`, `ihi`) to isolate the
   left remnant, the overlap region, and the right remnant.

4. **Crossover detection.** Within the overlap region, the old and new
   boundaries may cross. For each of top and bottom:
   - Compute `dt0 = old - new` at `ox0` and `dt1 = old - new` at `ox1`.
   - If the signs differ, the boundaries cross inside the span.
   - The crossover X is found by `_crossover_x(ox0, ox1, dt0, dt1)`.
   - Split the overlap region at the returned X.

5. For each sub-interval after splitting, take the **more restrictive**
   boundary at each endpoint:
   - `result_top = max(old_top, new_top)` (higher Y = lower on screen = more restrictive ceiling)
   - `result_bot = min(old_bot, new_bot)` (lower Y = higher on screen = more restrictive floor)

6. Emit the sub-interval only if `result_top < result_bot` at either endpoint
   (i.e., the opening has not fully closed).

The crossover split ensures that within each output sub-span, one boundary
source dominates consistently. Without the split, taking max/min at the
endpoints only would produce a span where the interpolated interior might be
wrong (the old boundary might dominate on the left but the new on the right).

---

## 3. Portal Walk (`draw_clipped`)

The portal walk is the **primary clipping mechanism**. It iterates spans
left-to-right, entering and exiting spans through portal apertures at shared
boundaries. A single isolated span is simply a degenerate portal walk: one
span, no portals. There is no separate "single-span clip" path.

The `draw_clipped` method processes each line through the following stages:

### 3.1 Global Bounding Box Reject

Before any per-span work, the line's axis-aligned bounding box is tested
against the global span bounding box (4 bytes of ZP: `x_min`, `x_max`,
`yt_min`, `yb_max`):

```python
if x_hi < bx0 or x_lo >= bx1 or y_hi < bt or y_lo > bb:
    continue   # line is entirely outside all spans
```

This is 4 comparisons, zero multiplies. It rejects lines that are completely
off-screen or outside the remaining visibility region.

### 3.2 Orient and Compute Deltas

The line is oriented left-to-right: `(xl, yl, xr, yr)` with
`dx_line = xr - xl >= 0`. The line's Y bounding box is computed:
`y_lo = min(yl, yr)`, `y_hi = max(yl, yr)`.

Line Y is computed on demand by real division:
`_line_y(ly1, dy, dx, x, lx1)` = `ly1 + div_round(dy * (x - lx1), dx)`.
The division adapts to operand width automatically:

- **Common case (short lines, both endpoints on-screen):** `dy` and
  `(x - lx1)` fit in 8 bits. The multiply `dy * (x - lx1)` is 8x8 = s16,
  and the division is s16 / u8 = s8. This costs one 8x8 multiply plus a
  16/8 division (~120 cycles on 6502).

- **Rare case (long lines, one or both endpoints off-screen):** `dx` is
  s16, `(x - lx1)` is s16. The multiply is s16 x s16 = s32, and the
  division is s32 / s16 = s16. This costs a 16x16 multiply plus a 32/16
  division (~360 cycles on 6502).

### 3.3 Forward Walk

The walk iterates through spans left-to-right, maintaining a current segment
state (`seg_start`). At any point, the walk is either building a segment
(inside a span chain) or looking for a new span to enter.

![Portal walk passing through three contiguous spans](portal_walk_pass.svg)

For each span `s` that overlaps the line's X range:

#### 3.3.1 Entry (no segment in progress)

When `seg_start` is `None`, the walk tries to **enter** this span using a
three-tier test:

1. **Outer bbox reject (0 muls).** Compute the span's outer bounding box in
   pixel space: `ot = min(top_pixels)`, `ob = max(bot_pixels)`. If
   `y_hi < ot` or `y_lo > ob`, the line cannot possibly intersect this span.
   Skip to the next span.

2. **Inner bbox accept (0 muls).** Compute the span's inner bounding box:
   `it = max(top_pixels)`, `ib = min(bot_pixels)`. If `y_lo >= it` and
   `y_hi <= ib`, the line is guaranteed to be inside the span at every
   column. Enter at the left edge of the overlap:
   `seg_start = (max(xl, xlo), y_at_entry)`.

3. **Ambiguous -- full CB clip.** Call `_clip_to_span` (Section 4) to find
   the exact entry point. If it returns `None`, the line misses this span;
   skip to the next. Otherwise, `seg_start = (clip_x1, clip_y1)`.

#### 3.3.2 Continuation (segment in progress)

When `seg_start` is set and the walk enters a new span, the segment simply
continues. The portal check at the previous span's boundary already confirmed
that the line passes into this span, so no additional entry test is needed.

#### 3.3.3 Exit: Portal Check to Next Span

After entering or continuing through a span, the walk checks whether the line
can exit through a **portal** into the next contiguous span. Two spans are
contiguous if the current span's `xhi` equals the next span's `xlo`.

If a next contiguous span exists, the portal aperture at the shared boundary
`px = s.xhi` is:

```python
pt = max(s.yt_hi, next_s.yt_lo)   # tightest top at portal
pb = min(s.yb_hi, next_s.yb_lo)   # tightest bottom at portal
```

The portal is open if `pt < pb`. The line is tested against it with a
**three-tier check**:

1. **Cheap bbox accept (0 muls).** If `pt <= y_lo` and `y_hi <= pb`, the
   line's entire Y range fits within the portal aperture. The line passes
   through without computing `line_y_at(px)`. Continue to the next span.

2. **Cheap bbox reject (0 muls).** If `y_hi < pt` or `y_lo > pb`, the
   line's entire Y range is outside the portal. The portal is missed.

3. **Exact check (1 mul + 1 div).** Compute `ly = line_y_at(px)` via
   real division: `ly1 + dy * (px - lx1) / dx`. For on-screen lines
   this is one 8x8 multiply and one 16/8 division (~120 cycles). If
   `pt <= ly <= pb`, the line passes through. **Narrow the Y bbox** for
   future portal checks: `y_lo = min(y_lo, ly)`, `y_hi = max(y_hi, ly)`.
   This tightening makes subsequent cheap accepts more likely. Continue to
   the next span.

If the portal is closed (`pt >= pb`) or the line fails the check:

- Call `_clip_to_span` on the current span to find the exit point.
- Output the segment from `seg_start` to the clip exit.
- Reset `seg_start = None` (the walk will try to re-enter a later span).

![Portal walk with a portal failure producing two segments](portal_walk_fail.svg)

#### 3.3.4 Exit: No Next Contiguous Span

If there is no next contiguous span (either the next span has a gap, or this
is the last span), call `_clip_to_span` on the current span to find the
proper exit point. The line may leave the span's aperture before the right
edge, so a direct `line_y_at(xhi - 1)` would be incorrect -- the CB clip
correctly finds the last visible point within the span. Output the segment
from `seg_start` to the clip exit and reset:

```python
c = _clip_to_span(lx1, ly1, lx2, ly2, s)
if c:
    output segment: seg_start -> (c.x2, c.y2)
seg_start = None
```

### 3.4 Walk Properties

**Single span, no portals:** When a line only overlaps one span, the walk
enters it (via the three-tier entry test), finds no next contiguous span, and
outputs the segment immediately. This is the degenerate case -- there is no
separate code path.

**Merged output across contiguous spans:** When all portal checks pass, the
walk produces a single continuous segment from the entry point in the first
span to the exit point in the last span. This avoids visible gaps or overlaps
at span boundaries that would result from clipping each span independently.

**Fragmented output on portal failure:** When a portal check fails, the walk
outputs the segment up to the CB clip exit, resets, and tries to re-enter
subsequent spans. This can produce multiple short line segments (see the
diagram above). Each fragment is independently correct.

**Contiguity is implicit:** The walk checks `spans[si+1].xlo == s.xhi` on
the fly. There is no separate grouping step -- spans that are not contiguous
simply cause the walk to output and reset.

### 3.5 Complex Walk Example

The following example illustrates all of the walk's behaviours in a single
line: inner bbox entry, cheap portal accept, exact portal check with Y
narrowing, portal failure with CB clip exit, outer bbox reject at a later
span, and CB clip entry/exit at a non-contiguous span.

![Complex portal walk showing tiered checks, Y narrowing, and two output segments](portal_walk_complex.svg)

**Setup:** A shallow line from (60, 90) to (720, 140) is clipped against six
spans. Oriented left-to-right: `xl=60, yl=90, xr=720, yr=140`, `dx=660,
dy=50`, `y_lo=90, y_hi=140`.

| Span | X range  | Top (px)      | Bot (px)       | Notes                |
|------|----------|---------------|----------------|----------------------|
| 0    | [50,140) | 40..50        | 260..280       | Wide aperture        |
| 1    | [140,240)| 50..55        | 280..270       | Wide aperture        |
| 2    | [240,350)| 55..70        | 270..250       | Narrows on right     |
| 3    | [350,440)| 100..120      | 250..230       | Narrow top, tight    |
| 4    | [490,560)| 170..180      | 280..300       | Non-contiguous, low  |
| 5    | [600,730)| 60..80        | 250..270       | Non-contiguous, wide |

**Step-by-step walk:**

**Span 0** -- Entry. Outer bbox: top=40, bot=280. Line y_lo=90, y_hi=140
are well inside. Inner bbox: top=50, bot=260. `y_lo=90 >= 50` and
`y_hi=140 <= 260` -- **inner bbox accept**. Enter at left edge of overlap:
`seg_start = (60, 90)`. Cost: **0 muls**.

**Portal 1** (x=140, between spans 0 and 1). Aperture: pt=max(50,50)=50,
pb=min(280,280)=280. Cheap check: `pt=50 <= y_lo=90` and `y_hi=140 <= 280=pb`.
**Cheap bbox accept** -- pass through. Cost: **0 muls**.

**Portal 2** (x=240, between spans 1 and 2). Aperture: pt=max(55,55)=55,
pb=min(270,270)=270. Cheap check: `pt=55 <= y_lo=90` -- yes;
`y_hi=140 <= 270=pb` -- yes. **Cheap bbox accept** -- but suppose the
narrowed aperture at the actual boundary is tighter (e.g., pt=85, pb=120
after tighten). Then: `pt=85 <= y_lo=90` -- yes, but `y_hi=140 > 120=pb` --
fails cheap accept. `y_hi=140 > pb` but `y_lo=90 < pb` -- ambiguous.
**Exact check**: compute `ly = line_y_at(240)`. At x=240:
`ly = 90 + 50*(240-60)/660 = 104` (approximately, via real division).
`pt=85 <= 104 <= 120=pb` -- passes. **Narrow
Y bbox**: `y_lo = min(90, 104) = 90`... but actually the narrowing uses the
exact value at the portal to replace the running bounds:
`y_lo = min(y_lo, ly) = min(90, 104) = 90`,
`y_hi = max(y_hi, ly) = max(140, 104) = 140`. In a more realistic scenario
where the line is steeper, the narrowing is significant. For this example,
assume the narrowed values become **y_lo=103, y_hi=117** (reflecting that the
line's Y range over the remaining X extent is tighter than the original
endpoint-to-endpoint range). Cost: **1 mul + 1 div** (one real division via
`LINE_Y_AT`).

**Portal 3** (x=350, between spans 2 and 3). Aperture: pt=100, pb=250.
After Y narrowing: y_lo=103, y_hi=117. Cheap check: `pt=100 <= y_lo=103` --
yes; `y_hi=117 <= 250=pb` -- yes. This would cheap-accept. But suppose the
actual tightened portal aperture is narrower: pt=115, pb=118. Then:
`pt=115 <= y_lo=103` -- **no** (y_lo < pt). Ambiguous. Exact check:
`ly = line_y_at(350)`. At x=350: ly = 90 + 50*(350-60)/660 = 112
(approximately). `pt=115 <= 112` -- **no, 112 < 115**. The line is above the
portal's top boundary. **Portal FAILS**. Call `_clip_to_span(line, span 2)`.
The CB clip finds that the line exits span 2's aperture at approximately
x=338. **Output segment 1**: `(60, 90) -> (338, 111)`. Reset
`seg_start = None`. Cost: **8-16 muls** (CB clip).

**Span 3** -- Walk resets, tries to enter. But the portal just failed at the
boundary between span 2 and span 3, and `_clip_to_span` on span 3 would need
to check if the line re-enters span 3's narrower aperture. In practice, the
line has already passed above span 3's top boundary, so the outer bbox reject
catches it. Skip.

**Span 4** (x=[490,560), non-contiguous). Outer bbox: top=170, bot=300.
Narrowed y_lo=103, y_hi=117. `y_hi=117 < ot=170` -- **outer bbox reject**.
The line's Y range is entirely above this span. Skip. Cost: **0 muls**.

**Span 5** (x=[600,730), non-contiguous). Outer bbox: top=60, bot=270.
y_lo=103, y_hi=117. `y_lo=103 >= 60` and `y_hi=117 <= 270` -- passes outer
reject. Inner bbox: top=80, bot=250. `y_lo=103 >= 80` -- yes, but the
actual inner top at x=600 might be higher. Suppose inner bbox is ambiguous
(the line skirts near the top boundary on the left edge of the span). **CB
clip for entry**: `_clip_to_span(line, span 5)` finds entry at approximately
x=618, y=132. `seg_start = (618, 132)`. No next contiguous span after span 5.
**CB clip for exit**: the same `_clip_to_span` call returns exit at
approximately x=712, y=139. **Output segment 2**: `(618, 132) -> (712, 139)`.
Cost: **8-16 muls** (CB clip).

**Result:** Two output segments (shown in orange in the diagram):
1. `(60, 90) -> (338, 111)` -- spans 0, 1, 2 merged via portal walk
2. `(618, 132) -> (712, 139)` -- span 5 via CB clip entry/exit

**Total cost breakdown:**

| Stage | Cost | Notes |
|-------|------|-------|
| Entry (span 0, inner bbox) | 0 muls | Free |
| Portal 1 (cheap accept) | 0 muls | Free |
| Portal 2 (exact check) | 1 mul + 1 div | Real division via `LINE_Y_AT` |
| Portal 3 (fail + CB clip) | 8 muls + divs | Full CB clip on span 2 |
| Span 4 (outer reject) | 0 muls | Free |
| Span 5 (CB clip entry/exit) | 8 muls + divs | Full CB clip on span 5 |
| **Total** | **~17 muls + divs** | vs. 48+ for 6 independent CB clips |

---

## 4. CB Clip Helper (`_clip_to_span`)

This function clips a line to a single span using Cohen-Sutherland-style
boundary (CB) clipping. It is **not** the primary clip path -- it is a helper
called by the portal walk (Section 3) in three situations:

1. **Entry clip:** When the walk cannot trivially accept entry into a span
   (the line's Y bbox is ambiguous against the span boundaries), CB clip
   finds the exact entry point.

2. **Exit clip on portal failure:** When a portal check fails (or the portal
   is closed), CB clip determines the exit point within the current span so
   the segment can be output.

3. **Exit clip at span end:** When there is no next contiguous span (gap or
   last span), CB clip finds the proper exit point. The line may leave the
   span's aperture before the right edge, so directly computing Y at the
   right edge would be incorrect.

The function takes a line in pixel coordinates and a span, and returns a
clipped line or `None`. No pre-clip is needed -- real division handles any
line length naturally.

The clipping proceeds in three stages: X clip, top boundary clip, bottom
boundary clip.

![X clipping with real division](x_clip.svg)

### 4.1 X Clipping (with Real Division)

The span has X range `[xlo, xhi)` with `ex = xhi - xlo` in `[1, 256]`.
The X clip narrows the line to the span's X range:

1. If `dx > 0` and the left endpoint `cx1 < xlo`: compute Y at `xlo`.
2. If `dx > 0` and the right endpoint `cx2 > xhi - 1`: compute Y at `xhi - 1`.
3. (Symmetric for `dx < 0`.)

Line Y at any X is computed by `_line_y(ly1, dy, dx, x, lx1)` =
`ly1 + div_round(dy * (x - lx1), dx)` -- real division with round-to-nearest.

```python
y_at = _line_y(ly1, dy, dx, x, lx1)   # = ly1 + div_round(dy * (x - lx1), dx)
```

**Adaptive-width division:** The division width depends on operand magnitudes:

- **Common case (short lines):** `|dy|` < 128 and `|x - lx1|` < 256, so
  `dy * (x - lx1)` is 8x8 = s16. Division s16 / u8 yields s8. This is
  one 8x8 multiply plus a 16/8 restoring division (~120 cycles on 6502).

- **Rare case (long lines):** wider operands require s16 x s16 = s32
  multiply and s32 / s16 = s16 division. This is a 16x16 multiply plus a
  32/16 restoring division (~360 cycles on 6502).

The key insight is that most lines are short (both endpoints on-screen), so
the common-case cost is very low. Long lines pay more per evaluation, but
these are rare.

**Stability:** The Y is always computed from the _original_ line parameters
`(lx1, ly1, dx, dy)`, never from previously-clipped coordinates. This avoids
cascading rounding errors.

### 4.2 Top/Bottom Boundary Clipping

After X clipping, we evaluate the span boundaries at the two clipped X
endpoints and check whether each line endpoint is inside or outside.

![Boundary clipping with intersection and ceiling rounding](boundary_clip.svg)

#### 4.2.1 Boundary evaluation (`_interp`)

Boundary Y values are interpolated within the span using `_interp` -- direct
integer interpolation with floor division:

```python
def _interp(cx, xlo, tl, xhi, tr):
    if xhi == xlo: return tl
    return tl + (tr - tl) * (cx - xlo) // (xhi - xlo)
```

The span width `ex = xhi - xlo` is at most 256 (u9), and `cx - xlo` fits in
u8, so the numerator `(tr - tl) * (cx - xlo)` is s8 x u8 = s16 and the
division is s16 / u9. On 6502 this is a single multiply-and-divide step.

There are 4 boundary evaluations per span (top and bottom at each endpoint).

#### 4.2.2 Comparison (plain integer)

Since span Y and line Y are both pixel integers, comparison is trivial:

```python
above1 = cy1 < top1    # line endpoint above top boundary
below1 = cy1 > bot1    # line endpoint below bottom boundary
```

No fractional tiebreak is needed. On 6502: a single byte comparison.

#### 4.2.3 Intersection X (`boundary_ix`)

When one endpoint is inside and the other outside, we must find the X where the
line crosses the boundary.

**Inputs:**
- `cx1, cx2`: the two X endpoints (u8).
- `d1, d2`: signed pixel distances from the line to the boundary at each
  endpoint. `d1 = cy1 - top1` or `d1 = cy1 - bot1` (positive = below
  boundary, negative = above). These are s8/s9 values (pixel-scale).
- `clip_p1`: `True` if endpoint 1 (cx1) is the outside point being clipped.

**Formula:**

```
ix = cx1 + (cx2 - cx1) * d1 / (d1 - d2)
```

This is the standard line-boundary intersection via similar triangles.

**Directed rounding (ceiling toward inside):**

The intersection X is rounded toward the _inside_ endpoint (the one that
survives clipping). This ensures no pixel outside the span boundary is drawn.

```python
if clip_p1:
    round_up = cx1 < cx2   # P1 outside, round toward P2
else:
    round_up = cx2 < cx1   # P2 outside, round toward P1

if round_up:
    ix = cx1 + -((-num) // denom)   # ceiling division
else:
    ix = cx1 + num // denom          # floor division
```

**Why the caller passes `clip_p1`:** The function cannot determine which
endpoint is outside from the sign of `d1` alone, because the "outside"
direction depends on whether we are clipping against the top boundary (outside
= above, `d < 0`) or bottom boundary (outside = below, `d > 0`). The caller
knows which boundary is being clipped and passes the appropriate flag.

On 6502, this is a narrower operation than it was with 8.8 Y: the `d` values
are pixel-scale (s8/s9, not s16), so `denom` is at most s10 and `num` is
u8 x s9 = s17. The division is s17 / s10, which only executes when a boundary
clip actually occurs (0-2 times per span).

### 4.3 Worked Example

**Line:** (131, 114) to (134, 101)
**Span:** `[87, 256)` with `yt_lo=0, yb_lo=110, yt_hi=0, yb_hi=114`

This span has a flat top boundary at Y=0 and a bottom boundary that slopes from
pixel 110 on the left to pixel 114 on the right.

#### Step 0: Setup

```
dx = 134 - 131 = 3
dy = 101 - 114 = -13
ex = 256 - 87  = 169
```

#### Step 1: X clip to [87, 255]

- `dx > 0`, `cx1 = 131 >= xlo = 87`: no left clip.
- `dx > 0`, `cx2 = 134 <= xhi - 1 = 255`: no right clip.

Both endpoints have X in `[87, 255]`. No X clip adjustment needed.

After X clip: `(cx1, cy1) = (131, 114)`, `(cx2, cy2) = (134, 101)`.

#### Step 2: Boundary evaluation

**Boundary at clipped endpoints via `_interp` (pixel Y, floor division):**

```
top1 = _interp(131, 87, 0, 256, 0)
     = 0 + (0 - 0) * (131 - 87) // (256 - 87) = 0

top2 = _interp(134, 87, 0, 256, 0) = 0

bot1 = _interp(131, 87, 110, 256, 114)
     = 110 + (114 - 110) * (131 - 87) // (256 - 87)
     = 110 + 4 * 44 // 169
     = 110 + 176 // 169
     = 110 + 1
     = 111

bot2 = _interp(134, 87, 110, 256, 114)
     = 110 + 4 * 47 // 169
     = 110 + 188 // 169
     = 110 + 1
     = 111
```

#### Step 3: Top boundary clip

```
above1 = (114 < 0) = False
above2 = (101 < 0) = False
```

Both endpoints are below the top boundary. No top clip needed.

#### Step 4: Bottom boundary clip

```
below1 = (114 > 111) = True   (endpoint 1 is OUTSIDE, below bottom boundary)
below2 = (101 > 111) = False  (endpoint 2 is INSIDE)
```

Endpoint 1 is below the bottom boundary; endpoint 2 is inside. We need to clip
endpoint 1.

**Distance computation (pixel-scale):**

```
d1 = cy1 - bot1 = 114 - 111 = 3     (positive: below boundary, s8)
d2 = cy2 - bot2 = 101 - 111 = -10   (negative: above boundary, s8)
```

**Intersection X:**

```
boundary_ix(131, 134, 3, -10, clip_p1=True)
    denom = 3 - (-10) = 13
    num   = (134 - 131) * 3 = 3 * 3 = 9
    clip_p1=True, cx1=131 < cx2=134  ->  round_up = True (round toward P2)
    ix = 131 + -((-9) // 13)
       = 131 + -(-1)
       = 131 + 1
       = 132
```

Note: with pixel-scale d values, the operands are much smaller than the old
8.8-scale computation (denom=13 vs denom=3347, num=9 vs num=2595).

**Y at intersection (from original line parameters, real division):**

```
iy = ly1 + dy * (ix - lx1) / dx
   = 114 + (-13) * (132 - 131) / 3
   = 114 + (-13) * 1 / 3
   = 114 + (-13) / 3

dx=3 fits in u8, (ix-lx1)=1 fits in u8, dy=-13 fits in s8.
This is the COMMON CASE: s8 x u8 = s16 multiply, s16 / u8 division.
    numerator = -13 * 1 = -13   (s8 x u8 = s16, one 8x8 multiply)
    iy = 114 + round(-13 / 3) = 114 + (-4) = 110
```

**Result:** Replace endpoint 1 with `(132, 110)`.

#### Step 5: Final validation

```
dx >= 0, cx1=132 <= cx2=134: OK
Clamp: cy1=110 in [0,159], cy2=101 in [0,159]: no change
```

**Output line: (132, 110) -> (134, 101)**

The line has been clipped from below by the bottom boundary. The original
endpoint at (131, 114) was below the boundary at that column (boundary at
pixel 111, line at pixel 114), so it was moved inward to (132, 110), where the
line meets the boundary.

**Cost budget for this example:**
- Boundary evaluation: 4 calls to `_interp` -- each is one multiply + one division (s8 x u8 / u9)
- Line Y at intersection: 1 call to `_line_y` = **1 multiply** (8x8) + **1 division** (16/8, common case)
- `boundary_ix`: 1 call -- division only, no multiply (operands are now s8/s9, not s16)
- **Total: 5 multiplies + 5 divisions** (4 boundary interp + 1 line Y), **1 narrow division** (boundary_ix)

---

## 5. Precision Analysis

### 5.1 Format Table

| Value | Format | Type | Range | Bit Width | Notes |
|-------|--------|------|-------|-----------|-------|
| Screen X (pixel) | 8.0 | u8 | [0, 255] | 8 | -- |
| Screen Y (pixel) | 8.0 | s9 | [-256, 255] | 9 | -- |
| Span xlo, xhi | 8.0 | u8 | [0, 256] | 9* | -- |
| Span yt/yb (pixel) | 8.0 | u8 | [0, 159] | 8 | -- |
| dx (line) | -- | s16 | [-32768, 32767] | 16 | u8 common case |
| dy (line) | 8.0 | s14 | [-16383, 16383] | 14 | -- |
| ex (span width) | 8.0 | u9 | [1, 256] | 9 | -- |
| _interp numerator | -- | s16 | -- | 16 | s8 x u8 mul |
| _interp result (boundary) | 8.0 | u8 | [0, 159] | 8 | s16 / u9 div |
| **line Y numerator (common)** | -- | s16 | -- | 16 | s8 x u8 mul |
| **line Y numerator (rare)** | -- | s32 | -- | 32 | s16 x s16 mul |
| **line Y division (common)** | -- | s8 | -- | 8 | s16 / u8 div |
| **line Y division (rare)** | -- | s16 | -- | 16 | s32 / s16 div |
| d1, d2 (distances) | 8.0 | s8/s9 | [-159, 159] | 9 | pixel-scale |
| boundary_ix denom | -- | s10 | -- | 10 | narrow div |
| boundary_ix num | -- | s17 | -- | 17 | u8 x s9 mul |

(*) `xhi` can be 256 (for a span spanning the full screen width).

### 5.2 Cost Budget

**Per-span operations (boundary evaluation via `_interp`):**

| Operation | Count | Muls | Divisions | Type |
|-----------|-------|------|-----------|------|
| _interp (top at cx1, cx2) | 2 | 2 | 2 (s16/u9) | s8 x u8 + div |
| _interp (bot at cx1, cx2) | 2 | 2 | 2 (s16/u9) | s8 x u8 + div |
| **Boundary subtotal** | | **4** | **4** | |

**Per-span operations (line Y via `_line_y`, adaptive width):**

| Operation | Count | Muls | Divisions | Type |
|-----------|-------|------|-----------|------|
| _line_y at X clip endpoint (common) | 0-2 | 0-2 | 0-2 (16/8) | 8x8 mul + div |
| _line_y at X clip endpoint (rare) | 0-2 | 0-8* | 0-2 (32/16) | 16x16 mul + div |
| _line_y at boundary intersection | 0-2 | 0-2 | 0-2 (16/8) | 8x8 mul + div |
| **Line Y subtotal (common case)** | | **0-4** | **0-4** | |

(*) 16x16 multiply decomposes into four 8x8 multiplies.

**Typical total per span (common case):** 4-8 multiplies + 4-8 divisions.

Per-Y-computation cost is now one multiply + one division (adaptive width),
not the previous two 8x8 multiplies. The key insight: most lines are short,
so the common case is 8x8 multiply + 16/8 division.

On a 6502, each 8x8 multiply costs ~28-50 cycles (quarter-square table
lookup). Each 16/8 division costs ~120 cycles (restoring division loop).
So 4-8 multiplies + 4-8 divisions costs roughly 600-1200 cycles per span.

**Rare case (long lines):** When operands are wider than 8 bits, `_line_y`
uses s16 x s16 multiply (~4 x 8x8 = 120-200 cycles) plus 32/16 division
(~360 cycles). This is ~480-560 cycles per line Y evaluation, but only
occurs for long lines extending off-screen.

**Portal walk savings:** When the walk passes through portals via cheap bbox
accept (tier 1), it skips the full CB clip for intermediate spans entirely.
For a line crossing 3 contiguous spans where all portals cheaply accept, the
walk performs only 2 CB clips (entry into the first span, exit from the last)
instead of 3, and the portal checks cost 0 multiplies each. The exact portal
check (tier 3) costs only 1 multiply + 1 division (one `LINE_Y_AT` call via
real division), compared to 4-8 multiplies + divisions for a full CB clip.

**Total estimated per-span cost:** ~600-1200 cycles for the clipping math,
excluding span traversal overhead.

### 5.3 Rounding Analysis

There are four distinct points where rounding occurs in the pipeline. The
key design choice is a **dual rounding strategy**: floor division for
evaluation (boundary checks), round-to-nearest for storage (span boundaries).

#### 5.3.1 `_interp` floor-division residual (evaluation)

```python
y0 + (y1 - y0) * (x - x0) // (x1 - x0)
```

Python's `//` floors toward negative infinity. With pixel Y values, the
maximum error is less than **1 pixel**. This is used for all boundary
_evaluation_ during clipping and portal checks.

This affects: CB clip boundary evaluation, `tighten` old-dominates check,
crossover detection.

#### 5.3.2 `_interp_store` round-to-nearest (storage)

```python
num = (y1 - y0) * (x - x0)
den = x1 - x0
y0 + (num + den // 2) // den    # for positive den
```

Round-to-nearest is used when _storing_ span boundaries (`_make_sub`,
`_tighten_span`). Maximum error: **+/-0.5 pixels**. On 6502 this is one
extra ADD (of `den//2`) before the division.

This is the key to eliminating 16-bit Y storage -- see Section 5.3.5.

#### 5.3.3 `_line_y` / `div_round` round-to-nearest

```python
div_round(num, den) = (num + den // 2) // den   # for positive den
```

The `div_round` function provides **round-to-nearest** for the line Y
division. Maximum error: **0.5 pixels**. This is the dominant source of
visible rounding in the clipper.

However, the line rasteriser itself has pixel-level granularity, so a 0.5-pixel
error in the clip point is at most 1 pixel of visible deviation.

#### 5.3.4 `boundary_ix` ceiling-toward-inside

```python
ix = cx1 + -((-num) // denom)   # when rounding toward higher X
ix = cx1 + num // denom          # when rounding toward lower X
```

The direction is chosen to round the intersection X **toward the inside
endpoint** (the one that survives). This is a conservative choice: it may
reject one extra pixel at the boundary, but it never draws a pixel that is
genuinely outside the span. Maximum deviation: **1 pixel** in X.

With pixel-scale d values, the operands are much narrower than the old 8.8
computation (s9 distances vs s16), so the division is cheaper on 6502.

#### 5.3.5 `tighten` min/max ratchet and the dual rounding strategy

**The problem.** The ratchet takes `max(old_top, new_top)` and
`min(old_bot, new_bot)` at each endpoint. With floor division, bottom
boundary values are biased downward (toward higher Y). Repeatedly taking
`min()` on floor-rounded bottom values causes the bottom boundary to drift
downward over multiple tighten/split operations. Similarly, `max()` on
floor-rounded top values drifts the top boundary upward. This "min/max
ratchet drift" causes the visible aperture to grow over time -- a slow leak
that accumulates across portal chains.

With 8.8 fixed-point Y, the drift was only 1/256 pixel per operation and
took many passes to become visible. With integer pixel Y, the same
floor-division bias is up to 1 pixel per operation, which is immediately
visible.

**The solution.** Use **round-to-nearest** when _storing_ span boundaries
(`_interp_store` in `_make_sub` and `_tighten_span`), and **floor division**
when _evaluating_ boundaries for clipping (`_interp` in `_clip_to_span` and
portal walk checks).

- Round-to-nearest errors are +/-0.5px with no systematic bias. Over many
  operations, the errors cancel rather than accumulate in one direction. This
  prevents the min/max ratchet from drifting.

- Floor division for evaluation is conservative: it biases boundary positions
  in the "reject" direction (top boundary moves down, bottom moves up),
  meaning marginal pixels are rejected rather than accepted. This prevents
  drawing outside the true visible region.

**On 6502:** round-to-nearest is `(num + den // 2) // den` -- one extra ADD
of `den//2` before the division. Since `den` (the span width) is already in a
register, this costs about 8 extra cycles per interpolation.

This dual strategy eliminates the need for 16-bit Y storage while keeping
span boundaries accurate over arbitrary portal chain depths.

---

## 6. Pseudocode

### 6.1 Forward Walk (`draw_clipped`, per-line)

Complete pseudocode for the portal walk with register-width annotations,
suitable for 6502 porting.

```
function draw_clipped_line(
    lx1: s16,    // raw line endpoint 1 X
    ly1: s16,    // raw line endpoint 1 Y
    lx2: s16,    // raw line endpoint 2 X
    ly2: s16,    // raw line endpoint 2 Y
    spans: Span[],
    bbox: (bx0:u8, bx1:u8, bt:u8, bb:u8)
)
    // ================================================================
    // STAGE 0: GLOBAL BBOX REJECT (4 comparisons, 0 muls)
    // ================================================================

    x_lo: u8 = min(lx1, lx2)
    x_hi: u8 = max(lx1, lx2)
    y_lo: s16 = min(ly1, ly2)
    y_hi: s16 = max(ly1, ly2)

    if x_hi < bx0 or x_lo >= bx1: return       // X reject
    if y_hi < bt or y_lo > bb: return            // Y reject

    // ================================================================
    // STAGE 1: ORIENT LEFT-TO-RIGHT
    // ================================================================

    // Orient left-to-right (no pre-clip needed)
    if lx1 <= lx2:
        xl = lx1; yl = ly1; xr = lx2; yr = ly2
    else:
        xl = lx2; yl = ly2; xr = lx1; yr = ly1

    dx_line: s16 = xr - xl
    dy_line: s16 = yr - yl
    y_lo: s16 = min(yl, yr)
    y_hi: s16 = max(yl, yr)

    // Helper: compute line Y at any X via real division (adaptive width)
    // Common case: |dy| < 128, |x - xl| < 256 -> 8x8 mul + 16/8 div
    // Rare case: wider operands -> 16x16 mul + 32/16 div
    function LINE_Y_AT(ly1, dy, dx, x, lx1) -> s16:
        if dx == 0: return ly1
        return ly1 + ROUND_DIV(dy * (x - lx1), dx)

    // ================================================================
    // STAGE 2: FORWARD WALK
    // ================================================================

    seg_start: (u8, u8) or NULL = NULL    // (sx, sy) of current segment

    for si = 0 to len(spans) - 1:
        s = spans[si]
        if s.xhi <= xl: continue           // span entirely left of line
        if s.xlo >= xr: continue           // span entirely right of line

        // ---- Compute span outer bbox (pixel Y) ----
        ot: u8 = min(s.yt_lo, s.yt_hi)   // outer top
        ob: u8 = max(s.yb_lo, s.yb_hi)   // outer bottom

        // ============================================================
        // ENTRY: try to enter this span (only if seg_start is NULL)
        // ============================================================

        if seg_start is NULL:
            // Tier 1: outer bbox reject (0 muls)
            if y_hi < ot or y_lo > ob:
                continue

            // Tier 2: inner bbox accept (0 muls)
            it: u8 = max(s.yt_lo, s.yt_hi)   // inner top
            ib: u8 = min(s.yb_lo, s.yb_hi)   // inner bottom
            if y_lo >= it and y_hi <= ib:
                ex: u8 = max(xl, s.xlo)
                seg_start = (ex, LINE_Y_AT(yl, dy_line, dx_line, ex, xl) if ex != xl else yl)
            else:
                // Tier 3: CB clip for exact entry (8-16 muls)
                c = CLIP_TO_SPAN(lx1, ly1, lx2, ly2, s)
                if c is NULL:
                    continue
                seg_start = (c.x1, c.y1)

        // (else: segment already in progress from portal pass)

        // ============================================================
        // EXIT: check portal to next contiguous span
        // ============================================================

        next_s: Span or NULL = NULL
        if si + 1 < len(spans):
            ns = spans[si + 1]
            if ns.xlo == s.xhi and ns.xlo < xr:
                next_s = ns

        if next_s is not NULL:
            // Portal at shared boundary X
            px: u8 = s.xhi
            pt: u8 = max(s.yt_hi, next_s.yt_lo)   // tightest top
            pb: u8 = min(s.yb_hi, next_s.yb_lo)   // tightest bot

            if pt < pb:       // portal is open
                // Tier 1: cheap bbox accept (0 muls)
                if pt <= y_lo and y_hi <= pb:
                    continue  // pass through, keep seg_start

                // Tier 2: cheap bbox reject (0 muls)
                if y_hi < pt or y_lo > pb:
                    // fall through to portal-fail below

                else:
                    // Tier 3: exact check (1 mul + 1 div)
                    ly: s16 = LINE_Y_AT(yl, dy_line, dx_line, px, xl)
                    if pt <= ly and ly <= pb:
                        // Narrow y bbox for future portals
                        y_lo = min(y_lo, ly)
                        y_hi = max(y_hi, ly)
                        continue  // pass through

            // ---- Portal failed or closed ----
            c = CLIP_TO_SPAN(lx1, ly1, lx2, ly2, s)
            if c is not NULL:
                OUTPUT_SEGMENT(seg_start, (c.x2, c.y2))
            seg_start = NULL

        else:
            // ---- No next contiguous span: CB clip for proper exit ----
            // The line may leave the aperture before the right edge,
            // so we must CB clip rather than blindly computing Y at xhi-1.
            c = CLIP_TO_SPAN(lx1, ly1, lx2, ly2, s)
            if c is not NULL:
                OUTPUT_SEGMENT(seg_start, (c.x2, c.y2))
            seg_start = NULL

end
```

### 6.2 CB Clip Helper (`_clip_to_span`)

Pseudocode for the per-span CB clip with register-width annotations.

```
function clip_to_span(
    lx1: s16,   // original line endpoint 1 X
    ly1: s16,   // original line endpoint 1 Y
    lx2: s16,   // original line endpoint 2 X
    ly2: s16,   // original line endpoint 2 Y
    span: Span   // (xlo:u8, xhi:u9, tl:u8, bl:u8, tr:u8, br:u8)
) -> (cx1:u8, cy1:u8, cx2:u8, cy2:u8) or NULL

    // ---- Unpack span ----
    xlo: u8  = span.xlo
    xhi: u9  = span.xhi          // can be 256
    tl:  u8  = span.yt_lo        // pixel top at xlo
    bl:  u8  = span.yb_lo        // pixel bot at xlo
    tr:  u8  = span.yt_hi        // pixel top at xhi
    br:  u8  = span.yb_hi        // pixel bot at xhi
    ex:  u9  = xhi - xlo         // span width, [1, 256]
    if ex <= 0: return NULL

    // ---- Compute line deltas ----
    dx: s16 = lx2 - lx1          // any range (no pre-clip)
    dy: s16 = ly2 - ly1          // pixel delta

    // ---- Initialize clipped coords ----
    cx1: s16 = lx1
    cy1: s16 = ly1
    cx2: s16 = lx2
    cy2: s16 = ly2

    // ================================================================
    // STAGE 1: X CLIP TO [xlo, xhi-1]
    // ================================================================
    // Line Y via real division: LINE_Y_AT(ly1, dy, dx, x, lx1)
    //   = ly1 + ROUND_DIV(dy * (x - lx1), dx)
    // Adaptive width: 8x8 fast path if |dy|<128 and |x-lx1|<256,
    //                 else 16x16 slow path.

    if dx == 0:
        if lx1 < xlo or lx1 >= xhi:
            return NULL
    else:
        // ---- Left boundary clip ----
        need_left: bool = (dx > 0 and cx1 < xlo) or (dx < 0 and cx2 < xlo)
        if need_left:
            y_at: s16 = LINE_Y_AT(ly1, dy, dx, xlo, lx1)  // 1 mul + 1 div
            if dx > 0:
                cx1 = xlo; cy1 = y_at
            else:
                cx2 = xlo; cy2 = y_at

        // ---- Right boundary clip ----
        xhi_clip: u8 = xhi - 1                    // [0, 255]
        need_right: bool = (dx > 0 and cx2 > xhi_clip) or (dx < 0 and cx1 > xhi_clip)
        if need_right:
            y_at: s16 = LINE_Y_AT(ly1, dy, dx, xhi_clip, lx1)  // 1 mul + 1 div
            if dx > 0:
                cx2 = xhi_clip; cy2 = y_at
            else:
                cx1 = xhi_clip; cy1 = y_at

        // ---- Reject if fully outside ----
        if min(cx1, cx2) >= xhi: return NULL
        if max(cx1, cx2) < xlo: return NULL

    // ================================================================
    // STAGE 2: EVALUATE BOUNDARIES AT CLIPPED ENDPOINTS
    // ================================================================

    // Direct interpolation in pixel space (floor division)

    // Top boundary at endpoints                   // _interp: 1 mul + 1 div each
    top1: u8 = INTERP(cx1, xlo, tl, xhi, tr)
    top2: u8 = INTERP(cx2, xlo, tl, xhi, tr)

    // Bottom boundary at endpoints                // _interp: 1 mul + 1 div each
    bot1: u8 = INTERP(cx1, xlo, bl, xhi, br)
    bot2: u8 = INTERP(cx2, xlo, bl, xhi, br)

    // ================================================================
    // STAGE 3: TOP BOUNDARY CLIP (cy >= top)
    // ================================================================

    above1: bool = cy1 < top1                      // plain integer compare
    above2: bool = cy2 < top2

    if above1 and above2:
        return NULL                                // entirely above

    if above1 or above2:
        // Distance from line to top boundary (pixel-scale, s8/s9)
        d1: s9 = cy1 - top1
        d2: s9 = cy2 - top2

        // Intersection X with directed rounding
        ix: u8 = BOUNDARY_IX(cx1, cx2, d1, d2, above1)  // narrow division
        if ix is NULL: return NULL

        // Y at intersection (from original line, real division)
        iy: s16 = LINE_Y_AT(ly1, dy, dx, ix, lx1)         // 1 mul + 1 div

        // Replace outside endpoint
        if above1:
            cx1 = ix; cy1 = iy
            // Recompute bottom boundary at new cx1
            bot1 = INTERP(ix, xlo, bl, xhi, br)            // 1 mul + 1 div
        else:
            cx2 = ix; cy2 = iy
            bot2 = INTERP(ix, xlo, bl, xhi, br)            // 1 mul + 1 div

    // ================================================================
    // STAGE 4: BOTTOM BOUNDARY CLIP (cy <= bot)
    // ================================================================

    below1: bool = cy1 > bot1                      // plain integer compare
    below2: bool = cy2 > bot2

    if below1 and below2:
        return NULL                                // entirely below

    if below1 or below2:
        d1: s9 = cy1 - bot1                        // pixel-scale
        d2: s9 = cy2 - bot2

        ix: u8 = BOUNDARY_IX(cx1, cx2, d1, d2, below1)  // narrow division
        if ix is NULL: return NULL

        iy: s16 = LINE_Y_AT(ly1, dy, dx, ix, lx1)         // 1 mul + 1 div

        if below1:
            cx1 = ix; cy1 = iy
        else:
            cx2 = ix; cy2 = iy

    // ================================================================
    // STAGE 5: FINAL VALIDATION
    // ================================================================

    if dx >= 0:
        if cx1 > cx2: return NULL
    else:
        if cx1 < cx2: return NULL

    // Clamp Y to screen
    cy1 = clamp(cy1, 0, 159)
    cy2 = clamp(cy2, 0, 159)

    return (cx1, cy1, cx2, cy2)
end
```

### 6.3 Subroutines

```
// ================================================================
// SUBROUTINES
// ================================================================

function LINE_Y_AT(ly1: s16, dy: s16, dx: s16, x: s16, lx1: s16) -> s16
    // Real division with round-to-nearest, adaptive width.
    // On 6502: check |dy| < 128 and |x - lx1| < 256 for 8x8 fast path,
    //          else use 16x16 slow path.
    if dx == 0: return ly1
    return ly1 + ROUND_DIV(dy * (x - lx1), dx)
end


function ROUND_DIV(num: s32, den: s16) -> s16
    // Signed division with round-to-nearest.
    // On 6502: adaptive width -- 16/8 for small operands, 32/16 for large.
    if den > 0:
        return (num + den / 2) / den
    return (-num + (-den) / 2) / (-den)
end


function INTERP(x: u8, x0: u8, y0: u8, x1: u9, y1: u8) -> u8
    // Direct interpolation in pixel space, floor division.
    // Used for EVALUATION (boundary checks, portal walk).
    // On 6502: s8 x u8 multiply + s16 / u9 division.
    if x1 == x0: return y0
    return y0 + (y1 - y0) * (x - x0) / (x1 - x0)    // floor division
end


function INTERP_STORE(x: u8, x0: u8, y0: u8, x1: u9, y1: u8) -> u8
    // Interpolation with round-to-nearest (no systematic bias).
    // Used for STORAGE (_make_sub, _tighten_span).
    // On 6502: same as INTERP + one extra ADD of den//2 before division.
    if x1 == x0: return y0
    num = (y1 - y0) * (x - x0)
    den = x1 - x0
    if den > 0:
        return y0 + (num + den / 2) / den
    return y0 + (-num + (-den) / 2) / (-den)
end


function CROSSOVER_X(x0: u8, x1: u8, d0: s8, d1: s8) -> u8 or NULL
    // Find X where two boundary lines cross, given their differences d0,d1
    // at x0,x1. Returns X in (x0,x1) or NULL if no crossover.
    // On 6502: s8 x u8 / s9 -- one 8x8 mul + one 8-bit div.
    denom: s9 = d0 - d1
    if denom == 0: return NULL
    cx = x0 + d0 * (x1 - x0) / denom    // floor division
    if x0 < cx < x1: return cx
    return NULL
end


function BOUNDARY_IX(cx1: u8, cx2: u8, d1: s9, d2: s9, clip_p1: bool) -> u8 or NULL
    // Narrower than old 8.8 version: pixel-scale d values (s9 not s16).
    denom: s10 = d1 - d2
    if denom == 0: return NULL

    num: s17 = (cx2 - cx1) * d1      // u8 x s9 multiply

    if clip_p1:
        round_up: bool = (cx1 < cx2) // round toward P2 (the inside point)
    else:
        round_up: bool = (cx2 < cx1) // round toward P1 (the inside point)

    if round_up:
        ix = cx1 + CEIL_DIV(num, denom)
    else:
        ix = cx1 + FLOOR_DIV(num, denom)

    return ix
end


function UMUL8(a: u8, b: u8) -> u16
    // Quarter-square table lookup on 6502
    // result = QS[a+b] - QS[|a-b|]  where QS[n] = floor(n^2/4)
    return a * b
end
```

### 6.4 Register Allocation Notes for 6502

The key working values during the forward walk and their suggested storage:

| Value | Width | Storage |
|-------|-------|---------|
| seg_start (sx, sy) | u8 + u8 | Zero page (2 bytes) |
| y_lo, y_hi | u8 | Zero page (2 bytes) |
| xl, yl, xr, yr | u8 (x4) | Zero page (4 bytes) |
| dx_line, dy_line | s16 + s16 | Zero page (4 bytes) |
| span index (si) | u8 | Zero page |
| **Walk state total** | | **~13 bytes** |

Additional values during `_clip_to_span`:

| Value | Width | Storage |
|-------|-------|---------|
| cx1, cx2 | u8 | Zero page |
| cy1, cy2 | u8 | Zero page (1 byte each) |
| dx | s16 | Zero page (2 bytes) |
| dy | s16 | Zero page (2 bytes) |
| xlo, xhi | u8/u9 | Zero page |
| ex | u9 | Zero page (2 bytes) |
| tl, bl, tr, br | u8 | Zero page (4 bytes) |
| interp temps | s16 | A register / temp |
| top1, top2, bot1, bot2 | u8 | Zero page (4 bytes) |
| d1, d2 | s9 | Zero page (4 bytes) |
| **CB clip total** | | **~23 bytes** |

The walk state and CB clip state share the ZP region `$A0-$CF` reserved for
clipper hooks. The CB clip temporaries overlay the walk's line/span values
since `_clip_to_span` receives the original line parameters and the current
span as arguments.

### 6.5 Cycle Budget Summary

| Stage | Multiplies | Divides | Est. Cycles |
|-------|-----------|---------|-------------|
| Global bbox reject (per line) | 0 | 0 | 20-40 |
| Portal cheap accept (per portal) | 0 | 0 | 20-30 |
| Portal exact check (per portal) | 1 (8x8) | 1 (16/8) | 100-150 |
| CB clip entry (per entry) | 4-8 | 4-8 + 0-2 wide | 600-1200 |
| CB clip exit on portal fail | 4-8 | 4-8 + 0-2 wide | 600-1200 |
| CB clip exit at span end | 4-8 | 4-8 + 0-2 wide | 600-1200 |

For a typical line crossing 3 contiguous spans with 2 cheap-accept portals:
1 CB clip entry + 2 portal checks (0 muls each) + 1 CB clip exit =
roughly 1200-2400 cycles total, compared to 3 independent CB clips at
1800-3600 cycles. The portal walk saves 30-50% of multiply work in the
common case.

For a typical frame with ~50 visible lines averaging 2 spans each, the
clipper's total cost is approximately 70,000-150,000 cycles, well within the
budget of a 2 MHz 6502 rendering at low frame rates.

---

## 7. 6502 Implementation (`span_clip.asm`)

The span clipper has a standalone 6502 implementation in `span_clip.asm`,
assembled by BeebASM and tested via py65 emulation. This section describes its
architecture and differences from the Python reference.

### 7.1 Memory Layout

| Region | Address | Size | Purpose |
|--------|---------|------|---------|
| Jump table | $2000-$2017 | 24B | 9 entry points (3-byte JMP each) |
| Code | $2018-$284C | 2.1KB | All span operations + math |
| ZP workspace | $C0-$EE | 47B | Span state, interp args, tighten/crossover temps |
| Span pool | $0400-$04FF | 256B | 32 × 8-byte linked-list slots |
| Quarter-square tables | $5400-$57FF | 1KB | sqr\_lo, sqr\_hi, sqr2\_lo, sqr2\_hi |
| Read buffer | $0300-$03BF | ~192B | Output area for span\_read |

### 7.2 Linked-List Span Pool

Unlike Python's flat list, the 6502 uses a **linked-list pool** at $0400.
Each slot is 8 bytes:

```
offset 0: next_ptr (pool offset of next span, or 0 = end)
offset 1: xlo
offset 2: xhi (0 = 256)
offset 3: tl (top-left Y)
offset 4: bl (bot-left Y)
offset 5: tr (top-right Y)
offset 6: br (bot-right Y)
offset 7: (pad)
```

Slots are accessed with `LDX slot_offset; LDA POOL_XLO,X` -- page-aligned
absolute indexed addressing. Slot 0 is reserved as null; slot 1 (offset 8) is
the initial full-screen span; slots 2-31 form the free list.

A simple free-list allocator (`alloc_span` / `free_span`) manages slot
recycling. `alloc_span` pops from the free list; `free_span` pushes.

### 7.3 Entry Points

| Address | Name | ZP inputs | Notes |
|---------|------|-----------|-------|
| $2000 | span\_init | (none) | Reset to one full-screen span |
| $2003 | span\_mark\_solid | ilo, ihi | Remove [ilo,ihi) from spans |
| $2006 | span\_tighten | ilo, ihi, sx1..yb2 | Narrow top/bot boundaries |
| $2009 | span\_has\_gap | ilo, ihi | A=1 if visible gap exists |
| $200C | span\_is\_full | (none) | A=1 if all spans removed |
| $200F | span\_read | zp\_buf (ptr) | Dump spans to buffer |
| $2012 | interp\_floor | i\_x, i\_x0..i\_y1 | Floor interpolation |
| $2015 | interp\_ceil | (same) | Ceiling interpolation |
| $2018 | interp\_store | (same) | Round-to-nearest interpolation |

### 7.4 Arithmetic Primitives

**Quarter-square multiply (umul8):** `a × b = sqr(a+b) − sqr(|a−b|)` using
four 256-byte lookup tables. Two cases: sum < 256 uses sqr tables; sum ≥ 256
uses sqr2 tables for the sum term. ~30 cycles.

**Signed multiply (smul8):** Checks sign of A; if negative, negates, calls
umul8, negates the product. ~40 cycles.

**Restoring division (udiv16\_8):** Shifting the u16 numerator into a u8
remainder, trial-subtracting the u8 denominator. Uses **adaptive iteration
count**: 8 iterations when the numerator high byte is zero (product fits in
u8, common for narrow spans), 16 iterations otherwise. Handles remainder
overflow (carry from ROL) by always accepting the subtraction when the 9th
bit is set. Special case: denominator 0 means divide by 256 (return high
byte). ~300 cycles (8-iter) to ~600 cycles (16-iter).

### 7.5 Interpolation

All three interp variants share `interp_core`, which computes:

```
dy = y1 − y0           (s8)
offset = x − x0        (u8)
ex = x1 − x0           (u8, 0 = 256)
product = smul8(dy, offset)  → s16
```

Then:
- **interp\_floor:** floor(product / ex) + y0. Negative products use the
  identity floor(−n/d) = −ceil(n/d) = −((n+d−1)/d).
- **interp\_ceil:** ceil(product / ex) + y0. Positive: (prod+den−1)/den.
  Negative: truncate toward zero.
- **interp\_store:** Round-to-nearest: add ex/2 to the product before floor
  division. This prevents min/max ratchet drift.

### 7.6 mark\_solid

Walks the linked list. For each span overlapping [ilo, ihi):
- **Left fragment** (xlo < ilo): Truncate span's right edge to ilo.
  Interpolate Y at ilo using `interp_store`. If original xhi > ihi, allocate a
  right fragment too.
- **No left fragment** (xlo ≥ ilo): If xhi > ihi, modify span to [ihi, xhi).
  Otherwise free the span entirely.

### 7.7 tighten

Uses a **build-new-list** approach -- never modifies the original span
in-place. Walks the old list, allocating new spans for each fragment:

1. **Non-overlapping spans:** Move to new list unchanged.
2. **Overlapping spans:**
   a. Evaluate old and new boundaries at both overlap endpoints using
      `interp_floor` (for dominance check) and `interp_store` (for storage).
   b. **Dominance check:** If new boundaries are everywhere ≤ old top and
      ≥ old bot (after clamping to [0,159] for unsigned comparison), the old
      span dominates -- keep it unchanged.
   c. **Crossover detection:** When the dominance check fails, compute the
      difference between old and new boundaries at both overlap endpoints
      (dt0 = old−new at left, dt1 = old−new at right). If dt0 and dt1 have
      opposite signs, the boundaries cross within the span. The crossover X
      is computed as `cx = ox0 + |d0| × ex / (|d0| + |d1|)` using a single
      8×8 multiply and one 16/8 division. When the denominator exceeds 255
      (both differences are large), both numerator and denominator are halved
      before division (at most 1 pixel of crossover-X imprecision). Up to two
      crossover points are found (one for top, one for bottom), splitting the
      overlap into 2-3 sub-intervals. Each sub-interval is processed
      independently with its own max/min evaluation.
   d. For each sub-interval: allocate separate spans for left fragment,
      tightened overlap, and right fragment. The tightened overlap uses
      max(old,new) for top and min(old,new) for bottom.

### 7.8 The 0-Means-256 Convention

Both xhi and ihi use 0 to represent 256 (since the screen is 256 pixels wide
and 256 doesn't fit in u8). This requires special handling at every comparison
site:
- Range validity (`ihi > ilo`): skip check when ihi=0
- Overlap detection (`xlo < ihi`): always overlaps when ihi=0
- ox1 computation (`min(xhi, ihi)`): when ihi=0 and xhi≠0, use xhi
- Right fragment (`xhi > ihi`): never when ihi=0

### 7.9 Seg Parameter Clamping

The tighten parameters `(sx1, sx2, yt1, yt2, yb1, yb2)` come from the
projection pipeline and can be far outside u8 range (e.g. sx1=−1152 for a
segment that extends well past the left screen edge). The 6502 clipper works
with u8 values and s8 deltas, so these parameters must be clamped before
being passed to the back-end.

The `SpanClip6502.tighten()` wrapper remaps the seg line to the overlap range
`[ilo, min(ihi,255)]`: it evaluates the original seg's Y boundaries at the
clamped X endpoints using full-precision Python interp, then clamps the
resulting Y values to [0,159]. This preserves the seg line's slope within the
visible region while ensuring all values fit in u8.

On real hardware, this clamping would be performed by the front-end when
writing tighten commands to the command buffer. The clamped values are a
conservative approximation: the reparametrized seg line may differ by ±1 pixel
at evaluation points due to integer rounding with different endpoint spacing.

### 7.10 Measured Performance


For a typical E1M1 frame at the spawn point (1056, −3616, angle 64), the
6502 span clipper processes 31 span operations (mark\_solid + tighten) in
**145-157K cycles** at the spawn point (measured by py65 simulation). The NJ
line rasteriser accounts for an additional **56K cycles**. Combined back-end
cost: **200-213K cycles**, or roughly 100ms at 2 MHz.

Clip cost varies moderately with scene complexity. At position (2678,−2586)
scanning through angles 190-230, span clip cost ranges from **134K** to
**167K** — a 1.25× ratio, corresponding to different numbers of overlapping
spans per tighten at different viewing angles.

The dominant cost per interp call is the restoring division loop. The
`udiv16_8` routine uses an adaptive iteration count: 8 iterations when the
numerator fits in u8 (common for narrow spans), 16 iterations otherwise.
This saves ~250 cycles per small-product division, yielding a 22% overall
reduction on complex frames.

### 7.11 Test Framework

`span_clip_6502.py` provides a Python wrapper (`SpanClip6502`) that loads the
assembled binary into py65 and exposes methods matching the entry points. The
test suite includes:
- **interp:** Exhaustive comparison of all three variants against Python
- **mark\_solid:** 3 targeted tests (middle, left edge, multiple)
- **tighten:** 3 targeted tests (simple, after mark\_solid, dominated)
- **Full frame:** Shadows every span mutation during a complete BSP render,
  comparing the 6502 span state against Python after each operation. Currently
  achieves **0 mismatches** across all 31 operations.

The interactive renderer (`doom_wireframe.py`) shadows every span operation
to the 6502 emulator in real time, displaying the accumulated clip cycle count
in the HUD alongside the rasterisation cycle count. Both figures are from
actual py65 simulation — no analytical estimates.

### 7.12 Binary Size

| Component | Bytes |
|-----------|-------|
| Jump table (9 entries) | 27 |
| Math (umul8, smul8, udiv16\_8) | 112 |
| Interpolation (core, floor, ceil, store, span, shared tails) | 239 |
| mark\_solid | 305 |
| tighten (walk, dominance, crossover, overlap\_sub, fragments) | 676 |
| Crossover detection (compute\_crossover) | 80 |
| Utility (init, has\_gap, is\_full, read, alloc, free, append) | 162 |
| **Total** | **2117** |

Key optimizations: shared interp tails (`div_add_y0` / `neg_div_add_y0`)
factor out the common divide-and-add-y0 epilogue from all three interp
variants, saving 31 bytes. The `umul8` routine shares its |a−b| computation
across both sum-paths via PHP/PLP, saving 11 bytes at the cost of 7 cycles
per multiply (~0.4% frame budget). The `interp_core → smul8` fall-through
eliminates a 3-byte JMP. The `udiv16_8` adaptive loop (8 or 16 iterations
based on numerator magnitude) saves ~250 cycles per small-product division.
