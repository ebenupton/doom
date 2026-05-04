# bsp_render.asm — overnight progress

## What's working

**Phase A-E: arithmetic foundation + transforms**, all unit-tested via
`test_bsp_render.py` against `fp.py` reference. 100+ test cases pass:

- `br_umul8` — u8 × u8 → u16 (wraps span_clip's `umul8`)
- `br_smul8` — s8 × s8 → s16
- `br_smul_s8_u8` — s8 × u8 → s16
- `br_recip` — reciprocal lookup with 1-bit fractional averaging
- `br_frac_rot_term` — fractional rotation contribution
- `br_rot_int` — signed integer rotation (s16 × u8 → s16)
- `br_view_setup` — frac_vx, frac_vy for the frame
- `br_to_view` — world (s16 wx, wy) → view (s16 vx, vy in 8.8)
- `br_project_x_subpx` — view vx → screen sx (3 muls)
- `br_project_y` — height → screen sy (2 muls)

**BSP traversal** works via `test_bsp_walk.py` — visits all 237
subsectors of the test WAD using an iterative stack-based walk
(no recursion, 64-byte stack at $0A00). Side test is currently a
stub (always picks front), so traversal order isn't geometrically
correct — but every leaf is reached.

## What's blocked

**Per-seg line emission**. The scaffolding is in place
(`br_render_subsector` and the dead `br_transform_vertex` block in
the asm), but calling `JSR SC_DRAW_S16` or `JSR SC_DRAW_U8` from
inside `br_render_subsector` causes the simulator to end with PC
stuck at $0000 (infinite BRK loop). This is a stack-imbalance
symptom: something on the call path between bsp_render → DCL →
rasteriser is RTSing more times than it pushes, or doing
unbalanced PHA/PLA, in a way that's only exposed when DCL is
called nested rather than via py65's `_run` (which sets up just
one stack frame).

A standalone test that JSRs DCL twice-deep from a tiny stub at
$0500 *works* (`PC = $FF00` exit, both inner and outer stubs
return). So the imbalance is sensitive to the surrounding state
at the time of the call — not a fixed issue with DCL itself.

## To diagnose

The next session should add a py65 instruction-level trace inside
`br_render_subsector` between "before JSR DCL" and "after JSR DCL"
to find the exact instruction where the stack goes wrong. Look for:

- An RTS in DCL or rasteriser that pops more than its matching JSR
  pushed.
- A PHA/PLA imbalance somewhere in the rasteriser at $A900
  (`linedraw_or_reloc.bin` — 4 PHA / 2 PLA in the raw bytes,
  which might be data not code, but worth checking by disassembling).
- Anything that writes to the 6502 hardware stack page directly.

Once that's resolved, the existing scaffolding should produce a
partial render: each subsector emits one horizontal line per seg,
visible in the framebuffer. From there, fill in the back-face test,
the seg detail / VWH lookup, the records-mode tighten, and the
correct side-test for proper geometry.

## Test files

- `test_bsp_render.py` — 5 primitive tests (all pass).
- `test_bsp_walk.py` — BSP traversal smoke test (passes: 237/237).
- `test_bsp_render_frame.py` — end-to-end render attempt (currently
  produces 0 pixels; will work once the stack issue is resolved).
