# 6502-vs-Python divergence investigation (autonomous session)

Triggered by: "massive divergence on the RHS" in `play.py` at player
(1056, −3328, byte-angle 14), comparing PYTHON mode vs 6502 mode.

## TL;DR

**The 6502 is correct. `play.py`'s PYTHON mode is the buggy one.**

I confirmed this against the float renderer (`render_bsp`, highest fidelity)
as independent ground truth: at (1056,−3328,14) the disputed RHS wall really
exists (float draws it, 576 px), and the **6502 draws it too (599 px)**. It's
`render_bsp_fp` — the pure-Python fixed-point path that `play.py`'s PYTHON mode
uses — that *misses* it. So what looked like "the 6502 inventing a wall" is
actually "the Python mode dropping a wall the 6502 correctly draws."

This divergence was **introduced by my own earlier `play.py` optimization**:
to fix the slow/looking-frozen 6502 mode at a heavy viewpoint, I switched
PYTHON mode from the 6502-accurate `packed_render_bsp + Instrumented6502Spans`
path to the fast pure-Python `render_bsp_fp`. `render_bsp_fp` is a legacy path
that has drifted from the 6502.

## The verification gap (why nothing caught this)

`run_regression.py` / `sweep_verify.py` compare `trace_asm` vs `trace_hybrid`
— **both run the 6502 clip**. They verify the 6502 is *self-consistent*, not
that it matches the Python reference, and only at **integer** positions (the
harness does `px & 0xFF`). Nothing bit-compared 6502 *output* against a Python
reference at arbitrary (incl. sub-unit) viewpoints.

New tool: **`verify_6502_vs_python.py`** renders `BspRender6502` vs
`render_bsp_fp` and measures per-column vertical displacement of differing
pixels (≤2px = rasteriser aliasing — the 6502 Hamiltonian plotter vs
`pygame.draw.line`; more = real geometry/occlusion divergence). Single
position: `python3 verify_6502_vs_python.py 1056 -3328 14`.

## How far `render_bsp_fp` has drifted

Controlled (20 random viewpoints, fresh instances, displacement>2px):
`render_bsp_fp` diverges from the 6502 at **~35–40%** of viewpoints. Decomposed:

- **BSP/bbox pruning** — `render_bsp_fp` defaults to the legacy
  `fp_bbox_visible_fixed` projection bbox; the 6502 uses angle-space
  `bbox_check_angle`. Forcing `dw._USE_ANGLE_BBOX=True` makes traversal match
  exactly at the reported position (38→46 subsectors). But it's a *minor*
  factor overall (8/20 vs 7/20), so I did **not** wire it in by default.
- **Clip algorithm (dominant)** — `render_bsp_fp` uses the legacy
  `EndpointClipSpans` tighten; the 6502 uses the newer records-driven tighten.
  Different algorithms → different occlusion → most of the divergence. The
  6502 (records-driven) is the validated/correct one.

A pure-Python renderer fundamentally **cannot** be pixel-identical to the 6502:
the 6502 mode's pixels come from its own clip + Hamiltonian rasteriser. The
float `render_bsp` is the best-fidelity *geometry* reference.

## Real bugs found and FIXED this session

1. **Zero-width record → infinite loop (hang).** A seg projecting to one
   column wrote a degenerate `[xl==xr]` record; `tfs_inner` then spun forever
   (`bot_dom` needs `xl<=cur<xr`, impossible when `xl==xr`; cursor never
   advances). Observed at (1308,−3289,252): frame never completed.
   **Fix (committed):** skip zero-width records at the DCL write site.
   Verified: that frame now completes (875k cyc); regression GREEN; sweep clean.

2. **`_interp_store_s16` rounding mismatch.** The Python s16 seg-interp rounded
   half toward +inf (signed floor) while the 6502 `s16_interp` rounds half
   away-from-zero — diverging by 1px on descending lines at exact half-points,
   despite a comment claiming it matched the 6502. **Fix (committed):** aligned
   the Python reference to the 6502 (round half away-from-zero). Verified
   0/8000 mismatches vs the emulated interp; regression GREEN. (This is a
   latent consistency fix; it was not the cause of the reported divergence.)

3. **Off-framebuffer rasteriser write → memory corruption → crash.** Reported
   as "1056,−3291,34 hangs" — actually a crash (PC spins at $0000), not a hang.
   Fully traced in the *real* `BspRender6502` pipeline (not the harness shadow):
   - A wall-edge line whose projected biased Y is **below `Y_BIAS` (48)** — here
     biased Y=41, i.e. ~7px above the screen top — reaches `dcl_emit_segment`
     (the DCL wireframe emit, span_clip.asm). It un-biases with `SBC #Y_BIAS`,
     wrapping 41→**249**, and emits a line to row 29 (the 160-row / 20-char-row
     framebuffer is `$5800–$6C00`).
   - The line rasteriser (`linedraw` @ $A900, PC $B0E2/$B117) writes that wrapped
     row into **ROM_MAIN** (`$6C00+`), corrupting **node 39**'s left child from
     `$8029` to `$8829`.
   - BSP traversal then resolves child `$8829` → subsector **2089** (only 237
     exist) → garbage `seg_count` → out-of-range vertex index (~32945) →
     `br_seg_xform_vertex` stores the vcache valid-bit through a wild pointer
     into **code** (`STA ($1C),Y` @ $555B) → BRK → PC=$0000 spin (69M cycles).
   - Root: the DCL emit never clipped Y to the visible band. The `draw_clipped_line_s16`
     wrapper's Y-clip targets `[0,255]` (and is bypassed entirely by its
     all-coords-in-u8 fast path), so biased Y in `[0,47]`/`[208,255]`
     (off-screen but valid u8) slips through. The Python reference clamps Y to
     `[0,255]` too — it only avoids the wild write because `pygame.draw.line`
     auto-clips to the surface.
   **Fix (committed):** `dcl_emit_segment` now guards each emitted segment with a
   four-compare in-band check `[Y_BIAS, VIS_YMAX]`. In-band segments (every
   regression seg) are byte-identical. Off-band segments are clipped
   analytically to the band via `dcl_yband_clip` (reuses `s16_interp` with axes
   swapped: free=Y, target=X — interp X at the Y boundary) or dropped if the
   whole segment is off-screen. No clamping/distortion (per the analytical-clip
   rule). Verified: crash position completes (797k cyc); regression ALL GREEN
   (byte-identical); wild-write sweep clean.

## "Truncations" were a tool artifact, not hangs

The first sweep flagged many TRUNCATED frames. They all **complete fine with a
fresh instance** (88k–592k cyc) — the sweep was reusing one `BspRender6502`
across positions and a capped frame left it mid-routine, poisoning later ones.
`verify_6502_vs_python.py` now drops the instance after any non-completing
frame. No real new hangs exist (only the zero-width one, already fixed).

## Recommendations

- **Trust the 6502 mode** in `play.py` — it matches ground truth.
- For PYTHON mode, pick one:
  - *Accurate, slower:* revert to `packed_render_bsp + Instrumented6502Spans`
    (the regression reference; ~60fps normal, slow at heavy views).
  - *Fast, approximate (current):* keep `render_bsp_fp` but treat it as a fast
    preview, not a 6502-faithful reference. (Optionally default
    `_USE_ANGLE_BBOX=True` for closer traversal.)
- **Close the regression gap:** add a 6502-vs-Python *output* check (like
  `verify_6502_vs_python.py`) at integer AND sub-unit positions to CI, so
  6502-clip-vs-Python-clip drift is caught.
- The dominant remaining work, if 6502↔Python parity matters, is reconciling
  `render_bsp_fp`'s `EndpointClipSpans` tighten with the 6502 records-driven
  tighten (or retiring `render_bsp_fp` in favour of the records-driven path).
