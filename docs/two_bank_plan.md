# Two-Bank Layout Plan — seg/vert bank + walk bank

*IMPLEMENTED 2026-08-13 (same day). Measured: 332.8 -> 193.7 ROMSEL
writes/frame (-42%), banked -774 cyc/frame on the 6-position paging
set. Deviations from the plan below: VXCACHE/VRCACHE/bitmaps STAYED IN MAIN
(main is always visible — moving them buys no paging); VYCACHE went to
bank A (the y-stage holds A, so the 1K fits after the recip shrink);
the DIR planes ship in BOTH banks at $B700 (the shared
CROSS_MAG_DECIDE serves node classify under bank B and seg backface
under bank A — the one union consumer the plan missed).*

## Bank A — the SEG/VERT bank (held for pipeline stages 1–4)

| content                          | bytes  | notes |
|----------------------------------|--------|-------|
| seg headers (649 × 16)           | 10,384 | detail stream is dead — headers ARE the seg data |
| vertex planes VP_OX/OY/PG        |  1,536 | 3 × 512 (junior + senior halves) |
| VXCACHE planes (4 × 512)          |  2,048 | rhi, rlo (S=0 clip sentinel), sxl, sxh |
| VRCACHE planes (4 × 512)             |  2,048 | base counts |
| RECIP_M8 junior page (swapped)   |    256 | needs page alignment — NOT a tail |
| RECIP_M8H far half               |    128 | fits a plane tail |
| vertex bitmaps (3 × 57)          |    171 | VXCACHE_VALID, VDONE, VRCACHE_VALID — **the 455+57=512 tail fit**: live in plane tails, zero footprint |
| **total**                        | **16,101** | ≈ 280 spare (tail-packing the far half + bitmaps into the 11 × 57-byte senior-half tails is what makes it fit) |

Constraints: planes and RECIP_M8 must stay page-aligned; the tails are
the senior halves' 199-of-256 occupancy (57 free per plane half — 627
bytes of tail space against 299 needed). The VDONE crossing sentinel
needs the mask-zero trick from 04bb56d (no gap byte in a tail home).

## Bank B — the WALK bank (held for the whole BSP walk)

| content                          | bytes  | notes |
|----------------------------------|--------|-------|
| node SoA (14 pages)              |  3,584 | |
| bbox corner tables               |  4,096 | 4 × $400 planes |
| rcache psi planes + STATE        |  1,792 | the box memo (3 serve regimes) |
| RCACHE_COMPUTED bitmap           |     59 | box-indexed — belongs here, in a tail |
| CPM                              |    768 | corner-phi memo |
| angle tables (AE/atanexp, DIRs, sincos) | ~1,500 | the bca/backface table group |
| anim tables (TABL0/CFG/SSMASK_SRC) | ~1,024 | anim glue pages this bank once per tick |
| **total**                        | ~12,800 | ≈ 3.5K growth room |

## Bank C — unchanged
Clipper, NJ blob (unrolled steep), HUD, VDESC/VEXPL, vplot.

## Main RAM reclaim
VXCACHE (2K) + VRCACHE (2K) + bitmap page (256) leave main → **~4.3K
freed**. VYCACHE (4 planes, 1K — projection-phase, can't live in a bank
the y-stage doesn't hold... but the y-stage holds bank A; VYCACHE could
join A if 1K is found — it isn't; so) **VYCACHE moves to freed main**
($0800–$0BFF), which ALSO retires the exit-L2 consumer: the y-stage
becomes bank-agnostic. Net main free after VYCACHE: ~3.3K → CODE
headroom / future.

## Phase → bank map (the payoff)
- **Walk**: PAGE B once; nodes + bboxes + rcache + CPM all resident.
  Today's node(L0) ↔ bca-tables(L2) flipping dies (~100+ of the 143
  PAGE/frame).
- **Seg stages 1–4**: PAGE A once per seg batch; headers + verts +
  VXCACHE + VRCACHE + recips resident, VYCACHE in main. The transform's bank
  choreography (entry PAGE, exit-L2 contract, the with-back island's
  L0/L2 excursion) all collapse.
- **Stages 5–9**: PAGE C for the emit cascade, exactly as today.
- Estimated: −700 to −900 cycles/frame banked (paging alone), plus the
  structural deletions. Flat build unaffected; tube unaffected.

## Risks / prerequisites
- The CPM scar rule: scan the MERGED map before claiming any address;
  bankedcmp (flat-vs-banked) is the only gate that catches cross-build
  divergence.
- Full repack: wad_packed layout, gen_layout_inc, banked_bsp loader,
  build_walk disc, bare-boot validation, jsbeeb both models.
- Boot ordering: seed banks BEFORE define_bank (the vrcache landmine).
- Python mirrors follow the layout dict; the harness helpers that
  hardcode homes (the 120-byte wipe class of bug) need the by-symbol
  treatment first — partially done.
