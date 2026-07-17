
; ============================================================================
; br_bbox_visible — node child-subtree visibility gate: is any part of the
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
;       span_has_gap([bca_ilo, bca_ihi]) — subtree worth descending;
;   A = 0 (Z set) otherwise. Callers branch on Z (BEQ → skip subtree).
; Clobbers: A, X, Y; $86/$87 (bca_boxp); $C2/$C3 (zp_i_l/zp_i_h);
;   pages bank L2 then bank C in the banked build (caller re-pages after).
;
; Pseudocode:
;   boxp = rom_bbox + node*16 + side*8
;   vis, ilo, ihi = bbox_check_angle(boxp, px, py, ab)   # bca_check_op
;   if not vis: return 0                                 # culled/behind
;   return span_has_gap(ilo, ihi)                        # occlusion query
; ============================================================================
; ============================================================================
; Forward-coherence bbox cache ("D cache", 2026-07-08).
;
; While the player only moves FORWARD (any movement vector inside the
; closed 90-degree view cone, angle byte unchanged), three theorems make
; last frame's bbox verdicts reusable with zero risk of missing pixels:
;   1. INVISIBLE persists: the forward-translated view wedge is a subset
;      of the previous wedge (sum of two vectors in a convex cone stays
;      in the cone), so a box wholly outside stays wholly outside. Exact.
;   2. VISIBLE may be served stale: treating an invisible box as visible
;      only over-descends, and over-traversal is pixel-safe (subtree
;      draws nothing). Entries re-check every 8th qualifying frame
;      (round-robin by node id) so staleness is bounded.
;   3. Extents open away from the focus of expansion: moving forward,
;      every point right of screen centre migrates right, left migrates
;      left (|bearing| grows monotonically; off-frustum points stay
;      off on their side). So a cached extent wholly right of centre
;      serves as (x0,255), wholly left as (0,x1), straddling as (0,255)
;      -- always a superset of the true extent, keeping the has_gap
;      column gate on the centre-facing edge where the apertures are.
;
; One code byte per (node, side):
;   0-124   left-of-centre box: serve (0, code)
;   125     invalid (recompute)
;   126     invisible: serve reject (exempt from refresh -- theorem 1)
;   127     straddles centre: serve (0, 255)
;   128-255 right-of-centre box: serve (code, 255)
;
; br_dcache_frame (below, called per frame from br_view_setup) classifies
; the frame: stationary same-angle or forward-move same-angle (driver
; asserts D_FWD; a bounds-reverted step nets to stationary) -> serve;
; anything else -> wipe to 125s and rebuild. Measured (phase-0 sim,
; 32-frame walks): ~90% of checks served at 1/8 refresh, subsector
; over-descent +6-17/frame, ZERO pixel divergence (and provably none).
; Default OFF (D_ENABLE=0): every existing test/frame is byte-identical.
; ============================================================================
; Data home (BOTH builds): the old OS workspace pages at $0210-$03F7.
; The engine owns OS space after boot (feedback_no_os_calls: the OS is
; never re-entered), DFS only needs these pages DURING boot — before the
; driver sets D_ENABLE — and the flat py65 harness provably never touches
; them (empirical full-memory write/read map, 2026-07-08). Garbage
; contents at first enable are safe: the first classified frame has no
; matching D_PREVP, takes the wipe path, and rebuilds.
D_MODE   = $0210                        ; 0 off / 1 store-only / 2 serve
D_FRAME  = $0211                        ; forward-run frame counter (mod 8 used)
D_PREV_AB = $0212
D_PREVP  = $0213                        ; 6 bytes (full 8.8 x/y position)
D_CODE_R = $0220                        ; 236 bytes (right-child codes by node)
D_CODE_L = $030C                        ; 236 bytes (ends $03F7)
; (D_ENABLE/D_FWD come from abi.inc — driver/harness write them;
; D_FWD: 1 = this frame's move was
                                        ; forward-only (driver-asserted)
.export D_ENABLE, D_FWD, D_MODE, D_FRAME
.export bca_check_op                    ; SMC site — operand patched by bca_frame

br_bbox_visible:
.scope
   PAGE BANK_L2                            ; bbox + angle tables (TA/VATOX) live in bank L2
; (The bca_boxp pointer build is GONE, 2026-07-15: corners live in
; page-split planes read abs,Y by the angle module's side/zone arms —
; zp_node_ch_l and zp_bbox_side ARE the box identity.)

; --- Angle-space visibility (px=$01, py=$03, ab=$FA2F preset per frame) ---
; bbox_check_angle (angle module, DOOM R_CheckBBox in the unsigned-BAM
; phi convention; angle_bbox.py mirror): picks the 2 silhouette corners
; for the player's zone, converts their angles to a conservative column
; extent, clips against the view cone. Writes bca_vis (1=some columns
; visible, 0=cull) and bca_ilo/bca_ihi (u8 column extent, ±1
; conservative). SMC: bca_frame (rcache.s) retargets the operand each
; frame — bbox_check_angle (moved/disabled) or bbox_check_angle_cached
; (stable frame). Genuine dynamic dispatch, patched at the call site.
::bca_check_op:
   JSR bbox_check_angle                    ; returns A/Z = bca_vis (byte
                                           ; still written for the D store)
   BNE bv_anglevis
   RTS                                     ; A=0/Z=1 already: bbox_check_angle's
                                           ; cull tail (bca.s) sets A=0 before
                                           ; RTS, and both SMC targets share it
; box wholly outside view cone → invisible (A=0, Z set)
bv_anglevis:
; Visible columns exist — ask the clipper whether any of them still
; have an open span. Tail-call: SC_HAS_GAP's A (1=gap, 0=fully
; occluded) and flags are our return value.
   LDA bca_ilo
   STA zp_i_l
; zp_i_l
   LDA bca_ihi
   STA zp_i_h
; zp_i_h (has_gap is main-resident — no PAGE)
   JMP SC_HAS_GAP

.endscope

; ============================================================================
; br_bbox_visible_d — D-cache wrapper around the pristine check above.
; The walk's two JSR operands are SMC-patched here by br_dcache_frame on
; frames where the cache is active (and back to br_bbox_visible when not,
; so the disabled path is byte-identical to the original engine).
;
; Serve rule: decode the (node, side) code byte; invisible → exact reject
; (convex-cone theorem: forward-cone movement keeps truly-outside boxes
; outside). Visible → serve the FOE-opened extent (a proven SUPERSET of
; the fresh extent: points migrate away from the screen-centre focus of
; expansion under forward motion; +2 columns of slack covers the check's
; ±1 rounding wobble) straight into has_gap. Pixel-preserving via the
; gate invariant (2026-07-08, fp_project_x / wad_packed notes): every
; seg's drawn columns lie inside its ancestors' gate extents, so a
; served descend of a fresh-gapless subtree is a no-op and a served skip
; implies the fresh skip. Guarded by tools/walkseq_check.py.
; Entries recompute every 8th active frame (round-robin by node id);
; invisible entries are exempt (exact under forward motion).
; ============================================================================
br_bbox_visible_d:
.scope
   LDX zp_node_ch_l
   LDA zp_bbox_side
   BNE dv_left
   LDA D_CODE_R,X
   JMP dv_have
dv_left:
   LDA D_CODE_L,X
dv_have:
   CMP #125
   BEQ dv_fresh                            ; invalid → recompute + store
   CMP #126
   BEQ dv_invis                            ; invisible: exact, no refresh needed
; (no D_MODE test needed: on store-only frames the wipe has set every
; code to 125, and the tree walk never re-reads an entry stored earlier
; in the same frame, so only the two branches above can fire there)
   STA zp_br_t0                            ; code (visible entry)
   TXA
   CLC
   ADC D_FRAME
   AND #7
   BEQ dv_fresh                            ; this entry's refresh slot
   LDA zp_br_t0
   CMP #127
   BEQ dv_straddle
   BCS dv_right                            ; 132-255: right-of-centre
   LDY #0                                  ; 0-124: left-of-centre → (0, code+2)
   STY zp_i_l
   ADC #2                                  ; C clear here (CMP #127 not taken)
   STA zp_i_h
   JMP dv_gap
dv_right:
   SBC #2                                  ; C set here (BCS taken) → code-2
   STA zp_i_l                                 ; (code-2, 255)
   LDA #255
   STA zp_i_h
   JMP dv_gap
dv_straddle:
   LDA #0
   STA zp_i_l
   LDA #255
   STA zp_i_h
dv_gap:
   LDA #0                                  ; D-serve skipped classify: the
   STA zp_bca_zone                         ; children must not inherit stale
                                        ; strict bits (exactness, not just
                                        ; pixel-safety — wrong corners)
   JMP SC_HAS_GAP                          ; serve: A/Z is our return value
                                        ; (main-resident — no PAGE)
dv_invis:
   LDA #0
   RTS
dv_fresh:
   JSR br_bbox_visible                     ; pristine core (pages L2/C itself)
   PHA                                     ; A = verdict (has_gap already run)
   PAGE BANK_L2                            ; store code lives in the L2 window
   bv_dcache_store                     ; encode bca_vis/ilo/ihi → code byte
   PLA                                     ; restore verdict; Z tracks A
   RTS
.endscope

; ---- D-cache cold code: once-per-frame classifier + per-fresh-check
; store. W/RCCODE segments — both float inside the one CODE region in
; both builds (the old placement constraints are history); both call
; sites hold L2 paged. Data is resident main RAM ($0210-$03F7). ----
.if ::BANKED
.segment "RCCODE"
.else
.segment "W"
.endif

; bv_dcache_store — encode the fresh bbox-check outcome for (node, side).
; In: bca_vis/bca_ilo/bca_ihi valid; zp_node_ch_l/zp_bbox_side = entry.
; Clobbers A, X, Y.
; (bv_dcache_store is a MACRO now — bsp/inline.s — expanded at its single
;  call site, 2026-07-17.)

; ============================================================================
; br_dcache_frame — per-frame D-cache classifier (called from br_view_setup
; with BANK_L2 paged, right after bca_frame).
;
;   D_ENABLE == 0                    → D_MODE = 0 (all hooks inert)
;   position (full 8.8) + angle same → D_MODE = 2 (serve; no drift, no
;                                      refresh advance — exact)
;   moved + D_FWD + angle same       → D_MODE = 2, D_FRAME++ (forward run;
;                                      the theorems chain over the summed
;                                      movement, which stays in the cone)
;   anything else (turn/backward/    → wipe codes to 125, D_MODE = 1
;     sideways/unflagged move)         (store-only rebuild frame)
;
; The 6-byte position compare includes the fraction bytes: a sub-integer
; backward step must NOT classify as stationary.  D_FWD is consumed
; per frame (driver re-asserts it each frame it applies a forward step).
; ============================================================================
br_dcache_frame:
.scope
   LDA D_ENABLE
   BNE df_on
   STA D_MODE                              ; A = 0
   JMP df_patch                            ; point sites at the pristine core
df_on:
   LDA zp_br_px
   CMP D_PREVP+0
   BNE df_moved
   LDA zp_br_px_h
   CMP D_PREVP+1
   BNE df_moved
   LDA zp_br_px_x
   CMP D_PREVP+2
   BNE df_moved
   LDA zp_br_py
   CMP D_PREVP+3
   BNE df_moved
   LDA zp_br_py_h
   CMP D_PREVP+4
   BNE df_moved
   LDA zp_br_py_x
   CMP D_PREVP+5
   BNE df_moved
; stationary — same angle?
   LDA bca_ab
   CMP D_PREV_AB
   BNE df_wipe                             ; rotated in place → extents invalid
   LDA #2
   STA D_MODE
   BNE df_patch                            ; (always) prevs unchanged, no advance
df_moved:
   LDA D_FWD
   BEQ df_wipe
   LDA bca_ab
   CMP D_PREV_AB
   BNE df_wipe                             ; move + turn in one frame → wipe
   INC D_FRAME
   LDA #2
   STA D_MODE
   BNE df_save                             ; (always)
df_wipe:
   LDA #125                                ; invalid code
   LDX #0
df_wl:
   STA D_CODE_R,X
   STA D_CODE_L,X
   INX
   CPX #236
   BNE df_wl
   LDA #1
   STA D_MODE                              ; store-only rebuild frame
df_save:
   LDA zp_br_px
   STA D_PREVP+0
   LDA zp_br_px_h
   STA D_PREVP+1
   LDA zp_br_px_x
   STA D_PREVP+2
   LDA zp_br_py
   STA D_PREVP+3
   LDA zp_br_py_h
   STA D_PREVP+4
   LDA zp_br_py_x
   STA D_PREVP+5
   LDA bca_ab
   STA D_PREV_AB
; fall through to df_patch
; --- SMC: point the walk's two bbox-check JSRs at the D wrapper when
; the cache is active this frame, at the pristine core when not — the
; disabled engine is byte-identical to pre-D code, zero per-check cost
; (the vxc_frame / bca_frame idiom). Operands are resident MAIN bytes,
; writable regardless of banking. ---
df_patch:
   LDA D_MODE
   BEQ df_plain
   LDA #<br_bbox_visible_d
   LDY #>br_bbox_visible_d
   BNE df_write                            ; (always: page byte nonzero)
df_plain:
   LDA #<br_bbox_visible
   LDY #>br_bbox_visible
df_write:
   STA bsp_walk::bv_site_near0+1
   STA bsp_walk::bv_site_far0+1
   STA bsp_walk::bv_site_near1+1
   STA bsp_walk::bv_site_far1+1
   TYA
   STA bsp_walk::bv_site_near0+2
   STA bsp_walk::bv_site_far0+2
   STA bsp_walk::bv_site_near1+2
   STA bsp_walk::bv_site_far1+2
   RTS
.endscope

.segment "MAIN"                         ; restore for subsequently-included parts
