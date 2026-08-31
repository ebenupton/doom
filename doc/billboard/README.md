# Billboard art — geometry, LODs and the checks

`billboard_art.html` is the published document (also an Artifact).  Everything
in it is generated; nothing is drawn by hand.

## The model

An object is a **stack of coaxial cylinders**, `(r, z0, z1)` bottom-to-top,
with r and the band heights read off the DOOM sprite at one pixel per world
unit.  The projection is not taken from the sprite: every rim is a circle, and
under perspective it projects to an ellipse with

    a = K·r/D            b = a·|z − z_eye|/D = a·e/K

where `e` is the rim's distance from the horizon in pixels and K = 152 px,
measured from the engine's own height-versus-distance sweep.  So **each rim
gets its own openness** — for a 128-unit pillar the top is 87 above the eye and
the base 41 below, and the top disc is over twice as open as the bottom.
See the `feedback-physical-not-sprite-fit` memory.

Eye height is the engine's: floor + 41, for everything standing on the
player's floor.

## Files

| file | what |
|---|---|
| `stack.py` | the model: `Stack`, `disc`, `cut`, the dodecagon ladder |
| `lod.py` | L0/L1/L2 tiers, per-object L1 config, `set_flat` |
| `objects.py` | the band tables for each object + the sprite-viewpoint fitter |
| `tables.py` | emits the 3D bands and the 2D templates as ladder indices |
| `armcheck.py` | asserts the armed rule |
| `engine_barrel.py` | the SHIPPING barrel art, rebuilt and verified against a live capture |
| `truth.py`, `truth2.py` | capture `obj_X`/`obj_Y`/`OBJ_ART` from a running render |
| `mkpage12.py` | builds the document |

## The invariants, all asserted

- **extent** — the drawn figure spans exactly the object's projected height.
  Rims are inset from the ends by their own arc depth, and that depth is the
  *tier's* (L0 reaches `b`, L1 only `q·b`, a flat rim 0).
- **joins** — every endpoint is shared with another segment or lies strictly
  inside one.  The only free ends are the shaft/stem termini that deliberately
  run half way into a disc's face.
- **armed = topmost** — the fused authority run must be the topmost line at
  every x.  A band's top arc is topmost only over the width no *higher* band
  covers, which is not always the adjacent one.  The engine's own OCT and HEX
  pass this same check.

## In the engine (2026-08-31)

All three L1 tiers ship in the BANKED build; `wad_packed.py` carries the
templates as ladder indices and `tools/test_pillar_ladder.py` /
`tools/test_lamp_ladder.py` gate the 6502 ladder builders against these
numbers.  `obj_Y` grew to 18 slots for the pillar; the lamp's 10-x/13-y
ladder fits by spilling its four inner +side x values into `obj_Y[13..16]`
(`obj_probe` requires +-a to stay at `obj_X+0`/`+10`).  OCT and RECT are
retired -- `obj_e` is a byte, and HEX 52 + LAMP 88 + PILLAR 96 = 236 is the
only cut of templates that fits 256.  Flat draws everything as the hex
barrel until the tube-parasite re-cut.

A shape-critical lesson learned landing the pillar: a billboard's every
dimension must be LINEAR in the projected height -- evaluate `b = a*e/K`
at the DESIGN distance, not per frame, or the discs open as the player
approaches (b ~ H^2) and the object visibly morphs.  L0 remains unused:
nothing selects tiers yet.
