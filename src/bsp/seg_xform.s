
; ============================================================================
; br_seg_xform_vertex — fetch vertex by index, transform to view, project X.
;
; One call per seg endpoint (subsector.s seg loop). Mirrors the "View
; transform with RAM vcache" + reciprocal + X-projection phase of Python's
; packed_render_seg (fp_to_view / fp_recip / fp_project_x_subpx), with a
; per-frame VERTEX CACHE so a vertex shared by several segs is transformed
; and X-projected only once per frame.
;
;   Input:  zp_seg_v_idx_l/hi = vertex index (u16), written by the caller
;             (doubles as the cache-write index — no staging copy).
;   Output: THE ENDPOINT STRUCT (zp.inc VX1/VX2, X = zp_seg_ep = 0/15):
;             +0 evy  +1 evx (ALWAYS — crossing math needs both endpoints)
;             +2 clip (1 = behind near plane; rest then undefined)
;             +3/+4 sx  +5..+12 the flag-gated sy pairs (do_project_y tail)
;             +13/+14 rhi/rlo (banked for ap2_solid_proj)
;           zp_br_r_m8/rlo also hold the recip (projection working slots).
;           NOTHING is staged — every result stores once, struct-direct.
;   Uses:   br_to_view (view.s, s24 rotation), br_recip, br_project_x.
;
; Vertex cache: VCACHE_BASE + idx*8, one 8-byte entry per vertex, plus a
; 1-bit-per-vertex valid bitmap at VCACHE_VALID_BASE (cleared per frame).
; 6502 entry layout (differs from Python's VCACHE_ENTRY, which stores
; vx/vy/vy_idx/sx — here the post-recip results are cached instead):
;   +0 evy (s8)  +1 evx (s8)  +2 rhi  +3 rlo  +4 sx_lo  +5 sx_hi
;   +6 near-clip flag (1 = vertex behind near plane)  +7 unused
;
; Pseudocode:
;   if valid[idx]:                          # cache hit
;       evy, evx = cache[0..1]
;       if cache[6]: skip = 1; return       # cached near-clip verdict
;       rhi, rlo, sx = cache[2..5]
;   else:                                   # cache miss
;       valid[idx] = 1
;       wx, wy = ROM_VERTS[idx]             # s16 prescaled world coords
;       vx, vy = br_to_view(wx, wy)         # s24 view space (8.8 + ext)
;       evx = vx >> 8 (trunc); evy = clamp_s8((vy + 128) >> 8)
;       cache[0..1] = evy, evx              # pre-write: hit path needs them
;       if vy < NEAR (s24 test): cache[6] = 1; skip = 1; return
;       rhi, rlo = br_recip(vy >> 7)        # 9.1 index into recip table
;       sx = br_project_x(vx)          # narrow 3-mul / wide 5-mul
;       cache[2..6] = rhi, rlo, sx, 0
;   do_project_y()                          # per-seg heights, tail call
; ============================================================================
br_seg_xform_vertex:
.scope
; ENTRY CONTRACT: A = idx_hi — both callers end LDA vN_hi / STA
; zp_seg_v_idx_b immediately before the JSR (mirrored at the call sites
; in subsector.s).
; EXIT CONTRACT (2026-07-21): every exit leaves BANK_L2 paged. The
; miss/near-clip exits already ended L2 (vertex_fetch/vxc_arm/br_recip);
; the four vc-hit exits page it explicitly. This makes the caller-side
; bank state exit-invariant: ys_deltas_done's blind re-page and
; c_set_recip's guard page both died against it (the off-bank arcs
; they defended were exactly these hit exits).
; No other PAGE in this routine (2026-07-11): the
; ROM vert fetch and its PAGE L2 moved to br_to_view_fetch (view.s);
; the hit path touches main-RAM VCACHE + rns vectors only, and
; br_project_y / br_recip page L2 themselves. Nothing here may touch
; A before the shift chain consumes it.
;
; LAYOUT INVARIANT: idx < 512 — each plane is two pages and the valid
; bitmap is 64 bytes max. B = idx>>3 <= 63 fits one byte (valid ptr hi =
; >VCACHE_VALID_BASE constant); the senior page select is B & $20.
;
; KEY ENCODING (2026-07-12): the header stores (A = idx&255, B = idx>>3)
; instead of (lo, hi) — B is consumed RAW as the bitmap/VXC_VALID byte
; index and the senior bit. (The idx*8 entry-pointer build died with the
; AoS cache, 2026-07-15 — no scaled forms remain here; br_to_view_fetch
; still builds idx*4 for the ROM vert fetch.)

; --- Check valid bit: byte = B, straight from the header key ---
   LDY zp_seg_v_idx_b                      ; Y RIDES to the vc_miss set-bit
                                        ; (PAGE between is A/flags only)
; bit mask = 1 << (idx_lo & 7), via table
   LDA zp_seg_v_idx_l
   AND #7
   TAX
   LDA vc_bit_mask,X
   STA zp_seg_v_bitm
   LDX zp_seg_ep                           ; X = struct offset from here on
   ZERO {VX1+2,X}                         ; clip = 0 (struct)
   LDA VCACHE_VALID_BASE,Y
   AND zp_seg_v_bitm
   BNE vc_hit_c                            ; (the fold's clip blocks grew
   JMP vc_miss                             ; the hit arms past branch
vc_hit_c:                                  ; range: miss pays the JMP)
; --- Cache hit: senior-bit arm (plane page BAKED), Y = idx&255 for every
; field — no address generation, no Y navigation. Fields go STRAIGHT
; from the planes into the endpoint struct (X = zp_seg_ep); rhi/rlo also
; land in the zp_br working slots because rns_select / the projections
; consume them there (two consumers of the value in A, not a copy). ---
   TYA                                     ; Y still holds idx_b from the
   AND #$20                                ; bitmap check; senior: idx >= 256
   BNE vc_hit_hi
   LDY zp_seg_v_idx_l
   LDA VC_EVY,Y
   STA VX1+0,X
   LDA VC_EVX,Y
   STA VX1+1,X
   LDA VC_RLO,Y                            ; rlo DOUBLES as the cached
   BEQ vch0_clip                           ; near-clip verdict (a live S
                                        ; is never 0) — VC_CLIP retired
                                        ; 2026-07-25, its page is VDESC's
; sx first, rlo LAST: RNS_SELECT clobbers X (its vector index), so the
; select runs after the final struct store and the old LDX zp_seg_ep
; reload is gone. The vector belongs to whoever wrote rlo last (the
; clip test above re-reads rlo at the tail for exactly this reason).
   LDA VC_SXL,Y
   STA VX1+3,X                             ; sx_lo
   LDA VC_SXH,Y
   STA VX1+4,X                             ; sx_hi
   LDA VC_RHI,Y
   STA zp_br_r_m8
   STA VX1+13,X                            ; rhi (for ap2_solid_proj)
   LDA VC_RLO,Y
   STA zp_br_r_s
   STA VX1+14,X                            ; rlo (= S; A still holds it)
   RNS_SELECT                              ; cached S → re-pick the shifter
vch0_pg:
   PAGE BANK_L2                            ; exit contract (see head)
   RTS                                     ; Y projection DEFERRED to the
                                        ; post-has_gap y stage (2026-07-11):
                                        ; culled segs never project.
vch0_clip:
   LDA #1
   STA VX1+2,X                             ; clip = 1
   BNE vch0_pg                             ; (always)
vc_hit_hi:
; (senior twin — pages +$100 baked; body identical)
   LDY zp_seg_v_idx_l
   LDA VC_EVY+$100,Y
   STA VX1+0,X
   LDA VC_EVX+$100,Y
   STA VX1+1,X
   LDA VC_RLO+$100,Y                       ; rlo==0 = cached clip verdict
   BNE vch1_ok
   LDA #1
   STA VX1+2,X
   PAGE BANK_L2                            ; exit contract (see head)
   RTS
vch1_ok:
   LDA VC_SXL+$100,Y
   STA VX1+3,X
   LDA VC_SXH+$100,Y
   STA VX1+4,X
   LDA VC_RHI+$100,Y
   STA zp_br_r_m8
   STA VX1+13,X
   LDA VC_RLO+$100,Y
   STA zp_br_r_s
   STA VX1+14,X
   RNS_SELECT
   PAGE BANK_L2                            ; exit contract (see head)
   RTS
vc_miss:
; --- Cache miss: mark valid now (entry bytes are filled as they are
; computed below — evy/evx first, so even the near-clipped path leaves
; a usable entry). The bitmap is main RAM, so no PAGE here: the ROM vert
; fetch (and its PAGE L2) moved into br_to_view_fetch (view.s,
; 2026-07-11) — the VXC warm path never reads the world coords, so only
; the paths that actually rotate pay for them. ---
; --- Set valid bit (Y = bitmap byte index, carried from the check) ---
   LDA VCACHE_VALID_BASE,Y
   ORA zp_seg_v_bitm
   STA VCACHE_VALID_BASE,Y

; (vxc_jsr_site SMC retired 2026-07-18: vertex_fetch (view.s) gates on
; zp_vxc_on and falls into the plain fetch when the cache is off.)
.endscope
   JSR vertex_fetch
.scope

; (view-x saves MOVED below the near-clip verdict, spectrack warm find
; 2026-07-12: clipped endpoints never read them — the sole consumer is
; THIS vertex's br_project_x; the crossing path stages its own.)

; Compute evx = vxhi (truncated s8) and evy = (vy + 128) >> 8 from the
; full s24 view-y (vyext, vyhi, vylo). Far-behind segs have negative
; vyext that overflows the s16 (vyhi:vylo) representation — using
; only vyhi misses the sign and lets clipped segs through.
   LDX zp_seg_ep                           ; struct offset (X survives to the
                                        ; cache pre-write + near-clip test)
   LDA zp_br_vx_h
   STA VX1+1,X                             ; evx
   LDA zp_br_vy_l
   ASL A
; carry = bit 7 of vylo
   LDA zp_br_vy_h
   ADC #0
; A = (vyhi:vylo + 128) >> 8 low byte
   STA VX1+0,X                             ; evy
; Clamp evy to s8 only when the rounded evy16 truly exceeds s8 —
; vyext=$FF is NORMAL for negative vy (s24 sign extension), not an
; overflow. Helper consumes the carry-out of the rounding add and
; clamps VX1+0,X in place (preserves X).
; --- evy16 clamp, common case inline (spectrack 2026-07-12: 88% of the
; old ev_clamp_evy16 calls did nothing). C is the rounding add's carry —
; still consumed here, the carry-chain contract just moved to the site.
   LDA zp_br_vy_x
   ADC #0                                  ; rounded evy16 hi byte
   BNE ec_hi_nz                            ; hi != 0 → rare, full logic
   LDA VX1+0,X
   BPL ec_done                             ; fits s8: no call, no store
   LDA #$7F                                ; 128..255 → clamp
   STA VX1+0,X
   BNE ec_done                             ; (A = $7F: always taken)
ec_hi_nz:
   ev_clamp_hi_nz
ec_done:

; (Cache writes are deferred to the two exits — each does ONE armed
; fill from the struct/working regs; the miss path has no cache
; pointer at all, 2026-07-15.)

; Near-clip on full s24: clipped iff total_vy < NEAR_88 (= 128 in 8.8).
;   vyext < 0 → clipped (very negative)
;   vyext > 0 → ok      (very positive, ≥ 256)
;   vyext = 0 → check (vyhi + carry from vylo bit 7) >= 1.
   LDA zp_br_vy_x
   BMI nc_fail
   BNE nc_ok
   LDA VX1+0,X
   BMI nc_fail
   BNE nc_ok                               ; evy>0 -> ok (was BEQ+JMP)
nc_fail:
; Near-clipped: armed cache fill (evy/evx from the struct — usable on
; any future hit — plus the clip verdict), and the struct clip byte.
   LDA zp_seg_v_idx_b
   AND #$20
   BNE ncf_hi
   LDY zp_seg_v_idx_l
   LDA VX1+0,X
   STA VC_EVY,Y
   LDA VX1+1,X
   STA VC_EVX,Y
   LDA #0
   STA VC_RLO,Y                            ; rlo = 0 = the clip verdict
   LDA #1
   STA VX1+2,X                             ; clip = 1
   RTS
ncf_hi:
   LDY zp_seg_v_idx_l
   LDA VX1+0,X
   STA VC_EVY+$100,Y
   LDA VX1+1,X
   STA VC_EVX+$100,Y
   LDA #0
   STA VC_RLO+$100,Y                       ; rlo = 0 = the clip verdict
   LDA #1
   STA VX1+2,X
   RTS
nc_ok:
; Save view-space x for br_project_x below (deferred past the
; near-clip test; vxlo/hi/ext are still intact — nothing above clobbers
; them since the Y projection moved to the post-has_gap stage).
; (the zp_v_x staging copy died 2026-07-19: nothing clobbers
; zp_br_vx_* after the rotate — view.s is the sole writer — so
; br_project_x and the chain path read/write zp_br_vx directly)
; --- Compute reciprocal: vy_idx = s24 total_vy >> 7 (9.1). The old
; code dropped vy_ext ('per s8 vx contract') — but wide-vx segs are
; projected now, and a vertex with vy >= 256 view units got an index
; computed mod 65536 (e.g. vy=262 -> idx 10 instead of 524, recip 23x
; too big, sx=-2296 instead of 77). br_recip clamps to [2,1023]. ---
   LDA zp_br_vy_l
   ASL A
   LDA zp_br_vy_h
   ROL A
   TAY                                     ; idx lo rides Y (register ABI)
   LDA zp_br_vy_x
   ROL A
   TAX                                     ; idx hi rides X
   JSR br_recip                            ; rhi/rlo = reciprocal

; --- Project X using saved view-x integer + fractional parts ---
; br_project_x goes wide when the s16 view-x (vxext:vxint)
; doesn't fit s8: Python projects these full-width (sx far
; off-screen) and their mark_solid and clipped draws still count —
; skipping the seg loses occlusion (e.g. mark_solid(0,81) at
; (800,-3400,96)) and over-emits behind it.
   JSR br_project_x                        ; -> Y = sx lo, A = sx hi
   LDX zp_seg_ep                           ; (recip/project clobbered X)
   STA VX1+4,X                             ; sx_hi (from A)
   TYA
   STA VX1+3,X                             ; sx_lo

; --- Struct stores from the working regs, then ONE armed fill drops
; the whole cache entry (evy/evx via the struct, the rest from the
; regs — sx still lives in zp_br_res_l/h from br_project_x). ---
   LDA zp_br_r_m8
   STA VX1+13,X                            ; rhi/rlo for ap2_solid_proj
   LDA zp_br_r_s
   STA VX1+14,X
   LDA zp_seg_v_idx_b
   AND #$20
   BNE vcf_hi
   LDY zp_seg_v_idx_l
   LDA VX1+0,X
   STA VC_EVY,Y
   LDA VX1+1,X
   STA VC_EVX,Y
   LDA zp_br_r_m8
   STA VC_RHI,Y
   LDA zp_br_r_s
   STA VC_RLO,Y
   LDA zp_br_res_l
   STA VC_SXL,Y
   LDA zp_br_res_h
   STA VC_SXH,Y
; (clip verdict = the NONZERO rlo just stored; VC_CLIP retired)
   JMP vs_serve                            ; SERVE AT FIRST TRANSFORM —
                                        ; tail; RTSes to our caller
vcf_hi:
   LDY zp_seg_v_idx_l
   LDA VX1+0,X
   STA VC_EVY+$100,Y
   LDA VX1+1,X
   STA VC_EVX+$100,Y
   LDA zp_br_r_m8
   STA VC_RHI+$100,Y
   LDA zp_br_r_s
   STA VC_RLO+$100,Y
   LDA zp_br_res_l
   STA VC_SXL+$100,Y
   LDA zp_br_res_h
   STA VC_SXH+$100,Y
   JMP vs_serve                            ; SERVE AT FIRST TRANSFORM (tail)
.endscope


; ============================================================================
; vxc_arm — the coherence-cache tier of the vertex pipeline (2026-07-12:
; the old vxc_to_view wrapper + vxc_warm_load hop, flattened into THIS
; file so the whole per-vertex path — frame-cache probe, coherence probe,
; warm reconstruction, rotate fallback — reads top to bottom in one
; place). JSR'd from vxc_jsr_site above when VXC is enabled (vxc_frame
; patches the operand; disabled frames call br_to_view_fetch directly,
; zero overhead). Ends RTS; the caller falls into the evy/evx compute.
;
; In:  zp_seg_v_idx_l/b (vertex key), zp_seg_v_bitm (1 << (idx&7)),
;      vxc_ref_x/y (this frame's to_view(0,0), s24 each)
; Out: zp_br_vx/vy lo/hi/ext = exact view totals (bit-identical to
;      br_to_view: base' = L(w) is translation-invariant, see vxcache.s)
; ============================================================================
vxc_arm:
.scope
   LDX zp_seg_v_idx_b                      ; VXC_VALID index = B (header key)
   PAGE BANK_C
   LDA VXC_VALID,X
   AND zp_seg_v_bitm
   BEQ va_cold
; --- warm: total = base + ref, two s24 adds (page-split on B bit 5) ---
   LDY zp_seg_v_idx_l
   TXA                                     ; X still = idx_b from entry
   AND #$20                                ; idx >= 256  <=>  B >= 32 (B<=58)
   BNE va_hi
   CLC
   LDA VXC_XLO,Y
   ADC vxc_ref_x+0
   STA zp_br_vx_l
   LDA VXC_XHI,Y
   ADC vxc_ref_x+1
   STA zp_br_vx_h
   LDA VXC_XEXT,Y
   ADC vxc_ref_x+2
   STA zp_br_vx_x
   CLC
   LDA VXC_YLO,Y
   ADC vxc_ref_y+0
   STA zp_br_vy_l
   LDA VXC_YHI,Y
   ADC vxc_ref_y+1
   STA zp_br_vy_h
   LDA VXC_YEXT,Y
   ADC vxc_ref_y+2
   STA zp_br_vy_x
   PAGE BANK_L2                            ; exit L2 = the OFF-path's exit
   RTS                                     ; state (br_to_view_fetch): one
                                           ; contract, and br_recip's
                                           ; per-call PAGE dies (2026-07-21)
va_hi:
   CLC
   LDA VXC_XLO+$100,Y
   ADC vxc_ref_x+0
   STA zp_br_vx_l
   LDA VXC_XHI+$100,Y
   ADC vxc_ref_x+1
   STA zp_br_vx_h
   LDA VXC_XEXT+$100,Y
   ADC vxc_ref_x+2
   STA zp_br_vx_x
   CLC
   LDA VXC_YLO+$100,Y
   ADC vxc_ref_y+0
   STA zp_br_vy_l
   LDA VXC_YHI+$100,Y
   ADC vxc_ref_y+1
   STA zp_br_vy_h
   LDA VXC_YEXT+$100,Y
   ADC vxc_ref_y+2
   STA zp_br_vy_x
   PAGE BANK_L2                            ; exit L2 = the OFF-path's exit
   RTS                                     ; state (br_to_view_fetch): one
                                           ; contract, and br_recip's
                                           ; per-call PAGE dies (2026-07-21)
va_cold:
; --- cold: mark valid, fetch + rotate for real, snapshot the base ---
   LDA VXC_VALID,X
   ORA zp_seg_v_bitm
   STA VXC_VALID,X
   JSR br_to_view_fetch                    ; pages L2 itself
   PAGE BANK_C
   vxc_cold_store                      ; leaf (vxcache.s): base = total-ref
   PAGE BANK_L2                        ; (same exit contract as the warm arms)
   RTS
.endscope


; ============================================================================
; vs_serve — vertex-span descriptor service AT FIRST TRANSFORM
; (2026-07-25, Eben's serve-at-transform). Tail of br_seg_xform_vertex's
; ok-miss exits ONLY: a vc hit means the vertex was already transformed
; (and served) this frame — later touches cost NOTHING; the near-clip
; miss exits skip this tail (nothing can draw at a clipped vertex). The
; vc valid bit IS the once-per-frame mark: the VDONE bitmap, its wipe
; and the emit-cascade probe sites are all retired.
;   Entry: BANK_L2; X = zp_seg_ep (struct); zp_br_r_m8/r_s = this
;   vertex's recip (shifter selected by br_recip); VX+3/4 = sx; vertex
;   key in zp_seg_v_idx; trigger heights zp_seg_fh/ch (subsector
;   prologue) + header +12/13 (bfh/bch, read under L0 only when a step
;   code actually fires). Exit: RTS under BANK_L2 (the xform exit
;   contract). Clobbers A/X/Y + zp_vs_* + projection scratch.
;   Spans project via br_project_y at the endpoint recip — the same
;   (M8,S,h) tuples the seg's own y stage will use, so the VWHC takes
;   the miss here and the hit there: projection work is conserved.
; ============================================================================
vs_serve:
.scope
   LDA VX1+4,X                             ; column off-screen (sx_h)?
   BNE srv_rts                             ; (near-clip impossible here)
; re-select the rns shifter for THIS vertex's S: br_project_x just
; patched rns_go for its own net shift (the "every consumer re-selects"
; invariant, project.s). Projecting without this POISONS the VWHC — a
; wrong value under a correct (M8,S,h) key, and the seg's own y stage
; later serves the poison (the 1500-pose 107-vs-117 catch).
; (measured: at-entry beats after-the-desc-read — desc-live serves
; dominate, so the A-preservation ride costs more than the desc-0 skip
; saves: 2,930,385 vs 2,931,104 suite total)
   LDA zp_br_r_s
   RNS_SELECT                              ; (clobbers A/X; srv paths
                                        ; reload X from zp_seg_ep)
   LDY zp_seg_v_idx_l
   LDA zp_seg_v_idx_b
   AND #$20                                ; senior plane (ids 256+)
   BNE srv_hi
   LDA VDESC_LO,Y
   BNE srv_on
srv_rts:
   RTS
srv_hi:
   LDA VDESC_HI,Y
   BNE srv_on
   RTS
srv_on:
   CMP #$80
   BCC srv_coded
   JMP vsx_expl                            ; $80|i: explicit table ref
srv_coded:
   CMP #2
   BCC srv_c1                              ; $01: fh->ch
   BEQ srv_c2                              ; $02: fh->bfh
   CMP #4
   BCC srv_c3                              ; $03: bch->ch
; $04 frame pair: top piece then bottom piece
   JSR srv_do_c3
srv_c2:                                    ; fh -> bfh, NEEDBB-gated (a
   LDA zp_seg_flags                        ; solid or stepless trigger
   AND #$08                                ; self-annuls the code)
   BEQ srv_rts
   PAGE BANK_L0                            ; bfh: header byte +12
   LDY #12
   LDA (zp_seg_hdr_p),Y
   STA zp_vs_hh                            ; span hi = bfh
   LDA zp_seg_fh
   STA zp_vs_hl                            ; span lo = fh
   JMP srv_span                            ; (srv_span re-pages L2)
srv_c3:
   JMP srv_do_c3                           ; tail: its RTS exits vs_serve
srv_c1:                                    ; full corner: fh -> ch
   LDA zp_seg_ch
   STA zp_vs_hh
   LDA zp_seg_fh
   STA zp_vs_hl
   JMP srv_span
srv_do_c3:                                 ; bch -> ch, NEEDBT-gated
   LDA zp_seg_flags
   AND #$04
   BEQ srv_c3rts
   PAGE BANK_L0                            ; bch: header byte +13
   LDY #13
   LDA (zp_seg_hdr_p),Y
   STA zp_vs_hl                            ; span lo = bch
   LDA zp_seg_ch
   STA zp_vs_hh                            ; span hi = ch
; falls into srv_span; when JSR'd (frame pair) its RTS returns to the
; dispatch, which falls into srv_c2 for the bottom piece
srv_span:
   PAGE BANK_L2                            ; br_project_y's VWHC planes
   LDA zp_vs_hh
   SEC
   SBC zp_br_vz
   JSR br_project_y                        ; -> Y = lo, A = hi
   STA zp_line_yl_h
   STY zp_line_yl_l
   LDA zp_vs_hl
   SEC
   SBC zp_br_vz
   JSR br_project_y
   STA zp_line_yr_h
   STY zp_line_yr_l
   PAGE BANK_C
   LDX zp_seg_ep
   LDA VX1+3,X                             ; column (sx_h gated zero)
   JSR SC_DCL_VERT_ON
   PAGE BANK_L2                            ; xform exit contract
   LDX zp_seg_ep
srv_c3rts:
   RTS

vsx_expl:
; explicit table walk: clamp world heights to this trigger's front
; sector, project at the endpoint recip (already staged + shifter
; selected — br_recip ran moments ago), emit. VEXPL planes live in the
; C window; clamps are pure ZP; projections excurse to L2.
   AND #$7F
   STA zp_vs_i
   PAGE BANK_C
vsx_exl:
   LDY zp_vs_i
; c_lo = max(h_lo, fh)  [signed s8]
   LDA VEXPL_LO,Y
   SEC
   SBC zp_seg_fh
   BVC vsx_lo1
   EOR #$80
vsx_lo1:
   BMI vsx_lofh
   LDA VEXPL_LO,Y
   JMP vsx_lohave
vsx_lofh:
   LDA zp_seg_fh
vsx_lohave:
   STA zp_vs_hl
; c_hi = min(h_hi, ch)  [signed s8]
   LDA VEXPL_HI,Y
   SEC
   SBC zp_seg_ch
   BVC vsx_hi1
   EOR #$80
vsx_hi1:
   BPL vsx_hich
   LDA VEXPL_HI,Y
   JMP vsx_hihave
vsx_hich:
   LDA zp_seg_ch
vsx_hihave:
   STA zp_vs_hh
; empty? (c_hi <= c_lo, signed) — A rides from the STA above
   SEC
   SBC zp_vs_hl
   BVC vsx_em1
   EOR #$80
vsx_em1:
   BMI vsx_enext
   BEQ vsx_enext
   PAGE BANK_L2
   LDA zp_vs_hh
   SEC
   SBC zp_br_vz
   JSR br_project_y
   STA zp_line_yl_h
   STY zp_line_yl_l
   LDA zp_vs_hl
   SEC
   SBC zp_br_vz
   JSR br_project_y
   STA zp_line_yr_h
   STY zp_line_yr_l
   PAGE BANK_C
   LDX zp_seg_ep
   LDA VX1+3,X
   JSR SC_DCL_VERT_ON
vsx_enext:
   LDY zp_vs_i
   LDA VEXPL_CONT,Y
   BEQ vsx_edone
   INC zp_vs_i
   JMP vsx_exl
vsx_edone:
   PAGE BANK_L2                            ; xform exit contract
   LDX zp_seg_ep
   RTS
.endscope
