
; ============================================================================
; bbox_visible — node child-subtree visibility gate: is any part of the
; child's bounding box potentially on screen, and does the span list still
; have a gap in the box's column extent?
;
; Mirrors packed_render_bsp's per-child guard (doom_wireframe.py):
;   br = fp_bbox_visible_fixed(node, side, ctx)   # angle-space column extent
;   visible = (br is not None) and clips.has_gap(br[0], br[1])
;
; Inputs:
;   zp_node_ch_l        = node id (u8 — n_nodes <= 256, asserted at pack time)
;   zp_bbox_side        = 0 → right child's box, 1 → left child's box
;   Box table base is the ROM_BBOX_C layout.inc CONSTANT (the zp_rom_bbox
;   pointer pair was retired 2026-07-10): 16 bytes/node = two 8-byte
;   records (right box then left box), each (top, bot, left, right) s16,
;   page-aligned (corner loads build the pointer byte-at-a-time).
;   Per-frame presets (written by view/render setup, constant per frame):
;     bca_pxs/bca_pys   = player x/y sign-extended s16 ($8D/$8E, $9B/$9C)
;     bca_ab            = view angle byte; bca_afn = ab<<4 (hoisted fine angle)
; Output:
;   A = 1 (Z clear) if the box subtends visible screen columns AND
;       span_has_gap([bca_ilo, bca_ihi)) — HALF-OPEN, ihi exclusive
;       (certified 2026-08-21, see the extent-semantics block in
;       src/ang/bca.s) — subtree worth descending;
;   A = 0 (Z set) otherwise. Callers branch on Z (BEQ → skip subtree).
; Clobbers: A, X, Y; $86/$87 (bca_boxp); $C2/$C3 (zp_i_l/zp_i_h);
;   pages bank L2 then bank C in the banked build (caller re-pages after).
;
; Pseudocode:
;   boxp = rom_bbox + node*16 + side*8
;   vis, ilo, ihi = box_classify(boxp, px, py, ab)
;   if not vis: return 0                                 # culled/behind
;   return span_has_gap(ilo, ihi)      # occlusion query over [ilo, ihi)
; ============================================================================

; ============================================================================
; bbox_visible — THE walk-facing bbox entry.  It is a plain equate for
; box_classify: every frame classifies from scratch.  (Until 2026-09-04
; this was a vector through zp_bv_entry, pointing at one of three frame
; classes — a rotation-cache probe, a forward-coherence probe, or the
; pristine classifier.  Both caches are gone; see src/ang/bca.s.)
;   in : zp_node_ch_l/zp_bbox_side = box identity; frame ZP preset
;   out: C = combined verdict (has_gap over the check's extent) —
;        C-only since 2026-07-26; the walk branches BCS/BCC
; ============================================================================
; NO PAGE HERE (2026-08-29).  BANK_WALK is already live at entry: both
; callers -- walk.s r0 and its r1 mirror -- execute LDA NODE_DSGN,X
; immediately before the JSR, and the node SoA is bank B (BANK_WALK = 7).
; The walk has held that bank since the two-bank re-cut killed the four
; child-fetch PAGEs, which is what the r0_vis comment below already
; asserts.  Confirmed dynamically: tools/pagecensus.py over the 18-pose
; suite counts 19.6 executions/frame of this store and ZERO of them
; changing the bank.  A ROMSEL store costs 6 cycles whether or not the
; bank changes, so deleting it is worth ~118 cycles/frame.  The two
; labels are now aliases; bbox_visible_l2 keeps its name because the
; L2-proven arcs document why they may skip a page.
.import box_classify
; ALIASES, not a stub (2026-09-04): with one class left there is nothing
; to dispatch, so the JMP died too -- every caller now assembles a direct
; JSR to box_classify.  The names live on because the tools and the
; L2-proven arcs document their contracts.
bbox_visible = box_classify
bbox_visible_l2 = box_classify
.export bbox_visible_l2

SEG_CODE                         ; restore for subsequently-included parts
