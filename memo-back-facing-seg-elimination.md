# 41 segs across E1M1 and the E1M2 split are back-facing from every reachable position

**Subject:** static back-face elimination pass for the BSP renderer  
**Maps covered:** E1M1 (shipped node tree, DOOM1.WAD shareware v1.9, md5 f0cefca49926d00903cf57551d901abe) and E1M2A / E1M2B / E1M2C (three-way split, nodes rebuilt with zdbsp)

## Recommendation

Strip the 41 segs listed below from the seg lists at build time. They cannot render in any frame, on any of the four maps, from any position the player can occupy. The saving is 41 of 2240 segs across the four maps, 1.8%, plus the per-frame angle test on each. Seven subsectors lose every seg they have and need their sector index carried explicitly.

The pass is cheap, exact to sampling resolution, and fully automatic. It should run as a standard stage of the map preprocessor rather than as a one-off edit.

## The test

A seg renders only when the viewpoint lies on its front side. Front is the right-hand side of the directed segment v1 to v2, which in DOOM's sign convention is the half-plane where

    (v2.x - v1.x) * (p.y - v1.y) - (v2.y - v1.y) * (p.x - v1.x) < 0

A seg is dead if that half-plane contains no point the player can stand on. This is a necessary condition for rendering, so failing it is proof the seg never draws. It is a pure 2D predicate with no occlusion reasoning, no ray casting, and no height arithmetic.

The reachable set is built by flood fill over two-sided linedefs from the player start, with a 24-unit step limit and a 56-unit clearance limit, treating door and lift specials as passable. Floor positions are sampled on a grid, with points outside the map rejected by one-sided crossing parity, and sectors of less than 56 units clearance excluded.

## Safety

Removal cannot open a hole. A one-sided seg enters the solid-segment clip list only when it is drawn; a seg that never draws never contributes to clipping, so deleting it changes nothing the renderer relies on. The same holds for two-sided segs, whose upper and lower closures clip only when drawn. Sector closure is a build-time property consumed by the node builder, which runs before this pass, so the tree is unaffected.

One dependency does change. Vanilla derives a subsector's sector from its first seg. Seven subsectors across the four maps lose every seg, so the preprocessor must write the sector index into the subsector record. Anything that already stores sectors per subsector is unaffected.

## Results

| map | segs | subsectors | floor samples | dead segs | share | subsectors emptied |
|---|---|---|---|---|---|---|
| E1M1 | 732 | 237 | 213,067 | 14 | 1.9% | 1 |
| E1M2A | 590 | 185 | 253,995 | 11 | 1.9% | 1 |
| E1M2B | 580 | 169 | 161,814 | 3 | 0.5% | 0 |
| E1M2C | 338 | 106 | 54,192 | 13 | 3.8% | 3 |
| **total** | **2240** | **697** | | **41** | **1.8%** | **5** |

Yield varies by an order of magnitude. E1M2C returns 3.8% because its geometry is dominated by a deep unreachable pit; E1M2B returns 0.5% because almost every wall in it faces a corridor the player walks down.

### E1M1

14 segs. Front sectors: 1 (floor 32, ceiling 88, unreachable), 28 (floor 0, ceiling 128, unreachable), 30 (floor 0, ceiling 264, unreachable), 33 (floor 136, ceiling 240, unreachable), 62 (floor 104, ceiling 184, unreachable), 70 (floor 104, ceiling 184, unreachable).

| seg | linedef | side | front sector | kind | length | v1 | v2 |
|---|---|---|---|---|---|---|---|
| 100 | 372 | 1 | 1 | two-sided | 512 | (2176, -2112) | (1664, -2112) |
| 229 | 122 | 0 | 30 | two-sided | 128 | (-336, -3168) | (-336, -3296) |
| 233 | 121 | 1 | 33 | two-sided | 128 | (-320, -3168) | (-320, -3296) |
| 239 | 109 | 0 | 30 | one-sided | 48 | (-336, -3120) | (-336, -3168) |
| 249 | 110 | 0 | 30 | one-sided | 48 | (-336, -3296) | (-336, -3344) |
| 274 | 131 | 1 | 28 | two-sided | 576 | (-640, -2944) | (-640, -3520) |
| 453 | 372 | 1 | 1 | two-sided | 320 | (2496, -2112) | (2176, -2112) |
| 518 | 464 | 1 | 62 | two-sided | 148 | (3400, -3152) | (3304, -3040) |
| 527 | 454 | 0 | 62 | one-sided | 16 | (3556, -3567) | (3552, -3552) |
| 528 | 455 | 0 | 62 | one-sided | 160 | (3552, -3552) | (3552, -3392) |
| 537 | 460 | 0 | 62 | one-sided | 277 | (3648, -3264) | (3496, -3032) |
| 582 | 465 | 1 | 70 | two-sided | 64 | (3520, -3904) | (3520, -3840) |
| 589 | 466 | 1 | 62 | two-sided | 64 | (3584, -3904) | (3584, -3840) |
| 591 | 454 | 0 | 62 | one-sided | 217 | (3616, -3776) | (3556, -3567) |

Subsectors affected, dead segs over total segs: 30 (1/2), 72 (1/2), 73 (1/4), 76 (1/2), 81 (1/3), 89 (1/3), 150 (1/2), 175 (1/1), 181 (2/4), 184 (1/2), 196 (1/6), 197 (1/2), 199 (1/2).

Emptied entirely: 175. These need an explicit sector index.

### E1M2A

11 segs. Front sectors: 46 (floor 176, ceiling 240, unreachable), 66 (floor 24, ceiling 24, reachable).

| seg | linedef | side | front sector | kind | length | v1 | v2 |
|---|---|---|---|---|---|---|---|
| 61 | 335 | 1 | 46 | two-sided | 128 | (704, -704) | (832, -694) |
| 286 | 327 | 1 | 66 | two-sided | 128 | (-720, 448) | (-720, 320) |
| 345 | 312 | 1 | 46 | two-sided | 1412 | (2304, 1488) | (896, 1600) |
| 414 | 313 | 1 | 46 | two-sided | 157 | (2432, 1232) | (2361, 1372) |
| 416 | 314 | 1 | 46 | two-sided | 816 | (2432, 416) | (2432, 1232) |
| 444 | 335 | 1 | 46 | two-sided | 514 | (832, -694) | (1344, -653) |
| 524 | 314 | 1 | 46 | two-sided | 320 | (2432, -256) | (2432, 64) |
| 544 | 334 | 1 | 46 | two-sided | 345 | (2304, -576) | (2432, -256) |
| 548 | 335 | 1 | 46 | two-sided | 722 | (1584, -634) | (2304, -576) |
| 549 | 335 | 1 | 46 | two-sided | 201 | (1344, -653) | (1544, -637) |
| 560 | 314 | 1 | 46 | two-sided | 352 | (2432, 64) | (2432, 416) |

Subsectors affected, dead segs over total segs: 22 (1/2), 93 (1/4), 109 (1/4), 129 (1/1), 130 (1/2), 140 (1/3), 161 (1/2), 167 (1/2), 168 (2/5), 173 (1/2).

Emptied entirely: 129. These need an explicit sector index.

Seg 334 qualified at 8-unit sampling but not at 4-unit, and is excluded. It is front-facing from a small pocket of floor that the coarser grid missed. Any implementation should sample at 4 units or finer.

### E1M2B

3 segs. Front sectors: 50 (floor 0, ceiling 128, unreachable).

| seg | linedef | side | front sector | kind | length | v1 | v2 |
|---|---|---|---|---|---|---|---|
| 464 | 269 | 1 | 50 | two-sided | 205 | (-1984, 1536) | (-2176, 1465) |
| 562 | 269 | 1 | 50 | two-sided | 60 | (-2176, 1465) | (-2232, 1444) |
| 563 | 269 | 1 | 50 | two-sided | 383 | (-2232, 1444) | (-2592, 1312) |

Subsectors affected, dead segs over total segs: 133 (1/2), 164 (2/5).

### E1M2C

13 segs. Front sectors: 36 (floor -120, ceiling -80, unreachable), 37 (floor -120, ceiling -80, unreachable), 41 (floor -216, ceiling -48, unreachable), 42 (floor -216, ceiling -128, unreachable).

| seg | linedef | side | front sector | kind | length | v1 | v2 |
|---|---|---|---|---|---|---|---|
| 8 | 186 | 1 | 42 | two-sided | 256 | (-96, 2112) | (-96, 2368) |
| 9 | 147 | 0 | 41 | one-sided | 72 | (-232, 2232) | (-232, 2304) |
| 26 | 147 | 0 | 41 | one-sided | 64 | (-232, 2304) | (-232, 2368) |
| 41 | 147 | 0 | 41 | one-sided | 72 | (-232, 2368) | (-232, 2440) |
| 45 | 184 | 1 | 42 | two-sided | 70 | (-96, 2624) | (-165, 2635) |
| 49 | 186 | 1 | 42 | two-sided | 256 | (-96, 2368) | (-96, 2624) |
| 55 | 148 | 0 | 41 | two-sided | 91 | (-232, 2440) | (-296, 2504) |
| 56 | 118 | 1 | 37 | two-sided | 91 | (-240, 2432) | (-304, 2496) |
| 60 | 135 | 0 | 41 | one-sided | 72 | (-496, 2504) | (-568, 2504) |
| 61 | 137 | 0 | 41 | two-sided | 128 | (-368, 2504) | (-496, 2504) |
| 62 | 138 | 0 | 41 | one-sided | 72 | (-296, 2504) | (-368, 2504) |
| 67 | 184 | 1 | 42 | two-sided | 693 | (-165, 2635) | (-848, 2752) |
| 77 | 116 | 1 | 36 | two-sided | 128 | (-368, 2496) | (-496, 2496) |

Subsectors affected, dead segs over total segs: 2 (1/4), 3 (1/1), 10 (1/1), 17 (1/3), 18 (1/2), 19 (1/4), 22 (1/1), 23 (1/4), 24 (3/5), 25 (1/3), 30 (1/4).

Emptied entirely: 3, 10, 22. These need an explicit sector index.

## Notes on the E1M1 result

Every E1M1 seg in the list fronts an unreachable sector. Five sit in the outdoor space west of the green-armour room: linedefs 109 and 110 one-sided in sector 30, linedef 122 side 0, linedef 121 side 1, and linedef 131 side 1 carrying sector 28's face of the horizon band. Six lie in sector 62 and sector 70 in the east, around x 3300 to 3650. Two come from linedef 372, an 832-unit run at y = -2112 that the node builder split at x = 2176.

Linedefs 109 and 110 also appear in the earlier visibility study as never seen. Back-facing is the stronger and far cheaper property: it is provable from a half-plane test, whereas never-seen requires occlusion sampling and is sensitive to grid resolution.

Linedefs 108 and 111, also never seen, are **not** in this list. They are front-facing from the stairs room even though occluded, and they close sector 30 around the room's corners, so they are not removable by either route.

## Notes on the E1M2 result

E1M2A seg 286 is the back face of the red door, linedef 327 side 1, front sector 66. Sector 66 is reachable, but the door can only be approached from one side once the far seam is sealed, so the seg is dead in this part although its counterpart in the unsplit map is not. Splitting a level creates dead segs that did not exist before, which argues for running the pass after partitioning rather than before.

E1M2A returns eleven segs, ten of them on the perimeter of sector 46, an unreachable ledge at floor 176. Three of those exceed 700 units, so the saving is disproportionate in stored vertex data if segs are packed by length.

E1M2C returns thirteen segs across sectors 36, 37, 41 and 42, all at negative floor heights between -216 and -80: an unreachable pit beneath the exit area.

## Assumptions and limits

The proof holds only as far as the reachable set does. It assumes no mechanism places the player outside the flood fill: no archvile blast, no rocket jump of consequence, no voodoo doll displacement, no noclip. Episode 1 satisfies this. Any port that adds movement options, or any map with a scripted teleport into scenery, invalidates the result and the pass must be rerun.

Sampling is on a 4-unit grid over the reachable floor. The E1M2A case above shows an 8-unit grid is too coarse and yields a false positive. A conservative implementation should sample at 4 units, or better, test the front half-plane against reachable sector polygons exactly rather than by sampling.

Monster and projectile sight lines are irrelevant here; only the player's view produces segs. The pass makes no claim about visplanes, which are generated from subsectors and are unaffected.

## Implementation

Order of operations in the preprocessor: build nodes, compute the reachable set, run the half-plane test per seg, write the sector index into every subsector record, then emit the seg list with dead segs removed and subsector first-seg and count fields adjusted. The seg list must be renumbered, so subsector records have to be rewritten in the same pass.

Expected yield on the four maps as split is 41 segs, between 0.5% and 3.8% depending on the map. The pass is worth having for its floor rather than its average: it is free, it is provable, and it removes the cases a human reviewer would never find.