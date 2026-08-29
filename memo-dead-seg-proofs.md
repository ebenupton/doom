# Formal never-renderable proofs: 5 segs, not 14

**Re:** memo-back-facing-seg-elimination.md (E1M1 claims only)
**Tool:** `tools/prove_dead_segs.py` — regenerates every certificate; exact
integer arithmetic throughout, no sampling anywhere.

## Theorem shape

For each candidate seg s: *the engine never draws s*, proved as

- **Lemma A (backface exactness).** The engine draws s only if the viewer
  center lies strictly inside a half-plane whose parameters are the packed
  engine bytes themselves (axis: baked form/C16 with the pack-folded tie;
  diagonal: folded DIR deltas + LV1 reference with sub-prescale K residues,
  tie draws only if dyp>0). The exact-backface arc makes the engine verdict
  equal the true sign — there is no numeric slack to argue about, and the
  proof speaks about the literal shipped constants.
- **Lemma B (containment).** The viewer center stays in the closed union of
  R+ = sectors flood-reachable from spawn, where a two-sided edge is
  passable iff step<=24 AND opening>=56 at SOME mover phase. Both conditions
  are monotone in each mover height, so testing the [far,rest] interval
  endpoints is an exact exists-phase test. One-sided lines block;
  ML_BLOCKING is ignored (over-approximation). pmove — the only mover of
  the player, colmap.py being its single canonical rule statement — rejects
  any center path crossing an edge that fails these tests at live heights.
  R+ = 75 of 85 sectors.
- **Certificate C.** A sector's closure lies in the convex hull of its
  linedef vertices; the draw predicate is linear; its maximum over the hull
  is attained at a vertex. Checking every vertex of every R+ sector (352
  vertices) against the half-plane therefore decides the theorem exactly.

## Proved never-renderable (margins in engine counts, 1 count = 8 wu)

| seg | linedef/side | draw condition | worst reachable vertex | margin |
|---|---|---|---|---|
| 659 | 109 s0 | x_int < -192 | (-320,-3296) | -2 |
| 660 | 122 s0 | x_int < -192 | (-320,-3296) | -2 |
| 670 | 121 s1 | x_int < -190 | (-320,-3296) | 0 (tie culls) |
| 676 | 110 s0 | x_int < -192 | (-320,-3296) | -2 |
| 709 | 131 s1 | x_int < -230 | (-320,-3296) | -40 |

All five are the west-lobe group: no reachable sector owns any vertex west
of world x=-320, so no reachable point (integer or fractional) can be
strictly front. Seg 670 (ld121) is settled by the engine's exact tie rule:
the boundary itself culls.

## Refuted (the memo's other 9 E1M1 segs)

- **East group (7 segs; memo front sectors 62/70 "unreachable"):** false.
  The player rides lift sector 70 (enter from sector 58 at the lift's far
  pose, floor -48; exit at rest, floor 104, into sector 62) — E1M1's
  ordinary secret-courtyard route. From inside 62/70 these walls draw.
  The visibility corpus contains the counterexamples: poses like
  (3584,-3840) draw segs 164/168/169. Any flood that misses this either
  used a symmetric step rule or did not model riding a lift between its
  poses.
- **ld372 s1 (memo segs 100/453):** its front half-plane is y>-2112, which
  contains the reachable northwest rooms (sectors 2/3/24/41). Fails the
  memo's own half-plane standard; it is occlusion, not facing, that hides
  this wall, and the memo explicitly does not claim occlusion proofs.
- Control: ld111 (known drawable from the armour courtyard) correctly
  fails certification.

## Assumptions

Spawn = the shipped spawn (1056,-3616); movement only via pmove (no
teleports exist in this engine; the exit switch respawns to spawn, inside
R+); mover heights within [far,rest] per anim_sectors. Lemma A rests on
the packed-mirror/6502 bit-identity maintained by the regression gates.
