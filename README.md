# DOOM on the BBC Micro

A wireframe port of DOOM's E1M1 — running on a stock 1981 **BBC Micro Model B**
(2MHz 6502, 32K + sideways RAM). Full BSP traversal, analytical hidden-surface
removal, perspective projection, walkable with working doors and lifts, at
roughly **7 frames per second**.

Boot `doom_walk.ssd` on a Model B with sideways RAM (or drag it into
[jsbeeb](https://bbc.xania.org/)): cursor keys to turn and move, and the
level's doors and platforms cycle on their own as you explore.

## Why this is hard

DOOM's renderer leans on a 32-bit CPU: 16.16 fixed point, 64KB of lookup
tables, hardware-friendly column drawing. The BBC Micro has a 2MHz 8-bit 6502
with **no multiply instruction**, 32K of main RAM (5K of which is the
framebuffer), and a 16K banked window for everything else. Every design
decision below falls out of those constraints.

## The engine

**Analytical span occlusion instead of column arrays.** DOOM clips against
per-column floor/ceiling arrays — 320 bytes touched per portal. This engine
keeps the visible region as a **linked list of trapezoid spans** (32-slot
pool), each with linear top/bottom edges. Solid walls `mark_solid` a column
range; portals `tighten` the aperture; the BSP walk prunes whole subtrees
with `has_gap`/`is_full`. A frame's occlusion state is a handful of spans,
not kilobytes of arrays.

**Records-driven clipping.** Each seg's edge lines are clipped by DCL
(draw-clipped-line) against the span list, which emits the visible fragments
to the rasteriser *and* writes per-span verdict records as a side effect. The
subsequent `tighten` replays those records instead of re-deriving
intersections — the geometry is computed exactly once.

**Angle-space bbox culling, Cartesian vertex projection.** Node bounding
boxes are tested DOOM-style in angle space (octant fold → exact `SlopeDiv` →
`tantoangle`), zero multiplies and one divide per silhouette corner. Vertices
that survive go through an s24 view transform built entirely from an 8×8→16
quarter-square multiply — the only multiply primitive in the engine — then a
9.1 reciprocal table for perspective.

**Everything pre-baked.** A pack stage (inspired by
[Doom8088](https://github.com/FrenkelS/Doom8088)'s jWadUtil philosophy)
precomputes what DOOM computed per frame: seg flags (solid/portal/step),
suppressed verticals (BSP-split seams and colinear joins are detected at
build time — 494 fake edges never drawn), merged colinear segs, per-seg
lengths, and the **partition type of every BSP node**. Node and subsector
tables are stored as page-aligned structure-of-arrays, so every field read
is a single `LDA table,X` — the 73% of nodes with axis-aligned partitions
load exactly the two bytes their side test needs.

## Frame coherence — the caches

The engine exploits temporal coherence with two exact (bit-identical output)
caches, both driven by per-frame classifiers that self-modify the dispatch:

- **Rotation coherence:** a bbox corner's angle ψ depends only on *position*.
  While the player rotates in place, every bbox check reuses cached ψ values
  and just re-subtracts the view angle — **16.5% off** render time on
  stable-position frames.
- **Translation coherence:** the view transform is exactly linear in the
  integer world deltas, so between same-angle frames every vertex's view
  coordinates shift by one per-frame constant. The cache stores
  `base = total − CACC` and reconstructs `total = base + CACC`, a telescoping
  identity that stays exact across any walk (forward, back, strafe,
  fractional steps) and any number of frames unseen — **8%+ off** walking
  frames, replacing a 1,100-cycle transform with six loads and adds.

## Animated sectors

Doors, the lift, and the zigzag floor run real state machines on the 6502.
The trick is *lazy visibility-driven patching*: logical heights tick every
frame for a few bytes of state, but the renderer's tables (heights, private
projection slots, solid/portal seg flags re-derived with the packer's own
rules) are only rewritten when the BSP walk first visits a subsector
containing that mover — an invisible door costs **zero** table writes, and a
closed one occludes correctly through the ordinary span machinery with no
special casing.

## The display

Mode 4 (256×160 window), double-buffered. The vertical blank is tracked by a
6522 timer locked to exactly one 312-line PAL field (the OS default interlace
setting drifts 32µs per field — one of the more entertaining bugs); frame
clears are split into beam classes and scheduled *behind the raster*, so the
whole 5K clear costs no visible time and nothing flickers.

## Correctness discipline

The native engine is developed in lockstep with a Python reference that
mirrors it bit-for-bit — same 8×8 multiply primitive, same tables, same
rounding. The rasteriser has a pure-Python twin proven pixel-exact over a
42,462-line corpus, which makes whole-frame comparisons byte-exact:

- a regression suite gates every commit on framebuffer identity across 18
  positions *and* on total cycle count (no silent slowdowns);
- caches and movers get dedicated exactness gates (cache-on must equal
  cache-off byte-for-byte);
- a soak harness rendered **272,392 random positions/orientations** against
  the reference — zero crashes, zero cache divergences;
- everything runs under a cycle-accurate 6502 simulator, and hardware
  behaviour is validated in jsbeeb before anything ships to a disc image.

## Building and running

Needs `DOOM1.WAD` (shareware) in the repo root, Python 3 with pygame and
py65, the vendored `beebasm`, and `ca65`/`ld65` (cc65) on the PATH for
the engine link.

```
python3 play.py               # interactive: pure-Python engine (fast), or
                              #   M = the real 6502 pipeline under simulation
python3 build_walk_ssd.py     # build the walkable disc -> doom_walk.ssd
```

Disc images: `doom_walk.ssd` (walkable, animated sectors), `doom_spin.ssd`
(rotating demo), for a Model B with sideways RAM banks 4/6/7 — plain
B + SWRAM, no Master required.

## Layout

| | |
|---|---|
| `src/bsp/` | BSP walk, view transform, seg pipeline, caches, movers |
| `src/clip/` | span pool, DCL, records-driven tighten, plotters |
| `src/ang/` | SlopeDiv, point-to-angle, angle-space bbox, ψ cache |
| `raster/` | the NJ linedraw4 rasteriser (vendored) |
| `wad_packed.py` | the pack stage: WAD → prescaled SoA tables |
| `doom_wireframe.py`, `fp.py` | the bit-exact Python reference pipeline |
| `ENGINE.md` | the engineering map: memory layout, invariants, ZP registry |

This tree is deliberately minimal: just the engine sources, the pack
stage, `play.py`, and the disc builds. The full development toolchain —
the cycle-gated regression suite, the 272k-frame soak harness, cache
exactness gates, lockstep comparators and profilers — lives intact at
the [`full-toolchain`](../../tree/full-toolchain) tag.

---

Level data © id Software (shareware `DOOM1.WAD`, not included). Rasteriser
by NJ. Built with [beebasm](https://github.com/stardot/beebasm) and
validated on [jsbeeb](https://github.com/mattgodbolt/jsbeeb).
