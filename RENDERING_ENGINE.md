# DOOM E1M1 Wireframe Rendering Engine

A fixed-point BSP wireframe renderer targeting pure 8-bit arithmetic (8x8 multiply as the only primitive), with a float reference path for validation.

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Geometry Prescaling](#2-geometry-prescaling)
3. [Fixed-Point Number Formats](#3-fixed-point-number-formats)
4. [Trigonometry](#4-trigonometry)
5. [BSP Traversal](#5-bsp-traversal)
6. [View Transform](#6-view-transform)
7. [Perspective Projection](#7-perspective-projection)
8. [Trapezoid Clip Spans](#8-trapezoid-clip-spans)
9. [Line Clipping: Cyrus-Beck](#9-line-clipping-cyrus-beck)
10. [Portal Walk Optimisation](#10-portal-walk-optimisation)
11. [Segment Rendering](#11-segment-rendering)
12. [Vertex Caching](#12-vertex-caching)
13. [Multiply Budget](#13-multiply-budget)
14. [Future: Shift-Add Y Projection](#14-future-shift-add-y-projection)

---

## 1. Architecture Overview

Two parallel rendering paths share the same BSP traversal and WAD data:

```
                    WAD File (DOOM1.WAD)
                           |
                    Parse & Prescale (divide by 8)
                           |
              +------------+------------+
              |                         |
        Float Path                 FP Path
     (1024 x 640)             (256 x 160, 4x upscale)
     exact arithmetic          8-bit arithmetic
     reference output          multiply-counted
              |                         |
              +------------+------------+
                           |
                    Display (1024 x 640)
```

Both paths use **front-to-back BSP traversal** with **analytical 2D trapezoid clip spans** for hidden surface removal. The key difference is arithmetic precision.

Toggle between paths with the **F** key at runtime.

---

## 2. Geometry Prescaling

All DOOM geometry is prescaled at load time to fit in 8-bit coordinates:

```
Prescaled value = (world_value - MAP_CENTER) / PRESCALE

MAP_CENTER_X = 1200      (approximate centre of E1M1)
MAP_CENTER_Y = -3250
PRESCALE     = 8
```

This transforms E1M1's coordinate range (~4500 units wide) into ~560 prescaled units, fitting comfortably in signed 16-bit with room for intermediate products.

Heights are prescaled identically, preserving the aspect ratio of projection.

```
 World coords               Prescaled coords
 +-----------+              +--------+
 |  -768     |   divide     | -246   |
 |    to     |  -------->   |   to   |
 |  3808     |   by 8       |  326   |
 +-----------+              +--------+
   (4576 range)              (572 range, fits 16-bit)
```

**Invisible seg stripping**: Two-sided segs where both sectors have identical floor AND ceiling heights produce no visible geometry. These are stripped from the FP seg table at load time, reducing per-frame work.

---

## 3. Fixed-Point Number Formats

| Format | Notation | Bits | Range | Used For |
|--------|----------|------|-------|----------|
| 16.0 signed | `int` | 16 | +/-32767 | Prescaled world coords, intermediate sums |
| 8.0 signed | `int8` | 8 | +/-127 | View-space coords, screen pixels |
| 1.7 signed | `s1.7` | 8 | -1.0 .. +0.992 | Sin/cos magnitude |
| 0.8 unsigned | `u0.8` | 8 | 0 .. 0.996 | Reciprocals (lo byte), slopes, parametric t |
| 8.8 signed | `s8.8` | 16 | +/-127.996 | Player position (sub-unit), intermediates |
| 4.12 signed | `s4.12` | 16 | +/-8 | Clip slopes (high precision for shallow angles) |

**The only multiply primitive**: 8-bit x 8-bit -> 16-bit signed product. All wider multiplications are decomposed into pairs of 8x8 multiplies.

---

## 4. Trigonometry

### Angle Representation

Angles are stored as a single byte (0-255 = 0-360 degrees). One full rotation = 256 steps, giving ~1.4 degree resolution.

### Sin/Cos Table

A 64-entry quadrant table stores **unsigned magnitude** (0-255) for one quarter cycle. Full-circle lookup mirrors and negates:

```
  Quadrant 0 (0-63):    sin = table[i],       cos = table[64-i]
  Quadrant 1 (64-127):  sin = table[64-i],    cos = -table[i]
  Quadrant 2 (128-191): sin = -table[i],      cos = -table[64-i]
  Quadrant 3 (192-255): sin = -table[64-i],   cos = table[i]
```

Each lookup returns a triple: **(magnitude, is_negative, is_unity)**.

### Unity Detection

When |sin| or |cos| rounds to 256/256 = 1.0, the multiply `value * sin` simplifies to just `value` (with sign). The `is_unity` flag enables this:

```
                Angle 0 (facing east)
                sin=0, cos=1 (unity)
                  |
          Angle   |   Angle
          64      |   192
  cos=0   sin=1   |   sin=-1   cos=0
  (unity)         |             (unity)
                  |
                Angle 128 (facing west)
                sin=0, cos=-1 (unity)
```

At cardinal angles, **zero multiplies** are needed for the view transform. The extended unity range (angles 62-66 and equivalents) catches near-cardinal angles too.

---

## 5. BSP Traversal

### DOOM's BSP Tree

Each node stores a partition line `(x, y, dx, dy)` and two children (each either a node or a leaf subsector). Each child has an axis-aligned bounding box.

```
              Node 235 (root)
             /              \
     Near (player side)    Far
           |                 |
        Node 128          Node 234
        /      \           /     \
      ...     ...       ...     ...
       |       |         |       |
     SS117  SS119      SS204   SS130
   (player)
```

### Front-to-Back Order

1. Determine which side of the partition contains the player (`point_on_side`)
2. **Always** recurse into the near child first
3. After near child completes, check if far child's bbox is visible:
   - Project bbox corners to screen X range (with near-plane edge clipping)
   - Check if any clip span has a gap in that X range (`has_gap`)
4. If visible and has gaps, recurse into far child
5. **Early exit**: if all clip spans are full (`is_full`), stop immediately

### Subsector Processing

All segs within a subsector are drawn **before** any clip updates are applied (deferred `mark_solid` / `tighten`). This prevents coplanar walls from splitting adjacent lines within the same subsector.

```
  Subsector with 4 segs:

  1. Draw seg 0 (solid wall)      }
  2. Draw seg 1 (solid wall)      }  All draws first
  3. Draw seg 2 (two-sided step)  }
  4. Draw seg 3 (back-facing, skip)}

  5. mark_solid for seg 0         }
  6. mark_solid for seg 1         }  Then clip updates
  7. tighten for seg 2            }
```

### Bbox Visibility with Near-Plane Clipping

When some bbox corners are behind the near plane, the bbox edges are clipped against the near plane before projection, giving a tight screen X range instead of the conservative full-width fallback:

```
        Near plane
  ------+----------
        |  /|
  Behind| / | In front
        |/  |
  ------+----------
        ^
  Edge clipped here, projected
```

---

## 6. View Transform

Convert world coordinates to view space (vx = sideways, vy = forward):

```
  vx = dx * sin(angle) - dy * cos(angle)
  vy = dx * cos(angle) + dy * sin(angle)

  where dx = world_x - player_x, dy = world_y - player_y
```

### FP Implementation

**Per-frame precomputation** (`fp_view_context`): The player position has a fractional part (0.8) for smooth movement. The rotation of this fraction by sin/cos is computed once (4 muls max, often 0 for cardinal angles) and added to every vertex.

**Per-vertex** (`fp_to_view`): Integer deltas rotated by sin/cos magnitude with sign/unity flags. 4 multiply calls, often reduced by unity detection.

```
  Frame setup (once):
    frac_contribution = rotate(player_frac, sin, cos)  [0-4 muls]

  Per vertex:
    vx = rotate_int(dx, dy, sin, cos) + frac_contribution  [0-4 muls]
    vy = rotate_int(dx, dy, cos, sin) + frac_contribution
```

### Near-Plane Clipping

Segments with one or both vertices behind the camera (vy < 1) are clipped to the near plane using parametric interpolation:

```
  t = (NEAR - vy1) / (vy2 - vy1)     [0.8 format]
  cx = vx1 + t * (vx2 - vx1)          [8x8 multiply]
```

---

## 7. Perspective Projection

### Reciprocal Tables

Division `FOCAL / vy` is replaced by table lookup. Two tables (for X and Y focal lengths) store 512 entries in hi/lo byte pairs:

```
  recip = FOCAL * 256 / vy    (8.8 format, split into hi and lo bytes)

  recip_hi = integer part     (0-127, 8 bits)
  recip_lo = fractional part  (0-255, 8 bits)
```

**Fractional interpolation**: A 3rd bit extracted from vy enables 50:50 averaging with the next table entry, giving 1024 effective entries from 512 stored. The averaging uses full 16-bit reconstruction to avoid byte-boundary catastrophes.

### Screen X Projection

```
  sx = HALF_W + vx * recip_hi + (vx * recip_lo >> 8)
       ^^^^^^   ^^^^^^^^^^^^    ^^^^^^^^^^^^^^^^^^^^^^
       128      8x8 mul #1      8x8 mul #2 (fractional correction)
```

2 multiplies per vertex. Optional sub-pixel mode adds a 3rd multiply using the fractional view-space X.

### Screen Y Projection

```
  sy = HALF_H - (h_delta * recip_hi + (h_delta * recip_lo >> 8))

  h_delta = sector_height - player_eye_height    (range: +/-31)
```

2 multiplies per height. Each vertex needs ceil and floor = 4 muls for Y projection. Cached per `(vertex, floor_height, ceil_height)` to avoid recomputation across subsectors.

---

## 8. Trapezoid Clip Spans

The visible region of the screen is represented as a list of non-overlapping half-open spans `[xlo, xhi)`, each with linear top and bottom boundary functions:

```
  Span:  [xlo, xhi)
         top(x) = slope_top * x + intercept_top
         bot(x) = slope_bot * x + intercept_bot

  +---------screen---------+
  |  /top           top\   |
  | /   VISIBLE         \  |
  |/     REGION          \ |
  |\                     / |
  | \   VISIBLE         /  |
  |  \bot           bot/   |
  +------------------------+
     ^xlo              ^xhi
```

### Operations

**`mark_solid(lo, hi)`**: Remove columns [lo, hi) entirely. Used for one-sided walls.

```
  Before: [..... span A .....]
  After:  [..A..]  gap  [.A..]
                   ^^^^
                   solid wall removed these columns
```

**`tighten(lo, hi, ...)`**: Narrow the top/bottom boundaries over [lo, hi). Used for two-sided segs (steps, windows). Computes piecewise max (top) and piecewise min (bottom) of old and new boundary functions:

```
  Before:     ________________ old top
              ________________ old bot

  Tighten:        ____
                 / new top (from ceiling step)
              __/
                 \___ new bot (from floor step)
              ______\

  After:          ____
                 / max(old_top, new_top)
              __/
                 \___ min(old_bot, new_bot)
              ______\
```

Crossover detection handles the case where old and new functions intersect, splitting the span at the crossover point.

### Slope-Intercept Storage

Boundaries are stored as `(slope, intercept)` rather than interpolated per-column. This avoids accumulated interpolation error and means every evaluation uses the original parameters:

```
  y(x) = slope * x + intercept

  slope in 0.8 signed (FP) or float
  intercept in 8.0 (FP) or float
```

The intercept is computed from whichever endpoint has smaller |x| to minimise slope quantisation error compounding over off-screen distances.

---

## 9. Line Clipping: Cyrus-Beck

Each line is clipped against a trapezoid using Cyrus-Beck (4 half-planes):

```
       xlo        xhi
        |  top(x)  |
        | /      \ |
        |/ visible\|
        |\ region /|
        | \      / |
        |  bot(x)  |
        |          |

  4 half-planes:
    Left:   x >= xlo
    Right:  x < xhi
    Top:    y >= top(x)
    Bottom: y <= bot(x)
```

For each half-plane, compute `(p, q)` where the constraint is `p * t + q >= 0`:

```
  Left:   p = -dx,          q = x1 - xlo
  Right:  p =  dx,          q = xhi - x1
  Top:    p = ta*dx - dy,   q = y1 - ta*x1 - tb
  Bottom: p = dy - ba*dx,   q = ba*x1 + bb - y1
```

The parametric range `[t0, t1]` is narrowed by each constraint. If t0 > t1, the line is entirely outside.

**Flat-slope short-circuit**: When a boundary slope is 0 (very common for flat ceiling/floor spans), the corresponding `ta*dx` and `ta*x1` multiplies are skipped (= 0).

**Post-clip clamping**: Integer division truncation can place endpoints slightly outside the trapezoid. X is clamped to `[xlo, xhi-1]`. For vertical lines (dx=0), Y is clamped to `[top_at_x, bot_at_x]` using values already computed during the Cyrus-Beck setup (zero extra multiplies).

---

## 10. Portal Walk Optimisation

Before falling back to per-span Cyrus-Beck clipping, the renderer attempts to draw each line as a single segment by verifying it passes cleanly through all span portals.

### Algorithm

```
  Line crosses 5 contiguous spans:

  [span A] | [span B] | [span C] | [span D] | [span E]
           ^          ^          ^          ^
       portal 1   portal 2   portal 3   portal 4

  1. Scan inward from left:  CB-clip to span A -> entry point
  2. Scan inward from right: CB-clip to span E -> exit point
  3. Check portals 1-4: is line Y within both spans' apertures?
  4. If all pass: draw ONE line from entry to exit
  5. If any fail: per-span CB for the visible range
```

### Portal Check

At each span boundary `x = xhi`, the portal is the intersection of both spans' apertures:

```
  portal_top = max(left_span_top(x), right_span_top(x))
  portal_bot = min(left_span_bot(x), right_span_bot(x))

           left span          right span
      top_L -------+-------- top_R
                    |
         PORTAL --> |<-- max(top_L, top_R) to min(bot_L, bot_R)
                    |
      bot_L -------+-------- bot_R
```

### Two-Level Test

1. **Fast (zero muls)**: Check line's Y bounding box `[min(y1,y2), max(y1,y2)]` against portal
2. **Exact (one Python int mul)**: If bbox fails, compute exact line Y at the portal X

### Contiguous Group Handling

Active spans are split into contiguous groups (separated by `mark_solid` gaps). Each group gets its own portal walk. A line crossing a gap produces separate draw calls for each group.

```
  [span A][span B]  GAP  [span C][span D]
  |--- group 1 ---|      |--- group 2 ---|

  Group 1: portal walk -> 1 draw call
  Group 2: portal walk -> 1 draw call
  (gap is real occlusion from closer geometry)
```

---

## 11. Segment Rendering

Each front-facing seg generates lines based on the height relationship between front and back sectors:

### One-Sided (Solid Wall)

```
  ft _____________________ ft
  |                        |
  |     SOLID WALL         |
  |                        |
  fb _____________________ fb

  4 lines: top, bottom, left vertical, right vertical
  Clip update: mark_solid (remove columns)
```

### Two-Sided: Ceiling Step Down

```
  ft _____________________ ft     <- front ceiling
  |  UPPER STEP            |
  bt _____________________ bt     <- back ceiling (lower)
  |                        |
  |     (opening)          |
  |                        |

  3 lines: step edge (bt), left vertical, right vertical
  Skip: front ceiling (ft) line when face is below eyeline (always clipped)
  Clip update: tighten top to max(ft, bt)
```

### Two-Sided: Floor Step Up

```
  |                        |
  |     (opening)          |
  |                        |
  bb _____________________ bb     <- back floor (higher)
  |  LOWER STEP            |
  fb _____________________ fb     <- front floor

  3 lines: step edge (bb), left vertical, right vertical
  Skip: front floor (fb) line when face is above eyeline (always clipped)
  Clip update: tighten bottom to min(fb, bb)
```

---

## 12. Vertex Caching

### Frame-Global View Cache (`vcache`)

Maps `vertex_index` -> `(vx_trunc, vx_round, vy, vx_frac, vy_idx, [sx, rxh, rxl])`.

Populated lazily on first access. X projection result appended after first computation. Shared across all subsectors in the frame.

### Frame-Global Y Cache (`ycache`)

Maps `(vertex_index, floor_height, ceil_height)` -> `(ft, fb, recip_y_hi, recip_y_lo)`.

Keyed on actual height values (not sector index), so vertices shared between sectors with the same heights hit the cache.

```
  Subsector A (sector 5, floor=0, ceil=16):
    v11 -> compute ft, fb  [4 muls]
    v14 -> compute ft, fb  [4 muls]

  Subsector B (sector 7, floor=0, ceil=16):    <- same heights!
    v11 -> CACHE HIT        [0 muls]
    v38 -> compute ft, fb  [4 muls]
```

---

## 13. Multiply Budget

### Per-Vertex Breakdown (Typical)

| Stage | Muls | Notes |
|-------|------|-------|
| View transform | 4 | Integer rotation (0 at cardinal angles) |
| X projection | 2 | recip_hi + recip_lo (3 with sub-pixel) |
| Y projection (ceil) | 2 | h_delta * recip split |
| Y projection (floor) | 2 | Same, different h_delta |
| **Total** | **10** | Before caching |

### Caching Savings

With frame-global vcache + ycache, shared vertices (appearing in 2-3 segs) pay the full cost once. Typical savings: 30-50% of total V+P muls.

### Per-Line Clipping Cost

| Operation | Muls | Notes |
|-----------|------|-------|
| Cyrus-Beck setup (4 constraints) | 0-4 | Short-circuited when slopes = 0 |
| Cyrus-Beck endpoint computation | 4 | t0*dx, t0*dy, t1*dx, t1*dy |
| Portal walk (fast path) | 0 | Just min/max comparisons |
| Portal walk (exact fallback) | 0 FP muls | Python int mul (not 8x8) |
| **Typical per line** | **2-8** | Most spans are flat (0 setup muls) |

### Uncounted Operations

| Operation | Location | Type |
|-----------|----------|------|
| Back-face test | `fp_render_seg` | 2 x integer multiply (prescaled coords) |
| Piecewise crossover | `_fp_pw_max/min` | 1 x integer multiply |

---

## 14. Future: Shift-Add Y Projection

`fp_project_y` currently costs 2 multiplies per call (4 per vertex for ceil+floor). Since `h_delta` (height minus eye level) is only +/-31 (6 bits) and constant per sector, the multiply can be replaced with a shift-add chain:

```
  h_delta = 11 (binary 1011)

  h_delta * recip_hi = (recip_hi << 3) + (recip_hi << 1) + recip_hi
                        8x               2x               1x = 11x

  Cost: 3 additions + 2 shifts (vs ~50-100 cycles for 8x8 multiply)
```

**Per-sector setup**: Precompute the bit pattern of |h_ceil| and |h_floor|.

**Recip_lo skip threshold**: When `|h_delta| * recip_lo < 256` (< 1 pixel contribution), skip the fractional correction entirely.

| |h_delta| | Skip threshold | % vertices skipped |
|-----------|---------------|-------------------|
| 2 | recip_lo < 128 | ~50% |
| 5 | recip_lo < 51 | ~20% |
| 11 | recip_lo < 23 | ~9% |

**Net effect**: Y projection drops from 4 muls/vertex to 0, leaving only view transform (4) and X projection (2) = **6 muls/vertex total**.

---

## Appendix: Debug Tools

| Key | Mode | Function |
|-----|------|----------|
| F | Any | Toggle float / fixed-point |
| M | Any | Toggle top-down map view |
| G | FP | Enter/exit line stepper (debug) |
| +/- | G mode | Step forward/back through lines |
| P | G mode | Dump portal analysis to stdout |
| D | Any | Dump float-vs-FP draw call comparison |
| S | FP | Toggle sub-pixel X projection |
| X | Any | Toggle XOR draw mode |
| +/- | Map | Zoom in/out |
