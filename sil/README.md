# sil/ — E1M1 silhouette outlines

Simplified closed-outline versions of the E1M1 enemies and objects, for
Another-World-style 2D polygon rendering (scale + translate only, no 3D
math). Wireframe meshes don't read at ~40 px tall; the outline does.

## Run

    python3 sil/extract.py [path-to-DOOM1.WAD]

Defaults to `../DOOM1.WAD` (the shareware IWAD already at the repo root —
freely distributable; `e1m1_zkdepth.wad` is geometry-only, no sprites).
Requires PIL for the previews. Regenerates `silhouettes.py`,
`preview/*.png`, `report.txt`.

## Pipeline

1. **Lump read** — DOOM picture format; only the alpha mask (posts =
   opaque) matters for the outline. Palette indices are kept solely for
   the colour-derived internal strokes below.
2. **Marching squares** — walk of the mask's cell-edge grid yields exact
   closed boundary loops at integer pixel-corner coordinates (u8-safe,
   sprites are < 128 px). Checkerboard corners take the clockwise turn so
   diagonally-touching regions stay in separate loops. Holes ≥ 4 px² are
   kept (they carry pose information, e.g. between-legs gaps); smaller
   ones dropped.
3. **Douglas-Peucker** — one epsilon shared by all loops of a figure,
   binary-searched (48 iterations) to the smallest epsilon whose total
   segment count lands at or under the figure's budget.
4. **Mirrored rotations** — lumps like `TROOA2A8` serve two angles; the
   mirror is baked into the data by x-flip (`x' = w - x`, order reversed).

## Budgets (segments, incl. internal strokes)

| class | budget | rationale |
|---|---|---|
| POSS, SPOS (humanoids) | 16 | identity survives; ≤ 20 hard cap |
| TROO (imp) | 18 | front views need the head/shoulder spikes (eps was 5.5 px at 16) |
| BAR1, ARM1 | 10 | |
| STIM, MEDI, SBOX | 8 | |
| BON1, BON2, CLIP | 6 | tiny pickups |
| PLAY N (dead marine) | 12 | irregular corpse mass |
| PLAY W (bloody mess) | 10 | |

## Internal strokes (counted against the same budget)

Decided per figure from the overlay previews; most figures need none —
the enemies read from silhouette alone at these budgets.

* **MEDI / STIM** — outline alone is just a box; the red cross is the
  identity. Extracted from the red palette region and emitted as two
  straight open strokes (vertical + horizontal bar, 2 segments — not a
  12-segment plus-sign polygon).
* **BAR1** — a rounded box only becomes a barrel with the sludge-rim
  line: one horizontal stroke at the bottom edge of the bright-green
  (nukage) region, top half of the sprite only (the grey-green body
  fools a looser test).

## Data format (`silhouettes.py`)

`SILHOUETTES[(sprite, frame, rotation)]` → `size`, `offset` (DOOM sprite
left/top offsets, mirror-adjusted), `outline` (list of closed loops of
`(x, y)` pixel-corner points), `strokes` (open polylines), `segments`.
Rotation 0 = single-view object; rotations 1–8 for enemies with mirrors
already baked. Bytes at 2/point: see `report.txt` (962 B total roster).

## Review artifacts

`preview/POSS_A.png`, `preview/SPOS_A.png`, `preview/TROO_A.png` (8
rotations each), `preview/objects.png` — top row: sprite alpha (grey)
with outline (red) and strokes (blue) overlaid; bottom row: outline only.
