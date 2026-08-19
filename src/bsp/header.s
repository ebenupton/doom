; ============================================================================
; bsp/header.s — build flags, macros, cross-unit imports.
;
; CONTEXT: included FIRST by src/bsp_render.s (after zp.inc). MAIN sits
; first in the CODE region — $2B00, both builds (= abi MAIN_BASE;
; gen_abi.py owns the constant). Jump tables are GONE (2026-07-16):
; drivers/harness resolve engine entries by symbol from the linker map. PAGE is the bank-select macro: LDA
; #bank / STA $FE30 banked, NOTHING flat — so PAGE clobbers A + flags
; only (X/Y ride through), and flat builds CANNOT catch a missing PAGE
; (jsbeeb/bare-boot are the catchers).
; ============================================================================

; --- CPU target: every builder MUST pass -D C02=0 (plain 6502) or -D C02=1
;     (enable 65C02 opcodes). STZ/INC A/PHX/etc are gated on C02 throughout. ---
.if ::C02
.setcpu "65C02"
.endif
; ZERO a1[,a2[,a3[,a4]]]: zero up to four bytes. 65C02 = STZ each (A
; preserved, NO flags set); 6502 = one LDA #0 + STA each (A clobbered,
; Z set). Only use where nothing downstream needs A = 0 or the flags,
; and never with abs,Y operands (STZ has no ,Y mode).
.macro ZERO a1, a2, a3, a4, a5, a6
.if ::C02
STZ a1
.ifnblank a2
STZ a2
.endif
.ifnblank a3
STZ a3
.endif
.ifnblank a4
STZ a4
.endif
.ifnblank a5
STZ a5
.endif
.ifnblank a6
STZ a6
.endif
.else
   LDA #0
   STA a1
.ifnblank a2
   STA a2
.endif
.ifnblank a3
   STA a3
.endif
.ifnblank a4
   STA a4
.endif
.ifnblank a5
   STA a5
.endif
.ifnblank a6
   STA a6
.endif
.endif
.endmacro

; ZERO_X / ZERO_Y: as ZERO but the NMOS arm clobbers X / Y instead of
; A (65C02 STZ clobbers nothing either way). Pick by which register is
; dead at the site.


; BUMP: A = A + 1. 65C02 = INC A (no carry); 6502 = CLC : ADC #1. Use only
; where the carry/overflow OUT is dead (negate, single-byte increments).
.macro BUMP
.if ::C02
ina
.else
   CLC
   ADC #1
.endif
.endmacro

; BUMP_CC: A = A + 1 at a site where C is PROVEN CLEAR (document the
; proof at each use — Eben's carry survey, 2026-07-26). Both CPUs:
; ADC #1, 2 cyc — the NMOS arm's CLC dies. Writes C/V like BUMP's ADC,
; so the out-flags must be dead.
.macro BUMP_CC
   ADC #1
.endmacro

; BUMP_TAX: A = X = A + 1 (the BUMP/TAX pair, CPU-forked to each
; core's best form — Eben, 2026-07-26). C02: INA:TAX (4 cyc, 2 B).
; NMOS: TAX:INX:TXA (6 cyc, 3 B — ties CLC:ADC#1:TAX on cycles, saves
; a byte, and never writes C/V, unlike BUMP's ADC).
.macro BUMP_TAX
.if ::C02
ina
TAX
.else
   TAX
   INX
   TXA
.endif
.endmacro

; bsp_render.asm — fresh 6502 BSP traversal + vertex transform + seg
; projection. Feeds lines into the existing s16 clipper / DCL pipeline
; in span_clip.asm.
;
; One object of the single engine link; calls into span_clip's exported
; routines DIRECTLY (draw_clipped_line_s16(_h), span_has_gap,
; span_mark_solid, tighten_from_records, seg_zero_rec_solid — see the
; SC_* alias block below). Arithmetic primitives are LOCAL copies.

; --- BBC banked port (path B), selected by beebasm -D BANKED=0|1 ---
; Sideways-RAM bank numbers (RAM banks confirmed on jsbeeb B; loader copies here)
; (BANK_L0/C/L2 come from abi.inc via zp.inc — one table, no copies)
; PAGE b : page sideways bank b ($FE30). No-op in the flat build, so flat stays
; bit-exact. A is clobbered — only invoke at A-dead points.
; --- Node/subsector SoA pages (head of ROM_MAIN; see wad_packed.py).
; n_nodes, n_ss <= 256 (asserted at pack time): ids are u8 EVERYWHERE,
; every field a constant-base LDA abs,X. Child links carry no hi byte;
; "this child is a subsector" is baked into the parent's TYPE byte
; (NF_RLEAF/NF_LLEAF) — leaf-ness is a property of the node, not the link.
; Layout mirrors wad_packed.build_packed: 11 node pages (one page per
; field byte, index X = node id) then 3 subsector pages (index X = ss id):
;   pg 0/1  nx lo/hi   partition-line origin, map-centre-relative raw s16
;   pg 2/3  ny lo/hi
;   pg 4/5  dx lo/hi   partition-line direction (raw s16)
;   pg 6/7  dy lo/hi
;   pg 8/9  right child id, left child id (u8)
;   pg 10   TYPE: bits 0-1 baked partition type (NT_*: skips the axis
;           test AND the unused field loads — 73% of E1M1 nodes are
;           axis-aligned); bit 7 NF_RLEAF / bit 6 NF_LLEAF
;   pg 11   subsector seg count
;   pg 12/13 subsector seg-header pointer lo/hi (first*16 in ROM,
;            loader-rebased onto the build's ROM_SEG_HDR page)
.include "layout.inc"

; Vertex planes (page-split SoA, 2026-07-15): 512 bytes per field,
; junior page idx 0-255, senior 256+ (select = header key B & $20).
; ROM_VERTS_C: flat $9C00 (planes end EXACTLY at SEL $A400), banked
; L2 $A200 (end $A7FF since the reclaim; next resident RCACHE $AD00).
; PAGE-DECOMPOSED vertex planes (Eben's concept, 2026-08-11): unsigned
; u8 offsets + a senior-bits nibble — THREE planes, $600 total (the
; 4th slot reclaimed same day: banked L2 $A800-$A9FF and flat
; $B700-$B8FF freed). See rot_w_pages.
VP_OX = ROM_VERTS_C + $000
VP_OY = ROM_VERTS_C + $200
VP_PG = ROM_VERTS_C + $400

; rotated page-base tables, 16 entries each (one per senior nibble),
; REBUILT PER ANGLE EPOCH by rot_select: PB_X = PX*sin - PY*cos,
; PB_Y = PX*cos + PY*sin in s16 counts (PX,PY in {-512,-256,0,+256}).
; $0680-$06BF: scratch-page run verified free by listing scan 2026-08-11.
PB_XL = $0680
PB_XH = $0690
PB_YL = $06A0
PB_YH = $06B0
SQR_MIRROR = $01E0                      ; 32-byte even-mirror prefix BELOW
                                        ; sqr_l — protruding into the STACK
                                        ; PAGE since the quad moved to $0200
                                        ; (Eben, 2026-08-18). The stack is
                                        ; capped at $01DF: every SP init is
                                        ; $DD/$DF (driver TXS, harness sp=)
                                        ; and pushes grow DOWN from there,
                                        ; so the mirror is never touched.
                                        ; Filled by rot_select on a fresh
                                        ; code image (rwp_stamp), so boot
                                        ; scribbles self-heal. SQR_MIRROR+k
                                        ; = f(32-k) & 255.
PB_TS = $06C0                           ; epoch-build scratch: (k-2)*256*sin
PB_TC = $06C8                           ; (k-2)*256*cos — 4 s16 each
PB_PREV_AB = $06D0                      ; angle the tables were built for
; ($06D1 free again 2026-08-11: PB_VALID died — validity rides
;  rwp_stamp IN THE CODE IMAGE, so code reloads self-invalidate)

; NODE_SOA comes from layout.inc (NODE_SOA_C): banked = L0 window head,
; flat = $B600 (the hole the retired FHCH stream vacated 2026-07-11 —
; the stride-16 headers with inlined heights at +10..15 own $6C00 now).
NODE_SOA = NODE_SOA_C
NODE_NXLO = NODE_SOA + $000
NODE_NXHI = NODE_SOA + $100
NODE_NYLO = NODE_SOA + $200
NODE_NYHI = NODE_SOA + $300
NODE_DIRID = NODE_SOA + $400            ; general: DIR-table index
NODE_DSGN  = NODE_SOA + $500            ; general: sign byte (b7 ndy neg,
                                        ;  b6 ndx neg); axis nodes ignore
; (raw dy pages RECLAIMED 2026-07-15: no reader on either side — the
;  SoA is 12 pages now and the 2 pages before ROM_BBOX_C are free)
NODE_CRLO = NODE_SOA + $600             ; right child id (side 0 = near)
NODE_CLLO = NODE_SOA + $700             ; left child id
NODE_TYPE = NODE_SOA + $800             ; bits 0-2 type; bit 7/6 leaf flags
SS_PC     = NODE_SOA + $900             ; (page<<3)|(cnt-1); $FF = empty —
                                        ; TWO packed subsector bytes since
                                        ; 2026-08-19 (was count/lo/hi in 3
                                        ; pages); hdr hi = page + >base at
                                        ; run time, which killed both
                                        ; loaders' rebase passes
SS_PLO    = NODE_SOA + $A00             ; header lo byte, PLAIN (slot *
                                        ; stride — an info-bit packing was
                                        ; clawed back the same day: 8 cyc
                                        ; per visited ss on the prologue
                                        ; for bits pm reads twice a MOVE;
                                        ; the 7 mover subsectors live in
                                        ; colmap's MV_SS probe list)

; TYPE-byte fields. NF_RLEAF sits at bit 7 so one ASL drops it into C
; (NF_LLEAF takes two) — the walk's child-follow gets id + leaf bit
; with no AND mask on the id.
NT_MASK  = $03                          ; sense-normalized axis forms
                                        ; (0 px>nx, 1 py>ny — the packer
                                        ;  child-swaps '<' nodes away),
                                        ;  3 general (LSR leaves C=1 =
                                        ;  the delta staging's borrow
                                        ;  seed)
NT_GEN   = $03
NF_RLEAF = $80                          ; right child is a subsector
NF_LLEAF = $40                          ; left child is a subsector

; Page-alignment contracts for the byte-at-a-time pointer builds
; (bbox_visible, bcac_index, the seg_xform vcache indexers):
.assert (VCACHE_BASE & $FF) = 0, error, "VCACHE_BASE must be page-aligned"

.macro PAGE bank
.if ::BANKED
   LDA #bank
   STA $FE30
.endif
.endmacro

; PAGE_X / PAGE_Y: as PAGE but clobber X / Y instead of A — lets a
; value RIDE A across a bank switch (flags still die: the immediate
; load sets N/Z — compute verdicts AFTER the page, not before).
.macro PAGE_X bank
.if ::BANKED
   LDX #bank
   STX $FE30
.endif
.endmacro

.macro PAGE_Y bank
.if ::BANKED
   LDY #bank
   STY $FE30
.endif
.endmacro

; RNS_SELECT — pick the vectored round-to-nearest shifter and patch
; rns_go_op (project.s RNSPG). CONTRACT: A = S (every select site has
; just stored zp_br_r_s from A — the old JSR routine's LDX zp_br_r_s
; was a pure reload). Clobbers X (A becomes the vector byte). Retired
; the rns_select subroutine 2026-07-15.
.macro RNS_SELECT
   TAX
   LDA rns_vec_l-1,X
   STA rns_go_op
.endmacro

; ============================================================================
; CROSS_MAG_DECIDE front, back — the shared cross-product magnitude
; comparator: sign(dot) when the two products dy'*dx and dx'*dy share a
; sign. ONE source, TWO expansions: the seg back-face test
; (backface.s: front/back = bf_seg_front / s_advance) and the node
; point-on-side general arm (lo.s: front/back = side 0 / side 1) — the
; algebra is identical (dot = dy'*dx - dx'*dy; ties lose).
;   in : X = shared product sign (bit 7), zp_br_dx/dy = SIGNED nonzero
;        deltas, zp_bf_dir = DIR-table index (gcd-reduced primitives).
;   out: control flow — JMP front (dot > 0) / JMP back (dot <= 0).
;   Clobbers A, X, deltas (abs-folded in place), t0-t5, mul workspace.
; ============================================================================
; (UMUL8_INLINE reverted 2026-07-19 evening: the space-recovery pass
; bought back its 212 bytes for +154 cycles/frame — 0.73 c/B, under
; the 1 c/B recovery price. The JSR/RTS pairs returned.)
.macro CROSS_MAG_DECIDE front, back
.local cm_dx_pos, cm_dy_pos, cm_p1_done, cm_p2_done, cm_p1_hi, cm_p2_hi
.local cm_dec, cm_neg, cm_back
   STX zp_br_sign                          ; X dies at umul8
; (t4/t5 zeroing lives in the senior-clear skips — each hi slot is
;  written on EVERY path: by its out-of-line hi tier, or by the skip's
;  STA with the zero already in A)
   LDX zp_br_dx_h
   BPL cm_dx_pos
   LDA #0                                  ; explicit zero: the negate
   SEC                                     ; seed (mirror-idiom lesson)
   SBC zp_br_dx_l
   STA zp_br_dx_l
   LDA #0
   SBC zp_br_dx_h
   STA zp_br_dx_h
cm_dx_pos:
   LDX zp_br_dy_h
   BPL cm_dy_pos
   LDA #0
   SEC
   SBC zp_br_dy_l
   STA zp_br_dy_l
   LDA #0
   SBC zp_br_dy_h
   STA zp_br_dy_h
cm_dy_pos:
; --- |P1| = |dy'| * |dx| -> (t2, t3, t4) u24 ---
   LDX zp_bf_dir
   LDA ROM_DIRS_C + LAY_MAX_DIRS,X         ; |dy'| (lazy: only this tier pays)
   STA zp_br_a                             ; survives for the hi partial
   LDX zp_br_dx_l
   STX zp_mul_b
   JSR umul8
   STA zp_br_t3
   LDA zp_prod_l
   STA zp_br_t2
   LDA zp_br_dx_h
   BNE cm_p1_hi                            ; senior partial (out of line)
   STA zp_br_t4                            ; A = 0: 1-mul product, hi = 0
cm_p1_done:
; --- |P2| = |dx'| * |dy| -> (t0, t1, t5) u24 ---
   LDX zp_bf_dir
   LDA ROM_DIRS_C,X                        ; |dx'|
   STA zp_br_a
   LDX zp_br_dy_l
   STX zp_mul_b
   JSR umul8
   STA zp_br_t1
   LDA zp_prod_l
   STA zp_br_t0
   LDA zp_br_dy_h
   BNE cm_p2_hi                            ; senior partial (out of line)
   STA zp_br_t5                            ; A = 0: 1-mul product, hi = 0
cm_p2_done:
; --- ONE u24 compare, early-out (products usually decide at the mid
; byte). A tie loses for either sign, so equality exits first; after
; that C is the STRICT order and one sign load decodes the verdict:
;   C=1 (|P1| > |P2|): front iff sign positive
;   C=0 (|P1| < |P2|): front iff sign negative
   LDA zp_br_t4
   CMP zp_br_t5
   BNE cm_dec
   LDA zp_br_t3
   CMP zp_br_t1
   BNE cm_dec
   LDA zp_br_t2
   CMP zp_br_t0
   BEQ cm_back                             ; equal -> dot == 0 -> back
cm_dec:
   LDA zp_br_sign                          ; (touches neither C nor N-verdict)
   BMI cm_neg
   BCC cm_back                             ; positive: |P1| < |P2| -> back
   JMP front                               ; (hot fall-through: pos front)
cm_neg:
   BCS cm_back                             ; negative: |P1| > |P2| -> back
   JMP front
cm_back:
   JMP back
; --- out-of-line senior partials (the uncommon big-delta tier) ---
cm_p1_hi:
   STA zp_mul_b
   LDA zp_br_a
   JSR umul8
   LDA zp_prod_l
   CLC
   ADC zp_br_t3
   STA zp_br_t3
   LDA zp_prod_h
   ADC #0
   STA zp_br_t4
   JMP cm_p1_done
cm_p2_hi:
   STA zp_mul_b
   LDA zp_br_a
   JSR umul8
   LDA zp_prod_l
   CLC
   ADC zp_br_t1
   STA zp_br_t1
   LDA zp_prod_h
   ADC #0
   STA zp_br_t5
   JMP cm_p2_done
.endmacro

SEG_CODE

; ============================================================================
; ZP layout (kept tight to avoid colliding with span_clip's $A0-$FF)
; We use $00-$3F (free in py65 sim; on real BBC OS this would need rework
; but the priority right now is correctness, not portability).
;
; Note: umul8 needs $D9 (zp_mul_b) and uses $DA/$DB for product.
; udiv16_8 needs zp_div_l:hi ($DA:DB), zp_div_den ($DC).
; Both are clobbered across calls — bsp_render saves any zp data it
; needs across these calls into the BR_* slots below.
; ============================================================================

; Per-frame view-context (Python wrapper writes once per frame)
; Raw (un-prescaled) player position for BSP side test.
; NOTE: these lived at $71-$74, but the NJ rasteriser at $A900 uses
; $74-$76/$79-$7A/$80-$88 as scratch — every drawn line corrupted
; zp_br_pyraw_h and flipped point_on_side decisions mid-walk.
; $90-$9F is unclaimed by span_clip, the rasteriser, and this module.

; Per-vertex working state — dx/dy widened to s16 (vertex range can
; exceed s8 after prescale; e.g. ±400 in our test scene).
zp_br_dx = zp_br_dx_l                   ; alias for the lo byte (backwards-compat)
zp_br_dy = zp_br_dy_l

; Multiply / divide / sign workspace

; Reciprocal output

; Pointer (used by indirect-Y reads of ROM/RAM)

; Generic temps

; Vertex cache helper state
; Side test working state (s16 deltas px-nx, py-ny held across fast/slow paths)
; Frame ROM table base ptrs (Python wrapper writes once)
; ($0BE8-$0BF7 ROM-pointer block RETIRED 2026-07-10: the packed layout is
; static — bases are layout.inc assembly-time constants; loaders no longer
; poke pointers and the walk_drv ptrtab is gone. Page-$0B bytes freed.)
; Bbox routine arg

; ============================================================================
; Memory map (RAM caches + ROM tables — Python wrapper places data here)
; ============================================================================
; recip/sincos: milestone keeps them flat ($E000/$E480), reachable in the
; banked_mem model (above the $8000-$BFFF window). Real-HW will bank these with
; the rest of the $C000+ subsystems (separate relocation step).
; $C000+ subsystems relocate to bank L2 for real HW. L2 window layout:
;   TA_LO $8000 TA_HI $8400 VATOX $8800 (angle tables, slope_div.asm)
;   bbox $8D00  recip $9C00  VWH $A100  VWHC cache $A600
.if ::BANKED
; L2 window (2026-07-21 regroup, no overlaps): TABLES $8000-$8BFF
; (L8/AE/VATOX/recip) | LEVEL $8C00-$A3FF (bbox 16p, verts $800) |
; CACHES $A400-$B2FF (CPM, rc psi planes, RCACHE_STATE, VWHC) |
; ANIM $B300/$B400 | FREE $B500-$BFFF contiguous.
RECIP_S  = $A800                        ; junior-page S table, PAGE-ALIGNED,
                                        ; in the run the vertex caches left
                                        ; (2026-08-17: it came out of the LDATA
                                        ; region at main $1E00 — every read was
                                        ; already under bank 4, censused, and
                                        ; $1E00 went to the driver so CODE could
                                        ; drop a page). NOT $B300: that is
                                        ; VWHC_R_S, which ships zero and so is
                                        ; invisible in an occupancy dump — it
                                        ; cost a bankedcmp failure to find.
RECIP_M8 = $B100                        ; bank SEG (two-bank re-cut)
RECIP_M8H = $B200                       ; far half-table [128,255],
                                        ; unswapped ($8980-$8BFF FREE
                                        ; 2026-08-13: far synthesis)
L2_BBOX = $9600                         ; bank WALK (harness/loader points zp_rom_bbox here; = ROM_BBOX_C)
.else
RECIP_S  = $D800                        ; page-aligned, in the free run the
                                        ; far half-table leaves
RECIP_M8 = $D500                        ; flat LEVEL block (2026-07-21 map)
RECIP_M8H = $D600                       ; far half ($D680-$D8FF FREE)
.endif
; (SINCOS_BASE deleted 2026-07-21: no reader — the engine takes sincos
;  via the ZP contract ($05-$0A), the driver owns its own DRV_TAB.)

; --- VERTEX-SPAN DESCRIPTORS (Eben's scheme, 2026-07-24) ---
; One byte per vertex, page-split (junior ids 0-255, senior 256+):
;   $00 none / $01 fh->ch / $02 fh->bfh (gate NEEDBB) / $03 bch->ch
;   (gate NEEDBT) / $04 frame pair / $80|i explicit table ref.
; Codes read the trigger's ALREADY-PROJECTED sy slots (solids alias
; bfh/bch = fh/ch at pack time, so the step codes self-annul via the
; NEEDBB/NEEDBT gates). Explicit entries are world s8 height pairs,
; clamped to the trigger's zp_seg_fh/ch, projected at the endpoint
; recip. VDONE = the once-per-frame first-touch bitmap (byte index =
; the header key's B byte = idx>>3, bit = vc_bit_mask[idx&7]).
.if ::BANKED
VDESC      = $A500                      ; bank C (verticals run under C;
VEXPL_LO   = $A700                      ; moved from $B200/$B400 2026-07-27
VEXPL_HI   = $A780                      ; — the vplot unrolled column owns
VEXPL_CONT = $9600                      ; moved from $A800 2026-08-11 (the
                                        ; unrolled-steep blob starts $A800;
                                        ; $9600 = clipper headroom, guarded
                                        ; in banked_bsp)
                                        ; HI split widened $60->$80
                                        ; 2026-08-14 (mover jamb entries
                                        ; pushed the count past 96; 128
                                        ; slots each, HI ends $A7FF flush
                                        ; against the rasteriser blob)
.else
VDESC      = $DC00                      ; flat TABLES block
VEXPL_LO   = $DE00
VEXPL_HI   = $DE80                      ; widened with the banked split
VEXPL_CONT = $DF00
.endif
; (VDONE moved next to VCACHE_VALID 2026-07-26 — see below; $0600 is
; fully FREE again.)

; Vertex transform cache: per-vertex saved view + projection results.
; Skip redundant transforms when multiple segs share a vertex.
; Fields: rhi, rlo, sx_lo, sx_hi (s16 projected screen X), near-clip
; flag — one plane each (see below). EV16 (2026-08-09): the s8 evy/evx
; planes DIED — near verdicts serve from CLIP, and the crossing
; recovers full s24 view totals via cr_recover instead of reading the
; lossy s8 tier.
; Valid bitmap: 1 bit per vertex; cleared at the start of each frame.
; VCACHE is page-split SoA (2026-07-15): one 512-byte plane per field,
; junior page = idx 0-255, senior page = idx 256+ (n_verts <= 512,
; pack-time assert). The senior bit is header key byte B & $20 — the
; reader dispatches to an arm with the page BAKED, so there is no
; address generation anywhere in the vertex frame cache.
; BANKED: the four planes live in the BANK A window since 2026-08-17 — the
; audit censused ~20,000 accesses (VXC off, VXC on with the coherence walk, and
; the real driver from a bare machine) and every one already ran with bank 4
; paged, so this costs no paging and no cycles: abs,X in the window is the same
; 4 cycles it was in main. FLAT keeps them in main, so $0800-$0FFF and
; $1200-$19DF are free in the BANKED map ONLY — the one place the two builds'
; sub-$5800 maps diverge (Eben's call, banked-first).
.if ::BANKED
VCACHE_BASE = $9800                     ; bank A, below the vertex planes
.else
VCACHE_BASE = $0800                     ; main (cache region shuffle 2026-08-09)
.endif
VC_RHI  = VCACHE_BASE + $000
VC_RLO  = VCACHE_BASE + $200
VC_SXL  = VCACHE_BASE + $400
VC_SXH  = VCACHE_BASE + $600
; (VC_CLIP folded into VC_RLO 2026-08-13 — S = 0 is the clipped sentinel, real
;  S is never 0. VCACHE = 4 planes.)
.if ::BANKED
.assert VCACHE_BASE >= $8000 && VC_SXH + $200 <= $AB00, error,  "banked VCACHE must sit inside bank A, below the vertex planes"
.endif
VCACHE_VALID_BASE = $0700               ; THE BITMAP PAGE (relocation to
                                        ; the VXC plane tails tried and
                                        ; UNWOUND 2026-08-13 pending the
                                        ; two-bank layout plan; the
                                        ; 455+57=512 tail fit is real —
                                        ; Eben: every cache's valid
                                        ; bitmap on ONE page, heading the
                                        ; contiguous cache region
                                        ; $0700-$19FF): VALID +$00,
                                        ; VDONE +$3C, VXC_VALID +$80,
                                        ; RCACHE_COMPUTED +$C0. The
                                        ; VDONE $80-sentinel probe lands
                                        ; at +$BC — inside the $BB-$BF
                                        ; gap, KEEP IT FREE.
                                        ; — moved from $1B00 2026-08-09
                                        ; (the sqr quad took $1A00-$1DFF).
                                        ; NOT page 6: flat RC_P1L_0 owns
                                        ; $0600 (the 2026-07-27 psi-plane
                                        ; recovery); $1F00 freed both
                                        ; builds by the LCODE/SQRH deaths.
; VDONE adjacent (2026-07-26, Eben: 'combine the reset loops — 60 bytes
; each'): the per-frame wipe below clears BOTH as one 120-byte block of
; uniform stripes off one base. 60 >= 59 bytes covers ALL vertex ids —
; the old $0600 home cleared only 0-49 and leaned on the packer's
; ids<384 assert for the tail; that dependence is gone. $1B78-$1BFF
; stays free (ex-BCA_WS).
VDONE = VCACHE_VALID_BASE + 60          ; (57 B live; the crossing's
                                        ; B=$80 probe/mark lands at
                                        ; $07BC — the sentinel gap)


; ============================================================================
; CODE region head. The driver-facing jump table that lived here is
; GONE (2026-07-16): jump tables are forbidden — the beebasm drivers
; take real entry addresses (view_setup / render_frame /
; anim_tick / anim_init) from the linker map via the generated
; engine_syms.inc, and the Python harness resolves every entry by
; symbol (symmap). MAIN still sits FIRST in the CODE region (cfg
; anchor $2B00 = MAIN_BASE in the ABI table): code_head marks it
; for engine_load.py's CODE-bin placement.
; ============================================================================
code_head:

; ============================================================================
; Aliases for span_clip's exported routines
; ============================================================================
; Imported from span_clip (same link) and called DIRECTLY — the linker
; resolves them; no jump-table hop. umul8 flows the OTHER way since
; 2026-08-09: THE copy lives below (main RAM, always mapped) and the
; clipper imports it — see the banner at its definition.
.export umul8
.import udiv16_8                        ; clip/arith.s — the crossing's t
                                        ; divide (EV16 2026-08-09; rare
                                        ; path, JSR beats the SC_ inline)
.import recip_hi                     ; ex-LCODE code, clip/rotvar.s
.import rot_zero, rot_unity_pos, rot_unity_neg
.import rot_zero_s, rot_unity_pos_s, rot_unity_neg_s
.export rns_vec_l, rns_go_op            ; rotvar's RNS_SELECT expansion
.export RECIP_M8, RECIP_M8H
.assert (RECIP_M8 & $FF) = 0, error     ; 4-page table indexed (page | t1);
                                        ; PAGE 0 NIBBLE-SWAPPED (2026-08-10):
                                        ; entry swap(idx) = M8[idx] — the
                                        ; fast path masks (vy_l & $F0)|vy_h;
                                        ; pages 1-3 linear (recip_hi)
.import span_mark_solid
.import span_has_gap                    ; has_gap body (main B segment)
.import seg_zero_rec_solid
.import tighten_from_records
.import draw_clipped_line_s16, draw_clipped_line_s16_h
.import dcl_vert, dcl_vert_on           ; vertical fastpath (senior-byte

; And span_clip's ZP slots that umul8/udiv16_8 use
; quarter-square tables (loaded by harness) — for inlining umul8 at hot sites
; abi.inc owns the table base (SQR_BASE, flat/banked variants there)
sqr_l = SQR_LO
sqr_h = SQR_HI
sqr2_l = SQR2_LO
sqr2_h = SQR2_HI

; span_clip's line ZP (zp_line_* lo bytes + zp_line_*_hi for the s16 clipper)

; ============================================================================
; umul8 — THE quarter-square multiplier (unified 2026-08-09: the clipper's
; bit-identical copy in clip/arith.s was discarded; this one is exported and
; every caller — bsp transform code AND the bank-C clipper — JSRs here).
; It lives in main RAM (always mapped), so it is reachable from any bank
; phase: the data-bank transform arcs and the bank-C clipper alike. The sqr
; tables sit at SQR_BASE ($1C00 banked) for the same reason.
;
; ============================================================================
; umul8 — u8 × u8 → u16 via quarter-square tables. ~50 cycles, no loop.
;   Inputs:  A = a, zp_mul_b = b.
;   Output:  zp_prod_l/hi = a * b (u16).
;   Clobbers: A, X, Y.
;   CONTRACT (2026-07-09, carried from the clip copy): A = zp_prod_h on
;   return AND the N/Z flags reflect it — BOTH exit paths end
;   `STA zp_prod_h`. Callers may take the product's HIGH byte straight
;   from A (backface's u24 magnitude products do). Preserve this if you
;   ever restructure the tail. zp_prod_l/hi alias zp_div_l/hi, so the
;   product feeds directly into udiv16_8 with no extra loads.
;
;   Identity: a*b = qsqr(a+b) - qsqr(|a-b|), where qsqr(n) = floor(n²/4).
;   Pseudocode:
;     d = |a - b|                       # Y index
;     s = a + b                         # X index (9 bits)
;     if s < 256:  prod = sqr[s]  - sqr[d]
;     else:        prod = sqr2[s & $FF] - sqr[d]   # sqr2[n] = qsqr(n+256)
;   The sqr2 tables absorb the 9th bit of a+b, so no 16-bit indexing is
;   needed. (The uo path enters SBC with carry set from the ADC overflow,
;   which is exactly the required borrow-clear.)
; ============================================================================
umul8:
.scope
   TAX                                     ; stash a in X (was zp_tmp0: the
   SEC                                     ; round-trip cost 6, TAX/TXA 4)
   SBC zp_mul_b
   BCS pos
   EOR #$FF
   ADC #1
pos:
   TAY
   TXA
   CLC
   ADC zp_mul_b
   TAX
   BCS uo
   LDA sqr_l,X
   SEC
   SBC sqr_l,Y
   STA zp_prod_l
   LDA sqr_h,X
   SBC sqr_h,Y
   STA zp_prod_h
   RTS
uo:
   LDA sqr2_l,X
   SBC sqr_l,Y
   STA zp_prod_l
   LDA sqr2_h,X
   SBC sqr_h,Y
   STA zp_prod_h
   RTS
.endscope
; (udiv16_8 DELETED 2026-08-12: the macro had lost its last
;  expansion site — zero invocations across every source.)
