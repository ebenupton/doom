# TODO

## Cross-implementation line count divergence
- 6502 and Python BSP traversals produce slightly different line sets
  (e.g., spawn East: 79 vs 87 lines after clipping)
- Root cause: minor differences in BSP traversal, projection, or span
  management between the native 6502 path and the Python FP reference
- The 6502 clipper itself is deterministic and produces correct screen
  coordinates (all in [0,255]×[0,159] range)
- Need a same-path verification: capture unclipped lines + span state
  from the 6502, clip with Python fp_clip_to_trap, compare against
  the 6502's clipped output

## Clipper performance
- Cyrus-Beck clipper adds ~1.4M cycles per frame (spawn East view)
- Total: 2.3M cycles = ~0.9 fps at 2MHz (was 888K = 2.3 fps unclipped)
- Optimisation opportunities:
  - Trivial reject via outer bbox (skip CB when line Y-range is
    entirely outside span bounds — 0 multiplies, 0 divisions)
  - Trivial accept via inner bbox (skip CB when line is fully inside —
    just clamp X endpoints, compute Y at clamped X)
  - Fast path for flat spans (ta=ba=0): constraints 3&4 become simple
    Y comparisons, no multiplies needed

## Keyboard input
- Add keyboard scanning for player movement on BBC
- virus repo has example keyboard scanning code
