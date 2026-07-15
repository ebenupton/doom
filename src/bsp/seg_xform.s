
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
; in subsector.s). No PAGE anywhere in this routine (2026-07-11): the
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
   LDA #0
   STA VX1+2,X                             ; clip = 0 (struct)
   LDA VCACHE_VALID_BASE,Y
   AND zp_seg_v_bitm
   BEQ vc_miss
; --- Cache hit: senior-bit arm (plane page BAKED), Y = idx&255 for every
; field — no address generation, no Y navigation. Fields go STRAIGHT
; from the planes into the endpoint struct (X = zp_seg_ep); rhi/rlo also
; land in the zp_br working slots because rns_select / the projections
; consume them there (two consumers of the value in A, not a copy). ---
   LDA zp_seg_v_idx_b
   AND #$20                                ; senior: idx >= 256 (B >= 32)
   BNE vc_hit_hi
   LDY zp_seg_v_idx_l
   LDA VC_EVY,Y
   STA VX1+0,X
   LDA VC_EVX,Y
   STA VX1+1,X
   LDA VC_CLIP,Y                           ; cached near-clip verdict
   BEQ vch0_ok
   STA VX1+2,X                             ; clip = 1
   RTS
vch0_ok:
   LDA VC_RHI,Y
   STA zp_br_r_m8
   STA VX1+13,X                            ; rhi (for ap2_solid_proj)
   LDA VC_RLO,Y
   STA zp_br_r_s
   STA VX1+14,X                            ; rlo
   JSR rns_select                          ; cached S → re-pick the shifter
                                        ; (preserves Y; CLOBBERS X — the
                                        ; vector belongs to whoever wrote
                                        ; rlo LAST)
   LDX zp_seg_ep
   LDA VC_SXL,Y
   STA VX1+3,X                             ; sx_lo
   LDA VC_SXH,Y
   STA VX1+4,X                             ; sx_hi
   RTS                                     ; Y projection DEFERRED to the
                                        ; post-has_gap y stage (2026-07-11):
                                        ; culled segs never project.
vc_hit_hi:
; (senior twin — pages +$100 baked; body identical)
   LDY zp_seg_v_idx_l
   LDA VC_EVY+$100,Y
   STA VX1+0,X
   LDA VC_EVX+$100,Y
   STA VX1+1,X
   LDA VC_CLIP+$100,Y
   BEQ vch1_ok
   STA VX1+2,X
   RTS
vch1_ok:
   LDA VC_RHI+$100,Y
   STA zp_br_r_m8
   STA VX1+13,X
   LDA VC_RLO+$100,Y
   STA zp_br_r_s
   STA VX1+14,X
   JSR rns_select
   LDX zp_seg_ep
   LDA VC_SXL+$100,Y
   STA VX1+3,X
   LDA VC_SXH+$100,Y
   STA VX1+4,X
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

; Scope split: vxc_jsr_site must be a GLOBAL label — vxc_frame SMC-patches
; this JSR's operand between br_to_view_fetch (VXC disabled: the original
; fetch+rotate path) and vxc_to_view (translation-coherent vertex cache,
; which reaches the fetch through its own cold path).
; No local labels cross this boundary (verified: vc_* live above, nc_*
; below in their own scope).
.endscope
vxc_jsr_site:
   JSR br_to_view_fetch
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
   JSR ev_clamp_hi_nz
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
   LDA #1
   STA VC_CLIP,Y
   STA VX1+2,X                             ; clip = 1
   RTS
ncf_hi:
   LDY zp_seg_v_idx_l
   LDA VX1+0,X
   STA VC_EVY+$100,Y
   LDA VX1+1,X
   STA VC_EVX+$100,Y
   LDA #1
   STA VC_CLIP+$100,Y
   STA VX1+2,X
   RTS
nc_ok:
; Save view-space x for br_project_x below (deferred past the
; near-clip test; vxlo/hi/ext are still intact — nothing above clobbers
; them since the Y projection moved to the post-has_gap stage).
   LDA zp_br_vx_h
   STA zp_v_x_h
   LDA zp_br_vx_l
   STA zp_v_x_l
   LDA zp_br_vx_x
   STA zp_v_x_x
; --- Compute reciprocal: vy_idx = s24 total_vy >> 7 (9.1). The old
; code dropped vy_ext ('per s8 vx contract') — but wide-vx segs are
; projected now, and a vertex with vy >= 256 view units got an index
; computed mod 65536 (e.g. vy=262 -> idx 10 instead of 524, recip 23x
; too big, sx=-2296 instead of 77). br_recip clamps to [2,1023]. ---
   LDA zp_br_vy_l
   ASL A
   LDA zp_br_vy_h
   ROL A
   STA zp_br_t0
   LDA zp_br_vy_x
   ROL A
   STA zp_br_t1
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
   LDA #0
   STA VC_CLIP,Y
; near_clip = 0. (Y projection deferred to the post-has_gap y stage.)
   RTS
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
   LDA #0
   STA VC_CLIP+$100,Y
   RTS
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
   PAGE BANK_L0
   RTS
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
   PAGE BANK_L0
   RTS
va_cold:
; --- cold: mark valid, fetch + rotate for real, snapshot the base ---
   LDA VXC_VALID,X
   ORA zp_seg_v_bitm
   STA VXC_VALID,X
   JSR br_to_view_fetch                    ; pages L2 itself
   PAGE BANK_C
   JSR vxc_cold_store                      ; leaf (vxcache.s): base = total-ref
   PAGE BANK_L0
   RTS
.endscope
