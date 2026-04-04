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
;   $0200-$021F  Column bitmap (32 bytes)
;   $0220-$02FF  BSP node stack (72 entries × 3 bytes = 216 bytes)
;   $0300-$0FFF  Command output buffer (~3KB)
;   $2000+       ROM main (vertices, nodes, subsectors, seg headers)
;   $6000+       ROM detail (seg detail: heights)
;   $A000-$A3FF  Quarter-square tables (4 × 256)
;   $A400+       ROM recip (sin/cos 128B + reciprocal tables)
;   $C000+       Code (this file)

ORG &C000

; ======================================================================
; Zero page assignments
; ======================================================================

; --- Math ---
zp_math_a   = &00
zp_math_b   = &01
zp_res_lo   = &02
zp_res_hi   = &03

; --- Player state (initialised by Python) ---
zp_px_int   = &10          ; s8  prescaled player x (integer part of 8.8)
zp_py_int   = &11          ; s8  prescaled player y
zp_px_lo    = &12          ; u8  fractional x (low byte of 8.8)
zp_py_lo    = &13          ; u8  fractional y
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

; --- Command buffer ---
zp_cmd_lo    = &56         ; u16 pointer to next command byte
zp_cmd_hi    = &57

; --- Deferred mark_solid stack (within subsector) ---
zp_defer_sp  = &58         ; u8 (byte offset into deferred stack)

; --- Pointer temps for ROM access ---
zp_ptr0      = &5A         ; u16 general-purpose pointer
zp_ptr1      = &5C         ; u16

; ======================================================================
; RAM addresses
; ======================================================================
colbitmap    = &0200        ; 32 bytes
bsp_stack    = &0220        ; 216 bytes (72 × 3)
cmd_buffer   = &0300        ; command output (grows upward)
deferred_stk = &0B00        ; deferred mark_solid pairs (64 × 4 = 256 bytes)

; ======================================================================
; ROM base addresses (set by Python loader)
; ======================================================================
rom_main     = &2000
rom_detail   = &6000

; Quarter-square tables
sqr_lo       = &A000
sqr_hi       = &A100
sqr2_lo      = &A200
sqr2_hi      = &A300

; Sin/cos + reciprocal tables
rom_recip    = &A400
sin_mag_tbl  = rom_recip        ; 64 bytes
sin_unity_tbl = rom_recip + 64  ; 64 bytes
recip_hi_tbl = rom_recip + 128  ; 513 bytes
recip_lo_tbl = rom_recip + 641  ; 513 bytes

; ======================================================================
; Layout offsets within rom_main (set by Python into these ZP locations)
; ======================================================================
zp_off_verts    = &60       ; u16
zp_off_nodes    = &62       ; u16
zp_off_ss       = &64       ; u16  (WAIT — conflicts with zp_cmd_lo!)

; Hmm, running out of ZP space. Let me use a different region.
; Actually let me use fixed addresses for the ROM layout offsets
; since they don't change during execution.  Store them in RAM.

layout_off_verts   = &0BF0  ; u16
layout_off_nodes   = &0BF2  ; u16
layout_off_ss      = &0BF4  ; u16
layout_off_seg_hdr = &0BF6  ; u16
layout_n_nodes     = &0BF8  ; u16

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

; Node offsets (within 16-byte record)
ND_PX  = 0                 ; s16
ND_PY  = 2                 ; s16
ND_DX  = 4                 ; s16
ND_DY  = 6                 ; s16
ND_CHR = 8                 ; u16 right child
ND_CHL = 10                ; u16 left child

; Command types
CMD_SOLID  = &53            ; 'S'
CMD_PORTAL = &50            ; 'P'
CMD_ENDSS  = &45            ; 'E'
CMD_DONE   = &00

; ======================================================================
; ENTRY POINT
; ======================================================================
.entry
    ; Clear column bitmap
    LDA #0
    LDX #31
.clr_bm
    STA colbitmap,X
    DEX
    BPL clr_bm

    ; Init BSP stack
    STA zp_bsp_sp

    ; Init command buffer pointer
    LDA #LO(cmd_buffer)
    STA zp_cmd_lo
    LDA #HI(cmd_buffer)
    STA zp_cmd_hi

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

    ; Write terminator
    LDY #0
    LDA #CMD_DONE
    STA (zp_cmd_lo),Y

    ; Done — return to Python
    BRK

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
    STA &0F14            ; debug: last nid lo
    LDA bsp_stack-2,X   ; nid hi
    STA zp_tmp0+1
    STA &0F15            ; debug: last nid hi

    ; Check if subsector (bit 15 set)
    AND #NF_SUBSECTOR
    BNE is_subsector

    ; --- It's a node: compute point_on_side ---
    JSR point_on_side    ; input: zp_tmp0 = nid, returns A = side (0 or 1)

    ; Save side in stack entry
    LDX zp_bsp_sp
    STA bsp_stack-1,X   ; side

    ; Restore nid from stack (point_on_side clobbers zp_tmp0)
    LDA bsp_stack-3,X
    STA zp_tmp0
    LDA bsp_stack-2,X
    STA zp_tmp0+1

    ; Get near child
    LDA bsp_stack-1,X   ; reload side into A
    JSR get_child        ; input: zp_tmp0 = nid, A = side; output: zp_tmp1 = child
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

    ; Check has_any_gap (coarse: is bitmap fully filled?)
    JSR has_any_gap
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
    ; Compute node address: rom_main + off_nodes + nid * 16
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

    ; Add rom_main base + off_nodes
    LDA zp_ptr0
    CLC
    ADC layout_off_nodes
    STA zp_ptr0
    LDA zp_ptr0+1
    ADC layout_off_nodes+1
    CLC
    ADC #HI(rom_main)
    STA zp_ptr0+1

    ; Read child: side 0 = offset 8 (right), side 1 = offset 10 (left)
    PLA
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
    ; Compute node address (same as get_child)
    LDA zp_tmp0
    ASL A : STA zp_ptr0
    LDA zp_tmp0+1
    ROL A : STA zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1
    ; ptr0 = nid * 16
    LDA zp_ptr0
    CLC
    ADC layout_off_nodes
    STA zp_ptr0
    LDA zp_ptr0+1
    ADC layout_off_nodes+1
    CLC
    ADC #HI(rom_main)
    STA zp_ptr0+1
    ; ptr0 → node record

    ; dx_to_player = px_int - node_x (s16 - s16 → s16)
    ; node_x is at ptr0+0 (s16 LE)
    ; But px_int is s8 in our ZP. Extend to s16.
    LDY #ND_PX
    LDA zp_px_int
    ; sign-extend px_int to 16 bits
    PHA
    LDX #0
    PLA
    BPL pos_px
    LDX #&FF
.pos_px
    SEC
    SBC (zp_ptr0),Y      ; lo byte
    STA zp_tmp2          ; dx_lo
    TXA                  ; hi byte of px_int
    INY
    SBC (zp_ptr0),Y
    STA zp_tmp2+1        ; dx_hi

    ; dy_to_player = py_int - node_y
    LDY #ND_PY
    LDA zp_py_int
    PHA
    LDX #0
    PLA
    BPL pos_py
    LDX #&FF
.pos_py
    SEC
    SBC (zp_ptr0),Y
    STA zp_tmp3          ; dy_lo
    TXA
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

    ; tmp2 = dy_to_player (in tmp3)
    LDA zp_tmp3
    STA zp_tmp2
    LDA zp_tmp3+1
    STA zp_tmp2+1

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

    ; Address = rom_main + off_ss + ssid * 4
    LDA zp_tmp0
    ASL A : STA zp_ptr0
    LDA zp_tmp0+1
    ROL A : STA zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1  ; × 4

    LDA zp_ptr0
    CLC
    ADC layout_off_ss
    STA zp_ptr0
    LDA zp_ptr0+1
    ADC layout_off_ss+1
    CLC
    ADC #HI(rom_main)
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

    ; Clear deferred mark_solid stack
    LDA #0
    STA zp_defer_sp

    ; Process each seg
.seg_loop
    LDA zp_seg_count
    BEQ segs_done
    DEC zp_seg_count
    JSR render_seg
    ; Advance seg index
    INC zp_seg_idx
    BNE seg_loop
    INC zp_seg_idx+1
    JMP seg_loop

.segs_done
    ; Flush deferred mark_solid
    LDX #0
.flush_loop
    CPX zp_defer_sp
    BCS flush_done
    ; Read x_lo, x_hi from deferred stack
    LDA deferred_stk,X
    STA zp_tmp0          ; x_lo lo
    LDA deferred_stk+1,X
    STA zp_tmp0+1        ; x_lo hi
    LDA deferred_stk+2,X
    STA zp_tmp1          ; x_hi lo
    LDA deferred_stk+3,X
    STA zp_tmp1+1        ; x_hi hi
    TXA
    PHA
    JSR mark_solid       ; input: zp_tmp0 = x_lo, zp_tmp1 = x_hi
    PLA
    TAX
    TXA
    CLC
    ADC #4
    TAX
    JMP flush_loop
.flush_done

    ; Emit end-of-subsector command
    LDY #0
    LDA #CMD_ENDSS
    STA (zp_cmd_lo),Y
    ; Advance cmd pointer by 1
    INC zp_cmd_lo
    BNE no_cmd_wrap
    INC zp_cmd_hi
.no_cmd_wrap

    RTS
}

; ======================================================================
; RENDER SEG
; Input: zp_seg_idx = seg index (u16)
; ======================================================================
.render_seg
{
    INC &0F00 : BNE no_dbg0 : INC &0F01 : .no_dbg0

    ; Compute seg header address: rom_main + off_seg_hdr + idx * 12
    ; idx * 12 = idx * 8 + idx * 4
    LDA zp_seg_idx
    STA zp_ptr0
    LDA zp_seg_idx+1
    STA zp_ptr0+1
    ; × 4
    ASL zp_ptr0 : ROL zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1
    ; save × 4
    LDA zp_ptr0
    STA zp_tmp0
    LDA zp_ptr0+1
    STA zp_tmp0+1
    ; × 8
    ASL zp_ptr0 : ROL zp_ptr0+1
    ; × 12 = ×8 + ×4
    LDA zp_ptr0
    CLC
    ADC zp_tmp0
    STA zp_ptr0
    LDA zp_ptr0+1
    ADC zp_tmp0+1
    STA zp_ptr0+1
    ; Add base
    LDA zp_ptr0
    CLC
    ADC layout_off_seg_hdr
    STA zp_ptr0
    LDA zp_ptr0+1
    ADC layout_off_seg_hdr+1
    CLC
    ADC #HI(rom_main)
    STA zp_ptr0+1
    ; ptr0 → seg header

    ; --- Back-face test ---
    ; dot = ldy * (px_int - lv1_x) - ldx * (py_int - lv1_y)
    ; lv1_x at offset 4 (s16), lv1_y at offset 6 (s16)
    ; ldx at offset 8 (s8), ldy at offset 9 (s8)

    ; dx_bf = px_int - lv1_x (s8 - s16 → s16)
    LDY #SH_LV1X
    LDA zp_px_int
    PHA
    LDX #0
    PLA
    BPL bf_px_pos
    LDX #&FF
.bf_px_pos
    SEC
    SBC (zp_ptr0),Y
    STA zp_tmp2
    TXA
    INY
    SBC (zp_ptr0),Y
    STA zp_tmp2+1        ; dx_bf (s16)

    ; dy_bf = py_int - lv1_y
    LDY #SH_LV1Y
    LDA zp_py_int
    PHA
    LDX #0
    PLA
    BPL bf_py_pos
    LDX #&FF
.bf_py_pos
    SEC
    SBC (zp_ptr0),Y
    STA zp_tmp3
    TXA
    INY
    SBC (zp_ptr0),Y
    STA zp_tmp3+1        ; dy_bf (s16)

    ; ldy (s8) at offset 9
    LDY #SH_LDY
    LDA (zp_ptr0),Y
    STA zp_tmp0           ; ldy

    ; ldx (s8) at offset 8
    LDY #SH_LDX
    LDA (zp_ptr0),Y
    STA zp_tmp1           ; ldx

    ; term1 = ldy * dx_bf (s8 × s16)
    ; term2 = ldx * dy_bf (s8 × s16)
    ; dot = term1 - term2

    ; For s8 × s16: use smul8x8 twice (lo and hi bytes of s16)
    ; ldy × dx_bf_lo (s8 × u8) + ldy × dx_bf_hi (s8 × s8) * 256
    LDA zp_tmp2           ; dx_bf_lo
    STA zp_math_b
    LDA zp_tmp0           ; ldy
    JSR smul8x8
    ; smul8x8(ldy, dx_bf_lo) — but dx_bf_lo is unsigned byte of a s16
    ; If dx_bf_lo > 127, result = ldy * (dx_bf_lo - 256), need correction: add ldy * 256
    STA &75               ; res_hi
    LDA zp_res_lo
    STA &74               ; res_lo
    ; Correction for unsigned lo byte
    LDA zp_tmp2
    BPL bf_lo1_ok
    ; Add ldy to hi byte
    LDA &75
    CLC
    ADC zp_tmp0
    STA &75
.bf_lo1_ok
    ; Sign-extend step_a 16-bit result to 24-bit byte2
    LDA &75
    BPL bf_se1_pos
    LDA #&FF : STA &76 : JMP bf_se1_done
.bf_se1_pos
    LDA #0 : STA &76
.bf_se1_done
    ; ldy × dx_bf_hi (s8 × s8 → s16)
    LDA zp_tmp2+1
    STA zp_math_b
    LDA zp_tmp0
    JSR smul8x8
    ; Add step_b to bytes 1-2 with carry propagation
    LDA &75
    CLC
    ADC zp_res_lo
    STA &75
    LDA &76
    ADC zp_res_hi
    STA &76
    ; term1 = $76:$75:$74 (24-bit)

    ; ldx × dy_bf: same approach
    LDA zp_tmp3           ; dy_bf_lo
    STA zp_math_b
    LDA zp_tmp1           ; ldx
    JSR smul8x8
    STA &79
    LDA zp_res_lo
    STA &78
    LDA zp_tmp3
    BPL bf_lo2_ok
    LDA &79
    CLC
    ADC zp_tmp1
    STA &79
.bf_lo2_ok
    ; Sign-extend step_a to byte2
    LDA &79
    BPL bf_se2_pos
    LDA #&FF : STA &7A : JMP bf_se2_done
.bf_se2_pos
    LDA #0 : STA &7A
.bf_se2_done
    LDA zp_tmp3+1
    STA zp_math_b
    LDA zp_tmp1
    JSR smul8x8
    LDA &79
    CLC
    ADC zp_res_lo
    STA &79
    LDA &7A
    ADC zp_res_hi
    STA &7A
    ; term2 = $7A:$79:$78 (24-bit)

    ; dot = term1 - term2 = $76:$75:$74 - $7A:$79:$78
    LDA &74
    SEC
    SBC &78
    STA &74               ; dot_lo
    LDA &75
    SBC &79
    STA &75               ; dot_mid
    LDA &76
    SBC &7A
    STA &76               ; dot_hi

    ; Read flags
    LDY #SH_FLAGS
    LDA (zp_ptr0),Y
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
    INC &0F02 : BNE no_dbg1 : INC &0F03 : .no_dbg1

    ; --- Read vertex indices ---
    LDY #SH_V1
    LDA (zp_ptr0),Y
    STA zp_tmp0           ; v1 lo
    INY
    LDA (zp_ptr0),Y
    STA zp_tmp0+1         ; v1 hi
    LDY #SH_V2
    LDA (zp_ptr0),Y
    STA zp_tmp1           ; v2 lo
    INY
    LDA (zp_ptr0),Y
    STA zp_tmp1+1         ; v2 hi

    ; --- View transform vertex 1 ---
    JSR load_vertex       ; input: zp_tmp0 = v_idx; output: zp_tmp2 = wx, zp_tmp3 = wy
    JSR to_view           ; output: zp_vx1, zp_vy1, zp_vi1

    ; Save v1 results (to_view always writes to vx1/vy1/vi1)
    LDA zp_vx1 : PHA : LDA zp_vx1+1 : PHA
    LDA zp_vy1 : PHA : LDA zp_vy1+1 : PHA
    LDA zp_vi1 : PHA : LDA zp_vi1+1 : PHA

    ; --- View transform vertex 2 ---
    LDA zp_tmp1
    STA zp_tmp0
    LDA zp_tmp1+1
    STA zp_tmp0+1
    JSR load_vertex
    JSR to_view           ; overwrites vx1/vy1/vi1 with v2 values
    ; Copy to v2 slots
    LDA zp_vx1 : STA zp_vx2
    LDA zp_vx1+1 : STA zp_vx2+1
    LDA zp_vy1 : STA zp_vy2
    LDA zp_vy1+1 : STA zp_vy2+1
    LDA zp_vi1 : STA zp_vi2
    LDA zp_vi1+1 : STA zp_vi2+1

    ; Restore v1 results
    PLA : STA zp_vi1+1 : PLA : STA zp_vi1
    PLA : STA zp_vy1+1 : PLA : STA zp_vy1
    PLA : STA zp_vx1+1 : PLA : STA zp_vx1

    ; --- Near clip ---
    JSR near_clip         ; input: vx1,vy1, vx2,vy2
                          ; output: ex1,ey1, ex2,ey2 or carry set = clipped away
    BCS seg_clipped
    INC &0F04 : BNE no_dbg2 : INC &0F05 : .no_dbg2

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

    ; --- Compute x_lo, x_hi ---
    ; x_lo = min(sx1, sx2), x_hi = max(sx1, sx2)
    JSR compute_x_range   ; output: zp_x_lo_clip, zp_x_hi_clip

    ; --- Has gap? ---
    JSR has_gap           ; input: zp_x_lo_clip, zp_x_hi_clip
    BCC seg_clipped       ; no gap
    INC &0F06 : BNE no_dbg3 : INC &0F07 : .no_dbg3

    ; --- Read seg detail (heights) ---
    JSR read_seg_detail   ; loads fh, ch (and bfh, bch if portal) into temps

    ; --- Y projection ---
    JSR project_y_all     ; projects ft1, fb1, ft2, fb2 (and bt/bb if needed)

    ; --- Emit command ---
    LDA zp_seg_flags
    AND #SF_SOLID
    BNE emit_solid

    ; Portal
    JSR emit_portal_cmd
    RTS

.emit_solid
    JSR emit_solid_cmd
    ; Defer mark_solid
    LDX zp_defer_sp
    LDA zp_x_lo_clip
    STA deferred_stk,X
    LDA zp_x_lo_clip+1
    STA deferred_stk+1,X
    LDA zp_x_hi_clip
    STA deferred_stk+2,X
    LDA zp_x_hi_clip+1
    STA deferred_stk+3,X
    TXA
    CLC
    ADC #4
    STA zp_defer_sp
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
    ; addr = rom_main + off_verts + idx * 4
    LDA zp_tmp0
    ASL A : STA zp_ptr0
    LDA zp_tmp0+1
    ROL A : STA zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1   ; × 4
    LDA zp_ptr0
    CLC
    ADC layout_off_verts
    STA zp_ptr0
    LDA zp_ptr0+1
    ADC layout_off_verts+1
    CLC
    ADC #HI(rom_main)
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
.rot_term
{
    STX &7E               ; save neg flag
    TYA
    BNE rt_unity
    ; Check mag
    LDA zp_math_b
    BEQ rt_zero
    ; Non-unity, non-zero: use mul_s16_u8_s24 (handles mag > 127)
    JSR mul_s16_u8_s24
    JMP rt_apply_neg

.rt_unity
    ; Result = val << 8 (3 bytes: lo=0, mid=val_lo, hi=val_hi)
    LDA #0
    STA &70
    LDA zp_tmp2
    STA &71
    LDA zp_tmp2+1
    STA &72
    JMP rt_apply_neg

.rt_zero
    LDA #0
    STA &70 : STA &71 : STA &72
    RTS

.rt_apply_neg
    LDA &7E               ; neg flag
    BEQ rt_done
    ; Negate 24-bit $70:$71:$72
    LDA &70
    EOR #&FF
    CLC
    ADC #1
    STA &70
    LDA &71
    EOR #&FF
    ADC #0
    STA &71
    LDA &72
    EOR #&FF
    ADC #0
    STA &72
.rt_done
    RTS
}

.to_view
{
    ; dx = wx - px_int (s16 - s8_extended)
    LDA zp_px_int
    BPL px_pos
    ; Negative: sign-extend to $FF
    STA zp_tmp0
    LDA #&FF
    STA zp_tmp0+1
    JMP px_done
.px_pos
    STA zp_tmp0
    LDA #0
    STA zp_tmp0+1
.px_done
    ; dx = tmp2 - tmp0
    LDA zp_tmp2
    SEC
    SBC zp_tmp0
    STA zp_tmp2
    LDA zp_tmp2+1
    SBC zp_tmp0+1
    STA zp_tmp2+1        ; dx in tmp2

    ; dy = wy - py_int
    LDA zp_py_int
    BPL py_pos
    STA zp_tmp0
    LDA #&FF
    STA zp_tmp0+1
    JMP py_done
.py_pos
    STA zp_tmp0
    LDA #0
    STA zp_tmp0+1
.py_done
    LDA zp_tmp3
    SEC
    SBC zp_tmp0
    STA zp_tmp3
    LDA zp_tmp3+1
    SBC zp_tmp0+1
    STA zp_tmp3+1        ; dy in tmp3

    ; Save dx ($76:$77) and dy ($78:$79) for all 4 rotations
    LDA zp_tmp2 : STA &76
    LDA zp_tmp2+1 : STA &77
    LDA zp_tmp3 : STA &78
    LDA zp_tmp3+1 : STA &79

    ; --- VX computation: rot(dx, sin) - rot(dy, cos) ---

    ; rot(dx, sin) → $70:$71:$72
    ; tmp2 already has dx
    LDA zp_sin_mag : STA zp_math_b
    LDX zp_sin_neg
    LDY zp_sin_unity
    JSR rot_term
    ; Save to $73:$74:$75
    LDA &70 : STA &73
    LDA &71 : STA &74
    LDA &72 : STA &75
    ; DEBUG: $75 after save
    LDA &75 : STA &0FE8

    ; rot(dy, cos) → $70:$71:$72
    LDA &78 : STA zp_tmp2
    LDA &79 : STA zp_tmp2+1
    LDA zp_cos_mag : STA zp_math_b
    LDX zp_cos_neg
    LDY zp_cos_unity
    JSR rot_term
    ; DEBUG: $75 after second rot_term
    LDA &75 : STA &0FE9

    ; int_vx = $73:$74:$75 - $70:$71:$72 → $70:$71:$72
    LDA &73 : SEC : SBC &70 : STA &70
    LDA &74 : SBC &71 : STA &71
    LDA &75 : SBC &72 : STA &72

    ; total_vx = int_vx + frac_vx (s16, sign-extend to 24-bit)
    LDA &70 : CLC : ADC zp_frac_vx : STA &70
    LDA &71 : ADC zp_frac_vx+1 : STA &71
    ; sign-extend frac_vx for byte 2
    LDA zp_frac_vx+1
    BPL vx_frac_pos
    LDA &72 : ADC #&FF : STA &72
    JMP vx_done_frac
.vx_frac_pos
    LDA &72 : ADC #0 : STA &72
.vx_done_frac
    ; total_vx is now in $70:$71:$72 (24-bit)
    ; --- VY computation: rot(dx, cos) + rot(dy, sin) ---

    ; rot(dx, cos) → $70 area via rot_term
    LDA &76 : STA zp_tmp2     ; restore dx
    LDA &77 : STA zp_tmp2+1
    LDA zp_cos_mag : STA zp_math_b
    LDX zp_cos_neg
    LDY zp_cos_unity
    ; Save total_vx to $0FE0:$0FE1:$0FE2 (safe from ZP temp conflicts)
    LDA &70 : STA &0FE0
    LDA &71 : STA &0FE1
    LDA &72 : STA &0FE2
    JSR rot_term
    ; rot(dx, cos) in $70:$71:$72 — save to $73:$74:$75
    LDA &70 : STA &73
    LDA &71 : STA &74
    LDA &72 : STA &75

    ; rot(dy, sin) → $70:$71:$72
    LDA &78 : STA zp_tmp2     ; restore dy
    LDA &79 : STA zp_tmp2+1
    LDA zp_sin_mag : STA zp_math_b
    LDX zp_sin_neg
    LDY zp_sin_unity
    JSR rot_term

    ; int_vy = rot(dx,cos) + rot(dy,sin) = $73:$74:$75 + $70:$71:$72
    LDA &73 : CLC : ADC &70 : STA &70
    LDA &74 : ADC &71 : STA &71
    LDA &75 : ADC &72 : STA &72

    ; total_vy = int_vy + frac_vy (sign-extend to 24-bit)
    LDA &70 : CLC : ADC zp_frac_vy : STA &70
    LDA &71 : ADC zp_frac_vy+1 : STA &71
    LDA zp_frac_vy+1
    BPL vy_frac_pos
    LDA &72 : ADC #&FF : STA &72
    JMP vy_done_frac
.vy_frac_pos
    LDA &72 : ADC #0 : STA &72
.vy_done_frac
    ; total_vy in $70:$71:$72 (24-bit)
    ; Save to $73:$74:$75
    LDA &70 : STA &73
    LDA &71 : STA &74
    LDA &72 : STA &75

    ; === Extract vx1, vy1, vi1 ===

    ; vx1 = (total_vx + 128) >> 8
    ; total_vx in $0FE0:$0FE1:$0FE2 (24-bit, lo:mid:hi)
    LDA &0FE0 : CLC : ADC #128
    LDA &0FE1 : ADC #0 : STA zp_vx1
    LDA &0FE2 : ADC #0 : STA zp_vx1+1

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
    ; sign-extend
    PHA
    LDX #0
    PLA
    BPL nc_dvx_pos
    LDX #&FF
.nc_dvx_pos
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
    PHA : LDX #0 : PLA : BPL nc2_pos : LDX #&FF
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
    ; Save b for later correction check
    LDA zp_math_b
    STA &7D                   ; $7D = b (for > 127 correction)

    ; ex_lo * b (unsigned × unsigned)
    LDA zp_tmp2               ; ex_lo
    JSR umul8x8
    LDA zp_res_lo
    STA &70                   ; byte0 = lo(ex_lo * b)
    LDA zp_res_hi
    STA &71                   ; temp: hi(ex_lo * b)

    ; ex_hi * b (signed × unsigned-treated-as-signed)
    LDA &7D
    STA zp_math_b
    LDA zp_tmp2+1             ; ex_hi (signed)
    JSR smul8x8
    ; Add res_lo to $71, res_hi (with carry) to $72
    LDA &71
    CLC
    ADC zp_res_lo
    STA &71
    LDA zp_res_hi
    ADC #0
    STA &72

    ; Correction for b > 127: add ex_hi (signed, as u8) to $72
    LDA &7D
    BPL m16u8_done             ; b <= 127 → no correction
    LDA &72
    CLC
    ADC zp_tmp2+1             ; add ex_hi (signed byte)
    STA &72
.m16u8_done
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
    STA zp_math_b
    JSR mul_s16_u8_s24
    ; Save term1 to $80:$81:$82
    LDA &70 : STA &80
    LDA &71 : STA &81
    LDA &72 : STA &82

    ; raw = ex1 * rxl → $70:$71:$72
    LDA zp_rxl
    STA zp_math_b
    JSR mul_s16_u8_s24
    ; term2 = raw >> 8: take $71:$72 as s16, sign-extend to s24
    ; $70 = $71 (new lo = old mid)
    ; $71 = $72 (new mid = old hi)
    ; $72 = sign extension of $72
    LDA &71 : STA &70
    LDA &72 : STA &71
    BPL rpx1_shift_pos
    LDA #&FF
    STA &72
    JMP rpx1_shift_done
.rpx1_shift_pos
    LDA #&00
    STA &72
.rpx1_shift_done

    ; total = term1 + term2 (s24 + s24 → s24)
    LDA &80 : CLC : ADC &70 : STA &70
    LDA &81 : ADC &71 : STA &71
    LDA &82 : ADC &72 : STA &72

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
    STA zp_math_b
    JSR mul_s16_u8_s24
    LDA &70 : STA &80
    LDA &71 : STA &81
    LDA &72 : STA &82

    LDA zp_rxl
    STA zp_math_b
    JSR mul_s16_u8_s24
    LDA &71 : STA &70
    LDA &72 : STA &71
    BPL rpx2_shift_pos
    LDA #&FF
    STA &72
    JMP rpx2_shift_done
.rpx2_shift_pos
    LDA #&00
    STA &72
.rpx2_shift_done

    LDA &80 : CLC : ADC &70 : STA &70
    LDA &81 : ADC &71 : STA &71
    LDA &82 : ADC &72 : STA &72

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


.compute_x_range
{
    ; Compare sx1 vs sx2 (signed 16-bit)
    LDA zp_sx1
    CMP zp_sx2
    LDA zp_sx1+1
    SBC zp_sx2+1
    BVC no_overflow
    EOR #&80
.no_overflow
    BMI sx1_less          ; sx1 < sx2
    ; sx1 >= sx2: x_lo = sx2, x_hi = sx1
    LDA zp_sx2 : STA zp_x_lo_clip
    LDA zp_sx2+1 : STA zp_x_lo_clip+1
    LDA zp_sx1 : STA zp_x_hi_clip
    LDA zp_sx1+1 : STA zp_x_hi_clip+1
    RTS
.sx1_less
    LDA zp_sx1 : STA zp_x_lo_clip
    LDA zp_sx1+1 : STA zp_x_lo_clip+1
    LDA zp_sx2 : STA zp_x_hi_clip
    LDA zp_sx2+1 : STA zp_x_hi_clip+1
    RTS
}

; ======================================================================
; HAS_GAP: check column bitmap for any unset bit in [x_lo, x_hi]
; Input: zp_x_lo_clip (s16), zp_x_hi_clip (s16)
; Output: carry set = has gap, carry clear = no gap
; Clamps to [0, 255]
; ======================================================================
.has_gap
{
    ; Clamp x_lo to [0, 255]
    LDA zp_x_lo_clip+1
    BMI use_zero_lo       ; negative → 0
    BNE use_255_lo        ; > 255 → 255
    LDA zp_x_lo_clip
    JMP got_lo
.use_zero_lo
    LDA #0
    JMP got_lo
.use_255_lo
    LDA #255
.got_lo
    STA &70               ; clamped x_lo

    ; Clamp x_hi
    LDA zp_x_hi_clip+1
    BMI use_zero_hi
    BNE use_255_hi
    LDA zp_x_hi_clip
    JMP got_hi
.use_zero_hi
    LDA #0
    JMP got_hi
.use_255_hi
    LDA #255
.got_hi
    STA &71               ; clamped x_hi

    ; Iterate from x_lo to x_hi, check each bit
    LDA &70
    CMP &71
    BEQ check_one         ; x_lo == x_hi: check one pixel
    BCS no_gap            ; x_lo > x_hi: no gap (shouldn't happen after swap)

.check_one
    LDX &70
.check_loop
    TXA
    AND #7
    TAY
    LDA bit_masks,Y       ; bit mask for bit position
    PHA                    ; save mask
    TXA
    LSR A : LSR A : LSR A  ; byte index
    TAY
    PLA                    ; mask
    AND colbitmap,Y
    BEQ found_gap          ; bit is 0 → gap exists

    INX
    CPX &71
    BEQ check_last
    BCC check_loop         ; X < x_hi → continue
    JMP no_gap
.check_last
    ; Check the last pixel too
    TXA
    AND #7
    TAY
    LDA bit_masks,Y
    PHA
    TXA
    LSR A : LSR A : LSR A
    TAY
    PLA
    AND colbitmap,Y
    BEQ found_gap

.no_gap
    CLC
    RTS
.found_gap
    SEC
    RTS
}

; Bit mask table
.bit_masks
    EQUB &01, &02, &04, &08, &10, &20, &40, &80

; ======================================================================
; HAS_ANY_GAP: check if ANY column is unset (bitmap not fully filled)
; Output: carry set = has gap, carry clear = full
; ======================================================================
.has_any_gap
{
    LDX #31
.loop
    LDA colbitmap,X
    CMP #&FF
    BNE found
    DEX
    BPL loop
    CLC
    RTS
.found
    SEC
    RTS
}

; ======================================================================
; MARK_SOLID: set bits in column bitmap for [x_lo, x_hi]
; Input: zp_tmp0 = x_lo (s16), zp_tmp1 = x_hi (s16)
; ======================================================================
.mark_solid
{
    ; Clamp x_lo to [0, 255]
    LDA zp_tmp0+1
    BMI ms_zero_lo
    BNE ms_255_lo
    LDA zp_tmp0
    JMP ms_got_lo
.ms_zero_lo
    LDA #0
    JMP ms_got_lo
.ms_255_lo
    LDA #255
.ms_got_lo
    STA &70

    ; Clamp x_hi
    LDA zp_tmp1+1
    BMI ms_zero_hi
    BNE ms_255_hi
    LDA zp_tmp1
    JMP ms_got_hi
.ms_zero_hi
    LDA #0
    JMP ms_got_hi
.ms_255_hi
    LDA #255
.ms_got_hi
    STA &71

    LDX &70
.ms_loop
    CPX &71
    BEQ ms_last
    BCS ms_done
.ms_last
    TXA
    AND #7
    TAY
    LDA bit_masks,Y
    PHA
    TXA
    LSR A : LSR A : LSR A
    TAY
    PLA
    ORA colbitmap,Y
    STA colbitmap,Y
    CPX &71
    BEQ ms_done
    INX
    JMP ms_loop
.ms_done
    RTS
}

; ======================================================================
; READ SEG DETAIL + PROJECT Y
; Reads heights from rom_detail and projects Y coordinates
; Input: zp_seg_idx, zp_seg_flags, reciprocals already computed
; Output: ft1, fb1, ft2, fb2 (and bt/bb if portal)
; ======================================================================
.read_seg_detail
{
    ; addr = rom_detail + seg_idx * 24
    ; seg_idx * 24 = seg_idx * 16 + seg_idx * 8
    LDA zp_seg_idx : STA zp_ptr0
    LDA zp_seg_idx+1 : STA zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1
    ASL zp_ptr0 : ROL zp_ptr0+1   ; × 8
    LDA zp_ptr0 : STA zp_tmp0
    LDA zp_ptr0+1 : STA zp_tmp0+1
    ASL zp_ptr0 : ROL zp_ptr0+1   ; × 16
    LDA zp_ptr0
    CLC : ADC zp_tmp0
    STA zp_ptr0
    LDA zp_ptr0+1
    ADC zp_tmp0+1                 ; × 24
    CLC : ADC #HI(rom_detail)
    STA zp_ptr0+1
    ; ptr0 → seg detail record

    ; Read fh (s8), ch (s8), bfh (s8), bch (s8)
    LDY #SD_FH
    LDA (zp_ptr0),Y
    STA &80                       ; fh
    LDY #SD_CH
    LDA (zp_ptr0),Y
    STA &81                       ; ch
    LDY #SD_BFH
    LDA (zp_ptr0),Y
    STA &82                       ; bfh
    LDY #SD_BCH
    LDA (zp_ptr0),Y
    STA &83                       ; bch

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
    ; h is s8. Uses mul_s16_u8_s24 (h sign-extended to s16).
    ;
    ; Reciprocals saved by caller:
    ;   $88=rxh1, $89=rxl1 (endpoint 1)
    ;   $8A=rxh2, $8B=rxl2 (endpoint 2)
    ; Heights:
    ;   $80=fh, $81=ch, $82=bfh, $83=bch
    ; Outputs:
    ;   zp_ft1, zp_fb1, zp_ft2, zp_fb2, $84-$87=bt1/bt2, $90-$93=bb1/bb2

    ; --- ft1 = project_y(ch - vz_ps, rxh1, rxl1) ---
    LDA &81
    SEC
    SBC zp_vz_ps
    STA zp_tmp2               ; h_lo
    BPL py_ft1_pos
    LDA #&FF
    STA zp_tmp2+1
    JMP py_ft1_done_ext
.py_ft1_pos
    LDA #0
    STA zp_tmp2+1
.py_ft1_done_ext
    LDA &88 : STA zp_math_b
    JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95 : LDA &72 : STA &96
    LDA &89 : STA zp_math_b
    JSR mul_s16_u8_s24
    ; term2 = (raw >> 8)
    LDA &71 : STA &70
    LDA &72 : STA &71
    BPL py_ft1_shp
    LDA #&FF : STA &72 : JMP py_ft1_shd
.py_ft1_shp
    LDA #0 : STA &72
.py_ft1_shd
    LDA &94 : CLC : ADC &70 : STA &70
    LDA &95 : ADC &71 : STA &71
    LDA &96 : ADC &72 : STA &72
    ; HALF_H - total (s24 subtract)
    LDA #HALF_H : SEC : SBC &70 : STA zp_ft1
    LDA #0 : SBC &71 : STA zp_ft1+1

    ; --- fb1 = project_y(fh - vz_ps, rxh1, rxl1) ---
    LDA &80 : SEC : SBC zp_vz_ps : STA zp_tmp2
    BPL py_fb1_pos
    LDA #&FF : STA zp_tmp2+1 : JMP py_fb1_done_ext
.py_fb1_pos
    LDA #0 : STA zp_tmp2+1
.py_fb1_done_ext
    LDA &88 : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95 : LDA &72 : STA &96
    LDA &89 : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &71 : STA &70 : LDA &72 : STA &71
    BPL py_fb1_shp
    LDA #&FF : STA &72 : JMP py_fb1_shd
.py_fb1_shp
    LDA #0 : STA &72
.py_fb1_shd
    LDA &94 : CLC : ADC &70 : STA &70
    LDA &95 : ADC &71 : STA &71
    LDA &96 : ADC &72 : STA &72
    LDA #HALF_H : SEC : SBC &70 : STA zp_fb1
    LDA #0 : SBC &71 : STA zp_fb1+1

    ; --- ft2 = project_y(ch - vz_ps, rxh2, rxl2) ---
    LDA &81 : SEC : SBC zp_vz_ps : STA zp_tmp2
    BPL py_ft2_pos
    LDA #&FF : STA zp_tmp2+1 : JMP py_ft2_done_ext
.py_ft2_pos
    LDA #0 : STA zp_tmp2+1
.py_ft2_done_ext
    LDA &8A : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95 : LDA &72 : STA &96
    LDA &8B : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &71 : STA &70 : LDA &72 : STA &71
    BPL py_ft2_shp
    LDA #&FF : STA &72 : JMP py_ft2_shd
.py_ft2_shp
    LDA #0 : STA &72
.py_ft2_shd
    LDA &94 : CLC : ADC &70 : STA &70
    LDA &95 : ADC &71 : STA &71
    LDA &96 : ADC &72 : STA &72
    LDA #HALF_H : SEC : SBC &70 : STA zp_ft2
    LDA #0 : SBC &71 : STA zp_ft2+1

    ; --- fb2 = project_y(fh - vz_ps, rxh2, rxl2) ---
    LDA &80 : SEC : SBC zp_vz_ps : STA zp_tmp2
    BPL py_fb2_pos
    LDA #&FF : STA zp_tmp2+1 : JMP py_fb2_done_ext
.py_fb2_pos
    LDA #0 : STA zp_tmp2+1
.py_fb2_done_ext
    LDA &8A : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95 : LDA &72 : STA &96
    LDA &8B : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &71 : STA &70 : LDA &72 : STA &71
    BPL py_fb2_shp
    LDA #&FF : STA &72 : JMP py_fb2_shd
.py_fb2_shp
    LDA #0 : STA &72
.py_fb2_shd
    LDA &94 : CLC : ADC &70 : STA &70
    LDA &95 : ADC &71 : STA &71
    LDA &96 : ADC &72 : STA &72
    LDA #HALF_H : SEC : SBC &70 : STA zp_fb2
    LDA #0 : SBC &71 : STA zp_fb2+1

    ; --- Back heights if portal ---
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

    ; bt1 = project_y(bch - vz_ps, rxh1, rxl1)
    LDA &83 : SEC : SBC zp_vz_ps : STA zp_tmp2
    BPL py_bt1_pos
    LDA #&FF : STA zp_tmp2+1 : JMP py_bt1_done_ext
.py_bt1_pos
    LDA #0 : STA zp_tmp2+1
.py_bt1_done_ext
    LDA &88 : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95 : LDA &72 : STA &96
    LDA &89 : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &71 : STA &70 : LDA &72 : STA &71
    BPL py_bt1_shp
    LDA #&FF : STA &72 : JMP py_bt1_shd
.py_bt1_shp
    LDA #0 : STA &72
.py_bt1_shd
    LDA &94 : CLC : ADC &70 : STA &70
    LDA &95 : ADC &71 : STA &71
    LDA &96 : ADC &72 : STA &72
    LDA #HALF_H : SEC : SBC &70 : STA &84
    LDA #0 : SBC &71 : STA &85

    ; bt2 = project_y(bch - vz_ps, rxh2, rxl2)
    LDA &83 : SEC : SBC zp_vz_ps : STA zp_tmp2
    BPL py_bt2_pos
    LDA #&FF : STA zp_tmp2+1 : JMP py_bt2_done_ext
.py_bt2_pos
    LDA #0 : STA zp_tmp2+1
.py_bt2_done_ext
    LDA &8A : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95 : LDA &72 : STA &96
    LDA &8B : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &71 : STA &70 : LDA &72 : STA &71
    BPL py_bt2_shp
    LDA #&FF : STA &72 : JMP py_bt2_shd
.py_bt2_shp
    LDA #0 : STA &72
.py_bt2_shd
    LDA &94 : CLC : ADC &70 : STA &70
    LDA &95 : ADC &71 : STA &71
    LDA &96 : ADC &72 : STA &72
    LDA #HALF_H : SEC : SBC &70 : STA &86
    LDA #0 : SBC &71 : STA &87

.py_skip_bt
    LDA zp_seg_flags
    AND #SF_NEEDBB
    BNE py_do_bb
    JMP py_done_final
.py_do_bb

    ; bb1
    LDA &82 : SEC : SBC zp_vz_ps : STA zp_tmp2
    BPL py_bb1_pos
    LDA #&FF : STA zp_tmp2+1 : JMP py_bb1_done_ext
.py_bb1_pos
    LDA #0 : STA zp_tmp2+1
.py_bb1_done_ext
    LDA &88 : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95 : LDA &72 : STA &96
    LDA &89 : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &71 : STA &70 : LDA &72 : STA &71
    BPL py_bb1_shp
    LDA #&FF : STA &72 : JMP py_bb1_shd
.py_bb1_shp
    LDA #0 : STA &72
.py_bb1_shd
    LDA &94 : CLC : ADC &70 : STA &70
    LDA &95 : ADC &71 : STA &71
    LDA &96 : ADC &72 : STA &72
    LDA #HALF_H : SEC : SBC &70 : STA &90
    LDA #0 : SBC &71 : STA &91

    ; bb2
    LDA &82 : SEC : SBC zp_vz_ps : STA zp_tmp2
    BPL py_bb2_pos
    LDA #&FF : STA zp_tmp2+1 : JMP py_bb2_done_ext
.py_bb2_pos
    LDA #0 : STA zp_tmp2+1
.py_bb2_done_ext
    LDA &8A : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &70 : STA &94 : LDA &71 : STA &95 : LDA &72 : STA &96
    LDA &8B : STA zp_math_b : JSR mul_s16_u8_s24
    LDA &71 : STA &70 : LDA &72 : STA &71
    BPL py_bb2_shp
    LDA #&FF : STA &72 : JMP py_bb2_shd
.py_bb2_shp
    LDA #0 : STA &72
.py_bb2_shd
    LDA &94 : CLC : ADC &70 : STA &70
    LDA &95 : ADC &71 : STA &71
    LDA &96 : ADC &72 : STA &72
    LDA #HALF_H : SEC : SBC &70 : STA &92
    LDA #0 : SBC &71 : STA &93

.py_done_final
    RTS
}

; ======================================================================
; EMIT SOLID COMMAND
; Writes: type(1) + sx1(2) + sx2(2) + ft1(2) + fb1(2) + ft2(2) + fb2(2) = 13 bytes
; ======================================================================
.emit_solid_cmd
{
    LDY #0
    LDA #CMD_SOLID
    STA (zp_cmd_lo),Y : INY
    LDA zp_sx1   : STA (zp_cmd_lo),Y : INY
    LDA zp_sx1+1 : STA (zp_cmd_lo),Y : INY
    LDA zp_sx2   : STA (zp_cmd_lo),Y : INY
    LDA zp_sx2+1 : STA (zp_cmd_lo),Y : INY
    LDA zp_ft1   : STA (zp_cmd_lo),Y : INY
    LDA zp_ft1+1 : STA (zp_cmd_lo),Y : INY
    LDA zp_fb1   : STA (zp_cmd_lo),Y : INY
    LDA zp_fb1+1 : STA (zp_cmd_lo),Y : INY
    LDA zp_ft2   : STA (zp_cmd_lo),Y : INY
    LDA zp_ft2+1 : STA (zp_cmd_lo),Y : INY
    LDA zp_fb2   : STA (zp_cmd_lo),Y : INY
    LDA zp_fb2+1 : STA (zp_cmd_lo),Y

    ; Advance cmd pointer by 13
    LDA zp_cmd_lo
    CLC : ADC #13
    STA zp_cmd_lo
    LDA zp_cmd_hi
    ADC #0
    STA zp_cmd_hi
    RTS
}

; ======================================================================
; EMIT PORTAL COMMAND
; type(1) + sx1(2) + sx2(2) + ft1(2) + fb1(2) + ft2(2) + fb2(2) +
; flags(1) + bt1(2) + bt2(2) + bb1(2) + bb2(2) + bch(1) + bfh(1) + ch(1) + fh(1)
; = 26 bytes
; ======================================================================
.emit_portal_cmd
{
    LDY #0
    LDA #CMD_PORTAL
    STA (zp_cmd_lo),Y : INY
    LDA zp_sx1   : STA (zp_cmd_lo),Y : INY
    LDA zp_sx1+1 : STA (zp_cmd_lo),Y : INY
    LDA zp_sx2   : STA (zp_cmd_lo),Y : INY
    LDA zp_sx2+1 : STA (zp_cmd_lo),Y : INY
    LDA zp_ft1   : STA (zp_cmd_lo),Y : INY
    LDA zp_ft1+1 : STA (zp_cmd_lo),Y : INY
    LDA zp_fb1   : STA (zp_cmd_lo),Y : INY
    LDA zp_fb1+1 : STA (zp_cmd_lo),Y : INY
    LDA zp_ft2   : STA (zp_cmd_lo),Y : INY
    LDA zp_ft2+1 : STA (zp_cmd_lo),Y : INY
    LDA zp_fb2   : STA (zp_cmd_lo),Y : INY
    LDA zp_fb2+1 : STA (zp_cmd_lo),Y : INY
    ; flags: need_bt | need_bb
    LDA zp_seg_flags
    AND #(SF_NEEDBT OR SF_NEEDBB)
    STA (zp_cmd_lo),Y : INY
    ; bt1
    LDA &84 : STA (zp_cmd_lo),Y : INY
    LDA &85 : STA (zp_cmd_lo),Y : INY
    ; bt2
    LDA &86 : STA (zp_cmd_lo),Y : INY
    LDA &87 : STA (zp_cmd_lo),Y : INY
    ; bb1
    LDA &90 : STA (zp_cmd_lo),Y : INY
    LDA &91 : STA (zp_cmd_lo),Y : INY
    ; bb2
    LDA &92 : STA (zp_cmd_lo),Y : INY
    LDA &93 : STA (zp_cmd_lo),Y : INY
    ; bch, bfh, ch, fh
    LDA &83 : STA (zp_cmd_lo),Y : INY  ; bch
    LDA &82 : STA (zp_cmd_lo),Y : INY  ; bfh
    LDA &81 : STA (zp_cmd_lo),Y : INY  ; ch
    LDA &80 : STA (zp_cmd_lo),Y        ; fh

    ; Advance by 26
    LDA zp_cmd_lo
    CLC : ADC #26
    STA zp_cmd_lo
    LDA zp_cmd_hi
    ADC #0
    STA zp_cmd_hi
    RTS
}

; ======================================================================
; MATH: smul8x8 — Signed 8×8 → 16-bit multiply (quarter-square)
; Input: A = signed multiplier, zp_math_b = signed multiplicand
; Output: zp_res_lo:zp_res_hi, A = res_hi
; ======================================================================
.smul8x8
{
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
}

; ======================================================================
; MATH: umul8x8 — Unsigned 8×8 → 16-bit multiply (quarter-square)
; Input: A = unsigned multiplier, zp_math_b = unsigned multiplicand
; Output: zp_res_lo:zp_res_hi, A = res_hi
; ======================================================================
.umul8x8
{
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
}

.end_of_code

SAVE "doom_fe.bin", &C000, end_of_code
