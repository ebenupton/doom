# The 6502 DOOM Engine — Operation of the Three Core Subsystems

*A reference description of the pure-6502 renderer as implemented in
`bsp_render.asm` (+`span_clip.asm`). This is the **target machine**
engine — the thing that runs with no Python in the loop — as opposed to
the float/FP Python reference described in `RENDERING_ENGINE.md`. The
6502 engine is validated bit-for-bit against that Python reference (see
`BSP_RENDER_STATUS.md`); this document explains how the silicon-side
implementation actually works.*

---

## 0. Orientation

The renderer is three cooperating subsystems plus a small kernel of
shared 8-bit arithmetic primitives:

```
        ┌────────────────────────────────────────────────────┐
        │  bsp_render.asm  ($4800 main, helpers $1B40+/$2x)   │
        │                                                     │
        │   ┌──────────────┐    ┌───────────────────────┐     │
        │   │ §1 VERTEX     │    │ §2 BSP TRAVERSAL      │     │
        │   │ TRANSFORM &   │◀───│  walk + bbox vis +    │     │
        │   │ CACHE         │    │  seg processor        │     │
        │   └──────┬───────┘    └──────────┬────────────┘     │
        │          │ projected verts        │ visible segs     │
        └──────────┼────────────────────────┼─────────────────┘
                   │                         │
                   ▼                         ▼
        ┌────────────────────────────────────────────────────┐
        │  span_clip.asm  (jump table $2000, code $2000-$4737)│
        │                                                     │
        │   §3 WINDOWED CLIPPED RENDERER                      │
        │     span pool · mark_solid · tighten · has_gap ·    │
        │     Cyrus-Beck line clip · portal walk · DCL → NJ   │
        └────────────────────────────────────────────────────┘
                   │
                   ▼
        ┌────────────────────────────────────────────────────┐
        │  NJ linedraw rasteriser  ($A900-$B55E)              │
        └────────────────────────────────────────────────────┘
```

The two modules are linked but separately assembled. `span_clip` exposes
a **fixed jump table** at `$2000` so `bsp_render` can call it by absolute
address without a linker:

| Address | Entry | Purpose |
|---|---|---|
| `$2000` | `span_init` | Reset pool to one full-screen span |
| `$2003` | `span_mark_solid` | Occlude columns `[lo,hi]` |
| `$2006` | `span_tighten` | Narrow apertures (legacy seg-param form) |
| `$2009` | `span_has_gap` | Visibility query over `[lo,hi]` |
| `$200C` | `span_is_full` | True when no spans remain (screen solid) |
| `$200F` | `span_read` | Dump a span (test harness) |
| `$2012` | `interp_store` | Linear interp (exposed for tests) |
| `$2015` | `draw_clipped_line` | DCL: clip+emit a line |
| `$2018` | `clip_line_records` | Split a line into per-span verdict records |
| `$201B` | `tighten_from_records` | Records-driven tighten |
| `$201E` | `draw_clipped_line_s16` | s16-input wrapper for DCL |
| `$2021` | `umul8` | Exported multiply (jump-table form) |
| `$2024` | `udiv16_8` | Exported divide |
| `$2030` | `umul8` (**pinned body**) | Direct-call multiply entry — saves 3cy |

The pinned `umul8` at `$2030` matters: `bsp_render` calls the multiply
primitive thousands of times per frame, so it bypasses the jump-table
`JMP` and calls the routine body directly. An `ASSERT` in `span_clip`
keeps the pin honest across edits.

### The arithmetic kernel

Everything in the engine is built from **one multiply primitive**: an
8×8→16 unsigned multiply.

- **`umul8`** (`$2030`): `A × zp_mul_b($D9) → zp_prod_lo:hi ($DA:$DB)`.
  Implemented as a **quarter-square** table multiply
  (`a·b = (sqr[a+b] − sqr[a−b])/4`), with two table sets to handle the
  `a+b ≥ 256` wrap. ~50 cycles including call/return. Clobbers A/X/Y.
- **`br_smul_s8_u8`** (`$0593`): signed-8 × unsigned-8 → s16. Negates the
  signed operand if needed, calls `umul8`, negates the s16 result back.
  Split sign paths (no flag byte, no writeback of the magnitude).
- **`udiv16_8`** (`$2024`): restoring division. Fast path is 8 iterations
  when the quotient fits a byte; slow path is the full 16. Used for
  near-plane crossing parameters and crossover columns.

Wider arithmetic (s16×u8, s24 accumulation) is always *decomposed* into
`umul8` calls plus carry-tracked adds. The multiply count is a frozen
budget; optimisation is by tables and bit tricks only.

### Number formats (as used on the 6502)

| Format | Bits | Used for |
|---|---|---|
| s16 (`.lo:.hi`) | 16 | Prescaled world coords, view coords, screen X |
| s24 (`.lo:.hi:.ext`) | 24 | Rotation products, wide view-X, projection accum |
| s8 | 8 | View-space integer coords, height deltas, pixels |
| u0.8 | 8 | Reciprocal fraction, trig magnitude, parametric `t` |
| 8.8 | 16 | Reciprocals (`hi:lo`), player sub-unit position |

All vertical (Y) coordinates inside the span clipper carry a constant
**`Y_BIAS = 48`** offset: the visible range `[0,159]` is stored as
`[48,207]` (`VIS_YMAX = 207`). The bias lets every boundary comparison
stay in unsigned `u8` with no sign juggling, and is folded into the Y
projection's base constant so no per-store add is needed.

---

# §1 — Vertex Transformation and the Vertex Cache

This subsystem turns a 16-bit prescaled world vertex `(wx, wy)` into a
projected **screen X** (s16) and a per-height **screen Y**, and caches the
expensive parts so a vertex shared between several segs is paid for once.

## 1.1 View transform — `br_to_view` (`$0507`)

Computes view-space `(vx, vy)` where `vx` is sideways and `vy` is forward
(depth). The maths mirrors the Python reference exactly:

```
dx = wx − px_int ,  dy = wy − py_int            (s16)
int_vx = rot_int(dx, sin) − rot_int(dy, cos)
int_vy = rot_int(dx, cos) + rot_int(dy, sin)
vx = int_vx + frac_vx                            (s24)
vy = int_vy + frac_vy                            (s24)
```

The player position has a fractional (0.8) part for smooth movement. Its
rotation (`frac_vx`, `frac_vy`) is computed **once per frame** by
`br_view_setup` (`$0434`) and added to every vertex — the per-vertex path
only rotates the integer delta.

### Per-frame trig state ($05–$0A)

`br_view_setup` resolves the player angle to a sin/cos **triple** each:
`(magnitude, is_negative, is_unity)`. These six bytes are laid out
contiguously so they can be addressed by a Y offset:

```
$05 smag   $06 sneg   $07 sone      (Y=0 → sin)
$08 cmag   $09 cneg   $0A cone      (Y=3 → cos)
```

The frac contribution is derived from the **low byte of the negated**
player position (`$0B–$0E` hold `fvxlo/hi`, `fvylo/hi`).

### `br_rot_int` (`$0373`) — the integer rotation

Input s16 delta in `zp_ri_dlo:dhi`; the trig triple selected by Y
(`LDA $0005,Y` / `$0007,Y` etc.). Output s24 in `resl:resh:resext`
(`$17:$18:$2D`). Three branches:

- **Unity** (`|trig| = 1`): result `= d << 8`, i.e. s24 `(0, d.lo, d.hi)`.
  No multiply — just a byte shuffle. This is the cardinal/near-cardinal
  fast path; at angles 0/64/128/192 the whole view transform costs **zero
  multiplies**.
- **Zero magnitude**: result `= 0`.
- **General**: `|d| × mag` via two `umul8` calls (lo·mag, hi·mag<<8),
  forming the s24 product, then negated if `d` was negative, then negated
  again if the trig term was negative.

`br_frac_rot_term` (`$0314`) is the analogous routine for the 0.8
fractional byte: unity returns the byte itself; otherwise one `umul8`
with round-to-nearest (`(lo·mag + 128) >> 8`).

**Cost**: ~80cy general / ~20cy unity per `rot_int`; a full `br_to_view`
is ~400cy worst case, far less when unity branches fire.

## 1.2 Reciprocal — `br_recip` (`$0229`)

Perspective needs `FOCAL / vy`; this is a table lookup, not a divide.

- Input: `vy_idx` (`zp_br_t0:t1`), a 9.1-format depth index.
- Tables at `RECIP_BASE = $E000`: 514 hi-bytes then 514 lo-bytes.
- Clamp `vy_idx` to `[2, 1023]` (guards tiny/huge depths).
- The **low bit** of `vy_idx` is a fractional selector; `i = vy_idx >> 1`
  indexes the table. When the bit is set, the routine reads entry `i` and
  `i+1` and **averages them with a full 16-bit add + double `ROR`** — this
  gives 1024 effective entries from 514 stored, while avoiding the
  byte-boundary catastrophe a naive lo-byte average would hit.
- Output: 8.8 reciprocal in `zp_br_rhi:rlo` (`$1A:$1B`).

## 1.3 X projection — `br_project_x_auto` (`$2399`)

Projects view-X to screen-X around `HALF_W = 128`. It **auto-dispatches**
between a narrow and a wide path based on whether the view-X fits s8:

```
narrow  iff  xext == sign_extend(xint)        ; |vx| ≤ 127
```

### Narrow path — `br_project_x_subpx` (`$0743`), 3 multiplies

```
sx = 128 + m8(vx,rhi) + (m8(vx,rlo) >> 8) + (m8(vxfrac,rhi) >> 8)
```

The first term is a full s16 add; the second is the sign-extended hi byte
of a `smul_s8_u8`; the third is the unsigned hi byte of a `umul8` on the
fractional part (the sub-pixel correction). Accumulated in `vxlo:hi`.

### Wide path — `br_project_x_wide` (`$3028`), 5 multiplies

For `|vx| ≥ 128`, `vx` is a true s16 `(xext:xint)` and the projection is
done **mod 2¹⁶, bit-exact with Python**, decomposed into five `umul8` /
`smul_s8_u8` terms accumulated in an s24 `vxlo:hi:t2`:

```
evx·rxh  mod 2¹⁶ = umul8(xint,rxh) + (smul_s8_u8(xext,rxh).lo << 8)
evx·rxl  >> 8     = smul_s8_u8(xext,rxl) + umul8(xint,rxl).hi
frac·rxh >> 8     = umul8(xfrac,rxh).hi
```

The s24 result (`resl:resh:resext`) keeps the carry-out as a sign
extension so the BSP bbox code can classify off-screen X (`sx < 0` /
`sx > 255`) without losing bits.

## 1.4 Y projection — `br_project_y` (cache front-end at `$DAC0`)

Screen-Y from a height delta `h = sector_height − eye` (range ±31, s8).
The raw computation `br_project_y_raw` (`$0798`) is **2 multiplies**:

```
sy = (HALF_H + Y_BIAS) − ( m8(h,rhi) + (m8(h,rlo) >> 8) )
   = 128            −   A          −   B
```

`HALF_H = 80` and `Y_BIAS = 48` are pre-summed into the constant `128`,
so every consumer gets a pre-biased Y with no extra add. Each vertex needs
ceiling+floor (and, for two-sided segs, back-ceiling+back-floor), so up to
4 Y projections per vertex — gated by `do_project_y` so plain solid walls
skip the two back-pair projections.

### The Y-projection cache (W region, `$D4C0–$D9FF`)

Because heights vary per seg, Y projection **cannot** be cached on the
vertex. But the *result* is a pure function of `(rhi, rlo, h)`, and
58–64% of those repeat within a frame. So `br_project_y` fronts the raw
routine with a 256-bucket direct-mapped cache:

```
idx  = (rlo + h + rhi) & 255                    ; fold all three inputs
hit  = VALID[idx] ∧ RHI[idx]==rhi ∧ RLO[idx]==rlo ∧ H[idx]==h
```

| Table | Address |
|---|---|
| `VWHC_VALID` | `$D4C0` |
| `VWHC_RHI` | `$D5C0` |
| `VWHC_RLO` | `$D6C0` |
| `VWHC_H` | `$D7C0` |
| `VWHC_LO` / `VWHC_HI` | `$D8C0` / `$D9C0` |

A hit verifies the **full** key (so hits are bit-identical to a fresh
compute) and returns the stored `sy`. The valid array is cleared once per
frame in `br_init_frame`. **Hit ≈ 45cy; miss ≈ 315cy.** This cache landed
−2.3% total cycles, bit-exact.

## 1.5 The vertex cache (`$0C00–$1A98`)

A frame-global cache keyed on vertex index, **8 bytes × 467 vertices**,
with a 1-bit-per-vertex valid bitmap at `VCACHE_VALID_BASE = $1B00`
(59 bytes), cleared each frame.

### Entry layout (8 bytes, at `VCACHE_BASE + idx*8`)

| Off | Field | Notes |
|---|---|---|
| +0 | `evy` (s8) | rounded view-Y `(vy + 128) >> 8`, clamped s8 |
| +1 | `evx` (s8) | truncated view-X integer part |
| +2 | `rhi` (u8) | reciprocal hi (`1/vy`, 8.8) |
| +3 | `rlo` (u8) | reciprocal lo |
| +4 | `sx_lo` (u8) | projected screen-X lo |
| +5 | `sx_hi` (u8) | projected screen-X hi |
| +6 | `near_clip` | non-zero ⇒ vertex behind near plane |
| +7 | pad | — |

> Note: this layout supersedes the older note in `BSP_RENDER_STATUS.md`'s
> memory-map table; the offsets above are read directly from
> `br_seg_xform_vertex` at `bsp_render.asm:2048–2174`.

### Lazy population — `br_seg_xform_vertex` (`$2014`)

1. **Probe**: byte offset `idx>>3`, mask `1<<(idx&7)`; if the valid bit is
   set, jump to `vc_hit`, else `vc_miss`.
2. **Hit** (`vc_hit`, `:2048`): always loads `evy`/`evx` (the near-plane
   crossing maths needs them even for clipped verts); checks `near_clip`
   at +6 and skips the seg if set; otherwise loads `rhi/rlo/sx` and falls
   into `do_project_y`. ~0 multiplies.
3. **Miss** (`vc_miss`, `:2075`): set the valid bit, read the 4 ROM bytes
   `(x_lo,x_hi,y_lo,y_hi)`, run `br_to_view`, round/clamp `evy` (via
   `ev_clamp_evy16`), set `near_clip` from the s24 sign of `vy` vs
   `NEAR_88`, compute the reciprocal, project X via `br_project_x_auto`,
   and write all of `evy,evx,rhi,rlo,sx_lo,sx_hi,near_clip` back into the
   slot. Then `do_project_y`.

The X projection result is therefore computed once per frame per vertex;
shared verts (typically appearing in 2–3 segs) hit the cache thereafter,
saving 30–50% of the view+projection multiplies.

---

# §2 — BSP Traversal

This subsystem walks DOOM's BSP tree front-to-back, decides which node
children are worth visiting (bbox visibility + span occlusion), and feeds
visible subsectors to the seg processor. It mirrors Python's
`packed_render_bsp` exactly and produces an identical visit sequence.

## 2.1 The walk driver — `br_render_frame` (`:892`)

An explicit stack replaces recursion.

- **`BSP_STACK = $0A00`**, 32 entries × 2 bytes (`$0A00–$0A3F`); pointer
  `zp_bsp_stack_sp` (`$4E`) is a byte offset.
- The root node id is pushed at init; the loop pops 2-byte entries until
  the stack is empty.

### Stack-entry encoding (hi byte flags)

A stack entry's **high byte** is overloaded:

| Hi-byte bits | Meaning |
|---|---|
| bit 7 (`$80`) set | **subsector** (leaf); low 7 bits + lo byte = id |
| bit 6 (`$40`) set | **deferred far child**; bit 5 carries the side |
| neither | plain interior **node** id |

### Per-pop control flow

```
pop (chlo, chhi)
JSR span_is_full              ; early-out: if screen solid, abandon stack
BNE done

if chhi & $40:  deferred far child  → re-test bbox at *pop* time
elif chhi & $80: subsector          → br_render_subsector
else:            interior node       → br_node_setup, recurse near-first
```

### Near-first recursion with deferred far child (`bsp_node`, `:946`)

For an interior node the driver:

1. Calls `br_node_setup` — reads the 16-byte node record
   (`partition normal (nx,ny)`, `offset (dx,dy)`, `child_right`,
   `child_left`), computes which side the player is on via the partition
   cross-product, and writes `BSP_NEAR_LO/HI` (`$096B/$096C`) and
   `BSP_FAR_LO/HI` (`$096D/$096E`).
2. **Pushes the far child as a *deferred* entry**: `chhi |= $40`, side
   encoded into bit 5 (`farside << 5`). It is *not* visibility-tested now.
3. **Bbox-tests the near child immediately** (`br_bbox_visible`); if
   visible it is pushed as a normal entry and visited first.

The deferral is the crux of front-to-back correctness: the far child's
bbox/`has_gap` test is performed **at pop time**, i.e. *after* the entire
near subtree has rendered and updated the span state. So the far subtree
is only entered if the near geometry left a gap for it to show through.

When a deferred entry is popped (`bsp_deferred`, `:928`), the side is
recovered from bit 5, the flags are masked off, `br_bbox_visible` runs
against the *current* span state, and if visible `bsp_resolve_child`
fetches `node.children[side]` and dispatches it.

`span_is_full` is checked on every pop, so once close geometry has filled
the screen the remaining stack is abandoned wholesale.

## 2.2 BBox visibility — `br_bbox_visible` (`:1257`)

Decides whether a child's axis-aligned bounding box could contribute any
pixel, bit-exactly matching Python's `fp_bbox_visible_fixed`. The BBox
table is 16 bytes/node (8 bytes/child): `top, bot, left, right` as s16,
pointed to by `zp_rom_bbox_lo/hi` (`$32/$33`).

The algorithm, in the same order as the reference (rejects are arranged to
fire *before* any projection/recip work):

1. **Inside test**: if the player point lies within `[left,right] ×
   [bot,top]`, the box surrounds the camera → return `has_gap(0,255)`.
2. **Transform 4 corners** `(L,T),(R,T),(R,B),(L,B)`. To avoid 16
   rotations, `bv_corner_products` computes the **8 shared rotation
   products** (`l_sin,l_cos,r_sin,r_cos,t_sin,t_cos,b_sin,b_cos`) once;
   `bv_proj_one` combines them per corner. Corners land in
   `BBOX_CORNERS = $0A40` (4×8 bytes).
3. **Frustum/near tests on rounded s16** `(evx,evy)` per corner, recording
   flags in `BBOX_FLAGS` (`$0968`): in-front, left-of-L-frustum,
   past-R-frustum.
4. **Cheap rejects**: no corner in front → reject; all corners left of the
   left frustum → reject; none past the right frustum → reject.
5. **Project in-front corners** (recip + `br_project_x_auto`), classifying
   each `sx` into the `u8` screen range and tracking `min/max` plus the
   "any `sx ≥ 0`" / "any `sx ≤ 255`" side flags.
6. **Near-plane edge crossings**: for box edges straddling the near plane,
   solve `t = ((1 − vy_i) << 8) / (vy_j − vy_i)` with a restoring
   `crx_udiv` (`:2434`), interpolate the crossing `cx`, and classify it.
   At the near plane the reciprocal is the constant `(127,255)`, so the
   crossing `sx` classifies directly by `cx ∈ {≤−2,−1,0,1,≥2}` → `{<0, 0,
   128, 255, >255}` with no projection multiply.
7. **All-off-one-side reject** via the side flags from steps 5–6.
8. **`has_gap` query** on the clamped `[BBOX_ILO,BBOX_IHI]` (`$0969/$096A`)
   — see §3.5.

The result (A = 0 skip, A ≠ 0 visit) drives the walk.

## 2.3 The seg processor — `br_render_subsector` (`:1552`)

When a subsector is visited, its segs are drawn, then the clip-state
mutations are applied **in seg order, after all draws** (deferred). This
prevents coplanar walls within one subsector from splitting each other's
lines.

### Per-seg data, walked by persistent pointers

Two ROM tables are walked by pointers that simply advance per seg (no
per-seg multiply):

- **Seg header**, 12 bytes, `zp_seg_hdr_p` (`$96/$97`), `+=12`/seg:
  `v1 idx (u16)`, `v2 idx (u16)`, local `(lv1x,lv1y)` s16, local
  `(ldx,ldy)` s8, and a **flags** byte:
  `SF_SOLID $02`, `SF_NEEDBT $04`, `SF_NEEDBB $08`,
  `SF_NOVT1 $10`, `SF_NOVT2 $20`, `SF_APEDGE1 $40`, `SF_APEDGE2 $80`.
- **FHCH table** at `$B600`, 6 bytes, `zp_fhch_p` (`$98/$99`), `+=6`/seg:
  `fh, ch, (bfh | apv1_ch), (bch | apv1_fh), apv2_ch, apv2_fh`
  (front floor/ceil, back floor/ceil, aperture-vertical heights).

### Per-seg flow

```
for each seg in subsector:
    reset DCL record buffers ($0700 top, $0800 bot)
    back-face test  → if back-facing, advance
    read fh/ch (and back heights); height deltas = ch−vz, fh−vz, …
    xform v1, v2  (br_seg_xform_vertex → vertex cache §1.5)
    near-plane crossing reproject if exactly one vertex clipped
    has_gap visibility (§3.5)  → if no gap, advance
    emit lines via draw_clipped_line:
        solid wall    → top, bottom, left & right verticals
        ceiling step  → step edge + verticals (skip occluded front ceil)
        floor step    → step edge + verticals (skip occluded front floor)
    queue clip mutation:
        SOLID  → defq_append_solid   (mark_solid later)
        PORTAL → defq_append_tighten (tighten-from-records later)
end
defq_drain   ; apply all queued mutations in seg order
```

Aperture-edge verticals (the `SF_APEDGE1/2` / `SF_NOVT` flags) handle the
NOVT cases where a vertical sits on a portal aperture boundary rather than
a true wall edge.

### The deferred-op queue (`DEFQ_BASE = $0600`, 256 bytes)

Tail at `DEFQ_TAIL` (`$09FB`), overflow flag `DEFQ_OVF` (`$09FC`).

- **Solid entry** (3 bytes): `[$00, ilo, ihi]`.
- **Tighten entry** (variable): `[$01, ilo, ihi, top_block, bot_block]`,
  where each block is a **snapshot** of the DCL verdict records (`count`
  then `6·count` bytes) copied out of `$0700/$0800` *before* the next
  seg's DCL emission overwrites them — this realises Python's `deferred`
  list semantics, where the tighten captures the line's geometry as it was
  drawn.

`defq_drain` (`:2323`) replays the queue: solids call `span_mark_solid`,
tightens restore their snapshot and call `tighten_from_records`, and a
`span_is_full` check after each lets a fully-occluded subsector bail
early.

## 2.4 Visited bitmap (`$0A80`, 30 bytes)

Test instrumentation only (not used by traversal logic): each visited
subsector sets bit `id&7` of byte `id>>3`, so `test_bsp_walk.py` can
confirm the 6502 visit set matches the Python walk across 237 subsectors.

---

# §3 — The Windowed Clipped Renderer (`span_clip.asm`)

The visible region of the screen is maintained as a linked list of
non-overlapping **trapezoid spans**, each a column range `[xstart,xend]`
with linear top and bottom boundaries. As walls and portals are
processed, spans are occluded (`mark_solid`), narrowed (`tighten`), and
queried (`has_gap`); each seg's lines are clipped to the current spans and
rasterised. This is the analytical 2-D clipper — there is no per-column
scan in the production path.

## 3.1 The span pool (`$0400–$05FF`)

32 slots in **struct-of-arrays** (block-row) layout: each field is a
contiguous 32-byte block, so slot `N`'s field is `FIELD_BASE + N` and is
reached by `LDX slot : LDA FIELD,X`. Slot 0 is the null terminator.

| Field | Base | Mut? | Meaning |
|---|---|---|---|
| `POOL_NEXT` | `$0400` | — | next slot (0 = end of list) |
| `POOL_XLO` | `$0420` | immutable | line anchor x_left |
| `POOL_DEN` | `$0440` | immutable | `xhi − xlo` (interp denominator) |
| `POOL_TL` | `$0460` | immutable | top Y at XLO (`+Y_BIAS`) |
| `POOL_BL` | `$0480` | immutable | bot Y at XLO |
| `POOL_TR` | `$04A0` | immutable | top Y at XLO+DEN |
| `POOL_BR` | `$04C0` | immutable | bot Y at XLO+DEN |
| `POOL_XSTART` | `$04E0` | **mutable** | active aperture left |
| `POOL_XEND` | `$0500` | **mutable** | active aperture right |
| `POOL_OT/OB` | `$0520/$0540` | immutable | outer bbox `min(TL,TR)` / `max(BL,BR)` |
| `POOL_IT/IB` | `$0560/$0580` | immutable | inner bbox `max(TL,TR)` / `min(BL,BR)` |

The key design choice: the **line geometry** (`XLO,DEN,TL,BL,TR,BR`) is
*immutable for a span's lifetime*. Occlusion and narrowing only move the
mutable **active range** `[XSTART,XEND]`. When a span is split, the
sibling copies the geometry verbatim — no re-interpolation, no accumulated
error. The pre-computed inner/outer Y bboxes (`OT/OB/IT/IB`) give the line
clipper cheap accept/reject tests before any interpolation.

- **Free list**: head `zp_free` (`$C1`); `alloc_span` (`:308` area) pops a
  slot, `free_span` pushes one (tail-callable).
- **Active list**: head `zp_head` (`$C0`).
- `span_init` (`$2000`) seeds the active list with one full-screen span
  (`[0,255] × [Y_BIAS, VIS_YMAX]`) and chains slots 2..31 free.

## 3.2 `mark_solid` — occlusion (`:475`)

Removes columns `[ilo,ihi]` (a one-sided wall). It walks the list and,
per span, adjusts only the active range — **zero interpolation**:

| Case | Condition | Action |
|---|---|---|
| before | `xend ≤ ilo` | leave unchanged |
| no-left-frag | `xstart ≥ ilo` | shrink `xstart` past `ihi`, or free if fully covered |
| left-only | `xstart < ilo ≤ xend ≤ ihi` | truncate `xend = ilo−1` |
| middle split | `xstart < ilo`, `xend > ihi` | keep left frag; **alloc a sibling** for the right frag, copying geometry verbatim |

The first action invalidates the `has_gap` coherence cache
(`zp_hg_cache = 0`); see §3.5.

## 3.3 `tighten` — narrowing apertures (`:699`)

For a two-sided seg (step/window), the aperture must be narrowed to the
intersection of the old span and the seg's new top/bottom lines:
piecewise `max(old_top, new_top)` and `min(old_bot, new_bot)` over
`[ilo,ihi]`, splitting at any crossover where the two tops (or two bots)
swap order. There are two implementations:

- **`span_tighten` (legacy, seg-param form, `:699`)**: reconstructs the
  active list, walking old spans and, per overlap, taking tiered
  **dominance fast paths** (Tier 1 old-dominates / Tier 2 portal
  continuation / Tier 2b new-dominates) that skip interpolation when one
  boundary clearly wins, before falling to the full crossover pipeline.
  Contiguous constant-line outputs are merged by `tg_append_x`.
- **`tighten_from_records` (production, `:3385`, entry `$201B`)**: the
  records-driven path. Instead of recomputing the seg's screen geometry,
  it consumes the **verdict records** the DCL already produced for the
  seg's top and bottom lines, walking the top records, bottom records, and
  the pool spans together with **three monotonic cursors** (never a
  restart-from-start quadratic scan). At each column event it decides
  whether the new top/bottom comes from a record or the pool, emits the
  narrowed sub-span, and merges adjacent sub-spans with identical
  source-kind/id. This path must handle every case — there is no fallback
  to a generic recompute.

### TFS working set (`$0900–$091B`)

`tighten_from_records` keeps its cursors and pending-output span in a
dedicated block: `TFS_CUR_X $0900`, `TFS_X_HI $0901`, `TFS_NEXT_X $0902`,
top/bot dominance flags, interpolated `TOP_L/R`/`BOT_L/R`, the
`kind`(pool|record)/`id` of each boundary's source, the record cursors
`T_CUR`/`B_CUR`, and a buffered pending span (`PEND_*`) used for the merge
test. `emit_unchanged_subspan` (`:3695`) copies a pool span's geometry to
a fresh slot with a new active range for the parts of a span no record
touches.

## 3.4 Line clipping, portal walk, and the DCL backend

`draw_clipped_line` (`$2015`, s16 wrapper `$201E`) clips one line to the
current span list and rasterises the visible parts.

### Cyrus-Beck clip (`dcl_cb_clip`, `:2496`)

A line is clipped to a span's trapezoid via 4 half-planes: `x ≥ XSTART`,
`x ≤ XEND`, `y ≥ top(x)`, `y ≤ bot(x)`. The implementation:

1. X-clip the line endpoints to `[xstart,xend]`, evaluating line-Y there.
2. **Top clip**: a bbox filter (both endpoints below `IT`) skips it
   cheaply; otherwise evaluate `top()` at both ends and, on a sign change,
   solve the crossing column with `dcl_boundary_ix` (`:2723` —
   `x = cx1 + (cx2−cx1)·|d1| / (|d1|+|d2|)`, directed rounding). Reject if
   the whole segment is above.
3. **Bot clip**: identical, mirrored.
4. Reject if the result is degenerate (`cx1 > cx2`).

Vertical lines (`xl == xr`) take `dcl_vertical` (`:2425`): find the span
containing the column, interpolate the aperture there, clamp `[yl,yr]` to
`[top,bot]`, emit one vertical. (Slopes of 0 — flat ceiling/floor spans,
extremely common — short-circuit their multiplies to zero.)

### Portal walk

When a clipped line still reaches a span's right edge,
`dcl_extends_past` (`:2298`) tries to continue it through the **portal** to
the abutting span rather than re-clipping. The portal aperture at the
shared boundary `x` is `pt = max(TR_left, TL_right)`,
`pb = min(BR_left, BL_right)`; a three-tier test —

1. cheap accept: line's `[ylo,yhi] ⊂ [pt,pb]` → continue;
2. cheap reject: line entirely outside `[pt,pb]` → emit & reset;
3. exact: line-Y at the boundary inside `[pt,pb]`? → continue or emit —

lets a line crossing several contiguous spans emit as **one** segment
when the portals line up, and split only at real occlusion gaps.

### DCL emission and the rasteriser handoff

`dcl_emit_segment` (`:2786`) emits a visible `(x0,y0)→(x1,y1)`. It
**de-biases** Y (`− Y_BIAS`) into the NJ rasteriser's ZP and tail-jumps to
`RASTER_ENTRY` at `$A900`. The NJ linedraw backend (`$A900–$B55E`) owns ZP
`$74–$76,$79–$7A,$80–$88` and writes the mode-4 framebuffer at `$5800`.

When the **records hook** is armed (`zp_dcl_rec_buf_h ≠ 0`), each emitted
segment also writes a 4-byte record `(start_x,start_y,end_x,end_y)` and
bumps the count — this is the raw material the deferred-tighten snapshot
captures. `clip_line_records` (`$2018`) is the richer variant: it walks
the line against the spans and produces **6-byte per-span verdict
records** `(slot, sox0, sox1, verdict∈{above,inside,below}, cy0, cy1)`,
splitting at top/bot crossovers, into the `$0700`(top)/`$0800`(bot)
buffers that `tighten_from_records` later consumes.

## 3.5 `has_gap` / `is_full` and the coherence cache

- **`span_has_gap(lo,hi)` (`$2009`, `:592`)** → 1 if any active span's
  `[xstart,xend]` overlaps `[lo,hi]`. It is the visibility oracle for both
  bbox tests (§2.2) and per-seg culling (§2.3). A **coherence cache**
  (`zp_hg_cache`, `$D0`) remembers the last matching slot for an O(1)
  re-check; on a miss it walks the list.
- The cache is **invalidated (`= 0`) on every pool mutation** —
  `mark_solid` and `tighten` both clear it. This was a real bug fix:
  stale `XSTART/XEND` left in freed/split slots could otherwise produce a
  false-positive gap. (The Python-driven pipeline discarded the 6502
  `has_gap` result and so never saw it; the pure-6502 walk depends on it.)
- **`span_is_full` (`$200C`, `:625`)** → 1 iff `zp_head == 0` (no spans
  remain, i.e. the screen is fully occluded). Drives the early-out on
  every BSP pop and after every deferred mutation.

---

# §4 — Memory Map (test-harness layout)

| Region | Address | Notes |
|---|---|---|
| X region | `$0100-$01DF` | bbox edge-crossing math (low half of stack page) |
| Span read buffer | `$0300` | test harness only |
| **Span pool** | `$0400-$05FF` | §3.1 (struct-of-arrays, 32 slots) |
| **Deferred op queue** | `$0600-$06FF` | seg-ordered solid/tighten ops |
| **DCL records** | `$0700` / `$0800` | TOP / BOT verdict records |
| span_clip LC scratch | `$0900-$0958` | TFS working set ($0900–$091B) |
| BBox corners/vars | `$0960-$0976` | corners, ILO/IHI, DEFQ tail/ovf |
| D region | `$0978-$09FF` | crossing divide, classify, child resolver |
| **BSP stack** | `$0A00-$0A3F` | §2.1 |
| Seg/bbox scratch | `$0A40-$0A6B` | BBOX_CORNERS, seg vertex slots |
| Visited bitmap | `$0A80-$0A9D` | 30 bytes (test only) |
| B region | `$0AA0-$0BFF` | defq code, ev_clamp, project_x_auto |
| **Vertex cache** | `$0C00-$1A98` | 8 B × 467 (§1.5) |
| Vcache valid bitmap | `$1B00-$1B3A` | 59 bytes |
| lo region | `$1B40-$1FFF` | xform helpers, crossing, ap_edges |
| **span_clip + pool code** | `$2000-$4737` | §3 (jump table at $2000, umul8 pinned $2030) |
| **bsp_render main** | `$4800-$57FF` | §1/§2 |
| Screen | `$5800-$6BFF` | mode 4 framebuffer |
| ROM main | `$6C00-$A4B0` | node/seg/ss tables |
| **Rasteriser** | `$A900-$B55E` | NJ DCL backend (owns ZP $74-76,79-7A,80-88) |
| **FHCH table** | `$B600-$C577` | 6 B/seg |
| **BBox table** | `$C600-$D4BF` | 16 B/node |
| **Y-proj cache** | `$D4C0-$D9FF` | VWHC (§1.4) |
| **Recip table** | `$E000-$E483` | 514 hi + 514 lo |
| VWH heights | `$E484-$E939` | |

### Zero-page conventions

- `$05–$0A` per-frame trig triples; `$0B–$0E` frac vx/vy.
- `$11–$14` view `vx/vy`; `$17:18:2D` s24 mul/projection result;
  `$1A/$1B` reciprocal `rhi/rlo`; `$2E/$2F` view-X/Y extension bytes.
- `$30–$33` ROM table pointers (FHCH, BBox); `$4E` BSP stack pointer;
  `$58/$59` current child id; `$96–$99` persistent seg-header / FHCH
  pointers.
- `$90–$95` hold `pxraw/pyraw/v_xext/t4` — deliberately moved out of the
  rasteriser's `$71–$76` range, which the rasteriser clobbers per line.
- `$A0–$B9` are the span_clip "hook arg" slots (DCL line params, tighten
  running bounds, records buffer pointer at `$BC–$BF`).
- `$C0/$C1` span list head/free; `$C2–$CF` seg input params; `$D0`
  has_gap coherence cache; `$D9–$DB` shared mul/div I/O; `$E7–$FE`
  tighten/crossover working set.

---

# §5 — Validation and Performance

The 6502 engine is verified **against the Python FP reference**, not just
against itself (over-emission is a silent regression). At the 10 standard
suite positions it is framebuffer-identical at 9 and within 7 px at the
tenth (a flat lying exactly on a span bottom — an AP-skip predicate
difference, not a renderer divergence). Tooling: `compare_subsector.py`
(per-subsector differential — 0 px across 178 subsectors),
`compare_traversal.py` (visit-sequence isolation), `test_bsp_walk.py`
(visited-set match).

Cycle counts are always taken from **py65 simulation**, never estimated.
A 3-frame baseline of 4,002,663 cy was reduced to 3,518,511 (**−12.1%**),
output-identical, via: shared bbox rotation products (8 not 16 `rot_int`
per node-side), two-pass bbox rejects (frustum/all-behind before any
recip work), gated back-pair Y projections, persistent seg pointers,
folded `HALF_H+Y_BIAS`, the pinned `umul8`, and the Y-projection cache.
Per-frame cost ranges 65 k (trivial view) to 1.79 M cycles
(1500,−3700,0).

Python's AP-skip predicates (`line_above_spans` / `line_below_spans` /
`vertical_outside_spans`) were measured and **rejected** as an
optimisation: a zero-pixel DCL call averages only ~341 cy, so the
predicates would not pay for themselves. They remain solely the route to
the final 7 px of exactness if ever wanted.

The remaining milestone is hardware bring-up: jsbeeb/SSD integration of
the standalone module per the memory map above (note the X region living
in the stack page, and the harness-loaded tables at `$B600+/$C600+/
$E000+`).
