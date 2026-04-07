; doom_fe.asm — 6502 DOOM BSP front-end
; Assembled with beebasm, executed in py65
;
; Performs: BSP traversal, back-face test, view transform, near clip,
; projection, column-bitmap visibility.  Outputs seg commands into a
; buffer for the Python back-end (FPClipSpans + line draw).
;
; Memory map (set up by Python before execution):
;   $0000-$00FF  Zero page
;   $0100-$01FF  Hardware stack
;   BSS (zero-initialized, $0200-$22D1):
;   $0200-$02D7  BSP node stack (72 entries × 3 bytes = 216 bytes)
;   $02D8-$02EF  Layout offsets (24B)
;   $02F0-$02FF  [pad / saved screen byte at $02F8] (16B)
;   $0300-$0469  Deferred queue (362B)
;   $046A-$066B  Scratch spans (514B)
;   $066C-$066F  [pad]
;   $0670-$166F  Vertex cache (4096B)
;   $1670-$16AF  Vcache valid bitmap (64B)
;   $16B0-$202F  VWH cache (2432B)
;   $2030-$20CF  VWH valid bitmap (160B)
;   $20D0-$22D1  Spans array (514B)
;   Code ($22D2-$4F7D):
;   $22D2+       Code (this file)
;   Tables ($4F7E-$57FF, loaded from ROM, not zeroed):
;   $4F7E-$537F  Reciprocal tables (1026B)
;   $5380-$53FF  Sin/cos tables (128B)
;   $5400-$57FF  Quarter-square tables (4 × 256)
;   $5800+       Framebuffers
;   $8000-$BFFF  Sideways ROM window (bank-switched via $FE30)

ORG &22D2

; ======================================================================
; Zero page assignments
; ======================================================================

; --- Math ---
zp_math_a   = &00
zp_math_b   = &01
zp_res_lo   = &02
zp_res_hi   = &03

; Dedicated divide scratch (used by fp_div8).  Leaf routine, but called
; from tighten with live zp_tmp* state, so use dedicated slots.
zp_div_num  = &08           ; u16 dividend / quotient output
zp_div_den  = &0A           ; u16 divisor (|den|)
zp_div_rem  = &0C           ; u16 remainder accumulator
zp_div_sign = &0E           ; u8 sign flag (0 = positive result, 1 = negative)

; --- Player state (initialised by Python) ---
zp_px_int   = &10          ; s8  prescaled player x (integer part of 8.8)
zp_py_int   = &11          ; s8  prescaled player y
zp_px_lo    = &12          ; u8  fractional x (low byte of 8.8)
zp_py_lo    = &13          ; u8  fractional y
zp_px_int_hi = &04         ; u8  sign extension of px_int (0 or $FF), set at entry
zp_py_int_hi = &05         ; u8  sign extension of py_int
zp_vz_ps    = &14          ; s8  prescaled eye height
zp_angle    = &15          ; u8  angle byte (0..255)

; --- Trig (computed by decompose_angle) ---
zp_sin_mag   = &16         ; u8
zp_sin_neg   = &17         ; u8 (0 or 1)
zp_sin_unity = &18         ; u8 (0 or 1)
zp_cos_mag   = &19         ; u8
zp_cos_neg   = &1A         ; u8 (0 or 1)
zp_cos_unity = &1B         ; u8 (0 or 1)

; --- Fractional rotation (s16, 8.8 format) ---
zp_frac_vx   = &1C         ; s16 (lo, hi)
zp_frac_vy   = &1E         ; s16
zp_frac_vx_ext = &06       ; u8 sign extension of frac_vx_hi (0 or $FF)
zp_frac_vy_ext = &07       ; u8 sign extension of frac_vy_hi

; --- Current seg working area ---
zp_sx1       = &20         ; s16
zp_sx2       = &22         ; s16
zp_ft1       = &24         ; s16
zp_fb1       = &26         ; s16
zp_ft2       = &28         ; s16
zp_fb2       = &2A         ; s16
zp_x_lo_clip = &2C         ; s16 (min of sx1, sx2)
zp_x_hi_clip = &2E         ; s16 (max of sx1, sx2)

; --- View transform working area ---
zp_vx1       = &30         ; s16 (view x, rounded)
zp_vy1       = &32         ; s16 (view y)
zp_vi1       = &34         ; u16 (vy_idx)
zp_vx2       = &36         ; s16
zp_vy2       = &38         ; s16
zp_vi2       = &3A         ; u16

; --- Near clip output ---
zp_ex1       = &3C         ; s16
zp_ey1       = &3E         ; s16
zp_ex2       = &40         ; s16
zp_ey2       = &42         ; s16

; --- Span double-buffer pointers ---
zp_cspan     = &56         ; u16: pointer to current span base (count byte)
; After each mark_solid/tighten, swapped with scratch buffer.
; Eliminates the 44K-cycle copy-back.
; (Reuses removed zp_cmd_lo/hi slots; must survive entire frame.)
; zp_dspan removed — dest count managed via self-modifying INC in inc_dest_count

; --- Reciprocal / projection temps ---
zp_rxh       = &44         ; u8 recip hi
zp_rxl       = &45         ; u8 recip lo

; --- General temporaries ---
zp_tmp0      = &48         ; s16
zp_tmp1      = &4A         ; s16
zp_tmp2      = &4C         ; s16
zp_tmp3      = &4E         ; s16

; --- BSP ---
zp_bsp_sp    = &50         ; u8 bsp stack pointer (byte offset)
zp_seg_idx   = &51         ; u16 current seg index
zp_seg_count = &53         ; u8 segs remaining in subsector
zp_seg_flags = &54         ; u8 seg flags

; --- Command buffer (REMOVED — now using direct line peripheral) ---
; zp_cmd_lo    = &56       ; (removed — now reused as zp_cspan)
; zp_cmd_hi    = &57       ; (removed — now reused as zp_cspan+1)

; --- Deferred mark_solid stack (within subsector) ---
zp_defer_sp  = &58         ; u8 (byte offset into deferred stack)

; --- Pointer temps for ROM access ---
zp_ptr0      = &5A         ; u16 general-purpose pointer
zp_ptr1      = &5C         ; u16

; --- Running seg pointers (advanced by seg_loop to avoid per-seg
;     idx*12 and idx*24 multiplies inside render_seg/read_seg_detail) ---
zp_seg_hdr_ptr = &5E       ; u16 pointer to current seg header (12B stride)
zp_seg_det_ptr = &60       ; u16 pointer to current seg detail (24B stride)

; --- Clipper state (used during line drawing, after BSP traversal) ---
; These overlap with zp_vx1..zp_vx2 ($30-$36) and zp_ls_* ($C4-$CE),
; which are only live during BSP traversal.
zp_cl_x1       = &A0    ; s16 line start X
zp_cl_y1       = &A2    ; s16 line start Y
zp_cl_x2       = &A4    ; s16 line end X
zp_cl_y2       = &A6    ; s16 line end Y
zp_cl_dx       = &A8    ; s16 dx = x2 - x1
zp_cl_dy       = &AA    ; s16 dy = y2 - y1
zp_cl_t0       = &AC    ; s16 parametric start (0.8 format)
zp_cl_t1       = &AE    ; s16 parametric end (0.8 format)
zp_cl_ta_dx    = &B0    ; s16 fp_mul8(ta, dx)
zp_cl_ta_x1    = &B2    ; s16 fp_mul8(ta, x1)
zp_cl_ba_dx    = &B4    ; s16 fp_mul8(ba, dx)
zp_cl_ba_x1    = &B6    ; s16 fp_mul8(ba, x1)
zp_cl_span_ptr = &B8    ; u16 pointer to current span record
zp_cl_count    = &C4    ; u8 remaining span count
zp_cl_xlo      = &C5    ; u8 current span xlo
zp_cl_xhi      = &C6    ; u8 current span xhi (0 = 256)
zp_cl_ta       = &C7    ; s16 current span top slope
zp_cl_tb       = &C9    ; s16 current span top intercept
zp_cl_ba       = &CB    ; s16 current span bottom slope
zp_cl_bb       = &CD    ; s16 current span bottom intercept
zp_cl_cx1      = &30    ; s16 clipped x1 output
zp_cl_cy1      = &32    ; s16 clipped y1 output
zp_cl_cx2      = &34    ; s16 clipped x2 output
zp_cl_cy2      = &36    ; s16 clipped y2 output
zp_cl_x_min    = &38    ; s16 min(x1,x2) — line X range
zp_cl_x_max    = &3A    ; s16 max(x1,x2)
zp_cl_y_min    = &3C    ; s16 min(y1,y2) — line Y range
zp_cl_y_max    = &3E    ; s16 max(y1,y2)

; --- Portal walk / group-based clipper state ---
; Line ordering (left-to-right).
; These values are set fresh at the start of each clip_and_rasterise
; call and only need to survive within that call.  fp_linfn writes to
; $60-$6B during flush, but flush only runs AFTER all segs in a
; subsector are done, so these are safe during individual clipper calls.
zp_pw_xl      = &62  ; s16
zp_pw_yl      = &64  ; s16
zp_pw_xr      = &66  ; s16
zp_pw_yr      = &68  ; s16
zp_pw_y_lo    = &6A  ; s16 min(yl, yr)
zp_pw_y_hi    = &6C  ; s16 max(yl, yr)
zp_pw_dx      = &6E  ; s16 xr - xl

; Group tracking — in reciprocal/projection scratch ($44-$47), dead during clipper
zp_pw_grp_ptr = &44  ; u16 pointer to first span of current group
zp_pw_grp_cnt = &46  ; u8 span count in group
zp_pw_prev_xhi = &47 ; u8

; Clip results for portal merge — tighten scratch range, dead during clipper
zp_pw_cf_x1   = &88  ; s16 c_first start X
zp_pw_cf_y1   = &8A  ; s16 c_first start Y
zp_pw_cf_x2   = &8C  ; s16 c_last end X
zp_pw_cf_y2   = &8E  ; s16 c_last end Y

; Portal walk iteration scratch
zp_pw_fi       = &90  ; u8 first visible span index within group
zp_pw_li       = &91  ; u8 last visible span index within group
; zp_ptr0/ptr1 are dead during clipper (only used for ROM access in BSP)
zp_pw_iter     = &5C  ; u8 iteration counter
zp_pw_iter_ptr = &5A  ; u16 iteration pointer into span array

; ======================================================================
; RAM addresses
; ======================================================================
; (old colbitmap at &0200 removed — visibility goes through span hooks)
bsp_stack    = &0200        ; 216 bytes (72 × 3)
; cmd_buffer removed — using direct line peripheral at $FE20-$FE27
vcache       = &0670        ; vertex cache: 512 × 8 bytes = 4096 bytes
vcache_valid = &1670        ; vertex cache valid bitmap: 64 bytes (512 bits)

; Vertex cache entry layout (8 bytes each)
VC_VX    = 0                ; s16
VC_VY    = 2                ; s16
VC_VI    = 4                ; u16 (vy_idx)
VC_PAD   = 6                ; s16 (reserved, matches Python VC_SX slot)

; VWH (vertex-with-height) projected-Y cache: 1216 × 2 bytes = 2432 bytes
vwh_cache    = &16B0        ; 2432 bytes
vwh_valid    = &2030        ; 160-byte valid bitmap (covers up to 1280 entries)

; ======================================================================
; ROM base addresses (sideways ROM window)
; ======================================================================
rom_window   = &8000

; Quarter-square tables (page-aligned, just before framebuffer)
sqr_lo       = &5400
sqr_hi       = &5500
sqr2_lo      = &5600
sqr2_hi      = &5700

; Sin/cos + reciprocal tables (just before quarter-square tables)
rom_recip    = &4F7E
sin_mag_tbl  = rom_recip        ; 64 bytes
sin_unity_tbl = rom_recip + 64  ; 64 bytes
recip_hi_tbl = rom_recip + 128  ; 513 bytes
recip_lo_tbl = rom_recip + 641  ; 513 bytes

; ======================================================================
; Layout offsets within rom_window (set by Python into these RAM locations)
; ======================================================================
zp_off_verts    = &60       ; u16
zp_off_nodes    = &62       ; u16
zp_off_ss       = &64       ; u16  (was conflicting with old zp_cmd_lo, now free)

; Hmm, running out of ZP space. Let me use a different region.
; Actually let me use fixed addresses for the ROM layout offsets
; since they don't change during execution.  Store them in RAM.

layout_off_verts   = &02D8  ; u16
layout_off_nodes   = &02DA  ; u16
layout_off_ss      = &02DC  ; u16
layout_off_seg_hdr = &02DE  ; u16
layout_n_nodes     = &02E0  ; u16

; Raw player position (s16 relative to map_center), set by fe6502.py per
; frame.  Used by point_on_side so the cross product has the correct sign
; on any node, independent of PRESCALE rounding.
zp_wx              = &C0    ; s16
zp_wy              = &C2    ; s16

; Scratch ZP for queue_tighten + line_survives (distinct from hook args
; at $A0-$B9 which hold the inputs, and from render_seg's scratch at
; $80-$93 which must survive across subroutine calls).
zp_top_dom    = &C4          ; u8
zp_bot_dom    = &C5          ; u8
zp_ls_x1      = &C6          ; s16
zp_ls_y1      = &C8          ; s16
zp_ls_x2      = &CA          ; s16
zp_ls_y2      = &CC          ; s16
zp_ls_count   = &CE          ; u8
zp_ls_found   = &CF          ; u8
zp_ls_scratch = &D0          ; u8 (saved xhi/xlo byte during compare)

; Running tail pointer for the deferred span-op queue.  Needs to be in
; zero page so (zp_q_tail),Y indirect-indexed addressing works.
zp_q_tail     = &D1          ; u16

; Frame-invariant ROM base pointers — computed once at entry from the
; layout_off_* values + HI(rom_window), so point_on_side/get_child/etc.
; can address with a single ADC pair instead of a two-step add.
zp_node_base     = &D3       ; u16: rom_window + layout_off_nodes
zp_vert_base     = &D5       ; u16: rom_window + layout_off_verts
zp_ss_base       = &D7       ; u16: rom_window + layout_off_ss
zp_seg_hdr_base  = &D9       ; u16: rom_window + layout_off_seg_hdr

; Native flush scratch (used by mark_solid / tighten / _make_span).
; Currently live only inside flush — callers outside flush can reuse.
zp_mk_tslope     = &DB       ; s16: tfn slope for new span
zp_mk_tintercept = &DD       ; s16
zp_mk_bslope     = &DF       ; s16
zp_mk_bintercept = &E1       ; s16
zp_mk_xlo        = &E3       ; u8
zp_mk_xhi        = &E4       ; u8 (0 = 256)
zp_mk_out        = &E5       ; u16: pointer to output span slot
zp_mk_tmp        = &E7       ; u16: scratch for fp_eval inputs
zp_mk_top_l      = &E9       ; s16: fp_eval(tfn, xlo)
zp_mk_top_r      = &EB       ; s16: fp_eval(tfn, xhi-1)
zp_mk_bot_l      = &ED       ; s16: fp_eval(bfn, xlo)
zp_mk_bot_r      = &EF       ; s16: fp_eval(bfn, xhi-1)

; mark_solid / tighten inputs & iteration state
zp_ms_lo         = &F0       ; s16 input: lo
zp_ms_hi         = &F2       ; s16 input: hi
zp_ms_ilo        = &F4       ; s16 clamped: max(0, lo)
zp_ms_ihi        = &F6       ; s16 clamped: min(256, hi+1)
zp_ms_src        = &F8       ; u16: pointer to current source span
zp_ms_count      = &FA       ; u8: source spans remaining
zp_ms_xlo16      = &FB       ; s16: current src span xlo (s16)
zp_ms_xhi16      = &FD       ; s16: current src span xhi (s16, 256 unwrapped)

; Tighten scratch — only live during flush.  Reuses the $80-$9F range
; which holds render_seg bt/bb and to_view products — both dead by flush.
zp_tg_new_tslope     = &80   ; s16
zp_tg_new_tintercept = &82   ; s16
zp_tg_new_bslope     = &84   ; s16
zp_tg_new_bintercept = &86   ; s16
zp_tg_src_tslope     = &88   ; s16 (stash of current span's tfn)
zp_tg_src_tintercept = &8A   ; s16
zp_tg_src_bslope     = &8C   ; s16 (stash of current span's bfn)
zp_tg_src_bintercept = &8E   ; s16
zp_tg_ox0            = &90   ; s16
zp_tg_ox1            = &92   ; s16
zp_tg_tx0            = &94   ; s16 (inner tx range)
zp_tg_tx1            = &96   ; s16
zp_tg_bx0            = &98   ; s16 (inner bx range)
zp_tg_bx1            = &9A   ; s16
zp_tg_tfn_use_new    = &9C   ; u8: nonzero if current inner range uses new_tfn
zp_tg_bfn_use_new    = &9D   ; u8: nonzero if current inner range uses new_bfn
zp_tg_pwmax_count    = &9E   ; u8: pw_max's count (saved across tg_process_tx_range
                             ;     because pw_min clobbers zp_pw_count)
zp_tg_pwmax_cx       = &BA   ; s16: pw_max's crossover x (saved across the
                             ;      tg_process_tx_range call, whose pw_min can
                             ;      overwrite zp_pw_cx)

; pw_max / pw_min scratch — reuses the hook ZP range (dead during flush).
zp_pw_f_slope        = &A0   ; s16: f = src fn (top or bot)
zp_pw_f_intercept    = &A2
zp_pw_g_slope        = &A4   ; s16: g = new fn (top or bot)
zp_pw_g_intercept    = &A6
zp_pw_x0             = &A8   ; s16
zp_pw_x1             = &AA   ; s16
zp_pw_d0             = &AC   ; s16: f(x0) - g(x0)
zp_pw_d1             = &AE   ; s16: f(x1-1) - g(x1-1)
zp_pw_cx             = &B0   ; s16: crossover x (when count == 2)
zp_pw_count          = &B2   ; u8: 1 or 2
zp_pw_r0_fn          = &B3   ; u8: 0 = use f, 1 = use g
zp_pw_r1_fn          = &B4   ; u8: 0 = use f, 1 = use g

; Scratch span buffer for mark_solid/tighten — written then copied back.
scratch_spans    = &046A     ; 514-byte buffer

; Visibility-span hook addresses.  These are intercepted by fe6502.py's
; run loop — control never actually reaches those PCs on the real 6502.
; All hooks use the same argument-passing convention: args in $A0..$B9.
spans_flush        = &FE0A  ; apply deferred queue to span state
spans_bbox_cull    = &FE0C  ; project node bbox and test has_gap
                            ; in:  $A0=nid(u16), $A4=far_side(u8)
                            ; out: C=visible?
spans_enter_ss     = &FE0E  ; diagnostic: record which ssid we entered
                            ; in:  $A0=ssid(u16)

; Span hook scratch-arg zero page (reserve $A0..$B9 for arg marshalling).
zp_hk_lo   = &A0           ; x_lo_clip (s16)
zp_hk_hi   = &A2           ; x_hi_clip (s16)
zp_hk_sx1  = &A4           ; sx1       (s16)
zp_hk_sx2  = &A6           ; sx2       (s16)
zp_hk_ft1  = &A8           ; ft1       (s16)
zp_hk_ft2  = &AA           ; ft2       (s16)
zp_hk_fb1  = &AC           ; fb1       (s16)
zp_hk_fb2  = &AE           ; fb2       (s16)
zp_hk_need_bt = &B0        ; u8 (0/non-zero)
zp_hk_need_bb = &B1        ; u8
zp_hk_bt1  = &B2           ; bt1       (s16)
zp_hk_bt2  = &B4           ; bt2       (s16)
zp_hk_bb1  = &B6           ; bb1       (s16)
zp_hk_bb2  = &B8           ; bb2       (s16)

; ======================================================================
; Constants
; ======================================================================
HALF_W       = 128
HALF_H       = 80
NEAR_FP      = 1           ; near plane in 8.0
NF_SUBSECTOR = &80         ; high byte flag for subsector ID

; Seg header offsets (within 12-byte record)
SH_V1   = 0                ; u16
SH_V2   = 2                ; u16
SH_LV1X = 4                ; s16
SH_LV1Y = 6                ; s16
SH_LDX  = 8                ; s8
SH_LDY  = 9                ; s8
SH_FLAGS = 10              ; u8

; Seg flags
SF_DIR    = &01
SF_SOLID  = &02
SF_NEEDBT = &04
SF_NEEDBB = &08

; Seg detail offsets (within 24-byte record)
SD_FH  = 0                 ; s8
SD_CH  = 1                 ; s8
SD_BFH = 2                 ; s8
SD_BCH = 3                 ; s8
; VWH (vertex-with-height) indices: u16 each
SD_VWH_FT1 = 4
SD_VWH_FB1 = 6
SD_VWH_FT2 = 8
SD_VWH_FB2 = 10
SD_VWH_BT1 = 12
SD_VWH_BB1 = 14
SD_VWH_BT2 = 16
SD_VWH_BB2 = 18

; Node offsets (within 16-byte record)
ND_PX  = 0                 ; s16
ND_PY  = 2                 ; s16
ND_DX  = 4                 ; s16
ND_DY  = 6                 ; s16
ND_CHR = 8                 ; u16 right child
ND_CHL = 10                ; u16 left child

; Command types (REMOVED — direct line drawing via peripheral)
; CMD_SOLID  = &53
; CMD_PORTAL = &50
; CMD_ENDSS  = &45
; CMD_DONE   = &00

; Line-drawing peripheral registers
LINE_X0_LO = &A0            ; = zp_cl_x1
LINE_X0_HI = &A1
LINE_Y0_LO = &A2            ; = zp_cl_y1
LINE_Y0_HI = &A3
LINE_X1_LO = &A4            ; = zp_cl_x2
LINE_X1_HI = &A5
LINE_Y1_LO = &A6            ; = zp_cl_y2
LINE_Y1_HI = &A7

; Visibility span array (in RAM at spans_base).  Layout mirrors
; wad_packed.py's SPAN_* constants.  The 2-byte header stores span
; count (u8) + pad, followed by up to MAX_SPANS × 16-byte records.
; xhi=0 in u8 means 256 (half-open [xlo, 256) wrap convention).
;
; Slopes are s16 (not s8) because fp_linfn can produce values outside
; the s8 range.  The outer_top/outer_bot bbox fields are derived
; on-the-fly by Python's draw_clipped path and not stored in RAM.
spans_base    = &20D0        ; RAM address of span array header
MAX_SPANS     = 32
SPAN_SIZE     = 16
SPAN_HDR      = 2
SP_XLO        = 0            ; u8
SP_XHI        = 1            ; u8 (0 = 256)
SP_TSLOPE     = 2            ; s16
SP_BSLOPE     = 4            ; s16
SP_TINTERCEPT = 6            ; s16
SP_BINTERCEPT = 8            ; s16
SP_INNER_TOP  = 10           ; s16
SP_INNER_BOT  = 12           ; s16
SP_OUTER_TOP  = 14           ; u8 outer top (min of top_l, top_r), clamped [0,159]
SP_OUTER_BOT  = 15           ; u8 outer bot (max of bot_l, bot_r), clamped [0,159]

; Deferred span-op queue.  Each subsector queues mark_solid / tighten
; operations while rendering, then flush applies them in order.  Queue
; lives in RAM with 20-byte entries:
;   +0   u8   type (0 = solid, 1 = tighten)
;   +1   u8   top_dom  (tighten only)
;   +2   u8   bot_dom  (tighten only)
;   +3   u8   pad
;   +4   s16  lo
;   +6   s16  hi
;   +8   s16  sx1       (tighten only)
;   +10  s16  sx2       (tighten only)
;   +12  s16  yt1       (tighten only)
;   +14  s16  yt2       (tighten only)
;   +16  s16  yb1       (tighten only)
;   +18  s16  yb2       (tighten only)
;
queue_count   = &0300        ; u8 (count of queued entries)
flush_ptr_lo  = &0301        ; u8: flush iteration pointer lo (RAM)
flush_ptr_hi  = &0302        ; u8: flush iteration pointer hi
flush_rem     = &0303        ; u8: queue entries remaining in flush
bb_log_ptr    = &0304        ; u8: bbox_cull log write pointer (DIAG)
bb_log_base   = &0F00        ; 8 bytes per entry (DIAG)
queue_base    = &030E        ; entries start here
MAX_QUEUE     = 18
QE_SIZE       = 20
QE_TYPE       = 0
QE_TOP_DOM    = 1
QE_BOT_DOM    = 2
QE_LO         = 4
QE_HI         = 6
QE_SX1        = 8
QE_SX2        = 10
QE_YT1        = 12
QE_YT2        = 14
QE_YB1        = 16
QE_YB2        = 18
QET_SOLID     = 0
QET_TIGHTEN   = 1

; ======================================================================
; ENTRY POINT
; ======================================================================
.entry
    ; ── Per-frame init (self-contained, no Python) ──

    ; Clear screen (fast unrolled in bank 2)
    LDA #2 : STA &FE30
    JSR clear_screen
    LDA #0 : STA &FE30

    ; Init spans: 1 full-screen span at spans_base ($20D0)
    LDA #1 : STA spans_base
    LDA #0 : STA spans_base+1
    STA spans_base+SPAN_HDR : STA spans_base+SPAN_HDR+1  ; xlo=0, xhi=0(=256)
    STA spans_base+SPAN_HDR+2 : STA spans_base+SPAN_HDR+3  ; tslope=0
    STA spans_base+SPAN_HDR+4 : STA spans_base+SPAN_HDR+5  ; bslope=0
    STA spans_base+SPAN_HDR+6 : STA spans_base+SPAN_HDR+7  ; tintercept=0
    LDA #159 : STA spans_base+SPAN_HDR+8
    LDA #0   : STA spans_base+SPAN_HDR+9  ; bintercept=159
    STA spans_base+SPAN_HDR+10 : STA spans_base+SPAN_HDR+11  ; inner_top=0
    LDA #159 : STA spans_base+SPAN_HDR+12
    LDA #0   : STA spans_base+SPAN_HDR+13  ; inner_bot=159
    STA spans_base+SPAN_HDR+SP_OUTER_TOP   ; outer_top=0
    LDA #159 : STA spans_base+SPAN_HDR+SP_OUTER_BOT  ; outer_bot=159

    ; Init zp_cspan to point at spans_base (double-buffer current pointer)
    LDA #LO(spans_base) : STA zp_cspan
    LDA #HI(spans_base) : STA zp_cspan+1

    ; Clear vertex cache valid bitmap (64 bytes)
    LDA #0
    LDX #63
.clr_vcv
    STA vcache_valid,X
    DEX
    BPL clr_vcv

    ; Clear VWH cache valid bitmap (160 bytes, 1280 bits)
    LDA #0
    LDX #159
.clr_vwhv
    STA vwh_valid,X
    DEX
    BPL clr_vwhv

    ; Init BSP stack
    STA zp_bsp_sp

    ; (Command buffer init removed — using direct line peripheral)

    ; Init deferred span-op queue (count=0, tail=queue_base)
    LDA #0
    STA queue_count
    LDA #LO(queue_base)
    STA zp_q_tail
    LDA #HI(queue_base)
    STA zp_q_tail+1

    ; Precompute absolute ROM base pointers for nodes/verts/subsectors.
    LDA layout_off_nodes     : STA zp_node_base
    LDA layout_off_nodes+1
    CLC : ADC #HI(rom_window)  : STA zp_node_base+1
    LDA layout_off_verts     : STA zp_vert_base
    LDA layout_off_verts+1
    CLC : ADC #HI(rom_window)  : STA zp_vert_base+1
    LDA layout_off_ss        : STA zp_ss_base
    LDA layout_off_ss+1
    CLC : ADC #HI(rom_window)  : STA zp_ss_base+1
    LDA layout_off_seg_hdr   : STA zp_seg_hdr_base
    LDA layout_off_seg_hdr+1
    CLC : ADC #HI(rom_window)  : STA zp_seg_hdr_base+1

    ; Pre-compute sign extensions of px_int / py_int (used by to_view,
    ; point_on_side and render_seg's back-face test). These are constant
    ; per frame.
    LDA #0 : STA zp_px_int_hi : STA zp_py_int_hi
    LDA zp_px_int
    BPL fe_px_pos
    LDA #&FF : STA zp_px_int_hi
.fe_px_pos
    LDA zp_py_int
    BPL fe_py_pos
    LDA #&FF : STA zp_py_int_hi
.fe_py_pos

    ; Decompose angle into sin/cos
    JSR decompose_angle

    ; Compute fractional rotation
    JSR compute_frac_rotation

    ; BSP traverse from root
    ; root = n_nodes - 1
    LDA layout_n_nodes
    SEC
    SBC #1
    STA zp_tmp0
    LDA layout_n_nodes+1
    SBC #0
    STA zp_tmp0+1
    JSR bsp_traverse

    ; Done — return to caller (loader frame loop or py65 halt)
    RTS

; ======================================================================
; DECOMPOSE ANGLE → sin/cos magnitude, sign, unity flags
; ======================================================================
.decompose_angle
{
    ; _sin_mag_sign(a):
    ;   q = a >> 6, idx = a & 63
    ;   if q & 1: idx = 64 - idx  (mirror for Q1/Q3)
    ;   if idx == 0: return mag=0, unity=false
    ;   neg = (q >= 2)
    ;   if unity[idx]: return mag=0, neg, unity=true
    ;   return mag[idx], neg, unity=false

    ; --- Sin ---
    LDA zp_angle
    PHA                 ; save for neg computation
    LSR A : LSR A : LSR A : LSR A : LSR A : LSR A  ; A = q (0..3)
    LSR A               ; bit 0 → carry (q & 1)
    PLA                 ; restore angle
    PHA                 ; save again
    AND #&3F            ; idx = angle & 63
    BCC sin_no_mirror   ; carry clear → even quadrant → no mirror
    ; Mirror: idx = 64 - idx
    EOR #&FF
    CLC
    ADC #65             ; 64 - idx = -idx + 64 = (~idx + 1) + 64 = ~idx + 65
.sin_no_mirror
    TAX                 ; X = idx (possibly mirrored)
    BEQ sin_zero        ; idx == 0 → mag=0, unity=false

    ; Check unity
    LDA sin_unity_tbl,X
    BNE sin_is_unity    ; unity flag set
    ; Not unity: mag = table[idx]
    LDA sin_mag_tbl,X
    STA zp_sin_mag
    LDA #0
    STA zp_sin_unity
    JMP sin_neg_check
.sin_is_unity
    LDA #0
    STA zp_sin_mag
    LDA #1
    STA zp_sin_unity
    JMP sin_neg_check
.sin_zero
    LDA #0
    STA zp_sin_mag
    STA zp_sin_unity
.sin_neg_check
    ; neg = (q >= 2) = bit 7 of angle
    PLA                 ; restore angle
    ASL A               ; bit 7 → carry
    LDA #0
    ROL A
    STA zp_sin_neg

    ; --- Cos = _sin_mag_sign(angle + 64) ---
    LDA zp_angle
    CLC
    ADC #64             ; cos_angle
    PHA                 ; save
    LSR A : LSR A : LSR A : LSR A : LSR A : LSR A  ; q
    LSR A               ; q & 1 → carry
    PLA
    PHA
    AND #&3F            ; idx
    BCC cos_no_mirror
    EOR #&FF
    CLC
    ADC #65
.cos_no_mirror
    TAX
    BEQ cos_zero
    LDA sin_unity_tbl,X
    BNE cos_is_unity
    LDA sin_mag_tbl,X
    STA zp_cos_mag
    LDA #0
    STA zp_cos_unity
    JMP cos_neg_check
.cos_is_unity
    LDA #0
    STA zp_cos_mag
    LDA #1
    STA zp_cos_unity
    JMP cos_neg_check
.cos_zero
    LDA #0
    STA zp_cos_mag
    STA zp_cos_unity
.cos_neg_check
    PLA
    ASL A
    LDA #0
    ROL A
    STA zp_cos_neg

    RTS
}

; ======================================================================
; COMPUTE FRACTIONAL ROTATION
; frac_vx = frac_rot(-px_lo, sin) - frac_rot(-py_lo, cos)
; frac_vy = frac_rot(-px_lo, cos) + frac_rot(-py_lo, sin)
; ======================================================================
.compute_frac_rotation
{
    ; dx_lo = (-px_lo) & 0xFF = (256 - px_lo) & 0xFF
    LDA #0
    SEC
    SBC zp_px_lo
    STA zp_tmp0         ; dx_lo (unsigned)

    ; dy_lo = (-py_lo) & 0xFF
    LDA #0
    SEC
    SBC zp_py_lo
    STA zp_tmp1         ; dy_lo (unsigned)

    ; frac_rot(lo, mag, neg, unity):
    ;   if unity: val = lo
    ;   elif mag == 0: val = 0
    ;   else: val = umul8x8(lo, mag) >> 7  (1.7 format → 8.8 result)
    ;   if neg: val = -val

    ; --- term0 = frac_rot(dx_lo, sin) ---
    LDA zp_sin_unity
    BNE frs_unity0
    LDA zp_sin_mag
    BEQ frs_zero0
    STA zp_math_b
    LDA zp_tmp0
    JSR umul8x8
    ; result in res_hi:res_lo, round to nearest (add 128, >> 8)
    LDA zp_res_lo
    CLC
    ADC #128
    LDA zp_res_hi
    ADC #0
    STA zp_tmp2         ; lo byte
    LDA #0
    STA zp_tmp2+1       ; hi byte
    JMP frs_sign0
.frs_unity0
    LDA zp_tmp0
    STA zp_tmp2
    LDA #0
    STA zp_tmp2+1
    JMP frs_sign0
.frs_zero0
    LDA #0
    STA zp_tmp2
    STA zp_tmp2+1
.frs_sign0
    LDA zp_sin_neg
    BEQ frs_done0
    ; negate zp_tmp2 (16-bit)
    LDA #0
    SEC
    SBC zp_tmp2
    STA zp_tmp2
    LDA #0
    SBC zp_tmp2+1
    STA zp_tmp2+1
.frs_done0
    ; tmp2 = frac_rot(dx_lo, sin)

    ; --- term1 = frac_rot(dy_lo, cos) ---
    LDA zp_cos_unity
    BNE frs_unity1
    LDA zp_cos_mag
    BEQ frs_zero1
    STA zp_math_b
    LDA zp_tmp1
    JSR umul8x8
    LDA zp_res_lo
    CLC
    ADC #128
    LDA zp_res_hi
    ADC #0
    STA zp_tmp3
    LDA #0
    STA zp_tmp3+1
    JMP frs_sign1
.frs_unity1
    LDA zp_tmp1
    STA zp_tmp3
    LDA #0
    STA zp_tmp3+1
    JMP frs_sign1
.frs_zero1
    LDA #0
    STA zp_tmp3
    STA zp_tmp3+1
.frs_sign1
    LDA zp_cos_neg
    BEQ frs_done1
    LDA #0
    SEC
    SBC zp_tmp3
    STA zp_tmp3
    LDA #0
    SBC zp_tmp3+1
    STA zp_tmp3+1
.frs_done1
    ; tmp3 = frac_rot(dy_lo, cos)

    ; --- term2 = frac_rot(dx_lo, cos) ---
    LDA zp_cos_unity
    BNE frs_unity2
    LDA zp_cos_mag
    BEQ frs_zero2
    STA zp_math_b
    LDA zp_tmp0
    JSR umul8x8
    LDA zp_res_lo
    CLC
    ADC #128
    LDA zp_res_hi
    ADC #0
    STA zp_tmp0         ; lo byte = rounded result
    LDA #0
    STA zp_tmp0+1       ; hi byte = 0 (unsigned magnitude)
    JMP frs_sign2
.frs_unity2
    LDA zp_tmp0
    STA zp_tmp0         ; already there
    LDA #0
    STA zp_tmp0+1
    JMP frs_sign2
.frs_zero2
    LDA #0
    STA zp_tmp0
    STA zp_tmp0+1
.frs_sign2
    LDA zp_cos_neg
    BEQ frs_done2
    LDA #0
    SEC
    SBC zp_tmp0
    STA zp_tmp0
    LDA #0
    SBC zp_tmp0+1
    STA zp_tmp0+1
.frs_done2
    ; tmp0 = frac_rot(dx_lo, cos) (overwritten since dx_lo no longer needed)

    ; --- term3 = frac_rot(dy_lo, sin) ---
    LDA zp_sin_unity
    BNE frs_unity3
    LDA zp_sin_mag
    BEQ frs_zero3
    STA zp_math_b
    LDA zp_tmp1
    JSR umul8x8
    LDA zp_res_lo
    CLC
    ADC #128
    LDA zp_res_hi
    ADC #0
    STA zp_tmp1         ; lo byte = rounded result
    LDA #0
    STA zp_tmp1+1       ; hi byte = 0
    JMP frs_sign3
.frs_unity3
    LDA zp_tmp1
    STA zp_tmp1
    LDA #0
    STA zp_tmp1+1
    JMP frs_sign3
.frs_zero3
    LDA #0
    STA zp_tmp1
    STA zp_tmp1+1
.frs_sign3
    LDA zp_sin_neg
    BEQ frs_done3
    LDA #0
    SEC
    SBC zp_tmp1
    STA zp_tmp1
    LDA #0
    SBC zp_tmp1+1
    STA zp_tmp1+1
.frs_done3
    ; tmp1 = frac_rot(dy_lo, sin)

    ; frac_vx = tmp2 - tmp3  (frac_rot(dx,sin) - frac_rot(dy,cos))
    LDA zp_tmp2
    SEC
    SBC zp_tmp3
    STA zp_frac_vx
    LDA zp_tmp2+1
    SBC zp_tmp3+1
    STA zp_frac_vx+1

    ; frac_vy = tmp0 + tmp1  (frac_rot(dx,cos) + frac_rot(dy,sin))
    LDA zp_tmp0
    CLC
    ADC zp_tmp1
    STA zp_frac_vy
    LDA zp_tmp0+1
    ADC zp_tmp1+1
    STA zp_frac_vy+1

    ; Pre-compute sign extensions for to_view
    LDA #0 : STA zp_frac_vx_ext : STA zp_frac_vy_ext
    LDA zp_frac_vx+1
    BPL cfr_vx_pos
    LDA #&FF : STA zp_frac_vx_ext
.cfr_vx_pos
    LDA zp_frac_vy+1
    BPL cfr_vy_pos
    LDA #&FF : STA zp_frac_vy_ext
.cfr_vy_pos
    RTS
}

; ======================================================================
; BSP TRAVERSE (iterative)
;
; Input: zp_tmp0 = root node ID (u16)
; Uses BSP stack at bsp_stack (3 bytes per entry: nid_lo, nid_hi, side)
; ======================================================================
.bsp_traverse
{
    ; Push root
    LDA zp_tmp0
    STA bsp_stack
    LDA zp_tmp0+1
    STA bsp_stack+1
    LDA #3              ; bsp_sp = 3 (one entry)
    STA zp_bsp_sp

.descend
    ; Peek top of stack: nid = bsp_stack[sp-3], bsp_stack[sp-2]
    LDX zp_bsp_sp
    LDA bsp_stack-3,X   ; nid lo
    STA zp_tmp0
    LDA bsp_stack-2,X   ; nid hi
    STA zp_tmp0+1

    ; Check if subsector (bit 15 set)
    AND #NF_SUBSECTOR
    BNE is_subsector

    ; --- It's a node: compute point_on_side ---
    JSR point_on_side    ; input: zp_tmp0 = nid, returns A = side (0 or 1)
                         ; leaves zp_ptr0 pointing at the node record

    ; Save side in stack entry (A still holds side)
    LDX zp_bsp_sp
    STA bsp_stack-1,X   ; side

    ; Get near child without recomputing node address (ptr0 is still valid)
    LDA bsp_stack-1,X
    JSR get_child_fast
    ; Push near child
    LDX zp_bsp_sp
    LDA zp_tmp1
    STA bsp_stack,X
    LDA zp_tmp1+1
    STA bsp_stack+1,X
    TXA
    CLC
    ADC #3
    STA zp_bsp_sp
    JMP descend

.is_subsector
    ; Pop this entry
    LDA zp_bsp_sp
    SEC
    SBC #3
    STA zp_bsp_sp

    ; ssid = nid & 0x7FFF; if nid == 0xFFFF, ssid = 0
    LDA zp_tmp0+1
    CMP #&FF
    BNE not_ffff
    LDA zp_tmp0
    CMP #&FF
    BNE not_ffff
    ; nid = 0xFFFF → ssid = 0
    LDA #0
    STA zp_tmp0
    STA zp_tmp0+1
    JMP do_render_ss
.not_ffff
    LDA zp_tmp0+1
    AND #&7F            ; clear bit 15
    STA zp_tmp0+1
.do_render_ss
    JSR render_subsector

    ; --- Pop back up, checking far children ---
.pop_check
    LDA zp_bsp_sp
    BEQ done            ; stack empty

    ; Peek: get saved nid and side
    LDX zp_bsp_sp
    LDA bsp_stack-3,X
    STA zp_tmp0          ; nid lo
    LDA bsp_stack-2,X
    STA zp_tmp0+1        ; nid hi
    LDA bsp_stack-1,X
    EOR #1               ; far = side ^ 1
    PHA                  ; save far_side

    ; Pop this entry (we're done with it regardless)
    LDA zp_bsp_sp
    SEC
    SBC #3
    STA zp_bsp_sp

    ; Bbox-projected has_gap cull — native fixed-point bbox visibility.
    ; Input: A = far_side, zp_tmp0 = nid (preserved across call).
    PLA                                 ; far_side from stack
    PHA                                 ; push back for get_child later
    JSR bbox_cull_native
    BCS has_gap_ok
    PLA                  ; discard far_side before looping back
    JMP pop_check
.has_gap_ok
    PLA                  ; far_side
    JSR get_child        ; zp_tmp0 = nid, A = side → zp_tmp1 = child

    ; Push far child and descend
    LDX zp_bsp_sp
    LDA zp_tmp1
    STA bsp_stack,X
    LDA zp_tmp1+1
    STA bsp_stack+1,X
    TXA
    CLC
    ADC #3
    STA zp_bsp_sp
    JMP descend

.done
    RTS
}

; ======================================================================
; GET_CHILD: read child node ID from packed node
; Input: zp_tmp0 = node ID (u16), A = side (0=right, 1=left)
; Output: zp_tmp1 = child ID (u16)
; ======================================================================
.get_child
{
    PHA                  ; save side
    ; Compute node address: rom_window + off_nodes + nid * 16
    ; nid * 16 = nid << 4
    LDA zp_tmp0
    ASL A
    STA zp_ptr0
    LDA zp_tmp0+1
    ROL A
    STA zp_ptr0+1       ; × 2
    ASL zp_ptr0
    ROL zp_ptr0+1       ; × 4
    ASL zp_ptr0
    ROL zp_ptr0+1       ; × 8
    ASL zp_ptr0
    ROL zp_ptr0+1       ; × 16

    ; Add precomputed zp_node_base (= rom_window + off_nodes)
    LDA zp_ptr0
    CLC
    ADC zp_node_base
    STA zp_ptr0
    LDA zp_ptr0+1
    ADC zp_node_base+1
    STA zp_ptr0+1

    PLA                  ; restore side
    ; Fall through into get_child_fast (zp_ptr0 now set)
}

; ======================================================================
; GET_CHILD_FAST: read child from a node whose address is already in zp_ptr0
; Input: zp_ptr0 = node address, A = side (0 or 1)
; Output: zp_tmp1 = child ID
; ======================================================================
.get_child_fast
{
    BEQ read_right
    ; Left child at offset 10
    LDY #ND_CHL
    LDA (zp_ptr0),Y
    STA zp_tmp1
    INY
    LDA (zp_ptr0),Y
    STA zp_tmp1+1
    RTS
.read_right
    LDY #ND_CHR
    LDA (zp_ptr0),Y
    STA zp_tmp1
    INY
    LDA (zp_ptr0),Y
    STA zp_tmp1+1
    RTS
}

; ======================================================================
; POINT_ON_SIDE
; Input: zp_tmp0 = node ID
; Output: A = side (0 or 1)
; Computes: sign of (node_dy * (px - node_x) - node_dx * (py - node_y))
;
; Uses prescaled coordinates.  node_dx/dy and px/py are all prescaled.
; Cross product is 16×16 — need sign only.
; ======================================================================
.point_on_side
{
    ; Compute node address via precomputed zp_node_base (= rom_window + off_nodes)
    LDA zp_tmp0
    ASL A : STA zp_ptr0
    LDA zp_tmp0+1
    ROL A : STA zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1     ; ptr0 = nid * 16
    LDA zp_ptr0
    CLC
    ADC zp_node_base
    STA zp_ptr0
    LDA zp_ptr0+1
    ADC zp_node_base+1
    STA zp_ptr0+1
    ; ptr0 → node record

    ; dx_to_player = zp_wx (raw s16) - node_nx (raw s16)
    ; The packed node now stores RAW nx/ny (s16 relative to map_center)
    ; at ND_PX/ND_PY, so the cross product preserves exact sign regardless
    ; of PRESCALE.
    LDY #ND_PX
    LDA zp_wx
    SEC
    SBC (zp_ptr0),Y
    STA zp_tmp2          ; dx_lo
    LDA zp_wx+1
    INY
    SBC (zp_ptr0),Y
    STA zp_tmp2+1        ; dx_hi

    ; dy_to_player = zp_wy (raw s16) - node_ny (raw s16)
    LDY #ND_PY
    LDA zp_wy
    SEC
    SBC (zp_ptr0),Y
    STA zp_tmp3          ; dy_lo
    LDA zp_wy+1
    INY
    SBC (zp_ptr0),Y
    STA zp_tmp3+1        ; dy_hi

    ; node_dy at ptr0+6 (s16)
    ; node_dx at ptr0+4 (s16)

    ; term_a = node_dy * dx_to_player (s16 × s16 → s32, need sign)
    ; term_b = node_dx * dy_to_player (s16 × s16 → s32, need sign)
    ; result sign = sign of (term_a - term_b)

    ; For a 16×16 multiply we need 4 smul8x8 calls.
    ; But we only need the sign of term_a - term_b.
    ;
    ; Optimisation: check if node_dx or node_dy is zero (axis-aligned).
    LDY #ND_DX
    LDA (zp_ptr0),Y
    INY
    ORA (zp_ptr0),Y
    BNE not_dx_zero
    ; node_dx == 0: result = node_dy * dx, sign depends on node_dy and dx
    ; If node_dx == 0, the cross product simplifies to node_dy * dx_to_player
    LDY #ND_DY
    LDA (zp_ptr0),Y
    INY
    ORA (zp_ptr0),Y
    BEQ return_zero     ; both zero??
    ; sign = sign(node_dy) XOR sign(dx_to_player)
    LDY #ND_DY+1
    LDA (zp_ptr0),Y      ; node_dy_hi
    EOR zp_tmp2+1        ; dx_hi
    BMI return_one        ; different signs → product negative → side 1
    LDA #0
    RTS
.not_dx_zero
    LDY #ND_DY
    LDA (zp_ptr0),Y
    INY
    ORA (zp_ptr0),Y
    BNE full_cross
    ; node_dy == 0: result = -node_dx * dy_to_player
    ; sign = sign(node_dx) XOR sign(dy_to_player), inverted
    LDY #ND_DX+1
    LDA (zp_ptr0),Y
    EOR zp_tmp3+1         ; dy_hi
    BMI return_zero_2     ; different signs → -node_dx * dy negative
    LDA #1
    RTS
.return_zero
.return_zero_2
    LDA #0
    RTS
.return_one
    LDA #1
    RTS

.full_cross
    ; Full 16×16 cross product.  Compute sign of:
    ;   (node_dy * dx_to_player) - (node_dx * dy_to_player)
    ;
    ; Strategy: compute both 32-bit products and subtract.
    ; We only need the sign, so we can stop early if the high bytes differ.
    ;
    ; For now, compute full products using mul16x16_sign.
    ; term_a: node_dy (at ptr0+6) × tmp2 (dx_to_player)
    ; term_b: node_dx (at ptr0+4) × tmp3 (dy_to_player)

    ; IMPORTANT: mul16x16 clobbers zp_tmp3 as an internal temp, so we
    ; must save dy_to_player to scratch BEFORE the first multiply.
    LDA zp_tmp3   : STA &46           ; save dy_to_player lo
    LDA zp_tmp3+1 : STA &47           ; save dy_to_player hi

    ; Load node_dy
    LDY #ND_DY
    LDA (zp_ptr0),Y
    STA zp_tmp0          ; reuse tmp0 for node_dy_lo
    INY
    LDA (zp_ptr0),Y
    STA zp_tmp0+1        ; node_dy_hi

    ; Compute term_a = node_dy × dx_to_player → 32-bit at $70-$73
    JSR mul16x16         ; inputs: tmp0 × tmp2, output: $70-$73

    ; Save term_a
    LDA &70
    PHA
    LDA &71
    PHA
    LDA &72
    PHA
    LDA &73
    PHA

    ; Load node_dx
    LDY #ND_DX
    LDA (zp_ptr0),Y
    STA zp_tmp0
    INY
    LDA (zp_ptr0),Y
    STA zp_tmp0+1

    ; Restore dy_to_player (saved before first mul) into tmp2
    LDA &46 : STA zp_tmp2
    LDA &47 : STA zp_tmp2+1

    ; Compute term_b = node_dx × dy_to_player → 32-bit at $70-$73
    JSR mul16x16

    ; Now subtract: term_a - term_b
    ; term_a is on stack (pushed lo first), term_b in $70-$73
    ; Pop term_a into $74-$77, subtract
    PLA : STA &77        ; term_a byte 3 (high)
    PLA : STA &76
    PLA : STA &75
    PLA : STA &74        ; term_a byte 0 (low)

    LDA &74
    SEC
    SBC &70
    LDA &75
    SBC &71
    LDA &76
    SBC &72
    LDA &77
    SBC &73
    ; A = high byte of (term_a - term_b)
    ; If negative (bit 7 set), result is negative → side = 1
    ; If positive or zero, side = 0
    BMI pos_return_one
    LDA #0
    RTS
.pos_return_one
    LDA #1
    RTS
}

; ======================================================================
; HAS_GAP: Does the x-range [zp_x_lo_clip, zp_x_hi_clip] overlap any
; span with an aperture (inner_top < inner_bot)?
; Input:  zp_x_lo_clip (s16), zp_x_hi_clip (s16)  — read directly
; Output: C=1 if gap found, C=0 otherwise
; Clobbers: A, X, Y, zp_tmp0..zp_tmp3, zp_ptr0
; Mirrors FPClipSpans.has_gap in doom_wireframe.py.
; ======================================================================
.has_gap
{
    ; --- Up-front range rejection ---
    ; If x_hi_clip < 0, the seg is entirely left of screen → no gap.
    LDA zp_x_hi_clip+1
    BMI no_gap
    ; If x_lo_clip > 255, seg is entirely right of screen → no gap.
    LDA zp_x_lo_clip+1
    BMI ilo_zero            ; x_lo_clip < 0 → ilo = 0
    BNE no_gap              ; x_lo_clip > 255
    LDA zp_x_lo_clip
    STA zp_tmp0             ; ilo_u8 in [0, 255]
    JMP clamp_ihi
.ilo_zero
    LDA #0
    STA zp_tmp0

.clamp_ihi
    ; ihi = min(255, x_hi_clip).  x_hi_clip_hi >= 0 (checked above).
    LDA zp_x_hi_clip+1
    BEQ ihi_normal
    LDA #255                ; x_hi_clip > 255 → clamp to 255
    STA zp_tmp1
    JMP loop_init
.ihi_normal
    LDA zp_x_hi_clip
    STA zp_tmp1             ; ihi_u8

.loop_init
    ; ilo_u8 in zp_tmp0, ihi_u8 in zp_tmp1.  Both in [0, 255].
    LDY #0 : LDA (zp_cspan),Y  ; span count from current buffer
    BEQ no_gap
    STA zp_tmp2             ; remaining count
    LDA zp_cspan : CLC : ADC #SPAN_HDR
    STA zp_ptr0
    LDA zp_cspan+1 : ADC #0
    STA zp_ptr0+1

.hg_loop
    ; --- Break if xlo > ihi (both u8) ---
    LDY #SP_XLO
    LDA (zp_ptr0),Y
    CMP zp_tmp1
    BEQ xlo_ok
    BCS hg_break            ; xlo > ihi → break
.xlo_ok

    ; --- Skip if xhi <= ilo (both u8; xhi=0 means 256 and never skips) ---
    LDY #SP_XHI
    LDA (zp_ptr0),Y
    BEQ inner_chk           ; xhi=0=256 > ilo (≤255): always process
    CMP zp_tmp0
    BEQ hg_next             ; xhi == ilo
    BCC hg_next             ; xhi < ilo

.inner_chk
    ; --- inner_top < inner_bot ? (signed s16 compare) ---
    SEC
    LDY #SP_INNER_TOP
    LDA (zp_ptr0),Y
    LDY #SP_INNER_BOT
    SBC (zp_ptr0),Y
    LDY #SP_INNER_TOP+1
    LDA (zp_ptr0),Y
    LDY #SP_INNER_BOT+1
    SBC (zp_ptr0),Y
    BVC hg_nov
    EOR #&80
.hg_nov
    BMI hg_found            ; result negative → inner_top < inner_bot → gap

.hg_next
    LDA zp_ptr0
    CLC
    ADC #SPAN_SIZE
    STA zp_ptr0
    BCC hg_ptr_nocarry
    INC zp_ptr0+1
.hg_ptr_nocarry
    DEC zp_tmp2
    BNE hg_loop

.hg_break
.no_gap
    CLC
    RTS
.hg_found
    SEC
    RTS
}

; ======================================================================
; QUEUE_SOLID: Append a deferred mark_solid op to the queue.
; Input: zp_x_lo_clip (s16), zp_x_hi_clip (s16)  — read directly
; Clobbers: A, Y
; ======================================================================
.queue_solid
{
    ; Write entry at queue_tail
    LDY #QE_TYPE
    LDA #QET_SOLID
    STA (zp_q_tail),Y
    LDY #QE_LO
    LDA zp_x_lo_clip
    STA (zp_q_tail),Y
    INY
    LDA zp_x_lo_clip+1
    STA (zp_q_tail),Y
    LDY #QE_HI
    LDA zp_x_hi_clip
    STA (zp_q_tail),Y
    INY
    LDA zp_x_hi_clip+1
    STA (zp_q_tail),Y

    ; Advance tail by QE_SIZE
    LDA zp_q_tail
    CLC
    ADC #QE_SIZE
    STA zp_q_tail
    BCC qs_nc
    INC zp_q_tail+1
.qs_nc
    INC queue_count
    RTS
}

; ======================================================================
; QUEUE_TIGHTEN: Append a deferred tighten op to the queue.
; Inputs in $A0..$B9 as marshalled by fp_render_seg:
;   zp_hk_lo, zp_hk_hi, zp_hk_sx1, zp_hk_sx2,
;   zp_hk_ft1, zp_hk_ft2, zp_hk_fb1, zp_hk_fb2,
;   zp_hk_need_bt (u8), zp_hk_need_bb (u8),
;   zp_hk_bt1, zp_hk_bt2, zp_hk_bb1, zp_hk_bb2
;
; Derives yt/yb per Python FP:
;   tt1 = bt1 if need_bt else ft1;  yt1 = max(ft1, tt1)
;   tb1 = bb1 if need_bb else fb1;  yb1 = min(fb1, tb1)
; And top_dom = need_bt AND line_survives(sx1, bt1, sx2, bt2),
;     bot_dom = need_bb AND line_survives(sx1, bb1, sx2, bb2)
; against the current span state (before the tighten is applied).
; ======================================================================
; ======================================================================
; QUEUE_TIGHTEN: Append a deferred tighten op to the queue.
; Reads inputs directly from the render_seg ZP slots:
;   zp_x_lo_clip/x_hi_clip, zp_sx1/sx2, zp_ft1/ft2/fb1/fb2,
;   zp_seg_flags (SF_NEEDBT / SF_NEEDBB bits),
;   &84-&87 = bt1/bt2, &90-&93 = bb1/bb2 (filled by project_y_all).
;
; Derives yt/yb per Python FP:
;   tt1 = bt1 if need_bt else ft1;  yt1 = max(ft1, tt1)
;   tb1 = bb1 if need_bb else fb1;  yb1 = min(fb1, tb1)
; And top_dom = need_bt AND line_survives(sx1, bt1, sx2, bt2),
;     bot_dom = need_bb AND line_survives(sx1, bb1, sx2, bb2)
; evaluated against the current span state (pre-tighten).
; ======================================================================
.queue_tighten
{
    ; --- top_dom = need_bt AND line_survives(sx1, bt1, sx2, bt2) ---
    ; (Evaluate line_survives FIRST because it clobbers zp_tmp0..zp_tmp3
    ; which we later use to hold yt/yb.)
    LDA #0 : STA zp_top_dom
    LDA zp_seg_flags
    AND #SF_NEEDBT
    BEQ tl_top_done
    LDA zp_sx1   : STA zp_ls_x1
    LDA zp_sx1+1 : STA zp_ls_x1+1
    LDA &98      : STA zp_ls_y1     ; bt1_lo
    LDA &99      : STA zp_ls_y1+1   ; bt1_hi
    LDA zp_sx2   : STA zp_ls_x2
    LDA zp_sx2+1 : STA zp_ls_x2+1
    LDA &9A      : STA zp_ls_y2     ; bt2_lo
    LDA &9B      : STA zp_ls_y2+1
    JSR line_survives
    BCC tl_top_done
    LDA #1 : STA zp_top_dom
.tl_top_done

    ; --- bot_dom = need_bb AND line_survives(sx1, bb1, sx2, bb2) ---
    LDA #0 : STA zp_bot_dom
    LDA zp_seg_flags
    AND #SF_NEEDBB
    BEQ tl_bot_done
    LDA zp_sx1   : STA zp_ls_x1
    LDA zp_sx1+1 : STA zp_ls_x1+1
    LDA &90      : STA zp_ls_y1     ; bb1_lo
    LDA &91      : STA zp_ls_y1+1
    LDA zp_sx2   : STA zp_ls_x2
    LDA zp_sx2+1 : STA zp_ls_x2+1
    LDA &92      : STA zp_ls_y2     ; bb2_lo
    LDA &93      : STA zp_ls_y2+1
    JSR line_survives
    BCC tl_bot_done
    LDA #1 : STA zp_bot_dom
.tl_bot_done

    ; --- Compute yt1, yt2 ---
    ; If need_bt: yt1 = max(ft1, bt1), yt2 = max(ft2, bt2)
    ; Else:       yt1 = ft1,           yt2 = ft2
    LDA zp_seg_flags
    AND #SF_NEEDBT
    BEQ yt_use_ft
    ; yt1 = max(ft1, bt1): ft1 - bt1 >= 0 ? pick ft1 : pick bt1
    SEC
    LDA zp_ft1 : SBC &98
    LDA zp_ft1+1 : SBC &99
    BVC yt1_nov
    EOR #&80
.yt1_nov
    BMI yt1_pick_bt1
    LDA zp_ft1   : STA zp_tmp0
    LDA zp_ft1+1 : STA zp_tmp0+1
    JMP yt1_done
.yt1_pick_bt1
    LDA &98 : STA zp_tmp0
    LDA &99 : STA zp_tmp0+1
.yt1_done
    ; yt2 = max(ft2, bt2)
    SEC
    LDA zp_ft2 : SBC &9A
    LDA zp_ft2+1 : SBC &9B
    BVC yt2_nov
    EOR #&80
.yt2_nov
    BMI yt2_pick_bt2
    LDA zp_ft2   : STA zp_tmp1
    LDA zp_ft2+1 : STA zp_tmp1+1
    JMP yt_done
.yt2_pick_bt2
    LDA &9A : STA zp_tmp1
    LDA &9B : STA zp_tmp1+1
    JMP yt_done
.yt_use_ft
    LDA zp_ft1   : STA zp_tmp0
    LDA zp_ft1+1 : STA zp_tmp0+1
    LDA zp_ft2   : STA zp_tmp1
    LDA zp_ft2+1 : STA zp_tmp1+1
.yt_done

    ; --- Compute yb1, yb2 ---
    ; If need_bb: yb1 = min(fb1, bb1), yb2 = min(fb2, bb2)
    ; Else:       yb1 = fb1,           yb2 = fb2
    LDA zp_seg_flags
    AND #SF_NEEDBB
    BEQ yb_use_fb
    SEC
    LDA zp_fb1 : SBC &90
    LDA zp_fb1+1 : SBC &91
    BVC yb1_nov
    EOR #&80
.yb1_nov
    BPL yb1_pick_bb1
    LDA zp_fb1   : STA zp_tmp2
    LDA zp_fb1+1 : STA zp_tmp2+1
    JMP yb1_done
.yb1_pick_bb1
    LDA &90 : STA zp_tmp2
    LDA &91 : STA zp_tmp2+1
.yb1_done
    SEC
    LDA zp_fb2 : SBC &92
    LDA zp_fb2+1 : SBC &93
    BVC yb2_nov
    EOR #&80
.yb2_nov
    BPL yb2_pick_bb2
    LDA zp_fb2   : STA zp_tmp3
    LDA zp_fb2+1 : STA zp_tmp3+1
    JMP yb_done
.yb2_pick_bb2
    LDA &92 : STA zp_tmp3
    LDA &93 : STA zp_tmp3+1
    JMP yb_done
.yb_use_fb
    LDA zp_fb1   : STA zp_tmp2
    LDA zp_fb1+1 : STA zp_tmp2+1
    LDA zp_fb2   : STA zp_tmp3
    LDA zp_fb2+1 : STA zp_tmp3+1
.yb_done

    ; --- Write entry at queue_tail ---
    LDY #QE_TYPE
    LDA #QET_TIGHTEN
    STA (zp_q_tail),Y
    LDY #QE_TOP_DOM
    LDA zp_top_dom
    STA (zp_q_tail),Y
    LDY #QE_BOT_DOM
    LDA zp_bot_dom
    STA (zp_q_tail),Y
    LDY #QE_LO
    LDA zp_x_lo_clip   : STA (zp_q_tail),Y
    INY
    LDA zp_x_lo_clip+1 : STA (zp_q_tail),Y
    LDY #QE_HI
    LDA zp_x_hi_clip   : STA (zp_q_tail),Y
    INY
    LDA zp_x_hi_clip+1 : STA (zp_q_tail),Y
    LDY #QE_SX1
    LDA zp_sx1   : STA (zp_q_tail),Y
    INY
    LDA zp_sx1+1 : STA (zp_q_tail),Y
    LDY #QE_SX2
    LDA zp_sx2   : STA (zp_q_tail),Y
    INY
    LDA zp_sx2+1 : STA (zp_q_tail),Y
    ; yt1, yt2 from zp_tmp0, zp_tmp1
    LDY #QE_YT1
    LDA zp_tmp0   : STA (zp_q_tail),Y
    INY
    LDA zp_tmp0+1 : STA (zp_q_tail),Y
    LDY #QE_YT2
    LDA zp_tmp1   : STA (zp_q_tail),Y
    INY
    LDA zp_tmp1+1 : STA (zp_q_tail),Y
    ; yb1, yb2 from zp_tmp2, zp_tmp3
    LDY #QE_YB1
    LDA zp_tmp2   : STA (zp_q_tail),Y
    INY
    LDA zp_tmp2+1 : STA (zp_q_tail),Y
    LDY #QE_YB2
    LDA zp_tmp3   : STA (zp_q_tail),Y
    INY
    LDA zp_tmp3+1 : STA (zp_q_tail),Y

    ; Advance tail by QE_SIZE
    LDA zp_q_tail
    CLC
    ADC #QE_SIZE
    STA zp_q_tail
    BCC qt_nc
    INC zp_q_tail+1
.qt_nc
    INC queue_count
    RTS
}

; ======================================================================
; LINE_SURVIVES: Does a line (x1,y1)-(x2,y2) lie entirely inside the
; inner bbox of every overlapping span?  (Used by queue_tighten to
; decide top/bot dominance.)
;
; Mirrors FPClipSpans.line_survives:
;   if abs(lx1 - lx2) < 1: return False
;   xl, xr = min, max
;   y_lo, y_hi = min, max of ly1, ly2
;   found = False
;   for s in spans:
;       if s[1] <= xl or s[0] >= xr: continue
;       found = True
;       if y_lo < s[4] or y_hi > s[5]: return False
;   return found
;
; Inputs (ZP):
;   zp_ls_x1 (s16), zp_ls_y1 (s16), zp_ls_x2 (s16), zp_ls_y2 (s16)
; Output: C = 1 if line survives, 0 otherwise.
; Clobbers: A, X, Y, zp_tmp0..zp_tmp3, zp_ptr0, zp_ls_count, zp_ls_found, zp_ls_scratch
; ======================================================================
.line_survives
{
    ; --- abs(lx1 - lx2) < 1 → fail (Python: <1 means equal or sub-pixel) ---
    LDA zp_ls_x1
    CMP zp_ls_x2
    BNE ls_dx_ok
    LDA zp_ls_x1+1
    CMP zp_ls_x2+1
    BNE ls_dx_ok
    CLC
    RTS
.ls_dx_ok

    ; --- xl, xr = sorted(lx1, lx2); xl → zp_tmp0, xr → zp_tmp1 ---
    SEC
    LDA zp_ls_x1 : SBC zp_ls_x2
    LDA zp_ls_x1+1 : SBC zp_ls_x2+1
    BVC ls_s_nov
    EOR #&80
.ls_s_nov
    BMI ls_x1_lt
    ; lx1 >= lx2: xl = lx2, xr = lx1
    LDA zp_ls_x2   : STA zp_tmp0
    LDA zp_ls_x2+1 : STA zp_tmp0+1
    LDA zp_ls_x1   : STA zp_tmp1
    LDA zp_ls_x1+1 : STA zp_tmp1+1
    JMP ls_y_sort
.ls_x1_lt
    LDA zp_ls_x1   : STA zp_tmp0
    LDA zp_ls_x1+1 : STA zp_tmp0+1
    LDA zp_ls_x2   : STA zp_tmp1
    LDA zp_ls_x2+1 : STA zp_tmp1+1

.ls_y_sort
    ; --- y_lo, y_hi = min/max(ly1, ly2); y_lo → zp_tmp2, y_hi → zp_tmp3 ---
    SEC
    LDA zp_ls_y1 : SBC zp_ls_y2
    LDA zp_ls_y1+1 : SBC zp_ls_y2+1
    BVC ls_y_nov
    EOR #&80
.ls_y_nov
    BMI ls_y1_lt
    ; ly1 >= ly2: y_lo = ly2, y_hi = ly1
    LDA zp_ls_y2   : STA zp_tmp2
    LDA zp_ls_y2+1 : STA zp_tmp2+1
    LDA zp_ls_y1   : STA zp_tmp3
    LDA zp_ls_y1+1 : STA zp_tmp3+1
    JMP ls_loop_init
.ls_y1_lt
    LDA zp_ls_y1   : STA zp_tmp2
    LDA zp_ls_y1+1 : STA zp_tmp2+1
    LDA zp_ls_y2   : STA zp_tmp3
    LDA zp_ls_y2+1 : STA zp_tmp3+1

.ls_loop_init
    LDY #0 : LDA (zp_cspan),Y  ; span count from current buffer
    BNE ls_have_spans
    JMP ls_no_spans
.ls_have_spans
    STA zp_ls_count
    LDA #0 : STA zp_ls_found
    LDA zp_cspan : CLC : ADC #SPAN_HDR : STA zp_ptr0
    LDA zp_cspan+1 : ADC #0 : STA zp_ptr0+1

.ls_loop
    ; --- Skip if xhi <= xl (s[1] <= xl) ---
    ; xhi is u8, 0 = 256.  xl is s16 in zp_tmp0.
    LDY #SP_XHI
    LDA (zp_ptr0),Y
    BNE ls_xhi_nz
    ; xhi = 256.  256 <= xl iff xl >= 256.
    LDA zp_tmp0+1
    BMI ls_xhi_pass         ; xl negative → 256 > xl, not skip
    BEQ ls_xhi_pass         ; xl in [0,255] → 256 > xl
    JMP ls_next             ; xl >= 256 → skip
.ls_xhi_nz
    ; xhi in [1, 255].  xhi <= xl iff xl >= xhi.
    STA zp_ls_scratch
    LDA zp_tmp0+1
    BMI ls_xhi_pass         ; xl negative → xhi > xl
    BNE ls_next             ; xl >= 256 → xhi <= xl, skip
    LDA zp_ls_scratch
    CMP zp_tmp0             ; xhi vs xl_lo
    BEQ ls_next             ; xhi == xl → skip
    BCC ls_next             ; xhi < xl → skip
.ls_xhi_pass

    ; --- Skip if xlo >= xr (s[0] >= xr) ---
    LDY #SP_XLO
    LDA (zp_ptr0),Y
    STA zp_ls_scratch
    LDA zp_tmp1+1
    BMI ls_next             ; xr negative → xlo >= 0 > xr → skip
    BNE ls_xlo_pass         ; xr >= 256 → xlo <= 255 < xr → not skip
    LDA zp_ls_scratch
    CMP zp_tmp1             ; xlo vs xr_lo
    BCS ls_next             ; xlo >= xr → skip
.ls_xlo_pass

    ; --- Overlapping span: found = True ---
    LDA #1 : STA zp_ls_found

    ; --- y_lo < inner_top ?  → return False ---
    SEC
    LDY #SP_INNER_TOP
    LDA zp_tmp2
    SBC (zp_ptr0),Y
    LDA zp_tmp2+1
    LDY #SP_INNER_TOP+1
    SBC (zp_ptr0),Y
    BVC ls_yl_nov
    EOR #&80
.ls_yl_nov
    BMI ls_fail

    ; --- y_hi > inner_bot ?  → return False ---
    SEC
    LDY #SP_INNER_BOT
    LDA (zp_ptr0),Y
    SBC zp_tmp3
    LDY #SP_INNER_BOT+1
    LDA (zp_ptr0),Y
    SBC zp_tmp3+1
    BVC ls_yh_nov
    EOR #&80
.ls_yh_nov
    BMI ls_fail

.ls_next
    LDA zp_ptr0
    CLC
    ADC #SPAN_SIZE
    STA zp_ptr0
    BCC ls_nc
    INC zp_ptr0+1
.ls_nc
    DEC zp_ls_count
    BNE ls_loop

    ; --- Loop done.  Return found ---
    LDA zp_ls_found
    BEQ ls_no_spans
    SEC
    RTS
.ls_no_spans
    CLC
    RTS
.ls_fail
    CLC
    RTS
}

; ======================================================================
; FP_EVAL: compute slope_s16 * x_u8 >> 8 + intercept_s16 → s16 result
;
; Mirrors Python's fp_eval(fn, x) where fn = (slope, intercept).
;
; Input:  zp_tmp2 = slope (s16), A = x (u8), zp_mk_tmp = intercept (s16)
; Output: $70:$71 = s16 result
; Clobbers: zp_math_b, $70-$72 (s24 temp), A, X, Y
; ======================================================================
.fp_eval
{
    ; Fast path: slope == 0 → result = intercept
    LDX zp_tmp2
    BNE fe_nonzero
    LDX zp_tmp2+1
    BNE fe_nonzero
    LDA zp_mk_tmp   : STA &70
    LDA zp_mk_tmp+1 : STA &71
    RTS
.fe_nonzero
    ; zp_tmp2 = slope (s16) is the multiplier, A = x (u8) is the multiplicand.
    ; mul_s16_u8_s24 expects ex in zp_tmp2 and b in A — exactly our layout.
    JSR mul_s16_u8_s24
    ; s24 product at $70:$72.  Arith shift right 8 = take bytes 1 and 2.
    ; Add intercept to get final s16 in $70:$71.
    CLC
    LDA &71 : ADC zp_mk_tmp   : STA &70
    LDA &72 : ADC zp_mk_tmp+1 : STA &71
    RTS
}

; ======================================================================
; MAKE_SPAN: write a new span record to the slot pointed to by zp_mk_out.
;
; Mirrors Python's FPClipSpans._make_span.  Computes the 4 endpoint
; evaluations of tfn/bfn and stores the new span with its inner bbox.
;
; Input:  zp_mk_xlo (u8), zp_mk_xhi (u8 with 0=256)
;         zp_mk_tslope/tintercept (s16) — tfn
;         zp_mk_bslope/bintercept (s16) — bfn
;         zp_mk_out (u16) — pointer to the 16-byte output slot
; Precondition: xlo < xhi (caller checks).
; Output: span written to (zp_mk_out).  zp_mk_out UNCHANGED.
; Clobbers: A, X, Y, zp_tmp2, zp_math_b, zp_mk_tmp, $70-$72,
;           zp_mk_top_l/top_r/bot_l/bot_r.
; ======================================================================
.make_span
{
    ; --- top_l = fp_eval(tfn, xlo) ---
    LDA zp_mk_tslope    : STA zp_tmp2
    LDA zp_mk_tslope+1  : STA zp_tmp2+1
    LDA zp_mk_tintercept    : STA zp_mk_tmp
    LDA zp_mk_tintercept+1  : STA zp_mk_tmp+1
    LDA zp_mk_xlo
    JSR fp_eval
    LDA &70 : STA zp_mk_top_l
    LDA &71 : STA zp_mk_top_l+1

    ; --- top_r = fp_eval(tfn, xhi - 1) ---
    ; xhi may be 0 (=256), so xhi - 1 = 255 in that case.
    LDA zp_mk_xhi
    BNE ms_topr_norm
    LDA #255
    JMP ms_topr_do
.ms_topr_norm
    SEC
    SBC #1
.ms_topr_do
    ; slope/intercept for tfn still in place
    JSR fp_eval
    LDA &70 : STA zp_mk_top_r
    LDA &71 : STA zp_mk_top_r+1

    ; --- bot_l = fp_eval(bfn, xlo) ---
    LDA zp_mk_bslope    : STA zp_tmp2
    LDA zp_mk_bslope+1  : STA zp_tmp2+1
    LDA zp_mk_bintercept    : STA zp_mk_tmp
    LDA zp_mk_bintercept+1  : STA zp_mk_tmp+1
    LDA zp_mk_xlo
    JSR fp_eval
    LDA &70 : STA zp_mk_bot_l
    LDA &71 : STA zp_mk_bot_l+1

    ; --- bot_r = fp_eval(bfn, xhi - 1) ---
    LDA zp_mk_xhi
    BNE ms_botr_norm
    LDA #255
    JMP ms_botr_do
.ms_botr_norm
    SEC
    SBC #1
.ms_botr_do
    JSR fp_eval
    LDA &70 : STA zp_mk_bot_r
    LDA &71 : STA zp_mk_bot_r+1

    ; --- inner_top = max(top_l, top_r) ---
    ; Signed compare zp_mk_top_l vs zp_mk_top_r.
    SEC
    LDA zp_mk_top_l   : SBC zp_mk_top_r
    LDA zp_mk_top_l+1 : SBC zp_mk_top_r+1
    BVC ms_it_nov
    EOR #&80
.ms_it_nov
    BMI ms_it_r       ; top_l < top_r → use top_r
    ; top_l >= top_r → inner_top = top_l
    LDA zp_mk_top_l   : STA &70
    LDA zp_mk_top_l+1 : STA &71
    JMP ms_it_done
.ms_it_r
    LDA zp_mk_top_r   : STA &70
    LDA zp_mk_top_r+1 : STA &71
.ms_it_done
    ; --- inner_bot = min(bot_l, bot_r) ---
    SEC
    LDA zp_mk_bot_l   : SBC zp_mk_bot_r
    LDA zp_mk_bot_l+1 : SBC zp_mk_bot_r+1
    BVC ms_ib_nov
    EOR #&80
.ms_ib_nov
    BPL ms_ib_r       ; bot_l >= bot_r → use bot_r
    ; bot_l < bot_r → inner_bot = bot_l
    LDA zp_mk_bot_l   : STA &72
    LDA zp_mk_bot_l+1 : STA &73
    JMP ms_ib_done
.ms_ib_r
    LDA zp_mk_bot_r   : STA &72
    LDA zp_mk_bot_r+1 : STA &73
.ms_ib_done
    ; Now $70:$71 = inner_top, $72:$73 = inner_bot.

    ; --- Write span record to (zp_mk_out) ---
    LDY #SP_XLO
    LDA zp_mk_xlo : STA (zp_mk_out),Y
    LDY #SP_XHI
    LDA zp_mk_xhi : STA (zp_mk_out),Y

    LDY #SP_TSLOPE
    LDA zp_mk_tslope   : STA (zp_mk_out),Y : INY
    LDA zp_mk_tslope+1 : STA (zp_mk_out),Y
    LDY #SP_BSLOPE
    LDA zp_mk_bslope   : STA (zp_mk_out),Y : INY
    LDA zp_mk_bslope+1 : STA (zp_mk_out),Y

    LDY #SP_TINTERCEPT
    LDA zp_mk_tintercept   : STA (zp_mk_out),Y : INY
    LDA zp_mk_tintercept+1 : STA (zp_mk_out),Y
    LDY #SP_BINTERCEPT
    LDA zp_mk_bintercept   : STA (zp_mk_out),Y : INY
    LDA zp_mk_bintercept+1 : STA (zp_mk_out),Y

    LDY #SP_INNER_TOP
    LDA &70 : STA (zp_mk_out),Y : INY
    LDA &71 : STA (zp_mk_out),Y
    LDY #SP_INNER_BOT
    LDA &72 : STA (zp_mk_out),Y : INY
    LDA &73 : STA (zp_mk_out),Y

    ; --- outer_top = min(top_l, top_r), clamped to [0, 159] as u8 ---
    ; (Already have inner_top = max in $70:$71)
    ; outer_top = top_l + top_r - inner_top (since min + max = a + b)
    ; But simpler: compare top_l vs top_r, take the smaller.
    SEC
    LDA zp_mk_top_l   : SBC zp_mk_top_r
    LDA zp_mk_top_l+1 : SBC zp_mk_top_r+1
    BVC ms_ot_nov
    EOR #&80
.ms_ot_nov
    BPL ms_ot_r       ; top_l >= top_r → outer = top_r
    ; top_l < top_r → outer = top_l
    LDA zp_mk_top_l   : STA &74
    LDA zp_mk_top_l+1 : STA &75
    JMP ms_ot_clamp
.ms_ot_r
    LDA zp_mk_top_r   : STA &74
    LDA zp_mk_top_r+1 : STA &75
.ms_ot_clamp
    ; Clamp s16 in $74:$75 to u8 [0, 159]
    LDA &75
    BMI ms_ot_zero     ; negative → 0
    BNE ms_ot_159      ; >= 256 → 159
    LDA &74
    CMP #160
    BCC ms_ot_store
    LDA #159
    JMP ms_ot_store
.ms_ot_zero
    LDA #0
    JMP ms_ot_store
.ms_ot_159
    LDA #159
.ms_ot_store
    LDY #SP_OUTER_TOP
    STA (zp_mk_out),Y

    ; --- outer_bot = max(bot_l, bot_r), clamped to [0, 159] as u8 ---
    SEC
    LDA zp_mk_bot_l   : SBC zp_mk_bot_r
    LDA zp_mk_bot_l+1 : SBC zp_mk_bot_r+1
    BVC ms_ob_nov
    EOR #&80
.ms_ob_nov
    BMI ms_ob_r       ; bot_l < bot_r → outer = bot_r
    ; bot_l >= bot_r → outer = bot_l
    LDA zp_mk_bot_l   : STA &74
    LDA zp_mk_bot_l+1 : STA &75
    JMP ms_ob_clamp
.ms_ob_r
    LDA zp_mk_bot_r   : STA &74
    LDA zp_mk_bot_r+1 : STA &75
.ms_ob_clamp
    ; Clamp s16 in $74:$75 to u8 [0, 159]
    LDA &75
    BMI ms_ob_zero     ; negative → 0
    BNE ms_ob_159      ; >= 256 → 159
    LDA &74
    CMP #160
    BCC ms_ob_store
    LDA #159
    JMP ms_ob_store
.ms_ob_zero
    LDA #0
    JMP ms_ob_store
.ms_ob_159
    LDA #159
.ms_ob_store
    LDY #SP_OUTER_BOT
    STA (zp_mk_out),Y

    RTS
}

; ======================================================================
; FP_DIV8: signed (num << 8) / den with truncation toward zero.
;
; Mirrors Python's fp_div8.  Both num and den are s16; result is s16.
; For our use (slope computation), |num| is bounded by screen Y range
; (< 256) so |num << 8| fits in u16.  If |num| > 255 we'd overflow;
; current callers don't trigger this case.
;
; Input:  zp_tmp0 = num (s16), zp_tmp2 = den (s16)
; Output: $70:$71 = s16 result (0 if den == 0)
; Clobbers: A, X, Y, zp_div_num/den/rem/sign, $70:$71
; ======================================================================
.fp_div8
{
    ; Check den == 0 → return 0
    LDA zp_tmp2
    ORA zp_tmp2+1
    BNE fd_den_nonzero
    LDA #0
    STA &70
    STA &71
    RTS
.fd_den_nonzero

    ; Compute sign_neg = (num_neg XOR den_neg)
    LDA zp_tmp0+1
    EOR zp_tmp2+1
    AND #&80
    STA zp_div_sign

    ; |num| << 8 → u24 dividend: byte0 = 0, byte1 = |num|_lo, byte2 = |num|_hi
    ; Use $0F (unused) and zp_div_num (2 bytes) for the 3 bytes.
    ; Actually: zp_div_num is 2 bytes.  Add zp_div_num+2 at $0A... wait
    ; zp_div_den starts at $0A.  Let me use zp_tmp3 (free during fp_div8) for byte2.
    LDA zp_tmp0+1
    BPL fd_num_pos
    SEC
    LDA #0 : SBC zp_tmp0   : STA zp_div_num+1    ; byte1 = |num|_lo
    LDA #0 : SBC zp_tmp0+1 : STA zp_tmp3         ; byte2 = |num|_hi
    JMP fd_num_done
.fd_num_pos
    LDA zp_tmp0   : STA zp_div_num+1
    LDA zp_tmp0+1 : STA zp_tmp3
.fd_num_done
    LDA #0
    STA zp_div_num                                 ; byte0 = 0

    ; |den| → zp_div_den
    LDA zp_tmp2+1
    BPL fd_den_pos
    SEC
    LDA #0 : SBC zp_tmp2   : STA zp_div_den
    LDA #0 : SBC zp_tmp2+1 : STA zp_div_den+1
    JMP fd_div
.fd_den_pos
    LDA zp_tmp2   : STA zp_div_den
    LDA zp_tmp2+1 : STA zp_div_den+1

.fd_div
    ; Unsigned 24-bit dividend / 16-bit divisor → u24 quotient (low 16 bits kept).
    ; Dividend bytes: zp_div_num (byte0), zp_div_num+1 (byte1), zp_tmp3 (byte2).
    ; 24 shifts.  Result quotient low 16 bits will be in zp_div_num+1, zp_tmp3
    ; after the shifts.  But we actually want low 16 bits — we care about
    ; byte0:byte1 (bottom 16 bits of the 24-bit quotient).
    ; After 24 shifts, the original bits are gone and the dividend-byte slots
    ; hold the 24-bit quotient: byte0=quot[0..7], byte1=quot[8..15], byte2=quot[16..23].
    ; Fast path: if |num| < 256 (byte2=0), pre-shift and do 16 iters.
    ; byte0 ($08) is already 0 from fd_num_done.
    LDY zp_tmp3
    BNE fd_full
    LDA zp_div_num+1       ; byte1 = |num_lo|
    STA zp_tmp3            ; byte2 = |num_lo| (pre-shifted)
    STY zp_div_num+1       ; byte1 = 0 (Y=0)
    STY zp_div_rem         ; rem_lo = 0
    STY zp_div_rem+1       ; rem_hi = 0
    LDX #16 : BNE fd_loop
.fd_full
    LDA #0
    STA zp_div_rem
    STA zp_div_rem+1
    LDX #24
.fd_loop
    ASL zp_div_num
    ROL zp_div_num+1
    ROL zp_tmp3
    ROL zp_div_rem
    ROL zp_div_rem+1
    LDA zp_div_rem
    SEC
    SBC zp_div_den
    TAY
    LDA zp_div_rem+1
    SBC zp_div_den+1
    BCC fd_no_commit
    STA zp_div_rem+1
    STY zp_div_rem
    INC zp_div_num                  ; set bit 0 of quotient
.fd_no_commit
    DEX
    BNE fd_loop

    ; Check for 24-bit quotient overflow (byte2 nonzero → |result| > 65535).
    ; Clamp to max-magnitude s16 to ensure correct reject in Cyrus-Beck.
    LDA zp_tmp3
    BEQ fd_result_fits
    LDA zp_div_sign
    BNE fd_ovf_neg
    LDA #&FF : STA &70
    LDA #&7F : STA &71       ; +32767
    RTS
.fd_ovf_neg
    LDA #&01 : STA &70
    LDA #&80 : STA &71       ; -32767
    RTS
.fd_result_fits

    ; Low 16 bits of quotient are in zp_div_num:zp_div_num+1.
    ; Apply sign.
    LDA zp_div_sign
    BEQ fd_result_pos
    SEC
    LDA #0 : SBC zp_div_num   : STA &70
    LDA #0 : SBC zp_div_num+1 : STA &71
    RTS
.fd_result_pos
    LDA zp_div_num   : STA &70
    LDA zp_div_num+1 : STA &71
    RTS
}

; ======================================================================
; FP_LINFN: compute slope_s16 + intercept_s16 from two points.
;
; Mirrors Python's fp_linfn(y1, y2, sx1, sx2):
;   dx = sx2 - sx1
;   if abs(dx) < 1: return (0, (y1 + y2) / 2)
;   dy = y2 - y1
;   slope_8 = fp_div8(dy, dx)
;   if slope_8 == 0: return (0, y1)
;   if abs(sx1) <= abs(sx2):
;       intercept = y1 - fp_mul8(slope_8, sx1)
;   else:
;       intercept = y2 - fp_mul8(slope_8, sx2)
;   return (slope_8, intercept)
;
; Input:  $60 = y1 (s16), $62 = y2 (s16), $64 = sx1 (s16), $66 = sx2 (s16)
; Output: $68 = slope (s16), $6A = intercept (s16)
; Clobbers: A, X, Y, zp_tmp0, zp_tmp2, zp_div_*, zp_mk_tmp, $70:$72
; ======================================================================
.fp_linfn
{
    ; dx = sx2 - sx1 → zp_tmp2 (for fp_div8 as divisor)
    SEC
    LDA &66 : SBC &64 : STA zp_tmp2
    LDA &67 : SBC &65 : STA zp_tmp2+1

    ; Check abs(dx) < 1 → dx == 0 (since integer).  If so, slope=0, intercept=(y1+y2)/2.
    LDA zp_tmp2
    ORA zp_tmp2+1
    BNE fl_dx_ok
    ; Degenerate: slope=0, intercept=(y1+y2)/2 with arithmetic shift right
    LDA #0 : STA &68 : STA &69
    CLC
    LDA &60 : ADC &62 : STA &6A
    LDA &61 : ADC &63 : STA &6B
    ; Arithmetic shift right by 1
    LDA &6B
    CMP #&80        ; C=1 if bit7 set (negative)
    ROR &6B
    ROR &6A
    RTS
.fl_dx_ok

    ; dy = y2 - y1 → zp_tmp0 (for fp_div8 as dividend)
    SEC
    LDA &62 : SBC &60 : STA zp_tmp0
    LDA &63 : SBC &61 : STA zp_tmp0+1

    ; slope_8 = fp_div8(dy, dx)
    JSR fp_div8             ; $70:$71 = slope
    LDA &70 : STA &68
    LDA &71 : STA &69

    ; If slope_8 == 0, return (0, y1)
    LDA &68
    ORA &69
    BNE fl_compute_intercept
    LDA &60 : STA &6A
    LDA &61 : STA &6B
    RTS

.fl_compute_intercept
    ; Decide which endpoint: abs(sx1) <= abs(sx2) ? use sx1, y1 : use sx2, y2
    ; Compute absolute values as u16 in scratch, compare.
    LDA &64
    STA zp_tmp0
    LDA &65
    STA zp_tmp0+1
    BPL fl_s1_pos
    SEC
    LDA #0 : SBC zp_tmp0   : STA zp_tmp0
    LDA #0 : SBC zp_tmp0+1 : STA zp_tmp0+1
.fl_s1_pos                 ; zp_tmp0 = |sx1| (u16)

    LDA &66
    STA zp_tmp2
    LDA &67
    STA zp_tmp2+1
    BPL fl_s2_pos
    SEC
    LDA #0 : SBC zp_tmp2   : STA zp_tmp2
    LDA #0 : SBC zp_tmp2+1 : STA zp_tmp2+1
.fl_s2_pos                 ; zp_tmp2 = |sx2| (u16)

    ; |sx1| vs |sx2| unsigned 16-bit compare (standard CMP/SBC pattern)
    LDA zp_tmp0   : CMP zp_tmp2
    LDA zp_tmp0+1 : SBC zp_tmp2+1
    BCS fl_use_sx2          ; |sx1| >= |sx2| → use sx2 (closer to origin)
    ; fall through: |sx1| < |sx2| → use sx1

.fl_use_sx1
    ; intercept = y1 - ((slope × sx1) >> 8)
    LDA &68 : STA zp_tmp0
    LDA &69 : STA zp_tmp0+1
    LDA &64 : STA zp_tmp2
    LDA &65 : STA zp_tmp2+1
    JSR fl_mul8_bysx
    SEC
    LDA &60 : SBC &70 : STA &6A
    LDA &61 : SBC &71 : STA &6B
    RTS

.fl_use_sx2
    LDA &68 : STA zp_tmp0
    LDA &69 : STA zp_tmp0+1
    LDA &66 : STA zp_tmp2
    LDA &67 : STA zp_tmp2+1
    JSR fl_mul8_bysx
    SEC
    LDA &62 : SBC &70 : STA &6A
    LDA &63 : SBC &71 : STA &6B
    RTS
}

; ======================================================================
; FL_MUL8_BYSX: compute (slope × sx) >> 8 as s16.
;
; Uses mul16x16 for full s16 × s16 → s32, then takes bytes 1..2 as s16.
;
; Input:  zp_tmp0 = slope (s16), zp_tmp2 = sx (s16)
; Output: $70:$71 = s16 result
; ======================================================================
.fl_mul8_bysx
{
    JSR mul16x16
    LDA &71 : STA &70
    LDA &72 : STA &71
    RTS
}

; ======================================================================
; PW_EVAL_F_AT_A: fp_eval(f, A) → $70:$71.
; Inputs: A = x (u8), zp_pw_f_slope/intercept
; Output: $70:$71 = result
; ======================================================================
.pw_eval_f_at_a
{
    PHA
    LDA zp_pw_f_slope     : STA zp_tmp2
    LDA zp_pw_f_slope+1   : STA zp_tmp2+1
    LDA zp_pw_f_intercept : STA zp_mk_tmp
    LDA zp_pw_f_intercept+1 : STA zp_mk_tmp+1
    PLA
    JMP fp_eval
}
.pw_eval_g_at_a
{
    PHA
    LDA zp_pw_g_slope     : STA zp_tmp2
    LDA zp_pw_g_slope+1   : STA zp_tmp2+1
    LDA zp_pw_g_intercept : STA zp_mk_tmp
    LDA zp_pw_g_intercept+1 : STA zp_mk_tmp+1
    PLA
    JMP fp_eval
}

; ======================================================================
; PW_MAX: piecewise max of f vs g over [x0, x1).
;
; Mirrors Python's _fp_pw_max.  Output is 1 or 2 sub-ranges.
;
; Input:  zp_pw_f_slope/intercept, zp_pw_g_slope/intercept,
;         zp_pw_x0, zp_pw_x1 (s16; must have x0 < x1, both in [0, 256])
; Output: zp_pw_count (1 or 2)
;         zp_pw_r0_fn (0=f, 1=g) — range 0 is [x0, cx_or_x1)
;         zp_pw_r1_fn — range 1 is [cx, x1)  (only if count==2)
;         zp_pw_cx (s16) — only valid if count==2
; Clobbers: many
; ======================================================================
.pw_max
{
    ; fv0 = fp_eval(f, x0) — save to zp_pw_d0 temporarily
    LDA zp_pw_x0
    JSR pw_eval_f_at_a
    LDA &70 : STA zp_pw_d0
    LDA &71 : STA zp_pw_d0+1

    ; gv0 = fp_eval(g, x0)
    LDA zp_pw_x0
    JSR pw_eval_g_at_a
    ; d0 = fv0 - gv0
    SEC
    LDA zp_pw_d0   : SBC &70 : STA zp_pw_d0
    LDA zp_pw_d0+1 : SBC &71 : STA zp_pw_d0+1

    ; fv1 = fp_eval(f, x1 - 1) — assume x1 >= 1 so x1-1 ≥ 0
    LDA zp_pw_x1
    SEC
    SBC #1
    PHA                              ; save x1-1 for reuse
    JSR pw_eval_f_at_a
    LDA &70 : STA zp_pw_d1
    LDA &71 : STA zp_pw_d1+1

    ; gv1 = fp_eval(g, x1-1)
    PLA
    JSR pw_eval_g_at_a
    SEC
    LDA zp_pw_d1   : SBC &70 : STA zp_pw_d1
    LDA zp_pw_d1+1 : SBC &71 : STA zp_pw_d1+1

    ; Trivial check: d0 >= 0 AND d1 >= 0 → all f (pick f)
    LDA zp_pw_d0+1 : BMI pm_not_all_f
    LDA zp_pw_d1+1 : BMI pm_not_all_f
    ; Both >= 0 → range = [x0, x1), fn = f
    LDA #1 : STA zp_pw_count
    LDA #0 : STA zp_pw_r0_fn
    RTS
.pm_not_all_f
    ; d0 <= 0 AND d1 <= 0 → all g?
    LDA zp_pw_d0+1
    BMI pm_d0_neg
    BNE pm_not_all_g            ; d0 > 0 → not all g
    LDA zp_pw_d0
    BNE pm_not_all_g            ; d0 > 0 → not all g
.pm_d0_neg                      ; d0 <= 0
    LDA zp_pw_d1+1
    BMI pm_all_g                ; d1 < 0 → all g
    BNE pm_not_all_g            ; d1 > 0 → crossover
    LDA zp_pw_d1
    BNE pm_not_all_g
.pm_all_g
    LDA #1 : STA zp_pw_count
    LDA #1 : STA zp_pw_r0_fn
    RTS
.pm_not_all_g

    ; Crossover case — full computation (mirrors Python _fp_pw_max crossover).
    ; fvx1 = fp_eval(f, x1), gvx1 = fp_eval(g, x1)
    LDA zp_pw_x1
    JSR pw_eval_f_at_a
    LDA &70 : STA zp_tg_tx0      ; stash fvx1 lo
    LDA &71 : STA zp_tg_tx0+1
    LDA zp_pw_x1
    JSR pw_eval_g_at_a
    ; dx1 = fvx1 - gvx1
    SEC
    LDA zp_tg_tx0   : SBC &70 : STA zp_tg_tx0
    LDA zp_tg_tx0+1 : SBC &71 : STA zp_tg_tx0+1
    ; denom = d0 - dx1
    SEC
    LDA zp_pw_d0   : SBC zp_tg_tx0   : STA zp_tg_tx1
    LDA zp_pw_d0+1 : SBC zp_tg_tx0+1 : STA zp_tg_tx1+1
    ; abs(denom) < 1 → degenerate
    LDA zp_tg_tx1 : ORA zp_tg_tx1+1
    BNE pm_denom_ok
    LDA zp_pw_d0+1 : BMI pm_pick_g : BNE pm_pick_f
    LDA zp_pw_d0   : BNE pm_pick_f
.pm_pick_g
    LDA #1 : STA zp_pw_count : LDA #1 : STA zp_pw_r0_fn : RTS
.pm_pick_f
    LDA #1 : STA zp_pw_count : LDA #0 : STA zp_pw_r0_fn : RTS
.pm_denom_ok
    ; |d0| → zp_tmp0, sign into zp_div_sign
    LDA zp_pw_d0+1
    BPL pm_d0_pos
    SEC : LDA #0 : SBC zp_pw_d0 : STA zp_tmp0
    LDA #0 : SBC zp_pw_d0+1 : STA zp_tmp0+1
    LDA #&80 : STA zp_div_sign : JMP pm_d0_abs_done
.pm_d0_pos
    LDA zp_pw_d0 : STA zp_tmp0 : LDA zp_pw_d0+1 : STA zp_tmp0+1
    LDA #0 : STA zp_div_sign
.pm_d0_abs_done
    ; span = x1 - x0 (u8)
    SEC : LDA zp_pw_x1 : SBC zp_pw_x0 : STA zp_math_b
    ; |d0| → zp_tmp2 for mul_s16_u8_s24
    LDA zp_tmp0 : STA zp_tmp2 : LDA zp_tmp0+1 : STA zp_tmp2+1
    LDA zp_math_b
    JSR mul_s16_u8_s24
    ; Full s24/s16 divide: product($70:$72) / denom(zp_tg_tx1)
    ; zp_div_sign has sign of |d0|; XOR with sign of denom
    LDA zp_div_sign : EOR zp_tg_tx1+1 : AND #&80 : STA zp_div_sign
    ; Set up dividend bytes: byte0=$70, byte1=$71, byte2=$72 (all unsigned)
    LDA &70 : STA zp_div_num
    LDA &71 : STA zp_div_num+1
    LDA &72 : STA zp_tmp3
    ; |denom| → zp_div_den
    LDA zp_tg_tx1+1 : BPL pm_da_pos
    SEC : LDA #0 : SBC zp_tg_tx1 : STA zp_div_den
    LDA #0 : SBC zp_tg_tx1+1 : STA zp_div_den+1 : JMP pm_da_done
.pm_da_pos
    LDA zp_tg_tx1 : STA zp_div_den : LDA zp_tg_tx1+1 : STA zp_div_den+1
.pm_da_done
    ; 24/16 unsigned divide (same loop as fp_div8)
    LDA #0 : STA zp_div_rem : STA zp_div_rem+1
    LDX #24
.pm_div_loop
    ASL zp_div_num : ROL zp_div_num+1 : ROL zp_tmp3
    ROL zp_div_rem : ROL zp_div_rem+1
    LDA zp_div_rem : SEC : SBC zp_div_den : TAY
    LDA zp_div_rem+1 : SBC zp_div_den+1
    BCC pm_div_skip
    STA zp_div_rem+1 : STY zp_div_rem : INC zp_div_num
.pm_div_skip
    DEX : BNE pm_div_loop
    ; Apply sign to quotient (low 16 bits in zp_div_num)
    ; Floor division: if negative and remainder != 0, increment abs quotient
    LDA zp_div_sign : BEQ pm_quot_pos
    LDA zp_div_rem : ORA zp_div_rem+1 : BEQ pm_no_floor
    INC zp_div_num : BNE pm_no_floor : INC zp_div_num+1
.pm_no_floor
    SEC : LDA #0 : SBC zp_div_num : STA zp_div_num
    LDA #0 : SBC zp_div_num+1 : STA zp_div_num+1
.pm_quot_pos
    ; cx = x0 + quotient
    CLC : LDA zp_pw_x0 : ADC zp_div_num : STA zp_pw_cx
    LDA zp_pw_x0+1 : ADC zp_div_num+1 : STA zp_pw_cx+1
    ; Clamp: cx = max(x0+1, min(x1-1, cx))
    SEC : LDA zp_pw_cx : SBC zp_pw_x0 : LDA zp_pw_cx+1 : SBC zp_pw_x0+1
    BVC pm_cmp1_nov : EOR #&80
.pm_cmp1_nov
    BMI pm_cx_low
    BNE pm_cmp1_ok
    LDA zp_pw_cx : SEC : SBC zp_pw_x0 : CMP #1 : BCS pm_cmp1_ok
.pm_cx_low
    CLC : LDA zp_pw_x0 : ADC #1 : STA zp_pw_cx
    LDA zp_pw_x0+1 : ADC #0 : STA zp_pw_cx+1
.pm_cmp1_ok
    SEC : LDA zp_pw_x1 : SBC #1 : STA zp_tg_tx0
    LDA zp_pw_x1+1 : SBC #0 : STA zp_tg_tx0+1
    SEC : LDA zp_pw_cx : SBC zp_tg_tx0 : LDA zp_pw_cx+1 : SBC zp_tg_tx0+1
    BVC pm_cmp2_nov : EOR #&80
.pm_cmp2_nov
    BMI pm_cmp2_ok
    BNE pm_cx_high
    LDA zp_pw_cx : CMP zp_tg_tx0 : BEQ pm_cmp2_ok
.pm_cx_high
    LDA zp_tg_tx0 : STA zp_pw_cx : LDA zp_tg_tx0+1 : STA zp_pw_cx+1
.pm_cmp2_ok
    ; Refinement: if f(cx) >= g(cx): cx += 1  (pw_max uses >=)
    LDA zp_pw_cx : JSR pw_eval_f_at_a
    LDA &70 : STA zp_tg_tx0 : LDA &71 : STA zp_tg_tx0+1
    LDA zp_pw_cx : JSR pw_eval_g_at_a
    SEC : LDA zp_tg_tx0 : SBC &70 : STA zp_ls_scratch
    LDA zp_tg_tx0+1 : SBC &71
    BVC pm_ref_nov : EOR #&80
.pm_ref_nov
    BMI pm_fv_lt_gv             ; f < g → no increment
    ; f >= g (check equality too)
    LDA zp_tg_tx0 : CMP &70 : BNE pm_fv_ge_gv
    LDA zp_tg_tx0+1 : CMP &71 : BNE pm_fv_ge_gv
.pm_fv_ge_gv                    ; f >= g → increment cx
    INC zp_pw_cx : BNE pm_inc_nc : INC zp_pw_cx+1
.pm_inc_nc
    ; Check cx >= x1 → single range with f
    SEC : LDA zp_pw_cx : SBC zp_pw_x1 : LDA zp_pw_cx+1 : SBC zp_pw_x1+1
    BVC pm_inc_nov : EOR #&80
.pm_inc_nov
    BMI pm_ref_done
    LDA #1 : STA zp_pw_count : LDA #0 : STA zp_pw_r0_fn : RTS
.pm_fv_lt_gv
    ; Check cx <= x0 → single range with g
    SEC : LDA zp_pw_cx : SBC zp_pw_x0 : LDA zp_pw_cx+1 : SBC zp_pw_x0+1
    BVC pm_gt_nov : EOR #&80
.pm_gt_nov
    BPL pm_ref_done
    LDA #1 : STA zp_pw_count : LDA #1 : STA zp_pw_r0_fn : RTS
.pm_ref_done
    ; count = 2, split based on d0 sign
    LDA #2 : STA zp_pw_count
    ; pw_max: d0 > 0 → [x0,cx) f, [cx,x1) g
    LDA zp_pw_d0+1 : BPL pm_d0_positive
    ; d0 < 0 → [x0,cx) g, [cx,x1) f
    LDA #1 : STA zp_pw_r0_fn : LDA #0 : STA zp_pw_r1_fn : RTS
.pm_d0_positive
    LDA #0 : STA zp_pw_r0_fn : LDA #1 : STA zp_pw_r1_fn : RTS
}

; ======================================================================
; PW_MIN: piecewise min of f vs g over [x0, x1).
; Mirror of pw_max with signs flipped.
; ======================================================================
.pw_min
{
    LDA zp_pw_x0
    JSR pw_eval_f_at_a
    LDA &70 : STA zp_pw_d0
    LDA &71 : STA zp_pw_d0+1
    LDA zp_pw_x0
    JSR pw_eval_g_at_a
    SEC
    LDA zp_pw_d0   : SBC &70 : STA zp_pw_d0
    LDA zp_pw_d0+1 : SBC &71 : STA zp_pw_d0+1

    LDA zp_pw_x1 : SEC : SBC #1
    PHA
    JSR pw_eval_f_at_a
    LDA &70 : STA zp_pw_d1
    LDA &71 : STA zp_pw_d1+1
    PLA
    JSR pw_eval_g_at_a
    SEC
    LDA zp_pw_d1   : SBC &70 : STA zp_pw_d1
    LDA zp_pw_d1+1 : SBC &71 : STA zp_pw_d1+1

    ; d0 <= 0 AND d1 <= 0 → all f (pick smaller)
    LDA zp_pw_d0+1
    BMI pn_d0_neg
    BNE pn_not_all_f           ; d0 > 0 → not all f
    LDA zp_pw_d0
    BNE pn_not_all_f
.pn_d0_neg
    LDA zp_pw_d1+1
    BMI pn_all_f
    BNE pn_not_all_f
    LDA zp_pw_d1
    BNE pn_not_all_f
.pn_all_f
    LDA #1 : STA zp_pw_count
    LDA #0 : STA zp_pw_r0_fn
    RTS
.pn_not_all_f

    ; d0 >= 0 AND d1 >= 0 → all g
    LDA zp_pw_d0+1 : BMI pn_not_all_g
    LDA zp_pw_d1+1 : BMI pn_not_all_g
    LDA #1 : STA zp_pw_count
    LDA #1 : STA zp_pw_r0_fn
    RTS
.pn_not_all_g

    ; Crossover — use fp_div8 to compute cx exactly (pw_min hits this
    ; path in E1M1 traversal, so we must implement it).
    ;
    ; fvx1 = fp_eval(f, x1), gvx1 = fp_eval(g, x1)
    LDA zp_pw_x1
    JSR pw_eval_f_at_a
    LDA &70 : STA zp_tg_tx0      ; stash fvx1 lo (reuse tg scratch as temps)
    LDA &71 : STA zp_tg_tx0+1
    LDA zp_pw_x1
    JSR pw_eval_g_at_a
    ; dx1 = fvx1 - gvx1
    SEC
    LDA zp_tg_tx0   : SBC &70 : STA zp_tg_tx0
    LDA zp_tg_tx0+1 : SBC &71 : STA zp_tg_tx0+1

    ; denom = d0 - dx1
    SEC
    LDA zp_pw_d0   : SBC zp_tg_tx0
    STA zp_tg_tx1                ; denom lo
    LDA zp_pw_d0+1 : SBC zp_tg_tx0+1
    STA zp_tg_tx1+1              ; denom hi

    ; abs(denom) < 1 → degenerate; pick f if d0 <= 0 else g
    LDA zp_tg_tx1
    ORA zp_tg_tx1+1
    BNE pn_denom_ok
    ; denom == 0 → degenerate
    LDA zp_pw_d0+1
    BMI pn_deg_f
    BNE pn_deg_g
    LDA zp_pw_d0
    BEQ pn_deg_f
.pn_deg_g
    LDA #1 : STA zp_pw_count
    LDA #1 : STA zp_pw_r0_fn
    RTS
.pn_deg_f
    LDA #1 : STA zp_pw_count
    LDA #0 : STA zp_pw_r0_fn
    RTS

.pn_denom_ok
    ; span = x1 - x0 (u8, since x1 > x0)
    ; cx = x0 + (d0 * span) / denom
    ;
    ; d0 * span: d0 is s16 (difference of fp_eval results), span is u8.
    ;   Use mul_s16_u8_s24 with d0 as ex, span as b.
    ;   Result is s24 = d0 × span.
    ; Then we need to divide that s24 by denom (s16).  We don't have
    ; s24/s16 directly.  Shortcut: since |d0 × span| typically fits in
    ; s16, compute (d0 * span) as s16 (truncating), then use fp_div8.
    ; Wait — Python does integer divide so precision matters.
    ;
    ; For our use (2 crossover cases in testing), we can compute the
    ; full s24 and do a manual s24/s16 divide.  Simpler shortcut: assume
    ; |d0 × span| ≤ s16 and do 16-bit divide.

    ; Compute |d0| into zp_div_num and sign
    LDA zp_pw_d0+1
    BPL pn_d0_pos
    SEC
    LDA #0 : SBC zp_pw_d0   : STA zp_tmp0
    LDA #0 : SBC zp_pw_d0+1 : STA zp_tmp0+1
    LDA #&80 : STA zp_div_sign
    JMP pn_d0_abs_done
.pn_d0_pos
    LDA zp_pw_d0   : STA zp_tmp0
    LDA zp_pw_d0+1 : STA zp_tmp0+1
    LDA #0 : STA zp_div_sign
.pn_d0_abs_done

    ; span = x1 - x0 (u8)
    SEC
    LDA zp_pw_x1 : SBC zp_pw_x0
    ; A = span
    STA zp_math_b                ; for mul_s16_u8_s24: b = span

    ; zp_tmp0 = |d0|, A (= zp_math_b) = span
    ; Note zp_tmp0 overlaps with the mul_s16_u8_s24's ex (zp_tmp2).
    ; We want ex = |d0| in zp_tmp2. Copy.
    LDA zp_tmp0   : STA zp_tmp2
    LDA zp_tmp0+1 : STA zp_tmp2+1
    LDA zp_math_b             ; reload A for the A-conventions
    JSR mul_s16_u8_s24        ; $70:$72 = |d0| × span (u24, always positive)

    ; Full s24/s16 divide: product($70:$72) / denom(zp_tg_tx1)
    ; zp_div_sign has sign of |d0|; XOR with sign of denom
    LDA zp_div_sign : EOR zp_tg_tx1+1 : AND #&80 : STA zp_div_sign
    ; Set up dividend bytes
    LDA &70 : STA zp_div_num
    LDA &71 : STA zp_div_num+1
    LDA &72 : STA zp_tmp3
    ; |denom| → zp_div_den
    LDA zp_tg_tx1+1 : BPL pn_den_abs_pos
    SEC : LDA #0 : SBC zp_tg_tx1 : STA zp_div_den
    LDA #0 : SBC zp_tg_tx1+1 : STA zp_div_den+1 : JMP pn_den_abs_done
.pn_den_abs_pos
    LDA zp_tg_tx1 : STA zp_div_den : LDA zp_tg_tx1+1 : STA zp_div_den+1
.pn_den_abs_done
    ; 24/16 unsigned divide
    LDA #0 : STA zp_div_rem : STA zp_div_rem+1
    LDX #24
.pn_div_loop
    ASL zp_div_num : ROL zp_div_num+1 : ROL zp_tmp3
    ROL zp_div_rem : ROL zp_div_rem+1
    LDA zp_div_rem : SEC : SBC zp_div_den : TAY
    LDA zp_div_rem+1 : SBC zp_div_den+1
    BCC pn_div_skip
    STA zp_div_rem+1 : STY zp_div_rem : INC zp_div_num
.pn_div_skip
    DEX : BNE pn_div_loop
    ; Apply sign to quotient (low 16 bits in zp_div_num)
    ; Floor division: if negative and remainder != 0, increment abs quotient
    LDA zp_div_sign : BEQ pn_quot_pos
    LDA zp_div_rem : ORA zp_div_rem+1 : BEQ pn_no_floor
    INC zp_div_num : BNE pn_no_floor : INC zp_div_num+1
.pn_no_floor
    SEC : LDA #0 : SBC zp_div_num : STA zp_div_num
    LDA #0 : SBC zp_div_num+1 : STA zp_div_num+1
.pn_quot_pos

    ; cx = x0 + quotient
    CLC
    LDA zp_pw_x0   : ADC zp_div_num   : STA zp_pw_cx
    LDA zp_pw_x0+1 : ADC zp_div_num+1 : STA zp_pw_cx+1

    ; Clamp: cx = max(x0 + 1, min(x1 - 1, cx))
    ; If cx < x0 + 1: cx = x0 + 1
    SEC
    LDA zp_pw_cx   : SBC zp_pw_x0
    LDA zp_pw_cx+1 : SBC zp_pw_x0+1
    BVC pn_cmp1_nov
    EOR #&80
.pn_cmp1_nov
    BMI pn_cx_set_low               ; cx < x0 → cx < x0+1 → clamp
    BNE pn_cmp1_gt                  ; cx - x0 > 0 ... check if ≥ 1
    LDA zp_pw_cx
    SEC : SBC zp_pw_x0
    CMP #1
    BCS pn_cmp1_ok                  ; cx - x0 ≥ 1 → OK
.pn_cx_set_low
    CLC
    LDA zp_pw_x0   : ADC #1 : STA zp_pw_cx
    LDA zp_pw_x0+1 : ADC #0 : STA zp_pw_cx+1
    JMP pn_cmp1_ok
.pn_cmp1_gt
.pn_cmp1_ok

    ; If cx > x1 - 1: cx = x1 - 1
    SEC
    LDA zp_pw_x1   : SBC #1         ; x1 - 1 in temp compare
    STA zp_tg_tx0                    ; reuse temp
    LDA zp_pw_x1+1 : SBC #0
    STA zp_tg_tx0+1
    SEC
    LDA zp_pw_cx   : SBC zp_tg_tx0
    LDA zp_pw_cx+1 : SBC zp_tg_tx0+1
    BVC pn_cmp2_nov
    EOR #&80
.pn_cmp2_nov
    BMI pn_cmp2_ok                  ; cx < x1-1 → OK
    BNE pn_cx_set_high              ; cx > x1-1 → clamp
    LDA zp_pw_cx
    CMP zp_tg_tx0
    BEQ pn_cmp2_ok                  ; equal → OK
.pn_cx_set_high
    LDA zp_tg_tx0   : STA zp_pw_cx
    LDA zp_tg_tx0+1 : STA zp_pw_cx+1
.pn_cmp2_ok

    ; Python refinement: if fp_eval(f, cx) <= fp_eval(g, cx): cx += 1
    ; (Bit-exact with Python.)
    LDA zp_pw_cx
    JSR pw_eval_f_at_a
    LDA &70 : STA zp_tg_tx0        ; fv_cx lo
    LDA &71 : STA zp_tg_tx0+1      ; fv_cx hi
    LDA zp_pw_cx
    JSR pw_eval_g_at_a             ; gv_cx in &70/&71
    ; diff = fv_cx - gv_cx (signed s16)
    SEC
    LDA zp_tg_tx0   : SBC &70 : STA zp_ls_scratch   ; save diff_lo
    LDA zp_tg_tx0+1 : SBC &71                       ; A = diff_hi
    BVC pn_ref_nov
    EOR #&80
.pn_ref_nov
    BMI pn_fv_le_gv                 ; diff < 0 → f < g → increment
    ; diff >= 0.  Check for equality: diff_hi == 0 AND diff_lo == 0.
    ; The original (unEORed) diff_hi is still in A after EOR only if V was set;
    ; if V was clear, A is the real diff_hi.  The Z-test here needs A==0 AND
    ; diff_lo==0.  After EOR, diff_hi==0 only if original diff_hi was 0x80
    ; (can't happen for small values) — but we saved diff_lo so re-compute.
    LDA zp_tg_tx0   : CMP &70 : BNE pn_fv_gt_gv
    LDA zp_tg_tx0+1 : CMP &71 : BNE pn_fv_gt_gv
    ; Exactly equal → f <= g → increment
.pn_fv_le_gv                        ; (fallthrough from pn_fv_lt_gv branch)
    INC zp_pw_cx
    BNE pn_inc_nc
    INC zp_pw_cx+1
.pn_inc_nc
    ; Check cx >= x1 → degenerate single range with f
    SEC
    LDA zp_pw_cx   : SBC zp_pw_x1
    LDA zp_pw_cx+1 : SBC zp_pw_x1+1
    BVC pn_inc_nov
    EOR #&80
.pn_inc_nov
    BMI pn_ref_done                 ; cx < x1, OK
    ; cx >= x1: return single range with f
    LDA #1 : STA zp_pw_count
    LDA #0 : STA zp_pw_r0_fn
    RTS

.pn_fv_gt_gv
    ; Need to check cx <= x0 → degenerate single g range
    SEC
    LDA zp_pw_cx   : SBC zp_pw_x0
    LDA zp_pw_cx+1 : SBC zp_pw_x0+1
    BVC pn_gt_nov
    EOR #&80
.pn_gt_nov
    BPL pn_ref_done                 ; cx > x0 → OK (but we want > not >=)
    ; cx <= x0: return single range with g
    LDA #1 : STA zp_pw_count
    LDA #1 : STA zp_pw_r0_fn
    RTS

.pn_ref_done
    ; count = 2
    LDA #2 : STA zp_pw_count
    ; d0 < 0 → [x0, cx) f, [cx, x1) g.  Python: "if d0 < 0:".
    LDA zp_pw_d0+1
    BMI pn_d0_is_neg
    ; d0 >= 0 → [x0, cx) g, [cx, x1) f
    LDA #1 : STA zp_pw_r0_fn
    LDA #0 : STA zp_pw_r1_fn
    RTS
.pn_d0_is_neg
    LDA #0 : STA zp_pw_r0_fn
    LDA #1 : STA zp_pw_r1_fn
    RTS
}

; ======================================================================
; Helper: advance zp_mk_out by SPAN_SIZE.  Called after writing a span.
; ======================================================================
.mk_out_advance
{
    LDA zp_mk_out
    CLC
    ADC #SPAN_SIZE
    STA zp_mk_out
    BCC mka_done
    INC zp_mk_out+1
.mka_done
    RTS
}

; ======================================================================
; Helper: increment the dest buffer's span count (self-modifying).
; The INC address is patched by setup_dest_buffer.
; ======================================================================
.inc_dest_count
    INC &FFFF             ; address patched at runtime (inc_dest_count+1)
    RTS

; ======================================================================
; SETUP_DEST_BUFFER: shared init for mark_solid / tighten.
; Computes dest=other buffer via EOR on zp_cspan, patches inc_dest_count,
; zeros dest count, sets zp_mk_out, reads source span count, sets zp_ms_src.
; Output: A = source span count (or 0 if empty), Z flag set accordingly.
; ======================================================================
.setup_dest_buffer
{
    ; Compute dest lo via EOR, patch INC and zero-store addresses
    LDA zp_cspan   : EOR #(LO(spans_base) EOR LO(scratch_spans))
    STA inc_dest_count + 1
    STA sdb_zero+1
    CLC : ADC #SPAN_HDR : STA zp_mk_out
    ; Compute dest hi via EOR
    LDA zp_cspan+1 : EOR #(HI(spans_base) EOR HI(scratch_spans))
    STA inc_dest_count + 2
    STA sdb_zero+2
    ADC #0 : STA zp_mk_out+1
    ; Zero the dest count
    LDA #0
.sdb_zero
    STA &FFFF
    ; Read source span count and set up src pointer
    LDY #0 : LDA (zp_cspan),Y : PHA
    LDA zp_cspan : CLC : ADC #SPAN_HDR : STA zp_ms_src
    LDA zp_cspan+1 : ADC #0 : STA zp_ms_src+1
    PLA                     ; restore count to A, sets Z flag
    RTS
}

; ======================================================================
; SWAP_CSPAN: swap zp_cspan between spans_base and scratch_spans.
; Called at the end of mark_solid / tighten via JMP (tail call).
; ======================================================================
.swap_cspan
    LDA zp_cspan   : EOR #(LO(spans_base) EOR LO(scratch_spans)) : STA zp_cspan
    LDA zp_cspan+1 : EOR #(HI(spans_base) EOR HI(scratch_spans)) : STA zp_cspan+1
    RTS

; ======================================================================
; Helper: copy a source span from (zp_ms_src) to (zp_mk_out) unchanged,
; advance zp_mk_out by SPAN_SIZE, and increment dest span count.
; ======================================================================
.ms_copy_unchanged
{
    LDY #SPAN_SIZE - 1
.msc_loop
    LDA (zp_ms_src),Y
    STA (zp_mk_out),Y
    DEY
    BPL msc_loop
    JSR inc_dest_count
    JMP mk_out_advance
}

; ======================================================================
; Helper: load source span's tfn/bfn into zp_mk_t/bslope/intercept.
; Reads from (zp_ms_src) offsets SP_TSLOPE..SP_BINTERCEPT (8 bytes).
; ======================================================================
.ms_load_src_fns
{
    LDY #SP_TSLOPE
    LDA (zp_ms_src),Y : STA zp_mk_tslope     : INY
    LDA (zp_ms_src),Y : STA zp_mk_tslope+1   : INY
    LDA (zp_ms_src),Y : STA zp_mk_bslope     : INY
    LDA (zp_ms_src),Y : STA zp_mk_bslope+1   : INY
    LDA (zp_ms_src),Y : STA zp_mk_tintercept : INY
    LDA (zp_ms_src),Y : STA zp_mk_tintercept+1 : INY
    LDA (zp_ms_src),Y : STA zp_mk_bintercept : INY
    LDA (zp_ms_src),Y : STA zp_mk_bintercept+1
    RTS
}

; ======================================================================
; Helper: load current source span's xlo/xhi as s16 into zp_ms_xlo16 /
; zp_ms_xhi16 (with xhi=0 converted to 256).
; ======================================================================
.ms_load_xlo_xhi
{
    LDY #SP_XLO
    LDA (zp_ms_src),Y
    STA zp_ms_xlo16
    LDA #0
    STA zp_ms_xlo16+1       ; xlo is u8 [0,255]
    LDY #SP_XHI
    LDA (zp_ms_src),Y
    BNE mslxh_nonzero
    LDA #0                  ; xhi = 0 means 256
    STA zp_ms_xhi16
    LDA #1
    STA zp_ms_xhi16+1
    RTS
.mslxh_nonzero
    STA zp_ms_xhi16
    LDA #0
    STA zp_ms_xhi16+1
    RTS
}

; ======================================================================
; Helper: advance zp_ms_src by SPAN_SIZE, decrement zp_ms_count, carry
; flag set if we should exit the loop (count reached 0).
; ======================================================================
.ms_next_src
{
    LDA zp_ms_src
    CLC
    ADC #SPAN_SIZE
    STA zp_ms_src
    BCC msns_no_carry
    INC zp_ms_src+1
.msns_no_carry
    DEC zp_ms_count
    BEQ msns_done      ; count hit 0 → exit
    CLC
    RTS
.msns_done
    SEC
    RTS
}

; ======================================================================
; MARK_SOLID: remove [ilo, ihi) from spans, splitting affected spans.
;
; Mirrors Python's FPClipSpans.mark_solid.  Uses double-buffered spans:
; reads from zp_cspan (current), writes to other buffer, then swaps.
;
; Input:  zp_ms_lo, zp_ms_hi (s16).  ilo = max(0, lo), ihi = min(256, hi+1).
; Output: zp_cspan swapped to point at the new span list.
; ======================================================================
.mark_solid
{
    ; --- Clamp ilo, ihi ---
    ; ilo = max(0, lo)
    LDA zp_ms_lo+1
    BPL ms_ilo_keep
    LDA #0 : STA zp_ms_ilo : STA zp_ms_ilo+1
    JMP ms_clamp_ihi
.ms_ilo_keep
    LDA zp_ms_lo   : STA zp_ms_ilo
    LDA zp_ms_lo+1 : STA zp_ms_ilo+1
.ms_clamp_ihi
    ; ihi = min(256, hi + 1)
    LDA zp_ms_hi
    CLC
    ADC #1
    STA zp_ms_ihi
    LDA zp_ms_hi+1
    ADC #0
    STA zp_ms_ihi+1
    ; Clamp to 256: if ihi > 256, ihi = 256; if ihi < 0, ihi = 0
    LDA zp_ms_ihi+1
    BMI ms_ihi_neg
    BEQ ms_ihi_lo_check
    ; ihi_hi > 0 → ihi > 255 → clamp to 256
    LDA #0   : STA zp_ms_ihi
    LDA #1   : STA zp_ms_ihi+1
    JMP ms_clamp_done
.ms_ihi_lo_check
    ; ihi_hi = 0, ihi = ihi_lo + 0.  No clamp needed (unless ihi_lo > 256 which
    ; can't happen with hi_hi=0).  OK.
    JMP ms_clamp_done
.ms_ihi_neg
    LDA #0 : STA zp_ms_ihi : STA zp_ms_ihi+1
.ms_clamp_done

    ; If ilo >= ihi, nothing to do.  Signed compare.
    SEC
    LDA zp_ms_ilo   : SBC zp_ms_ihi
    LDA zp_ms_ilo+1 : SBC zp_ms_ihi+1
    BVC ms_dge_nov
    EOR #&80
.ms_dge_nov
    BMI ms_work                    ; ilo < ihi → do work
    RTS                             ; ilo >= ihi → no-op

.ms_work
    JSR setup_dest_buffer
    BNE ms_have_spans
    JMP ms_finish                   ; empty input → empty output
.ms_have_spans
    STA zp_ms_count

.ms_loop
    JSR ms_load_xlo_xhi             ; zp_ms_xlo16, zp_ms_xhi16

    ; --- Case 1: xhi <= ilo → unchanged ---
    ; Compute diff = xhi - ilo; branch on diff <= 0 (signed).
    SEC
    LDA zp_ms_xhi16   : SBC zp_ms_ilo   : STA zp_tmp0
    LDA zp_ms_xhi16+1 : SBC zp_ms_ilo+1
    BVC ms_c1_nov
    EOR #&80
.ms_c1_nov
    BMI ms_unchanged                ; diff < 0 → unchanged
    BNE ms_c1_check_ihi             ; diff hi nonzero → diff > 0 → case 2
    LDA zp_tmp0
    BNE ms_c1_check_ihi             ; diff lo nonzero → diff > 0 → case 2
    JMP ms_unchanged                ; diff == 0 → xhi == ilo → unchanged
.ms_c1_check_ihi

    ; --- Case 2: xlo >= ihi → unchanged ---
    SEC
    LDA zp_ms_xlo16   : SBC zp_ms_ihi   : STA zp_tmp0
    LDA zp_ms_xlo16+1 : SBC zp_ms_ihi+1
    BVC ms_c2_nov
    EOR #&80
.ms_c2_nov
    BMI ms_split                    ; diff < 0 → xlo < ihi → split
    BNE ms_unchanged                ; diff hi nonzero → diff > 0 → unchanged
    LDA zp_tmp0
    BNE ms_unchanged                ; diff lo nonzero → diff > 0 → unchanged
    JMP ms_unchanged                ; diff == 0 → xlo == ihi → unchanged
.ms_unchanged
    JSR ms_copy_unchanged
    JMP ms_next

.ms_split
    ; --- Case 3: split span ---
    ; Load source fns once
    JSR ms_load_src_fns

    ; Left fragment: if xlo < ilo, make_span(xlo, ilo, src fns)
    SEC
    LDA zp_ms_xlo16   : SBC zp_ms_ilo
    LDA zp_ms_xlo16+1 : SBC zp_ms_ilo+1
    BVC ms_lf_nov
    EOR #&80
.ms_lf_nov
    BPL ms_lf_skip                  ; xlo >= ilo, no left fragment
    ; xlo < ilo → left fragment
    LDA zp_ms_xlo16
    STA zp_mk_xlo
    LDA zp_ms_ilo                   ; ilo fits in u8 (we asserted so)
    STA zp_mk_xhi
    JSR make_span
    JSR mk_out_advance
    JSR inc_dest_count
.ms_lf_skip

    ; Right fragment: if ihi < xhi, make_span(ihi, xhi, src fns)
    SEC
    LDA zp_ms_ihi   : SBC zp_ms_xhi16
    LDA zp_ms_ihi+1 : SBC zp_ms_xhi16+1
    BVC ms_rf_nov
    EOR #&80
.ms_rf_nov
    BPL ms_rf_skip                  ; ihi >= xhi, no right fragment
    ; ihi < xhi → right fragment
    LDA zp_ms_ihi                   ; ihi fits in u8 OR ihi = 256 (encoded as 0)
    STA zp_mk_xlo                   ; xlo for new span = ihi
    ; ihi = 256 case: ihi_lo = 0, ihi_hi = 1. Encoded as xlo = 0? No — new span's xlo
    ; would be 256 which we can't encode.  But if ihi = 256, then ihi < xhi is only
    ; true if xhi > 256, impossible. So we never hit this case with ihi = 256.
    LDY #SP_XHI                     ; source xhi (u8 with 0=256)
    LDA (zp_ms_src),Y
    STA zp_mk_xhi
    JSR make_span
    JSR mk_out_advance
    JSR inc_dest_count
.ms_rf_skip

    JMP ms_next

.ms_next
    JSR ms_next_src
    BCS ms_finish
    JMP ms_loop

.ms_finish
    JMP swap_cspan
}

; ======================================================================
; TIGHTEN: apply a tighten op to the span array.
;
; Mirrors Python's FPClipSpans.tighten (general-case only; the
; top_dom/bot_dom merge fast path is disabled in Python to match).
;
; Input:  zp_ms_lo/hi (s16), plus sx1/sx2/yt1/yt2/yb1/yb2 in scratch slots
;         loaded from the queue entry by the caller:
;           &A0:s16 sx1, &A2:s16 sx2
;           &60:s16 yt1, &62:s16 yt2   (fp_linfn input y1, y2)
;           &64:s16 sx1, &66:s16 sx2   (fp_linfn input sx1, sx2)
; Actually we'll set up inputs to fp_linfn directly from the queue entry.
; Callers (flush) pass via tg_ scratch slots; see flush for details.
; ======================================================================
.tighten
{
    ; --- Clamp ilo, ihi (reuses mark_solid logic) ---
    LDA zp_ms_lo+1
    BPL tg_ilo_keep
    LDA #0 : STA zp_ms_ilo : STA zp_ms_ilo+1
    JMP tg_clamp_ihi
.tg_ilo_keep
    LDA zp_ms_lo   : STA zp_ms_ilo
    LDA zp_ms_lo+1 : STA zp_ms_ilo+1
.tg_clamp_ihi
    LDA zp_ms_hi
    CLC
    ADC #1
    STA zp_ms_ihi
    LDA zp_ms_hi+1
    ADC #0
    STA zp_ms_ihi+1
    LDA zp_ms_ihi+1
    BMI tg_ihi_neg
    BEQ tg_ihi_done
    LDA #0 : STA zp_ms_ihi
    LDA #1 : STA zp_ms_ihi+1
    JMP tg_ihi_done
.tg_ihi_neg
    LDA #0 : STA zp_ms_ihi : STA zp_ms_ihi+1
.tg_ihi_done

    ; If ilo >= ihi, nothing to do
    SEC
    LDA zp_ms_ilo   : SBC zp_ms_ihi
    LDA zp_ms_ilo+1 : SBC zp_ms_ihi+1
    BVC tg_ige_nov
    EOR #&80
.tg_ige_nov
    BMI tg_do_work
    RTS
.tg_do_work

    ; --- Compute new_tfn via fp_linfn(yt1, yt2, sx1, sx2) ---
    ; fp_linfn expects: $60=y1, $62=y2, $64=sx1, $66=sx2; writes $68=slope $6A=intercept
    ; Caller has preloaded these slots via the queue read.
    JSR fp_linfn
    LDA &68 : STA zp_tg_new_tslope
    LDA &69 : STA zp_tg_new_tslope+1
    LDA &6A : STA zp_tg_new_tintercept
    LDA &6B : STA zp_tg_new_tintercept+1

    ; --- Compute new_bfn via fp_linfn(yb1, yb2, sx1, sx2) ---
    ; Caller must swap y1/y2 at $60/$62 to yb1/yb2 before this call.
    ; We do it here — yb1/yb2 are loaded to $A4/$A6 as alt scratch.
    LDA zp_tg_ox0   : STA &60      ; yb1 (caller stashed in ox0 slot)
    LDA zp_tg_ox0+1 : STA &61
    LDA zp_tg_ox1   : STA &62      ; yb2 (caller stashed in ox1 slot)
    LDA zp_tg_ox1+1 : STA &63
    ; sx1/sx2 still at $64/$66 from before
    JSR fp_linfn
    LDA &68 : STA zp_tg_new_bslope
    LDA &69 : STA zp_tg_new_bslope+1
    LDA &6A : STA zp_tg_new_bintercept
    LDA &6B : STA zp_tg_new_bintercept+1

    ; --- Init dest output (other buffer via EOR) ---
    JSR setup_dest_buffer
    BNE tg_have_spans
    JMP tg_finish
.tg_have_spans
    STA zp_ms_count

.tg_loop
    JSR ms_load_xlo_xhi

    ; Case 1/2 checks: entirely outside [ilo, ihi) → unchanged
    SEC
    LDA zp_ms_xhi16   : SBC zp_ms_ilo   : STA zp_tmp0
    LDA zp_ms_xhi16+1 : SBC zp_ms_ilo+1
    BVC tg_c1_nov
    EOR #&80
.tg_c1_nov
    BMI tg_unchanged                 ; xhi < ilo
    BNE tg_c1_chk2
    LDA zp_tmp0
    BNE tg_c1_chk2
    JMP tg_unchanged                 ; xhi == ilo
.tg_c1_chk2
    SEC
    LDA zp_ms_xlo16   : SBC zp_ms_ihi   : STA zp_tmp0
    LDA zp_ms_xlo16+1 : SBC zp_ms_ihi+1
    BVC tg_c2_nov
    EOR #&80
.tg_c2_nov
    BMI tg_split                     ; xlo < ihi → split
    BNE tg_unchanged                 ; xlo > ihi → unchanged
    LDA zp_tmp0
    BNE tg_unchanged
    JMP tg_unchanged                 ; xlo == ihi → unchanged (Python: xlo >= ihi)

.tg_unchanged
    JSR ms_copy_unchanged
    JMP tg_next

.tg_split
    ; Load src fns into BOTH zp_mk_* AND zp_tg_src_* (latter for right fragment)
    JSR ms_load_src_fns
    LDA zp_mk_tslope     : STA zp_tg_src_tslope
    LDA zp_mk_tslope+1   : STA zp_tg_src_tslope+1
    LDA zp_mk_tintercept : STA zp_tg_src_tintercept
    LDA zp_mk_tintercept+1 : STA zp_tg_src_tintercept+1
    LDA zp_mk_bslope     : STA zp_tg_src_bslope
    LDA zp_mk_bslope+1   : STA zp_tg_src_bslope+1
    LDA zp_mk_bintercept : STA zp_tg_src_bintercept
    LDA zp_mk_bintercept+1 : STA zp_tg_src_bintercept+1

    ; Left fragment: if xlo < ilo
    SEC
    LDA zp_ms_xlo16   : SBC zp_ms_ilo
    LDA zp_ms_xlo16+1 : SBC zp_ms_ilo+1
    BVC tg_lf_nov
    EOR #&80
.tg_lf_nov
    BPL tg_lf_skip
    ; xlo < ilo → make left fragment
    LDA zp_ms_xlo16 : STA zp_mk_xlo
    LDA zp_ms_ilo   : STA zp_mk_xhi
    JSR make_span
    JSR mk_out_advance
    JSR inc_dest_count
.tg_lf_skip

    ; ox0 = max(xlo, ilo)
    ; Since we're in split path, xlo < ihi and xhi > ilo, so overlap exists.
    SEC
    LDA zp_ms_xlo16   : SBC zp_ms_ilo
    LDA zp_ms_xlo16+1 : SBC zp_ms_ilo+1
    BVC tg_ox0_nov
    EOR #&80
.tg_ox0_nov
    BPL tg_ox0_xlo
    ; xlo < ilo → ox0 = ilo
    LDA zp_ms_ilo   : STA zp_tg_ox0
    LDA zp_ms_ilo+1 : STA zp_tg_ox0+1
    JMP tg_ox0_done
.tg_ox0_xlo
    LDA zp_ms_xlo16   : STA zp_tg_ox0
    LDA zp_ms_xlo16+1 : STA zp_tg_ox0+1
.tg_ox0_done

    ; ox1 = min(xhi, ihi)
    SEC
    LDA zp_ms_xhi16   : SBC zp_ms_ihi
    LDA zp_ms_xhi16+1 : SBC zp_ms_ihi+1
    BVC tg_ox1_nov
    EOR #&80
.tg_ox1_nov
    BPL tg_ox1_ihi
    LDA zp_ms_xhi16   : STA zp_tg_ox1
    LDA zp_ms_xhi16+1 : STA zp_tg_ox1+1
    JMP tg_ox1_done
.tg_ox1_ihi
    LDA zp_ms_ihi   : STA zp_tg_ox1
    LDA zp_ms_ihi+1 : STA zp_tg_ox1+1
.tg_ox1_done

    ; --- Inner loop: pw_max(src.tfn, new.tfn, ox0, ox1) ---
    ; Setup pw_max inputs: f = src.tfn, g = new.tfn, x0 = ox0, x1 = ox1
    LDA zp_tg_src_tslope     : STA zp_pw_f_slope
    LDA zp_tg_src_tslope+1   : STA zp_pw_f_slope+1
    LDA zp_tg_src_tintercept : STA zp_pw_f_intercept
    LDA zp_tg_src_tintercept+1 : STA zp_pw_f_intercept+1
    LDA zp_tg_new_tslope     : STA zp_pw_g_slope
    LDA zp_tg_new_tslope+1   : STA zp_pw_g_slope+1
    LDA zp_tg_new_tintercept : STA zp_pw_g_intercept
    LDA zp_tg_new_tintercept+1 : STA zp_pw_g_intercept+1
    LDA zp_tg_ox0   : STA zp_pw_x0
    LDA zp_tg_ox0+1 : STA zp_pw_x0+1
    LDA zp_tg_ox1   : STA zp_pw_x1
    LDA zp_tg_ox1+1 : STA zp_pw_x1+1
    JSR pw_max
    ; Save pw_max's count and cx — the nested pw_min call will clobber them.
    LDA zp_pw_count : STA zp_tg_pwmax_count
    LDA zp_pw_cx    : STA zp_tg_pwmax_cx
    LDA zp_pw_cx+1  : STA zp_tg_pwmax_cx+1

    ; Iterate tx ranges (count = 1 or 2)
    ; For tx_idx = 0: tx0 = ox0, tx1 = (count==1? ox1 : cx), tfn_use_new = r0_fn
    LDA zp_pw_r0_fn : STA zp_tg_tfn_use_new
    ; tx0 = ox0, tx1 = ox1 (if count==1) or cx (if count==2)
    LDA zp_tg_ox0   : STA zp_tg_tx0
    LDA zp_tg_ox0+1 : STA zp_tg_tx0+1
    LDA zp_tg_pwmax_count
    CMP #1
    BEQ tg_tx0_one
    ; count == 2 → tx1 = cx
    LDA zp_tg_pwmax_cx   : STA zp_tg_tx1
    LDA zp_tg_pwmax_cx+1 : STA zp_tg_tx1+1
    JMP tg_tx0_ready
.tg_tx0_one
    LDA zp_tg_ox1   : STA zp_tg_tx1
    LDA zp_tg_ox1+1 : STA zp_tg_tx1+1
.tg_tx0_ready
    ; Stash r1_fn before the call (pw_min in the callee clobbers zp_pw_r1_fn).
    LDA zp_pw_r1_fn : PHA
    JSR tg_process_tx_range
    PLA             : STA zp_pw_r1_fn

    ; If count == 2, iterate tx_idx = 1
    LDA zp_tg_pwmax_count
    CMP #2
    BNE tg_inner_done
    ; Second tx range: tx0 = cx, tx1 = ox1, fn = r1_fn
    LDA zp_pw_r1_fn : STA zp_tg_tfn_use_new
    LDA zp_tg_pwmax_cx   : STA zp_tg_tx0
    LDA zp_tg_pwmax_cx+1 : STA zp_tg_tx0+1
    LDA zp_tg_ox1   : STA zp_tg_tx1
    LDA zp_tg_ox1+1 : STA zp_tg_tx1+1
    JSR tg_process_tx_range
.tg_inner_done

    ; Right fragment: if ihi < xhi
    SEC
    LDA zp_ms_ihi   : SBC zp_ms_xhi16
    LDA zp_ms_ihi+1 : SBC zp_ms_xhi16+1
    BVC tg_rf_nov
    EOR #&80
.tg_rf_nov
    BPL tg_rf_skip
    ; ihi < xhi → right fragment with STASHED src fns
    LDA zp_tg_src_tslope     : STA zp_mk_tslope
    LDA zp_tg_src_tslope+1   : STA zp_mk_tslope+1
    LDA zp_tg_src_tintercept : STA zp_mk_tintercept
    LDA zp_tg_src_tintercept+1 : STA zp_mk_tintercept+1
    LDA zp_tg_src_bslope     : STA zp_mk_bslope
    LDA zp_tg_src_bslope+1   : STA zp_mk_bslope+1
    LDA zp_tg_src_bintercept : STA zp_mk_bintercept
    LDA zp_tg_src_bintercept+1 : STA zp_mk_bintercept+1
    LDA zp_ms_ihi : STA zp_mk_xlo
    LDY #SP_XHI
    LDA (zp_ms_src),Y
    STA zp_mk_xhi
    JSR make_span
    JSR mk_out_advance
    JSR inc_dest_count
.tg_rf_skip

.tg_next
    JSR ms_next_src
    BCS tg_finish
    JMP tg_loop

.tg_finish
    JMP swap_cspan
}

; ======================================================================
; TG_PROCESS_TX_RANGE: inner helper — given a (tx0, tx1) range with
; tfn_use_new flag, run pw_min on (src.bfn, new.bfn) and emit spans.
;
; Inputs: zp_tg_tx0, zp_tg_tx1 (s16), zp_tg_tfn_use_new (u8: 0=src, 1=new)
; Uses zp_pw_* scratch for the pw_min call.
; ======================================================================
.tg_process_tx_range
{
    ; Setup pw_min inputs: f = src.bfn, g = new.bfn, x0 = tx0, x1 = tx1
    LDA zp_tg_src_bslope     : STA zp_pw_f_slope
    LDA zp_tg_src_bslope+1   : STA zp_pw_f_slope+1
    LDA zp_tg_src_bintercept : STA zp_pw_f_intercept
    LDA zp_tg_src_bintercept+1 : STA zp_pw_f_intercept+1
    LDA zp_tg_new_bslope     : STA zp_pw_g_slope
    LDA zp_tg_new_bslope+1   : STA zp_pw_g_slope+1
    LDA zp_tg_new_bintercept : STA zp_pw_g_intercept
    LDA zp_tg_new_bintercept+1 : STA zp_pw_g_intercept+1
    LDA zp_tg_tx0   : STA zp_pw_x0
    LDA zp_tg_tx0+1 : STA zp_pw_x0+1
    LDA zp_tg_tx1   : STA zp_pw_x1
    LDA zp_tg_tx1+1 : STA zp_pw_x1+1
    JSR pw_min
    ; NOTE: pw_min's crossover path clobbers zp_tg_tx0/tx1 as scratch.
    ; The zp_pw_x0/x1 slots we set up above are untouched by pw_min, so
    ; use them (instead of zp_tg_tx0/tx1) for the rest of this routine.

    ; Iterate bx ranges.  For bx_idx = 0: bx0 = tx0, bx1 = (count==1? tx1 : cx_bot)
    ; Save pw_min outputs to tg slots since we might need them twice.
    LDA zp_pw_count : STA zp_tg_bfn_use_new  ; reuse as temp
    ; Handle bx_idx = 0
    LDA zp_pw_r0_fn : STA zp_tg_bfn_use_new
    LDA zp_pw_x0   : STA zp_tg_bx0
    LDA zp_pw_x0+1 : STA zp_tg_bx0+1
    LDA zp_pw_count
    CMP #1
    BEQ tgp_bx0_one
    LDA zp_pw_cx   : STA zp_tg_bx1
    LDA zp_pw_cx+1 : STA zp_tg_bx1+1
    JMP tgp_bx0_ready
.tgp_bx0_one
    LDA zp_pw_x1   : STA zp_tg_bx1
    LDA zp_pw_x1+1 : STA zp_tg_bx1+1
.tgp_bx0_ready
    JSR tg_emit_span

    LDA zp_pw_count
    CMP #2
    BNE tgp_done
    ; Second bx range
    LDA zp_pw_r1_fn : STA zp_tg_bfn_use_new
    LDA zp_pw_cx   : STA zp_tg_bx0
    LDA zp_pw_cx+1 : STA zp_tg_bx0+1
    LDA zp_pw_x1   : STA zp_tg_bx1
    LDA zp_pw_x1+1 : STA zp_tg_bx1+1
    JSR tg_emit_span
.tgp_done
    RTS
}

; ======================================================================
; TG_EMIT_SPAN: compute and emit one inner-loop span.
;
; Inputs:
;   zp_tg_bx0, zp_tg_bx1 (s16) — span x range
;   zp_tg_tfn_use_new (u8: 0=use src_tfn, 1=use new_tfn)
;   zp_tg_bfn_use_new (u8: 0=use src_bfn, 1=use new_bfn)
; Output: span written to scratch if aperture exists.
; ======================================================================
.tg_emit_span
{
    ; bx1 > bx0 check (strict signed).  If bx1 <= bx0, skip this span.
    ; Preserve diff_lo in zp_tmp0 so the equal-check can see both bytes.
    SEC
    LDA zp_tg_bx1   : SBC zp_tg_bx0   : STA zp_tmp0
    LDA zp_tg_bx1+1 : SBC zp_tg_bx0+1
    BVC tges_nov
    EOR #&80
.tges_nov
    BPL tges_maybe_proceed
    JMP tges_skip              ; diff < 0 → bx1 < bx0 → skip
.tges_maybe_proceed
    BNE tges_proceed           ; diff_hi != 0 and nonneg → diff > 0
    LDA zp_tmp0
    BNE tges_proceed           ; diff_lo != 0 → diff > 0
    JMP tges_skip              ; diff == 0 → bx1 == bx0 → skip
.tges_proceed

    ; Select t_fn → zp_mk_tslope/tintercept
    LDA zp_tg_tfn_use_new
    BEQ tges_t_src
    LDA zp_tg_new_tslope     : STA zp_mk_tslope
    LDA zp_tg_new_tslope+1   : STA zp_mk_tslope+1
    LDA zp_tg_new_tintercept : STA zp_mk_tintercept
    LDA zp_tg_new_tintercept+1 : STA zp_mk_tintercept+1
    JMP tges_t_done
.tges_t_src
    LDA zp_tg_src_tslope     : STA zp_mk_tslope
    LDA zp_tg_src_tslope+1   : STA zp_mk_tslope+1
    LDA zp_tg_src_tintercept : STA zp_mk_tintercept
    LDA zp_tg_src_tintercept+1 : STA zp_mk_tintercept+1
.tges_t_done

    ; Select b_fn → zp_mk_bslope/bintercept
    LDA zp_tg_bfn_use_new
    BEQ tges_b_src
    LDA zp_tg_new_bslope     : STA zp_mk_bslope
    LDA zp_tg_new_bslope+1   : STA zp_mk_bslope+1
    LDA zp_tg_new_bintercept : STA zp_mk_bintercept
    LDA zp_tg_new_bintercept+1 : STA zp_mk_bintercept+1
    JMP tges_b_done
.tges_b_src
    LDA zp_tg_src_bslope     : STA zp_mk_bslope
    LDA zp_tg_src_bslope+1   : STA zp_mk_bslope+1
    LDA zp_tg_src_bintercept : STA zp_mk_bintercept
    LDA zp_tg_src_bintercept+1 : STA zp_mk_bintercept+1
.tges_b_done

    ; Compute t0 = fp_eval(t_fn, bx0), b0 = fp_eval(b_fn, bx0)
    ;         t1 = fp_eval(t_fn, bx1-1), b1 = fp_eval(b_fn, bx1-1)
    ; Use zp_mk_top_l/top_r/bot_l/bot_r as storage for these.
    LDA zp_mk_tslope     : STA zp_tmp2
    LDA zp_mk_tslope+1   : STA zp_tmp2+1
    LDA zp_mk_tintercept : STA zp_mk_tmp
    LDA zp_mk_tintercept+1 : STA zp_mk_tmp+1
    LDA zp_tg_bx0
    JSR fp_eval
    LDA &70 : STA zp_mk_top_l   ; t0
    LDA &71 : STA zp_mk_top_l+1

    LDA zp_mk_bslope     : STA zp_tmp2
    LDA zp_mk_bslope+1   : STA zp_tmp2+1
    LDA zp_mk_bintercept : STA zp_mk_tmp
    LDA zp_mk_bintercept+1 : STA zp_mk_tmp+1
    LDA zp_tg_bx0
    JSR fp_eval
    LDA &70 : STA zp_mk_bot_l   ; b0
    LDA &71 : STA zp_mk_bot_l+1

    ; x = bx1 - 1 (u8; bx1 may be 0=256, so x = 255)
    LDA zp_tg_bx1
    BNE tges_x_sub
    LDA #255
    JMP tges_x_have
.tges_x_sub
    SEC
    SBC #1
.tges_x_have
    PHA
    LDA zp_mk_tslope     : STA zp_tmp2
    LDA zp_mk_tslope+1   : STA zp_tmp2+1
    LDA zp_mk_tintercept : STA zp_mk_tmp
    LDA zp_mk_tintercept+1 : STA zp_mk_tmp+1
    PLA
    PHA
    JSR fp_eval
    LDA &70 : STA zp_mk_top_r   ; t1
    LDA &71 : STA zp_mk_top_r+1

    LDA zp_mk_bslope     : STA zp_tmp2
    LDA zp_mk_bslope+1   : STA zp_tmp2+1
    LDA zp_mk_bintercept : STA zp_mk_tmp
    LDA zp_mk_bintercept+1 : STA zp_mk_tmp+1
    PLA
    JSR fp_eval
    LDA &70 : STA zp_mk_bot_r   ; b1
    LDA &71 : STA zp_mk_bot_r+1

    ; Aperture check: (t0 < b0) OR (t1 < b1)
    ; t0 < b0: signed compare (t0 - b0) < 0
    SEC
    LDA zp_mk_top_l   : SBC zp_mk_bot_l
    LDA zp_mk_top_l+1 : SBC zp_mk_bot_l+1
    BVC tges_ap1_nov
    EOR #&80
.tges_ap1_nov
    BMI tges_has_aperture
    ; t0 >= b0; check t1 < b1
    SEC
    LDA zp_mk_top_r   : SBC zp_mk_bot_r
    LDA zp_mk_top_r+1 : SBC zp_mk_bot_r+1
    BVC tges_ap2_nov
    EOR #&80
.tges_ap2_nov
    BMI tges_has_aperture
    RTS                          ; no aperture → skip this span

.tges_has_aperture
    ; --- Write span to (zp_mk_out) ---
    ; xlo = bx0, xhi = bx1 (both u8)
    LDY #SP_XLO
    LDA zp_tg_bx0 : STA (zp_mk_out),Y
    LDY #SP_XHI
    LDA zp_tg_bx1 : STA (zp_mk_out),Y

    LDY #SP_TSLOPE
    LDA zp_mk_tslope   : STA (zp_mk_out),Y : INY
    LDA zp_mk_tslope+1 : STA (zp_mk_out),Y
    LDY #SP_BSLOPE
    LDA zp_mk_bslope   : STA (zp_mk_out),Y : INY
    LDA zp_mk_bslope+1 : STA (zp_mk_out),Y
    LDY #SP_TINTERCEPT
    LDA zp_mk_tintercept   : STA (zp_mk_out),Y : INY
    LDA zp_mk_tintercept+1 : STA (zp_mk_out),Y
    LDY #SP_BINTERCEPT
    LDA zp_mk_bintercept   : STA (zp_mk_out),Y : INY
    LDA zp_mk_bintercept+1 : STA (zp_mk_out),Y

    ; inner_top = max(t0, t1)
    SEC
    LDA zp_mk_top_l   : SBC zp_mk_top_r
    LDA zp_mk_top_l+1 : SBC zp_mk_top_r+1
    BVC tges_it_nov
    EOR #&80
.tges_it_nov
    BMI tges_it_r
    LDA zp_mk_top_l   : STA &70
    LDA zp_mk_top_l+1 : STA &71
    JMP tges_it_done
.tges_it_r
    LDA zp_mk_top_r   : STA &70
    LDA zp_mk_top_r+1 : STA &71
.tges_it_done
    LDY #SP_INNER_TOP
    LDA &70 : STA (zp_mk_out),Y : INY
    LDA &71 : STA (zp_mk_out),Y

    ; inner_bot = min(b0, b1)
    SEC
    LDA zp_mk_bot_l   : SBC zp_mk_bot_r
    LDA zp_mk_bot_l+1 : SBC zp_mk_bot_r+1
    BVC tges_ib_nov
    EOR #&80
.tges_ib_nov
    BPL tges_ib_r
    LDA zp_mk_bot_l   : STA &70
    LDA zp_mk_bot_l+1 : STA &71
    JMP tges_ib_done
.tges_ib_r
    LDA zp_mk_bot_r   : STA &70
    LDA zp_mk_bot_r+1 : STA &71
.tges_ib_done
    LDY #SP_INNER_BOT
    LDA &70 : STA (zp_mk_out),Y : INY
    LDA &71 : STA (zp_mk_out),Y

    ; --- outer_top = min(top_l, top_r), clamped to [0, 159] as u8 ---
    SEC
    LDA zp_mk_top_l   : SBC zp_mk_top_r
    LDA zp_mk_top_l+1 : SBC zp_mk_top_r+1
    BVC tges_ot_nov
    EOR #&80
.tges_ot_nov
    BPL tges_ot_r       ; top_l >= top_r → outer = top_r
    LDA zp_mk_top_l   : STA &74
    LDA zp_mk_top_l+1 : STA &75
    JMP tges_ot_clamp
.tges_ot_r
    LDA zp_mk_top_r   : STA &74
    LDA zp_mk_top_r+1 : STA &75
.tges_ot_clamp
    LDA &75
    BMI tges_ot_zero
    BNE tges_ot_159
    LDA &74
    CMP #160
    BCC tges_ot_store
    LDA #159
    JMP tges_ot_store
.tges_ot_zero
    LDA #0
    JMP tges_ot_store
.tges_ot_159
    LDA #159
.tges_ot_store
    LDY #SP_OUTER_TOP
    STA (zp_mk_out),Y

    ; --- outer_bot = max(bot_l, bot_r), clamped to [0, 159] as u8 ---
    SEC
    LDA zp_mk_bot_l   : SBC zp_mk_bot_r
    LDA zp_mk_bot_l+1 : SBC zp_mk_bot_r+1
    BVC tges_ob_nov
    EOR #&80
.tges_ob_nov
    BMI tges_ob_r       ; bot_l < bot_r → outer = bot_r
    LDA zp_mk_bot_l   : STA &74
    LDA zp_mk_bot_l+1 : STA &75
    JMP tges_ob_clamp
.tges_ob_r
    LDA zp_mk_bot_r   : STA &74
    LDA zp_mk_bot_r+1 : STA &75
.tges_ob_clamp
    LDA &75
    BMI tges_ob_zero
    BNE tges_ob_159
    LDA &74
    CMP #160
    BCC tges_ob_store
    LDA #159
    JMP tges_ob_store
.tges_ob_zero
    LDA #0
    JMP tges_ob_store
.tges_ob_159
    LDA #159
.tges_ob_store
    LDY #SP_OUTER_BOT
    STA (zp_mk_out),Y

    JSR mk_out_advance
    JSR inc_dest_count
.tges_skip
    RTS
}

; ======================================================================
; FLUSH: apply all queued mark_solid / tighten ops to the span state.
;
; Reads queue entries at queue_base, dispatches to mark_solid or tighten
; for each.  After all entries processed, resets queue count and tail.
; ======================================================================
.flush_native
{
    LDA queue_count
    BNE fln_has_work
    RTS
.fln_has_work
    STA flush_rem
    LDA #LO(queue_base)
    STA flush_ptr_lo
    LDA #HI(queue_base)
    STA flush_ptr_hi

.fln_loop
    ; Load entry pointer into zp_ptr0 (we use it as the indirect base
    ; for reading queue fields).  ptr0 gets clobbered by the call; we
    ; restore from flush_ptr_lo/hi each iteration.
    LDA flush_ptr_lo : STA zp_ptr0
    LDA flush_ptr_hi : STA zp_ptr0+1

    ; Read lo, hi (always needed)
    LDY #QE_LO
    LDA (zp_ptr0),Y : STA zp_ms_lo
    INY
    LDA (zp_ptr0),Y : STA zp_ms_lo+1
    LDY #QE_HI
    LDA (zp_ptr0),Y : STA zp_ms_hi
    INY
    LDA (zp_ptr0),Y : STA zp_ms_hi+1

    ; Check type
    LDY #QE_TYPE
    LDA (zp_ptr0),Y
    BNE fln_tighten

    ; --- Type == solid: call mark_solid ---
    JSR mark_solid
    JMP fln_next

.fln_tighten
    ; --- Type == tighten: load fp_linfn inputs, call tighten ---
    ; fp_linfn reads $60=y1, $62=y2, $64=sx1, $66=sx2.
    ; tighten expects yb1/yb2 stashed in zp_tg_ox0/ox1 (s16 each).
    LDY #QE_YT1
    LDA (zp_ptr0),Y : STA &60
    INY
    LDA (zp_ptr0),Y : STA &61
    LDY #QE_YT2
    LDA (zp_ptr0),Y : STA &62
    INY
    LDA (zp_ptr0),Y : STA &63
    LDY #QE_SX1
    LDA (zp_ptr0),Y : STA &64
    INY
    LDA (zp_ptr0),Y : STA &65
    LDY #QE_SX2
    LDA (zp_ptr0),Y : STA &66
    INY
    LDA (zp_ptr0),Y : STA &67
    ; Stash yb1, yb2 for the second fp_linfn call inside tighten
    LDY #QE_YB1
    LDA (zp_ptr0),Y : STA zp_tg_ox0
    INY
    LDA (zp_ptr0),Y : STA zp_tg_ox0+1
    LDY #QE_YB2
    LDA (zp_ptr0),Y : STA zp_tg_ox1
    INY
    LDA (zp_ptr0),Y : STA zp_tg_ox1+1
    JSR tighten

.fln_next
    ; Python flush has an `if clips.is_full(): break` early-exit after
    ; each op.  is_full() returns True when the span list is empty, i.e.
    ; span count == 0.  Match this behaviour so cumulative span state
    ; evolves identically.
    LDY #0 : LDA (zp_cspan),Y
    BEQ fln_done
    ; Advance flush_ptr by QE_SIZE
    LDA flush_ptr_lo
    CLC
    ADC #QE_SIZE
    STA flush_ptr_lo
    BCC fln_no_carry
    INC flush_ptr_hi
.fln_no_carry
    DEC flush_rem
    BEQ fln_done
    JMP fln_loop

.fln_done
    ; Reset queue count and tail
    LDA #0
    STA queue_count
    LDA #LO(queue_base)
    STA zp_q_tail
    LDA #HI(queue_base)
    STA zp_q_tail+1
    RTS
}

; ======================================================================
; MUL16X16: Signed 16×16 → 32-bit multiply
; Input: zp_tmp0 (s16) × zp_tmp2 (s16)
; Output: $70-$73 (s32, little-endian)
; Uses 4 calls to smul8x8/umul8x8
; ======================================================================
.mul16x16
{
    ; a = tmp0 (a_hi:a_lo), b = tmp2 (b_hi:b_lo)
    ; result = a_lo*b_lo + (a_lo*b_hi + a_hi*b_lo)*256 + a_hi*b_hi*65536
    ;
    ; a_lo*b_lo: unsigned × unsigned
    ; a_hi*b_hi: signed × signed
    ; cross terms: mixed

    ; 1. a_lo × b_lo (unsigned × unsigned → u16)
    LDA zp_tmp0          ; a_lo
    STA zp_math_b
    LDA zp_tmp2          ; b_lo
    JSR umul8x8
    LDA zp_res_lo
    STA &70
    LDA zp_res_hi
    STA &71

    ; 2. a_hi × b_lo (signed × unsigned)
    ; Use smul8x8(a_hi, b_lo). If b_lo > 127, need correction.
    LDA zp_tmp2          ; b_lo
    STA zp_math_b
    LDA zp_tmp0+1        ; a_hi (signed)
    JSR smul8x8
    ; Result = a_hi * b_lo_signed. If b_lo > 127, add a_hi * 256.
    STA &73              ; res_hi → byte 3 temp
    LDA zp_res_lo
    STA &72              ; res_lo → byte 2 temp

    LDA zp_tmp2          ; b_lo
    BMI ahbl_correct     ; b_lo > 127
    JMP ahbl_done
.ahbl_correct
    ; Add a_hi * 256 to $72:$73 (which is a_hi * b_lo_signed)
    ; a_hi * 256 → just add a_hi to $73
    LDA &73
    CLC
    ADC zp_tmp0+1
    STA &73
.ahbl_done

    ; 3. a_lo × b_hi (unsigned × signed)
    LDA zp_tmp0          ; a_lo
    STA zp_math_b
    LDA zp_tmp2+1        ; b_hi (signed)
    JSR smul8x8
    ; Same correction if a_lo > 127
    STA zp_tmp3+1        ; res_hi
    LDA zp_res_lo
    STA zp_tmp3          ; res_lo

    LDA zp_tmp0          ; a_lo
    BMI albh_correct
    JMP albh_done
.albh_correct
    LDA zp_tmp3+1
    CLC
    ADC zp_tmp2+1        ; add b_hi
    STA zp_tmp3+1
.albh_done

    ; Add cross terms ($72:$73 and tmp3:tmp3+1) into result bytes 1-3
    ; $70 = byte 0 (done)
    ; $71 = byte 1 (has a_lo*b_lo hi byte)
    ; $72:$73 = a_hi*b_lo shifted by 8 (bytes 1-2)
    ; tmp3:tmp3+1 = a_lo*b_hi shifted by 8 (bytes 1-2)

    ; Add $72 to $71, carry into new $72
    LDA &71
    CLC
    ADC &72
    STA &71
    LDA &73
    ADC #0
    STA &72

    ; Sign-extend $72 to $73
    LDA &72
    BPL no_ext1
    LDA #&FF
    STA &73
    JMP add_cross2
.no_ext1
    LDA #0
    STA &73
.add_cross2

    ; Add tmp3:tmp3+1 to $71:$72:$73
    LDA &71
    CLC
    ADC zp_tmp3
    STA &71
    LDA &72
    ADC zp_tmp3+1
    STA &72
    ; sign-extend tmp3+1 for carry into $73
    LDA zp_tmp3+1
    BPL no_ext2
    LDA &73
    ADC #&FF
    STA &73
    JMP add_hh
.no_ext2
    LDA &73
    ADC #0
    STA &73

.add_hh
    ; 4. a_hi × b_hi (signed × signed → s16)
    LDA zp_tmp0+1
    STA zp_math_b
    LDA zp_tmp2+1
    JSR smul8x8
    ; Add to bytes 2-3
    LDA &72
    CLC
    ADC zp_res_lo
    STA &72
    LDA &73
    ADC zp_res_hi
    STA &73

    RTS
}

; ======================================================================
; RENDER SUBSECTOR
; Input: zp_tmp0 = subsector ID (u16)
; ======================================================================
.render_subsector
{
    ; Address = rom_window + off_ss + ssid * 4
    LDA zp_tmp0
    ASL A : STA zp_ptr0
    LDA zp_tmp0+1
    ROL A : STA zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1  ; × 4

    LDA zp_ptr0
    CLC
    ADC zp_ss_base
    STA zp_ptr0
    LDA zp_ptr0+1
    ADC zp_ss_base+1
    STA zp_ptr0+1

    ; Read count (u8) and first_seg (u16)
    LDY #0
    LDA (zp_ptr0),Y      ; count
    STA zp_seg_count
    LDY #2
    LDA (zp_ptr0),Y      ; first_seg lo
    STA zp_seg_idx
    INY
    LDA (zp_ptr0),Y      ; first_seg hi
    STA zp_seg_idx+1

    ; --- Initialise running seg header pointer: rom_window + off_seg_hdr + idx*12 ---
    ; idx * 12 = idx*8 + idx*4
    ; Compute idx * 12 in zp_seg_hdr_ptr, then idx * 24 = idx*12 << 1
    LDA zp_seg_idx : STA zp_seg_hdr_ptr
    LDA zp_seg_idx+1 : STA zp_seg_hdr_ptr+1
    ASL zp_seg_hdr_ptr : ROL zp_seg_hdr_ptr+1
    ASL zp_seg_hdr_ptr : ROL zp_seg_hdr_ptr+1           ; × 4
    LDA zp_seg_hdr_ptr : STA zp_tmp0
    LDA zp_seg_hdr_ptr+1 : STA zp_tmp0+1
    ASL zp_seg_hdr_ptr : ROL zp_seg_hdr_ptr+1           ; × 8
    LDA zp_seg_hdr_ptr : CLC : ADC zp_tmp0 : STA zp_seg_hdr_ptr
    LDA zp_seg_hdr_ptr+1 : ADC zp_tmp0+1 : STA zp_seg_hdr_ptr+1   ; × 12

    ; idx * 24 = idx * 12 * 2
    LDA zp_seg_hdr_ptr   : ASL A : STA zp_seg_det_ptr
    LDA zp_seg_hdr_ptr+1 : ROL A : STA zp_seg_det_ptr+1

    ; Add base: zp_seg_hdr_base (= rom_window + off_seg_hdr)
    LDA zp_seg_hdr_ptr   : CLC : ADC zp_seg_hdr_base : STA zp_seg_hdr_ptr
    LDA zp_seg_hdr_ptr+1 : ADC zp_seg_hdr_base+1     : STA zp_seg_hdr_ptr+1

    ; Add base: rom_window (bank 1) → zp_seg_det_ptr (no offset; detail at rom_window base)
    LDA zp_seg_det_ptr+1 : CLC : ADC #HI(rom_window) : STA zp_seg_det_ptr+1

    ; Process each seg (DEC-at-end loop to avoid redundant check+dec)
    LDA zp_seg_count
    BEQ segs_done
.seg_loop
    JSR render_seg
    ; Advance running seg pointers (header += 12, detail += 24)
    LDA zp_seg_hdr_ptr : CLC : ADC #12 : STA zp_seg_hdr_ptr
    BCC sl_no_hdr_carry
    INC zp_seg_hdr_ptr+1
.sl_no_hdr_carry
    LDA zp_seg_det_ptr : CLC : ADC #24 : STA zp_seg_det_ptr
    BCC sl_no_det_carry
    INC zp_seg_det_ptr+1
.sl_no_det_carry
    DEC zp_seg_count
    BNE seg_loop

.segs_done
    ; Flush deferred span queue (applies mark_solid/tighten in order)
    JSR flush_native

    ; (CMD_ENDSS removed — no command buffer)

    RTS
}

; ======================================================================
; RENDER SEG
; Input: zp_seg_idx = seg index (u16)
; ======================================================================
.render_seg
{
    ; Read seg header fields via (zp_seg_hdr_ptr),Y directly — no copy to
    ; zp_ptr0 needed.  zp_ptr0 is used as scratch later (clobbered by
    ; xform calls) but zp_seg_hdr_ptr is preserved by all callees, so we
    ; can re-read fields from the header after those calls.

    ; --- Back-face test ---
    ; dot = ldy * (px_int - lv1_x) - ldx * (py_int - lv1_y)
    ; lv1_x at offset 4 (s16), lv1_y at offset 6 (s16)
    ; ldx at offset 8 (s8), ldy at offset 9 (s8)

    ; dx_bf = px_int - lv1_x (s8 - s16 → s16)
    LDY #SH_LV1X
    LDA zp_px_int
    SEC
    SBC (zp_seg_hdr_ptr),Y
    STA zp_tmp2
    LDA zp_px_int_hi
    INY
    SBC (zp_seg_hdr_ptr),Y
    STA zp_tmp2+1        ; dx_bf (s16)

    ; dy_bf = py_int - lv1_y
    LDY #SH_LV1Y
    LDA zp_py_int
    SEC
    SBC (zp_seg_hdr_ptr),Y
    STA zp_tmp3
    LDA zp_py_int_hi
    INY
    SBC (zp_seg_hdr_ptr),Y
    STA zp_tmp3+1        ; dy_bf (s16)

    ; ldy (s8) at offset 9.  Invariant: |ldx|, |ldy| <= 127 by construction
    ; — wad_packed.py / doom_wireframe.py assert this at load time.
    LDY #SH_LDY
    LDA (zp_seg_hdr_ptr),Y
    STA zp_tmp0           ; ldy

    ; ldx (s8) at offset 8
    LDY #SH_LDX
    LDA (zp_seg_hdr_ptr),Y
    STA zp_tmp1           ; ldx

    ; term1 = ldy * dx_bf (s8 × s16)
    ; term2 = ldx * dy_bf (s8 × s16)
    ; dot = term1 - term2

    ; Fast path: if BOTH dx_bf and dy_bf fit in s8, skip the high-byte
    ; multiplies entirely.  Sign-extension of the 16-bit result gives a
    ; valid s24 without the extra work.
    LDA zp_tmp2+1
    BEQ bf_dxhi_zero
    CMP #&FF
    BNE bf_wide
    LDA zp_tmp2
    BPL bf_wide           ; dxhi=$FF but dxlo bit7 clear → doesn't fit
    JMP bf_dx_ok
.bf_dxhi_zero
    LDA zp_tmp2
    BMI bf_wide           ; dxhi=0 but dxlo bit7 set → doesn't fit
.bf_dx_ok
    LDA zp_tmp3+1
    BEQ bf_dyhi_zero
    CMP #&FF
    BNE bf_wide
    LDA zp_tmp3
    BPL bf_wide
    JMP bf_dy_ok
.bf_dyhi_zero
    LDA zp_tmp3
    BMI bf_wide
.bf_dy_ok
    ; Both fit in s8.  Compute 16-bit dot product using 2 smul8x8 calls,
    ; or short-circuit when ldy/ldx is zero (axis-aligned wall).
    LDA zp_tmp0                 ; ldy
    BEQ bf_fast_ldy_zero
    LDA zp_tmp2 : STA zp_math_b
    LDA zp_tmp0 : JSR smul8x8   ; ldy × dx_bf (s8 × s8 → s16)
    LDA zp_res_lo : STA &74
    LDA zp_res_hi : STA &75
    JMP bf_fast_term2
.bf_fast_ldy_zero
    LDA #0 : STA &74 : STA &75
.bf_fast_term2
    LDA zp_tmp1                 ; ldx
    BEQ bf_fast_ldx_zero
    LDA zp_tmp3 : STA zp_math_b
    LDA zp_tmp1 : JSR smul8x8   ; ldx × dy_bf (s8 × s8 → s16)
    ; dot (s16) = ($75:$74) - (res_hi:res_lo)
    LDA &74 : SEC : SBC zp_res_lo : STA &74
    LDA &75 : SBC zp_res_hi : STA &75
    JMP bf_fast_sex
.bf_fast_ldx_zero
    ; term2 = 0, dot = term1 (already in $74:$75)
.bf_fast_sex
    ; Sign-extend to 24-bit byte2
    LDA &75
    BPL bf_fast_pos
    LDA #&FF
    STA &76
    JMP bf_fast_done
.bf_fast_pos
    LDA #0
    STA &76
.bf_fast_done
    JMP bf_after_mul

.bf_wide
    ; Wide path: dx_bf or dy_bf doesn't fit in s8.  Use mul_s16_u8_s24
    ; with abs(ldy/ldx) + sign apply instead of 4 raw smul8x8 calls.
    ; Also short-circuit when ldy==0 or ldx==0 (axis-aligned walls).
    ;
    ; term1 (24-bit) → $74:$76,  term2 (24-bit) → $78:$7A,  dot = term1-term2.
    ;
    ; === term1 = ldy * dx_bf ===
    ; dx_bf is already in zp_tmp2 — mul_s16_u8_s24's "ex" input.
    LDA zp_tmp0                  ; ldy
    BEQ bf_t1_zero
    BPL bf_t1_pos
    ; ldy negative: pass |ldy|, negate result
    EOR #&FF
    CLC
    ADC #1
    JSR mul_s16_u8_s24           ; $70:$72 = |ldy| * dx_bf
    ; term1 = -$70:$72  → store negated at $74:$76
    SEC
    LDA #0 : SBC &70 : STA &74
    LDA #0 : SBC &71 : STA &75
    LDA #0 : SBC &72 : STA &76
    JMP bf_t1_done
.bf_t1_pos
    JSR mul_s16_u8_s24           ; $70:$72 = ldy * dx_bf
    LDA &70 : STA &74
    LDA &71 : STA &75
    LDA &72 : STA &76
    JMP bf_t1_done
.bf_t1_zero
    LDA #0
    STA &74 : STA &75 : STA &76
.bf_t1_done

    ; === term2 = ldx * dy_bf ===
    ; Move dy_bf into zp_tmp2 for mul_s16_u8_s24.
    LDA zp_tmp3   : STA zp_tmp2
    LDA zp_tmp3+1 : STA zp_tmp2+1
    LDA zp_tmp1                  ; ldx
    BEQ bf_t2_zero
    BPL bf_t2_pos
    EOR #&FF
    CLC
    ADC #1
    JSR mul_s16_u8_s24           ; $70:$72 = |ldx| * dy_bf
    SEC
    LDA #0 : SBC &70 : STA &78
    LDA #0 : SBC &71 : STA &79
    LDA #0 : SBC &72 : STA &7A
    JMP bf_t2_done
.bf_t2_pos
    JSR mul_s16_u8_s24
    LDA &70 : STA &78
    LDA &71 : STA &79
    LDA &72 : STA &7A
    JMP bf_t2_done
.bf_t2_zero
    LDA #0
    STA &78 : STA &79 : STA &7A
.bf_t2_done

    ; dot = term1 - term2
    LDA &74
    SEC
    SBC &78
    STA &74
    LDA &75
    SBC &79
    STA &75
    LDA &76
    SBC &7A
    STA &76

.bf_after_mul
    ; Read flags
    LDY #SH_FLAGS
    LDA (zp_seg_hdr_ptr),Y
    STA zp_seg_flags

    ; If SF_DIR, negate entire 24-bit dot
    AND #SF_DIR
    BEQ bf_no_flip
    LDA &74
    EOR #&FF : CLC : ADC #1 : STA &74
    LDA &75
    EOR #&FF : ADC #0 : STA &75
    LDA &76
    EOR #&FF : ADC #0 : STA &76
.bf_no_flip

    ; Check dot sign: if dot < 0, cull. if dot == 0, cull. if dot > 0, pass.
    LDA &76               ; hi byte
    BMI bf_cull           ; negative → cull
    BNE bf_pass           ; hi byte > 0 → definitely positive → pass
    ; Hi byte is 0: check mid and lo for nonzero
    LDA &75
    BNE bf_pass           ; mid nonzero → positive
    LDA &74
    BNE bf_pass           ; lo nonzero → positive
    ; All zero → dot == 0 → cull
    JMP bf_cull
.bf_cull
    RTS
.bf_pass
    ; --- Read vertex indices directly via seg_hdr_ptr ---
    LDY #SH_V1
    LDA (zp_seg_hdr_ptr),Y
    STA zp_tmp0           ; v1 lo
    INY
    LDA (zp_seg_hdr_ptr),Y
    STA zp_tmp0+1         ; v1 hi
    LDY #SH_V2
    LDA (zp_seg_hdr_ptr),Y
    STA zp_tmp1           ; v2 lo
    INY
    LDA (zp_seg_hdr_ptr),Y
    STA zp_tmp1+1         ; v2 hi

    ; --- View transform vertex 2 first (writes directly to v2 slots
    ; on cache hit) — v1 index stays in zp_tmp0 saved to scratch. ---
    LDA zp_tmp0 : STA &46
    LDA zp_tmp0+1 : STA &47
    LDA zp_tmp1
    STA zp_tmp0
    LDA zp_tmp1+1
    STA zp_tmp0+1
    JSR xform_vertex_cached_v2   ; writes zp_vx2/vy2/vi2 directly

    ; --- View transform vertex 1 (cached) ---
    LDA &46 : STA zp_tmp0
    LDA &47 : STA zp_tmp0+1
    JSR xform_vertex_cached      ; writes zp_vx1/vy1/vi1

    ; --- Near clip ---
    JSR near_clip         ; input: vx1,vy1, vx2,vy2
                          ; output: ex1,ey1, ex2,ey2 or carry set = clipped away
    BCC nc_passed
    JMP seg_clipped
.nc_passed

    ; --- Reciprocal + X projection for endpoint 1 ---
    JSR recip_and_project_x1
    ; output: zp_sx1
    ; Save endpoint 1 reciprocal for Y projection
    LDA zp_rxh : STA &88
    LDA zp_rxl : STA &89

    ; --- Reciprocal + X projection for endpoint 2 ---
    JSR recip_and_project_x2
    ; output: zp_sx2
    ; Save endpoint 2 reciprocal for Y projection
    LDA zp_rxh : STA &8A
    LDA zp_rxl : STA &8B

    ; --- Compute x_lo, x_hi inline (x_lo = min(sx1, sx2), x_hi = max) ---
    LDA zp_sx1
    CMP zp_sx2
    LDA zp_sx1+1
    SBC zp_sx2+1
    BVC rs_xr_novf
    EOR #&80
.rs_xr_novf
    BMI rs_sx1_less
    ; sx1 >= sx2: x_lo = sx2, x_hi = sx1
    LDA zp_sx2   : STA zp_x_lo_clip
    LDA zp_sx2+1 : STA zp_x_lo_clip+1
    LDA zp_sx1   : STA zp_x_hi_clip
    LDA zp_sx1+1 : STA zp_x_hi_clip+1
    JMP rs_xr_done
.rs_sx1_less
    LDA zp_sx1   : STA zp_x_lo_clip
    LDA zp_sx1+1 : STA zp_x_lo_clip+1
    LDA zp_sx2   : STA zp_x_hi_clip
    LDA zp_sx2+1 : STA zp_x_hi_clip+1
.rs_xr_done

    ; --- Has gap? (reads zp_x_lo_clip / zp_x_hi_clip directly) ---
    JSR has_gap
    BCS hg_pass
    JMP seg_clipped
.hg_pass

    ; --- Read seg detail (heights) — in ROM bank 1 ---
    JSR select_bank_1
    JSR read_seg_detail   ; loads fh, ch (and bfh, bch if portal) into temps
    JSR select_bank_0

    ; --- Y projection ---
    JSR project_y_all     ; projects ft1, fb1, ft2, fb2 (and bt/bb if needed)

    ; --- Emit command ---
    LDA zp_seg_flags
    AND #SF_SOLID
    BNE emit_solid

    ; Portal — draw lines and queue a deferred tighten.  queue_tighten
    ; reads sx/ft/fb/bt/bb directly from their render_seg ZP slots.
    JSR draw_portal_lines
    ; NB: rasteriser clobbered $80-$87 during drawing. queue_tighten
    ; reads bt1/bt2 from $98-$9B (saved by draw_portal_lines) instead.
    JSR queue_tighten
    RTS

.emit_solid
    JSR draw_solid_lines
    ; queue_solid reads zp_x_lo_clip / zp_x_hi_clip directly.
    JSR queue_solid
    RTS

.seg_clipped
    RTS
}

; ======================================================================
; LOAD_VERTEX: read (wx, wy) from packed vertex array
; Input: zp_tmp0 = vertex index (u16)
; Output: zp_tmp2 = wx (s16), zp_tmp3 = wy (s16)
; ======================================================================
.load_vertex
{
    ; addr = rom_window + off_verts + idx * 4
    LDA zp_tmp0
    ASL A : STA zp_ptr0
    LDA zp_tmp0+1
    ROL A : STA zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1   ; × 4
    LDA zp_ptr0
    CLC
    ADC zp_vert_base
    STA zp_ptr0
    LDA zp_ptr0+1
    ADC zp_vert_base+1
    STA zp_ptr0+1

    LDY #0
    LDA (zp_ptr0),Y
    STA zp_tmp2
    INY
    LDA (zp_ptr0),Y
    STA zp_tmp2+1
    INY
    LDA (zp_ptr0),Y
    STA zp_tmp3
    INY
    LDA (zp_ptr0),Y
    STA zp_tmp3+1
    RTS
}

; ======================================================================
; VCACHE_ADDR: compute vertex cache entry address and valid-bit location
; Input: zp_tmp0 = v_idx (u16)
; Output: zp_ptr1 = vcache entry base + v_idx * 8
;         X = byte index into vcache_valid (v_idx >> 3)
;         Y = bit index in that byte (v_idx & 7)
; Clobbers: A, X, Y, zp_ptr1
; (vcache_addr is now inlined at each call site — the body appears in
; xform_vertex_cached and xform_vertex_cached_v2 directly.)

; ======================================================================
; XFORM_VERTEX_CACHED: view-transform a vertex, using the cache (v1 slots)
; Input: zp_tmp0 = v_idx (u16)
; Output: zp_vx1, zp_vy1, zp_vi1 populated
; Clobbers: most temps (to_view)
; ======================================================================
.xform_vertex_cached
{
    ; vcache_addr computation: ptr1 = vcache + idx*8.
    ; Start with A=idx_lo, A*=2 into zp_ptr1 (saves one STA vs the old
    ; approach which started by copying zp_tmp0 to zp_ptr1 before the
    ; three ASL/ROL pairs).
    LDA zp_tmp0
    ASL A : STA zp_ptr1
    LDA zp_tmp0+1
    ROL A : STA zp_ptr1+1
    ASL zp_ptr1 : ROL zp_ptr1+1
    ASL zp_ptr1 : ROL zp_ptr1+1
    LDA zp_ptr1   : CLC : ADC #LO(vcache) : STA zp_ptr1
    LDA zp_ptr1+1 : ADC #HI(vcache) : STA zp_ptr1+1
    LDA zp_tmp0
    LSR A : LSR A : LSR A
    STA zp_ptr0
    LDA zp_tmp0+1
    BEQ xvc1_no_hi
    LDA zp_ptr0 : CLC : ADC #32 : STA zp_ptr0
.xvc1_no_hi
    LDX zp_ptr0
    LDA zp_tmp0 : AND #7 : TAY

    LDA vcache_valid,X
    AND bit_masks,Y
    BEQ xvc_miss

    ; Hit: load vx, vy, vi from (ptr1) into v1 slots
    LDY #VC_VX
    LDA (zp_ptr1),Y : STA zp_vx1     : INY
    LDA (zp_ptr1),Y : STA zp_vx1+1   : INY
    LDA (zp_ptr1),Y : STA zp_vy1     : INY
    LDA (zp_ptr1),Y : STA zp_vy1+1   : INY
    LDA (zp_ptr1),Y : STA zp_vi1     : INY
    LDA (zp_ptr1),Y : STA zp_vi1+1
    RTS

.xvc_miss
    LDA vcache_valid,X
    ORA bit_masks,Y
    STA vcache_valid,X

    LDA zp_ptr1   : PHA
    LDA zp_ptr1+1 : PHA

    JSR load_vertex              ; reads zp_tmp0 (= v_idx), writes tmp2/tmp3
    JSR to_view                  ; writes vx1/vy1/vi1

    PLA : STA zp_ptr1+1
    PLA : STA zp_ptr1

    LDY #VC_VX
    LDA zp_vx1     : STA (zp_ptr1),Y : INY
    LDA zp_vx1+1   : STA (zp_ptr1),Y : INY
    LDA zp_vy1     : STA (zp_ptr1),Y : INY
    LDA zp_vy1+1   : STA (zp_ptr1),Y : INY
    LDA zp_vi1     : STA (zp_ptr1),Y : INY
    LDA zp_vi1+1   : STA (zp_ptr1),Y
    RTS
}

; ======================================================================
; XFORM_VERTEX_CACHED_V2: same as xform_vertex_cached but writes directly
; to zp_vx2/zp_vy2/zp_vi2 slots on cache hit (miss path still goes via
; to_view → v1 slots then copies to v2 slots, since to_view writes v1).
; ======================================================================
.xform_vertex_cached_v2
{
    ; Inlined vcache_addr (same body as xform_vertex_cached, saving one
    ; STA vs the naive three-ASL-ROL approach).
    LDA zp_tmp0
    ASL A : STA zp_ptr1
    LDA zp_tmp0+1
    ROL A : STA zp_ptr1+1
    ASL zp_ptr1 : ROL zp_ptr1+1
    ASL zp_ptr1 : ROL zp_ptr1+1
    LDA zp_ptr1   : CLC : ADC #LO(vcache) : STA zp_ptr1
    LDA zp_ptr1+1 : ADC #HI(vcache) : STA zp_ptr1+1
    LDA zp_tmp0
    LSR A : LSR A : LSR A
    STA zp_ptr0
    LDA zp_tmp0+1
    BEQ xvc2_no_hi
    LDA zp_ptr0 : CLC : ADC #32 : STA zp_ptr0
.xvc2_no_hi
    LDX zp_ptr0
    LDA zp_tmp0 : AND #7 : TAY

    LDA vcache_valid,X
    AND bit_masks,Y
    BEQ xvc2_miss

    ; Hit: load directly into v2 slots
    LDY #VC_VX
    LDA (zp_ptr1),Y : STA zp_vx2     : INY
    LDA (zp_ptr1),Y : STA zp_vx2+1   : INY
    LDA (zp_ptr1),Y : STA zp_vy2     : INY
    LDA (zp_ptr1),Y : STA zp_vy2+1   : INY
    LDA (zp_ptr1),Y : STA zp_vi2     : INY
    LDA (zp_ptr1),Y : STA zp_vi2+1
    RTS

.xvc2_miss
    LDA vcache_valid,X
    ORA bit_masks,Y
    STA vcache_valid,X

    LDA zp_ptr1   : PHA
    LDA zp_ptr1+1 : PHA

    JSR load_vertex
    JSR to_view                  ; writes v1 slots

    PLA : STA zp_ptr1+1
    PLA : STA zp_ptr1

    ; Store cache entry from v1 slots and simultaneously copy to v2 slots
    LDY #VC_VX
    LDA zp_vx1     : STA (zp_ptr1),Y : STA zp_vx2     : INY
    LDA zp_vx1+1   : STA (zp_ptr1),Y : STA zp_vx2+1   : INY
    LDA zp_vy1     : STA (zp_ptr1),Y : STA zp_vy2     : INY
    LDA zp_vy1+1   : STA (zp_ptr1),Y : STA zp_vy2+1   : INY
    LDA zp_vi1     : STA (zp_ptr1),Y : STA zp_vi2     : INY
    LDA zp_vi1+1   : STA (zp_ptr1),Y : STA zp_vi2+1
    RTS
}

; ======================================================================
; TO_VIEW: view transform for vertex 1
; Input: zp_tmp2 = wx (s16), zp_tmp3 = wy (s16)
; Output: zp_vx1, zp_vy1, zp_vi1
;
; dx = wx - px_int,  dy = wy - py_int
; int_vx = rot(dx, sin) - rot(dy, cos)
; int_vy = rot(dx, cos) + rot(dy, sin)
; total_vx = int_vx + frac_vx
; total_vy = int_vy + frac_vy
; vx1 = (total_vx + 128) >> 8
; vy1 = (total_vy + 128) >> 8
; vi1 = max(2, total_vy >> 7)
; ======================================================================
; ======================================================================
; ROT_TERM: compute one rotation term as 24-bit result
; Input: zp_tmp2 = val (s16), A = mag, X = neg flag, Y = unity flag
; Output: $70:$71:$72 = 24-bit result (lo:mid:hi, signed)
; ======================================================================
; ======================================================================
; ROT_SIN / ROT_COS: specialized rotation-term routines that read their
; trig flags (mag / neg / unity) directly from ZP.  Called by to_view
; without any caller-side parameter marshalling.
;
; Input:  zp_tmp2 = val (s16)
; Output: $70:$71:$72 = 24-bit signed result (val * sin or val * cos)
; ======================================================================
.rot_sin
{
    LDA zp_sin_unity
    BNE rs_unity
    LDA zp_sin_mag
    BEQ rs_zero
    JSR mul_s16_u8_s24    ; A = mag; val in zp_tmp2 → $70:$72
    LDA zp_sin_neg
    BEQ rs_done
    JMP rs_neg24
.rs_unity
    LDA #0
    STA &70
    LDA zp_tmp2
    STA &71
    LDA zp_tmp2+1
    STA &72
    LDA zp_sin_neg
    BEQ rs_done
.rs_neg24
    ; Negate 24-bit $70:$72 via 0 - x (one cycle shorter per byte than EOR+ADC)
    SEC
    LDA #0 : SBC &70 : STA &70
    LDA #0 : SBC &71 : STA &71
    LDA #0 : SBC &72 : STA &72
.rs_done
    RTS
.rs_zero
    LDA #0
    STA &70 : STA &71 : STA &72
    RTS
}

.rot_cos
{
    LDA zp_cos_unity
    BNE rc_unity
    LDA zp_cos_mag
    BEQ rc_zero
    JSR mul_s16_u8_s24
    LDA zp_cos_neg
    BEQ rc_done
    JMP rc_neg24
.rc_unity
    LDA #0
    STA &70
    LDA zp_tmp2
    STA &71
    LDA zp_tmp2+1
    STA &72
    LDA zp_cos_neg
    BEQ rc_done
.rc_neg24
    SEC
    LDA #0 : SBC &70 : STA &70
    LDA #0 : SBC &71 : STA &71
    LDA #0 : SBC &72 : STA &72
.rc_done
    RTS
.rc_zero
    LDA #0
    STA &70 : STA &71 : STA &72
    RTS
}

.to_view
{
    ; Input: zp_tmp2 = wx (s16), zp_tmp3 = wy (s16)
    ;
    ; Reordered for minimal ZP shuffling:
    ; 1. Compute dx into tmp2 (keeps tmp3=wy intact for later).
    ; 2. Do BOTH dx rotations back-to-back (no swap between them).
    ; 3. Compute dy into tmp2 from tmp3.
    ; 4. Do BOTH dy rotations back-to-back.
    ; This eliminates the dx/dy backup+restore pairs (~40 cycles).
    ;
    ; Intermediate slots:
    ;   DS  (dx*sin) 24-bit → &73:&74:&75
    ;   DC  (dx*cos) 24-bit → &94:&95:&96
    ;   YS  (dy*sin) 24-bit → &97:&98:&99
    ;   YC  (dy*cos) 24-bit → $70:$71:$72 (from last rot_term)
    ;
    ; dx = wx - px_int
    LDA zp_tmp2
    SEC
    SBC zp_px_int
    STA zp_tmp2
    LDA zp_tmp2+1
    SBC zp_px_int_hi
    STA zp_tmp2+1        ; dx in tmp2

    ; --- rot(dx, sin) → $70:$72 → save to DS (&73:&75) ---
    JSR rot_sin
    LDA &70 : STA &73
    LDA &71 : STA &74
    LDA &72 : STA &75

    ; --- rot(dx, cos) → $70:$72 → save to DC (&94:&96) ---
    ; tmp2 still holds dx — no restore needed
    JSR rot_cos
    LDA &70 : STA &94
    LDA &71 : STA &95
    LDA &72 : STA &96

    ; --- Compute dy = wy - py_int (wy still in tmp3) into tmp2 ---
    LDA zp_tmp3
    SEC
    SBC zp_py_int
    STA zp_tmp2
    LDA zp_tmp3+1
    SBC zp_py_int_hi
    STA zp_tmp2+1

    ; --- rot(dy, sin) → $70:$72 → save to YS (&97:&99) ---
    JSR rot_sin
    LDA &70 : STA &97
    LDA &71 : STA &98
    LDA &72 : STA &99

    ; --- rot(dy, cos) → $70:$72 (stays in place, used for vx computation) ---
    ; tmp2 still holds dy
    JSR rot_cos
    ; YC now in $70:$71:$72

    ; === int_vx = DS - YC ===
    LDA &73 : SEC : SBC &70 : STA &70
    LDA &74 : SBC &71 : STA &71
    LDA &75 : SBC &72 : STA &72

    ; total_vx = int_vx + frac_vx (24-bit)
    LDA &70 : CLC : ADC zp_frac_vx : STA &70
    LDA &71 : ADC zp_frac_vx+1 : STA &71
    LDA &72 : ADC zp_frac_vx_ext : STA &72
    ; total_vx now in $70:$72 — save to $7A:$7C (used later for extraction)
    LDA &70 : STA &7A
    LDA &71 : STA &7B
    LDA &72 : STA &7C

    ; === int_vy = DC + YS ===
    LDA &94 : CLC : ADC &97 : STA &70
    LDA &95 : ADC &98 : STA &71
    LDA &96 : ADC &99 : STA &72

    ; total_vy = int_vy + frac_vy (24-bit)
    LDA &70 : CLC : ADC zp_frac_vy : STA &70
    LDA &71 : ADC zp_frac_vy+1 : STA &71
    LDA &72 : ADC zp_frac_vy_ext : STA &72
    ; Save total_vy to $73:$75
    LDA &70 : STA &73
    LDA &71 : STA &74
    LDA &72 : STA &75

    ; === Extract vx1, vy1, vi1 ===

    ; vx1 = (total_vx + 128) >> 8
    ; total_vx in $7A:$7B:$7C (24-bit, lo:mid:hi)
    LDA &7A : CLC : ADC #128
    LDA &7B : ADC #0 : STA zp_vx1
    LDA &7C : ADC #0 : STA zp_vx1+1

    ; vy1 = (total_vy + 128) >> 8
    ; total_vy in $73:$74:$75 (24-bit)
    LDA &73 : CLC : ADC #128
    LDA &74 : ADC #0 : STA zp_vy1
    LDA &75 : ADC #0 : STA zp_vy1+1

    ; vi1 = max(2, total_vy >> 7)
    ; total_vy is 24-bit. >> 7 of 24-bit = >> 7 keeping 16 bits
    ; total_vy_bytes: $73(lo), $74(mid), $75(hi)
    ; >> 7 = shift right 7 = shift left 1 bit from the 16-bit mid:hi portion
    ; with bit 0 coming from bit 7 of lo byte
    LDA &73 : ROL A          ; bit 7 → carry
    LDA &74 : ROL A          ; $74 << 1 | carry = total_vy >> 7 lo
    STA zp_vi1
    LDA &75 : ROL A          ; $75 << 1 | carry = total_vy >> 7 hi
    STA zp_vi1+1
    ; Clamp: if vi1 < 2, set to 2
    LDA zp_vi1+1
    BMI vi1_set2              ; negative → clamp to 2
    BNE vi1_ok                ; hi byte > 0 → >= 256 > 2
    LDA zp_vi1
    CMP #2
    BCS vi1_ok
.vi1_set2
    LDA #2 : STA zp_vi1
    LDA #0 : STA zp_vi1+1
.vi1_ok
    RTS
}

    ; Old rotation code removed — keeping just a marker
; ======================================================================
.near_clip
{
    ; Check if both behind: vy1 < 1 AND vy2 < 1
    ; s16 comparison: vy < 1 means vy <= 0
    LDA zp_vy1+1
    BMI v1_behind         ; negative → behind
    BNE v1_front          ; positive hi byte → vy >= 256 → front
    LDA zp_vy1
    BEQ v1_behind         ; vy == 0 → behind
    JMP v1_front          ; vy >= 1 → front
.v1_behind
    ; Check v2
    LDA zp_vy2+1
    BMI both_behind
    BEQ v1b_check_v2lo
    JMP v2_front_v1_behind
.v1b_check_v2lo
    LDA zp_vy2
    BEQ both_behind
    JMP v2_front_v1_behind

.both_behind
    SEC                   ; signal: clipped away
    RTS

.v1_front
    ; v1 is in front. Check v2.
    LDA zp_vy2+1
    BMI v1_front_v2_behind
    BNE both_front
    LDA zp_vy2
    BEQ v1_front_v2_behind
.both_front
    ; Both in front — no clip needed
    LDA zp_vx1 : STA zp_ex1
    LDA zp_vx1+1 : STA zp_ex1+1
    LDA zp_vy1 : STA zp_ey1
    LDA zp_vy1+1 : STA zp_ey1+1
    LDA zp_vx2 : STA zp_ex2
    LDA zp_vx2+1 : STA zp_ex2+1
    LDA zp_vy2 : STA zp_ey2
    LDA zp_vy2+1 : STA zp_ey2+1
    CLC
    RTS

.v1_front_v2_behind
    ; Clip v2 to near plane. v1 passes through.
    LDA zp_vx1 : STA zp_ex1
    LDA zp_vx1+1 : STA zp_ex1+1
    LDA zp_vy1 : STA zp_ey1
    LDA zp_vy1+1 : STA zp_ey1+1
    ; ey2 = NEAR_FP = 1
    LDA #NEAR_FP : STA zp_ey2
    LDA #0 : STA zp_ey2+1
    ; ex2 = vx2 + (vx1 - vx2) * t where t = (NEAR - vy2) / (vy1 - vy2)
    ; For now, compute with integer division
    ; t_num = NEAR_FP - vy2 (positive since vy2 < NEAR_FP)
    ; t_den = vy1 - vy2 (positive since vy1 >= NEAR_FP > vy2)
    ; t = (t_num * 256) / t_den (0.8 format, 0..255)
    ; ex2 = vx2 + ((vx1 - vx2) * t + 128) >> 8

    ; t_num = 1 - vy2 (s16)
    LDA #NEAR_FP
    SEC
    SBC zp_vy2
    STA &70
    LDA #0
    SBC zp_vy2+1
    STA &71              ; t_num (s16, positive)

    ; t_den = vy1 - vy2
    LDA zp_vy1
    SEC
    SBC zp_vy2
    STA &72
    LDA zp_vy1+1
    SBC zp_vy2+1
    STA &73              ; t_den (s16, positive)

    ; t = (t_num << 8) / t_den → u8 in 0.8 format
    ; Shift t_num left 8: hi = t_num_lo, lo = 0
    LDA &70
    STA &71
    LDA #0
    STA &70
    ; Now divide $71:$70 (u16) by $73:$72 (u16) → 8-bit result
    JSR div16_8           ; result in A
    STA &74              ; t (0..255)

    ; dvx = vx1 - vx2 (s16)
    LDA zp_vx1
    SEC
    SBC zp_vx2
    STA &75
    LDA zp_vx1+1
    SBC zp_vx2+1
    STA &76              ; dvx (s16)

    ; ex2 = vx2 + (dvx * t + 128) >> 8
    ; dvx * t: s16 × u8 (t is 0..255)
    ; Use the mul_s16_u8 approach
    LDA &74              ; t
    STA zp_math_b
    LDA &75              ; dvx_lo
    JSR umul8x8
    STA &78              ; (dvx_lo * t) hi
    LDA zp_res_lo
    STA &77              ; (dvx_lo * t) lo
    LDA &74
    STA zp_math_b
    LDA &76              ; dvx_hi
    JSR smul8x8
    ; Add res_lo to $78
    LDA &78
    CLC
    ADC zp_res_lo
    STA &78
    ; dvx * t in $78:$77 (16-bit, but really middle 16 of 24-bit)
    ; Actually $77 is the fractional part, $78 is the integer part
    ; (dvx * t + 128) >> 8 = ($78:$77 + 128) >> 8 = add 128 to $77, take $78
    LDA &77
    CLC
    ADC #128
    LDA &78
    ADC #0
    ; sign-extend A into X: test N flag from ADC before LDX clobbers it
    BMI nc_dvx_neg
    LDX #0
    JMP nc_dvx_sedone
.nc_dvx_neg
    LDX #&FF
.nc_dvx_sedone
    ; ex2 = vx2 + A:X(extended)
    CLC
    ADC zp_vx2
    STA zp_ex2
    TXA
    ADC zp_vx2+1
    STA zp_ex2+1
    CLC                   ; visible
    RTS

.v2_front_v1_behind
    ; Clip v1 to near plane. v2 passes through.
    LDA zp_vx2 : STA zp_ex2
    LDA zp_vx2+1 : STA zp_ex2+1
    LDA zp_vy2 : STA zp_ey2
    LDA zp_vy2+1 : STA zp_ey2+1
    LDA #NEAR_FP : STA zp_ey1
    LDA #0 : STA zp_ey1+1

    ; t_num = 1 - vy1
    LDA #NEAR_FP
    SEC
    SBC zp_vy1
    STA &70
    LDA #0
    SBC zp_vy1+1
    STA &71

    ; t_den = vy2 - vy1
    LDA zp_vy2
    SEC
    SBC zp_vy1
    STA &72
    LDA zp_vy2+1
    SBC zp_vy1+1
    STA &73

    LDA &70 : STA &71
    LDA #0 : STA &70
    JSR div16_8
    STA &74              ; t

    ; dvx = vx2 - vx1
    LDA zp_vx2
    SEC
    SBC zp_vx1
    STA &75
    LDA zp_vx2+1
    SBC zp_vx1+1
    STA &76

    LDA &74 : STA zp_math_b
    LDA &75 : JSR umul8x8
    STA &78 : LDA zp_res_lo : STA &77
    LDA &74 : STA zp_math_b
    LDA &76 : JSR smul8x8
    LDA &78 : CLC : ADC zp_res_lo : STA &78
    LDA &77 : CLC : ADC #128
    LDA &78 : ADC #0
    BMI nc2_neg
    LDX #0
    JMP nc2_pos
.nc2_neg
    LDX #&FF
.nc2_pos
    CLC
    ADC zp_vx1
    STA zp_ex1
    TXA
    ADC zp_vx1+1
    STA zp_ex1+1
    CLC
    RTS
}

; ======================================================================
; DIV16_8: unsigned 16/16 → 8-bit quotient
; Input: $71:$70 (dividend), $73:$72 (divisor)
; Output: A = quotient (0..255)
; ======================================================================
.div16_8
{
    LDA #0
    STA &7E               ; remainder lo
    STA &7F               ; remainder hi
    LDX #16               ; 16 iterations for 16-bit dividend
.loop
    ; Shift dividend left, MSB into remainder
    ASL &70
    ROL &71
    ROL &7E
    ROL &7F
    ; Compare remainder >= divisor
    LDA &7E
    CMP &72
    LDA &7F
    SBC &73
    BCC no_sub
    ; Subtract divisor from remainder
    LDA &7E
    SEC
    SBC &72
    STA &7E
    LDA &7F
    SBC &73
    STA &7F
    ; Set bit 0 of quotient (in dividend)
    INC &70
.no_sub
    DEX
    BNE loop
    LDA &70               ; quotient
    RTS
}

; ======================================================================
; RECIPROCAL AND PROJECT X (endpoint 1)
; Input: zp_ex1, zp_ey1, zp_vy1, zp_vi1
; Output: zp_sx1, zp_rxh, zp_rxl (reciprocal saved for Y projection)
; ======================================================================
; ======================================================================
; RECIP_LOOKUP: look up reciprocal with averaging
; Input: $70:$71 = integer table index (i), A = averaging flag (0 or 1)
; Output: zp_rxh, zp_rxl = reciprocal (averaged if flag set)
; Clobbers: A, Y, $83, $84, zp_ptr0
; ======================================================================
.recip_lookup
{
    PHA                       ; save averaging flag

    ; --- Fast path for i < 256 (common case): use absolute-indexed addressing ---
    LDA &71
    BNE rl_slow_body          ; i >= 256 → slow path
    LDX &70
    LDA recip_hi_tbl,X : STA zp_rxh
    LDA recip_lo_tbl,X : STA zp_rxl
    PLA                        ; avg flag
    BEQ rl_fast_done
    ; Fast-path averaging: need entry (i+1). If i=255, i+1=256 which is out
    ; of the fast-path range (would wrap X). Fall back to slow path for that.
    CPX #255
    BEQ rl_slow_avg_restore
    INX
    LDA recip_hi_tbl,X : STA &83
    LDA recip_lo_tbl,X : STA &84
    LDA zp_rxl : CLC : ADC &84 : STA zp_rxl
    LDA zp_rxh : ADC &83 : STA zp_rxh
    ROR zp_rxh : ROR zp_rxl
.rl_fast_done
    RTS

.rl_slow_avg_restore
    LDA #1 : PHA              ; re-push avg flag for slow path

.rl_slow_body
    ; --- Slow path: pointer setup + indirect lookups (handles i >= 256) ---
    ; Read rxh[i]
    LDA &70
    CLC
    ADC #LO(recip_hi_tbl)
    STA zp_ptr0
    LDA &71
    ADC #HI(recip_hi_tbl)
    STA zp_ptr0+1
    LDY #0
    LDA (zp_ptr0),Y
    STA zp_rxh
    ; Read rxl[i]
    LDA &70
    CLC
    ADC #LO(recip_lo_tbl)
    STA zp_ptr0
    LDA &71
    ADC #HI(recip_lo_tbl)
    STA zp_ptr0+1
    LDA (zp_ptr0),Y
    STA zp_rxl

    ; Check averaging flag
    PLA
    BEQ rl_done

    ; Average with table[i+1]
    INC &70
    BNE rl_no_carry
    INC &71
.rl_no_carry
    ; Read rxh[i+1]
    LDA &70
    CLC
    ADC #LO(recip_hi_tbl)
    STA zp_ptr0
    LDA &71
    ADC #HI(recip_hi_tbl)
    STA zp_ptr0+1
    LDY #0
    LDA (zp_ptr0),Y
    STA &83                   ; rxh2
    ; Read rxl[i+1]
    LDA &70
    CLC
    ADC #LO(recip_lo_tbl)
    STA zp_ptr0
    LDA &71
    ADC #HI(recip_lo_tbl)
    STA zp_ptr0+1
    LDA (zp_ptr0),Y
    STA &84                   ; rxl2

    ; sum = rxh:rxl + rxh2:rxl2 (17-bit, carry is bit 16)
    LDA zp_rxl
    CLC
    ADC &84
    STA zp_rxl
    LDA zp_rxh
    ADC &83
    STA zp_rxh
    ; Carry from ADC is bit 16 of sum. Shift 17-bit right by 1:
    ; ROR zp_rxh: carry → bit 7, bit 0 → carry
    ; ROR zp_rxl: carry → bit 7, bit 0 → discarded
    ROR zp_rxh
    ROR zp_rxl
.rl_done
    RTS
}

; ======================================================================
; MUL_S16_U8_S24: ex (s16) × b (u8) → s24 in $70:$71:$72
; Input: zp_tmp2 = ex (s16), zp_math_b = b (u8)
; Output: $70 = lo, $71 = mid, $72 = hi
; Clobbers: A, X, Y, $70-$72, $7D, math_a, res_lo, res_hi
; ======================================================================
.mul_s16_u8_s24
{
    ; Calling convention: A = b (multiplicand), zp_tmp2 = ex (s16 multiplier).
    ; We save A to zp_math_b ourselves so callers don't need to.
    STA zp_math_b
    ; === Inlined umul8x8(ex_lo, b) directly into $70:$71 ===
    ; Overflow path is rare — put its JMP there instead of the common path.
    LDA zp_tmp2               ; ex_lo
    TAX
    SEC
    SBC zp_math_b
    BCS mu_diff_pos
    EOR #&FF
    ADC #1                    ; C=0 from failed BCS, so ADC is +1
.mu_diff_pos
    TAY                       ; Y = |ex_lo - b|
    TXA
    CLC
    ADC zp_math_b
    TAX
    BCS mu_sum_ovf
    SEC
    LDA sqr_lo,X
    SBC sqr_lo,Y
    STA &70
    LDA sqr_hi,X
    SBC sqr_hi,Y
    STA &71
    ; ======================================================
    ; Fast paths: if ex_hi is 0 or $FF (ex fits in s8), skip second multiply.
    ; Inline fast_pos (ex_hi==0) on the normal path — it's the hottest case.
    LDA zp_tmp2+1
    BNE m16u8_not_fast_pos
    LDA #0
    STA &72
    RTS
.m16u8_not_fast_pos
    CMP #&FF
    BEQ m16u8_fast_neg
    JMP m16u8_wide

.mu_sum_ovf
    SEC
    LDA sqr2_lo,X
    SBC sqr_lo,Y
    STA &70
    LDA sqr2_hi,X
    SBC sqr_hi,Y
    STA &71
    LDA zp_tmp2+1
    BEQ m16u8_fast_pos
    CMP #&FF
    BEQ m16u8_fast_neg
    ; fall through to wide path

.m16u8_wide

    ; ---- Wide path: ex doesn't fit in s8 ----
    ; (rare: only when height/delta exceeds s8 range)
    LDA zp_tmp2+1             ; ex_hi (signed)
    JSR smul8x8               ; zp_math_b preserved by smul8x8
    LDA &71
    CLC
    ADC zp_res_lo
    STA &71
    LDA zp_res_hi
    ADC #0
    STA &72

    ; Correction for b > 127 (smul8x8 sees b_signed = b - 256)
    LDA zp_math_b
    BPL m16u8_done
    LDA &72
    CLC
    ADC zp_tmp2+1             ; add ex_hi
    STA &72
.m16u8_done
    RTS

.m16u8_fast_pos
    ; ex_hi = 0.  byte2 = 0 (no correction needed).
    LDA #0
    STA &72
    RTS

.m16u8_fast_neg
    ; ex_hi = $FF (ex in -256..-1).  byte1 -= b, byte2 = 0 or $FF.
    LDA &71
    SEC
    SBC zp_math_b              ; byte1 -= b
    STA &71
    LDA #0
    SBC #0                     ; 0 - 0 - (1-C) = 0 or $FF
    STA &72
    RTS
}

; ======================================================================
; RECIP_AND_PROJECT_X1
; Input: zp_ex1, zp_ey1, zp_vy1, zp_vi1
; Output: zp_sx1, zp_rxh, zp_rxl (saved for Y projection)
; ======================================================================
.recip_and_project_x1
{
    ; Determine table index and averaging flag
    LDA zp_ey1
    CMP zp_vy1
    BNE use_ey1
    LDA zp_ey1+1
    CMP zp_vy1+1
    BNE use_ey1
    ; vi1 path: i = vi1 >> 1, avg = vi1 & 1
    LDA zp_vi1
    AND #1
    STA &85                   ; averaging flag
    LDA zp_vi1+1
    LSR A
    STA &71
    LDA zp_vi1
    ROR A
    STA &70
    JMP do_lookup
.use_ey1
    ; ey1 path: i = ey1, avg = 0
    LDA #0
    STA &85
    LDA zp_ey1
    STA &70
    LDA zp_ey1+1
    STA &71
.do_lookup
    LDA &85
    JSR recip_lookup

    ; Copy ex1 to tmp2 for mul_s16_u8_s24
    LDA zp_ex1 : STA zp_tmp2
    LDA zp_ex1+1 : STA zp_tmp2+1

    ; term1 = ex1 * rxh → $70:$71:$72
    LDA zp_rxh
    JSR mul_s16_u8_s24
    ; Save term1 to $80:$81:$82
    LDA &70 : STA &80
    LDA &71 : STA &81
    LDA &72 : STA &82

    ; raw = ex1 * rxl → $70:$71:$72
    LDA zp_rxl
    JSR mul_s16_u8_s24
    ; Fused add: total = term1 ($80:$82) + (raw >> 8)
    ; where raw = $70:$72, so raw_shifted byte-wise:
    ;   lo = $71,  mid = $72,  hi = sign_ext($72)
    ; Extract sign of raw_hi into X first (so overwriting &72 is safe).
    LDA &72
    BPL rpx1_raw_pos
    LDX #&FF
    JMP rpx1_raw_sdone
.rpx1_raw_pos
    LDX #0
.rpx1_raw_sdone
    LDA &80 : CLC : ADC &71 : STA &70
    LDA &81 : ADC &72 : STA &71
    TXA : ADC &82 : STA &72

    ; Add HALF_W (128) to $70:$71:$72
    LDA &70
    CLC
    ADC #HALF_W
    STA &70
    LDA &71
    ADC #0
    STA &71
    LDA &72
    ADC #0
    STA &72

    ; Extract sx1 as s16 (low 16 bits, $70:$71)
    LDA &70 : STA zp_sx1
    LDA &71 : STA zp_sx1+1
    RTS
}

; ======================================================================
; RECIP_AND_PROJECT_X2: same for endpoint 2
; ======================================================================
.recip_and_project_x2
{
    LDA zp_ey2
    CMP zp_vy2
    BNE rpx2_use_ey
    LDA zp_ey2+1
    CMP zp_vy2+1
    BNE rpx2_use_ey
    LDA zp_vi2
    AND #1
    STA &85
    LDA zp_vi2+1
    LSR A
    STA &71
    LDA zp_vi2
    ROR A
    STA &70
    JMP rpx2_lookup
.rpx2_use_ey
    LDA #0
    STA &85
    LDA zp_ey2
    STA &70
    LDA zp_ey2+1
    STA &71
.rpx2_lookup
    LDA &85
    JSR recip_lookup

    LDA zp_ex2 : STA zp_tmp2
    LDA zp_ex2+1 : STA zp_tmp2+1

    LDA zp_rxh
    JSR mul_s16_u8_s24
    LDA &70 : STA &80
    LDA &71 : STA &81
    LDA &72 : STA &82

    LDA zp_rxl
    JSR mul_s16_u8_s24
    ; Fused add: total = term1 + (raw >> 8) — see rpx1 for the trick.
    LDA &72
    BPL rpx2_raw_pos
    LDX #&FF
    JMP rpx2_raw_sdone
.rpx2_raw_pos
    LDX #0
.rpx2_raw_sdone
    LDA &80 : CLC : ADC &71 : STA &70
    LDA &81 : ADC &72 : STA &71
    TXA : ADC &82 : STA &72

    LDA &70
    CLC
    ADC #HALF_W
    STA &70
    LDA &71
    ADC #0
    STA &71
    LDA &72
    ADC #0
    STA &72

    LDA &70 : STA zp_sx2
    LDA &71 : STA zp_sx2+1
    RTS
}

; ======================================================================
; (Old column-bitmap has_gap / mark_solid / has_any_gap code removed —
; visibility now goes through Python FPClipSpans via the span hooks.)

; Bit mask table (single bit) — still used by xform_vertex_cached for
; the vertex-cache valid bitmap.
.bit_masks
    EQUB &01, &02, &04, &08, &10, &20, &40, &80

; ======================================================================
; READ SEG DETAIL + PROJECT Y
; Reads heights from rom_window (bank 1) and projects Y coordinates
; Input: zp_seg_idx, zp_seg_flags, reciprocals already computed
; Output: ft1, fb1, ft2, fb2 (and bt/bb if portal)
; ======================================================================
.read_seg_detail
{
    ; Read fh/ch/bfh/bch directly via zp_seg_det_ptr (saves the copy to ptr0)
    LDY #SD_FH  : LDA (zp_seg_det_ptr),Y : STA &80
    LDY #SD_CH  : LDA (zp_seg_det_ptr),Y : STA &81
    LDY #SD_BFH : LDA (zp_seg_det_ptr),Y : STA &82
    LDY #SD_BCH : LDA (zp_seg_det_ptr),Y : STA &83
    RTS
}

; ======================================================================
; PROJECT_Y_ALL: project all needed Y coordinates
; Uses: $80=fh, $81=ch, $82=bfh, $83=bch, zp_vz_ps, zp_rxh, zp_rxl
; Output: zp_ft1, zp_fb1, zp_ft2, zp_fb2
;         $84-$87: bt1, bt2, bb1, bb2 (if needed)
; ======================================================================
.project_y_all
{
    ; project_y(h, rxh, rxl) = HALF_H - (h * rxh + (h * rxl >> 8))
    ; h is s8 height delta; zp_tmp2 carries it sign-extended to s16.
    ; Reciprocals: $88/$89 = rxh1/rxl1 (endpoint 1), $8A/$8B = rxh2/rxl2.
    ; Heights:     $80=fh, $81=ch, $82=bfh, $83=bch.
    ;
    ; Layout: compute each height delta ONCE, then project for both
    ; endpoints back-to-back using shared tmp2.  Two projections per
    ; delta = saved ~15 cycles per projection re-do.

    ; ===== ft1, ft2 share delta_ch = ch - vz_ps =====
    LDA &81 : SEC : SBC zp_vz_ps : STA zp_tmp2
    BPL py_ch_pos
    LDA #&FF : STA zp_tmp2+1 : JMP py_ch_done
.py_ch_pos
    LDA #0 : STA zp_tmp2+1
.py_ch_done
    ; ft1 using recip1 ($88/$89)
    LDA &88 : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95
    LDA &89 : JSR mul_s16_u8_s24
    LDA &94 : CLC : ADC &71 : STA &70
    LDA &95 : ADC &72 : STA &71
    LDA #HALF_H : SEC : SBC &70 : STA zp_ft1
    LDA #0 : SBC &71 : STA zp_ft1+1
    ; ft2 using recip2 ($8A/$8B) — tmp2 still has delta_ch
    LDA &8A : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95
    LDA &8B : JSR mul_s16_u8_s24
    LDA &94 : CLC : ADC &71 : STA &70
    LDA &95 : ADC &72 : STA &71
    LDA #HALF_H : SEC : SBC &70 : STA zp_ft2
    LDA #0 : SBC &71 : STA zp_ft2+1

    ; ===== fb1, fb2 share delta_fh = fh - vz_ps =====
    LDA &80 : SEC : SBC zp_vz_ps : STA zp_tmp2
    BPL py_fh_pos
    LDA #&FF : STA zp_tmp2+1 : JMP py_fh_done
.py_fh_pos
    LDA #0 : STA zp_tmp2+1
.py_fh_done
    LDA &88 : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95
    LDA &89 : JSR mul_s16_u8_s24
    LDA &94 : CLC : ADC &71 : STA &70
    LDA &95 : ADC &72 : STA &71
    LDA #HALF_H : SEC : SBC &70 : STA zp_fb1
    LDA #0 : SBC &71 : STA zp_fb1+1
    LDA &8A : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95
    LDA &8B : JSR mul_s16_u8_s24
    LDA &94 : CLC : ADC &71 : STA &70
    LDA &95 : ADC &72 : STA &71
    LDA #HALF_H : SEC : SBC &70 : STA zp_fb2
    LDA #0 : SBC &71 : STA zp_fb2+1

    ; ===== Back heights if portal =====
    LDA zp_seg_flags
    AND #SF_SOLID
    BEQ py_do_back
    JMP py_done_final
.py_do_back

    LDA zp_seg_flags
    AND #SF_NEEDBT
    BNE py_do_bt
    JMP py_skip_bt
.py_do_bt
    ; ===== bt1, bt2 share delta_bch = bch - vz_ps =====
    LDA &83 : SEC : SBC zp_vz_ps : STA zp_tmp2
    BPL py_bch_pos
    LDA #&FF : STA zp_tmp2+1 : JMP py_bch_done
.py_bch_pos
    LDA #0 : STA zp_tmp2+1
.py_bch_done
    LDA &88 : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95
    LDA &89 : JSR mul_s16_u8_s24
    LDA &94 : CLC : ADC &71 : STA &70
    LDA &95 : ADC &72 : STA &71
    LDA #HALF_H : SEC : SBC &70 : STA &84
    LDA #0 : SBC &71 : STA &85
    LDA &8A : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95
    LDA &8B : JSR mul_s16_u8_s24
    LDA &94 : CLC : ADC &71 : STA &70
    LDA &95 : ADC &72 : STA &71
    LDA #HALF_H : SEC : SBC &70 : STA &86
    LDA #0 : SBC &71 : STA &87

.py_skip_bt
    LDA zp_seg_flags
    AND #SF_NEEDBB
    BNE py_do_bb
    JMP py_done_final
.py_do_bb
    ; ===== bb1, bb2 share delta_bfh = bfh - vz_ps =====
    LDA &82 : SEC : SBC zp_vz_ps : STA zp_tmp2
    BPL py_bfh_pos
    LDA #&FF : STA zp_tmp2+1 : JMP py_bfh_done
.py_bfh_pos
    LDA #0 : STA zp_tmp2+1
.py_bfh_done
    LDA &88 : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95
    LDA &89 : JSR mul_s16_u8_s24
    LDA &94 : CLC : ADC &71 : STA &70
    LDA &95 : ADC &72 : STA &71
    LDA #HALF_H : SEC : SBC &70 : STA &90
    LDA #0 : SBC &71 : STA &91
    LDA &8A : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95
    LDA &8B : JSR mul_s16_u8_s24
    LDA &94 : CLC : ADC &71 : STA &70
    LDA &95 : ADC &72 : STA &71
    LDA #HALF_H : SEC : SBC &70 : STA &92
    LDA #0 : SBC &71 : STA &93

.py_done_final
    RTS
}

; ======================================================================
; DRAW SOLID LINES — write 4 edges to line peripheral at $FE20-$FE27
; Line 1 (top):    sx1,ft1 -> sx2,ft2
; Line 2 (bottom): sx1,fb1 -> sx2,fb2
; Line 3 (left):   sx1,ft1 -> sx1,fb1
; Line 4 (right):  sx2,ft2 -> sx2,fb2
; ======================================================================
.draw_solid_lines
{
    ; Line 1: top edge  sx1,ft1 -> sx2,ft2
    LDA zp_sx1   : STA LINE_X0_LO
    LDA zp_sx1+1 : STA LINE_X0_HI
    LDA zp_ft1   : STA LINE_Y0_LO
    LDA zp_ft1+1 : STA LINE_Y0_HI
    LDA zp_sx2   : STA LINE_X1_LO
    LDA zp_sx2+1 : STA LINE_X1_HI
    LDA zp_ft2   : STA LINE_Y1_LO
    LDA zp_ft2+1 : STA LINE_Y1_HI : JSR clip_rasterise

    ; Line 2: bottom edge  sx1,fb1 -> sx2,fb2
    LDA zp_sx1   : STA LINE_X0_LO
    LDA zp_sx1+1 : STA LINE_X0_HI
    LDA zp_fb1   : STA LINE_Y0_LO
    LDA zp_fb1+1 : STA LINE_Y0_HI
    LDA zp_sx2   : STA LINE_X1_LO
    LDA zp_sx2+1 : STA LINE_X1_HI
    LDA zp_fb2   : STA LINE_Y1_LO
    LDA zp_fb2+1 : STA LINE_Y1_HI : JSR clip_rasterise

    ; Line 3: left edge  sx1,ft1 -> sx1,fb1
    LDA zp_sx1   : STA LINE_X0_LO
    LDA zp_sx1+1 : STA LINE_X0_HI
    LDA zp_ft1   : STA LINE_Y0_LO
    LDA zp_ft1+1 : STA LINE_Y0_HI
    LDA zp_sx1   : STA LINE_X1_LO
    LDA zp_sx1+1 : STA LINE_X1_HI
    LDA zp_fb1   : STA LINE_Y1_LO
    LDA zp_fb1+1 : STA LINE_Y1_HI : JSR clip_rasterise

    ; Line 4: right edge  sx2,ft2 -> sx2,fb2
    LDA zp_sx2   : STA LINE_X0_LO
    LDA zp_sx2+1 : STA LINE_X0_HI
    LDA zp_ft2   : STA LINE_Y0_LO
    LDA zp_ft2+1 : STA LINE_Y0_HI
    LDA zp_sx2   : STA LINE_X1_LO
    LDA zp_sx2+1 : STA LINE_X1_HI
    LDA zp_fb2   : STA LINE_Y1_LO
    LDA zp_fb2+1 : STA LINE_Y1_HI : JSR clip_rasterise

    RTS
}

; ======================================================================
; DRAW PORTAL LINES — conditional edge drawing via line peripheral
; Implements the same logic as the Python back-end:
;   if need_bt: draw ceiling portal edges (bt1->bt2, ft1->bt1, ft2->bt2,
;               and ft1->ft2 if ch > vz_ps)
;   elif bch > ch: draw ft1->ft2 only
;   if need_bb: draw floor portal edges (bb1->bb2, bb1->fb1, bb2->fb2,
;               and fb1->fb2 if fh < vz_ps)
;   elif bfh < fh: draw fb1->fb2 only
;
; ZP: sx1=$20, sx2=$22, ft1=$24, fb1=$26, ft2=$28, fb2=$2A
; Scratch: bt1=$84/$85, bt2=$86/$87, bb1=$90/$91, bb2=$92/$93
;          bch=$83, bfh=$82, ch=$81, fh=$80, vz_ps=$14
;          seg_flags=$54, SF_NEEDBT=$04, SF_NEEDBB=$08
; ======================================================================
.draw_portal_lines
{
    ; Save $80-$87 → $94-$9B. NJ rasteriser clobbers $80-$87 entirely.
    ; After save: $94=fh, $95=ch, $96=bfh, $97=bch, $98/$99=bt1, $9A/$9B=bt2.
    LDX #7
.spt LDA &80,X : STA &94,X : DEX : BPL spt

    ; --- Ceiling logic ---
    LDA zp_seg_flags
    AND #SF_NEEDBT
    BNE has_need_bt
    JMP no_need_bt
.has_need_bt

    ; need_bt: draw bt1->bt2 (back-ceiling top line)
    LDA zp_sx1   : STA LINE_X0_LO
    LDA zp_sx1+1 : STA LINE_X0_HI
    LDA &98    : STA LINE_Y0_LO      ; bt1 lo (saved)
    LDA &99    : STA LINE_Y0_HI      ; bt1 hi
    LDA zp_sx2   : STA LINE_X1_LO
    LDA zp_sx2+1 : STA LINE_X1_HI
    LDA &9A    : STA LINE_Y1_LO      ; bt2 lo
    LDA &9B    : STA LINE_Y1_HI : JSR clip_rasterise

    ; draw left edge: sx1,ft1 -> sx1,bt1
    LDA zp_sx1   : STA LINE_X0_LO
    LDA zp_sx1+1 : STA LINE_X0_HI
    LDA zp_ft1   : STA LINE_Y0_LO
    LDA zp_ft1+1 : STA LINE_Y0_HI
    LDA zp_sx1   : STA LINE_X1_LO
    LDA zp_sx1+1 : STA LINE_X1_HI
    LDA &98    : STA LINE_Y1_LO      ; bt1 lo (saved)
    LDA &99    : STA LINE_Y1_HI : JSR clip_rasterise

    ; draw right edge: sx2,ft2 -> sx2,bt2
    LDA zp_sx2   : STA LINE_X0_LO
    LDA zp_sx2+1 : STA LINE_X0_HI
    LDA zp_ft2   : STA LINE_Y0_LO
    LDA zp_ft2+1 : STA LINE_Y0_HI
    LDA zp_sx2   : STA LINE_X1_LO
    LDA zp_sx2+1 : STA LINE_X1_HI
    LDA &9A    : STA LINE_Y1_LO      ; bt2 lo (saved)
    LDA &9B    : STA LINE_Y1_HI : JSR clip_rasterise

    ; if ch > vz_ps: also draw ft1->ft2 (front ceiling line)
    LDA &95             ; ch (s8)
    CMP zp_vz_ps        ; compare ch - vz_ps
    BEQ skip_ceil_front  ; ch == vz_ps -> skip
    BMI skip_ceil_front  ; ch < vz_ps -> skip (signed: N set means less)
    ; ch > vz_ps — draw front ceiling line
    JSR draw_ceil_line
.skip_ceil_front
    JMP ceil_done

.no_need_bt
    ; elif bch > ch: draw ft1->ft2 only
    LDA &97             ; bch (s8)
    CMP &95             ; ch (s8)
    BEQ ceil_done
    BMI ceil_done        ; bch <= ch -> skip
    ; bch > ch — draw ceiling line
    JSR draw_ceil_line

.ceil_done

    ; --- Floor logic ---
    LDA zp_seg_flags
    AND #SF_NEEDBB
    BNE has_need_bb
    JMP no_need_bb
.has_need_bb

    ; need_bb: draw bb1->bb2 (back-floor bottom line)
    LDA zp_sx1   : STA LINE_X0_LO
    LDA zp_sx1+1 : STA LINE_X0_HI
    LDA &90    : STA LINE_Y0_LO      ; bb1 lo (saved)
    LDA &91    : STA LINE_Y0_HI
    LDA zp_sx2   : STA LINE_X1_LO
    LDA zp_sx2+1 : STA LINE_X1_HI
    LDA &92    : STA LINE_Y1_LO      ; bb2 lo (saved)
    LDA &93    : STA LINE_Y1_HI : JSR clip_rasterise

    ; draw left edge: sx1,bb1 -> sx1,fb1
    LDA zp_sx1   : STA LINE_X0_LO
    LDA zp_sx1+1 : STA LINE_X0_HI
    LDA &90    : STA LINE_Y0_LO      ; bb1 lo (saved)
    LDA &91    : STA LINE_Y0_HI
    LDA zp_sx1   : STA LINE_X1_LO
    LDA zp_sx1+1 : STA LINE_X1_HI
    LDA zp_fb1   : STA LINE_Y1_LO
    LDA zp_fb1+1 : STA LINE_Y1_HI : JSR clip_rasterise

    ; draw right edge: sx2,bb2 -> sx2,fb2
    LDA zp_sx2   : STA LINE_X0_LO
    LDA zp_sx2+1 : STA LINE_X0_HI
    LDA &92    : STA LINE_Y0_LO      ; bb2 lo (saved)
    LDA &93    : STA LINE_Y0_HI
    LDA zp_sx2   : STA LINE_X1_LO
    LDA zp_sx2+1 : STA LINE_X1_HI
    LDA zp_fb2   : STA LINE_Y1_LO
    LDA zp_fb2+1 : STA LINE_Y1_HI : JSR clip_rasterise

    ; if fh < vz_ps: also draw fb1->fb2 (front floor line)
    LDA &94             ; fh (s8)
    CMP zp_vz_ps        ; compare fh - vz_ps
    BEQ skip_floor_front ; fh == vz_ps -> skip
    BPL skip_floor_front ; fh >= vz_ps -> skip (signed: N clear means >=)
    ; fh < vz_ps — draw front floor line
    JSR draw_floor_line
.skip_floor_front
    JMP floor_done

.no_need_bb
    ; elif bfh < fh: draw fb1->fb2 only
    LDA &96             ; bfh (s8)
    CMP &94             ; fh (s8)
    BEQ floor_done
    BPL floor_done       ; bfh >= fh -> skip
    ; bfh < fh — draw floor line
    JSR draw_floor_line

.floor_done
    RTS

; Helper: draw ceiling line ft1->ft2
.draw_ceil_line
    LDA zp_sx1   : STA LINE_X0_LO
    LDA zp_sx1+1 : STA LINE_X0_HI
    LDA zp_ft1   : STA LINE_Y0_LO
    LDA zp_ft1+1 : STA LINE_Y0_HI
    LDA zp_sx2   : STA LINE_X1_LO
    LDA zp_sx2+1 : STA LINE_X1_HI
    LDA zp_ft2   : STA LINE_Y1_LO
    LDA zp_ft2+1 : STA LINE_Y1_HI : JSR clip_rasterise
    RTS

; Helper: draw floor line fb1->fb2
.draw_floor_line
    LDA zp_sx1   : STA LINE_X0_LO
    LDA zp_sx1+1 : STA LINE_X0_HI
    LDA zp_fb1   : STA LINE_Y0_LO
    LDA zp_fb1+1 : STA LINE_Y0_HI
    LDA zp_sx2   : STA LINE_X1_LO
    LDA zp_sx2+1 : STA LINE_X1_HI
    LDA zp_fb2   : STA LINE_Y1_LO
    LDA zp_fb2+1 : STA LINE_Y1_HI : JSR clip_rasterise
    RTS
}

; ======================================================================
; RASTERISE_LINE: read s16 coords from ZP $A0-$A7, reject off-screen,
; call NJ rasteriser in bank 2 to plot pixels in the screen buffer.
; On py65 the write to $A7 already triggers the Python rasteriser via
; (rasterise_line removed — replaced by clip_rasterise + bank 2 clipper)

KEY_Z = &61 : KEY_X = &42 : KEY_K = &46 : KEY_M = &65 : TURN_SPEED = 4

.game_loop
    LDA &70 : STA &02F8    ; save back buffer hi (mul16x16 clobbers $70)
    JSR entry               ; render to back buffer

    ; Wait for vsync, present back buffer, swap $70 for next frame
    LDA #2 : STA &FE30
    JSR vsync_and_flip
    LDA #0 : STA &FE30

    ; --- Keyboard: direct VIA scan ---
    ; bit 7 = 0 = pressed, 1 = not pressed
    LDA #KEY_Z : JSR scan_key : BMI gl_no_z
    LDA zp_angle : SEC : SBC #TURN_SPEED : STA zp_angle
.gl_no_z
    LDA #KEY_X : JSR scan_key : BMI gl_no_x
    LDA zp_angle : CLC : ADC #TURN_SPEED : STA zp_angle
.gl_no_x
    LDA #KEY_K : JSR scan_key : BMI gl_no_k
    JSR gl_move_fwd
.gl_no_k
    LDA #KEY_M : JSR scan_key : BMI gl_no_m
    JSR gl_move_back
.gl_no_m

    JMP game_loop

; Key scan helper: A=key code → flags reflect bit 7 (BMI = not pressed)
.scan_key
    STA &FE4F : LDA &FE4F : RTS

; --- Movement: unified fwd/back via direction flag at &40 ---
; &40 = 0 for forward, 1 for backward
.gl_move_fwd
    LDA #1 : STA &40 : JMP gl_move
.gl_move_back
    LDA #0 : STA &40
.gl_move
{
    ; dx (wx) from cos, dy (wy) from sin — DOOM: angle 0=North(+Y), 64=East(+X)
    LDA zp_cos_unity : BEQ mv_cos_normal
    LDA #128 : JMP mv_cos_got
.mv_cos_normal
    LDA zp_cos_mag
.mv_cos_got
    LSR A : TAX : BEQ mv_skip_x
    LDA zp_cos_neg : EOR &40 : BNE mv_sub_x
    TXA : CLC : ADC zp_wx : STA zp_wx : LDA zp_wx+1 : ADC #0 : STA zp_wx+1 : JMP mv_skip_x
.mv_sub_x
    STX &41 : LDA zp_wx : SEC : SBC &41 : STA zp_wx : LDA zp_wx+1 : SBC #0 : STA zp_wx+1
.mv_skip_x
    LDA zp_sin_unity : BEQ mv_sin_normal
    LDA #128 : JMP mv_sin_got
.mv_sin_normal
    LDA zp_sin_mag
.mv_sin_got
    LSR A : TAX : BEQ mv_skip_y
    LDA zp_sin_neg : EOR &40 : BNE mv_sub_y
    TXA : CLC : ADC zp_wy : STA zp_wy : LDA zp_wy+1 : ADC #0 : STA zp_wy+1 : JMP mv_skip_y
.mv_sub_y
    STX &41 : LDA zp_wy : SEC : SBC &41 : STA zp_wy : LDA zp_wy+1 : SBC #0 : STA zp_wy+1
.mv_skip_y
}

; Recompute px/py from wx/wy: px_88 = wx << 5 (prescale=8)
.gl_recompute
{
    ; px_88 = wx << 5
    LDA zp_wx : STA &40 : LDA zp_wx+1 : STA &41
    LDX #5
.sh_px ASL &40 : ROL &41 : DEX : BNE sh_px
    LDA &40 : STA zp_px_lo : LDA &41 : STA zp_px_int
    BPL rp_px_pos : LDA #&FF : STA zp_px_int_hi : JMP rp_py
.rp_px_pos LDA #0 : STA zp_px_int_hi
.rp_py
    ; py_88 = wy << 5
    LDA zp_wy : STA &40 : LDA zp_wy+1 : STA &41
    LDX #5
.sh_py ASL &40 : ROL &41 : DEX : BNE sh_py
    LDA &40 : STA zp_py_lo : LDA &41 : STA zp_py_int
    BPL rp_py_pos : LDA #&FF : STA zp_py_int_hi : RTS
.rp_py_pos LDA #0 : STA zp_py_int_hi : RTS
}

; ======================================================================
; MATH: smul8x8 — Signed 8×8 → 16-bit multiply (quarter-square)
; Input: A = signed multiplier, zp_math_b = signed multiplicand
; Output: zp_res_lo:zp_res_hi, A = res_hi
; ======================================================================
.smul8x8
{
    ; Zero fast-path: if A==0, product is 0 regardless of b.
    ; The caller's LDA before JSR leaves the Z flag intact through JSR.
    BEQ smul_zero
    STA zp_math_a
    TAX
    SEC
    SBC zp_math_b
    BCS diff_pos
    EOR #&FF
    ADC #1
.diff_pos
    TAY                   ; Y = |a - b|

    TXA
    CLC
    ADC zp_math_b
    TAX
    BCC no_ovf

    SEC
    LDA sqr2_lo,X
    SBC sqr_lo,Y
    STA zp_res_lo
    LDA sqr2_hi,X
    SBC sqr_hi,Y
    JMP sign_correct

.no_ovf
    SEC
    LDA sqr_lo,X
    SBC sqr_lo,Y
    STA zp_res_lo
    LDA sqr_hi,X
    SBC sqr_hi,Y

.sign_correct
    LDX zp_math_a
    BPL a_pos
    SBC zp_math_b
.a_pos
    LDX zp_math_b
    BPL done
    SEC
    SBC zp_math_a
.done
    STA zp_res_hi
    RTS
.smul_zero
    STA zp_res_lo         ; A=0
    STA zp_res_hi         ; A=0
    RTS
}

; ======================================================================
; MATH: umul8x8 — Unsigned 8×8 → 16-bit multiply (quarter-square)
; Input: A = unsigned multiplier, zp_math_b = unsigned multiplicand
; Output: zp_res_lo:zp_res_hi, A = res_hi
; ======================================================================
.umul8x8
{
    ; Zero fast-path: if A==0, product is 0.
    BEQ umul_zero
    TAX
    SEC
    SBC zp_math_b
    BCS diff_pos
    EOR #&FF
    ADC #1
.diff_pos
    TAY

    TXA
    CLC
    ADC zp_math_b
    TAX
    BCS sum_overflow

    SEC
    LDA sqr_lo,X
    SBC sqr_lo,Y
    STA zp_res_lo
    LDA sqr_hi,X
    SBC sqr_hi,Y
    STA zp_res_hi
    RTS

.sum_overflow
    SEC
    LDA sqr2_lo,X
    SBC sqr_lo,Y
    STA zp_res_lo
    LDA sqr2_hi,X
    SBC sqr_hi,Y
    STA zp_res_hi
    RTS
.umul_zero
    STA zp_res_lo         ; A=0
    STA zp_res_hi         ; A=0
    RTS
}

; ======================================================================
; BBOX_CULL_NATIVE: Project a node's far-side bbox to screen X range
; and test has_gap.  Replaces the Python spans_bbox_cull hook.
;
; Input:  A = far_side (0 or 1), zp_tmp0 = nid (u16)
; Output: C=1 if visible (has_gap), C=0 if not visible
; Must preserve: zp_tmp0 (caller needs nid for get_child)
;
; Scratch ZP used:
;   $80-$87: bbox data (top, bot, left, right as s16)
;   $A0-$B7: corner view-space data (4 corners × 6 bytes)
;   $B8:$B9: saved nid
;   $BA:$BB: min_sx (s16)
;   $BC:$BD: max_sx (s16)
;   $BE:     saved far_side
; ======================================================================

; Bbox table offsets within 16-byte bbox record (in ROM bank 2)
BB_BBOX_R = 0             ; right-side bbox at +0
BB_BBOX_L = 8             ; left-side bbox at +8

; Corner storage layout in ZP
bb_c0_vx = &A0            ; corner 0: (left, top)
bb_c0_vy = &A2
bb_c0_vi = &A4
bb_c1_vx = &A6            ; corner 1: (right, top)
bb_c1_vy = &A8
bb_c1_vi = &AA
bb_c2_vx = &AC            ; corner 2: (right, bot)
bb_c2_vy = &AE
bb_c2_vi = &B0
bb_c3_vx = &B2            ; corner 3: (left, bot)
bb_c3_vy = &B4
bb_c3_vi = &B6

bb_save_nid = &B8         ; saved nid (2 bytes)
bb_min_sx   = &BA         ; min screen x (s16)
bb_max_sx   = &BC         ; max screen x (s16)
bb_far_side = &BE         ; saved far_side

.bbox_cull_native
{
    ; ---- Save far_side and nid ----
    STA bb_far_side
    LDA zp_tmp0   : STA bb_save_nid
    LDA zp_tmp0+1 : STA bb_save_nid+1

    ; ---- Switch to ROM bank 2 (bbox table) ----
    JSR select_bank_2

    ; ---- Compute bbox address: rom_window + nid * 16 ----
    ; nid * 16 = nid << 4
    LDA zp_tmp0
    ASL A
    STA zp_ptr0
    LDA zp_tmp0+1
    ROL A
    STA zp_ptr0+1            ; × 2
    ASL zp_ptr0
    ROL zp_ptr0+1            ; × 4
    ASL zp_ptr0
    ROL zp_ptr0+1            ; × 8
    ASL zp_ptr0
    ROL zp_ptr0+1            ; × 16
    ; Add rom_window base
    LDA zp_ptr0
    CLC
    ADC #LO(rom_window)
    STA zp_ptr0
    LDA zp_ptr0+1
    ADC #HI(rom_window)
    STA zp_ptr0+1
    ; zp_ptr0 now points to the bbox record for this node in bank 2

    ; ---- Compute bbox offset: far_side==0 → +0, far_side==1 → +8 ----
    LDA bb_far_side
    BEQ bb_side_right
    LDY #BB_BBOX_L            ; left bbox at offset 8
    JMP bb_read_bbox
.bb_side_right
    LDY #BB_BBOX_R            ; right bbox at offset 0

.bb_read_bbox
    ; Read 8 bytes (top, bot, left, right as s16) into $80-$87
    LDA (zp_ptr0),Y : STA &80 : INY   ; top lo
    LDA (zp_ptr0),Y : STA &81 : INY   ; top hi
    LDA (zp_ptr0),Y : STA &82 : INY   ; bot lo
    LDA (zp_ptr0),Y : STA &83 : INY   ; bot hi
    LDA (zp_ptr0),Y : STA &84 : INY   ; left lo
    LDA (zp_ptr0),Y : STA &85 : INY   ; left hi
    LDA (zp_ptr0),Y : STA &86 : INY   ; right lo
    LDA (zp_ptr0),Y : STA &87         ; right hi

    ; ---- Switch back to ROM bank 0 ----
    JSR select_bank_0

    ; ================================================================
    ; Trivial inside test: left <= px_int <= right AND bot <= py_int <= top
    ; Player position: zp_px_int ($10) s8, zp_px_int_hi ($04) sign ext
    ; Bbox values: s16 prescaled
    ; ================================================================

    ; --- Test: left ($84:$85) <= px_int ($10:$04) ---
    ; px_int - left >= 0 ?
    SEC
    LDA zp_px_int
    SBC &84
    LDA zp_px_int_hi
    SBC &85
    BVC bb_nov1
    EOR #&80
.bb_nov1
    BMI bb_not_inside          ; px_int < left

    ; --- Test: px_int ($10:$04) <= right ($86:$87) ---
    ; right - px_int >= 0 ?
    SEC
    LDA &86
    SBC zp_px_int
    LDA &87
    SBC zp_px_int_hi
    BVC bb_nov2
    EOR #&80
.bb_nov2
    BMI bb_not_inside          ; px_int > right

    ; --- Test: bot ($82:$83) <= py_int ($11:$05) ---
    ; py_int - bot >= 0 ?
    SEC
    LDA zp_py_int
    SBC &82
    LDA zp_py_int_hi
    SBC &83
    BVC bb_nov3
    EOR #&80
.bb_nov3
    BMI bb_not_inside          ; py_int < bot

    ; --- Test: py_int ($11:$05) <= top ($80:$81) ---
    ; top - py_int >= 0 ?
    SEC
    LDA &80
    SBC zp_py_int
    LDA &81
    SBC zp_py_int_hi
    BVC bb_nov4
    EOR #&80
.bb_nov4
    BMI bb_not_inside          ; py_int > top

    ; Player is inside bbox → visible, full screen range
    LDA #0
    STA zp_x_lo_clip
    STA zp_x_lo_clip+1
    LDA #255
    STA zp_x_hi_clip
    LDA #0
    STA zp_x_hi_clip+1
    JMP bb_call_has_gap

.bb_not_inside

    ; ================================================================
    ; Transform 4 bbox corners to view space via to_view
    ; Corners: (left,top), (right,top), (right,bot), (left,bot)
    ; to_view input: zp_tmp2 = wx (s16), zp_tmp3 = wy (s16)
    ; to_view output: zp_vx1 ($30:$31), zp_vy1 ($32:$33), zp_vi1 ($34:$35)
    ; to_view clobbers: $70-$7C, $94-$99, zp_tmp2, zp_tmp3
    ; ================================================================

    ; ---- Corner 0: (left, top) ----
    LDA &84 : STA zp_tmp2       ; wx = left lo
    LDA &85 : STA zp_tmp2+1     ; wx = left hi
    LDA &80 : STA zp_tmp3       ; wy = top lo
    LDA &81 : STA zp_tmp3+1     ; wy = top hi
    JSR to_view
    LDA zp_vx1   : STA bb_c0_vx
    LDA zp_vx1+1 : STA bb_c0_vx+1
    LDA zp_vy1   : STA bb_c0_vy
    LDA zp_vy1+1 : STA bb_c0_vy+1
    LDA zp_vi1   : STA bb_c0_vi
    LDA zp_vi1+1 : STA bb_c0_vi+1

    ; ---- Corner 1: (right, top) ----
    LDA &86 : STA zp_tmp2       ; wx = right lo
    LDA &87 : STA zp_tmp2+1     ; wx = right hi
    LDA &80 : STA zp_tmp3       ; wy = top lo
    LDA &81 : STA zp_tmp3+1     ; wy = top hi
    JSR to_view
    LDA zp_vx1   : STA bb_c1_vx
    LDA zp_vx1+1 : STA bb_c1_vx+1
    LDA zp_vy1   : STA bb_c1_vy
    LDA zp_vy1+1 : STA bb_c1_vy+1
    LDA zp_vi1   : STA bb_c1_vi
    LDA zp_vi1+1 : STA bb_c1_vi+1

    ; ---- Corner 2: (right, bot) ----
    LDA &86 : STA zp_tmp2       ; wx = right lo
    LDA &87 : STA zp_tmp2+1     ; wx = right hi
    LDA &82 : STA zp_tmp3       ; wy = bot lo
    LDA &83 : STA zp_tmp3+1     ; wy = bot hi
    JSR to_view
    LDA zp_vx1   : STA bb_c2_vx
    LDA zp_vx1+1 : STA bb_c2_vx+1
    LDA zp_vy1   : STA bb_c2_vy
    LDA zp_vy1+1 : STA bb_c2_vy+1
    LDA zp_vi1   : STA bb_c2_vi
    LDA zp_vi1+1 : STA bb_c2_vi+1

    ; ---- Corner 3: (left, bot) ----
    LDA &84 : STA zp_tmp2       ; wx = left lo
    LDA &85 : STA zp_tmp2+1     ; wx = left hi
    LDA &82 : STA zp_tmp3       ; wy = bot lo
    LDA &83 : STA zp_tmp3+1     ; wy = bot hi
    JSR to_view
    LDA zp_vx1   : STA bb_c3_vx
    LDA zp_vx1+1 : STA bb_c3_vx+1
    LDA zp_vy1   : STA bb_c3_vy
    LDA zp_vy1+1 : STA bb_c3_vy+1
    LDA zp_vi1   : STA bb_c3_vi
    LDA zp_vi1+1 : STA bb_c3_vi+1

    ; ================================================================
    ; All-behind check: if all 4 vy < NEAR_FP (=1), not visible
    ; vy is s16.  vy < 1 means vy_hi < 0, OR (vy_hi == 0 AND vy_lo == 0)
    ; i.e. vy <= 0 in integer terms.  Actually NEAR_FP=1 so vy < 1 means vy <= 0.
    ; For s16: vy < 1 iff vy_hi < 0 (negative) OR (vy_hi == 0 AND vy_lo == 0).
    ; ================================================================

    ; Check corner 0 vy
    LDA bb_c0_vy+1
    BMI bb_c0_behind           ; vy_hi < 0 → behind
    BNE bb_not_all_behind      ; vy_hi > 0 → vy >= 256, in front
    LDA bb_c0_vy
    BNE bb_not_all_behind      ; vy_lo > 0, vy_hi == 0 → vy >= 1
.bb_c0_behind

    ; Check corner 1 vy
    LDA bb_c1_vy+1
    BMI bb_c1_behind
    BNE bb_not_all_behind
    LDA bb_c1_vy
    BNE bb_not_all_behind
.bb_c1_behind

    ; Check corner 2 vy
    LDA bb_c2_vy+1
    BMI bb_c2_behind
    BNE bb_not_all_behind
    LDA bb_c2_vy
    BNE bb_not_all_behind
.bb_c2_behind

    ; Check corner 3 vy
    LDA bb_c3_vy+1
    BMI bb_c3_behind
    BNE bb_not_all_behind
    LDA bb_c3_vy
    BNE bb_not_all_behind
.bb_c3_behind
    ; All 4 corners are behind → not visible
    JMP bb_not_visible

.bb_not_all_behind

    ; ================================================================
    ; Project visible corners and near-clip edge crossings
    ; Track min_sx and max_sx
    ; ================================================================

    ; Init min_sx = +32767 ($7FFF), max_sx = -32768 ($8000)
    LDA #&FF : STA bb_min_sx
    LDA #&7F : STA bb_min_sx+1
    LDA #&00 : STA bb_max_sx
    LDA #&80 : STA bb_max_sx+1

    ; ================================================================
    ; CORNER 0: project if vy >= NEAR
    ; ================================================================
    LDA bb_c0_vy+1
    BMI bb_c0_skip_proj        ; vy < 0, behind
    BNE bb_c0_do_proj          ; vy >= 256, in front
    LDA bb_c0_vy
    BEQ bb_c0_skip_proj        ; vy == 0, behind (< NEAR=1)
.bb_c0_do_proj
    ; Set up recip_and_project_x1 inputs:
    ; ex1 = vx, ey1 = vy (same as vy1, triggers vi1 path), vi1 = vi
    LDA bb_c0_vx   : STA zp_ex1
    LDA bb_c0_vx+1 : STA zp_ex1+1
    LDA bb_c0_vy   : STA zp_ey1   : STA zp_vy1
    LDA bb_c0_vy+1 : STA zp_ey1+1 : STA zp_vy1+1
    LDA bb_c0_vi   : STA zp_vi1
    LDA bb_c0_vi+1 : STA zp_vi1+1
    JSR recip_and_project_x1
    ; sx1 now in zp_sx1 ($20:$21)
    JSR bb_update_minmax
.bb_c0_skip_proj

    ; ---- Edge 0→1: check near crossing ----
    JSR bb_edge_0_1

    ; ================================================================
    ; CORNER 1: project if vy >= NEAR
    ; ================================================================
    LDA bb_c1_vy+1
    BMI bb_c1_skip_proj
    BNE bb_c1_do_proj
    LDA bb_c1_vy
    BEQ bb_c1_skip_proj
.bb_c1_do_proj
    LDA bb_c1_vx   : STA zp_ex1
    LDA bb_c1_vx+1 : STA zp_ex1+1
    LDA bb_c1_vy   : STA zp_ey1   : STA zp_vy1
    LDA bb_c1_vy+1 : STA zp_ey1+1 : STA zp_vy1+1
    LDA bb_c1_vi   : STA zp_vi1
    LDA bb_c1_vi+1 : STA zp_vi1+1
    JSR recip_and_project_x1
    JSR bb_update_minmax
.bb_c1_skip_proj

    ; ---- Edge 1→2: check near crossing ----
    JSR bb_edge_1_2

    ; ================================================================
    ; CORNER 2: project if vy >= NEAR
    ; ================================================================
    LDA bb_c2_vy+1
    BMI bb_c2_skip_proj
    BNE bb_c2_do_proj
    LDA bb_c2_vy
    BEQ bb_c2_skip_proj
.bb_c2_do_proj
    LDA bb_c2_vx   : STA zp_ex1
    LDA bb_c2_vx+1 : STA zp_ex1+1
    LDA bb_c2_vy   : STA zp_ey1   : STA zp_vy1
    LDA bb_c2_vy+1 : STA zp_ey1+1 : STA zp_vy1+1
    LDA bb_c2_vi   : STA zp_vi1
    LDA bb_c2_vi+1 : STA zp_vi1+1
    JSR recip_and_project_x1
    JSR bb_update_minmax
.bb_c2_skip_proj

    ; ---- Edge 2→3: check near crossing ----
    JSR bb_edge_2_3

    ; ================================================================
    ; CORNER 3: project if vy >= NEAR
    ; ================================================================
    LDA bb_c3_vy+1
    BMI bb_c3_skip_proj
    BNE bb_c3_do_proj
    LDA bb_c3_vy
    BEQ bb_c3_skip_proj
.bb_c3_do_proj
    LDA bb_c3_vx   : STA zp_ex1
    LDA bb_c3_vx+1 : STA zp_ex1+1
    LDA bb_c3_vy   : STA zp_ey1   : STA zp_vy1
    LDA bb_c3_vy+1 : STA zp_ey1+1 : STA zp_vy1+1
    LDA bb_c3_vi   : STA zp_vi1
    LDA bb_c3_vi+1 : STA zp_vi1+1
    JSR recip_and_project_x1
    JSR bb_update_minmax
.bb_c3_skip_proj

    ; ---- Edge 3→0: check near crossing ----
    JSR bb_edge_3_0

    ; ================================================================
    ; Check if any points were projected (min_sx <= max_sx)
    ; If min_sx > max_sx, no projections happened → not visible
    ; ================================================================
    ; Compare max_sx - min_sx: if result < 0, no valid range
    SEC
    LDA bb_max_sx
    SBC bb_min_sx
    LDA bb_max_sx+1
    SBC bb_min_sx+1
    BVC bb_cmp_nov
    EOR #&80
.bb_cmp_nov
    BMI bb_not_visible         ; max < min → no projections

    ; ---- Set up has_gap inputs ----
    LDA bb_min_sx   : STA zp_x_lo_clip
    LDA bb_min_sx+1 : STA zp_x_lo_clip+1
    LDA bb_max_sx   : STA zp_x_hi_clip
    LDA bb_max_sx+1 : STA zp_x_hi_clip+1

.bb_call_has_gap
    JSR has_gap
    ; Restore zp_tmp0 AFTER has_gap (has_gap clobbers tmp0/tmp1 internally).
    ; LDA/STA don't affect carry, so the has_gap result propagates to caller.
    LDA bb_save_nid   : STA zp_tmp0
    LDA bb_save_nid+1 : STA zp_tmp0+1
    RTS

.bb_not_visible
    ; Restore zp_tmp0 and return not-visible
    LDA bb_save_nid   : STA zp_tmp0
    LDA bb_save_nid+1 : STA zp_tmp0+1
    CLC
    RTS

; ======================================================================
; BB_UPDATE_MINMAX: update min_sx / max_sx from zp_sx1
; Input:  zp_sx1 ($20:$21) = projected screen X (s16)
; Output: updates bb_min_sx, bb_max_sx
; Clobbers: A
; ======================================================================
.bb_update_minmax
    ; --- Update min: if sx1 < min_sx, min_sx = sx1 ---
    ; Compute sx1 - min_sx
    SEC
    LDA zp_sx1
    SBC bb_min_sx
    LDA zp_sx1+1
    SBC bb_min_sx+1
    BVC bb_min_nov
    EOR #&80
.bb_min_nov
    BPL bb_min_skip            ; sx1 >= min, don't update
    LDA zp_sx1   : STA bb_min_sx
    LDA zp_sx1+1 : STA bb_min_sx+1
.bb_min_skip
    ; --- Update max: if sx1 > max_sx, max_sx = sx1 ---
    ; Compute max_sx - sx1
    SEC
    LDA bb_max_sx
    SBC zp_sx1
    LDA bb_max_sx+1
    SBC zp_sx1+1
    BVC bb_max_nov
    EOR #&80
.bb_max_nov
    BPL bb_max_skip            ; max >= sx1, don't update
    LDA zp_sx1   : STA bb_max_sx
    LDA zp_sx1+1 : STA bb_max_sx+1
.bb_max_skip
    RTS

; ======================================================================
; BB_CLIP_EDGE: compute near-plane crossing for an edge and project it.
;
; Called with:
;   zp_tmp2 = vx_behind (s16)   [the corner that is behind]
;   zp_tmp3 = vy_behind (s16)
;   $80 = vx_front_lo, $81 = vx_front_hi (the corner that is in front)
;   $82 = vy_front_lo, $83 = vy_front_hi
;
; Computes:
;   t = ((NEAR - vy_behind) << 8) / (vy_front - vy_behind)   [u8, 0..255]
;   dvx = vx_front - vx_behind                                [s16]
;   cx = vx_behind + (dvx * t + 128) >> 8                     [s16]
;   Projects cx at vy=NEAR, updates min/max.
;
; Clobbers: A, X, Y, $70-$7F, zp_tmp2, zp_tmp3, zp_ex1, zp_ey1,
;           zp_vy1, zp_vi1, zp_sx1, zp_rxh, zp_rxl, $80-$85
; ======================================================================
.bb_clip_edge
    ; --- Compute dvy = vy_front - vy_behind (s16) ---
    ; Also compute numerator = (NEAR - vy_behind) << 8
    ; Since NEAR=1, numerator = (1 - vy_behind) << 8
    ; vy_behind is negative or zero (behind near plane), so 1 - vy_behind > 0.
    ;
    ; For div16_8: $71:$70 = dividend (u16), $73:$72 = divisor (u16)
    ; Output: A = quotient (u8)
    ;
    ; numerator = (1 - vy_behind) << 8
    ; Since vy_behind <= 0, 1 - vy_behind >= 1, which is positive.
    ; <<8 means: lo byte = 0, hi byte = (1 - vy_behind)_lo
    ; But wait, (1 - vy_behind) can be up to 1+32768 = 32769 which exceeds s16.
    ; For a bbox in a typical DOOM level this should be reasonable.
    ;
    ; Actually, let's compute this properly.
    ; NEAR - vy_behind = 1 - vy_behind (where vy_behind < 1)
    ; << 8: multiply by 256
    ; divisor = vy_front - vy_behind (always positive since front >= NEAR > behind)
    ;
    ; We want t = ((1 - vy_behind) * 256) / (vy_front - vy_behind)
    ; where 0 < t < 256 (u8).
    ;
    ; Since vy_behind is s16 and could be moderately negative, (1-vy_behind)
    ; fits in u16 (max ~32769).  << 8 would overflow u16.  But the quotient
    ; is u8 (0..255), so we use the 16-bit / 16-bit → 8-bit division.
    ;
    ; Numerator = (NEAR_FP - vy_behind_lo) : carry into hi
    ; Then shift left 8 = swap bytes, lo byte becomes 0.
    ;
    ; Let me compute: num16 = NEAR_FP - vy_behind (u16 result since positive)
    ; Then dividend for div16_8 = num16 << 8.
    ; But num16 << 8 can be up to 24 bits — too big for 16-bit dividend.
    ;
    ; Alternative: use the fact that we only need 8 bits of quotient.
    ; t = (num16 << 8) / dvy.  Equivalently, t = (num16 / dvy) << 8, but
    ; that loses precision.  Better: treat it as t = num16 * 256 / dvy.
    ;
    ; Since t must be in [0,255], and num16 < dvy always (because the behind
    ; corner is closer to NEAR than the full edge span), we have num16 < dvy.
    ; So num16 * 256 / dvy < 256 → fits in u8.
    ;
    ; For div16_8 with 16-bit dividend: the dividend is num16 * 256.
    ; num16 fits in u16 (at most ~32769).  num16 * 256 is up to ~24 bits.
    ;
    ; However, div16_8 uses a 16-bit dividend.  We can decompose:
    ; num16 * 256 = num16_hi * 65536 + num16_lo * 256
    ; = (num16_hi * 256 + num16_lo) << 8
    ; The 16-bit dividend register gets num16_lo : 0 (lo:hi = 0 : num16_lo).
    ; But num16_hi acts as initial remainder.
    ;
    ; Actually, let's just set up div16_8 differently.  div16_8 shifts
    ; the 16-bit dividend left through a 16-bit remainder.  If we pre-load
    ; the remainder with num16_hi, and the dividend with (num16_lo << 8),
    ; that's equivalent to dividing (num16 << 8) by dvy.
    ;
    ; dividend = num16_lo * 256 = $70=0, $71=num16_lo
    ; pre-set remainder $7E=0, $7F=0... no, that doesn't capture num16_hi.
    ;
    ; Let's think again.  div16_8 divides $71:$70 by $73:$72 → A = quotient.
    ; It processes 16 bits from the dividend.  Our effective dividend is 24 bits.
    ;
    ; Simplest: pre-load the remainder ($7E:$7F) with num16_hi, and set
    ; $71:$70 = num16_lo << 8 (i.e., $70=0, $71=num16_lo).
    ; Then div16_8 will shift through 16 bits of this plus the preloaded
    ; remainder, effectively dividing (num16_hi * 65536 + num16_lo * 256)
    ; by dvy.  That's exactly num16 * 256 / dvy.

    ; Step 1: Compute num16 = NEAR_FP - vy_behind  (positive u16)
    ; vy_behind is in zp_tmp3
    LDA #NEAR_FP
    SEC
    SBC zp_tmp3
    STA &88                    ; num16_lo
    LDA #0
    SBC zp_tmp3+1
    STA &89                    ; num16_hi

    ; Step 2: Compute dvy = vy_front - vy_behind  (positive s16, treat as u16)
    LDA &82
    SEC
    SBC zp_tmp3
    STA &72                    ; divisor lo for div16_8
    LDA &83
    SBC zp_tmp3+1
    STA &73                    ; divisor hi

    ; Step 3: Set up div16_8 with pre-loaded remainder
    ; dividend $71:$70 = num16_lo << 8
    LDA #0   : STA &70        ; dividend lo = 0
    LDA &88  : STA &71        ; dividend hi = num16_lo

    ; Pre-load remainder with num16_hi (effectively adding num16_hi * 65536
    ; to the value being divided)
    LDA #0   : STA &7E        ; remainder lo = 0
    LDA &89  : STA &7F        ; remainder hi = num16_hi

    ; We need a modified div16_8 that doesn't zero the remainder.
    ; Since div16_8 zeroes $7E:$7F at entry, we'll inline the loop here.
    LDX #16
.bb_div_loop
    ASL &70
    ROL &71
    ROL &7E
    ROL &7F
    LDA &7E
    CMP &72
    LDA &7F
    SBC &73
    BCC bb_div_no_sub
    LDA &7E
    SEC
    SBC &72
    STA &7E
    LDA &7F
    SBC &73
    STA &7F
    INC &70
.bb_div_no_sub
    DEX
    BNE bb_div_loop
    ; t = quotient in $70 (u8)
    LDA &70
    STA &88                    ; save t in $88

    ; Step 4: Compute dvx = vx_front - vx_behind (s16)
    ; vx_front in $80:$81, vx_behind in zp_tmp2
    LDA &80
    SEC
    SBC zp_tmp2
    STA zp_tmp2                ; dvx_lo → reuse zp_tmp2 for mul input
    LDA &81
    SBC zp_tmp2+1
    STA zp_tmp2+1              ; dvx_hi

    ; Step 5: Compute dvx * t → s24 in $70:$71:$72 via mul_s16_u8_s24
    ; Input: zp_tmp2 = dvx (s16), A = t (u8)
    LDA &88                    ; t
    JSR mul_s16_u8_s24
    ; Result in $70:$71:$72 (lo:mid:hi)

    ; Step 6: cx = vx_behind + (dvx * t + 128) >> 8
    ; (dvx * t + 128) >> 8:
    ;   add 128 to $70 (rounding), then take $71:$72 as the s16 result
    LDA &70
    CLC
    ADC #128
    ; We only care about the carry into $71
    LDA &71
    ADC #0
    STA &88                    ; cx_lo (offset_lo + carry)
    LDA &72
    ADC #0
    STA &89                    ; cx_hi

    ; cx = vx_behind + offset
    ; Need original vx_behind — but we overwrote zp_tmp2 with dvx!
    ; We need to recover vx_behind.
    ; vx_behind = vx_front - dvx, but dvx is also gone (overwritten by mul).
    ; Actually, let's rethink: we need to save vx_behind before computing dvx.
    ; I'll restructure: the edge handlers save vx_behind before calling.
    ; For now, the edge handlers will push vx_behind into $8A:$8B before calling.
    ; Let's use those.
    LDA &8A                    ; saved vx_behind_lo
    CLC
    ADC &88
    STA &88                    ; cx_lo
    LDA &8B                    ; saved vx_behind_hi
    ADC &89
    STA &89                    ; cx_hi

    ; Step 7: Project cx at vy=NEAR
    ; Set up recip_and_project_x1 for the use_ey1 path:
    ;   zp_ex1 = cx
    ;   zp_ey1 = NEAR_FP (=1)
    ;   zp_vy1 = 0 (differs from ey1, triggering use_ey1 path)
    LDA &88    : STA zp_ex1
    LDA &89    : STA zp_ex1+1
    LDA #NEAR_FP : STA zp_ey1
    LDA #0     : STA zp_ey1+1
    LDA #0     : STA zp_vy1     ; vy1 != ey1 → use_ey1 path
    LDA #0     : STA zp_vy1+1
    JSR recip_and_project_x1
    ; sx1 now in zp_sx1
    JSR bb_update_minmax
    RTS

; ======================================================================
; EDGE CROSSING HELPERS
; Each checks if the two endpoints straddle the near plane (one behind,
; one in front).  If so, computes the crossing and projects it.
;
; "Behind" means vy < NEAR_FP (=1), i.e. vy <= 0 in integer terms.
; "In front" means vy >= 1.
;
; For bb_clip_edge, we set up:
;   zp_tmp2 = vx_behind, zp_tmp3 = vy_behind
;   $80:$81 = vx_front, $82:$83 = vy_front
;   $8A:$8B = vx_behind (saved copy for cx computation)
; ======================================================================

; Helper: test if a corner's vy < NEAR (=1), i.e. vy <= 0.
; Returns C=1 if in front (vy >= 1), C=0 if behind (vy < 1).
; Input: A = vy_hi already loaded.
; This is inlined in each edge handler.

; ---- Edge 0→1 ----
.bb_edge_0_1
    ; Determine: corner 0 behind, corner 1 in front (or vice versa)?
    ; Corner 0 vy status
    LDA bb_c0_vy+1
    BMI bb_e01_0behind         ; vy0 < 0 → behind
    BNE bb_e01_0front          ; vy0_hi > 0 → in front
    LDA bb_c0_vy
    BEQ bb_e01_0behind         ; vy0 == 0 → behind
.bb_e01_0front
    ; Corner 0 is in front.  Check corner 1.
    LDA bb_c1_vy+1
    BMI bb_e01_cross_1behind   ; vy1 < 0 → behind, crossing!
    BNE bb_e01_no_cross        ; both in front
    LDA bb_c1_vy
    BEQ bb_e01_cross_1behind   ; vy1 == 0 → behind
    RTS                        ; both in front, no crossing
.bb_e01_0behind
    ; Corner 0 is behind.  Check corner 1.
    LDA bb_c1_vy+1
    BMI bb_e01_no_cross        ; both behind
    BNE bb_e01_cross_0behind   ; vy1 > 0, crossing!
    LDA bb_c1_vy
    BNE bb_e01_cross_0behind   ; vy1 >= 1, crossing!
.bb_e01_no_cross
    RTS                        ; no crossing (both same side)

.bb_e01_cross_0behind
    ; Corner 0 behind, corner 1 in front
    LDA bb_c0_vx   : STA zp_tmp2   : STA &8A
    LDA bb_c0_vx+1 : STA zp_tmp2+1 : STA &8B
    LDA bb_c0_vy   : STA zp_tmp3
    LDA bb_c0_vy+1 : STA zp_tmp3+1
    LDA bb_c1_vx   : STA &80
    LDA bb_c1_vx+1 : STA &81
    LDA bb_c1_vy   : STA &82
    LDA bb_c1_vy+1 : STA &83
    JMP bb_clip_edge

.bb_e01_cross_1behind
    ; Corner 1 behind, corner 0 in front
    LDA bb_c1_vx   : STA zp_tmp2   : STA &8A
    LDA bb_c1_vx+1 : STA zp_tmp2+1 : STA &8B
    LDA bb_c1_vy   : STA zp_tmp3
    LDA bb_c1_vy+1 : STA zp_tmp3+1
    LDA bb_c0_vx   : STA &80
    LDA bb_c0_vx+1 : STA &81
    LDA bb_c0_vy   : STA &82
    LDA bb_c0_vy+1 : STA &83
    JMP bb_clip_edge

; ---- Edge 1→2 ----
.bb_edge_1_2
    LDA bb_c1_vy+1
    BMI bb_e12_0behind
    BNE bb_e12_0front
    LDA bb_c1_vy
    BEQ bb_e12_0behind
.bb_e12_0front
    LDA bb_c2_vy+1
    BMI bb_e12_cross_1behind
    BNE bb_e12_no_cross
    LDA bb_c2_vy
    BEQ bb_e12_cross_1behind
    RTS
.bb_e12_0behind
    LDA bb_c2_vy+1
    BMI bb_e12_no_cross
    BNE bb_e12_cross_0behind
    LDA bb_c2_vy
    BNE bb_e12_cross_0behind
.bb_e12_no_cross
    RTS

.bb_e12_cross_0behind
    ; Corner 1 behind, corner 2 in front
    LDA bb_c1_vx   : STA zp_tmp2   : STA &8A
    LDA bb_c1_vx+1 : STA zp_tmp2+1 : STA &8B
    LDA bb_c1_vy   : STA zp_tmp3
    LDA bb_c1_vy+1 : STA zp_tmp3+1
    LDA bb_c2_vx   : STA &80
    LDA bb_c2_vx+1 : STA &81
    LDA bb_c2_vy   : STA &82
    LDA bb_c2_vy+1 : STA &83
    JMP bb_clip_edge

.bb_e12_cross_1behind
    ; Corner 2 behind, corner 1 in front
    LDA bb_c2_vx   : STA zp_tmp2   : STA &8A
    LDA bb_c2_vx+1 : STA zp_tmp2+1 : STA &8B
    LDA bb_c2_vy   : STA zp_tmp3
    LDA bb_c2_vy+1 : STA zp_tmp3+1
    LDA bb_c1_vx   : STA &80
    LDA bb_c1_vx+1 : STA &81
    LDA bb_c1_vy   : STA &82
    LDA bb_c1_vy+1 : STA &83
    JMP bb_clip_edge

; ---- Edge 2→3 ----
.bb_edge_2_3
    LDA bb_c2_vy+1
    BMI bb_e23_0behind
    BNE bb_e23_0front
    LDA bb_c2_vy
    BEQ bb_e23_0behind
.bb_e23_0front
    LDA bb_c3_vy+1
    BMI bb_e23_cross_1behind
    BNE bb_e23_no_cross
    LDA bb_c3_vy
    BEQ bb_e23_cross_1behind
    RTS
.bb_e23_0behind
    LDA bb_c3_vy+1
    BMI bb_e23_no_cross
    BNE bb_e23_cross_0behind
    LDA bb_c3_vy
    BNE bb_e23_cross_0behind
.bb_e23_no_cross
    RTS

.bb_e23_cross_0behind
    ; Corner 2 behind, corner 3 in front
    LDA bb_c2_vx   : STA zp_tmp2   : STA &8A
    LDA bb_c2_vx+1 : STA zp_tmp2+1 : STA &8B
    LDA bb_c2_vy   : STA zp_tmp3
    LDA bb_c2_vy+1 : STA zp_tmp3+1
    LDA bb_c3_vx   : STA &80
    LDA bb_c3_vx+1 : STA &81
    LDA bb_c3_vy   : STA &82
    LDA bb_c3_vy+1 : STA &83
    JMP bb_clip_edge

.bb_e23_cross_1behind
    ; Corner 3 behind, corner 2 in front
    LDA bb_c3_vx   : STA zp_tmp2   : STA &8A
    LDA bb_c3_vx+1 : STA zp_tmp2+1 : STA &8B
    LDA bb_c3_vy   : STA zp_tmp3
    LDA bb_c3_vy+1 : STA zp_tmp3+1
    LDA bb_c2_vx   : STA &80
    LDA bb_c2_vx+1 : STA &81
    LDA bb_c2_vy   : STA &82
    LDA bb_c2_vy+1 : STA &83
    JMP bb_clip_edge

; ---- Edge 3→0 ----
.bb_edge_3_0
    LDA bb_c3_vy+1
    BMI bb_e30_0behind
    BNE bb_e30_0front
    LDA bb_c3_vy
    BEQ bb_e30_0behind
.bb_e30_0front
    LDA bb_c0_vy+1
    BMI bb_e30_cross_1behind
    BNE bb_e30_no_cross
    LDA bb_c0_vy
    BEQ bb_e30_cross_1behind
    RTS
.bb_e30_0behind
    LDA bb_c0_vy+1
    BMI bb_e30_no_cross
    BNE bb_e30_cross_0behind
    LDA bb_c0_vy
    BNE bb_e30_cross_0behind
.bb_e30_no_cross
    RTS

.bb_e30_cross_0behind
    ; Corner 3 behind, corner 0 in front
    LDA bb_c3_vx   : STA zp_tmp2   : STA &8A
    LDA bb_c3_vx+1 : STA zp_tmp2+1 : STA &8B
    LDA bb_c3_vy   : STA zp_tmp3
    LDA bb_c3_vy+1 : STA zp_tmp3+1
    LDA bb_c0_vx   : STA &80
    LDA bb_c0_vx+1 : STA &81
    LDA bb_c0_vy   : STA &82
    LDA bb_c0_vy+1 : STA &83
    JMP bb_clip_edge

.bb_e30_cross_1behind
    ; Corner 0 behind, corner 3 in front
    LDA bb_c0_vx   : STA zp_tmp2   : STA &8A
    LDA bb_c0_vx+1 : STA zp_tmp2+1 : STA &8B
    LDA bb_c0_vy   : STA zp_tmp3
    LDA bb_c0_vy+1 : STA zp_tmp3+1
    LDA bb_c3_vx   : STA &80
    LDA bb_c3_vx+1 : STA &81
    LDA bb_c3_vy   : STA &82
    LDA bb_c3_vy+1 : STA &83
    JMP bb_clip_edge

}  ; end bbox_cull_native

; ======================================================================
; BANK SWITCH ROUTINES
; ======================================================================
.select_bank_0
    LDA #0 : STA &FE30 : RTS
.select_bank_1
    LDA #1 : STA &FE30 : RTS
.select_bank_2
    LDA #2 : STA &FE30 : RTS

; ======================================================================
; CLIP AND RASTERISE TRAMPOLINE
; Switches to bank 2 where the Cyrus-Beck clipper lives, calls it,
; then switches back to bank 0.
; ======================================================================
.clip_rasterise
    LDA #2 : STA &FE30         ; select bank 2 (clipper + NJ rasteriser)
    JSR clip_and_rasterise      ; in bank 2 at $9B20
    LDA #0 : STA &FE30         ; back to bank 0
    RTS

.end_of_code

SAVE "doom_fe.bin", &22D2, end_of_code

; ######################################################################
; CLIPPER CODE — assembled into ROM bank 2 at $9B20
; (lives after bbox table at $8000 and NJ rasteriser at $8EC0)
;
; Optimization tiers (matching the Python FPClipSpans.draw_clipped):
; 1. X overlap check — skip spans with no X overlap (0 muls)
; 2. Flat-span Y bbox reject — skip if line Y range outside span (0 muls)
; 3. Vertical line fast path — clamp Y to span top/bot (0-2 muls)
; 4. Inner bbox trivial accept — skip CB if line fits inside (0 muls)
; 5. Cyrus-Beck fallback — full parametric clip (4-12 muls)
; ######################################################################
ORG &9B20

; ======================================================================
; CLIP_AND_RASTERISE
; ======================================================================
.clip_and_rasterise
{
    ; LINE registers at ZP $A0-$A7 = zp_cl_x1..zp_cl_y2, no copy needed

    ; dx = x2 - x1, dy = y2 - y1
    SEC
    LDA zp_cl_x2   : SBC zp_cl_x1   : STA zp_cl_dx
    LDA zp_cl_x2+1 : SBC zp_cl_x1+1 : STA zp_cl_dx+1
    SEC
    LDA zp_cl_y2   : SBC zp_cl_y1   : STA zp_cl_dy
    LDA zp_cl_y2+1 : SBC zp_cl_y1+1 : STA zp_cl_dy+1

    ; --- Pre-compute line bounding box (s16) ---
    SEC
    LDA zp_cl_x1   : SBC zp_cl_x2
    LDA zp_cl_x1+1 : SBC zp_cl_x2+1
    BVC car_xv : EOR #&80
.car_xv
    BMI car_x1_lt
    LDA zp_cl_x2   : STA zp_cl_x_min
    LDA zp_cl_x2+1 : STA zp_cl_x_min+1
    LDA zp_cl_x1   : STA zp_cl_x_max
    LDA zp_cl_x1+1 : STA zp_cl_x_max+1
    JMP car_ybbox
.car_x1_lt
    LDA zp_cl_x1   : STA zp_cl_x_min
    LDA zp_cl_x1+1 : STA zp_cl_x_min+1
    LDA zp_cl_x2   : STA zp_cl_x_max
    LDA zp_cl_x2+1 : STA zp_cl_x_max+1

.car_ybbox
    SEC
    LDA zp_cl_y1   : SBC zp_cl_y2
    LDA zp_cl_y1+1 : SBC zp_cl_y2+1
    BVC car_yv : EOR #&80
.car_yv
    BMI car_y1_lt
    LDA zp_cl_y2   : STA zp_cl_y_min
    LDA zp_cl_y2+1 : STA zp_cl_y_min+1
    LDA zp_cl_y1   : STA zp_cl_y_max
    LDA zp_cl_y1+1 : STA zp_cl_y_max+1
    JMP car_spans
.car_y1_lt
    LDA zp_cl_y1   : STA zp_cl_y_min
    LDA zp_cl_y1+1 : STA zp_cl_y_min+1
    LDA zp_cl_y2   : STA zp_cl_y_max
    LDA zp_cl_y2+1 : STA zp_cl_y_max+1

.car_spans
    ; Load span count from current buffer (zp_cspan)
    LDY #0 : LDA (zp_cspan),Y
    BNE car_has_spans
    RTS
.car_has_spans
    STA zp_cl_count
    LDA zp_cspan : CLC : ADC #SPAN_HDR : STA zp_cl_span_ptr
    LDA zp_cspan+1 : ADC #0 : STA zp_cl_span_ptr+1

    ; === Check vertical (dx == 0) ===
    LDA zp_cl_dx : ORA zp_cl_dx+1
    BNE car_nonvertical

    ; --- Vertical path: per-span clip_vertical (unchanged) ---
.car_vert_loop
    LDY #SP_XLO
    LDA (zp_cl_span_ptr),Y : STA zp_cl_xlo
    LDY #SP_XHI
    LDA (zp_cl_span_ptr),Y : STA zp_cl_xhi
    ; Outer Y reject
    LDY #SP_OUTER_TOP
    LDA (zp_cl_span_ptr),Y : STA &74
    LDY #SP_OUTER_BOT
    LDA (zp_cl_span_ptr),Y : STA &75
    LDA zp_cl_y_max+1
    BMI car_vert_next
    BNE car_vot_ok
    LDA zp_cl_y_max : CMP &74
    BCC car_vert_next
.car_vot_ok
    LDA zp_cl_y_min+1
    BMI car_vob_ok
    BNE car_vert_next
    LDA &75 : CMP zp_cl_y_min
    BCC car_vert_next
.car_vob_ok
    JSR clip_vertical
    BCS car_vert_next
    JSR rasterise_clipped
.car_vert_next
    CLC
    LDA zp_cl_span_ptr   : ADC #SPAN_SIZE : STA zp_cl_span_ptr
    BCC car_vnc
    INC zp_cl_span_ptr+1
.car_vnc
    DEC zp_cl_count
    BNE car_vert_loop
    RTS

.car_nonvertical
    ; --- Non-vertical path: portal walk with contiguous groups ---

    ; Step 1: Order left-to-right.  If x1 > x2 (i.e. dx < 0), swap.
    LDA zp_cl_dx+1
    BPL car_lr_ok           ; dx >= 0 → already left-to-right
    ; Swap: xl=x2, yl=y2, xr=x1, yr=y1
    LDA zp_cl_x2   : STA zp_pw_xl
    LDA zp_cl_x2+1 : STA zp_pw_xl+1
    LDA zp_cl_y2   : STA zp_pw_yl
    LDA zp_cl_y2+1 : STA zp_pw_yl+1
    LDA zp_cl_x1   : STA zp_pw_xr
    LDA zp_cl_x1+1 : STA zp_pw_xr+1
    LDA zp_cl_y1   : STA zp_pw_yr
    LDA zp_cl_y1+1 : STA zp_pw_yr+1
    JMP car_lr_comp
.car_lr_ok
    LDA zp_cl_x1   : STA zp_pw_xl
    LDA zp_cl_x1+1 : STA zp_pw_xl+1
    LDA zp_cl_y1   : STA zp_pw_yl
    LDA zp_cl_y1+1 : STA zp_pw_yl+1
    LDA zp_cl_x2   : STA zp_pw_xr
    LDA zp_cl_x2+1 : STA zp_pw_xr+1
    LDA zp_cl_y2   : STA zp_pw_yr
    LDA zp_cl_y2+1 : STA zp_pw_yr+1

.car_lr_comp
    ; Compute dx = xr - xl (positive)
    SEC
    LDA zp_pw_xr   : SBC zp_pw_xl   : STA zp_pw_dx
    LDA zp_pw_xr+1 : SBC zp_pw_xl+1 : STA zp_pw_dx+1

    ; y_lo = min(yl, yr), y_hi = max(yl, yr)
    LDA zp_cl_y_min   : STA zp_pw_y_lo
    LDA zp_cl_y_min+1 : STA zp_pw_y_lo+1
    LDA zp_cl_y_max   : STA zp_pw_y_hi
    LDA zp_cl_y_max+1 : STA zp_pw_y_hi+1

    ; Step 2: Walk spans, detecting contiguous groups
    LDA #0 : STA zp_pw_grp_cnt     ; group count = 0

.car_grp_loop
    LDY #SP_XLO
    LDA (zp_cl_span_ptr),Y : STA zp_cl_xlo
    LDY #SP_XHI
    LDA (zp_cl_span_ptr),Y : STA zp_cl_xhi

    ; Early exit: xr < xlo?  (xr is s16, xlo is u8)
    ; (Match original: x_max < xlo → done)
    ; If xr_hi < 0: done (xr negative)
    ; If xr_hi > 0: xr >= 256 > xlo, so not done
    ; If xr_hi == 0: compare xr_lo < xlo
    LDA zp_pw_xr+1
    BMI car_grp_flush_done      ; xr < 0 → done
    BNE car_chk_skip            ; xr >= 256 → not done
    LDA zp_pw_xr : CMP zp_cl_xlo
    BCS car_chk_skip            ; xr >= xlo → not done
    JMP car_grp_flush_done      ; xr < xlo → done

.car_chk_skip
    ; Skip: xl >= xhi?  (xl is s16, xhi is u8 where 0=256)
    LDA zp_cl_xhi : BEQ car_chk_xhi256
    ; Normal xhi (1..255)
    LDA zp_pw_xl+1
    BMI car_chk_contiguous      ; xl < 0 < xhi → overlap
    BNE car_chk_skip_yes        ; xl >= 256 > xhi → skip
    LDA zp_pw_xl : CMP zp_cl_xhi
    BCC car_chk_contiguous      ; xl < xhi → overlap
.car_chk_skip_yes
    JMP car_grp_next
.car_chk_xhi256
    ; xhi = 256
    LDA zp_pw_xl+1
    BMI car_chk_contiguous      ; xl < 0 → overlap
    BEQ car_chk_contiguous      ; xl < 256 → overlap
    JMP car_grp_next            ; xl >= 256 → skip

.car_chk_contiguous
    ; This span overlaps the line.  Check contiguity with group.
    LDA zp_pw_grp_cnt
    BEQ car_start_group         ; no group yet → start one

    ; Check: xlo == prev_xhi?  (contiguous)
    LDA zp_cl_xlo : CMP zp_pw_prev_xhi
    BEQ car_add_to_group

    ; Not contiguous → process current group, start new one
    ; Save span_ptr (process_group clobbers it for span data reads)
    LDA zp_cl_span_ptr   : PHA
    LDA zp_cl_span_ptr+1 : PHA
    JSR process_group
    PLA : STA zp_cl_span_ptr+1
    PLA : STA zp_cl_span_ptr
    ; Fall through to start new group

.car_start_group
    LDA zp_cl_span_ptr   : STA zp_pw_grp_ptr
    LDA zp_cl_span_ptr+1 : STA zp_pw_grp_ptr+1
    LDA #0 : STA zp_pw_grp_cnt

.car_add_to_group
    INC zp_pw_grp_cnt
    LDA zp_cl_xhi : STA zp_pw_prev_xhi

.car_grp_next
    CLC
    LDA zp_cl_span_ptr   : ADC #SPAN_SIZE : STA zp_cl_span_ptr
    BCC car_gnc
    INC zp_cl_span_ptr+1
.car_gnc
    DEC zp_cl_count
    BNE car_grp_loop

.car_grp_flush_done
    ; Process final group if any
    LDA zp_pw_grp_cnt
    BEQ car_done
    JSR process_group

.car_done
    RTS

}

; ======================================================================
; PROCESS_GROUP — dispatch single or multi span group
; Input: zp_pw_grp_ptr, zp_pw_grp_cnt, line params in zp_cl_* and zp_pw_*
; ======================================================================
.process_group
{
    LDA zp_pw_grp_cnt
    CMP #1
    BNE pg_multi

    ; --- Single-span: existing cascade (outer reject, inner accept, CB) ---
    ; Set span pointer to group[0]
    LDA zp_pw_grp_ptr   : STA zp_cl_span_ptr
    LDA zp_pw_grp_ptr+1 : STA zp_cl_span_ptr+1
    LDY #SP_XLO
    LDA (zp_cl_span_ptr),Y : STA zp_cl_xlo
    LDY #SP_XHI
    LDA (zp_cl_span_ptr),Y : STA zp_cl_xhi

    ; Outer bbox Y reject
    LDY #SP_OUTER_TOP
    LDA (zp_cl_span_ptr),Y : STA &74
    LDY #SP_OUTER_BOT
    LDA (zp_cl_span_ptr),Y : STA &75
    ; y_hi_lo < outer_top?  (y_hi is the max Y of the line's Y range)
    ; Actually: use y_max and y_min from the line's original bbox
    LDA zp_cl_y_max+1
    BMI pg_done
    BNE pg_ot_ok
    LDA zp_cl_y_max : CMP &74
    BCC pg_done
.pg_ot_ok
    LDA zp_cl_y_min+1
    BMI pg_ob_ok
    BNE pg_done
    LDA &75 : CMP zp_cl_y_min
    BCC pg_done
.pg_ob_ok

    ; Inner bbox trivial accept
    LDY #SP_INNER_TOP
    SEC
    LDA zp_cl_y_min   : SBC (zp_cl_span_ptr),Y
    INY
    LDA zp_cl_y_min+1 : SBC (zp_cl_span_ptr),Y
    BVC pg_iv1 : EOR #&80
.pg_iv1
    BMI pg_full_cb
    LDY #SP_INNER_BOT
    SEC
    LDA (zp_cl_span_ptr),Y : SBC zp_cl_y_max
    INY
    LDA (zp_cl_span_ptr),Y : SBC zp_cl_y_max+1
    BVC pg_iv2 : EOR #&80
.pg_iv2
    BMI pg_full_cb
    JSR clip_lr_only
    BCS pg_done
    JSR rasterise_clipped
    RTS

.pg_full_cb
    JSR clip_to_trap
    BCS pg_done
    JSR rasterise_clipped
.pg_done
    RTS

.pg_multi
    JMP multi_span_clip
}

; ======================================================================
; MULTI_SPAN_CLIP — handle contiguous multi-span group
; Input: zp_pw_grp_ptr, zp_pw_grp_cnt, line at zp_cl_*/zp_pw_*
; ======================================================================
.multi_span_clip
{
    ; Step 1: Compute group_outer_top = min(SP_OUTER_TOP) across group
    ;         Compute group_outer_bot = max(SP_OUTER_BOT) across group
    LDA zp_pw_grp_ptr   : STA zp_pw_iter_ptr
    LDA zp_pw_grp_ptr+1 : STA zp_pw_iter_ptr+1
    LDA zp_pw_grp_cnt   : STA zp_pw_iter
    LDA #255 : STA &74         ; group_outer_top = 255 (min accumulator)
    LDA #0   : STA &75         ; group_outer_bot = 0 (max accumulator)

.msc_bbox_loop
    LDY #SP_OUTER_TOP
    LDA (zp_pw_iter_ptr),Y
    CMP &74
    BCS msc_ot_ok
    STA &74                     ; new min
.msc_ot_ok
    LDY #SP_OUTER_BOT
    LDA (zp_pw_iter_ptr),Y
    CMP &75
    BCC msc_ob_ok
    STA &75                     ; new max
.msc_ob_ok
    CLC
    LDA zp_pw_iter_ptr   : ADC #SPAN_SIZE : STA zp_pw_iter_ptr
    BCC msc_bnc
    INC zp_pw_iter_ptr+1
.msc_bnc
    DEC zp_pw_iter
    BNE msc_bbox_loop

    ; Step 2: Outer reject
    ; y_max < group_outer_top?
    LDA zp_cl_y_max+1
    BMI msc_reject          ; y_max < 0 < outer_top
    BNE msc_ot_pass
    LDA zp_cl_y_max : CMP &74
    BCC msc_reject
.msc_ot_pass
    ; y_min > group_outer_bot?
    LDA zp_cl_y_min+1
    BMI msc_ob_pass         ; y_min < 0 <= outer_bot → pass
    BNE msc_reject          ; y_min >= 256 > outer_bot → reject
    LDA &75 : CMP zp_cl_y_min
    BCC msc_reject
    JMP msc_ob_pass
.msc_reject
    JMP msc_done
.msc_ob_pass

    ; Step 3: Compute group_inner_top = max(SP_INNER_TOP low byte) across group
    ;         Compute group_inner_bot = min(SP_INNER_BOT low byte) across group
    LDA zp_pw_grp_ptr   : STA zp_pw_iter_ptr
    LDA zp_pw_grp_ptr+1 : STA zp_pw_iter_ptr+1
    LDA zp_pw_grp_cnt   : STA zp_pw_iter
    LDA #0   : STA &76         ; group_inner_top = 0 (max accumulator)
    LDA #255 : STA &77         ; group_inner_bot = 255 (min accumulator)

.msc_inner_loop
    LDY #SP_INNER_TOP
    LDA (zp_pw_iter_ptr),Y     ; low byte of inner_top (s16)
    CMP &76
    BCC msc_it_ok
    STA &76                     ; new max
.msc_it_ok
    LDY #SP_INNER_BOT
    LDA (zp_pw_iter_ptr),Y     ; low byte of inner_bot (s16)
    CMP &77
    BCS msc_ib_ok
    STA &77                     ; new min
.msc_ib_ok
    CLC
    LDA zp_pw_iter_ptr   : ADC #SPAN_SIZE : STA zp_pw_iter_ptr
    BCC msc_inc
    INC zp_pw_iter_ptr+1
.msc_inc
    DEC zp_pw_iter
    BNE msc_inner_loop

    ; Step 4: Inner accept: y_lo >= inner_top AND y_hi <= inner_bot
    ; y_lo = zp_pw_y_lo (s16), inner_top = &76 (u8 treated as s16 with hi=0)
    ; Compare: y_lo >= inner_top
    LDA zp_pw_y_lo+1
    BMI msc_no_inner          ; y_lo < 0 < inner_top → fail
    BNE msc_check_inner_hi   ; y_lo >= 256 → y_lo >= inner_top
    LDA zp_pw_y_lo : CMP &76
    BCC msc_no_inner
.msc_check_inner_hi
    ; y_hi <= inner_bot
    LDA zp_pw_y_hi+1
    BMI msc_inner_accept      ; y_hi < 0 → y_hi <= inner_bot
    BNE msc_no_inner          ; y_hi >= 256 > inner_bot → fail
    LDA &77 : CMP zp_pw_y_hi
    BCC msc_no_inner          ; inner_bot < y_hi → fail

.msc_inner_accept
    ; Trivial accept: draw one line from max(xl, first_xlo) to min(xr, last_xhi-1)
    JSR inner_accept_draw
    RTS

.msc_no_inner
    ; Step 5: Scan from left for first visible span (CB clip each)
    LDA zp_pw_grp_ptr   : STA zp_pw_iter_ptr
    LDA zp_pw_grp_ptr+1 : STA zp_pw_iter_ptr+1
    LDA zp_pw_grp_cnt   : STA zp_pw_iter
    LDA #0 : STA zp_pw_fi      ; fi = 0 (index of first visible)

.msc_fwd_scan
    ; Set span pointer and load span params
    LDA zp_pw_iter_ptr   : STA zp_cl_span_ptr
    LDA zp_pw_iter_ptr+1 : STA zp_cl_span_ptr+1
    LDY #SP_XLO
    LDA (zp_cl_span_ptr),Y : STA zp_cl_xlo
    LDY #SP_XHI
    LDA (zp_cl_span_ptr),Y : STA zp_cl_xhi
    JSR clip_to_trap
    BCC msc_fwd_found

    ; Not visible — advance to next span
    INC zp_pw_fi
    CLC
    LDA zp_pw_iter_ptr   : ADC #SPAN_SIZE : STA zp_pw_iter_ptr
    BCC msc_fwd_nc
    INC zp_pw_iter_ptr+1
.msc_fwd_nc
    DEC zp_pw_iter
    BNE msc_fwd_scan
    ; No visible span at all
.msc_done
    RTS

.msc_fwd_found
    ; Save c_first result from zp_cl_cx1..cy2
    LDA zp_cl_cx1   : STA zp_pw_cf_x1
    LDA zp_cl_cx1+1 : STA zp_pw_cf_x1+1
    LDA zp_cl_cy1   : STA zp_pw_cf_y1
    LDA zp_cl_cy1+1 : STA zp_pw_cf_y1+1
    LDA zp_cl_cx2   : STA zp_pw_cf_x2
    LDA zp_cl_cx2+1 : STA zp_pw_cf_x2+1
    LDA zp_cl_cy2   : STA zp_pw_cf_y2
    LDA zp_cl_cy2+1 : STA zp_pw_cf_y2+1

    ; Step 7: If fi is the last span, draw c_first and done
    LDA zp_pw_fi
    CLC : ADC #1
    CMP zp_pw_grp_cnt
    BCS msc_draw_first_only

    ; Step 8: Scan from right for last visible span
    ; Compute pointer to last span: grp_ptr + (grp_cnt - 1) * SPAN_SIZE
    LDA zp_pw_grp_cnt : SEC : SBC #1 : STA zp_pw_li
    ; Count of spans to scan backward = li - fi
    LDA zp_pw_li : SEC : SBC zp_pw_fi
    BEQ msc_draw_first_only     ; only one span after fi
    STA zp_pw_iter

    ; Compute pointer to group[li]
    ; grp_ptr + li * SPAN_SIZE
    LDA zp_pw_li
    JSR grp_idx_to_ptr          ; zp_pw_iter_ptr = grp_ptr + A*16

.msc_rev_scan
    LDA zp_pw_iter_ptr   : STA zp_cl_span_ptr
    LDA zp_pw_iter_ptr+1 : STA zp_cl_span_ptr+1
    LDY #SP_XLO
    LDA (zp_cl_span_ptr),Y : STA zp_cl_xlo
    LDY #SP_XHI
    LDA (zp_cl_span_ptr),Y : STA zp_cl_xhi
    JSR clip_to_trap
    BCC msc_rev_found

    ; Not visible — move backward
    DEC zp_pw_li
    SEC
    LDA zp_pw_iter_ptr   : SBC #SPAN_SIZE : STA zp_pw_iter_ptr
    BCS msc_rev_nc
    DEC zp_pw_iter_ptr+1
.msc_rev_nc
    DEC zp_pw_iter
    BNE msc_rev_scan

    ; No last visible → draw first only
.msc_draw_first_only
    LDA zp_pw_cf_x1   : STA zp_cl_cx1
    LDA zp_pw_cf_x1+1 : STA zp_cl_cx1+1
    LDA zp_pw_cf_y1   : STA zp_cl_cy1
    LDA zp_pw_cf_y1+1 : STA zp_cl_cy1+1
    LDA zp_pw_cf_x2   : STA zp_cl_cx2
    LDA zp_pw_cf_x2+1 : STA zp_cl_cx2+1
    LDA zp_pw_cf_y2   : STA zp_cl_cy2
    LDA zp_pw_cf_y2+1 : STA zp_cl_cy2+1
    JSR rasterise_clipped
    RTS

.msc_rev_found
    ; c_last endpoints: cx2, cy2 from this clip
    ; Store c_last end point (we keep c_first start from cf_x1/y1)
    LDA zp_cl_cx2   : STA zp_pw_cf_x2
    LDA zp_cl_cx2+1 : STA zp_pw_cf_x2+1
    LDA zp_cl_cy2   : STA zp_pw_cf_y2
    LDA zp_cl_cy2+1 : STA zp_pw_cf_y2+1

    ; Step 10: Portal walk between fi and li
    JSR portal_walk
    BCS msc_portal_fail

    ; All portals pass — draw ONE line from c_first start to c_last end
    LDA zp_pw_cf_x1   : STA zp_cl_cx1
    LDA zp_pw_cf_x1+1 : STA zp_cl_cx1+1
    LDA zp_pw_cf_y1   : STA zp_cl_cy1
    LDA zp_pw_cf_y1+1 : STA zp_cl_cy1+1
    LDA zp_pw_cf_x2   : STA zp_cl_cx2
    LDA zp_pw_cf_x2+1 : STA zp_cl_cx2+1
    LDA zp_pw_cf_y2   : STA zp_cl_cy2
    LDA zp_pw_cf_y2+1 : STA zp_cl_cy2+1
    JSR rasterise_clipped
    RTS

.msc_portal_fail
    ; Per-span CB from fi to li
    LDA zp_pw_fi
    JSR grp_idx_to_ptr
    LDA zp_pw_li : SEC : SBC zp_pw_fi : CLC : ADC #1 : STA zp_pw_iter

.msc_fallback_loop
    LDA zp_pw_iter_ptr   : STA zp_cl_span_ptr
    LDA zp_pw_iter_ptr+1 : STA zp_cl_span_ptr+1
    LDY #SP_XLO
    LDA (zp_cl_span_ptr),Y : STA zp_cl_xlo
    LDY #SP_XHI
    LDA (zp_cl_span_ptr),Y : STA zp_cl_xhi
    JSR clip_to_trap
    BCS msc_fb_next
    JSR rasterise_clipped
.msc_fb_next
    CLC
    LDA zp_pw_iter_ptr   : ADC #SPAN_SIZE : STA zp_pw_iter_ptr
    BCC msc_fb_nc
    INC zp_pw_iter_ptr+1
.msc_fb_nc
    DEC zp_pw_iter
    BNE msc_fallback_loop
    RTS
}

; ======================================================================
; GRP_IDX_TO_PTR — compute pointer to group[A]
; Input: A = index, zp_pw_grp_ptr = base
; Output: zp_pw_iter_ptr = grp_ptr + A * SPAN_SIZE
; ======================================================================
.grp_idx_to_ptr
{
    ; A * 16 = (A << 4).  A is small (< 32).
    ASL A : ASL A : ASL A : ASL A  ; A * 16, carry may be set
    CLC
    ADC zp_pw_grp_ptr   : STA zp_pw_iter_ptr
    LDA #0
    ADC zp_pw_grp_ptr+1 : STA zp_pw_iter_ptr+1
    RTS
}

; ======================================================================
; INNER_ACCEPT_DRAW — trivial accept for multi-span group
; Draws one line from max(xl, first_xlo) to min(xr, last_xhi-1)
; with Y computed via line_y_at at the clamped X endpoints.
; ======================================================================
.inner_accept_draw
{
    ; draw_xl = max(xl, group[0].xlo)
    LDY #SP_XLO
    LDA (zp_pw_grp_ptr),Y : STA &74    ; first_xlo
    ; xl (s16) vs xlo (u8): if xl < xlo, use xlo
    LDA zp_pw_xl+1
    BMI iad_use_xlo             ; xl < 0 → use xlo
    BNE iad_use_xl              ; xl >= 256 → use xl (will be clamped later)
    LDA zp_pw_xl : CMP &74
    BCS iad_use_xl
.iad_use_xlo
    LDA &74 : STA zp_cl_cx1
    LDA #0  : STA zp_cl_cx1+1
    JMP iad_right
.iad_use_xl
    LDA zp_pw_xl   : STA zp_cl_cx1
    LDA zp_pw_xl+1 : STA zp_cl_cx1+1

.iad_right
    ; draw_xr = min(xr, last_xhi - 1)
    ; Compute pointer to last span: grp_ptr + (grp_cnt-1)*16
    LDA zp_pw_grp_cnt : SEC : SBC #1
    ASL A : ASL A : ASL A : ASL A
    CLC : ADC zp_pw_grp_ptr   : STA zp_pw_iter_ptr
    LDA #0 : ADC zp_pw_grp_ptr+1 : STA zp_pw_iter_ptr+1
    LDY #SP_XHI
    LDA (zp_pw_iter_ptr),Y     ; last_xhi (u8, 0=256)
    BEQ iad_xhi256
    SEC : SBC #1 : STA &75     ; last_xhi - 1
    ; xr (s16) vs last_xhi-1 (u8)
    LDA zp_pw_xr+1
    BMI iad_use_xr              ; xr < 0 → use xr
    BNE iad_use_last            ; xr >= 256 → use last_xhi-1
    LDA zp_pw_xr : CMP &75
    BCC iad_use_xr              ; xr < last_xhi-1
    BEQ iad_use_xr              ; xr == last_xhi-1
.iad_use_last
    LDA &75 : STA zp_cl_cx2
    LDA #0  : STA zp_cl_cx2+1
    JMP iad_compute_y
.iad_xhi256
    ; last_xhi = 256, last_xhi - 1 = 255
    LDA zp_pw_xr+1
    BMI iad_use_xr
    BNE iad_use_255
    LDA zp_pw_xr : CMP #255
    BCC iad_use_xr
.iad_use_255
    LDA #255 : STA zp_cl_cx2
    LDA #0   : STA zp_cl_cx2+1
    JMP iad_compute_y
.iad_use_xr
    LDA zp_pw_xr   : STA zp_cl_cx2
    LDA zp_pw_xr+1 : STA zp_cl_cx2+1

.iad_compute_y
    ; cy1 = line_y_at(cx1), cy2 = line_y_at(cx2)
    ; But if cx1 == xl, cy1 = yl; if cx2 == xr, cy2 = yr
    LDA zp_cl_cx1 : CMP zp_pw_xl
    BNE iad_y1_calc
    LDA zp_cl_cx1+1 : CMP zp_pw_xl+1
    BNE iad_y1_calc
    ; cx1 == xl → cy1 = yl
    LDA zp_pw_yl   : STA zp_cl_cy1
    LDA zp_pw_yl+1 : STA zp_cl_cy1+1
    JMP iad_y2
.iad_y1_calc
    LDA zp_cl_cx1   : STA zp_tmp0
    LDA zp_cl_cx1+1 : STA zp_tmp0+1
    JSR line_y_at
    LDA &70 : STA zp_cl_cy1
    LDA &71 : STA zp_cl_cy1+1

.iad_y2
    LDA zp_cl_cx2 : CMP zp_pw_xr
    BNE iad_y2_calc
    LDA zp_cl_cx2+1 : CMP zp_pw_xr+1
    BNE iad_y2_calc
    ; cx2 == xr → cy2 = yr
    LDA zp_pw_yr   : STA zp_cl_cy2
    LDA zp_pw_yr+1 : STA zp_cl_cy2+1
    JMP iad_draw
.iad_y2_calc
    LDA zp_cl_cx2   : STA zp_tmp0
    LDA zp_cl_cx2+1 : STA zp_tmp0+1
    JSR line_y_at
    LDA &70 : STA zp_cl_cy2
    LDA &71 : STA zp_cl_cy2+1

.iad_draw
    JSR rasterise_clipped
    RTS
}

; ======================================================================
; PORTAL_WALK — check all portals between group[fi] and group[li]
; Input: zp_pw_fi, zp_pw_li, zp_pw_grp_ptr, zp_pw_y_lo/y_hi, zp_pw_*
; Output: C=0 all portals pass, C=1 portal fails
; Uses &74 = boundary_x, &75 = spare
;       &76:&77 = portal_top (s16), &78:&79 = portal_bot (s16)
; ======================================================================
.portal_walk
{
    LDA zp_pw_fi : CMP zp_pw_li
    BCC pw_has_portals
    JMP pw_pass                 ; fi >= li → no portals to check, pass
.pw_has_portals

    ; Start at group[fi]
    LDA zp_pw_fi
    JSR grp_idx_to_ptr          ; zp_pw_iter_ptr = group[fi]

    LDA zp_pw_li : SEC : SBC zp_pw_fi : STA zp_pw_iter  ; count = li - fi

.pw_loop
    ; boundary_x = span[i].xhi
    LDY #SP_XHI
    LDA (zp_pw_iter_ptr),Y
    STA &74                     ; boundary_x (u8)

    ; Compute span[i+1] pointer into zp_cl_span_ptr (reused as temp)
    CLC
    LDA zp_pw_iter_ptr   : ADC #SPAN_SIZE : STA zp_cl_span_ptr
    LDA zp_pw_iter_ptr+1 : ADC #0         : STA zp_cl_span_ptr+1

    ; top_left = fp_eval(span[i].tfn, boundary_x)
    LDY #SP_TSLOPE
    LDA (zp_pw_iter_ptr),Y : STA zp_tmp2
    INY
    LDA (zp_pw_iter_ptr),Y : STA zp_tmp2+1
    LDY #SP_TINTERCEPT
    LDA (zp_pw_iter_ptr),Y : STA zp_mk_tmp
    INY
    LDA (zp_pw_iter_ptr),Y : STA zp_mk_tmp+1
    LDA &74
    JSR fp_eval                 ; $70:$71 = top_left
    LDA &70 : STA &76          ; portal_top = top_left (will be max'd)
    LDA &71 : STA &77

    ; top_right = fp_eval(span[i+1].tfn, boundary_x)
    LDY #SP_TSLOPE
    LDA (zp_cl_span_ptr),Y : STA zp_tmp2
    INY
    LDA (zp_cl_span_ptr),Y : STA zp_tmp2+1
    LDY #SP_TINTERCEPT
    LDA (zp_cl_span_ptr),Y : STA zp_mk_tmp
    INY
    LDA (zp_cl_span_ptr),Y : STA zp_mk_tmp+1
    LDA &74
    JSR fp_eval                 ; $70:$71 = top_right

    ; portal_top = max(top_left, top_right)
    ; &76:&77 = top_left, $70:$71 = top_right
    SEC
    LDA &76 : SBC &70
    LDA &77 : SBC &71
    BVC pw_tv1 : EOR #&80
.pw_tv1
    BPL pw_tl_done              ; top_left >= top_right → keep &76:&77
    LDA &70 : STA &76           ; top_right is bigger
    LDA &71 : STA &77
.pw_tl_done
    ; &76:&77 = portal_top

    ; bot_left = fp_eval(span[i].bfn, boundary_x)
    LDY #SP_BSLOPE
    LDA (zp_pw_iter_ptr),Y : STA zp_tmp2
    INY
    LDA (zp_pw_iter_ptr),Y : STA zp_tmp2+1
    LDY #SP_BINTERCEPT
    LDA (zp_pw_iter_ptr),Y : STA zp_mk_tmp
    INY
    LDA (zp_pw_iter_ptr),Y : STA zp_mk_tmp+1
    LDA &74
    JSR fp_eval                 ; $70:$71 = bot_left
    LDA &70 : STA &78          ; portal_bot = bot_left (will be min'd)
    LDA &71 : STA &79

    ; bot_right = fp_eval(span[i+1].bfn, boundary_x)
    LDY #SP_BSLOPE
    LDA (zp_cl_span_ptr),Y : STA zp_tmp2
    INY
    LDA (zp_cl_span_ptr),Y : STA zp_tmp2+1
    LDY #SP_BINTERCEPT
    LDA (zp_cl_span_ptr),Y : STA zp_mk_tmp
    INY
    LDA (zp_cl_span_ptr),Y : STA zp_mk_tmp+1
    LDA &74
    JSR fp_eval                 ; $70:$71 = bot_right

    ; portal_bot = min(bot_left, bot_right)
    ; &78:&79 = bot_left, $70:$71 = bot_right
    SEC
    LDA &78 : SBC &70
    LDA &79 : SBC &71
    BVC pw_bv1 : EOR #&80
.pw_bv1
    BMI pw_bl_done              ; bot_left < bot_right → keep &78:&79 (min)
    LDA &70 : STA &78           ; bot_right is smaller
    LDA &71 : STA &79
.pw_bl_done
    ; &78:&79 = portal_bot
    ; &76:&77 = portal_top

    ; Check: y_lo < portal_top OR y_hi > portal_bot?
    ; If neither, portal is OK.

    ; Check y_lo < portal_top?
    SEC
    LDA zp_pw_y_lo   : SBC &76
    LDA zp_pw_y_lo+1 : SBC &77
    BVC pw_cv1 : EOR #&80
.pw_cv1
    BMI pw_check_line           ; y_lo < portal_top → might fail

    ; Check y_hi > portal_bot?
    SEC
    LDA &78   : SBC zp_pw_y_hi
    LDA &79   : SBC zp_pw_y_hi+1
    BVC pw_cv2 : EOR #&80
.pw_cv2
    BMI pw_check_line           ; portal_bot < y_hi → might fail

    ; Both checks pass → portal OK, advance to next
    JMP pw_next

.pw_check_line
    ; Bbox failed — compute actual line Y at boundary_x
    ; line_y_at needs x in zp_tmp0 (s16)
    LDA &74 : STA zp_tmp0
    LDA #0  : STA zp_tmp0+1
    JSR line_y_at               ; $70:$71 = line_y
    ; &76:&77 and &78:&79 survive line_y_at (it clobbers zp_tmp0-3, $70-$73,
    ; zp_div_*, but not &74-&79)

    ; Check line_y < portal_top?
    SEC
    LDA &70 : SBC &76
    LDA &71 : SBC &77
    BVC pw_lv1 : EOR #&80
.pw_lv1
    BMI pw_fail                 ; line_y < portal_top → portal fails

    ; Check line_y > portal_bot?
    SEC
    LDA &78 : SBC &70
    LDA &79 : SBC &71
    BVC pw_lv2 : EOR #&80
.pw_lv2
    BMI pw_fail                 ; portal_bot < line_y → portal fails

    ; Line passes through this portal

.pw_next
    CLC
    LDA zp_pw_iter_ptr   : ADC #SPAN_SIZE : STA zp_pw_iter_ptr
    BCC pw_nnc
    INC zp_pw_iter_ptr+1
.pw_nnc
    DEC zp_pw_iter
    BEQ pw_pass
    JMP pw_loop

.pw_pass
    CLC
    RTS

.pw_fail
    SEC
    RTS
}

; ======================================================================
; LINE_Y_AT — compute line Y at given X
; Computes: yl + (yr - yl) * (x - xl) / dx
; Input: zp_tmp0 = x (s16), zp_pw_xl/yl/xr/yr/dx set
; Output: $70:$71 = y (s16)
; Clobbers: zp_tmp0-3, zp_div_*, $70-$73
; ======================================================================
.line_y_at
{
    ; numerator_a = yr - yl
    SEC
    LDA zp_pw_yr   : SBC zp_pw_yl   : STA zp_tmp2
    LDA zp_pw_yr+1 : SBC zp_pw_yl+1 : STA zp_tmp2+1

    ; numerator_b = x - xl
    SEC
    LDA zp_tmp0   : SBC zp_pw_xl   : STA zp_tmp0
    LDA zp_tmp0+1 : SBC zp_pw_xl+1 : STA zp_tmp0+1

    ; product = (yr-yl) * (x-xl): s16 * s16 → s32 (we need middle 16 bits for /dx)
    ; Use mul16x16: inputs in zp_tmp0, zp_tmp2. Output in $70:$71:$72:$73.
    JSR mul16x16
    ; $70:$71:$72:$73 = product (s32)
    ; We need product / dx (integer division, truncation toward zero).
    ; product is a full 32-bit value, dx is 16-bit.
    ; For int_div16 we need 16-bit / 16-bit.
    ; But the product can exceed 16 bits!  For lines spanning the full screen
    ; (dy up to ~160, x-xl up to ~256), product can be ~40960 which fits s16.
    ; Actually: dy can be up to ~320 (s16), x-xl up to ~512, product up to ~160K.
    ; That DOESN'T fit in s16!
    ;
    ; Use 32/16 division for correctness.
    ; Actually, Python uses: yl + (yr - yl) * (x - xl) // dx
    ; where // is floor division.  For now, use truncation toward zero.
    ;
    ; 32-bit product in $70:$71:$72:$73, divisor = pw_dx in s16.
    ; Let's implement a 32/16 → 16 signed division.
    ; Save product to stack, set up division.

    ; Sign of result = sign of product XOR sign of dx.
    ; Since dx > 0 always (xr > xl, left-to-right ordering), sign = sign of product.
    ; |product|: if product negative, negate $70:$71:$72:$73

    ; Check product sign (bit 7 of $73)
    LDA &73
    STA zp_div_sign             ; 0 or $8x = product sign
    BPL lya_prod_pos
    ; Negate 32-bit product
    SEC
    LDA #0 : SBC &70 : STA &70
    LDA #0 : SBC &71 : STA &71
    LDA #0 : SBC &72 : STA &72
    LDA #0 : SBC &73 : STA &73
.lya_prod_pos

    ; Divisor = pw_dx (always positive since xr > xl)
    LDA zp_pw_dx   : STA zp_div_den
    LDA zp_pw_dx+1 : STA zp_div_den+1

    ; Unsigned 32-bit / 16-bit → quotient in $70:$71 (low 16 bits)
    ; Use shift-and-subtract: 32 iterations
    LDA #0 : STA zp_div_rem : STA zp_div_rem+1
    LDX #32
.lya_div_loop
    ; Shift dividend left (rotate through $70:$71:$72:$73)
    ASL &70
    ROL &71
    ROL &72
    ROL &73
    ROL zp_div_rem
    ROL zp_div_rem+1
    ; Try subtract
    LDA zp_div_rem
    SEC
    SBC zp_div_den
    TAY
    LDA zp_div_rem+1
    SBC zp_div_den+1
    BCC lya_no_sub
    STA zp_div_rem+1
    STY zp_div_rem
    INC &70                     ; set bit 0 of quotient
.lya_no_sub
    DEX
    BNE lya_div_loop

    ; Quotient in $70:$71 (unsigned, low 16 bits of 32-bit quotient)
    ; Apply sign with Python-style floor division:
    ; For negative results with nonzero remainder, quotient += 1 before negate.
    ; This gives floor(a/b) instead of trunc(a/b).
    LDA zp_div_sign
    BPL lya_add_yl
    ; Result is negative.  Check remainder for floor correction.
    LDA zp_div_rem : ORA zp_div_rem+1
    BEQ lya_exact_neg
    ; Nonzero remainder: floor = -(quotient + 1)
    CLC
    LDA &70 : ADC #1 : STA &70
    LDA &71 : ADC #0 : STA &71
.lya_exact_neg
    ; Negate quotient
    SEC
    LDA #0 : SBC &70 : STA &70
    LDA #0 : SBC &71 : STA &71

.lya_add_yl
    ; result = yl + quotient
    CLC
    LDA &70 : ADC zp_pw_yl   : STA &70
    LDA &71 : ADC zp_pw_yl+1 : STA &71
    RTS
}

; ======================================================================
; CLIP_VERTICAL — fast path for vertical lines (dx == 0)
; Evaluates span top/bot at the line's X and clamps Y range.
; Uses fp_eval (0-2 muls) instead of full CB (4-12 muls).
;
; Input:  zp_cl_x1 (= x2 since dx=0), zp_cl_y_min, zp_cl_y_max
;         span at (zp_cl_span_ptr)
; Output: C=0 visible (zp_cl_cx1..cy2 set), C=1 rejected
; ======================================================================
.clip_vertical
{
    ; x = x1.  Check xlo <= x < xhi.
    ; x < xlo → reject
    LDA zp_cl_x1+1
    BMI cv_rej              ; x < 0 < xlo → reject
    BNE cv_x_ge_xlo        ; x >= 256 → might still be < xhi
    LDA zp_cl_x1 : CMP zp_cl_xlo
    BCC cv_rej              ; x < xlo → reject
.cv_x_ge_xlo
    ; x >= xhi → reject (xhi=0 means 256)
    LDA zp_cl_xhi : BEQ cv_xhi256
    LDA zp_cl_x1+1
    BNE cv_rej              ; x >= 256 > xhi → reject (xhi < 256)
    LDA zp_cl_x1 : CMP zp_cl_xhi
    BCS cv_rej              ; x >= xhi → reject
    JMP cv_x_ok
.cv_xhi256
    LDA zp_cl_x1+1
    BNE cv_rej              ; x >= 256 = xhi → reject
    BEQ cv_x_ok             ; always taken (A=0), skip trampoline
.cv_rej
    JMP cv_reject
.cv_x_ok

    ; Compute top_y and bot_y at x.
    ; For flat spans (slope=0): top_y = tintercept, bot_y = bintercept
    ; For non-flat: top_y = fp_mul8(ta, x) + tb (up to 2 muls)

    ; Check ta == 0
    LDY #SP_TSLOPE
    LDA (zp_cl_span_ptr),Y : INY : ORA (zp_cl_span_ptr),Y
    BNE cv_ta_nonzero
    ; ta = 0: top_y = tb
    LDY #SP_TINTERCEPT
    LDA (zp_cl_span_ptr),Y : STA zp_tmp0
    INY
    LDA (zp_cl_span_ptr),Y : STA zp_tmp0+1
    JMP cv_do_bot
.cv_ta_nonzero
    ; top_y = fp_mul8(ta, x1) + tb
    LDY #SP_TSLOPE
    LDA (zp_cl_span_ptr),Y : STA zp_tmp0
    INY
    LDA (zp_cl_span_ptr),Y : STA zp_tmp0+1
    LDA zp_cl_x1   : STA zp_tmp2
    LDA zp_cl_x1+1 : STA zp_tmp2+1
    JSR fl_mul8_fast        ; $70:$71 = fp_mul8(ta, x)
    LDY #SP_TINTERCEPT
    CLC
    LDA &70 : ADC (zp_cl_span_ptr),Y : STA zp_tmp0
    INY
    LDA &71 : ADC (zp_cl_span_ptr),Y : STA zp_tmp0+1

.cv_do_bot
    ; Check ba == 0
    LDY #SP_BSLOPE
    LDA (zp_cl_span_ptr),Y : INY : ORA (zp_cl_span_ptr),Y
    BNE cv_ba_nonzero
    ; ba = 0: bot_y = bb
    LDY #SP_BINTERCEPT
    LDA (zp_cl_span_ptr),Y : STA zp_tmp2
    INY
    LDA (zp_cl_span_ptr),Y : STA zp_tmp2+1
    JMP cv_clamp
.cv_ba_nonzero
    LDY #SP_BSLOPE
    LDA (zp_cl_span_ptr),Y : STA zp_tmp0+2  ; abuse zp_tmp1 for ba temp
    INY
    LDA (zp_cl_span_ptr),Y : STA zp_tmp0+3
    ; Save top_y (in zp_tmp0) on stack temporarily
    LDA zp_tmp0 : PHA
    LDA zp_tmp0+1 : PHA
    LDA zp_tmp0+2 : STA zp_tmp0
    LDA zp_tmp0+3 : STA zp_tmp0+1
    LDA zp_cl_x1   : STA zp_tmp2
    LDA zp_cl_x1+1 : STA zp_tmp2+1
    JSR fl_mul8_fast        ; $70:$71 = fp_mul8(ba, x)
    LDY #SP_BINTERCEPT
    CLC
    LDA &70 : ADC (zp_cl_span_ptr),Y : STA zp_tmp2
    INY
    LDA &71 : ADC (zp_cl_span_ptr),Y : STA zp_tmp2+1
    ; Restore top_y
    PLA : STA zp_tmp0+1
    PLA : STA zp_tmp0

.cv_clamp
    ; zp_tmp0 = top_y (s16), zp_tmp2 = bot_y (s16)
    ; Check top_y >= bot_y → no aperture → reject
    SEC
    LDA zp_tmp2   : SBC zp_tmp0
    LDA zp_tmp2+1 : SBC zp_tmp0+1
    BVC cv_av : EOR #&80
.cv_av
    BMI cv_reject           ; bot_y < top_y → no aperture

    ; Clamp y_min/y_max to [top_y, bot_y] into cx/cy output slots.
    ; cy1 = max(y_min, top_y)
    LDA zp_cl_y_min   : STA zp_cl_cy1
    LDA zp_cl_y_min+1 : STA zp_cl_cy1+1
    SEC
    LDA zp_cl_cy1   : SBC zp_tmp0
    LDA zp_cl_cy1+1 : SBC zp_tmp0+1
    BVC cv_v1 : EOR #&80
.cv_v1
    BPL cv_cy1_ok           ; y_min >= top_y
    LDA zp_tmp0   : STA zp_cl_cy1
    LDA zp_tmp0+1 : STA zp_cl_cy1+1
.cv_cy1_ok
    ; cy2 = min(y_max, bot_y)
    LDA zp_cl_y_max   : STA zp_cl_cy2
    LDA zp_cl_y_max+1 : STA zp_cl_cy2+1
    SEC
    LDA zp_tmp2   : SBC zp_cl_cy2
    LDA zp_tmp2+1 : SBC zp_cl_cy2+1
    BVC cv_v2 : EOR #&80
.cv_v2
    BPL cv_cy2_ok           ; bot_y >= y_max
    LDA zp_tmp2   : STA zp_cl_cy2
    LDA zp_tmp2+1 : STA zp_cl_cy2+1
.cv_cy2_ok
    ; Check cy1 > cy2 (after clamping) → reject
    SEC
    LDA zp_cl_cy2   : SBC zp_cl_cy1
    LDA zp_cl_cy2+1 : SBC zp_cl_cy1+1
    BVC cv_v3 : EOR #&80
.cv_v3
    BMI cv_reject           ; cy2 < cy1 → empty

    ; Output: vertical line at (x1, cy1) → (x1, cy2)
    LDA zp_cl_x1   : STA zp_cl_cx1 : STA zp_cl_cx2
    LDA zp_cl_x1+1 : STA zp_cl_cx1+1 : STA zp_cl_cx2+1
    CLC
    RTS

.cv_reject
    SEC
    RTS
}

; ======================================================================
; CLIP_LR_ONLY — trivial-accept path: only apply left/right constraints.
; Used when inner bbox confirms line Y range fits inside span.
; Skips the expensive top/bot constraints (saves 4 muls + 2 divs).
;
; Input:  zp_cl_x1..y2, zp_cl_dx/dy precomputed
;         zp_cl_xlo, zp_cl_xhi
; Output: C=0 visible (zp_cl_cx1..cy2 set), C=1 rejected
; ======================================================================
.clip_lr_only
{
    ; Init t0 = 0, t1 = $0100
    LDA #0
    STA zp_cl_t0 : STA zp_cl_t0+1
    STA zp_cl_t1
    LDA #1 : STA zp_cl_t1+1

    ; Constraint 1: LEFT  p = -dx, q = x1 - xlo
    SEC
    LDA #0         : SBC zp_cl_dx   : STA zp_tmp2
    LDA #0         : SBC zp_cl_dx+1 : STA zp_tmp2+1
    SEC
    LDA zp_cl_x1   : SBC zp_cl_xlo  : STA zp_tmp0
    LDA zp_cl_x1+1 : SBC #0         : STA zp_tmp0+1
    JSR process_constraint
    BCS lr_reject

    ; Constraint 2: RIGHT  p = dx, q = xhi - x1
    LDA zp_cl_dx   : STA zp_tmp2
    LDA zp_cl_dx+1 : STA zp_tmp2+1
    LDA zp_cl_xhi
    BNE lr_xhi_normal
    SEC
    LDA #0         : SBC zp_cl_x1   : STA zp_tmp0
    LDA #1         : SBC zp_cl_x1+1 : STA zp_tmp0+1
    JMP lr_con2
.lr_xhi_normal
    SEC
    LDA zp_cl_xhi  : SBC zp_cl_x1   : STA zp_tmp0
    LDA #0         : SBC zp_cl_x1+1 : STA zp_tmp0+1
.lr_con2
    JSR process_constraint
    BCS lr_reject

    ; Check t0 > t1
    SEC
    LDA zp_cl_t1   : SBC zp_cl_t0
    LDA zp_cl_t1+1 : SBC zp_cl_t0+1
    BVC lr_cv1 : EOR #&80
.lr_cv1
    BMI lr_reject

    ; Compute clipped endpoints (same as full CB)
    JMP compute_clipped_endpoints

.lr_reject
    SEC
    RTS
}

; ======================================================================
; CLIP_TO_TRAP — Cyrus-Beck line clipper (full, 4 constraints)
; Clips line against trapezoid span: [xlo, xhi) with linear top/bot.
;
; Input:  zp_cl_x1..y2, zp_cl_dx/dy precomputed
;         span at (zp_cl_span_ptr)
; Output: C=0 visible (zp_cl_cx1..cy2 set), C=1 rejected
; ======================================================================
.clip_to_trap
{
    ; Init t0 = 0, t1 = $0100 (= 256 = 1.0 in 0.8 format)
    LDA #0
    STA zp_cl_t0 : STA zp_cl_t0+1
    STA zp_cl_t1
    LDA #1 : STA zp_cl_t1+1

    ; --- Read span slopes and intercepts ---
    LDY #SP_TSLOPE
    LDA (zp_cl_span_ptr),Y : STA zp_cl_ta
    INY
    LDA (zp_cl_span_ptr),Y : STA zp_cl_ta+1

    LDY #SP_BSLOPE
    LDA (zp_cl_span_ptr),Y : STA zp_cl_ba
    INY
    LDA (zp_cl_span_ptr),Y : STA zp_cl_ba+1

    LDY #SP_TINTERCEPT
    LDA (zp_cl_span_ptr),Y : STA zp_cl_tb
    INY
    LDA (zp_cl_span_ptr),Y : STA zp_cl_tb+1

    LDY #SP_BINTERCEPT
    LDA (zp_cl_span_ptr),Y : STA zp_cl_bb
    INY
    LDA (zp_cl_span_ptr),Y : STA zp_cl_bb+1

    ; --- Compute slope products (skip if slope == 0, very common) ---

    ; ta_dx = fp_mul8(ta, dx), ta_x1 = fp_mul8(ta, x1)
    LDA zp_cl_ta : ORA zp_cl_ta+1
    BNE ct_ta_nonzero
    LDA #0
    STA zp_cl_ta_dx : STA zp_cl_ta_dx+1
    STA zp_cl_ta_x1 : STA zp_cl_ta_x1+1
    JMP ct_compute_ba
.ct_ta_nonzero
    LDA zp_cl_ta   : STA zp_tmp0
    LDA zp_cl_ta+1 : STA zp_tmp0+1
    LDA zp_cl_dx   : STA zp_tmp2
    LDA zp_cl_dx+1 : STA zp_tmp2+1
    JSR fl_mul8_fast
    LDA &70 : STA zp_cl_ta_dx
    LDA &71 : STA zp_cl_ta_dx+1
    LDA zp_cl_ta   : STA zp_tmp0
    LDA zp_cl_ta+1 : STA zp_tmp0+1
    LDA zp_cl_x1   : STA zp_tmp2
    LDA zp_cl_x1+1 : STA zp_tmp2+1
    JSR fl_mul8_fast
    LDA &70 : STA zp_cl_ta_x1
    LDA &71 : STA zp_cl_ta_x1+1

.ct_compute_ba
    ; ba_dx = fp_mul8(ba, dx), ba_x1 = fp_mul8(ba, x1)
    LDA zp_cl_ba : ORA zp_cl_ba+1
    BNE ct_ba_nonzero
    LDA #0
    STA zp_cl_ba_dx : STA zp_cl_ba_dx+1
    STA zp_cl_ba_x1 : STA zp_cl_ba_x1+1
    JMP ct_constraints
.ct_ba_nonzero
    LDA zp_cl_ba   : STA zp_tmp0
    LDA zp_cl_ba+1 : STA zp_tmp0+1
    LDA zp_cl_dx   : STA zp_tmp2
    LDA zp_cl_dx+1 : STA zp_tmp2+1
    JSR fl_mul8_fast
    LDA &70 : STA zp_cl_ba_dx
    LDA &71 : STA zp_cl_ba_dx+1
    LDA zp_cl_ba   : STA zp_tmp0
    LDA zp_cl_ba+1 : STA zp_tmp0+1
    LDA zp_cl_x1   : STA zp_tmp2
    LDA zp_cl_x1+1 : STA zp_tmp2+1
    JSR fl_mul8_fast
    LDA &70 : STA zp_cl_ba_x1
    LDA &71 : STA zp_cl_ba_x1+1

.ct_constraints
    ; === Constraint 1: LEFT — x >= xlo ===
    ; p = -dx, q = x1 - xlo
    SEC
    LDA #0         : SBC zp_cl_dx   : STA zp_tmp2
    LDA #0         : SBC zp_cl_dx+1 : STA zp_tmp2+1
    SEC
    LDA zp_cl_x1   : SBC zp_cl_xlo  : STA zp_tmp0
    LDA zp_cl_x1+1 : SBC #0         : STA zp_tmp0+1
    JSR process_constraint
    BCC ct_con1_ok : JMP ct_reject
.ct_con1_ok

    ; === Constraint 2: RIGHT — x < xhi ===
    ; p = dx, q = xhi - x1
    LDA zp_cl_dx   : STA zp_tmp2
    LDA zp_cl_dx+1 : STA zp_tmp2+1
    LDA zp_cl_xhi
    BNE ct_xhi_normal
    ; xhi = 0 means 256 = $0100
    SEC
    LDA #0         : SBC zp_cl_x1   : STA zp_tmp0
    LDA #1         : SBC zp_cl_x1+1 : STA zp_tmp0+1
    JMP ct_con2_go
.ct_xhi_normal
    SEC
    LDA zp_cl_xhi  : SBC zp_cl_x1   : STA zp_tmp0
    LDA #0         : SBC zp_cl_x1+1 : STA zp_tmp0+1
.ct_con2_go
    JSR process_constraint
    BCC ct_con2_ok : JMP ct_reject
.ct_con2_ok

    ; === Constraint 3: TOP — y >= ta*x + tb ===
    ; p = ta_dx - dy, q = y1 - ta_x1 - tb
    SEC
    LDA zp_cl_ta_dx   : SBC zp_cl_dy     : STA zp_tmp2
    LDA zp_cl_ta_dx+1 : SBC zp_cl_dy+1   : STA zp_tmp2+1
    SEC
    LDA zp_cl_y1      : SBC zp_cl_ta_x1   : STA zp_tmp0
    LDA zp_cl_y1+1    : SBC zp_cl_ta_x1+1 : STA zp_tmp0+1
    SEC
    LDA zp_tmp0        : SBC zp_cl_tb      : STA zp_tmp0
    LDA zp_tmp0+1      : SBC zp_cl_tb+1    : STA zp_tmp0+1
    JSR process_constraint
    BCC ct_con3_ok : JMP ct_reject
.ct_con3_ok

    ; === Constraint 4: BOTTOM — y <= ba*x + bb ===
    ; p = dy - ba_dx, q = ba_x1 + bb - y1
    SEC
    LDA zp_cl_dy      : SBC zp_cl_ba_dx   : STA zp_tmp2
    LDA zp_cl_dy+1    : SBC zp_cl_ba_dx+1 : STA zp_tmp2+1
    CLC
    LDA zp_cl_ba_x1   : ADC zp_cl_bb      : STA zp_tmp0
    LDA zp_cl_ba_x1+1 : ADC zp_cl_bb+1    : STA zp_tmp0+1
    SEC
    LDA zp_tmp0        : SBC zp_cl_y1      : STA zp_tmp0
    LDA zp_tmp0+1      : SBC zp_cl_y1+1    : STA zp_tmp0+1
    JSR process_constraint
    BCC ct_con4_ok : JMP ct_reject
.ct_con4_ok

    ; === Check t0 > t1 → reject ===
    ; Signed: is t1 < t0?
    SEC
    LDA zp_cl_t1   : SBC zp_cl_t0
    LDA zp_cl_t1+1 : SBC zp_cl_t0+1
    BVC ct_cmpv1 : EOR #&80
.ct_cmpv1
    BPL ct_t_ok : JMP ct_reject
.ct_t_ok

    ; Shared endpoint computation + X clamp + vertical Y clamp
    JMP compute_clipped_endpoints

.ct_reject
    SEC
    RTS
}

; ======================================================================
; COMPUTE_CLIPPED_ENDPOINTS — shared by clip_to_trap and clip_lr_only.
; Converts parametric t0/t1 to screen coordinates with X clamping
; and vertical-line Y clamping.
; Input: zp_cl_t0, zp_cl_t1 set; zp_cl_x1..y2, dx, dy valid
; Output: C=0 visible (zp_cl_cx1..cy2 set), C=1 rejected
; ======================================================================
.compute_clipped_endpoints
{
    ; cx1/cy1: skip multiply if t0=0 (line starts inside span)
    LDA zp_cl_t0 : ORA zp_cl_t0+1
    BNE cce_t0_nonzero
    ; t0=0: cx1=x1, cy1=y1 (no multiply needed)
    LDA zp_cl_x1 : STA zp_cl_cx1 : LDA zp_cl_x1+1 : STA zp_cl_cx1+1
    LDA zp_cl_y1 : STA zp_cl_cy1 : LDA zp_cl_y1+1 : STA zp_cl_cy1+1
    JMP cce_do_t1
.cce_t0_nonzero
    ; cx1 = x1 + fp_mul8(t0, dx)
    LDA zp_cl_t0   : STA zp_tmp0
    LDA zp_cl_t0+1 : STA zp_tmp0+1
    LDA zp_cl_dx   : STA zp_tmp2
    LDA zp_cl_dx+1 : STA zp_tmp2+1
    JSR fl_mul8_fast
    CLC
    LDA zp_cl_x1   : ADC &70 : STA zp_cl_cx1
    LDA zp_cl_x1+1 : ADC &71 : STA zp_cl_cx1+1
    ; cy1 = y1 + fp_mul8(t0, dy)
    LDA zp_cl_t0   : STA zp_tmp0
    LDA zp_cl_t0+1 : STA zp_tmp0+1
    LDA zp_cl_dy   : STA zp_tmp2
    LDA zp_cl_dy+1 : STA zp_tmp2+1
    JSR fl_mul8_fast
    CLC
    LDA zp_cl_y1   : ADC &70 : STA zp_cl_cy1
    LDA zp_cl_y1+1 : ADC &71 : STA zp_cl_cy1+1

.cce_do_t1
    ; cx2/cy2: skip if t1=$0100 (=256=T_ONE, line ends inside span)
    LDA zp_cl_t1 : BNE cce_t1_nonone
    LDA zp_cl_t1+1 : CMP #1 : BNE cce_t1_nonone
    ; t1=256: cx2=x2, cy2=y2
    LDA zp_cl_x2 : STA zp_cl_cx2 : LDA zp_cl_x2+1 : STA zp_cl_cx2+1
    LDA zp_cl_y2 : STA zp_cl_cy2 : LDA zp_cl_y2+1 : STA zp_cl_cy2+1
    JMP cce_clamp
.cce_t1_nonone
    ; cx2 = x1 + fp_mul8(t1, dx)
    LDA zp_cl_t1   : STA zp_tmp0
    LDA zp_cl_t1+1 : STA zp_tmp0+1
    LDA zp_cl_dx   : STA zp_tmp2
    LDA zp_cl_dx+1 : STA zp_tmp2+1
    JSR fl_mul8_fast
    CLC
    LDA zp_cl_x1   : ADC &70 : STA zp_cl_cx2
    LDA zp_cl_x1+1 : ADC &71 : STA zp_cl_cx2+1
    ; cy2 = y1 + fp_mul8(t1, dy)
    LDA zp_cl_t1   : STA zp_tmp0
    LDA zp_cl_t1+1 : STA zp_tmp0+1
    LDA zp_cl_dy   : STA zp_tmp2
    LDA zp_cl_dy+1 : STA zp_tmp2+1
    JSR fl_mul8_fast
    CLC
    LDA zp_cl_y1   : ADC &70 : STA zp_cl_cy2
    LDA zp_cl_y1+1 : ADC &71 : STA zp_cl_cy2+1

.cce_clamp
    ; === Clamp cx1 >= xlo ===
    LDA zp_cl_cx1+1
    BMI ct_clamp_x1       ; cx1 negative → clamp
    BNE ct_x1_done        ; cx1 >= 256 → no clamp needed
    LDA zp_cl_cx1 : CMP zp_cl_xlo
    BCS ct_x1_done
.ct_clamp_x1
    LDA zp_cl_xlo : STA zp_cl_cx1
    LDA #0 : STA zp_cl_cx1+1
.ct_x1_done

    ; === Clamp cx2 < xhi (i.e., cx2 <= xhi-1) ===
    LDA zp_cl_xhi
    BEQ ct_xhi256         ; xhi = 256
    ; Normal xhi
    LDA zp_cl_cx2+1
    BMI ct_x2_done        ; cx2 negative → no clamp
    BNE ct_clamp_x2       ; cx2 >= 256 → clamp
    LDA zp_cl_cx2 : CMP zp_cl_xhi
    BCC ct_x2_done        ; cx2 < xhi → ok
.ct_clamp_x2
    LDA zp_cl_xhi : SEC : SBC #1 : STA zp_cl_cx2
    LDA #0 : STA zp_cl_cx2+1
    JMP ct_x2_done
.ct_xhi256
    ; xhi = 256: clamp if cx2 >= 256
    LDA zp_cl_cx2+1
    BMI ct_x2_done        ; negative → ok
    BEQ ct_x2_done        ; hi=0 → cx2 < 256 → ok
    LDA #255 : STA zp_cl_cx2
    LDA #0 : STA zp_cl_cx2+1
.ct_x2_done

    ; === Check cx1 > cx2 → reject ===
    SEC
    LDA zp_cl_cx2   : SBC zp_cl_cx1
    LDA zp_cl_cx2+1 : SBC zp_cl_cx1+1
    BVC ct_cmpv2 : EOR #&80
.ct_cmpv2
    BPL ct_cx_ok : JMP ct_reject
.ct_cx_ok

    ; === Vertical line: clamp Y to [top_y, bot_y] ===
    LDA zp_cl_dx : ORA zp_cl_dx+1
    BNE ct_accept

    ; top_y = ta_x1 + tb
    CLC
    LDA zp_cl_ta_x1   : ADC zp_cl_tb   : STA zp_tmp0
    LDA zp_cl_ta_x1+1 : ADC zp_cl_tb+1 : STA zp_tmp0+1
    ; bot_y = ba_x1 + bb
    CLC
    LDA zp_cl_ba_x1   : ADC zp_cl_bb   : STA zp_tmp2
    LDA zp_cl_ba_x1+1 : ADC zp_cl_bb+1 : STA zp_tmp2+1

    ; cy1 = max(cy1, top_y)
    SEC
    LDA zp_cl_cy1   : SBC zp_tmp0
    LDA zp_cl_cy1+1 : SBC zp_tmp0+1
    BVC ct_v3 : EOR #&80
.ct_v3
    BPL ct_cy1_max_ok
    LDA zp_tmp0   : STA zp_cl_cy1
    LDA zp_tmp0+1 : STA zp_cl_cy1+1
.ct_cy1_max_ok
    ; cy1 = min(cy1, bot_y)
    SEC
    LDA zp_tmp2   : SBC zp_cl_cy1
    LDA zp_tmp2+1 : SBC zp_cl_cy1+1
    BVC ct_v4 : EOR #&80
.ct_v4
    BPL ct_cy1_min_ok
    LDA zp_tmp2   : STA zp_cl_cy1
    LDA zp_tmp2+1 : STA zp_cl_cy1+1
.ct_cy1_min_ok
    ; cy2 = max(cy2, top_y)
    SEC
    LDA zp_cl_cy2   : SBC zp_tmp0
    LDA zp_cl_cy2+1 : SBC zp_tmp0+1
    BVC ct_v5 : EOR #&80
.ct_v5
    BPL ct_cy2_max_ok
    LDA zp_tmp0   : STA zp_cl_cy2
    LDA zp_tmp0+1 : STA zp_cl_cy2+1
.ct_cy2_max_ok
    ; cy2 = min(cy2, bot_y)
    SEC
    LDA zp_tmp2   : SBC zp_cl_cy2
    LDA zp_tmp2+1 : SBC zp_cl_cy2+1
    BVC ct_v6 : EOR #&80
.ct_v6
    BPL ct_cy2_min_ok
    LDA zp_tmp2   : STA zp_cl_cy2
    LDA zp_tmp2+1 : STA zp_cl_cy2+1
.ct_cy2_min_ok

.ct_accept
    CLC
    RTS

.ct_reject
    SEC
    RTS
}

; ======================================================================
; PROCESS_CONSTRAINT — update t0/t1 for one Cyrus-Beck half-plane
;
; Input:  zp_tmp0 = q (s16), zp_tmp2 = p (s16)
; Updates: zp_cl_t0 / zp_cl_t1
; Output: C=1 reject, C=0 continue
; Clobbers: A, X, Y, zp_div_*, zp_tmp3, $70:$71
; ======================================================================
.process_constraint
{
    ; Check p == 0 (line parallel to this boundary)
    LDA zp_tmp2 : ORA zp_tmp2+1
    BNE pc_p_nonzero

    ; p == 0: reject if q < -1 (i.e., q <= -2, point is outside)
    LDA zp_tmp0+1
    BPL pc_p0_ok              ; q >= 0 → inside
    CMP #&FF : BNE pc_reject  ; q_hi != $FF → q <= -256 → outside
    LDA zp_tmp0
    CMP #&FF : BEQ pc_p0_ok   ; q == -1 → on boundary → ok
.pc_reject
    SEC
    RTS
.pc_p0_ok
    CLC
    RTS

.pc_p_nonzero
    ; Sign-based skip: if p>0 and q<0, t<0 → reject immediately.
    ; If p<0 and q>=0, t<=0 → skip (can't tighten t0 above 0).
    LDA zp_tmp2+1 : BMI pc_p_is_neg
    ; p > 0 (leaving): if q < 0, t < 0 < t0 → reject
    LDA zp_tmp0+1 : BMI pc_reject
    JMP pc_do_div
.pc_p_is_neg
    ; p < 0 (entering): if q >= 0, t <= 0 → no update to t0, skip
    LDA zp_tmp0+1 : BPL pc_done
.pc_do_div
    JSR fp_div8             ; result in $70:$71 (s16)

    ; Check sign of p to determine entering vs leaving
    LDA zp_tmp2+1
    BMI pc_p_neg

    ; --- p > 0 (leaving constraint) ---
    ; if t < t0: reject
    SEC
    LDA &70 : SBC zp_cl_t0
    LDA &71 : SBC zp_cl_t0+1
    BVC pc_pv1 : EOR #&80
.pc_pv1
    BMI pc_reject           ; t < t0 → reject

    ; if t < t1: t1 = t
    SEC
    LDA &70 : SBC zp_cl_t1
    LDA &71 : SBC zp_cl_t1+1
    BVC pc_pv2 : EOR #&80
.pc_pv2
    BPL pc_done             ; t >= t1 → no update
    LDA &70 : STA zp_cl_t1
    LDA &71 : STA zp_cl_t1+1
    CLC
    RTS

.pc_p_neg
    ; --- p < 0 (entering constraint) ---
    ; if t > t1: reject (t1 < t)
    SEC
    LDA zp_cl_t1   : SBC &70
    LDA zp_cl_t1+1 : SBC &71
    BVC pc_pv3 : EOR #&80
.pc_pv3
    BMI pc_reject           ; t1 < t → reject

    ; if t > t0: t0 = t (t0 < t)
    SEC
    LDA zp_cl_t0   : SBC &70
    LDA zp_cl_t0+1 : SBC &71
    BVC pc_pv4 : EOR #&80
.pc_pv4
    BPL pc_done             ; t0 >= t → no update
    LDA &70 : STA zp_cl_t0
    LDA &71 : STA zp_cl_t0+1

.pc_done
    CLC
    RTS
}

; ======================================================================
; RASTERISE_CLIPPED — clamp s16 coords to u8 and call NJ rasteriser
; Input:  zp_cl_cx1..cy2 (s16 clipped coordinates)
; Called from bank 2 — NJ rasteriser at $8EC0 is in same bank.
; ======================================================================
.rasterise_clipped
{
    ; Clamp cx1 X: s16 → u8 [0,255]
    LDA zp_cl_cx1+1
    BEQ rc_x0_ok
    BPL rc_x0_max
    LDA #0 : JMP rc_x0_set
.rc_x0_max
    LDA #255
.rc_x0_set
    STA &82 : JMP rc_y0
.rc_x0_ok
    LDA zp_cl_cx1 : STA &82

.rc_y0
    LDA zp_cl_cy1+1
    BEQ rc_y0_ok
    BPL rc_y0_max
    LDA #0 : JMP rc_y0_set
.rc_y0_max
    LDA #159
.rc_y0_set
    STA &83 : JMP rc_x1
.rc_y0_ok
    LDA zp_cl_cy1 : CMP #160 : BCC rc_y0_keep : LDA #159
.rc_y0_keep
    STA &83

.rc_x1
    LDA zp_cl_cx2+1
    BEQ rc_x1_ok
    BPL rc_x1_max
    LDA #0 : JMP rc_x1_set
.rc_x1_max
    LDA #255
.rc_x1_set
    STA &84 : JMP rc_y1
.rc_x1_ok
    LDA zp_cl_cx2 : STA &84

.rc_y1
    LDA zp_cl_cy2+1
    BEQ rc_y1_ok
    BPL rc_y1_max
    LDA #0 : JMP rc_y1_set
.rc_y1_max
    LDA #159
.rc_y1_set
    STA &85 : JMP rc_draw
.rc_y1_ok
    LDA zp_cl_cy2 : CMP #160 : BCC rc_y1_keep : LDA #159
.rc_y1_keep
    STA &85

.rc_draw
    ; Write coords to magic peripheral $FE20-$FE23 (py65 captures if enabled)
    LDA &82 : STA &FE20
    LDA &83 : STA &FE21
    LDA &84 : STA &FE22
    LDA &85 : STA &FE23
    ; Then always call NJ rasteriser for jsbeeb / J-mode
    LDA &02F8 : STA &70
    JSR &8EC0
    RTS
}

; ======================================================================
; FL_MUL8_FAST — s8×s8 fast path for clipper multiply.
; Same interface as fl_mul8_bysx: inputs in zp_tmp0/zp_tmp2, result in $70:$71.
; When both operands fit in s8 (~60 cycles), avoids mul16x16 (~200 cycles).
; Falls back to fl_mul8_bysx for wider operands.
; ======================================================================
.fl_mul8_fast
{
    ; Check both operands fit in s8 [-128, 127]: (val+128) < 256
    CLC : LDA zp_tmp0 : ADC #128 : LDA zp_tmp0+1 : ADC #0
    BNE fmf_wide
    CLC : LDA zp_tmp2 : ADC #128 : LDA zp_tmp2+1 : ADC #0
    BNE fmf_wide
    ; Both s8 — single smul8x8 (~60 cyc vs ~200 for mul16x16)
    LDA zp_tmp0 : STA zp_math_b
    LDA zp_tmp2 : JSR smul8x8
    LDA zp_res_hi : STA &70
    BPL fmf_pos
    LDA #&FF : STA &71 : RTS
.fmf_pos
    LDA #0 : STA &71 : RTS
.fmf_wide
    JMP fl_mul8_bysx
}

; ======================================================================
; CLEAR_SCREEN — fast unrolled screen clear: 20 × STA abs,X ($5800-$6BFF)
; ======================================================================
.clear_screen
{
    LDA &70 : CMP #&6C : BEQ clear_buf1
    ; Buffer 0: $5800-$6BFF
    LDA #0 : TAX
.cb0
    STA &5800,X : STA &5900,X : STA &5A00,X : STA &5B00,X
    STA &5C00,X : STA &5D00,X : STA &5E00,X : STA &5F00,X
    STA &6000,X : STA &6100,X : STA &6200,X : STA &6300,X
    STA &6400,X : STA &6500,X : STA &6600,X : STA &6700,X
    STA &6800,X : STA &6900,X : STA &6A00,X : STA &6B00,X
    INX : BNE cb0
    RTS
.clear_buf1
    ; Buffer 1: $6C00-$7FFF
    LDA #0 : TAX
.cb1
    STA &6C00,X : STA &6D00,X : STA &6E00,X : STA &6F00,X
    STA &7000,X : STA &7100,X : STA &7200,X : STA &7300,X
    STA &7400,X : STA &7500,X : STA &7600,X : STA &7700,X
    STA &7800,X : STA &7900,X : STA &7A00,X : STA &7B00,X
    STA &7C00,X : STA &7D00,X : STA &7E00,X : STA &7F00,X
    INX : BNE cb1
    RTS
}

; ======================================================================
; VSYNC_AND_FLIP — wait for vsync, present back buffer, swap
; ZP $70 = current back buffer hi ($58 or $6C). Updated on return.
; ======================================================================
.vsync_and_flip
{
    ; Wait for vsync: poll System VIA IFR bit 1 (CA1)
    LDA #2
.wv BIT &FE4D : BEQ wv
    STA &FE4D               ; clear vsync flag

    ; Set CRTC R12:R13 to display the just-rendered back buffer
    ; Read saved back buffer hi from $02F8 (ZP $70 clobbered by mul16x16)
    LDA #12 : STA &FE00
    LDA &02F8 : CMP #&6C : BEQ vf_buf1
    LDA #&0B : STA &FE01    ; R12 for buffer 0
    LDA #13 : STA &FE00
    LDA #&00 : STA &FE01    ; R13 for buffer 0
    JMP vf_swap
.vf_buf1
    LDA #&0D : STA &FE01    ; R12 for buffer 1
    LDA #13 : STA &FE00
    LDA #&80 : STA &FE01    ; R13 for buffer 1

.vf_swap
    ; Swap back buffer: toggle between $58 and $6C
    LDA &02F8 : EOR #(&58 EOR &6C) : STA &70 : STA &02F8
    RTS
}

.end_of_clipper
SAVE "clipper_bank2.bin", &9B20, end_of_clipper
