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

## Not yet in the engine

The ladder sizes are the gate: `obj_X` is 6 and `obj_Y` is 12.  Barrel fits
(6/9).  Pillar fits in x, wants 18 y.  Lamp wants 18 x / 20 y at L0 because its
radii are off the vertex ladder so its occlusion cuts mint new x values.
